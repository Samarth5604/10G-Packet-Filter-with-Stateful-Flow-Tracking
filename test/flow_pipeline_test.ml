(* flow_pipeline_test.ml -- the pending-insert race.
   ---------------------------------------------------------------------------
   Demonstrates the race, shows the pending CAM fixes it, and measures how deep
   that CAM must be. The functional model in Flow_table cannot express any of
   this: it has no cycles, so every insert is atomic and the race is invisible.
   --------------------------------------------------------------------------- *)

open Flow_pipeline

let failures = ref 0
let check name c =
  if c then Printf.printf "  ok    %s\n" name
  else begin incr failures; Printf.printf "  FAIL  %s\n" name end

let key i =
  let st = Random.State.make [| i |] in
  Bytes.init 13 (fun _ -> Char.chr (Random.State.bits st land 0xff))

let tbl = { Flow_table.ways = 4; rows_log2 = 12; max_evict = 32; stash_depth = 32 }

(* URAM read-modify-write, cascaded 4 deep, is several cycles; each eviction
   step is another. These are estimates, and the sweep below is what matters --
   how the CAM depth responds, not the absolute numbers. *)
let base = { table = tbl; base_latency = 8; cycles_per_evict = 3;
             pending_depth = 16 }

(* Minimum-size frames at 10G line rate: one every 10.5 cycles. *)
let iat = 10

let () =
  print_endline "flow table pipeline (timed)\n";

  (* --- the race, with dedup disabled ------------------------------------ *)
  (* The race needs insert latency > inter-arrival time. At an empty table that
     is not true -- a free-slot insert is 8 cycles against 10 between packets,
     so it retires before the next packet and nothing races. The FIRST version
     of this test used an empty table and reported no race, which is a property
     of the chosen numbers, not of the design.

     Latency is load-dependent and the tail is severe: median 8 cycles at every
     load, but p99 rises 8 -> 29 -> 50 -> 104 cycles across 50/80/85/90% as
     eviction chains lengthen. So the table is PRE-LOADED here. That is also the
     honest operating condition -- a flow table under pressure is when new flows
     are hardest to place and most likely to arrive back-to-back. *)
  let preload t n =
    for i = 0 to n - 1 do
      ignore (Flow_table.insert t.tbl (key (500000 + i)))
    done
  in
  (* The key must be one whose candidate slots are ALL occupied, or its insert
     finds a free slot in 8 cycles, retires before the next packet, and no race
     occurs. Picking an arbitrary key made the test pass vacuously. *)
  let contended_key t =
    let rec find i =
      if i > 400000 then key 42
      else
        let k = key i in
        let full =
          List.for_all
            (fun w ->
               t.tbl.Flow_table.slots.(w).(Flow_table.hash tbl ~way:w k) <> None)
            (List.init tbl.Flow_table.ways (fun w -> w))
        in
        if full && not (Flow_table.lookup t.tbl k) then k else find (i + 1)
    in
    find 300000
  in
  let t = create { base with pending_depth = 0 } in
  preload t (Flow_table.capacity tbl * 85 / 100);
  let k = contended_key t in
  for _ = 1 to 4 do
    ignore (packet t k);
    advance t iat
  done;
  Printf.printf "  burst of 4 packets, one new flow, NO dedup: %d duplicate inserts\n"
    t.duplicates;
  check "race is real without a pending CAM" (t.duplicates > 0);

  (* --- same burst, dedup enabled ---------------------------------------- *)
  let t2 = create base in
  preload t2 (Flow_table.capacity tbl * 85 / 100);
  let t = t2 in
  for _ = 1 to 4 do
    ignore (packet t k);
    advance t iat
  done;
  Printf.printf "  same burst WITH dedup: %d duplicates, %d races caught\n"
    t.duplicates t.dedup_hits;
  check "pending CAM eliminates duplicates" (t.duplicates = 0);
  check "and it caught the repeats" (t.dedup_hits >= 1);

  (* --- how deep must the CAM be? ---------------------------------------- *)
  (* Worst case for pending depth is every packet being a NEW flow, so inserts
     queue as fast as packets arrive. Real traffic is nothing like this -- the
     skewed profile has a few flows dominating -- but the CAM must survive it. *)
  Printf.printf "\n  all-new-flow traffic at 85%% load, one packet every %d cycles:\n" iat;
  Printf.printf "  %10s %12s %10s\n" "packets" "max pending" "overflow";
  List.iter
    (fun n ->
       let t = create { base with pending_depth = 64 } in
       preload t (Flow_table.capacity tbl * 85 / 100);
       for i = 0 to n - 1 do
         ignore (packet t (key (100000 + i)));
         advance t iat
       done;
       drain t;
       Printf.printf "  %10d %12d %10d\n" n t.max_pending t.pending_overflow)
    [ 100; 1000; 10000 ];

  (* --- CAM depth sweep --------------------------------------------------- *)
  Printf.printf "\n  pending CAM depth vs dropped inserts (10000 new flows):\n";
  Printf.printf "  %8s %10s\n" "depth" "overflow";
  List.iter
    (fun d ->
       let t = create { base with pending_depth = d } in
       preload t (Flow_table.capacity tbl * 85 / 100);
       for i = 0 to 9999 do
         ignore (packet t (key (200000 + i)));
         advance t iat
       done;
       drain t;
       Printf.printf "  %8d %10d\n" d t.pending_overflow)
    [ 2; 4; 8; 16 ];

  Printf.printf "\n%s\n"
    (if !failures = 0 then "all checks passed"
     else Printf.sprintf "%d FAILURES" !failures);
  if !failures > 0 then exit 1

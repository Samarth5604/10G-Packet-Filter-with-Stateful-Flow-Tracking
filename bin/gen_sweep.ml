(* gen_sweep.ml -- occupancy sweep for the flow table.
   ---------------------------------------------------------------------------
   Fills a table to a target load factor and reports the eviction chain depth
   distribution. This is the experiment that picks ways, eviction bound and
   stash depth for the RTL; nothing downstream should hardcode a value this
   sweep has not supported.

     gen_sweep [ways] [rows_log2] [max_evict] [stash_depth]
   --------------------------------------------------------------------------- *)

(* 104-bit key, 13 bytes, from a seeded PRNG rather than a function of the
   counter. The first version derived every byte from i by shifting 3 bits per
   byte, so adjacent bytes overlapped and 20,000 keys produced only 11,541
   distinct index tuples -- the table looked broken at 21% load when the fault
   was entirely in the stimulus. A real 5-tuple carries far more entropy than
   that; so should the test keys. *)
let key_of_int i =
  let st = Random.State.make [| i |] in
  Bytes.init 13 (fun _ -> Char.chr (Random.State.bits st land 0xff))

let pct sorted p =
  let n = Array.length sorted in
  if n = 0 then 0
  else sorted.(min (n - 1) (int_of_float (float_of_int n *. p)))

let () =
  let arg n d = if Array.length Sys.argv > n then int_of_string Sys.argv.(n) else d in
  let p =
    { Flow_table.ways = arg 1 4;
      rows_log2 = arg 2 14;              (* 4 ways x 16384 = 65536 slots *)
      max_evict = arg 3 16;
      stash_depth = arg 4 32 }
  in
  Printf.printf
    "ways %d  rows %d  capacity %d  max_evict %d  stash %d  (%d URAM288 @ 128b)\n\n"
    p.Flow_table.ways (Flow_table.rows p) (Flow_table.capacity p)
    p.Flow_table.max_evict p.Flow_table.stash_depth
    (Flow_table.uram_blocks p ~entry_bits:128);

  Printf.printf "%6s %10s %8s %8s %8s %8s %8s\n"
    "load%" "inserted" "maxchain" "p99.9" "p99" "median" "stashed";

  let t = Flow_table.create p in
  let depths = ref [] in
  let target_pct = [ 10; 20; 30; 40; 50; 60; 70; 75; 80; 85; 90; 95 ] in
  let cap = Flow_table.capacity p in
  let i = ref 0 in
  let failed = ref false in

  List.iter
    (fun pc ->
       if not !failed then begin
         let target = cap * pc / 100 in
         while t.Flow_table.n_live < target && not !failed do
           (match Flow_table.insert t (key_of_int !i) with
            | Flow_table.Placed d -> depths := d :: !depths
            | Flow_table.Stashed d -> depths := d :: !depths
            | Flow_table.Already_present -> ()
            | Flow_table.Stash_full ->
              Printf.printf "  STASH FULL at %.1f%% load after %d inserts\n"
                (100. *. Flow_table.occupancy t) !i;
              failed := true);
           incr i
         done;
         let arr = Array.of_list !depths in
         Array.sort compare arr;
         Printf.printf "%6d %10d %8d %8d %8d %8d %8d\n"
           pc t.Flow_table.n_live
           (if Array.length arr = 0 then 0 else arr.(Array.length arr - 1))
           (pct arr 0.999) (pct arr 0.99) (pct arr 0.5)
           (Flow_table.stash_used t)
       end)
    target_pct

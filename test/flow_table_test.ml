(* flow_table_test.ml -- self-test for the cuckoo model.
   ---------------------------------------------------------------------------
   The properties a hash table must have, plus the one that actually broke:
   the ways must be INDEPENDENT. That is checked numerically here because the
   first implementation failed it completely and looked like a load-factor
   problem instead.
   --------------------------------------------------------------------------- *)

open Flow_table

let failures = ref 0
let check name c =
  if c then Printf.printf "  ok    %s\n" name
  else begin incr failures; Printf.printf "  FAIL  %s\n" name end

let key i =
  let st = Random.State.make [| i |] in
  Bytes.init 13 (fun _ -> Char.chr (Random.State.bits st land 0xff))

let p = { ways = 4; rows_log2 = 12; max_evict = 32; stash_depth = 128 }

let () =
  print_endline "flow table model\n";

  (* --- hash independence ------------------------------------------------ *)
  (* Pairs colliding in way 0 must rarely collide in way 1. The CRC-with-
     different-init version scored 39332/39332 here; multiply-shift scores a
     handful against an expectation of n/rows. *)
  let n = 20000 in
  let by0 = Hashtbl.create n in
  for i = 0 to n - 1 do Hashtbl.add by0 (hash p ~way:0 (key i)) (key i) done;
  let pairs = ref 0 and both = ref 0 and all4 = ref 0 in
  Hashtbl.iter
    (fun h _ ->
       let ks = Hashtbl.find_all by0 h in
       if List.length ks > 1 then
         List.iteri
           (fun a ka ->
              List.iteri
                (fun b kb ->
                   if a < b then begin
                     incr pairs;
                     if hash p ~way:1 ka = hash p ~way:1 kb then incr both;
                     if hash p ~way:1 ka = hash p ~way:1 kb
                        && hash p ~way:2 ka = hash p ~way:2 kb
                        && hash p ~way:3 ka = hash p ~way:3 kb
                     then incr all4
                   end)
                ks)
           ks)
    by0;
  let expected = float_of_int !pairs /. float_of_int (rows p) in
  Printf.printf "  way0 collisions: %d; also way1: %d (expect ~%.1f); all 4: %d\n"
    !pairs !both expected !all4;
  (* Generous bound: the point is to catch total dependence, not to assert a
     precise distribution. The broken version was 4 orders of magnitude out. *)
  check "ways are independent" (float_of_int !both < 10. *. (expected +. 1.));
  check "no all-way collisions at this scale" (!all4 = 0);

  (* --- basic table behaviour -------------------------------------------- *)
  let t = create p in
  check "empty table finds nothing" (not (lookup t (key 1)));

  ignore (insert t (key 1));
  check "inserted key is found" (lookup t (key 1));
  check "other key is not found" (not (lookup t (key 2)));
  check "duplicate insert detected" (insert t (key 1) = Already_present);
  check "live count is 1" (t.n_live = 1);

  check "delete removes" (delete t (key 1));
  check "deleted key is gone" (not (lookup t (key 1)));
  check "delete of absent key fails" (not (delete t (key 99)));
  check "live count back to 0" (t.n_live = 0);

  (* --- every inserted key remains findable ------------------------------ *)
  (* This is the property the formal proof will state: an inserted key that was
     not explicitly deleted is retrievable. Eviction MOVES keys, so a bug in the
     chain silently loses them -- and a lost key looks like a new flow, not like
     an error. *)
  let t = create p in
  let target = capacity p * 80 / 100 in
  let inserted = ref [] in
  let i = ref 0 in
  while t.n_live < target do
    (match insert t (key !i) with
     | Placed _ | Stashed _ -> inserted := !i :: !inserted
     | Already_present | Stash_full -> ());
    incr i
  done;
  let lost = List.filter (fun j -> not (lookup t (key j))) !inserted in
  Printf.printf "  filled to %.0f%% with %d keys; %d lost\n"
    (100. *. occupancy t) (List.length !inserted) (List.length lost);
  check "no key lost through eviction at 80% load" (lost = []);

  (* --- eviction chain stays bounded ------------------------------------- *)
  let t = create p in
  let worst = ref 0 in
  let i = ref 0 in
  while t.n_live < capacity p * 70 / 100 do
    (match insert t (key (100000 + !i)) with
     | Placed d | Stashed d -> if d > !worst then worst := d
     | _ -> ());
    incr i
  done;
  Printf.printf "  worst chain at 70%% load: %d (bound %d)\n" !worst p.max_evict;
  check "chain never exceeds the bound" (!worst <= p.max_evict + 1);

  Printf.printf "\n%s\n"
    (if !failures = 0 then "all checks passed"
     else Printf.sprintf "%d FAILURES" !failures);
  if !failures > 0 then exit 1

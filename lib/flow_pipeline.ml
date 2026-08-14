(* flow_pipeline.ml -- the flow table WITH TIME.
   ---------------------------------------------------------------------------
   Flow_table is a functional reference: insert and lookup are atomic, and the
   table is always consistent between calls. Real hardware is not like that. An
   insert takes cycles -- a URAM read-modify-write, plus up to max_evict of them
   if the chain runs -- and packets keep arriving throughout.

   That gap hides a race the functional model CANNOT express:

     cycle 0   packet 1 of a new flow arrives, misses, requests an insert
     cycle 10  packet 2 of the SAME flow arrives. The insert has not landed.
               It misses too, and requests a second insert for the same key.
     cycle 20  packet 3. Same again.
     cycle 40  three inserts complete: three copies of one key, or a corrupted
               eviction chain if they interleave.

   The fix is a pending-insert CAM checked in parallel with the table, so a
   lookup hits a key that is requested but not yet placed. This module exists to
   size that CAM and to be the reference the RTL is checked against.

   Everything here is in CYCLES at 156.25 MHz. Minimum-size frames arrive every
   10.5 cycles at 10G line rate (14.88 Mpps), which is the interval that makes
   the race tight.
   --------------------------------------------------------------------------- *)

type params = {
  table         : Flow_table.params;
  base_latency  : int;  (* cycles for an insert that finds a free slot *)
  cycles_per_evict : int;  (* additional cycles per eviction step *)
  pending_depth : int;  (* pending-insert CAM entries; 0 disables dedup *)
}

type t = {
  p       : params;
  tbl     : Flow_table.t;
  (* key, cycle at which the insert completes *)
  mutable pending : (Bytes.t * int) list;
  mutable cycle   : int;
  (* instrumentation *)
  mutable max_pending      : int;
  mutable dedup_hits       : int;   (* races caught *)
  mutable pending_overflow : int;   (* CAM too small: insert dropped *)
  mutable duplicates       : int;   (* races NOT caught: would corrupt *)
}

let create p =
  { p; tbl = Flow_table.create p.table; pending = []; cycle = 0;
    max_pending = 0; dedup_hits = 0; pending_overflow = 0; duplicates = 0 }

let in_pending t key =
  List.exists (fun (k, _) -> Bytes.equal k key) t.pending

(* Retire completed inserts. Called before every lookup, as the hardware would
   on every cycle. *)
let retire t =
  let due, still = List.partition (fun (_, c) -> c <= t.cycle) t.pending in
  t.pending <- still;
  List.iter (fun (k, _) -> ignore (Flow_table.insert t.tbl k)) due

(* Insert latency depends on how far the eviction chain would run. That is not
   known until the chain runs, and a real design discovers it as it goes; here
   the depth is estimated from how many of the key's candidate slots are already
   occupied, which is the same information the hardware has at request time.

   An earlier version probed by calling Flow_table.insert and then deleting the
   key. That PLACES the key, so the next packet of the same flow found it in the
   table and the race under test could never occur -- the measurement destroyed
   the thing it measured. The table must not be mutated here. *)
let latency_for t key =
  let occupied =
    List.length
      (List.filter
         (fun w ->
            t.tbl.Flow_table.slots.(w).(Flow_table.hash t.p.table ~way:w key)
            <> None)
         (List.init t.p.table.Flow_table.ways (fun w -> w)))
  in
  (* All candidate slots full means a chain runs; the deeper the table, the
     longer it tends to be. One free slot means no eviction at all. *)
  let est_depth =
    if occupied < t.p.table.Flow_table.ways then 0
    else t.p.table.Flow_table.max_evict / 2
  in
  t.p.base_latency + (est_depth * t.p.cycles_per_evict)

(* One packet arrives. Returns true if the key was already known (a hit, in the
   table or pending), false if this packet started a new flow. *)
let packet t key =
  retire t;
  let in_table = Flow_table.lookup t.tbl key in
  let pending_hit = in_pending t key in

  if in_table then true
  else if pending_hit then begin
    (* THE RACE, CAUGHT. Without the pending CAM this is a miss and a second
       insert request for a key already in flight. *)
    if t.p.pending_depth > 0 then (t.dedup_hits <- t.dedup_hits + 1; true)
    else begin
      (* dedup disabled: the duplicate insert is issued, which is the bug *)
      t.duplicates <- t.duplicates + 1;
      let lat = latency_for t key in
      t.pending <- (key, t.cycle + lat) :: t.pending;
      false
    end
  end else begin
    (* genuine miss: request an insert *)
    if List.length t.pending >= t.p.pending_depth && t.p.pending_depth > 0 then
      t.pending_overflow <- t.pending_overflow + 1
    else begin
      let lat = latency_for t key in
      t.pending <- (key, t.cycle + lat) :: t.pending;
      let n = List.length t.pending in
      if n > t.max_pending then t.max_pending <- n
    end;
    false
  end

let advance t n = t.cycle <- t.cycle + n

let drain t =
  let rec go () =
    if t.pending <> [] then begin
      t.cycle <- t.cycle + 1;
      retire t;
      go ()
    end
  in
  go ()

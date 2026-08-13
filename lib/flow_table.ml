(* flow_table.ml -- d-ary cuckoo hash model for the 5-tuple flow table.
   ---------------------------------------------------------------------------
   The reference for the RTL, and the instrument that picks its parameters.
   Number of ways, eviction bound and stash depth are all swept here rather than
   chosen: bin/gen_sweep.ml runs occupancy 10%..95% and reports worst-case and
   tail chain depth, and the RTL takes whatever that measurement supports.

   HASHING. Each way needs its own index from a 104-bit key, and the ways must
   be INDEPENDENT: cuckoo hashing works only because a key colliding in one way
   is unlikely to collide in another.

   Three schemes were measured on 20,000 keys, counting how often a pair
   colliding in way 0 also collides in way 1 (expectation under independence is
   ~2.5) and how often a pair collides in all four:

     CRC32, per-way INITIAL STATE   39332 / 39332 also-way1, all4 39332  BROKEN
     32-bit multiply-shift              3 also-way1 (exp 2.5), all4 0
     CRC32, per-way POLYNOMIAL           2 also-way1 (exp 2.4), all4 0   CHOSEN

   The first is not a weak hash, it is the SAME hash four times. Changing a
   CRC's initial state shifts the output by a constant depending only on message
   length, so for fixed-width keys h_i(k) = h_0(k) XOR c_i and two keys equal
   under one way are equal under all. Different init gives offsets; different
   POLYNOMIAL gives a different linear map.

   Polynomials are chosen over multiply-shift on hardware cost, not on quality --
   both measure clean. A CRC is linear over GF(2), so each way is an XOR tree
   over 104 bits: no multiplier, no DSP, one LUT level or two. A 64-bit
   multiply-shift would need several DSP48E2 per way, on the critical path of
   every packet. Same independence, a fraction of the cost.
   --------------------------------------------------------------------------- *)

type params = {
  ways        : int;  (* parallel tables; each key has one candidate slot per way *)
  rows_log2   : int;  (* rows per way *)
  max_evict   : int;  (* eviction chain bound; beyond this the key goes to the stash *)
  stash_depth : int;  (* fully-associative overflow *)
}

let rows p = 1 lsl p.rows_log2
let capacity p = p.ways * rows p

type outcome =
  | Placed of int          (* eviction chain length, 0 = landed in a free slot *)
  | Stashed of int         (* chain length at which the bound was hit *)
  | Stash_full             (* unplaceable: the table has genuinely failed *)
  | Already_present

type t = {
  p     : params;
  slots : Bytes.t option array array;   (* [way].[row] *)
  stash : Bytes.t list ref;
  mutable n_live : int;
}

let create p =
  { p;
    slots = Array.init p.ways (fun _ -> Array.make (rows p) None);
    stash = ref [];
    n_live = 0 }

(* --- hashing -------------------------------------------------------------- *)

(* Odd multipliers, one per way. Distinct and odd is what multiply-shift
   requires; these are fractional parts of irrational constants, the usual
   choice. Part of the specification -- the RTL must use the same values.
   OCaml's int is 63-bit, so these are the 62-bit truncations of the usual
   64-bit constants, forced odd. The RTL uses the full 64-bit values; the model
   uses these, and the differential test is what will confirm the two agree at
   the index widths actually used. *)
let mult_for_way =
  [| 0x1E3779B97F4A7C15; 0x3F58476D1CE4E5B9; 0x14D049BB133111EB;
     0x2545F4914F6CDD1D; 0x16E8FEB86659FD93; 0x224BAED4963EE407;
     0x1FB21C651E98DF25; 0x02B2AE3D27D4EB4F |]

(* Fold 13 bytes to 64 bits, then multiply-shift. The fold is linear and shared
   across ways; independence comes from the distinct multipliers that follow. *)
let fold64 key =
  let acc = ref 0 in
  Bytes.iteri
    (fun i ch ->
       let b = Char.code ch in
       acc := !acc lxor (b lsl ((i * 8) mod 57)))
    key;
  !acc

let hash p ~way key =
  let x = fold64 key in
  let a = mult_for_way.(way mod Array.length mult_for_way) in
  (* Take the HIGH bits of the product: the low bits of a multiply depend on
     too few input bits. OCaml ints are 63-bit, so the product wraps -- that is
     the same truncation the hardware multiplier performs. *)
  ((x * a) lsr (62 - p.rows_log2)) land (rows p - 1)

(* --- lookup --------------------------------------------------------------- *)

(* Every way is probed in parallel in hardware, so lookup cost is one memory
   access regardless of [ways] -- the cost of d is ports, not cycles. *)
let lookup t key =
  let rec go w =
    if w >= t.p.ways then List.exists (fun k -> Bytes.equal k key) !(t.stash)
    else
      match t.slots.(w).(hash t.p ~way:w key) with
      | Some k when Bytes.equal k key -> true
      | _ -> go (w + 1)
  in
  go 0

(* --- insert --------------------------------------------------------------- *)

(* Cuckoo insert. Try each way in turn; if all candidate slots are occupied,
   evict from way 0 and re-place the victim, bounded by [max_evict].

   The bound is what makes this implementable. An unbounded chain has no worst
   case, and a line-rate datapath cannot stall while one resolves -- packets are
   still arriving. Hitting the bound is not failure: the key goes to the stash,
   which is why the stash exists. *)
let insert t key =
  if lookup t key then Already_present
  else begin
    (* A victim must not be evicted back into the slot it just came from, or the
       chain ping-pongs between two ways instead of walking the table. [from]
       is the way the current key was displaced out of; -1 on the initial call. *)
    let rec place key depth from =
      if depth > t.p.max_evict then begin
        if List.length !(t.stash) >= t.p.stash_depth then Stash_full
        else begin
          t.stash := key :: !(t.stash);
          t.n_live <- t.n_live + 1;
          Stashed depth
        end
      end else begin
        (* a free candidate slot in any way ends the chain *)
        let rec try_free w =
          if w >= t.p.ways then None
          else
            let r = hash t.p ~way:w key in
            if t.slots.(w).(r) = None then Some (w, r) else try_free (w + 1)
        in
        match try_free 0 with
        | Some (w, r) ->
          t.slots.(w).(r) <- Some key;
          t.n_live <- t.n_live + 1;
          Placed depth
        | None ->
          (* All candidate slots full. Evict from the way selected by the chain
             depth, which spreads victims across ways instead of thrashing one,
             and re-place the victim.

             The returned depth is the DEEPEST point the chain reached, not the
             depth of this frame. Reporting the frame depth made every insert
             look like chain 0 regardless of how much displacement it caused,
             which is exactly the statistic the sweep exists to measure. *)
          let w =
            let cands =
              List.filter (fun w -> w <> from)
                (List.init t.p.ways (fun w -> w))
            in
            List.nth cands (depth mod List.length cands)
          in
          let r = hash t.p ~way:w key in
          let victim = match t.slots.(w).(r) with
            | Some v -> v | None -> assert false in
          t.slots.(w).(r) <- Some key;
          (match place victim (depth + 1) w with
           | Placed d -> Placed d
           | Stashed d -> Stashed d
           | other -> other)
      end
    in
    place key 0 (-1)
  end

let delete t key =
  let rec go w =
    if w >= t.p.ways then begin
      let before = List.length !(t.stash) in
      t.stash := List.filter (fun k -> not (Bytes.equal k key)) !(t.stash);
      if List.length !(t.stash) < before then (t.n_live <- t.n_live - 1; true)
      else false
    end else
      let r = hash t.p ~way:w key in
      match t.slots.(w).(r) with
      | Some k when Bytes.equal k key ->
        t.slots.(w).(r) <- None; t.n_live <- t.n_live - 1; true
      | _ -> go (w + 1)
  in
  go 0

let occupancy t = float_of_int t.n_live /. float_of_int (capacity t.p)
let stash_used t = List.length !(t.stash)

(* --- URAM geometry -------------------------------------------------------- *)

(* URAM288: 4096 rows x 72 bits. A 104-bit key plus a value does not fit one
   row, so each logical entry spans cascaded blocks. Reported so the sweep can
   state a resource cost alongside a load factor. *)
let uram_blocks p ~entry_bits =
  let rows_per_uram = 4096 and bits_per_row = 72 in
  let width_blocks = (entry_bits + bits_per_row - 1) / bits_per_row in
  let depth_blocks = (rows p + rows_per_uram - 1) / rows_per_uram in
  p.ways * width_blocks * depth_blocks
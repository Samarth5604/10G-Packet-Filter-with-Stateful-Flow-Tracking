(* gen_cam.ml -- fully-associative CAM, parameterised by depth.
   ---------------------------------------------------------------------------
   Two instances of this block appear in the flow table, both on the per-packet
   path and both sized by measurement in docs/adr/0008:

     stash            32 entries -- keys that hit the eviction bound
     pending-insert    8..16     -- keys requested but not yet placed

   Every entry compares against the search key in parallel, so depth costs LUTs
   and comparison delay directly. That is why ADR 0008 spends eviction depth
   rather than stash depth: chain depth is cycles on the insert path (once per
   new flow), CAM depth is logic on every lookup.

   Latency should be flat across a range of depths -- the match reduction is
   an OR tree of ceil(log6(depth)) LUT6 levels, so 7..36 entries all cost two
   levels -- but that is a prediction, and syn/ is where it gets checked.

     gen_cam [depth] [width]      defaults 32 104
   --------------------------------------------------------------------------- *)

open Hardcaml
open Signal

let or_all = function
  | [] -> gnd
  | x :: tl -> List.fold_left ( |: ) x tl

let bits_for n =
  let rec go b v = if v <= 0 then b else go (b + 1) (v / 2) in
  max 1 (go 0 (n - 1))

let create ~depth ~width () =
  let clock = input "clock" 1 in
  let clear = input "clear" 1 in
  let spec = Reg_spec.create ~clock ~clear () in

  let search_key = input "search_key" width in
  let wr_en = input "wr_en" 1 in
  let wr_idx = input "wr_idx" (bits_for depth) in
  let wr_key = input "wr_key" width in
  let wr_valid = input "wr_valid" 1 in          (* 0 invalidates the entry *)

  let iw = bits_for depth in

  (* Entries are registers, not memory: every one is read every cycle, so there
     is nothing for a RAM to amortise. This is what makes a CAM expensive. *)
  let entries =
    List.init depth (fun i ->
        let sel = wr_en &: (wr_idx ==: of_int ~width:iw i) in
        let key = reg spec ~enable:sel wr_key in
        let valid = reg spec ~enable:sel wr_valid in
        (key, valid))
  in

  (* All comparisons in parallel. This is the block's whole cost and its whole
     point. *)
  let matches =
    List.map (fun (key, valid) -> valid &: (key ==: search_key)) entries
  in

  let found = or_all matches in

  (* Priority encode to an index. Entries are unique by construction -- the
     caller must not write the same key twice -- so priority only matters for
     determinism, not correctness. *)
  let idx =
    List.fold_left
      (fun acc (i, m) -> mux2 m (of_int ~width:iw i) acc)
      (zero iw)
      (List.rev (List.mapi (fun i m -> (i, m)) matches))
  in

  (* A free-slot index for the allocator, plus a full flag. Without these the
     caller has to track occupancy separately and the two can disagree. *)
  let frees = List.map (fun (_, v) -> ~:v) entries in
  let free_idx =
    List.fold_left
      (fun acc (i, f) -> mux2 f (of_int ~width:iw i) acc)
      (zero iw)
      (List.rev (List.mapi (fun i f -> (i, f)) frees))
  in
  let full = ~:(or_all frees) in

  Circuit.create_exn
    ~name:(Printf.sprintf "cam_d%d_w%d" depth width)
    [ output "match_found" (reg spec found);
      output "match_idx" (reg spec idx);
      output "free_idx" (reg spec free_idx);
      output "full" (reg spec full) ]

let () =
  let arg n d = if Array.length Sys.argv > n then int_of_string Sys.argv.(n) else d in
  let depth = arg 1 32 and width = arg 2 104 in
  prerr_endline
    (Printf.sprintf "cam_d%d_w%d: %d entries x %d bits, %d-bit index"
       depth width depth width (bits_for depth));
  Rtl.print Verilog (create ~depth ~width ())

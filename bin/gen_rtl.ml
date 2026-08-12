(* gen_rtl.ml -- fourth backend: RTL.
   ---------------------------------------------------------------------------
   Emits the header parser from Protocol_spec.stack. Nothing here names a
   protocol: offsets, selector values, guard conditions and the key layout are
   all read out of the spec.

   STRUCTURE. The generator first asks whether every layer's byte offset is
   statically determined. For the shipped spec it is -- ihl is constrained to
   {5}, so IPv4 spans exactly 20 bytes, and every other span is Fixed. That
   yields 12 reachable (layer, offset) pairs and a one-hot path decoder with
   fixed-position field extraction. No barrel shifter is required.

   Relaxing ihl to Range(5,15) would make spans data-dependent and demand a
   shifter -- but Protocol_spec.validate rejects that first, because the parse
   window derives to 86 bytes against a 48-byte budget. The cheap structure is
   available precisely because the spec is constrained enough to earn it.
   [span_of] raises rather than silently emitting something wrong if that ever
   stops holding.

   Latency: the decode is combinational over a full parse window, and the
   result is then REGISTERED, so it lands one cycle after the 6th beat. The
   6-beat bound is the one derived in Protocol_spec and confirmed independently
   by the golden model.

   The output register is not optional. Without it the decode sits between the
   buffer registers and the module ports, so register-to-register timing covers
   only the shift register and the beat counter -- trivial paths that report
   enormous slack and say nothing about the decode. Registering the outputs
   puts the decode inside a real timing path, and gives the flow table a clean
   pipeline boundary to launch its lookup from.
   --------------------------------------------------------------------------- *)

open Hardcaml
open Signal
open Protocol_spec

let st = stack
let window_bytes = st.parse_window_bytes
let wbits = window_bytes * 8
let beats = cut_through_beats ~datapath_bits:64 st
let key_width = export_bits st

let bits_for n =
  let rec go b v = if v <= 0 then b else go (b + 1) (v / 2) in
  max 1 (go 0 n)

(* --- helpers ------------------------------------------------------------- *)

let eqi x v = x ==: of_int ~width:(width x) v

let in_set x vs =
  match vs with
  | Any | Derived -> vdd
  | One_of [] -> vdd
  | One_of xs -> List.fold_left (fun a v -> a |: eqi x v) gnd xs
  | Range (lo, hi) ->
    x >=: of_int ~width:(width x) lo &: (x <=: of_int ~width:(width x) hi)

let all_of = function [] -> vdd | xs -> List.fold_left ( &: ) vdd xs
let any_of = function [] -> gnd | xs -> List.fold_left ( |: ) gnd xs

(* Byte offset of the next layer. Static, or the design assumption is void. *)
let span_of l =
  match l.length with
  | Fixed n -> n
  | From_field { lf_field; scale } ->
    (match (field_or_fail l lf_field).values with
     | One_of [ x ] -> scale * x
     | _ ->
       failwith
         (l.lname
          ^ ": span is data-dependent. A one-hot decoder with fixed offsets is \
             no longer valid here; this layer needs a barrel shifter."))

(* Field extraction. buf holds beat 0 in the most significant bits, so absolute
   bit index [a] (network order, MSB first) maps to select index wbits-1-a. *)
let fld buf ~off_bits ~w = select buf (wbits - 1 - off_bits) (wbits - off_bits - w)

(* --- path decoder -------------------------------------------------------- *)

type acc = {
  mutable terminals  : (Signal.t * Signal.t) list;   (* cond, key *)
  mutable e_selector : Signal.t list;
  mutable e_guard    : Signal.t list;
  mutable e_field    : Signal.t list;
  mutable e_repeat   : Signal.t list;
}

let build buf =
  let a =
    { terminals = []; e_selector = []; e_guard = []; e_field = []; e_repeat = [] }
  in
  (* Everything a layer contributes before its successor is chosen: bounds check,
     accepted-value checks on constrained fields inside the read depth, and the
     exports appended to the key. Shared by terminal and branch nodes. *)
  let prologue (n : Protocol_spec.node) cond keyparts =
    let l = n.n_layer and off = n.n_offset in
    let need = layer_read_bytes l in
    if off + need > window_bytes then
      failwith
        (Printf.sprintf "%s at %d needs %d B, past the %d B window"
           l.lname off need window_bytes);
    let rd fn =
      fld buf ~off_bits:((off * 8) + field_offset l fn) ~w:(field_or_fail l fn).width
    in
    (* Constrained fields inside the read depth are checked. Fields beyond it are
       not read, so they cannot be checked without widening the window. Same rule
       as the golden model. *)
    let checks =
      List.filter_map
        (fun f ->
           if field_end l f.fname <= need * 8
              && f.values <> Any && f.values <> Derived
           then Some (in_set (rd f.fname) f.values)
           else None)
        l.fields
    in
    let fields_ok = all_of checks in
    if checks <> [] then a.e_field <- (cond &: ~:fields_ok) :: a.e_field;
    let cond = cond &: fields_ok in
    let keyparts = keyparts @ List.map (fun e -> rd e) l.exports in
    (rd, cond, keyparts)
  in
  (* Recursion over the SHARED tree from Protocol_spec. The layer-graph logic --
     repeat bounds, offsets, and grouping selector values by target layer -- is
     not repeated here; only the mapping from that structure onto conditions. *)
  let rec go (t : Protocol_spec.tree) cond keyparts =
    match t with
    | Stop _ -> a.e_repeat <- cond :: a.e_repeat
    | Leaf n ->
      let _, cond, keyparts = prologue n cond keyparts in
      a.terminals <- (cond, concat_msb keyparts) :: a.terminals
    | Branch (n, edges) ->
      let rd, cond, keyparts = prologue n cond keyparts in
      (* Assert the span is static. The tree's offsets are worst case; fixed
         offset extraction is only valid when worst case equals actual. *)
      ignore (span_of n.n_layer);
      (match n.n_layer.next with
       | Payload -> ()
       | Switch { sw_field; require; _ } ->
         let gok =
           all_of (List.map (fun g -> in_set (rd g.g_field) g.g_values) require)
         in
         if require <> [] then a.e_guard <- (cond &: ~:gok) :: a.e_guard;
         let cond = cond &: gok in
         let sel = rd sw_field in
         let taken =
           List.filter_map
             (fun (e : Protocol_spec.edge) ->
                if e.e_default then None
                else Some (e, any_of (List.map (fun v -> eqi sel v) e.e_values)))
             edges
         in
         let matched = any_of (List.map snd taken) in
         List.iter (fun (e, hit) -> go e.Protocol_spec.e_tree (cond &: hit) keyparts) taken;
         (match List.find_opt (fun (e : Protocol_spec.edge) -> e.e_default) edges with
          | Some d -> go d.e_tree (cond &: ~:matched) keyparts
          | None -> a.e_selector <- (cond &: ~:matched) :: a.e_selector))
  in
  (match reachable st with
   | None -> failwith "entry layer not found"
   | Some t -> go t vdd []);
  a

(* --- circuit ------------------------------------------------------------- *)

let create () =
  let clock = input "clock" 1 in
  let clear = input "clear" 1 in
  let in_valid = input "in_valid" 1 in
  let in_data = input "in_data" 64 in
  let in_last = input "in_last" 1 in
  let spec = Reg_spec.create ~clock ~clear () in
  let cw = bits_for (beats + 1) in

  (* tdata[7:0] is the first byte on the wire; reverse so byte 0 is the MSB of
     the beat, matching the network bit order the offsets assume. *)
  let swapped = concat_msb (List.init 8 (fun i -> select in_data ((8 * i) + 7) (8 * i))) in

  (* Beat counter, saturating at the window size. *)
  let beat_ct =
    reg_fb spec ~enable:in_valid ~width:cw ~f:(fun c ->
        mux2 (c ==: of_int ~width:cw beats) c (c +: of_int ~width:cw 1))
  in
  let full = beat_ct ==: of_int ~width:cw beats in

  (* Shift register: each beat enters at the LSB, so after [beats] beats the
     first beat has reached the MSB and every extraction offset is correct.
     THE SHIFT MUST STOP THERE. A frame is longer than the window -- 96 bytes is
     12 beats against a 6-beat window -- and continuing to shift walks byte 0
     out of the buffer, leaving the extraction logic reading payload as headers.
     Freezing on [full] also stops the buffer toggling on every payload beat.

     The alternative, having the caller drive only the first [beats] beats,
     leaks the parse window into the interface: the cut-through control would
     have to know a parser-internal parameter and replicate the truncation. The
     block's contract is "give me a frame, get a classification".

     Found by the differential regression, which failed 91 of 100 packets on its
     first run -- every VLAN and QinQ frame. Invisible to the golden model,
     which reads a byte array and has no notion of beats. *)
  let buf =
    reg_fb spec ~enable:(in_valid &: ~:full) ~width:wbits ~f:(fun b ->
        select (b @: swapped) (wbits - 1) 0)
  in

  (* A frame is SHORT when tlast arrives before the window has been filled.
     [beat_ct] counts beats already accepted, so the beat carrying tlast is
     number beat_ct+1, and the frame is short when beat_ct + 1 < beats.

     This must be COMBINATIONAL, not just registered. The decode below is
     combinational on [buf] in the same cycle, and it runs on a half-filled
     buffer whose extraction offsets point at whatever happens to be there --
     typically producing a spurious unmatched-selector. A registered flag
     arrives a cycle too late to mask that, and since the outputs are registered
     too, the wrong error is what gets captured.

     Found by the differential regression: 3023 of 100000 smoke packets, 7506 of
     50000 adversarial, every one a frame under 27 bytes where the verdict
     agreed and only the reason differed. The sticky register is kept so the
     condition holds through to the sample point; the combinational term is what
     makes the masking correct on the deciding cycle. *)
  let short_now =
    in_valid &: in_last &: (beat_ct <: of_int ~width:cw (beats - 1))
  in
  let truncated_r = reg_fb spec ~width:1 ~f:(fun q -> q |: short_now) in
  let truncated = truncated_r |: short_now in

  let a = build buf in
  let parsed = any_of (List.map fst a.terminals) &: ~:truncated in
  let key =
    List.fold_left
      (fun acc (c, k) -> acc |: mux2 c k (zero key_width))
      (zero key_width) a.terminals
  in

  (* Conditions are mutually exclusive by construction: each is gated on the
     checks that precede it. The priority order is defensive, and matches the
     golden model's order of decision. *)
  let e_trunc = truncated in
  let e_rep = any_of a.e_repeat &: ~:truncated in
  let e_fld = any_of a.e_field &: ~:truncated in
  let e_grd = any_of a.e_guard &: ~:truncated in
  let e_sel = any_of a.e_selector &: ~:truncated in
  let err =
    mux2 e_trunc (of_int ~width:3 1)
      (mux2 e_rep (of_int ~width:3 5)
         (mux2 e_fld (of_int ~width:3 4)
            (mux2 e_grd (of_int ~width:3 3)
               (mux2 e_sel (of_int ~width:3 2) (of_int ~width:3 0)))))
  in
  (* Registered outputs: see the note at the top of this file. Costs one cycle
     -- the decision lands at beat 7 of a frame whose minimum length is 8 beats
     (60 bytes on the DUT interface, per docs/interface-contract.md). That is
     one beat of margin, and it is worth tracking as the cut-through control
     is built. *)
  Circuit.create_exn ~name:"header_parser"
    [ output "hdr_valid" (reg spec (full |: truncated));
      output "hdr_parsed" (reg spec parsed);
      output "hdr_err" (reg spec err);
      output "hdr_key" (reg spec key) ]

let () =
  validate st;
  (* Terminal paths come from the shared traversal, not from a second call to
     [build]. Building the circuit twice allocated Hardcaml signal UIDs before
     [create] ran, so every wire name in the emitted Verilog shifted whenever
     this line changed -- producing large, meaningless diffs in committed RTL
     and in the CI diff gate. *)
  prerr_endline
    (Printf.sprintf
       "header_parser: %d B window, %d beats, %d-bit key, %d terminal paths"
       window_bytes beats key_width
       (List.length (all_paths st)));
  Rtl.print Verilog (create ())
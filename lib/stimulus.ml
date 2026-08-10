(* stimulus.ml -- third backend: constrained stimulus.
   ---------------------------------------------------------------------------
   Runs the spec BACKWARDS. The parser reads a frame and follows selectors; this
   picks a path first, then solves for the field values that make a parser take
   it. That inversion is only possible because selectors, guards and lengths are
   first-order data (ADR 0002) -- a closure could be applied but not solved.

   Nothing here names a protocol. Selector values come from [Switch.cases],
   guard values from [guard.g_values], header spans from [length]. Adding a
   layer to the spec extends the generator with no edit.

   Every generated packet carries its INTENT. The round-trip property is that
   the golden model, parsing the frame forwards, reproduces that intent --
   which checks generator and model against each other in opposite directions.
   --------------------------------------------------------------------------- *)

open Protocol_spec

(* --- profile ------------------------------------------------------------- *)

type path_weighting =
  | Uniform_paths
  (* Weight proportional to depth^k. Uniform under-samples the deepest path
     (QinQ), which is the one that exercises the widest parse window. *)
  | Depth_weighted of float

type key_distribution =
  (* Uniform over the full export space. Fills a hash table evenly; the right
     choice for the occupancy sweep, the wrong one for realism. *)
  | Uniform_keys
  (* n distinct flows, reused. Stresses the lookup-hit path and, at small n,
     the pending-insert dedup race on first packets. *)
  | Small_pool of int
  (* Sequential dense keys. Deterministic fill for occupancy characterisation. *)
  | Dense_fill of int
  (* Zipf-like skew: a few flows dominate, as in real traffic. [s] > 0; larger
     is more skewed. *)
  | Skewed of { flows : int; s : float }

(* Defect categories, not concrete malformations. The actual bad value is
   derived from the spec: an unmatched selector is any value outside
   [Switch.cases]; a guard violation is any value outside [g_values]. *)
type defect =
  | Selector_unmatched
  | Guard_violated
  | Field_out_of_set
  | Frame_truncated
  | Repeats_exceeded

type profile = {
  pname         : string;
  paths         : path_weighting;
  keys          : key_distribution;
  (* Fraction of packets carrying an injected defect, and the relative mix
     among categories. Remainder of the stream is well-formed. *)
  negative_frac : float;
  negative_mix  : (defect * float) list;
  payload_range : int * int;
  seed          : int;
}

(* --- intent -------------------------------------------------------------- *)

type intent =
  | Expect_parsed of { path : string list; key_hex : string }
  | Expect_unparseable of defect

type packet = {
  bytes   : Bytes.t;
  intent  : intent;
  tags    : string list;          (* coverage tags for this packet *)
}

let string_of_defect = function
  | Selector_unmatched -> "selector_unmatched"
  | Guard_violated -> "guard_violated"
  | Field_out_of_set -> "field_out_of_set"
  | Frame_truncated -> "frame_truncated"
  | Repeats_exceeded -> "repeats_exceeded"

(* --- path enumeration ---------------------------------------------------- *)

(* All complete paths from entry to a Payload layer, respecting max_repeats.
   For the shipped spec this is six: {eth, eth+vlan, eth+qinq} x {udp, tcp}. *)
let all_paths st =
  (* Distinct LAYER SEQUENCES. Several selector values may reach the same layer
     (0x8100 and 0x88A8 both reach vlan); those are one path here, and the
     specific case is chosen at emission so both values still get exercised. *)
  let rec go name counts acc =
    match find_layer st name with
    | None -> []
    | Some l ->
      let used = try List.assoc name counts with Not_found -> 0 in
      if used >= l.max_repeats then []
      else
        let counts = (name, used + 1) :: List.remove_assoc name counts in
        let acc = name :: acc in
        (match l.next with
         | Payload -> [ List.rev acc ]
         | Switch { cases; _ } ->
           List.concat_map (fun (_, nxt) -> go nxt counts acc) cases)
  in
  List.sort_uniq compare (go st.entry [] [])

(* --- randomness ---------------------------------------------------------- *)

(* Random.State.int rejects bounds >= 2^30, so a 48-bit MAC cannot be drawn
   with it. Random.State.bits yields exactly 30 bits; assemble wider fields
   from those. *)
let rand_bits rs w =
  let rec go acc left =
    if left <= 0 then acc
    else
      let take = min 30 left in
      go ((acc lsl take) lor (Random.State.bits rs land ((1 lsl take) - 1)))
        (left - take)
  in
  go 0 w

let pick_in rs f =
  match f.values with
  | Any | Derived -> rand_bits rs f.width
  | Range (lo, hi) -> lo + Random.State.int rs (hi - lo + 1)
  | One_of xs -> List.nth xs (Random.State.int rs (List.length xs))

(* A value the field does NOT accept. Returns None when the set is exhaustive,
   which is the honest answer for an unconstrained field. *)
let pick_outside rs f =
  match f.values with
  | Any | Derived -> None
  | _ ->
    let rec try_n n =
      if n = 0 then None
      else
        let v = rand_bits rs f.width in
        let ok = match f.values with
          | Range (lo, hi) -> v < lo || v > hi
          | One_of xs -> not (List.mem v xs)
          | _ -> false
        in
        if ok then Some v else try_n (n - 1)
    in
    try_n 64

(* As pick_outside, but never below [floor]. A length field must still admit
   its own header: picking ihl = 3 would be clamped back up to 5 and the
   injected defect would vanish. *)
let pick_outside_min rs f floor =
  match f.values with
  | Any | Derived -> None
  | _ ->
    let rec try_n n =
      if n = 0 then None
      else
        let v = rand_bits rs f.width in
        let ok =
          v >= floor
          && (match f.values with
              | Range (lo, hi) -> v < lo || v > hi
              | One_of xs -> not (List.mem v xs)
              | _ -> false)
        in
        if ok then Some v else try_n (n - 1)
    in
    try_n 128

let pick_selector_outside rs l sw_field cases =
  let f = field_or_fail l sw_field in
  let rec try_n n =
    if n = 0 then None
    else
      let v = rand_bits rs f.width in
      if List.mem_assoc v cases then try_n (n - 1) else Some v
  in
  try_n 64

let weighted rs items =
  let total = List.fold_left (fun a (_, w) -> a +. w) 0.0 items in
  if total <= 0.0 then fst (List.hd items)
  else begin
    let r = Random.State.float rs total in
    let rec go acc = function
      | [] -> fst (List.hd items)
      | (x, w) :: tl -> if r <= acc +. w then x else go (acc +. w) tl
    in
    go 0.0 items
  end

(* --- key sourcing -------------------------------------------------------- *)

(* Export fields draw from the key distribution. A field that is BOTH an export
   and a selector (ipv4.protocol) takes its selector value: the path was chosen
   first and must be honoured. *)
let key_value rs dist ~width ~idx =
  let cap v = v land ((1 lsl width) - 1) in
  match dist with
  | Uniform_keys -> rand_bits rs width
  | Small_pool n -> cap (Random.State.int rs (max 1 n) * 2654435761)
  | Dense_fill n -> cap ((idx mod max 1 n) + 1)
  | Skewed { flows; s } ->
    let u = Random.State.float rs 1.0 in
    let rank = int_of_float (float_of_int (max 1 flows) ** (u ** s)) in
    cap (rank * 2654435761)

(* --- emission ------------------------------------------------------------ *)

let put_bits buf off width v =
  for i = 0 to width - 1 do
    let bitpos = off + i in
    let byte = bitpos lsr 3 and sh = 7 - (bitpos land 7) in
    let cur = Char.code (Bytes.get buf byte) in
    let b = (v lsr (width - 1 - i)) land 1 in
    Bytes.set buf byte (Char.chr ((cur land lnot (1 lsl sh)) lor (b lsl sh)))
  done

let min_dut_frame = 60 (* 64-byte minimum Ethernet frame less the 4 FCS bytes,
                          which the BFM adds; see docs/interface-contract.md *)

let gen_one st prof rs idx =
  let paths = all_paths st in
  let path =
    match prof.paths with
    | Uniform_paths -> List.nth paths (Random.State.int rs (List.length paths))
    | Depth_weighted k ->
      weighted rs
        (List.map (fun p -> (p, float_of_int (List.length p) ** k)) paths)
  in
  let defect =
    if Random.State.float rs 1.0 < prof.negative_frac
       && prof.negative_mix <> []
    then Some (weighted rs prof.negative_mix)
    else None
  in
  (* Repeats_exceeded needs a path containing a repeatable layer. Re-draw from
     the eligible subset rather than emitting a well-formed frame labelled
     unparseable -- a false intent is worse than a missed defect, because the
     round-trip would then report a model bug that is not one. *)
  let has_repeatable p =
    List.exists
      (fun n -> match find_layer st n with
         | Some l -> l.max_repeats > 1 | None -> false)
      p
  in
  let path =
    if defect = Some Repeats_exceeded && not (has_repeatable path) then
      match List.filter has_repeatable paths with
      | [] -> path
      | eligible -> List.nth eligible (Random.State.int rs (List.length eligible))
    else path
  in
  (* Extend the repeatable layer to exactly max_repeats + 1 occurrences.
     Doubling is not enough: a path with one VLAN doubles to two, which is
     exactly the bound and still legal. The target is derived from the spec,
     not assumed. *)
  let path =
    match defect with
    | Some Repeats_exceeded ->
      let rep =
        List.find_opt
          (fun n -> match find_layer st n with
             | Some l -> l.max_repeats > 1 | None -> false)
          path
      in
      (match rep with
       | None -> path
       | Some r ->
         let l = match find_layer st r with
           | Some l -> l | None -> raise (Spec_error r) in
         let present = List.length (List.filter (fun n -> n = r) path) in
         let needed = max 0 (l.max_repeats + 1 - present) in
         let extra = List.init needed (fun _ -> r) in
         let rec insert = function
           | [] -> []
           | x :: tl when x = r -> extra @ (x :: tl)
           | x :: tl -> x :: insert tl
         in
         insert path)
    | _ -> path
  in
  let buf = Buffer.create 128 in
  let tags = ref [] in
  let key_parts = ref [] in
  let injected = ref false in

  let rec emit = function
    | [] -> ()
    | lname :: rest ->
      let l = match find_layer st lname with
        | Some l -> l | None -> raise (Spec_error lname) in
      let next_layer = match rest with [] -> None | n :: _ -> Some n in
      (* header span: from the length rule, using a value the field accepts *)
      let len_field =
        match l.length with
        | Fixed _ -> None
        | From_field { lf_field; scale } -> Some (lf_field, scale)
      in
      let hdr_bits = List.fold_left (fun a f -> a + f.width) 0 l.fields in
      let span =
        match l.length with
        | Fixed n -> n
        | From_field { lf_field; scale } ->
          let f = field_or_fail l lf_field in
          let floor = ((hdr_bits + 7) / 8 + scale - 1) / scale in
          let v =
            if defect = Some Field_out_of_set && not !injected then
              match pick_outside_min rs f floor with
              | Some bad ->
                injected := true;
                tags := "field_out_of_set" :: !tags;
                bad
              | None -> pick_in rs f
            else pick_in rs f
          in
          scale * v
      in
      let span = max span ((hdr_bits + 7) / 8) in
      let hdr = Bytes.make span '\000' in
      let chosen = ref [] in
      List.iter
        (fun f ->
           let off = field_offset l f.fname in
           let v =
             (* precedence: selector, then guard, then length, then key, then
                free choice within the accepted set *)
             match l.next with
             | Switch { sw_field; cases; _ } when sw_field = f.fname ->
               (match next_layer with
                | Some nxt when defect <> Some Selector_unmatched || !injected ->
                  (* Several cases may reach the same layer (0x8100 / 0x88A8).
                     Choose among them so both values are exercised. *)
                  (match List.filter (fun (_, n) -> n = nxt) cases with
                   | [] -> pick_in rs f
                   | opts ->
                     fst (List.nth opts (Random.State.int rs (List.length opts))))
                | _ ->
                  (match pick_selector_outside rs l sw_field cases with
                   | Some bad ->
                     injected := true;
                     tags := "selector_unmatched" :: !tags; bad
                   | None -> pick_in rs f))
             | Switch { require; _ }
               when List.exists (fun g -> g.g_field = f.fname) require ->
               let g = List.find (fun g -> g.g_field = f.fname) require in
               if defect = Some Guard_violated && not !injected then begin
                 match pick_outside rs { f with values = g.g_values } with
                 | Some bad ->
                   injected := true;
                   tags := ("guard_violated:" ^ g.g_reason) :: !tags; bad
                 | None -> pick_in rs { f with values = g.g_values }
               end else pick_in rs { f with values = g.g_values }
             | _ ->
               (match len_field with
                | Some (lf, scale) when lf = f.fname -> span / scale
                | _ ->
                  if List.mem f.fname l.exports then
                    key_value rs prof.keys ~width:f.width ~idx
                  else pick_in rs f)
           in
           if off + f.width <= span * 8 then put_bits hdr off f.width v;
           chosen := (f.fname, v) :: !chosen)
        l.fields;
      (* Exports are appended in l.exports order, matching the golden model.
         Field declaration order differs -- ipv4.protocol precedes src_ip in
         the header but follows it in the key. *)
      List.iter
        (fun e ->
           let f = field_or_fail l e in
           key_parts :=
             (l.lname ^ "." ^ e, f.width, List.assoc e !chosen) :: !key_parts)
        l.exports;
      Buffer.add_bytes buf hdr;
      tags := lname :: !tags;
      emit rest
  in
  emit path;

  let lo, hi = prof.payload_range in
  let pay = lo + Random.State.int rs (max 1 (hi - lo + 1)) in
  for _ = 1 to pay do Buffer.add_char buf '\x5A' done;
  let body = Buffer.to_bytes buf in
  let body =
    if Bytes.length body >= min_dut_frame then body
    else begin
      let padded = Bytes.make min_dut_frame '\000' in
      Bytes.blit body 0 padded 0 (Bytes.length body);
      padded
    end
  in
  let body =
    if defect = Some Frame_truncated then begin
      injected := true;
      tags := "frame_truncated" :: !tags;
      let cut = 8 + Random.State.int rs 20 in
      Bytes.sub body 0 (min cut (Bytes.length body))
    end else body
  in
  let intent =
    match defect with
    | Some Repeats_exceeded -> Expect_unparseable Repeats_exceeded
    | Some d when !injected -> Expect_unparseable d
    | _ ->
      Expect_parsed
        { path; key_hex = Golden_model.key_hex (List.rev !key_parts) }
  in
  { bytes = body; intent; tags = List.rev !tags }

let generate st prof n =
  let rs = Random.State.make [| prof.seed |] in
  List.init n (fun i -> gen_one st prof rs i)

(* --- shipped profiles ---------------------------------------------------- *)

let no_negatives = { pname = ""; paths = Uniform_paths; keys = Uniform_keys;
                     negative_frac = 0.0; negative_mix = [];
                     payload_range = (0, 64); seed = 0 }

let standard_mix =
  [ Selector_unmatched, 0.3; Guard_violated, 0.25; Field_out_of_set, 0.2;
    Frame_truncated, 0.15; Repeats_exceeded, 0.1 ]

(* Broad coverage: every path, every defect category, moderate flow count. *)
let smoke =
  { no_negatives with pname = "smoke"; paths = Depth_weighted 2.0;
    keys = Small_pool 256; negative_frac = 0.2;
    negative_mix = standard_mix; seed = 1 }

(* Occupancy sweep: dense deterministic keys, no defects, shallow paths so the
   table sees maximum packets per unit time. *)
let occupancy n =
  { no_negatives with pname = "occupancy"; paths = Uniform_paths;
    keys = Dense_fill n; negative_frac = 0.0; payload_range = (0, 0); seed = 2 }

(* Realistic skew: a few flows dominate, as in production traffic. *)
let skewed =
  { no_negatives with pname = "skewed"; paths = Depth_weighted 1.0;
    keys = Skewed { flows = 65536; s = 2.0 }; negative_frac = 0.05;
    negative_mix = standard_mix; seed = 3 }

(* Error paths only. Every packet carries a defect. *)
let adversarial =
  { no_negatives with pname = "adversarial"; paths = Depth_weighted 3.0;
    keys = Small_pool 16; negative_frac = 1.0;
    negative_mix = standard_mix; seed = 4 }

(* golden_model.ml -- second backend: the reference parser.
   ---------------------------------------------------------------------------
   An INTERPRETER over [Protocol_spec.stack], not a hand-written IPv4 parser.
   Nothing here names a protocol. Editing the spec changes this model and the
   generated RTL together; hand-writing it would let the two drift and leave the
   differential test confirming a shared misunderstanding.

   Bit order is network order throughout: bit 0 of a layer is the most
   significant bit of its first byte.
   --------------------------------------------------------------------------- *)

open Protocol_spec

type reason =
  (* The frame did not fill the parse window, so no field offset is meaningful.
     This DOMINATES every other verdict, matching the RTL: the parser shifts
     beats into a buffer and beat 0 only reaches its final position after the
     window is full, so with fewer beats every extraction points at the wrong
     bytes. A short frame with an unmatched EtherType has no EtherType to be
     unmatched about. See docs/adr/0002-first-order-spec.md. *)
  | Frame_too_short of { got_beats : int; need_beats : int }
  | Truncated of string             (* layer name: frame ended mid-header *)
  | Unmatched_selector of string * int
  | Guard_failed of string          (* g_reason *)
  | Bad_field_value of string * int (* "layer.field", observed value *)
  | Repeat_limit of string
  | Unknown_layer of string

type status =
  | Parsed
  | Unparseable of reason

type result = {
  status      : status;
  path        : (string * int) list;          (* layer name, byte offset *)
  fields      : (string * int) list;          (* "layer.field" -> value *)
  key_parts   : (string * int * int) list;    (* name, width, value *)
  key_hex     : string;                       (* canonical, for RTL diff *)
  decided_at  : int;                          (* bytes consumed before the
                                                 classification was final;
                                                 compare against RTL latency *)
}

(* --- bit access ---------------------------------------------------------- *)

let bit frame i =
  let b = Char.code (Bytes.get frame (i lsr 3)) in
  (b lsr (7 - (i land 7))) land 1

let bits frame off width =
  let v = ref 0 in
  for i = 0 to width - 1 do
    v := (!v lsl 1) lor bit frame (off + i)
  done;
  !v

(* --- value-set membership ------------------------------------------------ *)

(* [Any] and [Derived] accept anything: [Derived] marks a field the stimulus
   generator back-patches, which says nothing about what the parser accepts. *)
let accepts vs v =
  match vs with
  | Any | Derived -> true
  | Range (lo, hi) -> v >= lo && v <= hi
  | One_of xs -> List.mem v xs

(* --- key rendering ------------------------------------------------------- *)

let key_hex parts =
  let bs =
    List.concat_map
      (fun (_, w, v) -> List.init w (fun i -> (v lsr (w - 1 - i)) land 1))
      parts
  in
  let n = List.length bs in
  if n = 0 then ""
  else begin
    let pad = (4 - (n mod 4)) mod 4 in
    let bs = List.init pad (fun _ -> 0) @ bs in
    let buf = Buffer.create ((n + pad) / 4) in
    let rec go = function
      | a :: b :: c :: d :: tl ->
        Buffer.add_char buf
          "0123456789abcdef".[(a lsl 3) lor (b lsl 2) lor (c lsl 1) lor d];
        go tl
      | _ -> ()
    in
    go bs;
    Buffer.contents buf
  end

(* --- the interpreter ----------------------------------------------------- *)

(* [datapath_bits] is a hardware parameter, not a protocol one, but truncation
   semantics depend on it: the window is filled a beat at a time. Defaulting to
   64 keeps existing callers working. *)
let parse ?(datapath_bits = 64) st frame =
  let nbits = 8 * Bytes.length frame in
  let bytes_per_beat = datapath_bits / 8 in
  let got_beats = ceil_div (Bytes.length frame) bytes_per_beat in
  let need_beats = cut_through_beats ~datapath_bits st in
  let stop reason path fields key at =
    (* key_hex is deliberately empty on failure. Exports from layers parsed
       before the failure are retained in key_parts for debugging, but a
       PARTIAL key must never reach the differential comparison: a guard
       failing at IPv4 leaves 72 bits of a 104-bit key, which would compare
       as a well-formed value against whatever the RTL happened to hold. *)
    { status = Unparseable reason; path = List.rev path;
      fields = List.rev fields; key_parts = List.rev key;
      key_hex = ""; decided_at = at }
  in
  let rec go name off counts path fields key =
    match find_layer st name with
    | None -> stop (Unknown_layer name) path fields key off
    | Some l ->
      let used = try List.assoc name counts with Not_found -> 0 in
      if used >= l.max_repeats then stop (Repeat_limit name) path fields key off
      else begin
        let counts = (name, used + 1) :: List.remove_assoc name counts in
        let path = (name, off) :: path in
        let need = layer_read_bytes l in
        if (off + need) * 8 > nbits then
          stop (Truncated name) path fields key off
        else begin
          let base = off * 8 in
          let rd fname = bits frame (base + field_offset l fname) (field_or_fail l fname).width in
          let after = off + need in

          (* Every constrained field lying inside the read depth is validated.
             Fields beyond it are not read at all, so they cannot be checked
             without extending the parse window. *)
          let bad =
            List.find_opt
              (fun f ->
                 field_end l f.fname <= need * 8
                 && not (accepts f.values (rd f.fname)))
              l.fields
          in
          match bad with
          | Some f ->
            stop (Bad_field_value (l.lname ^ "." ^ f.fname, rd f.fname))
              path fields key after
          | None ->
            let fields =
              List.fold_left
                (fun acc f ->
                   if field_end l f.fname <= need * 8
                   then (l.lname ^ "." ^ f.fname, rd f.fname) :: acc
                   else acc)
                fields l.fields
            in
            let key =
              List.fold_left
                (fun acc e ->
                   (l.lname ^ "." ^ e, (field_or_fail l e).width, rd e) :: acc)
                key l.exports
            in
            (match l.next with
             | Payload ->
               { status = Parsed; path = List.rev path;
                 fields = List.rev fields; key_parts = List.rev key;
                 key_hex = key_hex (List.rev key); decided_at = after }
             | Switch { sw_field; cases; default; require } ->
               let failed =
                 List.find_opt (fun g -> not (accepts g.g_values (rd g.g_field)))
                   require
               in
               (match failed with
                | Some g -> stop (Guard_failed g.g_reason) path fields key after
                | None ->
                  let sel = rd sw_field in
                  (match List.assoc_opt sel cases, default with
                   | Some nxt, _ | None, Some nxt ->
                     let span =
                       match l.length with
                       | Fixed n -> n
                       | From_field { lf_field; scale } -> scale * rd lf_field
                     in
                     go nxt (off + span) counts path fields key
                   | None, None ->
                     stop (Unmatched_selector (l.lname ^ "." ^ sw_field, sel))
                       path fields key after)))
        end
      end
  in
  if got_beats < need_beats then
    stop (Frame_too_short { got_beats; need_beats }) [] [] [] (Bytes.length frame)
  else go st.entry 0 [] [] [] []

(* --- reporting ----------------------------------------------------------- *)

let string_of_reason = function
  | Frame_too_short { got_beats; need_beats } ->
    Printf.sprintf "frame too short: %d of %d beats" got_beats need_beats
  | Truncated l -> Printf.sprintf "truncated in %s" l
  | Unmatched_selector (f, v) -> Printf.sprintf "unmatched %s = 0x%X" f v
  | Guard_failed r -> Printf.sprintf "guard %s" r
  | Bad_field_value (f, v) -> Printf.sprintf "bad %s = %d" f v
  | Repeat_limit l -> Printf.sprintf "repeat limit on %s" l
  | Unknown_layer l -> Printf.sprintf "unknown layer %s" l

let string_of_status = function
  | Parsed -> "parsed"
  | Unparseable r -> "unparseable: " ^ string_of_reason r

let to_string r =
  Printf.sprintf "%s | path %s | key %s | decided at %d B"
    (string_of_status r.status)
    (String.concat "/" (List.map fst r.path))
    (if r.key_hex = "" then "-" else r.key_hex)
    r.decided_at

(* --- projection onto the RTL error code ---------------------------------- *)

(* The model distinguishes six reasons carrying layer, field and value; the RTL
   encodes three bits. Comparison in the differential regression happens at THIS
   granularity, and the mapping is defined here rather than in the testbench so
   both sides read it from one place. Changing an encoding means changing this
   table and bin/gen_rtl.ml together.

   0 none | 1 short/truncated | 2 unmatched selector | 3 guard | 4 bad field
   5 repeat limit *)
let err_code = function
  | Parsed -> 0
  | Unparseable (Frame_too_short _) -> 1
  | Unparseable (Truncated _) -> 1
  | Unparseable (Unmatched_selector _) -> 2
  | Unparseable (Guard_failed _) -> 3
  | Unparseable (Bad_field_value _) -> 4
  | Unparseable (Repeat_limit _) -> 5
  | Unparseable (Unknown_layer _) -> 2

let err_name = function
  | 0 -> "none" | 1 -> "short_or_truncated" | 2 -> "unmatched_selector"
  | 3 -> "guard_failed" | 4 -> "bad_field_value" | 5 -> "repeat_limit"
  | n -> Printf.sprintf "unknown(%d)" n
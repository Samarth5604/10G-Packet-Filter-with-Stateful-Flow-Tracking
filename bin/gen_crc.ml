(* gen_crc.ml -- parallel CRC32 RTL from the matrices in Crc_spec.
   ---------------------------------------------------------------------------
   Emits one XOR tree per output bit per width. The eight widths exist because
   tkeep admits 1..8 valid bytes on a final beat, and each byte count is a
   different linear map. Deriving them is why this is generated: eight
   hand-written 32x(32+n) XOR matrices is where the bugs would be, and the
   derivation is already checked against a serial reference and a published
   vector in test/crc_test.ml.

   Interface is a pure update: crc_in -> crc_out for one beat. Initialisation to
   0xFFFFFFFF and the final XOR are the caller's job, so the same block serves
   both the transmit path (compute FCS after header rewrite) and the receive
   path (accumulate and compare against the residue).

   Combinational, with a registered output. Worst-case XOR fan-in is 52 terms
   at 64 bits, which maps to three LUT6 levels -- comfortable at 156.25 MHz,
   but confirm rather than assume: syn/crc32_par.xdc constrains it and
   make synth reports it.
   --------------------------------------------------------------------------- *)

open Hardcaml
open Signal

let width = Crc_spec.width

(* XOR reduction. Hardcaml lowers this to a balanced tree; the ordering here
   does not constrain the netlist. *)
let xor_all = function
  | [] -> gnd
  | x :: tl -> List.fold_left ( ^: ) x tl

(* One output bit of the n-byte update: XOR of the crc bits and data bits the
   matrix says contribute. *)
let out_bit mx ~crc ~data k =
  let crc_terms, data_terms = Crc_spec.terms mx k in
  xor_all
    (List.map (fun i -> bit crc i) crc_terms
     @ List.map (fun j -> bit data j) data_terms)

(* The full 32-bit update for a given number of valid bytes. *)
let update_for_bytes nbytes ~crc ~data =
  let mx = Crc_spec.matrix_for_bytes nbytes in
  concat_msb (List.init width (fun k -> out_bit mx ~crc ~data (width - 1 - k)))

(* tkeep is contiguous from the least significant byte (interface contract), so
   the byte count is a population count and the eight cases are selected by it.
   Reading it as a count rather than a mask is what makes the eight matrices
   indexable; a non-contiguous tkeep is illegal and not handled. *)
let bytes_from_keep keep =
  let sum =
    List.fold_left
      (fun acc i -> acc +: uresize (bit keep i) 4)
      (of_int ~width:4 0)
      (List.init 8 (fun i -> i))
  in
  sum

(* Characterisation wrapper.
   ---------------------------------------------------------------------------
   crc32_par has no register-to-register paths: every path runs port -> XOR
   tree -> output register. Synthesised standalone, the reported slack is
   dominated by the arbitrary input/output delay budget and by clock insertion
   delay on the capture flop against an ideal external launch flop -- which is
   also why hold fails there, and why the router cannot fix it (port nets have
   no HD.PARTPIN_LOCS, so no detour is available).

   Registering the inputs makes the measured path register -> XOR tree -> mux
   -> register, which is the actual logic depth and is what the block will see
   once instantiated next to the parser. Used for `make synth` only; the design
   itself instantiates the unregistered crc32_par. *)
let create ?(ooc = false) () =
  let clock = input "clock" 1 in
  let clear = input "clear" 1 in
  let en = input "en" 1 in
  let crc_in = input "crc_in" width in
  let data = input "data" 64 in
  let keep = input "keep" 8 in
  let spec = Reg_spec.create ~clock ~clear () in

  (* In the characterisation build, every input passes through a register first
     so the combinational logic sits between two real flops. *)
  let reg_if x = if ooc then reg spec x else x in
  let crc_in = reg_if crc_in in
  let data = reg_if data in
  let keep = reg_if keep in
  let en = reg_if en in

  let nbytes = bytes_from_keep keep in

  (* All eight updates are computed and then selected. They share no logic, so
     this is eight XOR trees in parallel -- the cost of a single-cycle update
     that does not care how many bytes arrived. A sequential alternative would
     be smaller and slower, and slower is not available at line rate. *)
  let candidates = List.init 8 (fun i -> update_for_bytes (i + 1) ~crc:crc_in ~data) in
  let selected = mux (nbytes -: of_int ~width:4 1) candidates in

  (* Hold when not enabled: a beat with no valid bytes must not disturb the
     running CRC. *)
  let crc_out = reg spec ~enable:en selected in

  Circuit.create_exn ~name:(if ooc then "crc32_par_ooc" else "crc32_par")
    [ output "crc_out" crc_out ]

let () =
  let ooc = Array.exists (fun a -> a = "--ooc") Sys.argv in
  let mx8 = Crc_spec.matrix_for_bytes 8 in
  prerr_endline
    (Printf.sprintf
       "%s: %d-bit state, 8 widths (8..64 bits), worst XOR fan-in %d"
       (if ooc then "crc32_par_ooc (registered inputs, for characterisation)"
        else "crc32_par")
       width (Crc_spec.max_terms mx8));
  Rtl.print Verilog (create ~ooc ())
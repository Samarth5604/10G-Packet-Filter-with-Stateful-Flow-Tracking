(* crc_spec.ml -- parallel CRC32 derived from the bit-serial definition.
   ---------------------------------------------------------------------------
   Ethernet FCS is CRC-32/ISO-HDLC: polynomial 0x04C11DB7, reflected, init
   0xFFFFFFFF, final XOR 0xFFFFFFFF. Reflected form uses 0xEDB88320 and shifts
   right, consuming data LSB-first -- which matches the wire, where the least
   significant bit of each byte is transmitted first.

   The serial update is LINEAR over GF(2): no constant term appears, so
   advancing n bits is a linear map

       crc' = M_n . crc  XOR  D_n . data

   and both matrices are obtained by running the serial algorithm on basis
   vectors. That is the whole derivation. Nothing here is hand-computed, which
   matters because tkeep requires EIGHT matrices (1..8 valid bytes) and hand
   deriving eight XOR trees is where the bugs would live.

   This module is pure OCaml with no Hardcaml dependency so it can be tested
   directly against a reference implementation; bin/gen_crc.ml turns the
   matrices into RTL.
   --------------------------------------------------------------------------- *)

let poly_reflected = 0xEDB88320
let width = 32

(* One bit of the serial LFSR. *)
let step crc bit =
  let x = (crc lxor bit) land 1 in
  let crc = crc lsr 1 in
  if x = 1 then crc lxor poly_reflected else crc

(* --- basis-vector probing ------------------------------------------------ *)

(* Column i of M_n: start from crc = e_i with all-zero data, advance n bits. *)
let state_column i n =
  let c = ref (1 lsl i) in
  for _ = 1 to n do c := step !c 0 done;
  !c

(* Column j of D_n: start from crc = 0 with a single 1 at data bit j. Indexing
   by bit position rather than by a data word avoids needing a 64-bit integer,
   which OCaml's 63-bit native int cannot hold. *)
let data_column j n =
  let c = ref 0 in
  for i = 0 to n - 1 do
    c := step !c (if i = j then 1 else 0)
  done;
  !c

type matrix = { n_bits : int; m : int array; d : int array }

let derive n_bits =
  { n_bits;
    m = Array.init width (fun i -> state_column i n_bits);
    d = Array.init n_bits (fun j -> data_column j n_bits) }

(* Apply a derived matrix. [get_data_bit] returns bit j of the input word. *)
let apply mx crc ~get_data_bit =
  let acc = ref 0 in
  for i = 0 to width - 1 do
    if (crc lsr i) land 1 = 1 then acc := !acc lxor mx.m.(i)
  done;
  for j = 0 to mx.n_bits - 1 do
    if get_data_bit j = 1 then acc := !acc lxor mx.d.(j)
  done;
  !acc

(* --- reference ------------------------------------------------------------ *)

(* Byte-at-a-time serial reference. Deliberately written the obvious way: it is
   what the matrices are checked against, so it must not share their logic. *)
let ref_update crc byte =
  let c = ref (crc lxor byte) in
  for _ = 1 to 8 do
    c := if !c land 1 = 1 then (!c lsr 1) lxor poly_reflected else !c lsr 1
  done;
  !c

let ref_crc bytes =
  let c = ref 0xFFFFFFFF in
  Bytes.iter (fun ch -> c := ref_update !c (Char.code ch)) bytes;
  !c lxor 0xFFFFFFFF

(* --- the eight matrices the datapath needs -------------------------------- *)

(* One per possible tkeep population on a final beat: 1..8 valid bytes. Index 0
   is unused so that [by_bytes.(k)] is the matrix for k bytes. *)
let by_bytes = Array.init 9 (fun k -> if k = 0 then derive 8 else derive (8 * k))

let matrix_for_bytes k =
  if k < 1 || k > 8 then invalid_arg "matrix_for_bytes: 1..8";
  by_bytes.(k)

(* Convenience: fold a byte sequence using the k-byte matrix at each step. *)
let crc_via_matrix ?(chunk = 8) bytes =
  let n = Bytes.length bytes in
  let c = ref 0xFFFFFFFF in
  let off = ref 0 in
  while !off < n do
    let k = min chunk (n - !off) in
    let base = !off in
    let mx = matrix_for_bytes k in
    c := apply mx !c ~get_data_bit:(fun j ->
        let byte = Char.code (Bytes.get bytes (base + (j / 8))) in
        (byte lsr (j mod 8)) land 1);
    off := !off + k
  done;
  !c lxor 0xFFFFFFFF

(* --- RTL-facing description ---------------------------------------------- *)

(* For output bit k of the n-bit-wide update: which crc bits and which data bits
   XOR together. This is exactly what the Hardcaml backend emits as an XOR tree,
   and what makes the generated logic inspectable. *)
let terms mx k =
  let crc_terms = ref [] and data_terms = ref [] in
  for i = width - 1 downto 0 do
    if (mx.m.(i) lsr k) land 1 = 1 then crc_terms := i :: !crc_terms
  done;
  for j = mx.n_bits - 1 downto 0 do
    if (mx.d.(j) lsr k) land 1 = 1 then data_terms := j :: !data_terms
  done;
  (!crc_terms, !data_terms)

let max_terms mx =
  let worst = ref 0 in
  for k = 0 to width - 1 do
    let c, d = terms mx k in
    worst := max !worst (List.length c + List.length d)
  done;
  !worst

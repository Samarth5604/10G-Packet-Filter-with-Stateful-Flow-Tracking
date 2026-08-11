(* crc_test.ml -- the derived matrices must reproduce the serial reference.
   ---------------------------------------------------------------------------
   Two independent checks. First a published test vector, so a systematic error
   in BOTH implementations cannot pass. Then matrix-vs-reference over random
   data at every chunk width, which is what catches an error in one matrix out
   of eight -- exactly the failure hand-derivation would produce.
   --------------------------------------------------------------------------- *)

open Crc_spec

let failures = ref 0
let check name c =
  if c then Printf.printf "  ok    %s\n" name
  else begin incr failures; Printf.printf "  FAIL  %s\n" name end

let () =
  print_endline "parallel CRC32 derivation\n";

  (* Published vector for CRC-32/ISO-HDLC, cross-checked against zlib.crc32
     rather than recalled: the first version of this test asserted 0xCBF43F26,
     two digits transposed, and failed a correct implementation. A wrong
     reference constant is worse than none -- it accuses working code. *)
  let check9 = Bytes.of_string "123456789" in
  Printf.printf "reference CRC32(\"123456789\") = 0x%08X (expect 0xCBF43926)\n"
    (ref_crc check9);
  check "reference matches published vector" (ref_crc check9 = 0xCBF43926);

  for chunk = 1 to 8 do
    check (Printf.sprintf "matrix chunk=%dB matches vector" chunk)
      (crc_via_matrix ~chunk check9 = 0xCBF43926)
  done;

  (* Random data, every length, every chunk width. *)
  let rs = Random.State.make [| 7 |] in
  let bad = ref 0 in
  for _ = 1 to 2000 do
    let n = 1 + Random.State.int rs 200 in
    let b = Bytes.init n (fun _ -> Char.chr (Random.State.int rs 256)) in
    let want = ref_crc b in
    for chunk = 1 to 8 do
      if crc_via_matrix ~chunk b <> want then incr bad
    done
  done;
  check "2000 random buffers x 8 chunk widths" (!bad = 0);

  (* Partial-beat path specifically: lengths that are NOT multiples of 8 force
     a final beat of 1..7 bytes, which is the tkeep case. *)
  let partial_bad = ref 0 in
  for n = 1 to 64 do
    let b = Bytes.init n (fun i -> Char.chr ((i * 37) land 0xff)) in
    if crc_via_matrix ~chunk:8 b <> ref_crc b then incr partial_bad
  done;
  check "partial final beat, lengths 1..64" (!partial_bad = 0);

  (* Residue: appending the FCS makes the running CRC a fixed constant, which is
     how a receiver validates a frame. 0xDEBB20E3 is the value before the final
     XOR; 0x2144DF1C is its complement, quoted under the other convention. *)
  let frame = Bytes.of_string "the quick brown fox" in
  let fcs = ref_crc frame in
  let with_fcs = Bytes.cat frame
      (Bytes.init 4 (fun i -> Char.chr ((fcs lsr (8 * i)) land 0xff))) in
  let residue = ref 0xFFFFFFFF in
  Bytes.iter (fun ch -> residue := ref_update !residue (Char.code ch)) with_fcs;
  Printf.printf "\nresidue with FCS appended = 0x%08X (expect 0xDEBB20E3)\n" !residue;
  check "magic residue" (!residue = 0xDEBB20E3);

  (* XOR-tree depth per width: what the RTL will actually cost. *)
  print_endline "\nworst-case XOR terms for one output bit:";
  for k = 1 to 8 do
    Printf.printf "  %d byte%s (%2d bits) : %d terms\n"
      k (if k = 1 then " " else "s") (8 * k) (max_terms (matrix_for_bytes k))
  done;

  Printf.printf "\n%s\n"
    (if !failures = 0 then "all checks passed"
     else Printf.sprintf "%d FAILURES" !failures);
  if !failures > 0 then exit 1

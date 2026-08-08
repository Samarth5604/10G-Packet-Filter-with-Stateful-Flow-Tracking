(* Validates the spec and prints every derived bound. Fails the build if the
   asserted parse window is exceeded. Runs in CI; needs no FPGA toolchain. *)
open Protocol_spec

let () =
  validate stack;
  Printf.printf "parse window   : %d / %d bytes\n"
    (max_parse_bytes stack) stack.parse_window_bytes;
  Printf.printf "cut-through    : %d beats @ 64-bit\n"
    (cut_through_beats ~datapath_bits:64 stack);
  Printf.printf "flow key       : %d bits\n" (export_bits stack);
  Printf.printf "unparseable    : %s\n"
    (match stack.on_unparseable with
     | Drop -> "drop"
     | Forward_unclassified -> "forward unclassified")

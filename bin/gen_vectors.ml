(* gen_vectors.ml -- stimulus and expected results for the cocotb regression.
   ---------------------------------------------------------------------------
   Writes one line per packet: the frame bytes, and what the golden model says
   the DUT must produce. The testbench drives the bytes and compares; it does
   not know the protocol, and it does not reimplement the model.

   The alternative -- regenerating stimulus in Python -- would mean a second
   implementation of the generator, which is the drift this project exists to
   avoid. One generator, one model, one file between them.

   Format, tab separated:

     <hex frame> <parsed 0|1> <err_code> <key hex or ->

   err_code is Golden_model.err_code, the projection defined alongside the model
   so both sides read the mapping from one place.

     gen_vectors [profile] [count] [seed]
       profile : smoke | adversarial | skewed | occupancy   (default smoke)
       count   : packets                                    (default 10000)
       seed    : overrides the profile's seed               (default profile)
   --------------------------------------------------------------------------- *)

let () =
  let arg n d = if Array.length Sys.argv > n then Sys.argv.(n) else d in
  let pname = arg 1 "smoke" in
  let count = int_of_string (arg 2 "10000") in
  let base =
    match pname with
    | "smoke" -> Stimulus.smoke
    | "adversarial" -> Stimulus.adversarial
    | "skewed" -> Stimulus.skewed
    | "occupancy" -> Stimulus.occupancy 4096
    | s -> prerr_endline ("unknown profile: " ^ s); exit 1
  in
  let prof =
    if Array.length Sys.argv > 3
    then { base with Stimulus.seed = int_of_string Sys.argv.(3) }
    else base
  in
  let pkts = Stimulus.generate Protocol_spec.stack prof count in

  (* Expected values come from the MODEL, not from the generator's declared
     intent. The two already agree -- that is the round-trip property in
     test/stimulus_test.ml -- but the model is the reference the RTL is being
     compared against, so it is the model that must be quoted here. *)
  List.iter
    (fun (p : Stimulus.packet) ->
       let r = Golden_model.parse Protocol_spec.stack p.bytes in
       let hex = Bytes.fold_left (fun a c -> a ^ Printf.sprintf "%02x" (Char.code c)) "" p.bytes in
       Printf.printf "%s\t%d\t%d\t%s\n" hex
         (if r.status = Golden_model.Parsed then 1 else 0)
         (Golden_model.err_code r.status)
         (if r.key_hex = "" then "-" else r.key_hex))
    pkts;

  let n_parsed =
    List.length
      (List.filter
         (fun (p : Stimulus.packet) ->
            (Golden_model.parse Protocol_spec.stack p.bytes).status
            = Golden_model.Parsed)
         pkts)
  in
  Printf.eprintf "%s: %d packets, %d parsed, %d unparseable (seed %d)\n"
    prof.Stimulus.pname count n_parsed (count - n_parsed) prof.Stimulus.seed

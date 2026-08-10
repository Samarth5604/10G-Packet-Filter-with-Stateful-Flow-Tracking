(* stimulus_test.ml -- round-trip property.
   ---------------------------------------------------------------------------
   The generator solves the spec backwards; the model reads it forwards. For
   every generated packet the model's verdict must equal the generator's
   declared intent. The two derive from one description by opposite routes, so
   a disagreement is a bug in one of them and neither can hide it.

   This is the property that pays for ADR 0002. With closures in the spec the
   generator could not exist, and there would be nothing to round-trip against.
   --------------------------------------------------------------------------- *)

open Protocol_spec
open Stimulus

let failures = ref 0
let check name c =
  if c then Printf.printf "  ok    %s\n" name
  else begin incr failures; Printf.printf "  FAIL  %s\n" name end

(* Does the model's verdict match the intended defect category? *)
let matches_defect d (r : Golden_model.result) =
  match d, r.status with
  | Selector_unmatched, Unparseable (Unmatched_selector _) -> true
  | Guard_violated, Unparseable (Guard_failed _) -> true
  | Field_out_of_set, Unparseable (Bad_field_value _) -> true
  | Frame_truncated, Unparseable (Truncated _) -> true
  | Repeats_exceeded, Unparseable (Repeat_limit _) -> true
  (* A truncation short enough to cut the ethertype presents as truncation at
     the first layer; a deep truncation can also mask a later defect. Accept
     any unparseable verdict for the truncation category only. *)
  | Frame_truncated, Unparseable _ -> true
  | _ -> false

let round_trip prof n =
  Printf.printf "\nprofile %s (%d packets)\n" prof.pname n;
  let pkts = generate stack prof n in
  let parsed = ref 0 and neg = ref 0 and mismatched = ref [] in
  List.iteri
    (fun i p ->
       let r = Golden_model.parse stack p.bytes in
       match p.intent with
       | Expect_parsed { path; key_hex } ->
         incr parsed;
         let got_path = List.map fst r.path in
         if r.status <> Golden_model.Parsed then
           mismatched := (i, "expected parse, got " ^ Golden_model.string_of_status r.status) :: !mismatched
         else if got_path <> path then
           mismatched := (i, "path " ^ String.concat "/" got_path
                             ^ " <> " ^ String.concat "/" path) :: !mismatched
         else if r.key_hex <> key_hex then
           mismatched := (i, "key " ^ r.key_hex ^ " <> " ^ key_hex) :: !mismatched
       | Expect_unparseable d ->
         incr neg;
         if not (matches_defect d r) then
           mismatched :=
             (i, string_of_defect d ^ " -> " ^ Golden_model.string_of_status r.status)
             :: !mismatched)
    pkts;
  Printf.printf "  %d positive, %d negative\n" !parsed !neg;
  List.iteri
    (fun i (idx, m) -> if i < 5 then Printf.printf "  pkt %d: %s\n" idx m)
    (List.rev !mismatched);
  check (prof.pname ^ ": round trip") (!mismatched = []);
  pkts

let () =
  print_endline "stimulus round-trip";

  let pkts = round_trip smoke 4000 in

  (* every enumerated path must actually appear *)
  let paths = all_paths stack in
  Printf.printf "\n%d paths enumerated\n" (List.length paths);
  List.iter (fun p -> Printf.printf "  %s\n" (String.concat "/" p)) paths;
  let seen =
    List.filter_map
      (fun p -> match p.intent with
         | Expect_parsed { path; _ } -> Some path | _ -> None)
      pkts
  in
  check "all paths generated"
    (List.for_all (fun p -> List.mem p seen) paths);

  (* depth weighting must actually bias toward deep paths *)
  let deep = List.length (List.filter (fun p -> List.length p >= 5) seen) in
  let shallow = List.length (List.filter (fun p -> List.length p = 3) seen) in
  Printf.printf "\ndepth-weighted: %d deep (qinq) vs %d shallow\n" deep shallow;
  check "depth weighting biases deep" (deep > shallow);

  (* every defect category must be exercised *)
  let cats =
    [ Selector_unmatched; Guard_violated; Field_out_of_set;
      Frame_truncated; Repeats_exceeded ]
  in
  let hit d =
    List.exists (fun p -> p.intent = Expect_unparseable d) pkts
  in
  List.iter
    (fun d -> check ("defect exercised: " ^ string_of_defect d) (hit d))
    cats;

  ignore (round_trip adversarial 2000);
  ignore (round_trip skewed 2000);

  (* dense fill must produce the requested number of distinct keys *)
  let occ = round_trip (occupancy 512) 3000 in
  let keys =
    List.filter_map
      (fun p -> match p.intent with
         | Expect_parsed { key_hex; _ } -> Some key_hex | _ -> None)
      occ
  in
  let distinct = List.length (List.sort_uniq compare keys) in
  Printf.printf "\ndense fill: %d distinct keys from 3000 packets\n" distinct;
  check "dense fill bounded" (distinct > 0 && distinct <= 512 * 4);

  (* determinism: same seed, same bytes *)
  let a = generate stack smoke 200 and b = generate stack smoke 200 in
  check "reproducible from seed"
    (List.for_all2 (fun x y -> Bytes.equal x.bytes y.bytes) a b);

  (* minimum frame size honoured except where truncation is the point *)
  check "min frame size"
    (List.for_all
       (fun p ->
          Bytes.length p.bytes >= 60
          || p.intent = Expect_unparseable Frame_truncated)
       pkts);

  Printf.printf "\n%s\n"
    (if !failures = 0 then "all checks passed"
     else Printf.sprintf "%d FAILURES" !failures);
  if !failures > 0 then exit 1

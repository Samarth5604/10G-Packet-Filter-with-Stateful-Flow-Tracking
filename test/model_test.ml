(* model_test.ml -- self-test for the golden model.
   ---------------------------------------------------------------------------
   Frames here are assembled BY HAND, byte by byte, deliberately not using the
   spec. The model is a spec interpreter; checking it against spec-derived
   frames would let one bug cancel another. Hand assembly keeps the two
   independent.
   --------------------------------------------------------------------------- *)

open Protocol_spec
open Golden_model

let b = Buffer.create 256
let u8 v = Buffer.add_char b (Char.chr (v land 0xff))
let u16 v = u8 (v lsr 8); u8 v
let u32 v = u16 (v lsr 16); u16 v
let mac () = for _ = 1 to 6 do u8 0xAA done

let eth ethertype = Buffer.clear b; mac (); mac (); u16 ethertype
let vlan vid inner = u16 vid; u16 inner

(* ihl and frag are parameters so the negative cases can be built by hand *)
let ipv4 ?(ihl = 5) ?(frag = 0) ?(mf = false) ~proto ~src ~dst () =
  u8 ((4 lsl 4) lor ihl);
  u8 0;
  u16 40;
  u16 0x1234;
  u16 (((if mf then 1 else 0) lsl 13) lor frag);
  u8 64; u8 proto; u16 0;
  u32 src; u32 dst;
  for _ = 1 to (ihl - 5) * 4 do u8 0 done

let l4 sp dp = u16 sp; u16 dp; u16 8; u16 0
let payload n = for _ = 1 to n do u8 0x5A done
let frame () = Bytes.of_string (Buffer.contents b)

let failures = ref 0

let check name cond =
  if cond then Printf.printf "  ok    %s\n" name
  else begin incr failures; Printf.printf "  FAIL  %s\n" name end

let run name f expect_status =
  f ();
  let r = parse stack (frame ()) in
  Printf.printf "%-28s %s\n" name (to_string r);
  check name (expect_status r);
  r

let parsed r = r.status = Parsed
let unparseable p r = match r.status with Unparseable x -> p x | _ -> false

let () =
  print_endline "golden model self-test\n";

  let r1 =
    run "eth/ipv4/udp" (fun () ->
        eth 0x0800;
        ipv4 ~proto:17 ~src:0x0A000001 ~dst:0x0A000002 ();
        l4 1000 2000; payload 20)
      parsed
  in
  (* 32 + 32 + 8 + 16 + 16 = 104 bits = 26 hex chars *)
  check "key width 26 hex" (String.length r1.key_hex = 26);
  check "key value"
    (r1.key_hex = "0a0000010a00000211" ^ "03e807d0");
  check "decided at 38 B" (r1.decided_at = 38);

  let r2 =
    run "eth/vlan/ipv4/tcp" (fun () ->
        eth 0x8100; vlan 100 0x0800;
        ipv4 ~proto:6 ~src:0x0A000001 ~dst:0x0A000002 ();
        l4 1000 2000; payload 20)
      parsed
  in
  check "vlan in path" (List.mem_assoc "vlan" r2.path);
  check "decided at 42 B" (r2.decided_at = 42);

  let r3 =
    run "qinq/ipv4/udp" (fun () ->
        eth 0x88A8; vlan 100 0x8100; vlan 200 0x0800;
        ipv4 ~proto:17 ~src:0x0A000001 ~dst:0x0A000002 ();
        l4 1000 2000; payload 20)
      parsed
  in
  (* worst case derived from the spec: this must equal max_parse_bytes *)
  check "decided at worst case"
    (r3.decided_at = max_parse_bytes stack);

  ignore
    (run "3x vlan -> repeat limit" (fun () ->
         eth 0x8100; vlan 1 0x8100; vlan 2 0x8100; vlan 3 0x0800;
         ipv4 ~proto:17 ~src:1 ~dst:2 (); l4 1 2; payload 20)
       (unparseable (function Repeat_limit "vlan" -> true | _ -> false)));

  ignore
    (run "arp -> unmatched" (fun () ->
         eth 0x0806; payload 46)
       (unparseable (function
            | Unmatched_selector ("ethernet.ethertype", 0x0806) -> true
            | _ -> false)));

  let rf =
    run "non-initial fragment" (fun () ->
         eth 0x0800;
         ipv4 ~frag:185 ~proto:17 ~src:1 ~dst:2 ();
        payload 40)
      (unparseable (function
           | Guard_failed "non_initial_fragment" -> true | _ -> false))
  in
  check "no partial key on guard failure" (rf.key_hex = "");
  check "partial exports retained for debug" (rf.key_parts <> []);

  ignore
    (run "initial fragment (MF=1)" (fun () ->
         eth 0x0800;
         ipv4 ~frag:0 ~mf:true ~proto:17 ~src:1 ~dst:2 ();
         l4 1000 2000; payload 20)
       parsed);

  ignore
    (run "ipv4 options (ihl=6)" (fun () ->
         eth 0x0800;
         ipv4 ~ihl:6 ~proto:17 ~src:1 ~dst:2 (); l4 1 2; payload 20)
       (unparseable (function
            | Bad_field_value ("ipv4.ihl", 6) -> true | _ -> false)));

  ignore
    (run "truncated in ipv4" (fun () ->
         eth 0x0800; u8 0x45; u8 0; u16 40)
       (unparseable (function Truncated "ipv4" -> true | _ -> false)));

  ignore
    (run "unmatched ip protocol" (fun () ->
         eth 0x0800;
         ipv4 ~proto:1 ~src:1 ~dst:2 (); payload 40)
       (unparseable (function
            | Unmatched_selector ("ipv4.protocol", 1) -> true | _ -> false)));

  Printf.printf "\n%s\n"
    (if !failures = 0 then "all checks passed"
     else Printf.sprintf "%d FAILURES" !failures);
  if !failures > 0 then exit 1

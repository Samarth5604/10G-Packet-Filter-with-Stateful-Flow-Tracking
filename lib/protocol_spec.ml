(* protocol_spec.ml
   ---------------------------------------------------------------------------
   Declarative description of a protocol header stack.

   DESIGN RULE: this description contains NO functions. Every role is
   first-order data. Parsing runs the description forwards; stimulus generation
   runs it backwards (choose a path, then back-patch the selector and length
   fields that make a parser take that path). A closure cannot be inverted, so
   a closure anywhere here kills the generator and coverage backends.

   Four artifacts are derived from a value of type [stack]:
     - Hardcaml parser RTL           (Gen_rtl)
     - OCaml golden model            (Gen_model)
     - constrained stimulus          (Gen_stimulus)
     - functional coverage bins      (Gen_coverage)
   --------------------------------------------------------------------------- *)

(* The set of values a field may take. Used in BOTH directions: the parser
   accepts only in-set values, and the stimulus generator emits in-set values
   for the happy path and deliberately out-of-set values for error paths.
   This dual use is why parse-window bounds fall out of it for free -- see
   [ipv4] below, where restricting IHL to {5} is what caps the parse window. *)
type value_set =
  | Any
  | Range  of int * int
  | One_of of int list
  | Derived                     (* back-patched at generation time:
                                   a selector or a length field *)

type field = {
  fname  : string;
  width  : int;                 (* bits; need not be byte-aligned *)
  values : value_set;
}


(* A condition that must hold for the next layer to exist at all. Data, not a
   predicate function, so the stimulus generator can invert it: to reach TCP it
   emits frag_offset = 0; to emit a non-initial fragment it picks anything else
   and stops after IPv4. [g_reason] names the drop counter in RTL and the
   coverage bin. *)
type guard = {
  g_field  : string;
  g_values : value_set;
  g_reason : string;
}

(* How far past the start of this layer the next layer begins. *)
type length =
  | Fixed      of int                                   (* bytes *)
  | From_field of { lf_field : string; scale : int }     (* e.g. IHL * 4 *)

(* Which layer follows, and what selects it. *)
type next =
  | Payload
  | Switch of {
      sw_field : string;
      cases    : (int * string) list;                   (* value -> layer name *)
      default  : string option;                         (* None = unparseable *)
      require  : guard list;                            (* ALL must hold, else
                                                           the packet is
                                                           unparseable at this
                                                           layer *)
    }

type layer = {
  lname       : string;
  fields      : field list;
  length      : length;
  next        : next;
  exports     : string list;    (* fields handed to the match engine *)
  max_repeats : int;            (* HARDWARE BOUND: 1 normally, 2 for VLAN/QinQ.
                                   Unbounded recursion is unimplementable; the
                                   type has to say so. *)
}

(* What the datapath does with a frame it cannot classify: no matching
   EtherType, or a guard that failed (e.g. a non-initial fragment, which
   carries no L4 header and therefore has no obtainable 5-tuple). *)
type action =
  | Drop
  | Forward_unclassified

type stack = {
  entry              : string;
  on_unparseable     : action;
  layers             : layer list;
  parse_window_bytes : int;     (* ASSERTED budget. [validate] fails if the
                                   derived worst case exceeds it. Adding a
                                   layer that blows the latency budget then
                                   breaks the build instead of silently
                                   costing you cycles. *)
}

(* --- lookup helpers ------------------------------------------------------ *)

exception Spec_error of string

let find_layer st name = List.find_opt (fun l -> l.lname = name) st.layers

let find_field l name = List.find_opt (fun f -> f.fname = name) l.fields

let field_or_fail l name =
  match find_field l name with
  | Some f -> f
  | None -> raise (Spec_error (Printf.sprintf "%s: no field %S" l.lname name))

(* Bit offset of a field from the start of its layer. Static per layer, which
   is what lets the RTL backend emit a fixed extraction network; the *layer's*
   own start offset is the part that is dynamic at runtime. *)
let field_offset l name =
  let rec go acc = function
    | [] -> raise (Spec_error (Printf.sprintf "%s: no field %S" l.lname name))
    | f :: tl -> if f.fname = name then acc else go (acc + f.width) tl
  in
  go 0 l.fields

let field_end l name = field_offset l name + (field_or_fail l name).width

let ceil_div a b = (a + b - 1) / b

(* --- derivations --------------------------------------------------------- *)

let max_value f =
  match f.values with
  | One_of vs -> List.fold_left max 0 vs
  | Range (_, hi) -> hi
  | Any | Derived -> (1 lsl f.width) - 1

(* Bytes to skip to reach the next layer, worst case. *)
let layer_span_bytes l =
  match l.length with
  | Fixed n -> n
  | From_field { lf_field; scale } -> scale * max_value (field_or_fail l lf_field)

(* Bytes that must actually be READ from this layer -- far enough to cover every
   exported field, the selector, and the length field. For a terminal layer this
   is much less than the full span: we need TCP's ports, not TCP's whole header. *)
let layer_read_bytes l =
  let ends = List.map (fun n -> field_end l n) l.exports in
  let ends =
    match l.next with
    | Payload -> ends
    | Switch { sw_field; require; _ } ->
      (* guard fields are read too -- but for IPv4 they sit at bit 64, well
         inside the 20 bytes already needed for src_ip/dst_ip, so fragment
         handling costs zero additional parse depth. The derivation proves it
         rather than assuming it. *)
      field_end l sw_field
      :: List.map (fun g -> field_end l g.g_field) require
      @ ends
  in
  (* The length field is only needed to find where the NEXT layer starts. On a
     terminal layer nothing follows, so it is dead -- and skipping it here is
     what keeps TCP's read at 4 bytes rather than 13. *)
  let ends =
    match l.next, l.length with
    | Payload, _ | _, Fixed _ -> ends
    | _, From_field { lf_field; _ } -> field_end l lf_field :: ends
  in
  ceil_div (List.fold_left max 0 ends) 8

(* --- the traversal ------------------------------------------------------- *)

(* THE layer-graph walk. Everything that needs to know the shape of the parse --
   the derived bounds, the stimulus generator's path list, the RTL decoder --
   folds over the tree this produces. It exists because the walk was previously
   written out four times and the same bug appeared in two of them: recursing
   per SELECTOR VALUE instead of per TARGET LAYER, so a layer sequence reachable
   by two ethertypes (0x8100 and 0x88A8 both reach vlan) was expanded twice.
   Grouping happens here, once, and consumers cannot reintroduce it.

   Offsets are worst case: [layer_span_bytes] uses the largest value the length
   field accepts. For the shipped spec every span is static (ihl is constrained
   to {5}), so worst case equals actual -- gen_rtl asserts that separately and
   refuses to emit fixed-offset extraction if it ever stops holding. *)

type node = {
  n_layer  : layer;
  n_offset : int;          (* byte offset of this layer from frame start *)
  n_path   : string list;  (* layer names, entry first, including this one *)
}

type edge = {
  e_values  : int list;    (* selector values that take this edge *)
  e_default : bool;        (* true for the Switch default, which has no values *)
  e_target  : string;
  e_tree    : tree;
}

and tree =
  | Leaf of node           (* next = Payload: the parse ends here *)
  | Stop of node           (* max_repeats reached: this layer cannot be entered *)
  | Branch of node * edge list

let reachable st =
  let rec go name off path counts =
    match find_layer st name with
    | None -> None
    | Some l ->
      let path = path @ [ name ] in
      let node = { n_layer = l; n_offset = off; n_path = path } in
      let used = try List.assoc name counts with Not_found -> 0 in
      if used >= l.max_repeats then Some (Stop node)
      else begin
        let counts = (name, used + 1) :: List.remove_assoc name counts in
        match l.next with
        | Payload -> Some (Leaf node)
        | Switch { cases; default; _ } ->
          let span = layer_span_bytes l in
          (* group cases by target layer, preserving first-seen order *)
          let targets =
            List.fold_left
              (fun acc (v, nxt) ->
                 match List.assoc_opt nxt acc with
                 | Some vs -> List.remove_assoc nxt acc @ [ (nxt, vs @ [ v ]) ]
                 | None -> acc @ [ (nxt, [ v ]) ])
              [] cases
          in
          let edges =
            List.filter_map
              (fun (nxt, vs) ->
                 match go nxt (off + span) path counts with
                 | None -> None
                 | Some t ->
                   Some { e_values = vs; e_default = false; e_target = nxt; e_tree = t })
              targets
          in
          let edges =
            match default with
            | None -> edges
            | Some d ->
              (match go d (off + span) path counts with
               | None -> edges
               | Some t ->
                 edges
                 @ [ { e_values = []; e_default = true; e_target = d; e_tree = t } ])
          in
          Some (Branch (node, edges))
      end
  in
  go st.entry 0 [] []

(* Bottom-up fold. [branch] receives each edge paired with its folded subtree. *)
let rec fold_tree ~leaf ~stop ~branch t =
  match t with
  | Leaf n -> leaf n
  | Stop n -> stop n
  | Branch (n, es) ->
    branch n (List.map (fun e -> (e, fold_tree ~leaf ~stop ~branch e.e_tree)) es)

let fold st ~leaf ~stop ~branch ~empty =
  match reachable st with
  | None -> empty
  | Some t -> fold_tree ~leaf ~stop ~branch t

(* Distinct layer sequences from entry to a terminal. Six for the shipped spec. *)
let all_paths st =
  fold st ~empty:[]
    ~leaf:(fun n -> [ n.n_path ])
    ~stop:(fun _ -> [])
    ~branch:(fun _ rs -> List.concat_map snd rs)

(* Worst-case bytes the parser must see before the last classification decision
   is available. THIS IS THE LATENCY NUMBER. It sets the cut-through threshold,
   and therefore the pipeline depth of the generated RTL. *)
let max_parse_bytes st =
  fold st ~empty:0
    ~leaf:(fun n -> layer_read_bytes n.n_layer)
    ~stop:(fun _ -> 0)
    ~branch:(fun n rs ->
        layer_span_bytes n.n_layer
        + List.fold_left (fun acc (_, r) -> max acc r) 0 rs)

(* Width of the flow key. A MAX OVER PATHS, not a sum over layers: UDP and TCP
   both export ports, but no packet traverses both. Summing gives 136 bits and
   sizes the table 30% too wide. *)
let export_bits st =
  let own l =
    List.fold_left (fun a n -> a + (field_or_fail l n).width) 0 l.exports
  in
  fold st ~empty:0
    ~leaf:(fun n -> own n.n_layer)
    ~stop:(fun _ -> 0)
    ~branch:(fun n rs ->
        own n.n_layer + List.fold_left (fun acc (_, r) -> max acc r) 0 rs)

let cut_through_beats ~datapath_bits st =
  ceil_div (max_parse_bytes st * 8) datapath_bits

let validate st =
  if find_layer st st.entry = None then
    raise (Spec_error (Printf.sprintf "entry layer %S not defined" st.entry));
  List.iter
    (fun l ->
       if l.max_repeats < 1 then
         raise (Spec_error (l.lname ^ ": max_repeats must be >= 1"));
       List.iter (fun e -> ignore (field_or_fail l e)) l.exports;
       (match l.length with
        | Fixed n ->
          if n * 8 < List.fold_left (fun a f -> a + f.width) 0 l.fields then
            raise (Spec_error (l.lname ^ ": Fixed length shorter than its fields"))
        | From_field { lf_field; _ } -> ignore (field_or_fail l lf_field));
       match l.next with
       | Payload -> ()
       | Switch { sw_field; cases; default; require } ->
         ignore (field_or_fail l sw_field);
         List.iter (fun g -> ignore (field_or_fail l g.g_field)) require;
         List.iter
           (fun (_, n) ->
              if find_layer st n = None then
                raise (Spec_error (l.lname ^ ": unknown successor " ^ n)))
           cases;
         (match default with
          | Some d when find_layer st d = None ->
            raise (Spec_error (l.lname ^ ": unknown default " ^ d))
          | _ -> ()))
    st.layers;
  let derived = max_parse_bytes st in
  if derived > st.parse_window_bytes then
    raise
      (Spec_error
         (Printf.sprintf
            "parse window blown: derived %d bytes > asserted %d"
            derived st.parse_window_bytes))

(* --- the stack under test ------------------------------------------------ *)

let f ?(values = Any) fname width = { fname; width; values }

let ethernet = {
  lname  = "ethernet";
  fields = [ f "dst_mac" 48; f "src_mac" 48; f "ethertype" 16 ~values:Derived ];
  length = Fixed 14;
  next   = Switch { sw_field = "ethertype";
                    cases    = [ 0x0800, "ipv4"; 0x8100, "vlan"; 0x88A8, "vlan" ];
                    default  = None;          (* IPv4 only: ARP, IPv6, LLDP and
                                                 anything else are unparseable.
                                                 We generate them anyway, as
                                                 negative stimulus. *)
                    require  = [] };
  exports     = [];
  max_repeats = 1;
}

let vlan = {
  lname  = "vlan";
  fields = [ f "pcp" 3; f "dei" 1; f "vid" 12; f "ethertype" 16 ~values:Derived ];
  length = Fixed 4;
  next   = Switch { sw_field = "ethertype";
                    cases    = [ 0x0800, "ipv4"; 0x8100, "vlan"; 0x88A8, "vlan" ];
                    default  = None;
                    require  = [] };
  exports     = [];
  max_repeats = 2;              (* QinQ. Raising this raises latency -- and
                                   [validate] will say so. *)
}

let ipv4 = {
  lname  = "ipv4";
  fields =
    [ f "version" 4 ~values:(One_of [ 4 ]);
      (* Restricting IHL to 5 is what caps the parse window at 20 bytes here.
         Allowing options would derive 60 and blow the asserted budget --
         deliberately, so the trade-off is visible rather than discovered in
         timing closure. Option-bearing packets classify as unparseable. *)
      f "ihl" 4 ~values:(One_of [ 5 ]);
      f "dscp" 6; f "ecn" 2; f "total_len" 16 ~values:Derived;
      f "id" 16; f "flags" 3; f "frag_offset" 13;
      f "ttl" 8; f "protocol" 8 ~values:Derived; f "checksum" 16 ~values:Derived;
      f "src_ip" 32; f "dst_ip" 32 ];
  length = From_field { lf_field = "ihl"; scale = 4 };
  next   = Switch { sw_field = "protocol";
                    cases    = [ 6, "tcp"; 17, "udp" ];
                    default  = None;
                    (* A non-initial fragment (frag_offset > 0) carries no L4
                       header, so no 5-tuple exists. The INITIAL fragment
                       (offset = 0, MF = 1) parses normally. *)
                    require  = [ { g_field  = "frag_offset";
                                   g_values = One_of [ 0 ];
                                   g_reason = "non_initial_fragment" } ] };
  exports     = [ "src_ip"; "dst_ip"; "protocol" ];
  max_repeats = 1;
}

let udp = {
  lname  = "udp";
  fields = [ f "src_port" 16; f "dst_port" 16;
             f "length" 16 ~values:Derived; f "checksum" 16 ~values:Derived ];
  length = Fixed 8;
  next   = Payload;
  exports     = [ "src_port"; "dst_port" ];
  max_repeats = 1;
}

let tcp = {
  lname  = "tcp";
  fields = [ f "src_port" 16; f "dst_port" 16; f "seq" 32; f "ack" 32;
             f "data_offset" 4 ~values:(Range (5, 15)); f "reserved" 4;
             f "flags" 8; f "window" 16;
             f "checksum" 16 ~values:Derived; f "urgent" 16 ];
  length = From_field { lf_field = "data_offset"; scale = 4 };
  next   = Payload;
  exports     = [ "src_port"; "dst_port" ];
  max_repeats = 1;
}

let stack = {
  entry              = "ethernet";
  on_unparseable     = Drop;
  layers             = [ ethernet; vlan; ipv4; udp; tcp ];
  parse_window_bytes = 48;
}

(* --- backend interfaces -------------------------------------------------- *)
(* Each backend is an interpreter over [stack]. None of them may take any input
   the others cannot see, or the artifacts can drift apart again. *)

module type BACKEND = sig
  type output
  val generate : stack -> output
end

let _selftest () =
  validate stack;
  Printf.printf "parse window   : %d / %d bytes\n"
    (max_parse_bytes stack) stack.parse_window_bytes;
  Printf.printf "cut-through    : %d beats @ 64-bit\n"
    (cut_through_beats ~datapath_bits:64 stack);
  Printf.printf "flow key       : %d bits\n" (export_bits stack);
  Printf.printf "unparseable    : %s\n"
    (match stack.on_unparseable with
     | Drop -> "drop" | Forward_unclassified -> "forward unclassified");
  List.iter
    (fun l ->
       match l.next with
       | Switch { require; _ } when require <> [] ->
         List.iter
           (fun g ->
              Printf.printf "guard          : %s.%s (%s) read-depth %d B\n"
                l.lname g.g_field g.g_reason
                (ceil_div (field_end l g.g_field) 8))
           require
       | _ -> ())
    stack.layers
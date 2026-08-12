# 2. The protocol description contains no functions

**Decision:** every role in `Protocol_spec.stack` is first-order data. `Switch`
carries a case list, `From_field` carries a field name and scale, `guard`
carries a value set.

## Alternative: express roles as OCaml functions

Encoding the layer selector as `int -> string`, the length rule as
`fields -> int`, and guards as predicates.

**Pros**
- Substantially more concise; a selector is one line rather than a case list.
- Expresses relationships that data cannot: computed lengths, conditions over
  several fields, arithmetic on field values.
- No extension pressure on the type — a new rule is a new lambda, not a new
  constructor.
- Reads naturally to anyone used to parser combinators.

**Cons**
- Not invertible. A parser runs the description forwards; a stimulus generator
  runs it backwards, choosing a path and back-patching the selector and length
  fields that make a parser take it. A function can be applied but not solved.
- Not enumerable. Coverage bins are obtained by listing selector cases and guard
  outcomes; a function exposes no cases to list.
- Not analysable. The worst-case parse window is computed by walking the layer
  graph; a function hides the graph, so the bound would have to be asserted by
  hand and could not be checked.
- Not printable. Generated documentation reduces to the function's name.
- Of five backends, two work with functions and three do not.

## Alternative: a tagless-final encoding

**Pros**
- Extensible without modifying a central variant type.
- Backends compose as interpreters with no pattern-match exhaustiveness burden.

**Cons**
- Backends that traverse the structure more than once, or need it as a graph
  rather than a fold, are awkward to express.
- The parse-window derivation requires cycle detection with per-layer repeat
  counts, which is a graph algorithm, not a fold.

## Rules that follow, and are not obvious from the type

**One traversal.** The layer graph is walked by exactly one function,
`Protocol_spec.reachable`, which produces an explicit tree; every consumer folds
over it. Before this, four separate walks existed -- the parse-window
derivation, the key-width derivation, the stimulus generator's path list, and
the RTL decoder -- and the same bug appeared in two of them: recursing per
SELECTOR VALUE rather than per TARGET LAYER, so a sequence reachable by two
ethertypes (0x8100 and 0x88A8 both reach vlan) was expanded twice. It inflated
the path count from 6 to 14, skewed the stimulus depth weighting, and duplicated
104-bit key-select logic in the RTL. Grouping now happens once, inside the
traversal, and a new backend cannot reintroduce it.

**Acceptance is a function of read depth.** A constrained field is validated if
and only if it lies inside its layer's read depth. So `ipv4.ihl` (bit 4, inside
20 bytes) is rejected when out of set, but `tcp.data_offset` (bit 96, outside
TCP's 4-byte read depth) is not checked at all. The rule is derivable and costs
no extra parse window, but it is surprising, and both the golden model and the
generated RTL must honour it or differential testing reports a divergence that
is really a specification ambiguity.

**A frame shorter than the parse window is unparseable, whatever it contains.**
The parser shifts beats into a buffer, and beat 0 only reaches its final
position once the window is full. Below that, every extraction offset points at
the wrong bytes -- a short frame carrying an unmatched EtherType has no
EtherType to be unmatched about. `Frame_too_short` therefore dominates every
other verdict in both the model and the RTL, and the model takes the datapath
width as a parameter because truncation semantics depend on it.

The two sides are not symmetric below that threshold. `header_parser` consumes
`in_last` but not `in_keep`, so it has no byte-granular length: a frame that
fills the window but ends inside the parse depth (41..45 bytes here) is detected
by the model and invisible to the RTL, which parses the padding as data. That
range is unreachable in valid traffic -- the interface minimum is 60 bytes -- so
the differential regression cannot reach it. It is recorded as a model-only test
case rather than hidden, and becomes a real comparison point if `in_keep` is
ever added to the parser.

**A false intent is worse than a missed defect.** The stimulus generator labels
each packet with the outcome it expects. Twice, an injected defect was silently
erased -- a bad length value clamped back into range, a repeat extension one
short of the bound -- leaving a well-formed frame labelled unparseable. That
does not merely lose coverage: the round-trip then reports a golden-model bug
that does not exist, and the time is spent looking in the wrong place. Where a
defect cannot be injected, the generator must fall back to emitting a positive
packet, never to claiming one it did not produce.

## Consequences

- Genuinely computed relationships require extending the type rather than
  writing a lambda. This constrains what the description can express, and keeps
  it enumerable.
- Backends may take no input the others cannot see, or the artifacts can drift
  apart despite the shared source.
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

## Consequences

- Genuinely computed relationships require extending the type rather than
  writing a lambda. This constrains what the description can express, and keeps
  it enumerable.
- Backends may take no input the others cannot see, or the artifacts can drift
  apart despite the shared source.

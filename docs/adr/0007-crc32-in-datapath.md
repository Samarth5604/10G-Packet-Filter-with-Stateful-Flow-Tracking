# 7. Parallel CRC32 is a first-class DUT block

**Decision:** implement 64-bit-parallel CRC32 inside the DUT, with `tkeep`-aware
handling of a partial final beat. Recompute FCS after header rewrite.

Header rewrite is in scope (ADR 0006). Modifying any header byte invalidates the
frame's FCS, so CRC32 is inside the datapath by consequence of the feature set,
not by preference.

## Alternative: delegate CRC to a MAC below the boundary

**Pros**
- No CRC logic to write or verify.
- A vendor or third-party MAC regenerates FCS on transmit as a matter of course.

**Cons**
- Requires a MAC in the DUT, which ADR 0003 declines for independent reasons.
- Removes the strongest available formal target from the project.

## Alternative: full recomputation over the whole frame

**Pros**
- One code path; no dependence on which bytes changed.
- Simpler to prove correct.

**Cons**
- The CRC engine must see every byte of every frame, whether or not a rewrite
  occurred.

## Alternative: incremental update over changed bytes only

**Pros**
- Recomputes from the delta rather than the frame; standard practice in
  networking hardware.
- Lower switching activity on frames that pass through unmodified.

**Cons**
- Correctness argument is subtler, and the proof obligation is correspondingly
  harder.
- Deferred: full recomputation first, incremental as a follow-on once the
  equivalence proof for the parallel form is established.

## Consequences

- Deriving a 64-bit-parallel form from the bit-serial polynomial is design work
  rather than transcription.
- The partial final beat requires a variable-width CRC update in a single cycle
  under `tkeep`. This is the same alignment problem the header parser solves, in
  a second location — a second consumer for the generated alignment abstraction
  rather than a one-off.
- Supplies a bounded, self-contained formal target: bit-exactness against a
  bit-serial reference by induction.

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

## Alternative structures for the eight tkeep widths

Three ways to produce a 32-bit update for 1..8 valid bytes. Operation counts are
from the derived matrices; the depth figures assume LUT6 with ~2 levels per
14-input reduction.

| | XOR2 ops | depth | |
|---|---|---|---|
| A: eight independent full-width trees, mux by byte count | 6,832 | ~4 levels | chosen |
| B: cascade of eight byte-wide stages, prefix k = answer for k bytes | 1,760 | ~16 levels | |
| C: one 64-bit tree plus a state-only inverse correction per width | ~4,974 | ~6 levels | |

**Pros of B.** Nearly 4x fewer operations, and conceptually the neatest: the
answer for every byte count falls out of one chain rather than eight separate
trees, so there is a single byte-update matrix to reason about.

**Cons of B.** Eight sequential stages at roughly two LUT6 levels each is about
sixteen levels, which at ~0.4 ns per level on a -2 part lands at or past the
6.400 ns period. Probably-just-misses is the worst outcome available: it costs
the restructure and then needs pipelining anyway.

**Pros of C.** Mathematically the most elegant. Because
`crc_full = M(64-8k) . crc_correct`, the partial-width answer is obtained by
applying `M(64-8k)^-1` to a single 64-bit result, and the inverse matrices are
state-only so each is cheaper than a full tree.

**Cons of C.** Saves only 27% over A. The cleverness does not pay for itself.

## Measured

Scheme A, out-of-context on `XCZU7EV-FFVC1156-2-E` at 6.400 ns:

- **756 LUTs, 32 flip-flops** for the block; 0.3% of the device.
- **WNS 3.259 ns register-to-register (318.4 MHz)**, hold +0.149 ns. The XOR
  tree and byte-count mux together take 3.141 ns, under half the period.
- Measured on `crc32_par_ooc`, the registered-input variant. The block itself
  has no register-to-register paths -- every path runs port to output register
  -- so standalone timing reflects the I/O budget and clock insertion delay
  rather than the logic, and its hold "failure" is an artifact of launching
  from an ideal external clock into a flop that sees BUFG insertion delay.

B would have saved roughly 500 LUTs on a device with 230,000, at the cost of
probably missing timing. The area A spends is not scarce; the timing margin it
buys is.

## Consequences

- Deriving a 64-bit-parallel form from the bit-serial polynomial is design work
  rather than transcription.
- The partial final beat requires a variable-width CRC update in a single cycle
  under `tkeep`. This is the same alignment problem the header parser solves, in
  a second location — a second consumer for the generated alignment abstraction
  rather than a one-off.
- Supplies a bounded, self-contained formal target: bit-exactness against a
  bit-serial reference by induction.
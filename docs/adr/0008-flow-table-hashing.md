# 8. Flow table: 4-way cuckoo, multiply-shift hashing

**Decision:** a 4-way cuckoo hash over a 104-bit key, each way indexed by a
CRC32 with its own **polynomial**, `max_evict = 32`, `stash_depth = 32`.

Every parameter comes from the occupancy sweep in `bin/gen_sweep.ml`. None is
asserted.

## Alternative: CRC-based hashing with a per-way initial state

The first implementation. Attractive because the GF(2) matrix derivation already
exists in `lib/crc_spec.ml` for the FCS path, so each way would have been one
XOR tree over 104 bits -- no multiplier, no DSP, one LUT level.

**Pros**
- Reuses machinery already written, derived and formally targeted.
- Cheapest possible hardware: XOR trees, no arithmetic.
- Same cost per way, so scaling ways is linear and predictable.

**Cons**
- **The ways are not independent. They are the same function.** Changing a CRC's
  initial state shifts the output by a constant that depends only on message
  length, so for fixed-width keys `h_i(k) = h_0(k) XOR c_i`. Two keys equal
  under one way are equal under all of them.
- Measured: **39,332 of 39,332** key pairs colliding in way 0 also collided in
  all four ways, against ~2.4 expected under independence. Cuckoo hashing has no
  reason to work at all under this hash; the table stashed keys at 21% load with
  a maximum eviction chain of zero, which reads as a load-factor failure and is
  not one.
**The fix was not to abandon CRC but to vary the right thing.** Different
polynomials give genuinely different linear maps and measure clean: 2 of 39,332
also-way1 collisions against 2.4 expected, zero all-four. The four ways use
CRC-32 (0xEDB88320), CRC-32C, CRC-32Q and CRC-32K -- published, well-studied
polynomials rather than arbitrary bit patterns that happen to score well.

## Alternative: multiply-shift hashing

Measured equally clean: 3 of 40,210 also-way1 against 2.5 expected, zero
all-four. Rejected on hardware cost, not quality.

**Pros**
- The textbook choice, with a proven analysis behind it.
- One multiplier per way is conceptually simpler than a CRC tree.

**Cons**
- A 64-bit multiply needs several DSP48E2 per way on UltraScale+ (the primitive
  is 27x18), so four ways is a dozen or more DSPs plus adder trees -- on the
  critical path of **every packet**, since lookup happens per packet while
  insert does not.
- A CRC is linear over GF(2), so the same independence costs one XOR tree per
  way: no DSP, one or two LUT levels, and the derivation machinery already
  exists in `lib/crc_spec.ml` for the FCS path.
- A 32-bit multiply-shift would be cheaper and also measured clean, but still
  buys nothing over an XOR tree.

## Alternative: 2 or 3 ways

Equal-load-factor sweep, capacity normalised:

| ways | usable load | URAM288 @128b | median chain |
|---|---|---|---|
| 2 | ~56% | 32 | 0 |
| 3 | ~74% | 48 | 0 |
| 4 | **~92%** | 32 | 0 |

**Pros of fewer ways**
- Fewer parallel memory ports, which is the real cost of `d` -- lookup latency
  is one access regardless.
- 2-way is the classic cuckoo formulation and the best understood.

**Cons**
- 2-way walls at 56% load: over 40% of provisioned URAM is unusable.
- 3-way needs 1.5x the blocks for a worse wall than 4-way, because
  `3 * 2^n` does not tile URAM as cleanly as `4 * 2^n` -- a non-power-of-2 way
  count wastes depth.
- Median chain depth is 0 at every load factor for all three, so the common case
  never distinguishes them; only the tail does.

## Eviction bound versus stash depth

These trade against each other, and the sweep shows the trade is very uneven:

| `max_evict` | stash used at 85% | at 90% | wall |
|---|---|---|---|
| 8 | 107 | -- | 85.6% |
| 16 | 16 | -- | 89.4% |
| 32 | **0** | 24 | 92.2% |
| 64 | 0 | 0 | 93.5% |

A deeper eviction bound substitutes almost perfectly for stash depth, and the
two costs are not comparable:

- **Chain depth costs cycles on the INSERT path only.** Inserts happen once per
  new flow, not once per packet.
- **Stash depth costs LUTs and comparison delay on EVERY LOOKUP.** A
  fully-associative CAM is probed in parallel with the table for every packet.

So buy chain depth, not stash. `max_evict = 32` with `stash_depth = 32` leaves
the stash empty at 85% load and 24 of 32 used at 90%.

Raising the bound to 64 buys another 1.3% of load and doubles worst-case insert
latency; not taken.

## Sizing the stash

Stash depth does not change how many keys NEED stashing at a given load -- at
90% exactly 74 keys overflow whether the stash holds 128 or 256. It only changes
where the run stops. So the stash is sized for the OPERATING POINT, not to push
the wall:

| operating load | slots needed |
|---|---|
| 85% | 0 |
| 90% | 24 |
| 92%+ | 128 and climbing steeply |

Using a CAM to hold the table together past 92% is asking the most expensive
structure in the design to do the cheapest structure's job.

## Consequences

- Eviction is bounded (`max_evict`) because an unbounded chain has no worst
  case, and a line-rate datapath cannot stall while one resolves -- packets keep
  arriving. Hitting the bound sends the key to the stash; that is the stash's
  purpose, not a failure.
- A victim is never evicted back into the way it came from. Without that, chains
  ping-pong between two ways rather than walking the table.
- The polynomials and their per-way assignment are part of the specification:
  the RTL must use the same values or the model is not a reference.
- These figures are for uniformly random keys. The `skewed` stimulus profile
  produces realistic flow-count distributions, and the trade should be confirmed
  there before the parameters are treated as final.
- Hash independence is now a numerical assertion in
  `test/flow_table_test.ml`, not a comment. The original file carried a note
  saying independence was "not proved, only measured" -- and then did not
  measure it until the table failed.
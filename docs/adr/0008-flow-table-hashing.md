# 8. Flow table: 4-way cuckoo, multiply-shift hashing

**Decision:** a 4-way cuckoo hash over a 104-bit key, each way indexed by a
CRC32 with its own **polynomial**, `max_evict = 32`, `stash_depth = 8`,
`pending_depth = 16`, operated at an **85% load factor**.

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

## The pending-insert race, and sizing its CAM

An insert is not atomic in hardware. It is a URAM read-modify-write plus, if the
chain runs, up to `max_evict` more of them -- and packets keep arriving
throughout. Packets 2 and 3 of a new flow therefore miss a table that already
has an insert in flight for their key, and request their own. Three inserts land
for one key: duplicates, or a corrupted chain if they interleave.

`lib/flow_pipeline.ml` is the same table WITH TIME, and exists to expose this.
`lib/flow_table.ml` structurally cannot: it has no cycles, so every insert is
atomic and the race does not exist there.

**Measured.** A four-packet burst of one new flow at 85% load, packets every 10
cycles: **3 duplicate inserts** without a pending CAM, **0** with one.

**The race is load-dependent**, which is what makes it dangerous. Insert latency
is 8 cycles at the median regardless of load -- under the 10.5-cycle
inter-arrival at line rate, so nothing races on a quiet table. The tail is not:

| load | median | p99 | max |
|---|---|---|---|
| 50% | 8 | 8 | 11 |
| 70% | 8 | 14 | 23 |
| 80% | 8 | 29 | 47 |
| 85% | 8 | 50 | 92 |
| 90% | 11 | 104 | 107 |

So the race appears exactly when the table is under pressure and new flows are
hardest to place -- the condition least likely to be reached by a short test on
an empty table.

**CAM depth**, all-new-flow traffic at 85% load:

| depth | inserts dropped per 10,000 |
|---|---|
| 2 | 5,922 |
| 4 | 2,605 |
| 8 | **0** |
| 16 | 0 |

Maximum pending occupancy is 6, stable from 100 to 10,000 packets. **8 entries**,
a quarter of the stash, on a structure that also sits on the per-packet path.

Two measurement mistakes worth recording, both of which made the test pass while
proving nothing:

- The first `latency_for` probed the chain depth by inserting the key and then
  deleting it. That places the key, so the next packet found it in the table and
  the race could not occur. The measurement destroyed what it measured.
- The burst then used an arbitrary key, which had a free candidate slot even at
  85% load, so its insert completed in 8 cycles and retired before the next
  packet. The test has to choose a key whose candidate slots are ALL occupied,
  or it passes vacuously.

## CAM cost, and why the operating point moved to 85%

Both CAMs were synthesised out-of-context at five depths before either was
sized. 104-bit entries, `XCZU7EV-FFVC1156-2-E`, 6.400 ns:

| depth | LUTs | LUT/entry | FFs | WNS r2r |
|---|---|---|---|---|
| 8 | 308 | 38.5 | 848 | 4.364 |
| 12 | 464 | 38.7 | 1270 | 3.350 |
| 16 | 622 | 38.9 | 1690 | 3.877 |
| 32 | 1255 | 39.2 | 3372 | 3.293 |
| 64 | 2630 | 41.1 | 6734 | 3.283 |

**Area is linear** at ~39 LUTs and ~105 flip-flops per entry (104 key bits plus
a valid bit).

**Latency is flat from 12 to 64.** Depth 12 measured *slower* than depth 16,
which no structural effect can produce -- a larger CAM cannot be faster than a
smaller one -- so the 322-491 MHz spread is placement variance, the same few
percent that moved the parser's LUT count under a pure signal rename. Depth 8 is
genuinely faster because it packs tightly.

That flatness was not the prediction. The expectation was a step at 64 as the
match-OR reduction went from two LUT6 levels to three. It does not appear, which
says **the OR tree is not the critical path: the 104-bit equality comparison
is**, and that is depth-independent. Adding entries adds width, not depth.

**The consequence is a design change.** A 32-deep stash costs 1255 LUTs and 3372
FFs -- more than seven times the entire header parser (169 LUTs). Both CAMs at
the originally chosen depths would have dominated the design's logic.

The occupancy sweep shows the stash is **empty at 85% load** and holds 24 entries
at 90%. Operating five points lower costs 3,200 flows out of 58,900 -- about 5%
of capacity on a table with 92% of headroom -- and buys back roughly 950 LUTs and
2,500 flip-flops.

This is the evict-versus-stash trade one level up: **the cheapest way to shrink
the most expensive block is to run the table slightly emptier.** Stash depth 8,
pending depth 16, operating point 85%.
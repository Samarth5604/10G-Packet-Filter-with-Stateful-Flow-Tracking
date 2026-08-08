# 6. Scope freeze and definition of done

**Decision:** the feature set below is frozen. Additions are recorded in
`future/` and do not enter the build.

**In:** Ethernet / 802.1Q / QinQ to depth 2 / IPv4 / TCP / UDP; 5-tuple flow
table with bounded cuckoo insert and CAM stash; cut-through with FCS abort;
forward, drop and header-rewrite actions; 64-bit-parallel CRC32 with
`tkeep`-aware partial-beat handling; five generators; four formal properties.

**Out:** IPv6, IPv4 options, fragment-decision inheritance, MPLS, tunnelling,
VLAN depth beyond 2, reassembly, PCIe, hardware bring-up, incremental CRC
update, any Ethernet MAC function beyond framing (pause frames, jumbo frames,
statistics, link status).

## Alternative: leave scope open

**Pros**
- Permits opportunistic depth where a sub-problem turns out to be interesting.
- Avoids committing before the difficulty of each block is known.

**Cons**
- A simulation-only project has no external forcing function. Nothing outside
  the repository establishes when it is finished.
- Every item on the "out" list is individually reasonable, which is the
  mechanism by which scope grows without any single unreasonable decision.
- Partial breadth is worth less than completed depth: an unverified IPv6 path
  adds no defensible claim while consuming the budget for coverage closure.

## Done

1. Coverage closure on all generated bins.
2. Occupancy sweep 10% to 95% published, with worst-case and p99.9 chain depth.
3. Differential regression green at target packet count, zero divergence.
4. Four formal properties proved, induction depth recorded:
   - field extraction bit-exact against a byte-addressed reference across all
     encapsulation offsets (validates *generated* RTL);
   - 64-bit-parallel CRC32 bit-exact against a bit-serial reference;
   - the cut-through FSM never emits a frame shorter than 64 bytes;
   - any inserted, non-evicted key is retrievable within the bounded probe
     count.
5. Out-of-context post-route timing report committed.

No figure from this project is published externally until all five hold.

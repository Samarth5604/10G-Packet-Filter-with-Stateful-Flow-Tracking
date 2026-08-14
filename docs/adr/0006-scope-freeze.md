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

### Status (last updated 2026-08-14)

Tracked here rather than inferred from the repo state, since "the code
exists" and "the condition is met" are not the same claim.

1. **Not done.** No coverage-closure pass against the 15 declared bins has
   been run. The sim regression below proves correctness of the packets it
   was fed, not that every bin was fed one.
2. **Mostly done, one discrepancy to resolve.** `make sweep 4 14 32 8` ran
   10%→90% in the committed transcript; the stash hit 88% and the run
   stopped at 90%, not 95% as this condition is literally worded. Either
   rerun to force rows past the stash-full point so the 95% figure exists,
   or narrow the wording of this condition to "10% to stash exhaustion" — do
   not round 90% up to 95% on the resume.
3. **Done.** Verilator differential regression, RTL vs golden model, four
   profiles, zero mismatches:

   | profile | packets | mismatched |
   |---|---|---|
   | smoke | 2,000,000 | 0 |
   | adversarial | 200,000 | 0 |
   | skewed | 200,000 | 0 |
   | occupancy | 200,000 | 0 |

   2,600,000 packets total. Evidence: `sim/results_smoke_2M.xml`,
   `sim/results_adversarial_200k.xml`, `sim/results_skewed_200k.xml`,
   `sim/results_occupancy_200k.xml`.
4. **Not started.** `make formal` still exits non-zero by design; no
   SymbiYosys `.sby` files exist yet.
5. **Both clock-gating blocks now synthesized; condition substantively met,
   one caveat flagged below.** `make cam-sweep` gives post-route numbers for
   the CAM at 5 depths (8/12/16/32/64), 320–491 MHz range,
   `reports/cam-sweep/`.

   `crc32_par_ooc` (`make synth TOP=crc32_par_ooc`):

   | metric | value |
   |---|---|
   | period target | 6.400 ns (156.25 MHz) |
   | WNS reg-to-reg | 3.259 ns |
   | WNS overall (incl. budgeted I/O) | 1.729 ns |
   | WHS hold | 0.149 ns |
   | max frequency | 318.4 MHz |
   | LUT2/3/4/5/6 | 62 / 32 / 92 / 114 / 499 |
   | FDRE | 137 |

   `header_parser` (`make synth`, default TOP):

   | metric | value |
   |---|---|
   | period target | 6.400 ns (156.25 MHz) |
   | WNS reg-to-reg | 4.152 ns |
   | WNS overall (incl. budgeted I/O) | 1.100 ns |
   | WHS hold (r2r) | 0.013 ns |
   | WHS hold (all, incl. ports) | -0.114 ns |
   | max frequency | 444.8 MHz |
   | LUT1/2/3/4/5/6 | 1 / 8 / 6 / 27 / 13 / 114 |
   | FDRE | 379 |

   Both blocks meet setup with margin (444.8 MHz and 318.4 MHz respectively,
   against a 156.25 MHz requirement). **Caveat, not yet resolved:**
   `header_parser`'s r2r hold margin is 0.013 ns -- close enough to zero that
   it should not be called "closed" without rerunning against derated
   multi-corner OCV numbers, which OOC nominal-corner analysis does not
   apply. `report_timing_summary` also raised a CRITICAL WARNING on this run
   from the -0.114 ns all-paths hold number; `synth_ooc.tcl`'s pass/fail gate
   only checks the r2r figure (by design, per the script's own comments on
   OOC port-path artifacts), so the run reported success, but do not quote a
   general "hold closes" claim from this -- scope it explicitly to
   "nominal-corner r2r hold, 13 ps margin" if it goes on the resume at all.
   Evidence: `reports/header_parser_timing.rpt`,
   `reports/header_parser_utilization.rpt`.
# 1. Verification scope: simulation and formal, not hardware

**Decision:** correctness is established by cycle-accurate simulation, formal
proof and differential testing. No hardware measurement is claimed.

## Alternative: reduce feature scope to reach a board

**Pros**
- Produces a wire-to-wire latency figure including PCS/PMA, which simulation
  cannot supply.
- Exercises failure modes simulation hides: routing congestion on the critical
  path, and clock-domain crossing between the recovered RX clock and the local
  TX clock.
- External hardware provides a forcing function toward completion.

**Cons**
- Requires 10G-capable hardware and a line-rate traffic source; without both,
  the measurement is not obtainable at any feature scope.
- Feature budget spent on integration is taken from the flow table and the
  generator, which carry the design content.
- Characterisation coverage falls sharply. Sweeping table occupancy from 10% to
  95% over millions of keys is routine in simulation and impractical on a board.
- Latency measured through on-chip timestamping is quantised to the clock;
  cycle counts in simulation are exact.

## Alternative: simulation only, without formal

**Pros**
- Removes the SMT toolchain and its install cost.
- Faster to a first working regression.

**Cons**
- Simulation samples the input space; it cannot establish a property over all
  encapsulation offsets or all table states.
- The strongest available claims — bit-exactness of extraction, absence of
  sub-64-byte egress frames — become statistical rather than proved.

## What CI can and cannot check

CI runs everything that needs no proprietary toolchain, including a 20{,}000
packet differential run against Verilator from apt. That number is small on
purpose: its value is not coverage but **third-party reproducibility**. Vectors
derive from a named profile and an integer seed, so anyone can regenerate the
exact packets the job checked. The volume runs stay local and their results are
committed under `reports/`.

`make synth` cannot run in CI -- Vivado is not installable there -- so
post-route timing is produced locally and committed as evidence rather than
recomputed on every push.

## Consequences

- Latency is reported at the MAC AXI4-Stream boundary, excluding PCS/PMA. The
  boundary is stated at every occurrence.
- The two untested failure modes above are published in the README rather than
  omitted.
- Completion is defined by ADR 0006 rather than by hardware availability.
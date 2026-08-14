# Line-rate 10G packet filter with stateful flow tracking

A cut-through Ethernet/IPv4 packet filter for `XCZU7EV-FFVC1156-2-E`, generated
from a single declarative protocol description, verified against an OCaml golden
model and bounded-induction proofs.

## Status and evidence basis

**This design has never run on hardware, and does not claim to.**

Every quantitative claim in this repository comes from exactly one of four
sources, and each is labelled as such wherever it appears:

| verb | meaning |
|---|---|
| *in cycle-accurate simulation* | Verilator, measured at the MAC AXI4-Stream boundary. Excludes PCS/PMA. |
| *post-route in Vivado* | 2024.1, out-of-context, `XCZU7EV-FFVC1156-2-E`. |
| *formally proved* | SymbiYosys, bounded induction, depth stated per property. Four properties; see `docs/adr/0006-scope-freeze.md`. |
| *differentially verified over N packets* | RTL vs. OCaml golden model, zero divergence. Verdict, failure reason and extracted key are all compared. |

Anything that cannot be phrased with one of those four verbs is not a result.
The words "measured on hardware", "on-chip", "board", and "bring-up" do not
appear in this repository by design.

Known gaps that board bring-up would expose, and simulation will not:

- alignment-network critical path under real routing congestion, versus
  out-of-context estimates;
- CDC between the recovered RX clock and the local TX clock in a
  bump-in-the-wire topology.

## What is actually built here

All RTL in this repository is original. There is no Ethernet MAC in the design:
frame construction and checking — preamble, SFD, inter-frame gap, FCS bytes —
are performed by the Python BFM in the regression, and the DUT's interface is
AXI4-Stream, specified in `docs/interface-contract.md`. Rationale and
alternatives in `docs/adr/0003-no-mac-dependency.md`.

Writing the framing in the testbench does not remove the need for a MAC and PHY
in a deployed system. It means that in simulation there is no wire, so the
question does not arise.

The design comprises the protocol description, the five generators that consume
it, the header parser, the 5-tuple flow table, the parallel CRC32 engine, the
cut-through control, and the verification framework.

## Generated artifacts

`lib/protocol_spec.ml` holds one value of type `stack`. Five backends consume
it, and none may take input the others cannot see:

1. Hardcaml parser RTL
2. OCaml golden model
3. constrained stimulus generator
4. functional coverage bins
5. this repository's protocol documentation (`docs/protocol.md`)

Adding QinQ, or a new L4 protocol, is a spec edit; all five regenerate
consistently. Maintaining five artifacts by hand permits a golden model and its
RTL to converge on the same misunderstanding, at which point differential
testing confirms the error instead of catching it.

Derived, not chosen by hand:

```
parse window   : 46 / 48 bytes
cut-through    : 6 beats @ 64-bit
flow key       : 104 bits
```

The parse window is *asserted* in the spec; `validate` fails the build if the
derivation exceeds it. Allowing IPv4 options derives 86 B and breaks the build
deliberately, so the latency cost is visible at spec-edit time rather than in
timing closure.

## Reproducing

See `docs/toolchain.md` for exact versions and the environment-isolation rule
(Vivado, OSS CAD Suite and the opam switch must never share a shell).

```
make derive      # validate spec, print derived bounds     [implemented]
make docs        # regenerate docs/protocol.md             [implemented]
make docs-check  # fail if the committed copy is stale     [implemented]
make model       # OCaml golden model self-test             [implemented]
make stimulus    # generator round-trip vs the model        [implemented]
make crc         # parallel CRC32 derivation self-test      [implemented]
make flowtable   # cuckoo hash model self-test              [implemented]
make sweep       # occupancy sweep, picks table parameters  [implemented]
make pipeline    # timed model: the pending-insert race     [implemented]
make rtl         # Hardcaml -> rtl/*.v                       [implemented]
make vectors     # stimulus + expected results -> sim/      [implemented]
make sim         # Verilator differential regression        [implemented]
make formal      # SymbiYosys proofs                       [not implemented]
make synth       # out-of-context synthesis -> reports/    [needs rtl/]
```

Unimplemented targets exit non-zero rather than succeeding silently, so a green
build means the named work was actually done. `make help` lists current status.

## Layout

```
lib/           protocol description (the single source) + derivations
               golden_model.ml -- reference parser, an interpreter over it
               stimulus.ml -- the spec run backwards, parametric profiles
               crc_spec.ml -- parallel CRC32 matrices from the polynomial
               flow_table.ml -- cuckoo hash model, reference for the RTL
               flow_pipeline.ml -- the same table WITH TIME; the race lives here
bin/           gen_docs, gen_rtl -- documentation and RTL backends
test/          spec validation, derived bounds, golden-model self-test; CI
rtl/           generated and hand-written Verilog          (empty)
sim/           cocotb differential regression              (empty)
formal/        SymbiYosys proofs                           (empty)
syn/           non-project out-of-context synthesis
env/           three isolated tool environments -- never combine
docs/adr/      decision records: options considered, with trade-offs
docs/interface-contract.md   the AXI4-Stream boundary, specified not inherited
future/        deferred items, with the analysis behind each deferral
```

## Decisions

Architecture decision records live in `docs/adr/`. Each states a decision and
gives the rejected alternatives their strongest case, so the trade-off is
legible without the reasoning having to be reconstructed.

Interface contract: `docs/interface-contract.md`. Third-party components and
their licences: `THIRD_PARTY.md`.
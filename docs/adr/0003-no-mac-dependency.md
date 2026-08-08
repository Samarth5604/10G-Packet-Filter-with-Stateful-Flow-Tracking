# 3. No MAC in the design; framing lives in the testbench

**Decision:** the DUT contains no Ethernet MAC. Frame construction and checking
— preamble, SFD, inter-frame gap, FCS bytes — are performed by the Python BFM
in the regression. The DUT's interface is AXI4-Stream, specified in
`docs/interface-contract.md`. CRC32 moves *into* the DUT as a first-class block
(ADR 0007).

Supersedes the earlier decision to integrate `verilog-ethernet`.

## Alternative: integrate a third-party MAC (`verilog-ethernet`, MIT)

**Pros**
- Supports a frame-level integration simulation with a production-grade MAC in
  the loop; this is the MAC beneath the Corundum NIC, not a toy.
- Exercises the AXI4-Stream conventions that a real vendor MAC also uses, so
  assumptions baked into the filter are less likely to be private ones.
- Supports the claim "10GBASE-R MAC/PCS integration" on a skills list.
- Simulates under Verilator and Icarus, unlike encrypted vendor IP.

**Cons**
- The MAC sits below the DUT boundary, so it is absent from the volume
  regression regardless. Its presence changes nothing about what is verified.
- The integration claim is thin on inspection: connecting to an existing
  AXI4-Stream port is wiring, not design. In a loopback simulation the PCS is
  never meaningfully exercised.
- Introduces a pinned external dependency and an attribution boundary that must
  be defended whenever authorship is discussed.

## Alternative: implement a synthesizable MAC

**Pros**
- Frame delimiting, CRC checking and IFG counting are perhaps 400 lines; the
  core is not difficult.
- Removes all third-party RTL.

**Cons**
- A MAC that deserves the name also handles pause frames, alignment errors,
  jumbo frames, deficit idle count, link status and statistics counters. None
  carries design content; none is optional if the block is called a MAC.
- The unqualified claim "implemented a MAC" invites an enumeration of what was
  omitted.
- Displaces budget from the flow table and the generator.

## Alternative: encrypted vendor IP (Xilinx 10G/25G Ethernet Subsystem)

**Pros**
- The industrial choice; vendor-supported and timing-closed.
- Integrates directly with the GT wizard.

**Cons**
- IEEE-1735 encrypted, so it runs only under simulators with approved key
  support. Verilator and Icarus cannot elaborate it, confining simulation to
  XSIM, which cannot carry a multi-million-packet regression in useful time.
- A clone cannot build without the same Vivado edition and licence.
- Limited internal visibility during debug.

## Consequences

- The repository contains no third-party RTL. Authorship needs no boundary
  argument.
- The interface contract is defined rather than inherited, and is stated
  explicitly in `docs/interface-contract.md`.
- The skills claim narrows from "10GBASE-R MAC/PCS integration" to a designed
  frame budget plus a formally proved CRC. The narrower claim is harder to
  fabricate.
- Writing framing in the testbench does not remove the need for a MAC and PHY
  in a deployed system. It means that in simulation there is no wire, so the
  question does not arise. Nothing here implies otherwise.

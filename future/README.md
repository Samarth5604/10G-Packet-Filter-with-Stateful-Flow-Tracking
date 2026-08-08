# Deferred

Items excluded by `docs/adr/0006-scope-freeze.md`. Nothing here enters the build
until the five completion conditions in that record hold.

## Fragment-decision inheritance
A secondary table keyed on `(src_ip, dst_ip, id, protocol)` recording the
initial fragment's verdict so later fragments of the same datagram inherit it,
rather than being dropped. Composes with the primary flow table; requires an
ageing mechanism and a defined policy for fragments arriving before their
initial fragment. Analysis in `docs/adr/0005-ipv4-only-and-fragments.md`.

## IPv6
Widens the flow key from 104 to 296 bits and makes the parse window a function
of extension-header chain depth. Analysis in ADR 0005.

## IPv4 options
Derives an 86-byte parse window against the 48-byte assertion; `validate` fails
the build. Admitting options requires raising the asserted window and accepting
the cut-through threshold that follows from it.

## VLAN depth beyond 2
Depth 3 derives 50 bytes and 7 beats.

## Incremental CRC update
Recomputing FCS from the changed header bytes rather than the whole frame.
Standard practice in networking hardware and lower switching activity on
unmodified frames, but a subtler correctness argument and a harder proof
obligation. Full recomputation ships first. Analysis in
`docs/adr/0007-crc32-in-datapath.md`.

## MAC integration
The design has no MAC (ADR 0003). Adapting the AXI4-Stream contract in
`docs/interface-contract.md` onto a real MAC is a wrapper, not a redesign — the
four interface questions in that document are exactly what such a wrapper must
answer.

## Others
MPLS, tunnelling, reassembly, PCIe, hardware bring-up, and MAC functions beyond
framing: pause frames, jumbo frames, statistics, link status.

# rtl

Generated and hand-written Verilog. Empty until the corresponding Makefile
targets are implemented.

Planned blocks:

- `header_parser` — generated from `lib/protocol_spec.ml` via Hardcaml
- `alignment_network` — generated; field extraction across encapsulation offsets
- `crc32_par` — hand-written; 64-bit-parallel, `tkeep`-aware partial final beat
- `flow_table` — cuckoo hash in URAM, CAM stash, pending-insert dedup
- `cut_through_ctrl` — egress commit, FCS abort, injection arbitration

Interface for every block: `docs/interface-contract.md`. Scope: ADR 0006.

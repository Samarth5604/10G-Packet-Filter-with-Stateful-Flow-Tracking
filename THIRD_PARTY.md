# Third-party components

All RTL in this repository is original. No third-party HDL is vendored or
submoduled; see `docs/adr/0003-no-mac-dependency.md`.

The components below are build- and test-time dependencies only.

## Hardcaml (build-time)
- Author: Jane Street
- Licence: MIT
- Use: RTL generation from `lib/protocol_spec.ml`
- Version: pinned in `opam.locked`

## cocotb, cocotbext-axi, scapy (test-time)
- Licences: BSD-3-Clause (cocotb, cocotbext), GPL-2.0 (scapy)
- Use: testbench, AXI4-Stream BFM, frame construction in the regression
- Versions: pinned in `requirements.txt`

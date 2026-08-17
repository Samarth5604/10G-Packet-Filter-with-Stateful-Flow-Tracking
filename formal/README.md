# formal

SymbiYosys proofs. `make formal` runs every `.sby` file in this directory
and fails loud if any proof fails or if `sby` isn't on PATH (`source
env/oss.sh` first).

Status against the four properties in `docs/adr/0006-scope-freeze.md`,
condition 4 -- see that ADR's Status section for the authoritative,
dated account. Summarised here:

| # | property | `.sby` | status |
|---|---|---|---|
| 1 | field extraction bit-exact vs. byte-addressed reference | not yet written | RTL exists (`header_parser.v`); next to build |
| 2 | CRC32 bit-exact vs. bit-serial reference | not yet written | RTL exists (`crc32_par.v`/`_ooc.v`); next to build |
| 3 | cut-through FSM never emits a frame shorter than 64 bytes | cannot be written | **blocked: no cut-through FSM RTL has been generated.** Only the sub-blocks (parser, CRC, CAM) exist. This property has no subject until that RTL is built. |
| 4 | any inserted, non-evicted key retrievable within the bounded probe count | `cam_retrieve.sby` | **partial.** Proves a necessary sub-property against `cam.v` alone -- a key written to an index and not since overwritten/invalidated is always found there. Says nothing about probe count or eviction, because the cuckoo-hash probing logic (`lib/flow_table.ml`) is an OCaml model only, not RTL. See the scope note at the top of `cam_retrieve.sv` before quoting this as evidence for property 4 as literally worded.

Do not round "one sub-property proved" up to "property 4 proved" anywhere
this gets cited. The distinction is the whole point of writing it down here.
# 4. Target `XCZU7EV-FFVC1156-2-E` as a part, not as a board

**Decision:** synthesise against the part directly. No board file, no board
target.

## Alternative: select the ZCU106 board target

**Pros**
- Board files preset IP configuration and IP Integrator connections.
- Supplies pin constraints for on-board peripherals.
- Matches the workflow used when hardware is in the loop, so the project would
  transfer to a board with less change.

**Cons**
- There is no block design, no external pin and no board peripheral in this
  datapath, so a board target sets the part and contributes nothing further.
- A clone requires the matching board repository to be installed; a part-only
  project builds on any 2024.1 installation.
- Selecting a board makes "targeted the ZCU106" available as a phrase, which is
  one step from being heard as "ran it on a ZCU106". The part number implies the
  board to a reader who knows it, without asserting hardware.

## Alternative: a device without URAM

**Pros**
- Wider availability across the free Vivado device set.

**Cons**
- A 64K-entry, 128-bit-wide table is roughly 8 Mbit. In BRAM36 that is about 228
  blocks, a large fraction of a mid-size part.
- BRAM cascade depth and timing differ from URAM, changing both the resource
  result and the achievable clock.

## Consequences

- Vivado 2024.1 precedes the Basic/Core/Pro licensing restructure. The version
  is pinned for the duration of the project.
- Project mode is used for iteration; `write_project_tcl` output is committed so
  the project is reconstructible from source. Synthesis reports are produced by
  the non-project script in `syn/`.

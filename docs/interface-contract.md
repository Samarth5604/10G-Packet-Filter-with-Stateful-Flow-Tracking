# DUT interface contract

The DUT boundary is AXI4-Stream. No MAC is instantiated (ADR 0003), so this
contract is defined here rather than inherited from one. It is the specification
the Python BFM implements and the RTL assumes; any future MAC becomes an adapter
onto it.

## Signals

64-bit datapath at 156.25 MHz, one stream in and one out.

| signal | width | meaning |
|---|---|---|
| `tdata` | 64 | frame bytes, first byte in bits [7:0] |
| `tvalid` | 1 | `tdata` valid |
| `tready` | 1 | sink accepts this beat |
| `tlast` | 1 | final beat of the frame |
| `tkeep` | 8 | byte enables; see below |
| `tuser` | 1 | frame error; see below |

## The four questions

Every MAC answers these, and they answer them differently. These are this
project's answers.

### 1. `tkeep` on the final beat

`tkeep` is all ones on every beat except the last, where it is contiguous from
the least significant byte: one of `0x01, 0x03, 0x07, 0x0F, 0x1F, 0x3F, 0x7F,
0xFF`. Non-contiguous `tkeep` is illegal and is not handled.

The final beat carries 1 to 8 valid bytes. This is what forces a variable-width
CRC update in a single cycle (ADR 0007) and is the same alignment problem the
header parser solves.

**`header_parser` does not consume `tkeep`.** It takes `in_data`, `in_valid` and
`in_last` only. Classification needs a fixed 46-byte window, and any frame
reaching the DUT is at least 60 bytes, so byte-granular length carries no
information the parser can act on. The consequence is that the parser cannot
distinguish a frame ending mid-header from one padded to the same length; the
golden model can. See `docs/adr/0002-first-order-spec.md`. Blocks that do need
byte granularity -- `crc32_par` above all -- take `keep` directly.

### 2. When the FCS verdict is valid

At `tlast`, and not before. The CRC covers the whole frame, so no verdict exists
until the last byte has arrived.

This is the origin of the cut-through problem. With a parse window of 46 bytes
the egress commit point is 6 beats in, so for any frame longer than 48 bytes
transmission has already begun when the verdict arrives.

### 3. `tuser` semantics

On ingress, `tuser` asserted at `tlast` means the frame's FCS failed or the
frame was aborted upstream. It is only meaningful on the final beat; mid-frame
assertion is illegal.

On egress, the DUT asserts `tuser` at `tlast` to mark a frame as bad. A
downstream MAC is expected to respond by deliberately corrupting the transmitted
FCS so the far end discards it. This is the abort mechanism, and it is the only
place the MAC convention reaches into the RTL rather than the testbench.

### 4. Backpressure

`tready` may deassert on any beat, including mid-frame. The DUT must not drop or
reorder under backpressure. On egress the DUT may be backpressured after it has
committed to a cut-through frame; the resulting buffering requirement is bounded
by the maximum frame size.

## What the BFM supplies

Preamble, SFD, inter-frame gap and the FCS bytes themselves are handled by the
BFM and are not present on the DUT interface. They contribute 20 bytes of
per-frame overhead, which is why minimum-size frames arrive at 14.88 Mpps rather
than 19.53 Mpps, and why the budget is 10.5 cycles per packet at 156.25 MHz.

## Not covered

Pause frames, jumbo frames, alignment errors, deficit idle count, link status,
statistics counters. Out of scope per ADR 0006.
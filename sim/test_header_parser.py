"""Differential regression: header_parser RTL against the OCaml golden model.

Vectors come from bin/gen_vectors.ml -- frame bytes plus what the model says the
DUT must produce. This file drives and compares; it does not know the protocol
and does not reimplement the model. Any divergence is a real disagreement
between two implementations derived from one specification.

Both the verdict AND the reason are compared. The reason mapping is
Golden_model.err_code, defined next to the model so both sides read it from one
place; the encoding is repeated in ERR_NAMES here for messages only.

    make sim                       # default vectors
    make sim VECTORS=... COUNT=... # override
"""

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

# Encoding shared with lib/golden_model.ml (err_code) and bin/gen_rtl.ml.
ERR_NAMES = {
    0: "none",
    1: "short_or_truncated",
    2: "unmatched_selector",
    3: "guard_failed",
    4: "bad_field_value",
    5: "repeat_limit",
}

BEAT_BYTES = 8


def load_vectors(path):
    """Each line: <hex frame> <parsed> <err_code> <key hex or ->."""
    out = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                raise ValueError(f"{path}:{lineno}: expected 4 fields, got {len(parts)}")
            frame_hex, parsed, err, key = parts
            out.append(
                {
                    "n": lineno,
                    "frame": bytes.fromhex(frame_hex),
                    "parsed": int(parsed),
                    "err": int(err),
                    # The model emits no key unless the frame parsed; a partial
                    # key would compare as a well-formed value against whatever
                    # the RTL happened to hold.
                    "key": None if key == "-" else int(key, 16),
                }
            )
    return out


async def drive_frame(dut, frame):
    """One frame, one beat per cycle, first byte in the low byte of in_data.

    No backpressure: header_parser has no tready. The datapath is designed to
    accept a beat every cycle at line rate, so a stall would be a design
    change, not a test parameter.
    """
    beats = [frame[i : i + BEAT_BYTES] for i in range(0, len(frame), BEAT_BYTES)]
    for i, beat in enumerate(beats):
        padded = beat.ljust(BEAT_BYTES, b"\x00")
        dut.in_data.value = int.from_bytes(padded, "little")
        dut.in_valid.value = 1
        dut.in_last.value = 1 if i == len(beats) - 1 else 0
        await RisingEdge(dut.clock)
    dut.in_valid.value = 0
    dut.in_last.value = 0


async def reset(dut):
    """clear is synchronous and must be held with in_valid low, or the beat
    counter advances while the buffer is being cleared."""
    dut.clear.value = 1
    dut.in_valid.value = 0
    dut.in_last.value = 0
    dut.in_data.value = 0
    for _ in range(4):
        await RisingEdge(dut.clock)
    dut.clear.value = 0
    await RisingEdge(dut.clock)


@cocotb.test()
async def differential(dut):
    vec_path = os.environ.get("VECTORS", "vectors.txt")
    if not Path(vec_path).exists():
        raise FileNotFoundError(
            f"{vec_path} not found -- run 'make vectors' first"
        )
    vectors = load_vectors(vec_path)
    dut._log.info(f"{len(vectors)} vectors from {vec_path}")

    cocotb.start_soon(Clock(dut.clock, 6.4, units="ns").start())
    await reset(dut)

    mismatches = []
    stats = {"parsed": 0, "unparseable": 0}

    for v in vectors:
        # Reset between frames: the parser has no inter-frame gap handling, and
        # each vector is an independent classification.
        await reset(dut)
        await drive_frame(dut, v["frame"])

        # Outputs are registered, so the result is valid one cycle after the
        # last beat is consumed. One extra edge covers the register.
        await RisingEdge(dut.clock)

        # hdr_valid is the DUT's own statement that the result means something.
        # Checking it turns a silent sampling-point error into a loud one: a
        # fixed delay that happened to line up would otherwise hide a timing
        # bug in either the design or this harness.
        if not int(dut.hdr_valid.value):
            mismatches.append((v, ["hdr_valid low at the sample point"]))
            if len(mismatches) <= 10:
                dut._log.error(
                    f"packet {v['n']} ({len(v['frame'])} B): hdr_valid low\n"
                    f"  frame: {v['frame'].hex()}"
                )
            continue

        got_parsed = int(dut.hdr_parsed.value)
        got_err = int(dut.hdr_err.value)
        got_key = int(dut.hdr_key.value)

        why = []
        if got_parsed != v["parsed"]:
            why.append(f"parsed {got_parsed} != {v['parsed']}")
        if got_err != v["err"]:
            why.append(
                f"err {got_err} ({ERR_NAMES.get(got_err, '?')}) "
                f"!= {v['err']} ({ERR_NAMES.get(v['err'], '?')})"
            )
        if v["key"] is not None and got_key != v["key"]:
            why.append(f"key {got_key:026x} != {v['key']:026x}")

        if why:
            mismatches.append((v, why))
            if len(mismatches) <= 10:
                dut._log.error(
                    f"packet {v['n']} ({len(v['frame'])} B): {'; '.join(why)}\n"
                    f"  frame: {v['frame'].hex()}"
                )

        stats["parsed" if v["parsed"] else "unparseable"] += 1

    dut._log.info(
        f"{len(vectors)} packets: {stats['parsed']} parsed, "
        f"{stats['unparseable']} unparseable, {len(mismatches)} mismatched"
    )
    assert not mismatches, (
        f"{len(mismatches)}/{len(vectors)} diverged from the golden model"
    )
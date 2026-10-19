#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate Q8.8 saturation-boundary golden vectors for the STDP and output-layer paths.

Usage::

    python3 scripts/gen_golden_q88_boundary.py            # regenerate
    python3 scripts/gen_golden_q88_boundary.py --check    # drift gate; non-zero if stale

This is the HDL half of the Q8.8 contract shared with ``rmems/silicon-bridge``:

* **signed** two's-complement Q8.8 (``0xFF00`` is ``-1.0``, ``0x8000`` is
  ``-128.0``),
* host ``f32`` values **truncate toward zero** at the encoder
  (``scripts/q88.py::encode_q88_signed``, the single codec in this repo),
* every datapath add **saturates, never wraps**, at ``0x7FFF`` / ``0x8000``.

GH#66 already pins ``LifNeuron`` and the ``OutputLayer`` argmax. What it does
not pin is the exact word at a saturation edge on:

* the STDP weight-update path -- ``StdpController`` +/-1 LSB with signed
  saturation, and the same arithmetic through ``StdpWriteback``'s
  RAM read / modify / write, and
* ``OutputLayer``'s per-step saturating accumulator (the GH#66 TB only checks
  the one-hot argmax, never the class score word).

The bit-exact model below is deliberately written from the contract, not from
the RTL: it is plain Python integer arithmetic over ``q88.Q88_RAW_MIN`` /
``q88.Q88_RAW_MAX``. Testbenches ``tb_StdpController_q88``,
``tb_StdpWriteback_q88`` and ``tb_OutputLayer_q88`` replay the emitted
``.mem`` images via ``$readmemh`` and ``$fatal`` on any mismatch.

All outputs land in ``spikenaut-core-sv/mem/golden/q88b_*``. Do not hand-edit
them; see ``docs/golden-lif-vectors.md`` (Q8.8 saturation boundaries section).
"""

from __future__ import annotations

import argparse
import filecmp
import json
import math
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import q88

REPO_ROOT = Path(__file__).resolve().parent.parent
GOLDEN_DIR = REPO_ROOT / "spikenaut-core-sv" / "mem" / "golden"

RAW_MAX = q88.Q88_RAW_MAX  # 0x7FFF
RAW_MIN = q88.Q88_RAW_MIN  # 0x8000

# ---------------------------------------------------------------------------
# Bit-exact model
# ---------------------------------------------------------------------------

#: STDP op codes as written to ``q88b_*_op.mem``.
OP_HOLD = 0  # no LTP / LTD condition: weight passes through, we low
OP_LTP = 1  # pre-then-post: +1 LSB, saturate at 0x7FFF
OP_LTD = 2  # post-then-pre: -1 LSB, saturate at 0x8000
OP_BOTH = 3  # LTP and LTD conditions in the same tick: LTP has priority
OP_NAMES = {OP_HOLD: "hold", OP_LTP: "ltp", OP_LTD: "ltd", OP_BOTH: "ltp_priority"}


def _check_raw(raw: int) -> int:
    if not (RAW_MIN <= raw <= RAW_MAX):
        raise ValueError(f"raw {raw} is outside signed Q8.8 range")
    return raw


def sat16(wide: int) -> int:
    """Clamp an unbounded integer into the signed Q8.8 raw range (saturate, never wrap)."""
    return max(RAW_MIN, min(RAW_MAX, wide))


def sat_add(a: int, b: int) -> int:
    """Signed Q8.8 saturating add of two raw words."""
    return sat16(_check_raw(a) + _check_raw(b))


def stdp_update(weight: int, op: int) -> tuple[int, bool]:
    """One STDP weight update. Returns ``(new_weight, write_enable)``.

    ``write_enable`` is true only when the weight actually changes: a
    saturated LTP at ``0x7FFF`` (or LTD at ``0x8000``) holds the weight and
    does not write, per the StdpController contract (GH#55 / GH#73).
    """
    _check_raw(weight)
    if op in (OP_LTP, OP_BOTH):
        new = sat16(weight + 1)
    elif op == OP_LTD:
        new = sat16(weight - 1)
    elif op == OP_HOLD:
        new = weight
    else:
        raise ValueError(f"unknown STDP op {op}")
    return new, new != weight


def output_layer_scores(
    weights: list[int], bitmap: int, num_neurons: int, num_classes: int
) -> list[int]:
    """OutputLayer class scores for one tick.

    ``weights`` is row-major ``addr = neuron * num_classes + class``. Each
    class accumulates the weights of spiking neurons in ascending neuron
    order, **saturating at every step** -- the result is order-dependent by
    design, and a single final clamp gives different words (see
    ``final_clamp`` vectors).
    """
    if len(weights) != num_neurons * num_classes:
        raise ValueError("weights length does not match num_neurons * num_classes")
    acc = [0] * num_classes
    for neuron in range(num_neurons):
        if not (bitmap >> neuron) & 1:
            continue
        for cls in range(num_classes):
            acc[cls] = sat_add(acc[cls], weights[neuron * num_classes + cls])
    return acc


def argmax_onehot(scores: list[int]) -> int:
    """One-hot argmax, ties won by the lowest class index."""
    best = 0
    for cls in range(1, len(scores)):
        if scores[cls] > scores[best]:
            best = cls
    return 1 << best


# ---------------------------------------------------------------------------
# Vector sets
# ---------------------------------------------------------------------------

NUM_NEURONS = 16
NUM_CLASSES = 3
WB_GROUP = 4  # tb_StdpWriteback_q88 runs NUM_NEURONS=4: one vector per post row


@dataclass(frozen=True)
class Weight:
    raw: int
    origin: str  # "raw" or the f32 literal it was encoded from


def _raw(word: int) -> Weight:
    return Weight(q88.hex_to_raw(f"{word:04X}"), "raw")


def _f32(value: float, label: str) -> Weight:
    # Weights are parameter words, so they use the full-range parameter
    # encoder (silicon-bridge encode_q88_signed_full; -128.0 -> 0x8000), not
    # the +/-127.99 UART stimulus clamp (silicon-bridge
    # docs/host-hdl-contract.md, "UART v3.0 boundary").
    return Weight(q88.encode_q88_signed_full(value), f"f32:{label}")


#: Boundary weights. Raw words cover the two saturation edges +/-1 LSB plus
#: zero / +1 LSB / -1 LSB. The f32-sourced words tie the parameter encoder's
#: truncate-toward-zero and its i16 saturation (``-128.0`` -> ``0x8000``,
#: ``127.99609375`` -> ``0x7FFF``, ``+/-1e6`` saturating) into the same replay.
BOUNDARY_WEIGHTS: tuple[Weight, ...] = (
    _raw(0x7FFD),
    _raw(0x7FFE),
    _raw(0x7FFF),
    _raw(0x8000),
    _raw(0x8001),
    _raw(0x8002),
    _raw(0x0000),
    _raw(0x0001),
    _raw(0xFFFF),
    _raw(0xFFFE),
    _f32(127.99, "127.99"),
    _f32(-127.99, "-127.99"),
    _f32(127.99609375, "127.99609375"),
    _f32(-128.0, "-128.0"),
    _f32(1.0e6, "1e6"),
    _f32(-1.0e6, "-1e6"),
    _f32(0.999, "0.999"),
    _f32(-0.999, "-0.999"),
    _f32(1.0 / 256.0, "1/256"),
    _f32(-1.0 / 256.0, "-1/256"),
    _f32(math.nan, "nan"),
    _f32(-1.0, "-1.0"),
)

STDP_OPS = (OP_HOLD, OP_LTP, OP_LTD, OP_BOTH)


def stdp_vectors() -> list[dict]:
    """Every boundary weight under every op (StdpController replay)."""
    rows = []
    for op in STDP_OPS:
        for w in BOUNDARY_WEIGHTS:
            new, we = stdp_update(w.raw, op)
            rows.append(
                {"op": op, "weight_in": w.raw, "exp_weight": new, "exp_we": we, "origin": w.origin}
            )
    return rows


def writeback_vectors() -> list[dict]:
    """Same set, grouped WB_GROUP at a time with a uniform op per group.

    ``tb_StdpWriteback_q88`` seeds one column of a 4x4 WeightRam with a group
    (one weight per post neuron) and runs one closed-loop STDP tick. Groups
    are padded by wrapping around the boundary list so every group is full.
    """
    rows = []
    n = len(BOUNDARY_WEIGHTS)
    padded = n + (-n) % WB_GROUP
    for op in STDP_OPS:
        for i in range(padded):
            w = BOUNDARY_WEIGHTS[i % n]
            new, we = stdp_update(w.raw, op)
            rows.append(
                {"op": op, "weight_in": w.raw, "exp_weight": new, "exp_we": we, "origin": w.origin}
            )
    return rows


def _seq(*words: int) -> list[int]:
    """Per-neuron weight sequence for one class, zero-padded to NUM_NEURONS."""
    vals = [q88.hex_to_raw(f"{w:04X}") for w in words]
    return vals + [0] * (NUM_NEURONS - len(vals))


def _bits(n: int) -> int:
    return (1 << n) - 1


#: Output-layer cases: (name, bitmap, [class0 seq, class1 seq, class2 seq]).
#: Every sequence lists the weight of neuron 0, 1, 2, ... for that class.
OUTPUT_CASES: tuple[tuple[str, int, list[list[int]]], ...] = (
    ("zero_tie", 0xFFFF, [_seq(), _seq(), _seq()]),
    ("pos_edge_exact_over_hold",
     0x0003, [_seq(0x7FFE, 0x0001), _seq(0x7FFF, 0x0001), _seq(0x7FFF, 0x0000)]),
    ("pos_edge_back_off",
     0x0003, [_seq(0x7FFF, 0xFFFF), _seq(0x7FFF, 0x7FFF), _seq(0x0001, 0x7FFF)]),
    ("neg_edge_exact_over_hold",
     0x0003, [_seq(0x8001, 0xFFFF), _seq(0x8000, 0xFFFF), _seq(0x8000, 0x0000)]),
    ("neg_edge_back_off",
     0x0003, [_seq(0x8000, 0x0001), _seq(0x8000, 0x8000), _seq(0xFFFF, 0x8000)]),
    ("cross_extremes",
     0x0003, [_seq(0x7FFF, 0x8000), _seq(0x8000, 0x7FFF), _seq(0x0001, 0xFFFF)]),
    # Per-step saturation is order-dependent. Every class here has the same
    # wide sum (+/-32768), so a single final clamp would give 0x7FFF / 0x8000
    # on all three classes; per-step saturation gives 7EFF/7EFF/7FFF and
    # 8100/8100/8000, which also moves the positive argmax to class 2.
    ("final_clamp_pos",
     0x0007, [_seq(0x7F00, 0x0200, 0xFF00), _seq(0x0200, 0x7F00, 0xFF00), _seq(0xFF00, 0x7F00, 0x0200)]),
    ("final_clamp_neg",
     0x0007, [_seq(0x8100, 0xFE00, 0x0100), _seq(0xFE00, 0x8100, 0x0100), _seq(0x0100, 0x8100, 0xFE00)]),
    ("all16_extremes",
     0xFFFF, [_seq(*([0x7FFF] * 16)), _seq(*([0x8000] * 16)), _seq(*([0x0001] * 16))]),
    ("all16_lsb_neg",
     0xFFFF, [_seq(*([0xFFFF] * 16)), _seq(*([0x0800] * 16)), _seq(*([0xF800] * 16))]),
    # Masked neurons must contribute nothing: the big words sit on neuron 1,
    # which is not in the bitmap.
    ("masked_extremes",
     0x0005, [_seq(0x0001, 0x7FFF, 0xFFFF), _seq(0xFFFF, 0x8000, 0x0001), _seq(0x0000, 0x7FFF, 0x0000)]),
    ("neg_argmax_tie",
     0x0001, [_seq(0x8000), _seq(0x8000), _seq(0x8001)]),
    ("sat_then_recover_neg_wins",
     0x000F, [_seq(0x7FFF, 0x7FFF, 0x8000, 0x8000), _seq(0x8000, 0x8000, 0x7FFF, 0x0001), _seq(0x0001, 0x0001, 0xFFFF, 0x0000)]),
)


def output_vectors() -> list[dict]:
    rows = []
    for name, bitmap, per_class in OUTPUT_CASES:
        weights = [per_class[c][n] for n in range(NUM_NEURONS) for c in range(NUM_CLASSES)]
        scores = output_layer_scores(weights, bitmap, NUM_NEURONS, NUM_CLASSES)
        rows.append(
            {
                "name": name,
                "bitmap": bitmap,
                "weights": weights,
                "exp_scores": scores,
                "exp_result": argmax_onehot(scores),
            }
        )
    return rows


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

BANNER = (
    "GENERATED by scripts/gen_golden_q88_boundary.py -- do not edit by hand.\n"
    "Regenerate: python3 scripts/gen_golden_q88_boundary.py"
)

GENERATED_NAMES = (
    "q88b_stdp_weight_in.mem",
    "q88b_stdp_op.mem",
    "q88b_stdp_exp_weight.mem",
    "q88b_stdp_exp_we.mem",
    "q88b_stdp_count.mem",
    "q88b_wb_weight_in.mem",
    "q88b_wb_op.mem",
    "q88b_wb_exp_weight.mem",
    "q88b_wb_exp_we.mem",
    "q88b_wb_count.mem",
    "q88b_out_weights.mem",
    "q88b_out_bitmap.mem",
    "q88b_out_exp_scores.mem",
    "q88b_out_exp_result.mem",
    "q88b_out_count.mem",
    "q88_boundary_vectors.json",
)


def _emit_stdp(out: Path, prefix: str, rows: list[dict], what: str) -> None:
    hdr = f"{BANNER}\n{what}"
    q88.write_mem(out / f"{prefix}_weight_in.mem", [r["weight_in"] for r in rows],
                  header=f"{hdr}\nweight_in (signed Q8.8 raw)")
    q88.write_words(out / f"{prefix}_op.mem", [r["op"] for r in rows],
                    header=f"{hdr}\nop: 0=hold 1=ltp 2=ltd 3=ltp_priority")
    q88.write_mem(out / f"{prefix}_exp_weight.mem", [r["exp_weight"] for r in rows],
                  header=f"{hdr}\nexpected weight after the tick (signed Q8.8 raw)")
    q88.write_words(out / f"{prefix}_exp_we.mem", [int(r["exp_we"]) for r in rows],
                    header=f"{hdr}\nexpected write enable (1 = weight changed)")
    q88.write_words(out / f"{prefix}_count.mem", [len(rows)], header=f"{hdr}\nvector count")


def emit(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    stdp = stdp_vectors()
    wb = writeback_vectors()
    outl = output_vectors()

    _emit_stdp(out, "q88b_stdp", stdp, "StdpController boundary vectors (tb_StdpController_q88)")
    _emit_stdp(out, "q88b_wb", wb,
               f"StdpWriteback boundary vectors, groups of {WB_GROUP} with uniform op (tb_StdpWriteback_q88)")

    hdr = f"{BANNER}\nOutputLayer accumulator boundary vectors (tb_OutputLayer_q88)"
    q88.write_mem(out / "q88b_out_weights.mem", [w for r in outl for w in r["weights"]],
                  header=f"{hdr}\n{NUM_NEURONS * NUM_CLASSES} words per case, addr = neuron*{NUM_CLASSES} + class")
    q88.write_words(out / "q88b_out_bitmap.mem", [r["bitmap"] for r in outl],
                    header=f"{hdr}\nspike_bitmap per case")
    q88.write_mem(out / "q88b_out_exp_scores.mem", [s for r in outl for s in r["exp_scores"]],
                  header=f"{hdr}\n{NUM_CLASSES} expected class_acc words per case (signed Q8.8 raw)")
    q88.write_words(out / "q88b_out_exp_result.mem", [r["exp_result"] for r in outl],
                    header=f"{hdr}\nexpected one-hot argmax (ties -> lowest class)")
    q88.write_words(out / "q88b_out_count.mem", [len(outl)], header=f"{hdr}\ncase count")

    def hexw(raw: int) -> str:
        return q88.raw_to_hex(raw)

    manifest = {
        "generated_by": "scripts/gen_golden_q88_boundary.py",
        "contract": {
            "format": "signed two's-complement Q8.8",
            "encoder": "truncate toward zero, saturate at the i16 limits "
                       "(scripts/q88.py encode_q88_signed_full; parameter words)",
            "datapath": "saturate at 0x7FFF / 0x8000, never wrap",
        },
        "stdp": [
            {"index": i, "op": OP_NAMES[r["op"]], "weight_in": hexw(r["weight_in"]),
             "exp_weight": hexw(r["exp_weight"]), "exp_we": r["exp_we"], "origin": r["origin"]}
            for i, r in enumerate(stdp)
        ],
        "writeback_group_size": WB_GROUP,
        "writeback_count": len(wb),
        "output_layer": [
            {"index": i, "name": r["name"], "bitmap": f"{r['bitmap']:04X}",
             "exp_scores": [hexw(s) for s in r["exp_scores"]], "exp_result": f"{r['exp_result']:03b}"}
            for i, r in enumerate(outl)
        ],
    }
    (out / "q88_boundary_vectors.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="do not write; exit non-zero if regenerating would change committed vectors")
    args = parser.parse_args(argv)

    if not args.check:
        emit(GOLDEN_DIR)
        print(f"wrote {len(GENERATED_NAMES)} files to {GOLDEN_DIR.relative_to(REPO_ROOT)}/")
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        fresh = Path(tmp)
        emit(fresh)
        stale = [
            name for name in GENERATED_NAMES
            if not (GOLDEN_DIR / name).exists()
            or not filecmp.cmp(fresh / name, GOLDEN_DIR / name, shallow=False)
        ]
    if stale:
        print("Q8.8 boundary vectors are out of date:", file=sys.stderr)
        for name in stale:
            print(f"  {(GOLDEN_DIR / name).relative_to(REPO_ROOT)}", file=sys.stderr)
        print("\nRegenerate with: python3 scripts/gen_golden_q88_boundary.py", file=sys.stderr)
        return 1
    print(f"Q8.8 boundary vectors up to date ({len(GENERATED_NAMES)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

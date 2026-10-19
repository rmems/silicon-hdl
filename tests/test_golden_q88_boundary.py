# SPDX-License-Identifier: MIT OR Apache-2.0
"""Model + drift-gate tests for the Q8.8 saturation-boundary golden vectors.

Covers ``scripts/gen_golden_q88_boundary.py``:

1. **The model** -- ``sat16`` / ``sat_add`` / ``stdp_update`` /
   ``output_layer_scores`` agree with the contract (signed Q8.8, saturate never
   wrap) at every boundary word, independently of the generator's own tables.
2. **The committed vectors** -- regenerating is a no-op (``--check``), and the
   ``.mem`` images the testbenches read decode back to the model's answers.
3. **Discrimination** -- deliberately wrong models (wrapping add, unsigned
   saturation, final-only clamp, write-on-saturate) produce *different*
   vectors, so the images actually pin the semantics.

The RTL side is ``tb_StdpController_q88`` / ``tb_StdpWriteback_q88`` /
``tb_OutputLayer_q88`` under Verilator.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import gen_golden_q88_boundary as gen  # noqa: E402
import q88  # noqa: E402

GOLDEN_DIR = REPO_ROOT / "spikenaut-core-sv" / "mem" / "golden"

REQUIRED_WORDS = {0x7FFF, 0x8000, 0x0000, 0x0001, 0xFFFF, 0x7FFE, 0x8001}


def s16(word: int) -> int:
    return q88.hex_to_raw(f"{word:04X}")


# --------------------------------------------------------------------------
# 1. Model
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "value, expected",
    [
        # silicon-bridge encode_q88_signed_full / format_q88_hex doctest vectors
        (-1.0, 0xFF00),
        (-0.5, 0xFF80),
        (0.0, 0x0000),
        (0.5, 0x0080),
        (1.0, 0x0100),
        (-128.0, 0x8000),
        (127.99609375, 0x7FFF),
        # truncate toward zero, saturate at the i16 limits, NaN -> 0
        (-0.999, 0xFF01),
        (0.999, 0x00FF),
        (128.0, 0x7FFF),
        (-128.5, 0x8000),
        (1.0e6, 0x7FFF),
        (-1.0e6, 0x8000),
        (1.0e40, 0x7FFF),
        (float("-inf"), 0x8000),
        (float("nan"), 0x0000),
    ],
)
def test_encode_q88_signed_full_matches_bridge(value: float, expected: int) -> None:
    assert q88.encode_q88_signed_full(value) & 0xFFFF == expected


def test_full_encoder_round_trips_every_word() -> None:
    for raw in range(q88.Q88_RAW_MIN, q88.Q88_RAW_MAX + 1):
        assert q88.encode_q88_signed_full(q88.q88_signed_to_f32(raw)) == raw


@pytest.mark.parametrize(
    "value, uart, full",
    [
        (-128.0, 0x8003, 0x8000),
        (127.99609375, 0x7FFD, 0x7FFF),
        (-127.99609375, 0x8003, 0x8001),
        (127.995, 0x7FFD, 0x7FFE),
        (-1.0e6, 0x8003, 0x8000),
        (127.99, 0x7FFD, 0x7FFD),
    ],
)
def test_uart_clamp_and_parameter_encoder_diverge_only_beyond_127_99(
    value: float, uart: int, full: int
) -> None:
    # silicon-bridge docs/host-hdl-contract.md: "boundary values such as
    # -128.0 have different UART and .mem encodings".
    assert q88.encode_q88_signed(value) & 0xFFFF == uart
    assert q88.encode_q88_signed_full(value) & 0xFFFF == full


@pytest.mark.xfail(
    strict=True,
    reason=(
        "FINDING: gen_golden_lif_vectors encodes parameter words with the "
        "UART +/-127.99 clamp (q88.encode_q88_signed). A bank word at the "
        "signed edges -- e.g. 0x8000, which silicon-bridge's .mem writer emits "
        "for -128.0 -- fails its f32 round-trip tripwire (0x8000 -> -128.0 -> "
        "0x8003). Latent: no pinned exp-025 word is affected."
    ),
)
@pytest.mark.parametrize("raw", [q88.Q88_RAW_MIN, q88.Q88_RAW_MAX, -32767, 32766])
def test_lif_generator_parameter_round_trip_at_edges(raw: int) -> None:
    assert q88.encode_q88_signed(q88.q88_signed_to_f32(raw)) == raw


def test_contract_constants_match_codec() -> None:
    assert gen.RAW_MAX == 0x7FFF == q88.Q88_RAW_MAX
    assert gen.RAW_MIN == -0x8000 == q88.Q88_RAW_MIN


@pytest.mark.parametrize(
    "wide, expected",
    [
        (32767, 32767),
        (32768, 32767),
        (65535, 32767),
        (-32768, -32768),
        (-32769, -32768),
        (-65536, -32768),
        (0, 0),
        (-1, -1),
    ],
)
def test_sat16_saturates_never_wraps(wide: int, expected: int) -> None:
    assert gen.sat16(wide) == expected


@pytest.mark.parametrize(
    "a, b, expected",
    [
        (0x7FFF, 0x0001, 0x7FFF),
        (0x7FFE, 0x0001, 0x7FFF),
        (0x7FFF, 0xFFFF, 0x7FFE),
        (0x8000, 0xFFFF, 0x8000),
        (0x8001, 0xFFFF, 0x8000),
        (0x8000, 0x0001, 0x8001),
        (0x7FFF, 0x8000, 0xFFFF),
        (0x7FFF, 0x7FFF, 0x7FFF),
        (0x8000, 0x8000, 0x8000),
        (0xFFFF, 0x0001, 0x0000),
    ],
)
def test_sat_add_boundaries(a: int, b: int, expected: int) -> None:
    assert gen.sat_add(s16(a), s16(b)) == s16(expected)


def test_sat_add_rejects_out_of_range_operands() -> None:
    with pytest.raises(ValueError):
        gen.sat_add(32768, 0)
    with pytest.raises(ValueError):
        gen.sat_add(0, -32769)


@pytest.mark.parametrize(
    "weight, op, expected, we",
    [
        (0x7FFE, gen.OP_LTP, 0x7FFF, True),
        (0x7FFF, gen.OP_LTP, 0x7FFF, False),
        (0x8000, gen.OP_LTP, 0x8001, True),
        (0xFFFF, gen.OP_LTP, 0x0000, True),
        (0x8001, gen.OP_LTD, 0x8000, True),
        (0x8000, gen.OP_LTD, 0x8000, False),
        (0x7FFF, gen.OP_LTD, 0x7FFE, True),
        (0x0000, gen.OP_LTD, 0xFFFF, True),
        (0x7FFF, gen.OP_HOLD, 0x7FFF, False),
        (0x8000, gen.OP_HOLD, 0x8000, False),
        (0x7FFF, gen.OP_BOTH, 0x7FFF, False),
        (0x8000, gen.OP_BOTH, 0x8001, True),
    ],
)
def test_stdp_update(weight: int, op: int, expected: int, we: bool) -> None:
    assert gen.stdp_update(s16(weight), op) == (s16(expected), we)


def test_stdp_update_rejects_unknown_op() -> None:
    with pytest.raises(ValueError):
        gen.stdp_update(0, 7)


def test_output_scores_saturate_per_step_in_neuron_order() -> None:
    # Two classes, three neurons. Class 0 saturates then backs off; a final
    # clamp of the wide sum (0x7F00 + 0x0200 - 0x0100 = 0x8000 -> 0x7FFF) would
    # give a different word.
    weights = [s16(w) for w in (0x7F00, 0x0000, 0x0200, 0x0000, 0xFF00, 0x0000)]
    assert gen.output_layer_scores(weights, 0b111, 3, 2) == [s16(0x7EFF), 0]
    # Masked neuron contributes nothing.
    assert gen.output_layer_scores(weights, 0b101, 3, 2) == [s16(0x7E00), 0]


def test_argmax_ties_go_to_lowest_class() -> None:
    assert gen.argmax_onehot([5, 5, 5]) == 0b001
    assert gen.argmax_onehot([s16(0x8000), s16(0x8000), s16(0x8001)]) == 0b100
    assert gen.argmax_onehot([0, 7, 7]) == 0b010


# --------------------------------------------------------------------------
# 2. Committed vectors
# --------------------------------------------------------------------------


def test_committed_vectors_are_current() -> None:
    result = subprocess.run(
        [sys.executable, "scripts/gen_golden_q88_boundary.py", "--check"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_boundary_set_covers_required_words() -> None:
    covered = {w.raw & 0xFFFF for w in gen.BOUNDARY_WEIGHTS}
    assert REQUIRED_WORDS <= covered
    # +/-1 LSB on both sides of both edges is reachable via the op set too.
    stdp = q88.read_words(GOLDEN_DIR / "q88b_stdp_weight_in.mem")
    assert REQUIRED_WORDS <= set(stdp)


def _stdp_files(prefix: str) -> list[tuple[int, int, int, int]]:
    w = q88.read_mem(GOLDEN_DIR / f"{prefix}_weight_in.mem")
    op = q88.read_words(GOLDEN_DIR / f"{prefix}_op.mem")
    exp = q88.read_mem(GOLDEN_DIR / f"{prefix}_exp_weight.mem")
    we = q88.read_words(GOLDEN_DIR / f"{prefix}_exp_we.mem")
    (count,) = q88.read_words(GOLDEN_DIR / f"{prefix}_count.mem")
    assert len(w) == len(op) == len(exp) == len(we) == count
    return list(zip(w, op, exp, we))


@pytest.mark.parametrize("prefix", ["q88b_stdp", "q88b_wb"])
def test_stdp_images_decode_to_model(prefix: str) -> None:
    rows = _stdp_files(prefix)
    for w, op, exp, we in rows:
        assert gen.stdp_update(w, op) == (exp, bool(we))
    # Every op and both saturating holds are present.
    assert {op for _, op, _, _ in rows} == set(gen.STDP_OPS)
    assert (s16(0x7FFF), gen.OP_LTP, s16(0x7FFF), 0) in rows
    assert (s16(0x8000), gen.OP_LTD, s16(0x8000), 0) in rows


def test_writeback_groups_have_uniform_op() -> None:
    rows = _stdp_files("q88b_wb")
    assert len(rows) % gen.WB_GROUP == 0
    for g in range(0, len(rows), gen.WB_GROUP):
        assert len({op for _, op, _, _ in rows[g : g + gen.WB_GROUP]}) == 1


def test_output_images_decode_to_model() -> None:
    weights = q88.read_mem(GOLDEN_DIR / "q88b_out_weights.mem")
    bitmaps = q88.read_words(GOLDEN_DIR / "q88b_out_bitmap.mem")
    scores = q88.read_mem(GOLDEN_DIR / "q88b_out_exp_scores.mem")
    results = q88.read_words(GOLDEN_DIR / "q88b_out_exp_result.mem")
    (count,) = q88.read_words(GOLDEN_DIR / "q88b_out_count.mem")
    pairs = gen.NUM_NEURONS * gen.NUM_CLASSES
    assert len(weights) == count * pairs
    assert len(bitmaps) == len(results) == count
    assert len(scores) == count * gen.NUM_CLASSES
    for i in range(count):
        s = gen.output_layer_scores(weights[i * pairs : (i + 1) * pairs], bitmaps[i],
                                    gen.NUM_NEURONS, gen.NUM_CLASSES)
        assert s == scores[i * gen.NUM_CLASSES : (i + 1) * gen.NUM_CLASSES]
        assert gen.argmax_onehot(s) == results[i]
    assert gen.RAW_MAX in scores and gen.RAW_MIN in scores


def test_tb_vector_capacity() -> None:
    # tb_*_q88 size their arrays with MAX_VECTORS = 512 / MAX_CASES = 64.
    assert len(gen.stdp_vectors()) <= 512
    assert len(gen.writeback_vectors()) <= 512
    assert len(gen.output_vectors()) <= 64


# --------------------------------------------------------------------------
# 3. Discrimination: wrong models must disagree with the committed vectors
# --------------------------------------------------------------------------


def _wrap16(x: int) -> int:
    return ((x + 0x8000) & 0xFFFF) - 0x8000


def _unsigned_sat(x_signed: int, delta: int) -> int:
    u = (x_signed & 0xFFFF) + delta
    return s16(max(0, min(0xFFFF, u)))


def _scores_with(add, weights: list[int], bitmap: int) -> list[int]:
    acc = [0] * gen.NUM_CLASSES
    for n in range(gen.NUM_NEURONS):
        if (bitmap >> n) & 1:
            for c in range(gen.NUM_CLASSES):
                acc[c] = add(acc[c], weights[n * gen.NUM_CLASSES + c])
    return acc


def _final_clamp_scores(weights: list[int], bitmap: int) -> list[int]:
    acc = _scores_with(lambda a, b: a + b, weights, bitmap)
    return [gen.sat16(a) for a in acc]


def test_wrapping_stdp_is_caught() -> None:
    rows = _stdp_files("q88b_stdp")
    mismatches = 0
    for w, op, exp, _ in rows:
        delta = {gen.OP_HOLD: 0, gen.OP_LTP: 1, gen.OP_LTD: -1, gen.OP_BOTH: 1}[op]
        mismatches += _wrap16(w + delta) != exp
    assert mismatches >= 2


def test_unsigned_saturation_stdp_is_caught() -> None:
    rows = _stdp_files("q88b_stdp")
    mismatches = 0
    for w, op, exp, _ in rows:
        delta = {gen.OP_HOLD: 0, gen.OP_LTP: 1, gen.OP_LTD: -1, gen.OP_BOTH: 1}[op]
        mismatches += _unsigned_sat(w, delta) != exp
    assert mismatches >= 4


def test_write_on_saturate_is_caught() -> None:
    rows = _stdp_files("q88b_stdp")
    assert any(op != gen.OP_HOLD and not we for _, op, _, we in rows)


@pytest.mark.parametrize(
    "wrong",
    [
        pytest.param(lambda w, b: _scores_with(lambda x, y: _wrap16(x + y), w, b), id="wrapping"),
        pytest.param(_final_clamp_scores, id="final_clamp_only"),
    ],
)
def test_wrong_accumulators_are_caught(wrong) -> None:
    caught = 0
    for r in gen.output_vectors():
        caught += wrong(r["weights"], r["bitmap"]) != r["exp_scores"]
    assert caught >= 2

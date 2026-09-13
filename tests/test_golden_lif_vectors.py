# SPDX-License-Identifier: MIT OR Apache-2.0
"""Drift gate for the GH#66 golden LIF / output-layer vectors.

Three separate things can drift, and each gets its own coverage here:

1. **The codec** -- ``scripts/q88.py`` must keep agreeing with silicon-bridge's
   ``encode_q88_signed``. Those assertions are copied verbatim from that
   crate's own unit tests.
2. **The committed vectors** -- regenerating must be a no-op. If the reference
   model, the codec, or the pinned bank changes, the vectors have to be
   refreshed in the same commit.
3. **The semantics the vectors actually pin down** -- replaying them through
   deliberately wrong LIF variants must produce a *different* trace. Without
   this, the vectors could be perfectly reproducible and still assert nothing
   interesting.

The RTL side is covered by ``tb_LifNeuron_golden`` / ``tb_OutputLayer_golden``
under Verilator; see ``docs/golden-lif-vectors.md``.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import gen_golden_lif_vectors as gen  # noqa: E402
import lif_reference as lif  # noqa: E402
import q88  # noqa: E402

GOLDEN_DIR = REPO_ROOT / "spikenaut-core-sv" / "mem" / "golden"
BANK_DIR = REPO_ROOT / "spikenaut-core-sv" / "mem"


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads((GOLDEN_DIR / "golden_vectors.json").read_text())


@pytest.fixture(scope="module")
def golden_ticks() -> list[tuple]:
    """The committed tick stream, read back out of the ``.mem`` images.

    Deliberately read from the files rather than from the generator, so these
    tests exercise the artifacts the testbenches actually consume.
    """
    weights = q88.read_mem(GOLDEN_DIR / "lif_golden_weights.mem")
    thresholds = q88.read_mem(GOLDEN_DIR / "lif_golden_thresholds.mem")
    leaks = q88.read_mem(GOLDEN_DIR / "lif_golden_leaks.mem")
    spike_ins = q88.read_words(GOLDEN_DIR / "lif_golden_spike_in.mem")
    resets = q88.read_words(GOLDEN_DIR / "lif_golden_reset.mem")
    return [
        (w, t, lk, bool(si), bool(r))
        for w, t, lk, si, r in zip(weights, thresholds, leaks, spike_ins, resets)
    ]


@pytest.fixture(scope="module")
def golden_expectations() -> tuple[list[int], list[int]]:
    membrane = q88.read_mem(GOLDEN_DIR / "lif_golden_exp_membrane.mem")
    spike = q88.read_mem(GOLDEN_DIR / "lif_golden_exp_spike.mem")
    return membrane, spike


# --------------------------------------------------------------------------
# 1. Codec
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        # Copied from silicon-bridge src/fpga_export.rs `test_q88_signed_*`.
        (0.0, 0),
        (1.0, 256),
        (-1.0, -256),
        (0.5, 128),
        (-0.5, -128),
        (1.0 / 256.0, 1),
        (-1.0 / 256.0, -1),
        (0.999, 255),
        (-0.999, -255),
        (q88.Q88_CLAMP_MAX, 32765),
        (q88.Q88_CLAMP_MIN, -32765),
    ],
)
def test_encoder_matches_silicon_bridge(value: float, expected: int) -> None:
    """Our signed Q8.8 encoder must agree with silicon-bridge's, word for word."""
    assert q88.encode_q88_signed(value) == expected


def test_encoder_clamps_and_handles_nan() -> None:
    assert q88.encode_q88_signed(1e9) == 32765
    assert q88.encode_q88_signed(-1e9) == -32765
    assert q88.encode_q88_signed(float("nan")) == 0
    assert q88.encode_q88_signed(float("inf")) == 32765


def test_dale_inhibitory_word_is_negative_one() -> None:
    """The word this whole issue exists for: 0xFF00 is -1.0, never +65280."""
    assert q88.raw_to_hex(q88.encode_q88_signed(-1.0)) == "FF00"
    assert q88.hex_to_raw("FF00") == -256
    assert q88.q88_signed_to_f32(q88.hex_to_raw("FF00")) == -1.0


@pytest.mark.parametrize(
    "image",
    [
        "merged_v2_weights.mem",
        "merged_v2_thresholds.mem",
        "merged_v2_decay.mem",
        "merged_v2_output_weights.mem",
    ],
)
def test_bank_words_round_trip_through_f32(image: str) -> None:
    """f32 -> Q8.8 must be lossless for every word in the pinned bank.

    This is what makes the ``f32 -> Q8.8 -> .mem`` leg of the golden path real:
    the generator decodes committed words to f32 and re-encodes them, so a
    lossy codec would ship a weight the FPGA never sees.
    """
    for index, raw in enumerate(q88.read_mem(BANK_DIR / image)):
        assert q88.encode_q88_signed(q88.q88_signed_to_f32(raw)) == raw, (
            f"{image}[{index}] = {q88.raw_to_hex(raw)} does not survive the f32 round trip"
        )


# --------------------------------------------------------------------------
# 2. The committed vectors are reproducible and self-consistent
# --------------------------------------------------------------------------


def test_regenerating_is_a_no_op() -> None:
    """``--check`` is the drift gate; it must pass on a clean tree."""
    result = subprocess.run(
        [sys.executable, "scripts/gen_golden_lif_vectors.py", "--check"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        "golden vectors are stale -- run: python3 scripts/gen_golden_lif_vectors.py\n"
        + result.stdout
        + result.stderr
    )


def test_generator_is_deterministic() -> None:
    """Two runs of the generator must produce identical output (no seeds, no clocks)."""
    bank = gen.Bank()
    first = gen.encode_scenarios(gen.build_scenarios(bank), bank)
    second = gen.encode_scenarios(gen.build_scenarios(bank), bank)
    assert first == second


@pytest.mark.parametrize(
    "name",
    [
        "lif_golden_weights.mem",
        "lif_golden_thresholds.mem",
        "lif_golden_leaks.mem",
        "lif_golden_spike_in.mem",
        "lif_golden_reset.mem",
        "lif_golden_exp_membrane.mem",
        "lif_golden_exp_spike.mem",
    ],
)
def test_lif_images_all_have_the_declared_length(name: str) -> None:
    """Every LIF image holds exactly as many words as the count file declares.

    The testbenches cannot check this themselves: ``$readmemh`` does not report
    how many words it loaded, and Verilator zero-initialises the entries it
    never wrote, so the usual ``$isunknown`` probe past the end is useless.
    """
    declared = q88.read_mem(GOLDEN_DIR / "lif_golden_count.mem")[0]
    assert len(q88.read_mem(GOLDEN_DIR / name)) == declared


@pytest.mark.parametrize(
    "name", ["outlayer_golden_bitmap.mem", "outlayer_golden_exp_result.mem"]
)
def test_output_layer_images_all_have_the_declared_length(name: str) -> None:
    declared = q88.read_mem(GOLDEN_DIR / "outlayer_golden_count.mem")[0]
    assert len(q88.read_mem(GOLDEN_DIR / name)) == declared


def test_generated_files_carry_spdx_and_a_do_not_edit_banner() -> None:
    for name in gen.GENERATED_NAMES:
        text = (GOLDEN_DIR / name).read_text()
        if name.endswith(".json"):
            assert "do_not_edit" in text
            continue
        assert text.startswith("// SPDX-License-Identifier: MIT OR Apache-2.0")
        assert "GENERATED FILE" in text


def test_manifest_pins_the_spikenaut_bank(manifest: dict) -> None:
    assert manifest["bank"]["commit"] == gen.SPIKENAUT_BANK_COMMIT
    assert "exp-025" in manifest["bank"]["source"]


def test_manifest_scenarios_tile_the_tick_stream(manifest: dict, golden_ticks) -> None:
    """Scenario ranges must be contiguous and cover every committed tick."""
    cursor = 0
    for scenario in manifest["lif"]["scenarios"]:
        assert scenario["first_tick"] == cursor, f"gap or overlap before {scenario['name']}"
        assert scenario["tick_count"] == len(scenario["ticks"])
        cursor += scenario["tick_count"]
    assert cursor == len(golden_ticks)


_ORIGIN_RE = re.compile(r"^weights\[n(\d+)\]\[ch(\d+)\]$")


def test_exp025_scenarios_only_use_words_from_the_pinned_bank(manifest: dict) -> None:
    """No invented weights: every exp-025 word must be at its stated bank address."""
    bank = gen.Bank()
    checked = 0
    for scenario in manifest["lif"]["scenarios"]:
        if scenario["source"] != "exp-025":
            continue
        for position, tick in enumerate(scenario["ticks"]):
            match = _ORIGIN_RE.match(tick["weight_origin"])
            if not match:
                # The leak-only ticks carry no weight; they must encode to zero.
                assert tick["weight_q88"] == "0000", (
                    f"{scenario['name']} tick {position}: unrecognised origin "
                    f"{tick['weight_origin']!r} on a non-zero weight"
                )
                continue
            neuron, channel = int(match.group(1)), int(match.group(2))
            expected = bank.weights[neuron * gen.NUM_CHANNELS + channel]
            assert q88.hex_to_raw(tick["weight_q88"]) == expected, (
                f"{scenario['name']} tick {position}: {tick['weight_q88']} is not "
                f"weights[n{neuron}][ch{channel}] in the pinned bank"
            )
            # Thresholds and leaks must likewise be that neuron's own words.
            assert q88.hex_to_raw(tick["threshold_q88"]) == bank.thresholds[neuron]
            assert q88.hex_to_raw(tick["leak_q88"]) == bank.decay[neuron]
            checked += 1
    assert checked > 0, "no exp-025 bank-sourced ticks were checked"


def test_at_least_one_real_dale_inhibitory_word_is_exercised(manifest: dict) -> None:
    """The acceptance criterion: a real negative-weight path must be covered."""
    negatives = {
        tick["weight_q88"]
        for scenario in manifest["lif"]["scenarios"]
        if scenario["source"] == "exp-025"
        for tick in scenario["ticks"]
        if q88.hex_to_raw(tick["weight_q88"]) < 0
    }
    assert "FF00" in negatives, "the -1.0 Dale-I word is not exercised by any vector"
    assert len(negatives) >= 2, f"only one distinct negative word is covered: {negatives}"


# --------------------------------------------------------------------------
# 3. The vectors match the reference model, and discriminate against wrong ones
# --------------------------------------------------------------------------


def test_committed_expectations_match_the_reference_model(golden_ticks, golden_expectations):
    membrane, spike = golden_expectations
    trace = lif.run(golden_ticks)
    assert [state.membrane for state in trace] == membrane
    assert [1 if state.spike_out else 0 for state in trace] == spike


DRIFT_VARIANTS = {
    "unsigned_misread": lif.Semantics(signed=False),
    "one_sided_leak": lif.Semantics(symmetric_leak=False),
    "wrapping_instead_of_saturating": lif.Semantics(saturate=False),
}


@pytest.mark.parametrize("variant", sorted(DRIFT_VARIANTS))
def test_vectors_reject_wrong_semantics(variant, golden_ticks, golden_expectations):
    """Replaying the golden vectors through a wrong LIF must not reproduce them.

    This is what makes the check meaningful rather than merely reproducible:
    each of the three failure modes named in GH#66 -- an unsigned misread of
    ``0xFF00``, the wrong leak, the wrong saturate -- is shown to change the
    committed trace.
    """
    membrane, spike = golden_expectations
    trace = lif.run(golden_ticks, semantics=DRIFT_VARIANTS[variant])
    drifted = [
        index
        for index, state in enumerate(trace)
        if state.membrane != membrane[index] or int(state.spike_out) != spike[index]
    ]
    assert drifted, f"the golden vectors do not distinguish '{variant}' from the shipped semantics"


def test_unsigned_misread_fires_the_dale_neuron_on_its_first_tick(manifest, golden_ticks):
    """Name the exact regression: 0xFF00 read unsigned fires a neuron that must stay silent."""
    scenario = next(
        s for s in manifest["lif"]["scenarios"] if s["name"] == "dale_i_subtracts"
    )
    start = scenario["first_tick"]
    ticks = golden_ticks[start : start + scenario["tick_count"]]

    correct = lif.run(ticks)
    assert not any(state.spike_out for state in correct), (
        "signed: a -1.0 weight must never drive this neuron over threshold"
    )
    assert all(state.membrane < 0 for state in correct)

    misread = lif.run(ticks, semantics=DRIFT_VARIANTS["unsigned_misread"])
    assert misread[0].spike_out, (
        "unsigned: +65280 should saturate over the 115/256 threshold on tick 0 -- "
        "if it no longer does, this vector has stopped guarding the GH#73 regression"
    )


def test_one_sided_leak_fails_the_recovery_vector(manifest, golden_ticks):
    """The leak-recovery vector must be what catches a non-symmetric leak."""
    scenario = next(
        s for s in manifest["lif"]["scenarios"] if s["name"] == "dale_i_leak_recovery"
    )
    start = scenario["first_tick"]
    ticks = golden_ticks[start : start + scenario["tick_count"]]

    correct = lif.run(ticks)
    assert correct[-1].membrane == 0, "symmetric leak must recover the membrane to exactly 0"

    one_sided = lif.run(ticks, semantics=DRIFT_VARIANTS["one_sided_leak"])
    assert one_sided[-1].membrane < 0, (
        "a one-sided leak should drive the inhibited membrane further negative"
    )


def test_wrapping_datapath_fails_the_saturation_vectors(manifest, golden_ticks):
    """The saturation vectors must be what catches a non-saturating datapath."""
    for name, expected_membrane in (
        ("saturate_positive", lif.MAX_MEM),
        ("saturate_negative", lif.MIN_MEM),
    ):
        scenario = next(s for s in manifest["lif"]["scenarios"] if s["name"] == name)
        start = scenario["first_tick"]
        ticks = golden_ticks[start : start + scenario["tick_count"]]

        correct = lif.run(ticks)
        assert any(state.membrane == expected_membrane for state in correct), (
            f"{name}: the membrane never reaches the saturation extreme it exists to pin"
        )

        wrapping = lif.run(ticks, semantics=DRIFT_VARIANTS["wrapping_instead_of_saturating"])
        assert [s.membrane for s in wrapping] != [s.membrane for s in correct], (
            f"{name}: a wrapping datapath produces the same trace, so this vector proves nothing"
        )


# --------------------------------------------------------------------------
# Output layer (GH#72 hooks)
# --------------------------------------------------------------------------


def test_output_layer_vectors_match_an_independent_argmax(manifest: dict) -> None:
    """Recompute the expected argmax straight from the bank, not from the generator."""
    weights = q88.read_mem(BANK_DIR / "merged_v2_output_weights.mem")
    # Bitmaps and one-hot results are bit patterns, not Q8.8 numbers: read_mem
    # would hand back the all-lanes-spiking bitmap 0xFFFF as -1.
    bitmaps = q88.read_words(GOLDEN_DIR / "outlayer_golden_bitmap.mem")
    results = q88.read_words(GOLDEN_DIR / "outlayer_golden_exp_result.mem")

    for pattern, onehot, entry in zip(bitmaps, results, manifest["output_layer"]["vectors"]):
        scores = [0, 0, 0]
        for neuron in range(gen.NUM_NEURONS):
            if (pattern >> neuron) & 1:
                for klass in range(gen.NUM_CLASSES):
                    scores[klass] += weights[neuron * gen.NUM_CLASSES + klass]
        best = max(range(gen.NUM_CLASSES), key=lambda c: (scores[c], -c))
        assert onehot == 1 << best
        assert entry["argmax_class"] == best


def test_output_layer_vectors_cover_every_class(manifest: dict) -> None:
    """An argmax test that only ever selects class 0 is not testing the argmax."""
    selected = {entry["argmax_class"] for entry in manifest["output_layer"]["vectors"]}
    assert selected == set(range(gen.NUM_CLASSES)), f"classes covered: {sorted(selected)}"


def test_output_layer_covers_negative_scores(manifest: dict) -> None:
    """Neurons 12-15 carry non-positive output weights; some vector must go negative."""
    negatives = [
        entry
        for entry in manifest["output_layer"]["vectors"]
        if any(q88.hex_to_raw(score) < 0 for score in entry["scores_q88"])
    ]
    assert negatives, "no output-layer vector produces a negative class score"


# --------------------------------------------------------------------------
# The tooling's own guardrails. A guard that has never fired is a guard that
# might not work, and these ones are what stop bad vectors from being written.
# --------------------------------------------------------------------------


def test_read_mem_reports_the_offending_line(tmp_path: Path) -> None:
    bad = tmp_path / "bad.mem"
    bad.write_text("// SPDX-License-Identifier: MIT OR Apache-2.0\n0100\nnothex\n")
    with pytest.raises(ValueError, match=r"bad\.mem:3"):
        q88.read_mem(bad)


def test_read_mem_skips_comments_and_blank_lines(tmp_path: Path) -> None:
    image = tmp_path / "ok.mem"
    image.write_text("// header\n\n0100\n// mid-file comment\nFF00\n\n")
    assert q88.read_mem(image) == [256, -256]


def test_writers_reject_out_of_range_words(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        q88.write_mem(tmp_path / "a.mem", [0x8000])  # 32768 is not a signed Q8.8 word
    with pytest.raises(ValueError):
        q88.write_words(tmp_path / "b.mem", [0x10000])  # does not fit in 16 bits


def test_hex_round_trips_over_the_whole_word_space() -> None:
    for unsigned in range(0x10000):
        word = f"{unsigned:04X}"
        assert q88.raw_to_hex(q88.hex_to_raw(word)) == word


def test_write_mem_emits_the_spdx_header(tmp_path: Path) -> None:
    path = tmp_path / "c.mem"
    q88.write_mem(path, [256, -256], header="provenance line")
    lines = path.read_text().splitlines()
    assert lines[0] == "// SPDX-License-Identifier: MIT OR Apache-2.0"
    assert lines[1] == "// provenance line"
    assert lines[2:] == ["0100", "FF00"]


def test_bank_rejects_an_image_of_the_wrong_length(tmp_path: Path, monkeypatch) -> None:
    """A retrain that changes the bank geometry must stop the generator, not reshape it."""
    for name in (
        "merged_v2_weights.mem",
        "merged_v2_thresholds.mem",
        "merged_v2_decay.mem",
        "merged_v2_output_weights.mem",
    ):
        (tmp_path / name).write_text((BANK_DIR / name).read_text())
    # Truncate the weight image to one row.
    q88.write_mem(tmp_path / "merged_v2_weights.mem", q88.read_mem(BANK_DIR / "merged_v2_weights.mem")[:16])

    monkeypatch.setattr(gen, "BANK_DIR", tmp_path)
    with pytest.raises(SystemExit, match="merged_v2_weights.mem"):
        gen.Bank()


def test_emit_reproduces_the_committed_tree(tmp_path: Path) -> None:
    """Exercise the writer in-process, not only through the --check subprocess."""
    bank = gen.Bank()
    gen.emit(
        tmp_path,
        gen.encode_scenarios(gen.build_scenarios(bank), bank),
        gen.output_layer_vectors(bank),
    )
    for name in gen.GENERATED_NAMES:
        assert (tmp_path / name).read_bytes() == (GOLDEN_DIR / name).read_bytes(), name


def test_check_mode_returns_zero_on_a_clean_tree() -> None:
    assert gen.main(["--check"]) == 0

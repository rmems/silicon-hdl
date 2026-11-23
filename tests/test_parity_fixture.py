# SPDX-License-Identifier: MIT OR Apache-2.0
"""Tests for the GH#76 supervisor-parity fixture.

Three things are pinned here, matching the house pattern of
``test_golden_lif_vectors.py`` / ``test_golden_frame_vectors.py``:

1. the committed fixture (``testdata/supervisor_parity/``) is reproducible
   from ``scripts/gen_parity_fixture.py`` — including the ``--check``
   drift gate CI runs;
2. the reference model (``scripts/soc_reference.py``) produces the trace
   the RTL must match — including the binary-event decode, the route-drop
   semantics, and the consumed-tick schedule;
3. the comparator (``scripts/parity_compare.py``) actually discriminates:
   a corrupted expectation must fail, a shifted consumed tick must fail,
   and unobservable board outputs are recorded — never counted as passing.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import gen_parity_fixture as gen  # noqa: E402
import lif_reference as lif  # noqa: E402
import parity_compare  # noqa: E402
import q88  # noqa: E402
import soc_reference as ref  # noqa: E402

FIXTURE_DIR = REPO_ROOT / "testdata" / "supervisor_parity"


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads((FIXTURE_DIR / "manifest.json").read_text())


@pytest.fixture(scope="module")
def expected_trace() -> dict:
    return json.loads((FIXTURE_DIR / "expected_trace.json").read_text())


@pytest.fixture(scope="module")
def observed_sim() -> dict | None:
    """The sim's observed.json, if a replay ran locally (CI may skip it)."""
    path = FIXTURE_DIR / "observed.json"
    return json.loads(path.read_text()) if path.exists() else None


# --------------------------------------------------------------------------
# 1. Generator / committed-artifact drift gates
# --------------------------------------------------------------------------


def test_regenerating_is_a_no_op():
    """`--check` against the committed tree must return 0."""
    result = subprocess.run(
        [sys.executable, "scripts/gen_parity_fixture.py", "--check"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_check_mode_returns_zero_on_a_clean_tree():
    assert gen.main(["--check"]) == 0


def test_generator_is_deterministic():
    bank = gen.load_bank()
    a = gen.encode(gen.build_steps(), bank)
    b = gen.encode(gen.build_steps(), bank)
    assert a == b


def test_all_generated_files_exist():
    for name in gen.GENERATED_NAMES:
        assert (FIXTURE_DIR / name).exists(), f"missing {name}"


def test_banner_and_do_not_edit():
    for name in gen.GENERATED_NAMES:
        if not name.endswith(".mem"):
            continue
        first = (FIXTURE_DIR / name).read_text().splitlines()[0]
        assert first.startswith("// SPDX-License-Identifier"), name
        assert "GENERATED FILE" in (FIXTURE_DIR / name).read_text().splitlines()[1], name
    assert "do_not_edit" in json.loads((FIXTURE_DIR / "manifest.json").read_text())


# --------------------------------------------------------------------------
# 2. Fixture contents pin the contract
# --------------------------------------------------------------------------


def test_parameter_images_are_the_pinned_bank():
    """The fixture's parameter files ARE the exp-025 bank (digest-enforced)."""
    fixture_images = {
        "parameters_weights.mem": "merged_v2_weights.mem",
        "parameters.mem": "merged_v2_thresholds.mem",
        "parameters_decay.mem": "merged_v2_decay.mem",
        "parameters_output_weights.mem": "merged_v2_output_weights.mem",
    }
    for fixture_name, bank_name in fixture_images.items():
        assert q88.content_digest(FIXTURE_DIR / fixture_name) == gen.BANK_DIGESTS[bank_name], (
            f"{fixture_name} must be byte-equivalent to the pinned {bank_name} "
            "(the silicon-bridge silicon_hdl_v3 export emits the same images)"
        )


def test_inputs_mem_shape_and_count(manifest):
    words = q88.read_words(FIXTURE_DIR / "inputs.mem")
    count = q88.read_words(FIXTURE_DIR / "inputs_count.mem")[0]
    assert count == manifest["step_count"] == len(manifest["steps"])
    assert len(words) == count * gen.NUM_CHANNELS


def test_aer_routes_image_is_identity():
    words = q88.read_words(FIXTURE_DIR / "aer_routes.mem")
    assert len(words) == gen.NUM_CHANNELS
    for addr, word in enumerate(words):
        assert word == 0xC000 | addr, "identity entry must be valid|terminal|next=addr"


def test_manifest_records_contract_and_schedule(manifest):
    assert manifest["host_hdl_contract"]["contract_id"] == gen.CONTRACT_ID
    assert manifest["host_hdl_contract"]["profile_id"] == gen.PROFILE_ID
    assert manifest["schedule"]["ticks_per_frame"] == ref.TICKS_PER_FRAME
    assert manifest["schedule"]["base_tick"] == ref.BASE_TICK
    assert manifest["schedule"]["consumed_ticks"] == [
        ref.BASE_TICK + i * ref.TICKS_PER_FRAME
        for i in range(manifest["step_count"])
    ]


def test_fixture_is_public():
    """No private checkpoint: parameter images equal committed bank words."""
    assert (FIXTURE_DIR / "parameters_weights.mem").read_text() == (
        REPO_ROOT / "spikenaut-core-sv/mem/merged_v2_weights.mem"
    ).read_text().replace(
        "merged_v2_weights.mem", "parameters_weights.mem"
    ) or q88.read_mem(FIXTURE_DIR / "parameters_weights.mem") == q88.read_mem(
        REPO_ROOT / "spikenaut-core-sv/mem/merged_v2_weights.mem"
    )


# --------------------------------------------------------------------------
# 3. Reference model semantics
# --------------------------------------------------------------------------


def test_reference_spike_outcomes(expected_trace):
    """Known bank outcomes: lane 2 fires n1+n3, lane 1 fires n8, lane 4 n9."""
    by_name = {s["name"]: s for s in expected_trace["steps"]}
    assert by_name["lane2_spikes"]["spike_word"] == 0b1010        # n1, n3
    assert by_name["lane1_spikes"]["spike_word"] == 0b1_0000_0000  # n8
    assert by_name["lane4_spikes"]["spike_word"] == 0b10_0000_0000  # n9
    assert by_name["lane0_baseline"]["spike_word"] == 0


def test_lowest_lane_wins(expected_trace):
    """multi_lowest_wins has lanes 0/2/4 active: only lane 0 may integrate."""
    step = next(s for s in expected_trace["steps"] if s["name"] == "multi_lowest_wins")
    assert step["input_index"] == 0
    # lane 0's weights are sub-threshold everywhere: no spikes
    assert step["spike_word"] == 0


def test_dropped_frame_is_consumed_as_leak_tick(expected_trace):
    drop = next(s for s in expected_trace["steps"] if s["name"] == "all_zero_drop")
    assert drop["dropped"] is True
    assert drop["input_index"] is None
    assert drop["spike_word"] == 0
    assert all(p == 0 for p in drop["potentials_raw"]), (
        "after the preceding leak ticks a drop must produce an all-zero response"
    )


def test_magnitude_is_discarded(expected_trace):
    """0x7FFF and -1.0 must produce the same trace as 0x0001 on the same lane."""
    by_name = {s["name"]: s for s in expected_trace["steps"]}
    base = by_name["lane2_spikes"]
    for name in ("magnitude_irrelevant_max", "magnitude_irrelevant_neg"):
        other = by_name[name]
        assert other["spike_word"] == base["spike_word"], name
        assert other["potentials_raw"] == base["potentials_raw"], name


def test_membrane_values_match_single_step_arithmetic(expected_trace):
    """Step 0 (lane0, first stimulus): mem[n] == weight[n][0] exactly."""
    bank = gen.load_bank()
    step0 = expected_trace["steps"][0]
    for n in range(gen.NUM_NEURONS):
        assert step0["potentials_raw"][n] == bank.weights[n * gen.NUM_CHANNELS + 0]


def test_leak_drains_before_next_stimulus(expected_trace):
    """With 6 leak ticks between stimuli no weight bump survives; each
    stimulated tick starts from membrane 0, so its potentials equal the
    selected column's raw weights."""
    bank = gen.load_bank()
    for step in expected_trace["steps"]:
        if step["input_index"] is None:
            continue
        col = step["input_index"]
        for n in range(gen.NUM_NEURONS):
            # spiking rows also report the post-integrate membrane in their
            # response word — the refractory clear lands on the *next* tick
            assert step["potentials_raw"][n] == bank.weights[n * gen.NUM_CHANNELS + col]


def test_output_class_mirror_known_cases():
    """Mirror OutputLayer: bitmap -> saturating scores -> argmax one-hot."""
    bank = gen.load_bank()
    # empty bitmap: all scores 0, lowest class wins
    assert ref.output_class_onehot(0, bank.output_weights) == 1
    # golden bitmaps from the GH#72 golden vectors
    goldens = json.loads(
        (REPO_ROOT / "spikenaut-core-sv/mem/golden/golden_vectors.json").read_text()
    )
    for vec in goldens["output_layer"]["vectors"]:
        bitmap = int(vec["spike_bitmap"], 16)
        assert ref.output_class_onehot(bitmap, bank.output_weights) == int(
            vec["result_onehot"], 16
        ), f"bitmap {vec['spike_bitmap']}"


# --------------------------------------------------------------------------
# 4. Comparator discrimination
# --------------------------------------------------------------------------


def _mini_expected() -> dict:
    return {
        "fixture": "mini",
        "ticks_per_frame": ref.TICKS_PER_FRAME,
        "steps": [
            {"step": 0, "name": "a", "consumed_tick": ref.BASE_TICK,
             "input_lane": 2, "input_index": 2, "dropped": False,
             "potentials_raw": [1] * 16, "spike_word": 0x000A, "output_class": 1,
             "aux_word": 0},
            {"step": 1, "name": "b", "consumed_tick": ref.BASE_TICK + ref.TICKS_PER_FRAME,
             "input_lane": 0, "input_index": 0, "dropped": False,
             "potentials_raw": [2] * 16, "spike_word": 0x0000, "output_class": 1,
             "aux_word": 0},
        ],
    }


def _mini_observed() -> dict:
    return {
        "fixture": "mini",
        "ticks_per_frame": ref.TICKS_PER_FRAME,
        "steps": [
            {"step": 0, "consumed_tick": ref.BASE_TICK, "potentials": [1] * 16,
             "spike_word": 0x000A, "aux_word": 0, "output_class": 1},
            {"step": 1, "consumed_tick": ref.BASE_TICK + ref.TICKS_PER_FRAME,
             "potentials": [2] * 16, "spike_word": 0, "aux_word": 0, "output_class": 1},
        ],
        "frame_send_count": 2,
        "elapsed_ticks": ref.BASE_TICK + ref.TICKS_PER_FRAME,
    }


def test_comparator_passes_identical_traces():
    report = parity_compare.compare(_mini_expected(), _mini_observed(), {})
    assert report["pass"] is True
    assert report["spike_agreement"] == 1.0
    assert report["potential_agreement"] == 1.0
    assert report["action_agreement"] == 1.0
    assert report["alignment_agreement"] == 1.0
    assert report["first_divergence_step"] is None


def test_comparator_fails_on_corrupted_expected_spike():
    """The issue's discrimination proof: corrupt an expected output."""
    expected = _mini_expected()
    expected["steps"][0]["spike_word"] ^= 0b100  # flip neuron 2's bit
    report = parity_compare.compare(expected, _mini_observed(), {})
    assert report["pass"] is False
    assert report["first_divergence_step"] == 0
    assert report["divergent_steps"][0]["fields"] == ["spike_word"]


def test_comparator_fails_on_wrong_timestep_offset():
    observed = _mini_observed()
    observed["steps"][1]["consumed_tick"] += 1  # one tick late
    report = parity_compare.compare(_mini_expected(), observed, {})
    assert report["pass"] is False
    assert report["first_divergence_step"] == 1
    assert "consumed_tick" in report["divergent_steps"][0]["fields"]


def test_comparator_fails_on_potential_drift():
    observed = _mini_observed()
    observed["steps"][0]["potentials"][7] += 1
    report = parity_compare.compare(_mini_expected(), observed, {})
    assert report["pass"] is False
    mismatch = report["checks"]["potentials"]["mismatches"][0]
    assert mismatch["step"] == 0
    assert mismatch["lanes"] == [{"lane": 7, "expected": 1, "observed": 2}]


def test_unobservable_output_is_recorded_not_passing():
    """A board capture has no output_class: recorded, excluded, never passing."""
    observed = _mini_observed()
    for s in observed["steps"]:
        del s["output_class"]
    report = parity_compare.compare(_mini_expected(), observed, {})
    assert report["checks"]["output_class"]["not_observed"] == 2
    assert report["checks"]["output_class"]["compared"] == 0
    assert report["action_agreement"] is None
    assert report["pass"] is True  # remaining observables still exact


def test_missing_observed_steps_fail():
    observed = _mini_observed()
    observed["steps"].pop()
    report = parity_compare.compare(_mini_expected(), observed, {})
    assert report["pass"] is False


def test_comparator_report_is_deterministic(tmp_path):
    exp = _mini_expected()
    obs = _mini_observed()
    a = parity_compare.compare(exp, obs, {})
    b = parity_compare.compare(exp, obs, {})
    assert a == b


def test_comparator_cli(tmp_path):
    exp = tmp_path / "exp.json"
    obs = tmp_path / "obs.json"
    out = tmp_path / "report.json"
    exp.write_text(json.dumps(_mini_expected()))
    obs.write_text(json.dumps(_mini_observed()))
    rc = parity_compare.main([str(exp), str(obs), "-o", str(out)])
    assert rc == 0
    report = json.loads(out.read_text())
    assert report["pass"] is True

    obs.write_text(json.dumps({**_mini_observed(), "steps": [
        {**s, "spike_word": s["spike_word"] ^ 1} for s in _mini_observed()["steps"]
    ]}))
    assert parity_compare.main([str(exp), str(obs)]) == 1


# --------------------------------------------------------------------------
# 5. Sim replay (only when an observed.json exists locally)
# --------------------------------------------------------------------------


def test_sim_replay_if_present(observed_sim, expected_trace):
    """If a local Verilator replay wrote observed.json, it must compare clean."""
    if observed_sim is None:
        pytest.skip("no local observed.json (run tb_SocParity first)")
    # A stale observed.json from an older fixture must not be compared.
    assert observed_sim.get("fixture") == expected_trace.get("fixture")
    report = parity_compare.compare(
        json.loads((FIXTURE_DIR / "expected_trace.json").read_text()),
        observed_sim,
        {},
    )
    assert report["pass"], report["divergent_steps"][:3]

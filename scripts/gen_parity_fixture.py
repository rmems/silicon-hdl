#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate the GH#76 supervisor-parity fixture (``testdata/supervisor_parity/``).

Run from the repo root::

    python3 scripts/gen_parity_fixture.py            # regenerate in place
    python3 scripts/gen_parity_fixture.py --check    # fail if regenerating would change anything

``--check`` is the drift gate, same contract as ``gen_golden_lif_vectors.py``
/ ``gen_golden_frame_vectors.py`` (see ``scripts/quality.sh``,
``tests/test_parity_fixture.py``).

What this fixture is
--------------------
The "first deliverable" of GH#76: a **small public deterministic stimulus
sequence** plus a bit-exact expected trace, replayable through

1. the Python reference (``scripts/soc_reference.py`` — what "expected" is),
2. RTL simulation (``spikenaut-soc-sv/tb/tb_SocParity.sv`` — full-chip,
   wire-level UART in, 36-byte responses out), and
3. a physical Basys 3 via the documented replay recipe
   (``docs/supervisor-parity.md``; board capture pending).

The fixture needs no private checkpoint or model download: the parameter
images are byte-identical copies of the pinned exp-025 Dale bank
(Spikenaut-SNN#47 @ ``6965e12a``) — the same file set a
``silicon-bridge`` ``ExportConfig::silicon_hdl_v3()`` export emits
(contract ``silicon-bridge-silicon-hdl-v3-contract-v2``, crate 0.4.0).

What the scenarios deliberately cover
-------------------------------------
- every legal input lane 0-4 (bank columns 5-15 are structurally zero)
- lanes that fire spikes (n1/n3 on lane 2, n8 on lane 1, n9 on lane 4)
- Dale-I rows (negative weights never spike below a positive threshold)
- multi-lane frames: the lowest non-zero lane wins, others are dropped
- all-zero frames: consumed + answered, but leak-only (route_drop)
- non-unit magnitudes: 0x7FFF and negative 0xFF00 still count as "active"
- a zero-weight active lane (lane 5): consume + response, no integrate

``TICKS_PER_FRAME`` in ``soc_reference.py`` is the contract's pacing: one
consumed frame per 7 ticks, 6 leak-only ticks between consumed ticks.
"""

from __future__ import annotations

import argparse
import filecmp
import json
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import q88  # noqa: E402
import soc_reference as ref  # noqa: E402
from gen_golden_lif_vectors import (  # noqa: E402
    BANK_DIGESTS,
    SPIKENAUT_BANK_COMMIT,
    SPIKENAUT_BANK_SOURCE,
)
from gen_aer_route_vectors import identity_words  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
BANK_DIR = REPO_ROOT / "spikenaut-core-sv" / "mem"
FIXTURE_DIR = REPO_ROOT / "testdata" / "supervisor_parity"

NUM_NEURONS = ref.NUM_NEURONS
NUM_CHANNELS = ref.NUM_CHANNELS
NUM_CLASSES = ref.NUM_CLASSES

#: silicon-bridge v3 profile provenance (rmems/silicon-bridge#81, shipped
#: in crate 0.4.0). The fixture's parameter images are the pinned bank —
#: byte-identical to what this contract's export writes for this bank.
PROFILE_ID = "silicon-hdl-v3-compatible"
CONTRACT_ID = "silicon-bridge-silicon-hdl-v3-contract-v2"
CRATE_VERSION = "silicon-bridge 0.4.0"
HDL_PROFILE_REVISION = "d45163f38ac1cd88f8a3918e3793a08ace85e132"

BANNER = (
    "GENERATED FILE -- do not edit by hand.",
    "Regenerate: python3 scripts/gen_parity_fixture.py",
    "Source bank: " + SPIKENAUT_BANK_SOURCE,
    "Pinned at Spikenaut-SNN commit " + SPIKENAUT_BANK_COMMIT,
    "See docs/supervisor-parity.md (GH#76).",
)
BANNER_TEXT = "\n".join(BANNER)

GENERATED_NAMES = (
    "inputs.mem",
    "inputs_count.mem",
    "parameters.mem",
    "parameters_decay.mem",
    "parameters_weights.mem",
    "parameters_output_weights.mem",
    "aer_routes.mem",
    "expected_trace.json",
    "expected_spikes.json",
    "expected_actions.json",
    "manifest.json",
)


@dataclass(frozen=True)
class Step:
    """One scheduled stimulus frame: the 16-lane vector plus provenance."""

    name: str
    lanes: tuple[int, ...]
    why: str


def one_hot(lane: int, value: int = 0x0100) -> tuple[int, ...]:
    lanes = [0] * NUM_CHANNELS
    lanes[lane] = value
    return tuple(lanes)


def multi(*lane_values: tuple[int, int]) -> tuple[int, ...]:
    lanes = [0] * NUM_CHANNELS
    for lane, value in lane_values:
        lanes[lane] = value
    return tuple(lanes)


def build_steps() -> list[Step]:
    """The deterministic stimulus schedule (~80 ticks of sim time)."""
    steps = [
        Step("lane0_baseline", one_hot(0),
             "every legal channel gets touched; single event, sub-threshold"),
        Step("lane2_spikes", one_hot(2),
             "lane 2 fires n1/n3 (w=410>=t=409/409): non-empty spike word"),
        Step("lane2_refire", one_hot(2),
             "n1/n3 spike again: refractory clears one tick after the spike, "
             "leak drains the membrane back before the next stimulus"),
        Step("lane1_spikes", one_hot(1),
             "lane 1 fires inhibitory-bank n8 (w=171>=t=115)"),
        Step("lane4_spikes", one_hot(4),
             "lane 4 fires n9 (w=158>=t=115)"),
        Step("all_zero_drop", (0,) * NUM_CHANNELS,
             "all-zero frame: consumed + answered, leak-only (route_drop)"),
        Step("multi_lowest_wins", multi((2, 0x0100), (0, 0x0100), (4, 0x0100)),
             "lanes 0/2/4 active: lowest lane (0) wins, others discarded"),
        Step("magnitude_irrelevant_max", one_hot(2, 0x7FFF),
             "binary-event PE: 0x7FFF integrates exactly the same weight as 0x0001"),
        Step("magnitude_irrelevant_neg", one_hot(2, -256),
             "a negative stimulus word is still a non-zero (active) lane"),
        Step("lane3_subthresh", one_hot(3),
             "small weights (~1-79): no row reaches threshold"),
        Step("lane5_zero_weight", one_hot(5),
             "active lane on a structurally zero column: consume + response, "
             "integrate adds weight 0"),
        Step("lane0_after_traffic", one_hot(0),
             "post-traffic baseline: membranes must have fully leaked back"),
        Step("lane2_multi_with_high", multi((5, 0x0100), (2, 0x0100)),
             "lanes 2/5: lowest wins (2) -> n1/n3 fire again"),
        Step("all_zero_second", (0,) * NUM_CHANNELS,
             "second drop: response still arrives (pending != silent)"),
        Step("lane1_second", one_hot(1),
             "repeat coverage; determinism across the run"),
        Step("lane0_close", one_hot(0),
             "final state: known quiescent trace end"),
    ]
    return steps


def load_bank() -> ref.Bank:
    """The pinned bank, digest-verified (shared BANK_DIGESTS with GH#66)."""
    images = {
        "weights": "merged_v2_weights.mem",
        "thresholds": "merged_v2_thresholds.mem",
        "decay": "merged_v2_decay.mem",
        "output_weights": "merged_v2_output_weights.mem",
    }
    for name in images.values():
        actual = q88.content_digest(BANK_DIR / name)
        if actual != BANK_DIGESTS[name]:
            raise SystemExit(
                f"pinned bank drifted: {name}\n"
                f"  expected sha256 {BANK_DIGESTS[name]}\n"
                f"  actual   sha256 {actual}\n"
                "If this retrain is intentional, re-pin BANK_DIGESTS in "
                "scripts/gen_golden_lif_vectors.py first, then regenerate."
            )
    return ref.Bank(
        weights=tuple(q88.read_mem(BANK_DIR / images["weights"])),
        thresholds=tuple(q88.read_mem(BANK_DIR / images["thresholds"])),
        decay=tuple(q88.read_mem(BANK_DIR / images["decay"])),
        output_weights=tuple(q88.read_mem(BANK_DIR / images["output_weights"])),
    )


def encode(steps: list[Step], bank: ref.Bank) -> dict:
    stimuli = [ref.Stimulus(lanes=s.lanes) for s in steps]
    consumed = ref.expected_steps(stimuli, bank)

    input_words: list[int] = []
    expected_steps = []
    for i, (step, result) in enumerate(zip(steps, consumed)):
        input_words.extend(word & 0xFFFF for word in step.lanes)
        lane = ref.Stimulus(lanes=step.lanes).decoded_lane()
        expected_steps.append({
            "step": i,
            "name": step.name,
            "why": step.why,
            "lanes_q88": [q88.raw_to_hex(w) for w in step.lanes],
            "consumed_tick": result.tick,
            "input_lane": lane,
            "input_index": result.input_index,
            "dropped": lane is None,
            "potentials_q88": [q88.raw_to_hex(p) for p in result.potentials],
            "potentials_raw": result.potentials,
            "spike_word": result.spike_bitmap,
            "output_class": result.output_class,
        })

    return {
        "step_count": len(steps),
        "input_words": input_words,
        "expected_steps": expected_steps,
    }


def emit(target: Path, encoded: dict, bank: ref.Bank) -> None:
    target.mkdir(parents=True, exist_ok=True)

    q88.write_words(target / "inputs.mem", encoded["input_words"], header=BANNER_TEXT)
    q88.write_words(target / "inputs_count.mem", [encoded["step_count"]], header=BANNER_TEXT)
    # Fixture-local parameter images = the pinned bank under the export
    # contract's filenames (parameters_output_weights.mem is the HDL-native
    # N x K image = silicon-bridge's hdl_readout_neuron_major.mem).
    q88.write_mem(target / "parameters.mem", list(bank.thresholds), header=BANNER_TEXT)
    q88.write_mem(target / "parameters_decay.mem", list(bank.decay), header=BANNER_TEXT)
    q88.write_mem(target / "parameters_weights.mem", list(bank.weights), header=BANNER_TEXT)
    q88.write_mem(target / "parameters_output_weights.mem",
                  list(bank.output_weights), header=BANNER_TEXT)
    # Identity aer-route-v1 image: (valid|terminal|next=addr) encoding, same
    # words as synapse-link-hdl/mem/aer_routes_identity_n16.mem.
    q88.write_words(target / "aer_routes.mem", identity_words(), header=BANNER_TEXT)

    expected_trace = {
        "fixture": "supervisor_parity_v1",
        "ticks_per_frame": ref.TICKS_PER_FRAME,
        "steps": encoded["expected_steps"],
    }
    (target / "expected_trace.json").write_text(
        json.dumps(expected_trace, indent=2) + "\n"
    )
    (target / "expected_spikes.json").write_text(json.dumps([
        {"step": s["step"], "consumed_tick": s["consumed_tick"],
         "spike_word": s["spike_word"]}
        for s in encoded["expected_steps"]
    ], indent=2) + "\n")
    (target / "expected_actions.json").write_text(json.dumps([
        {"step": s["step"], "consumed_tick": s["consumed_tick"],
         "output_class": s["output_class"], "observability": "sim_only"}
        for s in encoded["expected_steps"]
    ], indent=2) + "\n")

    manifest = {
        "generated_by": "scripts/gen_parity_fixture.py",
        "issue": "GH#76 / RM-616",
        "do_not_edit": "Regenerate with: python3 scripts/gen_parity_fixture.py",
        "fixture": "supervisor_parity_v1",
        "host_hdl_contract": {
            "profile_id": PROFILE_ID,
            "contract_id": CONTRACT_ID,
            "crate": CRATE_VERSION,
            "hdl_revision_pinned_by_profile": HDL_PROFILE_REVISION,
            "export_api": (
                "FpgaParameterExporter::from_params + set_output_weights(KxN) + "
                "write_with_config(dir, ExportConfig::silicon_hdl_v3())"
            ),
            "readout_note": (
                "parameters_output_weights.mem is the HDL-native N x K readout; "
                "silicon-bridge writes it as hdl_readout_neuron_major.mem. The "
                "K x N parameters_output_weights.mem the crate also emits is NOT "
                "the file OutputLayer consumes."
            ),
        },
        "bank": {
            "source": SPIKENAUT_BANK_SOURCE,
            "commit": SPIKENAUT_BANK_COMMIT,
            "images": [f"spikenaut-core-sv/mem/{n}" for n in BANK_DIGESTS],
            "content_digests_sha256": dict(BANK_DIGESTS),
        },
        "q88": {
            "convention": "signed two's-complement Q8.8 (GH#73)",
            "codec": "scripts/q88.py, mirroring silicon-bridge encode_q88_signed",
            "clamp_f32": [q88.Q88_CLAMP_MIN, q88.Q88_CLAMP_MAX],
            "rounding": "truncate toward zero",
        },
        "schedule": {
            "ticks_per_frame": ref.TICKS_PER_FRAME,
            "consumed_ticks": [s["consumed_tick"] for s in encoded["expected_steps"]],
            "base_tick": ref.BASE_TICK,
            "rule": (
                f"frame i is consumed at tick {ref.BASE_TICK} + i*{ref.TICKS_PER_FRAME}; "
                "ticks between consumed ticks are leak-only"
            ),
            "pacing": (
                "wait for the full 36-byte response, delay ~0.5 ms, then send "
                "the next frame; RX_COMMIT lands ~6.5 ms after the previous "
                "consumed tick -> consumed 7 ticks later (+/-500 us margin)"
            ),
        },
        "reset": {
            "state": "all membranes 0, spike flags 0, output_class 0",
            "switches": "sw=0x0000: STDP off (SW14=0), spike-LED view (SW15=0)",
        },
        "semantics": {
            "stimulus_decode": "lowest non-zero lane wins; magnitudes discarded (binary-event PE)",
            "routing": "identity AER table (aer_routes.mem)",
            "leak": "signed, symmetric toward 0, every tick",
            "refractory": "spike registered on crossing tick, membrane cleared next tick",
            "response": "36 bytes = 16 potentials + spike word + aux(switch) word, big-endian",
            "unobservable": [
                "output_class is LED-only (not in the frame): sim-only observable, "
                "recorded as sim_only on board runs",
            ],
        },
        "dimensions": {
            "num_neurons": NUM_NEURONS,
            "num_channels": NUM_CHANNELS,
            "num_classes": NUM_CLASSES,
        },
        "step_count": encoded["step_count"],
        "steps": [
            {"step": s["step"], "name": s["name"], "why": s["why"],
             "lanes_q88": s["lanes_q88"]}
            for s in encoded["expected_steps"]
        ],
        "tools": {
            "testbench": "spikenaut-soc-sv/tb/tb_SocParity.sv",
            "comparator": "scripts/parity_compare.py",
            "reference_model": "scripts/soc_reference.py",
        },
    }
    (target / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="do not write; exit non-zero if regenerating would change the committed fixture",
    )
    args = parser.parse_args(argv)

    bank = load_bank()
    encoded = encode(build_steps(), bank)

    if not args.check:
        emit(FIXTURE_DIR, encoded, bank)
        print(
            f"wrote {len(GENERATED_NAMES)} files to {FIXTURE_DIR.relative_to(REPO_ROOT)}/ "
            f"({encoded['step_count']} stimulus steps)"
        )
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        fresh = Path(tmp)
        emit(fresh, encoded, bank)
        stale = [
            name
            for name in GENERATED_NAMES
            if not (FIXTURE_DIR / name).exists()
            or not filecmp.cmp(fresh / name, FIXTURE_DIR / name, shallow=False)
        ]

    if stale:
        print("supervisor parity fixture is out of date:", file=sys.stderr)
        for name in stale:
            print(f"  {(FIXTURE_DIR / name).relative_to(REPO_ROOT)}", file=sys.stderr)
        print(
            "\nRegenerate with: python3 scripts/gen_parity_fixture.py\n"
            "If you did not intend to change the schedule, the reference "
            "model, or the pinned bank, this is the drift this check exists "
            "to catch.",
            file=sys.stderr,
        )
        return 1

    print(f"supervisor parity fixture up to date ({len(GENERATED_NAMES)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

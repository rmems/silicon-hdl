#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate the golden f32 -> Q8.8 -> ``.mem`` -> Verilator vectors (GH#66).

Run from the repo root::

    python3 scripts/gen_golden_lif_vectors.py            # regenerate in place
    python3 scripts/gen_golden_lif_vectors.py --check    # fail if regenerating would change anything

``--check`` is the drift gate: it regenerates into a temporary directory and
diffs against what is committed, so a change to the codec, the reference model,
or the pinned bank cannot land without the vectors being refreshed in the same
commit. ``scripts/quality.sh`` and ``tests/test_golden_lif_vectors.py`` both
run it.

What is and is not invented here
--------------------------------
Every weight/threshold/leak word in the ``exp-025`` scenarios is a **decode of
a word already committed** under ``spikenaut-core-sv/mem/`` (the exp-025 Dale
bank promoted in Spikenaut-SNN#47 @ ``6965e12a``). The generator reads the
bank, decodes to ``f32``, and re-encodes -- it never authors a trained weight.
The re-encode is asserted to return the identical word, which is what makes the
``f32 -> Q8.8`` leg real rather than decorative.

The handful of ``synthetic`` scenarios exist to reach behaviour the trained
bank cannot express at all (datapath saturation needs magnitudes near +/-128;
the bank's largest word is 410/256 = 1.6). They are tagged ``synthetic`` in the
manifest so they are never mistaken for bank data.

See ``docs/golden-lif-vectors.md``.
"""

from __future__ import annotations

import argparse
import filecmp
import json
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import lif_reference as lif  # noqa: E402
import q88  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
BANK_DIR = REPO_ROOT / "spikenaut-core-sv" / "mem"
GOLDEN_DIR = BANK_DIR / "golden"

#: Spikenaut-SNN commit the live exp-025 Dale bank was promoted at
#: (Spikenaut-SNN#47). The committed ``.mem`` images under
#: ``spikenaut-core-sv/mem/`` are byte-identical to
#: ``dataset/merged_v2/*.mem`` at this commit; re-verify after any retrain.
SPIKENAUT_BANK_COMMIT = "6965e12a"
SPIKENAUT_BANK_SOURCE = "rmems/Spikenaut-SNN dataset/merged_v2 (exp-025 Dale health-PASS bank, PR #47)"

#: SHA-256 of each pinned image's canonical word stream (see
#: ``q88.content_digest``). Length checks alone cannot detect a retrain that
#: keeps the same word count, which would silently regenerate every vector
#: while the manifest still claimed the commit above. These digests make the
#: provenance claim enforceable.
#:
#: To update after an intentional bank change: re-copy the images from the
#: vault, bump SPIKENAUT_BANK_COMMIT, run
#: ``python3 -c "import sys; sys.path.insert(0, 'scripts'); import q88;
#: [print(n, q88.content_digest(f'spikenaut-core-sv/mem/{n}')) for n in
#: BANK_DIGESTS]"``, paste the new values here, and regenerate.
BANK_DIGESTS = {
    "merged_v2_weights.mem": "825969873444d215d09920e69592700a2cc8594d92e7b14c4059eef8919fe4f3",
    "merged_v2_thresholds.mem": "2aff910820757f7015f7097dae0aa00f631fc49d2a5df912b35ba92e309f7a70",
    "merged_v2_decay.mem": "bbb575d31ebd5e0386037c3421d17212b3645522f4e64d02272bb5d6abc0610d",
    "merged_v2_output_weights.mem": "6577e1c5958cb04d0e064a23a8356f54d73739378ed7fdd925a367627014cf72",
}

#: Bank geometry (see spikenaut-core-sv/mem/README.md and #92).
NUM_NEURONS = 16
NUM_CHANNELS = 16
NUM_CLASSES = 3

BANNER = (
    "GENERATED FILE -- do not edit by hand.",
    "Regenerate: python3 scripts/gen_golden_lif_vectors.py",
    "Source bank: " + SPIKENAUT_BANK_SOURCE,
    "Pinned at Spikenaut-SNN commit " + SPIKENAUT_BANK_COMMIT,
    "See docs/golden-lif-vectors.md (GH#66).",
)


# --------------------------------------------------------------------------
# Scenario description. Everything is authored in f32; the generator encodes.
# --------------------------------------------------------------------------


@dataclass
class Tick:
    """One enabled ``step_en`` tick, described in host ``f32`` units."""

    weight: float
    threshold: float
    leak: float
    spike_in: bool
    #: Where this tick's weight came from, for the manifest.
    weight_origin: str


@dataclass
class Scenario:
    name: str
    source: str  # "exp-025" or "synthetic"
    why: str
    ticks: list[Tick] = field(default_factory=list)


class Bank:
    """The committed exp-025 images, decoded to ``f32``."""

    def __init__(self) -> None:
        self.weights = q88.read_mem(BANK_DIR / "merged_v2_weights.mem")
        self.thresholds = q88.read_mem(BANK_DIR / "merged_v2_thresholds.mem")
        self.decay = q88.read_mem(BANK_DIR / "merged_v2_decay.mem")
        self.output_weights = q88.read_mem(BANK_DIR / "merged_v2_output_weights.mem")

        expected = {
            "merged_v2_weights.mem": (self.weights, NUM_NEURONS * NUM_CHANNELS),
            "merged_v2_thresholds.mem": (self.thresholds, NUM_NEURONS),
            "merged_v2_decay.mem": (self.decay, NUM_NEURONS),
            "merged_v2_output_weights.mem": (self.output_weights, NUM_NEURONS * NUM_CLASSES),
        }
        for name, (words, count) in expected.items():
            if len(words) != count:
                raise SystemExit(
                    f"{name}: expected {count} words, found {len(words)}. "
                    "The pinned bank geometry changed -- re-read "
                    "spikenaut-core-sv/mem/README.md before regenerating."
                )

        # Content pin. A retrain that keeps the word count would otherwise
        # regenerate every vector while the manifest still claimed commit
        # SPIKENAUT_BANK_COMMIT -- a provenance claim nothing enforced.
        for name, expected_digest in BANK_DIGESTS.items():
            actual = q88.content_digest(BANK_DIR / name)
            if actual != expected_digest:
                raise SystemExit(
                    f"{name}: content digest {actual[:16]}... does not match the pinned "
                    f"{expected_digest[:16]}... for Spikenaut-SNN commit "
                    f"{SPIKENAUT_BANK_COMMIT}.\n"
                    "The bank changed. If that was intentional, bump "
                    "SPIKENAUT_BANK_COMMIT and BANK_DIGESTS in "
                    "scripts/gen_golden_lif_vectors.py, then regenerate. If it was not, "
                    "the working tree's bank images have drifted from the pinned export."
                )

    def weight_f32(self, neuron: int, channel: int) -> tuple[float, str]:
        """Decode one committed weight to f32, proving the round trip is exact.

        This is the assertion that makes the ``f32 -> Q8.8`` leg of the golden
        path real: if re-encoding did not return the very word that was read,
        the vectors would ship a weight the FPGA never sees.
        """
        raw = self.weights[neuron * NUM_CHANNELS + channel]
        value = q88.q88_signed_to_f32(raw)
        if q88.encode_q88_signed(value) != raw:
            raise SystemExit(
                f"weights[n{neuron}][ch{channel}] = {q88.raw_to_hex(raw)} does not survive "
                f"the f32 round trip (got {q88.raw_to_hex(q88.encode_q88_signed(value))}). "
                "Fix the codec -- do not adjust the vector."
            )
        return value, f"weights[n{neuron}][ch{channel}]"

    def threshold_f32(self, neuron: int) -> float:
        return q88.q88_signed_to_f32(self.thresholds[neuron])

    def leak_f32(self, neuron: int) -> float:
        return q88.q88_signed_to_f32(self.decay[neuron])


def build_scenarios(bank: Bank) -> list[Scenario]:
    """The golden scenario set. Order is stable; append rather than reorder."""
    scenarios: list[Scenario] = []

    def bank_ticks(scenario: Scenario, neuron: int, channels, spike_in=True) -> None:
        """Append ticks driving ``neuron`` from its own real bank row."""
        threshold = bank.threshold_f32(neuron)
        leak = bank.leak_f32(neuron)
        for channel in channels:
            if channel is None:
                # No input this tick: leak-only relaxation.
                scenario.ticks.append(
                    Tick(0.0, threshold, leak, False, f"none (leak-only, n{neuron})")
                )
                continue
            weight, origin = bank.weight_f32(neuron, channel)
            scenario.ticks.append(Tick(weight, threshold, leak, spike_in, origin))

    # -- 1. The headline regression: a real Dale-I word must subtract. -------
    # Neuron 6 channel 0 is 0xFF00 = -1.0. Read unsigned it is +65280, which
    # saturates the membrane positive on the first tick and fires immediately
    # against this row's low threshold (115/256 = 0.449). Signed, the membrane
    # walks negative and the neuron never fires.
    s = Scenario(
        "dale_i_subtracts",
        "exp-025",
        "0xFF00 (-1.0) on a real Dale-I row must drive the membrane negative and "
        "never fire; an unsigned misread saturates positive and fires on tick 1.",
    )
    bank_ticks(s, 6, [0, 0, 0, 0, 0, 0])
    scenarios.append(s)

    # -- 2. Symmetric leak recovers an inhibited membrane. ------------------
    # Two inhibitory ticks, then leak-only. The real decay word (218/256) must
    # pull the membrane back up toward 0 and clamp there without overshooting
    # positive. A one-sided leak drives it further negative instead.
    s = Scenario(
        "dale_i_leak_recovery",
        "exp-025",
        "After real inhibition, the real decay word must recover the membrane "
        "toward 0 and clamp; a one-sided leak pushes it further negative.",
    )
    bank_ticks(s, 6, [0, 0])
    bank_ticks(s, 6, [None] * 4)
    scenarios.append(s)

    # -- 3. Excitatory row crosses its own real threshold. ------------------
    # Neuron 0 channel 0 (+308/256) against threshold 410/256 with decay
    # 218/256: fires on tick 3, not tick 2. Drop or shrink the leak and it
    # fires a tick early, so this pins the leak magnitude, not just its sign.
    s = Scenario(
        "exc_crosses_threshold",
        "exp-025",
        "Real excitatory weight/threshold/decay: the leak delays the crossing to "
        "tick 3, so a wrong leak magnitude shifts the spike tick. Also pins the "
        "single-tick pulse and the refractory clear.",
    )
    bank_ticks(s, 0, [0, 0, 0, 0, 0, 0])
    scenarios.append(s)

    # -- 4. Genuinely mixed-sign traffic on one real row. -------------------
    # Neuron 7 carries both -256 (ch0) and +79 (ch3). Alternating them walks
    # the membrane across zero in both directions.
    s = Scenario(
        "mixed_sign_alternating",
        "exp-025",
        "One real row alternating its inhibitory (ch0, -1.0) and excitatory "
        "(ch3, +0.309) words: the membrane must cross zero in both directions.",
    )
    bank_ticks(s, 7, [3, 0, 3, 3, 0, 3, 3, 0])
    scenarios.append(s)

    # -- 5. Inhibition applied to an already-positive membrane. -------------
    # Neuron 15 is the only shape in the bank where a positive membrane
    # survives the 218/256 decay long enough to then be inhibited: ch2 is
    # +405/256 (beats the leak) and ch3 is 0xFFFF, a real -1/256 word.
    # 0xFFFF is also the sharpest unsigned-misread probe in the whole bank --
    # read unsigned it is +65535, which saturates the membrane to 0x7FFF and
    # fires instantly against this row's 410/256 threshold. Signed, it barely
    # moves the membrane and nothing fires.
    s = Scenario(
        "inhibit_from_positive",
        "exp-025",
        "Real -1/256 (0xFFFF) subtracting from an already-positive membrane on a "
        "real row. Misread unsigned it is +65535: it would saturate and fire.",
    )
    bank_ticks(s, 15, [2, 3, 3, 2, 3])
    scenarios.append(s)

    # -- 5b. A real Dale row across spike, refractory, and recovery. ---------
    # Neuron 8 fires on its own ch1 word (+171 over a 115 threshold), clears
    # through refractory, is driven negative by ch0 (-256), then recovers.
    s = Scenario(
        "dale_i_row_spike_and_recover",
        "exp-025",
        "One real Dale row walked through fire -> refractory clear -> real "
        "inhibition -> leak recovery, all with its own bank threshold and decay.",
    )
    bank_ticks(s, 8, [1, 1, 0, 0, 1])
    scenarios.append(s)

    # -- 6. Positive saturation (synthetic: the bank has no such magnitude). -
    # 300.0 clamps at encode to +127.99 -> raw 32765. Two ticks overflow the
    # 16-bit datapath, which must saturate at 0x7FFF rather than wrap negative.
    s = Scenario(
        "saturate_positive",
        "synthetic",
        "Two +100.0 ticks overflow the 16-bit datapath: the membrane must pin at "
        "0x7FFF and fire there, not wrap to a negative value and stay silent.",
    )
    # +100.0 is below the +127.99 threshold on its own, so tick 1 must not
    # fire; two of them overflow the 16-bit datapath, which must saturate to
    # 0x7FFF (and only then cross). A wrapping datapath lands on a negative
    # membrane and never fires at all.
    s.ticks = [
        Tick(100.0, 127.99, 0.0, True, "synthetic +100.0"),
        Tick(100.0, 127.99, 0.0, True, "synthetic +100.0"),
        Tick(100.0, 127.99, 0.0, True, "synthetic +100.0"),
    ]
    scenarios.append(s)

    # -- 7. Negative saturation. --------------------------------------------
    s = Scenario(
        "saturate_negative",
        "synthetic",
        "Mirror of saturate_positive: the membrane must pin at 0x8000 and never "
        "fire. A wrapping datapath aliases to a large positive and fires.",
    )
    s.ticks = [
        Tick(-100.0, 0.5, 0.0, True, "synthetic -100.0"),
        Tick(-100.0, 0.5, 0.0, True, "synthetic -100.0"),
        Tick(-100.0, 0.5, 0.0, True, "synthetic -100.0"),
    ]
    scenarios.append(s)

    # -- 8. Encoder truncation / sub-LSB behaviour. -------------------------
    # Pins truncate-toward-zero on both signs and the 1-LSB quantum. -0.999
    # must encode to -255 (toward zero), not -256 (away).
    s = Scenario(
        "f32_truncation",
        "synthetic",
        "f32 values chosen to pin truncate-toward-zero on both signs "
        "(+/-0.999 -> +/-255) and the 1/256 LSB quantum.",
    )
    # Threshold parked at the clamp ceiling and leak at 0, so nothing fires and
    # nothing decays: the membrane is a running sum of the encoded words, which
    # makes an off-by-one-LSB encode visible directly in the expected trace.
    for value in (0.999, 0.999, -0.999, 1.0 / 256.0, -1.0 / 256.0, 0.9999):
        s.ticks.append(Tick(value, 127.99, 0.0, True, f"synthetic {value!r}"))
    scenarios.append(s)

    return scenarios


# --------------------------------------------------------------------------
# Encode + simulate + emit
# --------------------------------------------------------------------------


def encode_scenarios(scenarios: list[Scenario], bank: Bank) -> dict:
    """Encode every tick to Q8.8, run the reference model, and build the manifest."""
    weights: list[int] = []
    thresholds: list[int] = []
    leaks: list[int] = []
    spike_ins: list[int] = []
    resets: list[int] = []
    model_ticks = []
    manifest_scenarios = []

    bank_words = set(bank.weights) | set(bank.thresholds) | set(bank.decay)

    for scenario in scenarios:
        first_index = len(weights)
        for position, tick in enumerate(scenario.ticks):
            raw_weight = q88.encode_q88_signed(tick.weight)
            raw_threshold = q88.encode_q88_signed(tick.threshold)
            raw_leak = q88.encode_q88_signed(tick.leak)

            # Backstop tripwire. Bank.weight_f32() already proves the round
            # trip is exact at the point of decode, and
            # tests/test_golden_lif_vectors.py re-checks every word against its
            # stated bank address. This only catches a hand-edited scenario
            # that slipped a foreign constant into an exp-025 block.
            if scenario.source == "exp-025" and raw_weight not in bank_words:
                raise SystemExit(
                    f"{scenario.name} tick {position}: {q88.raw_to_hex(raw_weight)} does not "
                    "appear anywhere in the pinned bank, so this scenario is not exp-025 data. "
                    "Tag it 'synthetic' or use a real bank word."
                )

            weights.append(raw_weight)
            thresholds.append(raw_threshold)
            leaks.append(raw_leak)
            spike_ins.append(1 if tick.spike_in else 0)
            resets.append(1 if position == 0 else 0)
            model_ticks.append(
                (raw_weight, raw_threshold, raw_leak, tick.spike_in, position == 0)
            )

        manifest_scenarios.append(
            {
                "name": scenario.name,
                "source": scenario.source,
                "why": scenario.why,
                "first_tick": first_index,
                "tick_count": len(scenario.ticks),
                "ticks": [
                    {
                        "weight_f32": tick.weight,
                        "weight_q88": q88.raw_to_hex(q88.encode_q88_signed(tick.weight)),
                        "weight_origin": tick.weight_origin,
                        "threshold_q88": q88.raw_to_hex(q88.encode_q88_signed(tick.threshold)),
                        "leak_q88": q88.raw_to_hex(q88.encode_q88_signed(tick.leak)),
                        "spike_in": tick.spike_in,
                    }
                    for tick in scenario.ticks
                ],
            }
        )

    trace = lif.run(model_ticks)
    exp_membrane = [state.membrane for state in trace]
    exp_spike = [1 if state.spike_out else 0 for state in trace]

    for entry in manifest_scenarios:
        start = entry["first_tick"]
        stop = start + entry["tick_count"]
        for tick_entry, state in zip(entry["ticks"], trace[start:stop]):
            tick_entry["expect_membrane_q88"] = q88.raw_to_hex(state.membrane)
            tick_entry["expect_membrane_f32"] = q88.q88_signed_to_f32(state.membrane)
            tick_entry["expect_spike"] = state.spike_out

    return {
        "weights": weights,
        "thresholds": thresholds,
        "leaks": leaks,
        "spike_ins": spike_ins,
        "resets": resets,
        "exp_membrane": exp_membrane,
        "exp_spike": exp_spike,
        "manifest_scenarios": manifest_scenarios,
    }


def output_layer_vectors(bank: Bank) -> dict:
    """Golden vectors for the GH#72 output layer, over the same pinned bank.

    ``OutputLayer`` reduces one tick's ``spike_bitmap`` into ``NUM_CLASSES``
    signed Q8.8 scores (``addr = neuron*NUM_CLASSES + class``) and reports the
    argmax one-hot, ties to the lowest class. This mirrors that exactly.
    """
    # Chosen so every class wins at least once and the negative output weights
    # (neurons 12-15) are exercised on their own -- otherwise every vector
    # would land on class 0 and the argmax would never be under test.
    bitmaps = [
        0x0000,  # no spikes: all scores 0, tie -> lowest class wins
        0x0001,  # neuron 0 alone            -> class 0
        0x0040,  # neuron 6 alone            -> class 1
        0x0100,  # neuron 8 alone            -> class 2
        0x0007,  # neurons 0-2
        0x03C0,  # neurons 6-9, the inhibitory block
        0xF000,  # neurons 12-15: every weight here is <= 0, so the scores go
                 # negative. Misread unsigned they saturate positive and the
                 # argmax flips off class 0.
        0xFFFF,  # every neuron
        0x8001,  # lowest and highest lanes
        0xAAAA,  # alternating lanes
    ]

    results = []
    for bitmap in bitmaps:
        scores = [0] * NUM_CLASSES
        for neuron in range(NUM_NEURONS):
            if not (bitmap >> neuron) & 1:
                continue
            for klass in range(NUM_CLASSES):
                weight = bank.output_weights[neuron * NUM_CLASSES + klass]
                total = scores[klass] + weight
                # Per-step saturation, mirroring OutputLayer.sv's guard-bit idiom.
                scores[klass] = max(lif.MIN_MEM, min(lif.MAX_MEM, total))
        best = 0
        for klass in range(1, NUM_CLASSES):
            if scores[klass] > scores[best]:
                best = klass
        results.append(
            {
                "spike_bitmap": f"{bitmap:04X}",
                "scores_q88": [q88.raw_to_hex(score) for score in scores],
                "scores_f32": [q88.q88_signed_to_f32(score) for score in scores],
                "argmax_class": best,
                "result_onehot": f"{1 << best:04X}",
            }
        )

    return {
        "bitmaps": bitmaps,
        "onehot": [1 << entry["argmax_class"] for entry in results],
        "manifest": results,
    }


def emit(target: Path, encoded: dict, output_layer: dict) -> None:
    target.mkdir(parents=True, exist_ok=True)
    header = "\n".join(BANNER)

    # Signed Q8.8 numbers.
    q88_files = {
        "lif_golden_weights.mem": encoded["weights"],
        "lif_golden_thresholds.mem": encoded["thresholds"],
        "lif_golden_leaks.mem": encoded["leaks"],
        "lif_golden_exp_membrane.mem": encoded["exp_membrane"],
    }
    for name, words in q88_files.items():
        q88.write_mem(target / name, words, header=header)

    # Bit patterns and counts -- not fixed-point values.
    pattern_files = {
        "lif_golden_spike_in.mem": encoded["spike_ins"],
        "lif_golden_reset.mem": encoded["resets"],
        "lif_golden_exp_spike.mem": encoded["exp_spike"],
        # A one-word count so the testbench never has to hardcode a length and
        # never reads uninitialised entries of its oversized arrays.
        "lif_golden_count.mem": [len(encoded["weights"])],
        "outlayer_golden_bitmap.mem": output_layer["bitmaps"],
        "outlayer_golden_exp_result.mem": output_layer["onehot"],
        "outlayer_golden_count.mem": [len(output_layer["bitmaps"])],
    }
    for name, words in pattern_files.items():
        q88.write_words(target / name, words, header=header)

    manifest = {
        "generated_by": "scripts/gen_golden_lif_vectors.py",
        "issue": "GH#66 / RM-281",
        "do_not_edit": "Regenerate with: python3 scripts/gen_golden_lif_vectors.py",
        "q88": {
            "convention": "signed two's-complement Q8.8 (GH#73)",
            "codec": "scripts/q88.py, mirroring silicon-bridge encode_q88_signed",
            "clamp_f32": [q88.Q88_CLAMP_MIN, q88.Q88_CLAMP_MAX],
            "rounding": "truncate toward zero",
        },
        "bank": {
            "source": SPIKENAUT_BANK_SOURCE,
            "commit": SPIKENAUT_BANK_COMMIT,
            "images": [
                "spikenaut-core-sv/mem/merged_v2_weights.mem",
                "spikenaut-core-sv/mem/merged_v2_thresholds.mem",
                "spikenaut-core-sv/mem/merged_v2_decay.mem",
                "spikenaut-core-sv/mem/merged_v2_output_weights.mem",
            ],
            "content_digests_sha256": dict(BANK_DIGESTS),
            "digest_note": (
                "SHA-256 over each image's canonical word stream, not its raw bytes; "
                "see q88.content_digest."
            ),
        },
        "lif": {
            "dut": "spikenaut-core-sv/rtl/LifNeuron.sv",
            "testbench": "spikenaut-core-sv/tb/tb_LifNeuron_golden.sv",
            "reference_model": "scripts/lif_reference.py",
            "tick_count": len(encoded["weights"]),
            "scenarios": encoded["manifest_scenarios"],
        },
        "output_layer": {
            "dut": "spikenaut-core-sv/rtl/OutputLayer.sv",
            "testbench": "spikenaut-core-sv/tb/tb_OutputLayer_golden.sv",
            "weight_image": "spikenaut-core-sv/mem/merged_v2_output_weights.mem",
            "addressing": "addr = neuron * NUM_CLASSES + class",
            "tie_break": "lowest class index wins",
            "vectors": output_layer["manifest"],
        },
    }
    (target / "golden_vectors.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n"
    )


GENERATED_NAMES = (
    "lif_golden_weights.mem",
    "lif_golden_thresholds.mem",
    "lif_golden_leaks.mem",
    "lif_golden_spike_in.mem",
    "lif_golden_reset.mem",
    "lif_golden_exp_membrane.mem",
    "lif_golden_exp_spike.mem",
    "lif_golden_count.mem",
    "outlayer_golden_bitmap.mem",
    "outlayer_golden_exp_result.mem",
    "outlayer_golden_count.mem",
    "golden_vectors.json",
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="do not write; exit non-zero if regenerating would change the committed vectors",
    )
    args = parser.parse_args(argv)

    bank = Bank()
    encoded = encode_scenarios(build_scenarios(bank), bank)
    output_layer = output_layer_vectors(bank)

    if not args.check:
        emit(GOLDEN_DIR, encoded, output_layer)
        print(
            f"wrote {len(GENERATED_NAMES)} files to {GOLDEN_DIR.relative_to(REPO_ROOT)}/ "
            f"({len(encoded['weights'])} LIF ticks, "
            f"{len(output_layer['bitmaps'])} output-layer vectors)"
        )
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        fresh = Path(tmp)
        emit(fresh, encoded, output_layer)
        stale = [
            name
            for name in GENERATED_NAMES
            if not (GOLDEN_DIR / name).exists()
            or not filecmp.cmp(fresh / name, GOLDEN_DIR / name, shallow=False)
        ]

    if stale:
        print("golden vectors are out of date:", file=sys.stderr)
        for name in stale:
            print(f"  {(GOLDEN_DIR / name).relative_to(REPO_ROOT)}", file=sys.stderr)
        print(
            "\nRegenerate with: python3 scripts/gen_golden_lif_vectors.py\n"
            "If you did not intend to change LIF semantics, the codec, or the "
            "pinned bank, this is the drift this check exists to catch.",
            file=sys.stderr,
        )
        return 1

    print(f"golden vectors up to date ({len(GENERATED_NAMES)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

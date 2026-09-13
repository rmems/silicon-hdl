#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate the golden SiliconBridge v3.0 UART frame vectors (GH#64).

Run from the repo root::

    python3 scripts/gen_golden_frame_vectors.py            # regenerate in place
    python3 scripts/gen_golden_frame_vectors.py --check    # fail if regenerating would change anything

``--check`` is the drift gate, same contract as
``scripts/gen_golden_lif_vectors.py``: it regenerates into a temporary
directory and diffs against what is committed, so a change to the codec or to
the pinned bank cannot land without the vectors being refreshed in the same
commit. ``scripts/quality.sh`` and ``tests/test_golden_frame_vectors.py`` both
run it.

What this pins, and what it deliberately does not
-------------------------------------------------
This generator pins the **wire framing contract** between the host
(``rmems/silicon-bridge`` ``src/fpga_bridge.rs::process_stimuli``) and the F1
SoC (``spikenaut-soc-sv/rtl/SocProtocolFsm.sv``): byte count, byte order, lane
order, spike bit order, and signedness. It does *not* model neural behaviour —
what the SoC computes from a stimulus is pinned by the GH#66 LIF and
output-layer goldens (``scripts/gen_golden_lif_vectors.py``). Splitting them
this way is deliberate: the framing contract is the thing two repositories
have to agree on, and it is checkable without a reference simulation of the
whole SoC tick.

The frame is **36 bytes in the response direction and 33 in the request
direction**, and GH#64 does not change either. GH#72's output-class flags are
LED-only (``status_word[15:13]``, see ``docs/led-map.md``); they add no bytes.
``tests/test_golden_frame_vectors.py`` asserts both lengths against the values
the Rust host hardcodes.

What is and is not invented here
--------------------------------
Cases tagged ``exp-025`` take every ``f32`` from a **decode of a word already
committed** under ``spikenaut-core-sv/mem/`` (the exp-025 Dale bank promoted in
Spikenaut-SNN#47 @ ``6965e12a``). The generator decodes the bank to ``f32`` and
re-encodes, asserting the round trip returns the identical word — which is what
makes the ``f32 -> Q8.8 -> bytes`` leg real rather than decorative. No trained
weight is authored here.

Cases tagged ``synthetic`` exist to reach framing edges the bank cannot
express: lane-by-lane walks that catch a transposition, single-bit spike words
at each end of the bitmap, the all-ones and all-zero frames, and the +/-127.99
clamp. They carry no claim about the network.

See ``docs/host-soc-e2e.md``.
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

REPO_ROOT = Path(__file__).resolve().parent.parent
BANK_DIR = REPO_ROOT / "spikenaut-core-sv" / "mem"
GOLDEN_DIR = BANK_DIR / "golden"

#: Spikenaut-SNN commit the live exp-025 Dale bank was promoted at
#: (Spikenaut-SNN#47). Kept in step with ``gen_golden_lif_vectors.py``; the
#: digests below are the enforceable half of the claim.
SPIKENAUT_BANK_COMMIT = "6965e12a"
SPIKENAUT_BANK_SOURCE = "rmems/Spikenaut-SNN dataset/merged_v2 (exp-025 Dale health-PASS bank, PR #47)"

#: SHA-256 of each pinned image's canonical word stream (see
#: ``q88.content_digest``). Only the images this generator actually reads are
#: listed; ``gen_golden_lif_vectors.py`` pins the output-weight image too.
BANK_DIGESTS = {
    "merged_v2_weights.mem": "825969873444d215d09920e69592700a2cc8594d92e7b14c4059eef8919fe4f3",
    "merged_v2_thresholds.mem": "2aff910820757f7015f7097dae0aa00f631fc49d2a5df912b35ba92e309f7a70",
    "merged_v2_decay.mem": "bbb575d31ebd5e0386037c3421d17212b3645522f4e64d02272bb5d6abc0610d",
}

# --------------------------------------------------------------------------
# Wire protocol geometry (SiliconBridge v3.0, N=16, 16-bit words).
# These mirror SocProtocolFsm's localparams; see docs/host-soc-e2e.md.
# --------------------------------------------------------------------------

NUM_NEURONS = 16
WORD_WIDTH = 16
BYTES_PER_WORD = WORD_WIDTH // 8
PAYLOAD_BYTES = NUM_NEURONS * BYTES_PER_WORD          # 32
#: Response frame: potentials + spike-flag word + aux word.
RESPONSE_BYTES = PAYLOAD_BYTES + 2 * BYTES_PER_WORD   # 36
#: Request frame: 0xAA sync + the stimulus payload.
REQUEST_BYTES = 1 + PAYLOAD_BYTES                     # 33
SYNC_BYTE = 0xAA
#: Distinct sync for the 0xA5 RAM-write frame (GH#63). Not exercised by these
#: vectors; recorded so the manifest documents the whole byte pipe.
WRITE_SYNC_BYTE = 0xA5
WRITE_FRAME_BYTES = 5

BANNER = (
    "GENERATED FILE -- do not edit by hand.",
    "Regenerate: python3 scripts/gen_golden_frame_vectors.py",
    "Source bank: " + SPIKENAUT_BANK_SOURCE,
    "Pinned at Spikenaut-SNN commit " + SPIKENAUT_BANK_COMMIT,
    "See docs/host-soc-e2e.md (GH#64).",
)
BANNER_TEXT = "\n".join(BANNER)

GENERATED_NAMES = (
    "frame_golden_count.mem",
    "frame_golden_host_tx.mem",
    "frame_golden_soc_rx.mem",
    "frame_golden_stimuli.mem",
    "frame_golden_potentials.mem",
    "frame_golden_spikes.mem",
    "frame_golden_aux.mem",
    "frame_golden_vectors.json",
)


# --------------------------------------------------------------------------
# Case description. Everything is authored in host f32 / bit patterns.
# --------------------------------------------------------------------------


@dataclass
class Case:
    """One request/response frame pair, described in host units."""

    name: str
    source: str  # "exp-025" or "synthetic"
    why: str
    #: Host stimulus, lane 0 first. Lane 0 is the first word on the wire.
    stimuli_f32: list[float]
    #: SoC membrane potentials, lane 0 first.
    potentials_f32: list[float]
    #: Spike-flag word: bit i is neuron i, so bit 0 is the LSB.
    spike_word: int
    #: Aux word (the synchronized switch bus, response bytes 34-35).
    aux_word: int
    #: Where each f32 came from, for the manifest.
    origin: str


class Bank:
    """The committed exp-025 images, decoded to ``f32``."""

    def __init__(self) -> None:
        self.weights = q88.read_mem(BANK_DIR / "merged_v2_weights.mem")
        self.thresholds = q88.read_mem(BANK_DIR / "merged_v2_thresholds.mem")
        self.decay = q88.read_mem(BANK_DIR / "merged_v2_decay.mem")

        expected_weights = NUM_NEURONS * NUM_NEURONS
        if len(self.weights) != expected_weights:
            raise SystemExit(
                f"merged_v2_weights.mem has {len(self.weights)} words, expected {expected_weights}"
            )
        for name, words in (("thresholds", self.thresholds), ("decay", self.decay)):
            if len(words) != NUM_NEURONS:
                raise SystemExit(
                    f"merged_v2_{name}.mem has {len(words)} words, expected {NUM_NEURONS}"
                )

        # Length checks cannot see a retrain that keeps the word count, so the
        # provenance claim is enforced by content digest.
        for name, expected in BANK_DIGESTS.items():
            actual = q88.content_digest(BANK_DIR / name)
            if actual != expected:
                raise SystemExit(
                    f"{name} no longer matches the pinned exp-025 bank.\n"
                    f"  expected {expected}\n  actual   {actual}\n"
                    "If the bank was intentionally retrained, bump "
                    "SPIKENAUT_BANK_COMMIT and BANK_DIGESTS in this script and "
                    "in scripts/gen_golden_lif_vectors.py together, then regenerate."
                )

    def weight_column(self, channel: int) -> list[float]:
        """``weights[n][channel]`` for every neuron, decoded to ``f32``."""
        return [q88.q88_signed_to_f32(self.weights[n * NUM_NEURONS + channel])
                for n in range(NUM_NEURONS)]

    def weight_row(self, neuron: int) -> list[float]:
        """``weights[neuron][c]`` for every channel, decoded to ``f32``."""
        return [q88.q88_signed_to_f32(self.weights[neuron * NUM_NEURONS + c])
                for c in range(NUM_NEURONS)]

    def threshold_vector(self) -> list[float]:
        return [q88.q88_signed_to_f32(w) for w in self.thresholds]

    def decay_vector(self) -> list[float]:
        return [q88.q88_signed_to_f32(w) for w in self.decay]


def build_cases(bank: Bank) -> list[Case]:
    """Author the frame cases.

    Ordering matters only for reproducibility; the testbench replays them in
    index order and the manifest maps index to name.
    """
    lsb = 1.0 / q88.Q88_SCALE

    return [
        Case(
            name="bank_ei_column",
            source="exp-025",
            why=(
                "A real mixed Dale E/I vector in both directions: neurons 6-9 carry "
                "-1.0 (0xFF00) and the rest ~+1.2. A host that decodes the response "
                "unsigned reads 255.0 where the SoC sent -1.0, and an RTL side that "
                "packs lanes MSB-first swaps the inhibitory group to the other end."
            ),
            stimuli_f32=bank.weight_column(0),
            potentials_f32=bank.threshold_vector(),
            # The four Dale-I lanes, so the bitmap is tied to the same rows the
            # payload makes recognisable.
            spike_word=0x03C0,
            aux_word=0x0000,
            origin="stimuli=weights[n][ch0], potentials=thresholds[n]",
        ),
        Case(
            name="bank_inhibitory_row",
            source="exp-025",
            why=(
                "An all-non-positive frame from Dale-I row n6 (0xFF00, 0xFF0D, 0xFF1D, "
                "0xFF8A, then zeros). The aux word is 0xA5A5, the switch pattern "
                "tb_Basys3_Top.sv drives, so the golden bytes and the SoC testbench "
                "agree on what bytes 34-35 should carry."
            ),
            stimuli_f32=bank.weight_row(6),
            potentials_f32=bank.weight_row(6),
            spike_word=0x0000,
            aux_word=0xA5A5,
            origin="stimuli=potentials=weights[n6][c]",
        ),
        Case(
            name="lane_walk",
            source="synthetic",
            why=(
                "Every lane differs from its neighbour by exactly one Q8.8 LSB, so any "
                "lane transposition, off-by-one lane offset, or byte-swapped word "
                "changes the stream. Positive on request, negative on response, so the "
                "two directions cannot be confused. spike_word=0x0001 pins bit 0 to "
                "neuron 0."
            ),
            stimuli_f32=[(i + 1) * lsb for i in range(NUM_NEURONS)],
            potentials_f32=[-(i + 1) * lsb for i in range(NUM_NEURONS)],
            spike_word=0x0001,
            aux_word=0x0102,
            origin="synthetic lane-index walk",
        ),
        Case(
            name="lane15_only",
            source="synthetic",
            why=(
                "The mirror of lane_walk at the other end of the vector: only lane 15 "
                "is non-zero and only bit 15 is set. A reversed spike-bit order or a "
                "reversed lane order swaps this case with lane_walk, so the pair pins "
                "the direction that neither case pins alone."
            ),
            stimuli_f32=[0.0] * (NUM_NEURONS - 1) + [1.0],
            potentials_f32=[0.0] * (NUM_NEURONS - 1) + [-1.0],
            spike_word=0x8000,
            aux_word=0x8000,
            origin="synthetic single-lane edge",
        ),
        Case(
            name="all_ones",
            source="synthetic",
            why=(
                "The all-ones edge. spike_word and aux_word are 0xFFFF, which is a bit "
                "pattern and not the Q8.8 value -1/256: a tool that range-checks them "
                "as fixed-point numbers fails here rather than in production."
            ),
            stimuli_f32=[1.0] * NUM_NEURONS,
            potentials_f32=[1.0] * NUM_NEURONS,
            spike_word=0xFFFF,
            aux_word=0xFFFF,
            origin="synthetic all-ones edge",
        ),
        Case(
            name="all_zeros",
            source="synthetic",
            why=(
                "The all-zero frame must still be exactly 36 bytes. This case is also "
                "why the testbench needs a vacuity guard: an unloaded $readmemh array "
                "reads all-zero and would match this case, so the count image and a "
                "non-zero-expectation check are what prove the images actually loaded."
            ),
            stimuli_f32=[0.0] * NUM_NEURONS,
            potentials_f32=[0.0] * NUM_NEURONS,
            spike_word=0x0000,
            aux_word=0x0000,
            origin="synthetic all-zero edge",
        ),
        Case(
            name="clamp_saturation",
            source="synthetic",
            why=(
                "Alternating +/-127.99, the clamp bounds shared with silicon-bridge's "
                "STIMULUS_Q88_MIN/MAX. Saturation lands on 0x7FFD / 0x8003, not on the "
                "i16 limits, because the clamp is applied to the unscaled f32 -- so "
                "these bytes catch a clamp moved to the raw word."
            ),
            stimuli_f32=[q88.Q88_CLAMP_MAX if i % 2 == 0 else q88.Q88_CLAMP_MIN
                         for i in range(NUM_NEURONS)],
            potentials_f32=[q88.Q88_CLAMP_MIN if i % 2 == 0 else q88.Q88_CLAMP_MAX
                            for i in range(NUM_NEURONS)],
            spike_word=0x5555,
            aux_word=0x7FFD,
            origin="synthetic clamp edge",
        ),
        Case(
            name="bank_decay_thresholds",
            source="exp-025",
            why=(
                "Real bank words with the complement of clamp_saturation's bitmap "
                "(0xAAAA) and the 0x5AA5 aux pattern. A stuck spike byte that passes "
                "0x5555 fails 0xAAAA."
            ),
            stimuli_f32=bank.decay_vector(),
            potentials_f32=bank.threshold_vector(),
            spike_word=0xAAAA,
            aux_word=0x5AA5,
            origin="stimuli=decay[n], potentials=thresholds[n]",
        ),
    ]


# --------------------------------------------------------------------------
# Encoding: f32 -> Q8.8 -> wire bytes.
# --------------------------------------------------------------------------


def encode_vector(values: list[float], *, bank_sourced: bool) -> list[int]:
    """Encode one 16-lane ``f32`` vector to signed raw Q8.8 words.

    ``bank_sourced`` asserts the round trip: a value that came from decoding a
    committed bank word must re-encode to that exact word, otherwise the
    ``f32 -> Q8.8`` leg of the claim is not real.
    """
    if len(values) != NUM_NEURONS:
        raise SystemExit(f"expected {NUM_NEURONS} lanes, got {len(values)}")
    raws = [q88.encode_q88_signed(v) for v in values]
    if bank_sourced:
        for lane, (value, raw) in enumerate(zip(values, raws)):
            if q88.q88_signed_to_f32(raw) != value:
                raise SystemExit(
                    f"lane {lane}: f32 {value!r} did not survive the Q8.8 round trip "
                    f"(re-encoded to {q88.raw_to_hex(raw)}); it cannot have come from "
                    "a committed bank word"
                )
    return raws


def request_frame(stimulus_raws: list[int]) -> list[int]:
    """Build the 33-byte host request: 0xAA then 16 big-endian Q8.8 words, lane 0 first."""
    frame = [SYNC_BYTE]
    for raw in stimulus_raws:
        frame.extend(q88.q88_to_be_bytes(raw))
    if len(frame) != REQUEST_BYTES:
        raise SystemExit(f"request frame is {len(frame)} bytes, expected {REQUEST_BYTES}")
    return frame


def response_frame(potential_raws: list[int], spike_word: int, aux_word: int) -> list[int]:
    """Build the 36-byte SoC response: potentials, spike-flag word, aux word.

    All three fields are big-endian per word and lane 0 is first, matching
    ``SocProtocolFsm``'s serializer and ``fpga_bridge.rs``'s reader.
    """
    for name, word in (("spike_word", spike_word), ("aux_word", aux_word)):
        if not (0 <= word <= 0xFFFF):
            raise SystemExit(f"{name} {word} does not fit in 16 bits")
    frame: list[int] = []
    for raw in potential_raws:
        frame.extend(q88.q88_to_be_bytes(raw))
    frame.extend(((spike_word >> 8) & 0xFF, spike_word & 0xFF))
    frame.extend(((aux_word >> 8) & 0xFF, aux_word & 0xFF))
    if len(frame) != RESPONSE_BYTES:
        raise SystemExit(f"response frame is {len(frame)} bytes, expected {RESPONSE_BYTES}")
    return frame


def encode_cases(cases: list[Case]) -> dict:
    """Encode every case into the flat images the testbench reads."""
    host_tx: list[int] = []
    soc_rx: list[int] = []
    stimuli_words: list[int] = []
    potential_words: list[int] = []
    spike_words: list[int] = []
    aux_words: list[int] = []
    manifest: list[dict] = []

    for index, case in enumerate(cases):
        bank_sourced = case.source == "exp-025"
        stimulus_raws = encode_vector(case.stimuli_f32, bank_sourced=bank_sourced)
        potential_raws = encode_vector(case.potentials_f32, bank_sourced=bank_sourced)

        request = request_frame(stimulus_raws)
        response = response_frame(potential_raws, case.spike_word, case.aux_word)

        host_tx.extend(request)
        soc_rx.extend(response)
        stimuli_words.extend(raw & 0xFFFF for raw in stimulus_raws)
        potential_words.extend(raw & 0xFFFF for raw in potential_raws)
        spike_words.append(case.spike_word)
        aux_words.append(case.aux_word)

        manifest.append({
            "index": index,
            "name": case.name,
            "source": case.source,
            "why": case.why,
            "origin": case.origin,
            "stimuli_f32": case.stimuli_f32,
            "stimuli_q88": [q88.raw_to_hex(raw) for raw in stimulus_raws],
            "potentials_f32": case.potentials_f32,
            "potentials_q88": [q88.raw_to_hex(raw) for raw in potential_raws],
            "spike_word": f"{case.spike_word:04X}",
            "aux_word": f"{case.aux_word:04X}",
            "host_tx_bytes": " ".join(f"{b:02X}" for b in request),
            "soc_rx_bytes": " ".join(f"{b:02X}" for b in response),
        })

    return {
        "count": len(cases),
        "host_tx": host_tx,
        "soc_rx": soc_rx,
        "stimuli_words": stimuli_words,
        "potential_words": potential_words,
        "spike_words": spike_words,
        "aux_words": aux_words,
        "manifest": manifest,
    }


def emit(target: Path, encoded: dict) -> None:
    """Write every generated file into ``target``."""
    target.mkdir(parents=True, exist_ok=True)

    q88.write_words(target / "frame_golden_count.mem", [encoded["count"]], header=BANNER_TEXT)
    q88.write_bytes(target / "frame_golden_host_tx.mem", encoded["host_tx"], header=BANNER_TEXT)
    q88.write_bytes(target / "frame_golden_soc_rx.mem", encoded["soc_rx"], header=BANNER_TEXT)
    q88.write_words(target / "frame_golden_stimuli.mem", encoded["stimuli_words"], header=BANNER_TEXT)
    q88.write_words(target / "frame_golden_potentials.mem", encoded["potential_words"], header=BANNER_TEXT)
    q88.write_words(target / "frame_golden_spikes.mem", encoded["spike_words"], header=BANNER_TEXT)
    q88.write_words(target / "frame_golden_aux.mem", encoded["aux_words"], header=BANNER_TEXT)

    manifest = {
        "generated_by": "scripts/gen_golden_frame_vectors.py",
        "issue": "GH#64 / RM-288",
        "do_not_edit": "Regenerate with: python3 scripts/gen_golden_frame_vectors.py",
        "q88": {
            "convention": "signed two's-complement Q8.8 (GH#73)",
            "codec": "scripts/q88.py, mirroring silicon-bridge encode_q88_signed",
            "clamp_f32": [q88.Q88_CLAMP_MIN, q88.Q88_CLAMP_MAX],
            "rounding": "truncate toward zero",
        },
        "wire_protocol": {
            "name": "SiliconBridge v3.0",
            "soc_codec": "spikenaut-soc-sv/rtl/SocProtocolFsm.sv",
            "host_codec": "rmems/silicon-bridge src/fpga_bridge.rs (FpgaBridge::process_stimuli)",
            "num_neurons": NUM_NEURONS,
            "word_width": WORD_WIDTH,
            "word_endianness": "big-endian per 16-bit word, both directions",
            "lane_order": "lane 0 first on the wire; lane 0 is the LSB of the packed RTL vector",
            "spike_bit_order": "bit i = neuron i, so bit 0 (LSB) is neuron 0",
            "request_sync_byte": f"{SYNC_BYTE:02X}",
            "request_bytes": REQUEST_BYTES,
            "response_bytes": RESPONSE_BYTES,
            "response_layout": {
                "0..31": "16 potentials, signed Q8.8, lane 0 first",
                "32..33": "spike-flag word",
                "34..35": "aux word (synchronized switch bus)",
            },
            "write_frame": {
                "sync_byte": f"{WRITE_SYNC_BYTE:02X}",
                "bytes": WRITE_FRAME_BYTES,
                "note": "GH#63 RAM-write frame; on the same byte pipe, not exercised by these vectors",
            },
            "gh72_note": (
                "GH#72's output-class flags are LED-only (status_word[15:13], "
                "docs/led-map.md). They add no response bytes: response_bytes stays "
                f"{RESPONSE_BYTES}."
            ),
        },
        "bank": {
            "source": SPIKENAUT_BANK_SOURCE,
            "commit": SPIKENAUT_BANK_COMMIT,
            "images": [f"spikenaut-core-sv/mem/{name}" for name in BANK_DIGESTS],
            "content_digests_sha256": dict(BANK_DIGESTS),
            "digest_note": (
                "SHA-256 over each image's canonical word stream, not its raw bytes; "
                "see q88.content_digest."
            ),
        },
        "frames": {
            "testbench": "spikenaut-soc-sv/tb/tb_SocFrameGolden.sv",
            "wire_level_testbench": "spikenaut-soc-sv/tb/tb_Basys3_Top.sv (test 12)",
            "host_model_test": "tests/test_golden_frame_vectors.py",
            "runbook": "docs/host-soc-e2e.md",
            "case_count": encoded["count"],
            "cases": encoded["manifest"],
        },
    }
    (target / "frame_golden_vectors.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="do not write; exit non-zero if regenerating would change the committed vectors",
    )
    args = parser.parse_args(argv)

    encoded = encode_cases(build_cases(Bank()))

    if not args.check:
        emit(GOLDEN_DIR, encoded)
        print(
            f"wrote {len(GENERATED_NAMES)} files to {GOLDEN_DIR.relative_to(REPO_ROOT)}/ "
            f"({encoded['count']} frame cases, "
            f"{len(encoded['host_tx'])} request bytes, {len(encoded['soc_rx'])} response bytes)"
        )
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        fresh = Path(tmp)
        emit(fresh, encoded)
        stale = [
            name
            for name in GENERATED_NAMES
            if not (GOLDEN_DIR / name).exists()
            or not filecmp.cmp(fresh / name, GOLDEN_DIR / name, shallow=False)
        ]

    if stale:
        print("golden frame vectors are out of date:", file=sys.stderr)
        for name in stale:
            print(f"  {(GOLDEN_DIR / name).relative_to(REPO_ROOT)}", file=sys.stderr)
        print(
            "\nRegenerate with: python3 scripts/gen_golden_frame_vectors.py\n"
            "If you did not intend to change the wire framing, the codec, or the "
            "pinned bank, this is the drift this check exists to catch.",
            file=sys.stderr,
        )
        return 1

    print(f"golden frame vectors up to date ({len(GENERATED_NAMES)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

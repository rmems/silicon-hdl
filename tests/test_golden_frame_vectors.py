# SPDX-License-Identifier: MIT OR Apache-2.0
"""Host-side gate for the GH#64 golden SiliconBridge v3.0 frame vectors.

``tb_SocFrameGolden`` replays the committed golden frames through the real
``SocProtocolFsm``, so the RTL end of the contract is covered under Verilator.
This module covers the **host** end and the vectors themselves:

1. **The committed vectors** -- regenerating must be a no-op, and the images
   must have exactly the lengths the frame geometry implies.
2. **The host decoder** -- a Python model of
   ``rmems/silicon-bridge src/fpga_bridge.rs::process_stimuli`` must recover the
   authored ``f32`` / spike / aux values from the golden response bytes, and
   must produce the golden request bytes from the authored stimuli. If the two
   repositories ever disagree about byte order, lane order, spike bit order, or
   signedness, one of these fails.
3. **What the vectors actually pin** -- decoding them the *wrong* way must
   produce different values. Without this, the vectors could be perfectly
   reproducible and still assert nothing.

The host model here is a model, not the crate: it is a transcription of the
Rust decode kept deliberately short so a reviewer can diff it against
``fpga_bridge.rs`` by eye. Running the real crate against these bytes belongs to
silicon-bridge's own suite (see ``docs/host-soc-e2e.md``); what this file buys
is that a framing change in *this* repository fails here, in this repository's
CI, instead of on a board.

See ``docs/host-soc-e2e.md``.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import gen_golden_frame_vectors as gen  # noqa: E402
import q88  # noqa: E402

GOLDEN_DIR = REPO_ROOT / "spikenaut-core-sv" / "mem" / "golden"

#: Byte counts the Rust host hardcodes (``vec![0u8; 36]`` / ``read_exact``, and
#: ``0xAA`` plus 16 two-byte words on TX). Asserted rather than imported so a
#: change on either side of the wire has to be made deliberately in both.
HOST_RESPONSE_BYTES = 36
HOST_REQUEST_BYTES = 33

GENERATED_MEM_FILES = (
    "frame_golden_count.mem",
    "frame_golden_host_tx.mem",
    "frame_golden_soc_rx.mem",
    "frame_golden_stimuli.mem",
    "frame_golden_potentials.mem",
    "frame_golden_spikes.mem",
    "frame_golden_aux.mem",
)


# --------------------------------------------------------------------------
# A transcription of the silicon-bridge host codec
# --------------------------------------------------------------------------


def host_encode_request(stimuli: list[float]) -> list[int]:
    """Model of ``process_stimuli``'s TX half.

    Rust::

        let mut tx_data = vec![0xAAu8];
        for i in 0..16 {
            let s = stimuli.get(i).copied().unwrap_or(0.0);
            tx_data.extend_from_slice(&crate::encode_q88_signed(s).to_be_bytes());
        }
    """
    frame = [0xAA]
    for lane in range(gen.NUM_NEURONS):
        value = stimuli[lane] if lane < len(stimuli) else 0.0
        raw = q88.encode_q88_signed(value)
        frame.extend(q88.q88_to_be_bytes(raw))
    return frame


def host_decode_response(frame: list[int]) -> tuple[list[float], list[bool], int]:
    """Model of ``process_stimuli``'s RX half.

    Rust::

        let raw = i16::from_be_bytes([rx_data[i * 2], rx_data[i * 2 + 1]]);
        potentials.push(crate::q88_signed_to_f32(raw));
        let spike_word = u16::from_be_bytes([rx_data[32], rx_data[33]]);
        let spikes = (0..16).map(|i| (spike_word & (1 << i)) != 0);
        // rx_data[34..36] = switch state
    """
    if len(frame) != HOST_RESPONSE_BYTES:
        raise ValueError(f"host reads exactly {HOST_RESPONSE_BYTES} bytes, got {len(frame)}")
    potentials = [
        q88.q88_signed_to_f32(q88.q88_from_be_bytes(frame[i * 2], frame[i * 2 + 1]))
        for i in range(gen.NUM_NEURONS)
    ]
    spike_word = (frame[32] << 8) | frame[33]
    spikes = [(spike_word & (1 << i)) != 0 for i in range(gen.NUM_NEURONS)]
    aux_word = (frame[34] << 8) | frame[35]
    return potentials, spikes, aux_word


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads((GOLDEN_DIR / "frame_golden_vectors.json").read_text())


@pytest.fixture(scope="module")
def cases(manifest: dict) -> list[dict]:
    return manifest["frames"]["cases"]


@pytest.fixture(scope="module")
def committed_frames() -> tuple[list[int], list[int]]:
    """The committed request/response byte streams, read back out of the images.

    Deliberately read from the files rather than from the generator, so these
    tests exercise the artifacts the testbench actually consumes.
    """
    return (
        q88.read_bytes(GOLDEN_DIR / "frame_golden_host_tx.mem"),
        q88.read_bytes(GOLDEN_DIR / "frame_golden_soc_rx.mem"),
    )


def request_of(committed: tuple[list[int], list[int]], index: int) -> list[int]:
    host_tx, _ = committed
    start = index * gen.REQUEST_BYTES
    return host_tx[start:start + gen.REQUEST_BYTES]


def response_of(committed: tuple[list[int], list[int]], index: int) -> list[int]:
    _, soc_rx = committed
    start = index * gen.RESPONSE_BYTES
    return soc_rx[start:start + gen.RESPONSE_BYTES]


# --------------------------------------------------------------------------
# Frame geometry
# --------------------------------------------------------------------------


def test_frame_lengths_match_what_the_host_hardcodes() -> None:
    """GH#64 is explicit that neither frame length moves.

    GH#72's output-class flags are LED-only (``status_word[15:13]``,
    ``docs/led-map.md``), so nothing was added to the response.
    """
    assert gen.RESPONSE_BYTES == HOST_RESPONSE_BYTES
    assert gen.REQUEST_BYTES == HOST_REQUEST_BYTES


def test_response_fields_tile_the_frame_exactly() -> None:
    """Potentials + spike word + aux word must account for every byte.

    A silently added field would still make a self-consistent generator; this
    is the arithmetic that says the 36 bytes are fully spoken for.
    """
    assert gen.PAYLOAD_BYTES == gen.NUM_NEURONS * gen.BYTES_PER_WORD
    assert gen.PAYLOAD_BYTES + gen.BYTES_PER_WORD + gen.BYTES_PER_WORD == gen.RESPONSE_BYTES


def test_sync_bytes_are_distinct() -> None:
    """A shared sync would make a 5-byte write look like a truncated stimulus."""
    assert gen.SYNC_BYTE != gen.WRITE_SYNC_BYTE


# --------------------------------------------------------------------------
# Vector integrity
# --------------------------------------------------------------------------


def test_regenerating_is_a_no_op() -> None:
    """The drift gate ``scripts/quality.sh`` and CI run."""
    result = subprocess.run(
        [sys.executable, "scripts/gen_golden_frame_vectors.py", "--check"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        "committed golden frame vectors are stale:\n"
        f"{result.stdout}\n{result.stderr}"
    )


def test_generator_is_deterministic(tmp_path: Path) -> None:
    """Two runs must produce identical bytes, or ``--check`` would be noise."""
    encoded = gen.encode_cases(gen.build_cases(gen.Bank()))
    first = tmp_path / "first"
    second = tmp_path / "second"
    gen.emit(first, encoded)
    gen.emit(second, encoded)
    for name in gen.GENERATED_NAMES:
        assert (first / name).read_bytes() == (second / name).read_bytes(), name


@pytest.mark.parametrize("name", GENERATED_MEM_FILES)
def test_images_have_the_declared_length(name: str, manifest: dict) -> None:
    n_cases = manifest["frames"]["case_count"]
    expected = {
        "frame_golden_count.mem": 1,
        "frame_golden_host_tx.mem": n_cases * gen.REQUEST_BYTES,
        "frame_golden_soc_rx.mem": n_cases * gen.RESPONSE_BYTES,
        "frame_golden_stimuli.mem": n_cases * gen.NUM_NEURONS,
        "frame_golden_potentials.mem": n_cases * gen.NUM_NEURONS,
        "frame_golden_spikes.mem": n_cases,
        "frame_golden_aux.mem": n_cases,
    }[name]
    reader = q88.read_bytes if name in {"frame_golden_host_tx.mem", "frame_golden_soc_rx.mem"} else q88.read_words
    assert len(reader(GOLDEN_DIR / name)) == expected


def test_count_image_agrees_with_the_manifest(manifest: dict) -> None:
    committed_count = q88.read_words(GOLDEN_DIR / "frame_golden_count.mem")
    assert committed_count == [manifest["frames"]["case_count"]]
    # The testbench sizes its arrays against MAX_CASES = 32 and fatals outside
    # 1..32, so a generator that grew past that would fail as a confusing
    # $readmemh overflow rather than a clear message.
    assert 1 <= committed_count[0] <= 32


def test_generated_files_carry_spdx_and_a_do_not_edit_banner() -> None:
    for name in GENERATED_MEM_FILES:
        text = (GOLDEN_DIR / name).read_text()
        assert text.startswith("// SPDX-License-Identifier: MIT OR Apache-2.0"), name
        assert "GENERATED FILE -- do not edit by hand." in text, name
        assert "gen_golden_frame_vectors.py" in text, name
    manifest_text = (GOLDEN_DIR / "frame_golden_vectors.json").read_text()
    assert "gen_golden_frame_vectors.py" in manifest_text


def test_byte_images_reject_a_16_bit_word(tmp_path: Path) -> None:
    """``$readmemh`` into ``logic [7:0]`` truncates a 4-digit token silently.

    That would shift the whole frame, so the reader refuses it outright rather
    than letting the testbench report a byte-offset mismatch instead of a load
    error.
    """
    path = tmp_path / "bad.mem"
    path.write_text("// SPDX-License-Identifier: MIT OR Apache-2.0\nAA\n0134\n")
    with pytest.raises(ValueError, match="2-digit hex byte"):
        q88.read_bytes(path)


def test_byte_writer_rejects_out_of_range(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="does not fit in 8 bits"):
        q88.write_bytes(tmp_path / "x.mem", [0x100])


# --------------------------------------------------------------------------
# Provenance
# --------------------------------------------------------------------------


def test_manifest_pins_the_spikenaut_bank(manifest: dict) -> None:
    bank = manifest["bank"]
    assert bank["commit"] == gen.SPIKENAUT_BANK_COMMIT
    assert bank["content_digests_sha256"] == dict(gen.BANK_DIGESTS)
    for name, digest in gen.BANK_DIGESTS.items():
        assert q88.content_digest(REPO_ROOT / "spikenaut-core-sv" / "mem" / name) == digest, name


def test_bank_digests_agree_with_the_lif_generator() -> None:
    """Both generators pin the same bank; a half-updated pin is a real hazard."""
    import gen_golden_lif_vectors as lif_gen

    assert gen.SPIKENAUT_BANK_COMMIT == lif_gen.SPIKENAUT_BANK_COMMIT
    for name, digest in gen.BANK_DIGESTS.items():
        assert lif_gen.BANK_DIGESTS[name] == digest, name


def test_exp025_cases_only_use_words_from_the_pinned_bank(cases: list[dict]) -> None:
    """Every ``exp-025`` word must appear in a committed bank image.

    This is what makes the ``exp-025`` tag mean something: a value that drifted
    to a hand-authored number would no longer be found in the bank.
    """
    bank_words = set()
    for name in gen.BANK_DIGESTS:
        bank_words.update(
            q88.raw_to_hex(raw)
            for raw in q88.read_mem(REPO_ROOT / "spikenaut-core-sv" / "mem" / name)
        )

    checked = 0
    for case in cases:
        if case["source"] != "exp-025":
            continue
        for field in ("stimuli_q88", "potentials_q88"):
            for word in case[field]:
                assert word in bank_words, (
                    f"case {case['name']} {field} word {word} is not in the pinned bank"
                )
                checked += 1
    assert checked > 0, "no exp-025 case words were checked"


def test_synthetic_cases_are_labelled(cases: list[dict]) -> None:
    assert {case["source"] for case in cases} <= {"exp-025", "synthetic"}
    assert any(case["source"] == "exp-025" for case in cases)
    assert any(case["source"] == "synthetic" for case in cases)
    for case in cases:
        assert case["why"].strip(), case["name"]


def test_a_real_dale_inhibitory_word_reaches_the_wire(cases: list[dict], committed_frames) -> None:
    """0xFF00 (-1.0) must appear in a committed response, not just a manifest.

    An unsigned host decode reads 255.0 there. If no golden frame actually
    carries the word, that regression has nothing to fail against.
    """
    found = False
    for case in cases:
        if "FF00" not in case["potentials_q88"]:
            continue
        frame = response_of(committed_frames, case["index"])
        for lane in range(gen.NUM_NEURONS):
            if (frame[lane * 2], frame[lane * 2 + 1]) == (0xFF, 0x00):
                found = True
    assert found, "no golden response frame carries a real Dale-I -1.0 word"


# --------------------------------------------------------------------------
# The host codec agrees with the committed bytes
# --------------------------------------------------------------------------


def test_host_encoder_reproduces_every_golden_request(cases: list[dict], committed_frames) -> None:
    for case in cases:
        assert host_encode_request(case["stimuli_f32"]) == request_of(committed_frames, case["index"]), (
            f"case {case['name']}: host TX bytes differ from the committed image"
        )


def test_host_decoder_recovers_every_golden_response(cases: list[dict], committed_frames) -> None:
    """The host must recover the Q8.8 value each golden word encodes.

    Compared against the manifest's ``potentials_q88`` rather than its
    ``potentials_f32``: encoding is lossy where the authored ``f32`` is not
    representable (``clamp_saturation`` authors +/-127.99, which quantizes to
    +/-127.98828125). Exactness for bank-sourced values is a separate, stronger
    claim -- see ``test_exp025_potentials_survive_the_wire_exactly``.
    """
    for case in cases:
        potentials, spikes, aux = host_decode_response(response_of(committed_frames, case["index"]))
        expected = [q88.q88_signed_to_f32(q88.hex_to_raw(w)) for w in case["potentials_q88"]]
        assert potentials == expected, f"case {case['name']}: potentials"
        expected_word = int(case["spike_word"], 16)
        assert spikes == [(expected_word & (1 << i)) != 0 for i in range(gen.NUM_NEURONS)], (
            f"case {case['name']}: spike flags"
        )
        assert aux == int(case["aux_word"], 16), f"case {case['name']}: aux word"


def test_exp025_potentials_survive_the_wire_exactly(cases: list[dict], committed_frames) -> None:
    """Bank-sourced values must come back off the wire bit-exact.

    They are decodes of committed ``.mem`` words, so ``f32 -> Q8.8 -> bytes ->
    f32`` has to be the identity for them. This is the claim that makes the
    ``exp-025`` cases meaningful; the synthetic ``clamp_saturation`` case is
    deliberately excluded because its authored bound is not representable.
    """
    checked = 0
    for case in cases:
        if case["source"] != "exp-025":
            continue
        potentials, _, _ = host_decode_response(response_of(committed_frames, case["index"]))
        assert potentials == case["potentials_f32"], f"case {case['name']}: potentials"
        checked += 1
    assert checked >= 2, "too few exp-025 cases to pin the exact round trip"


def test_host_round_trip_is_lossless(cases: list[dict], committed_frames) -> None:
    """Decode then re-encode must return the identical response bytes."""
    for case in cases:
        frame = response_of(committed_frames, case["index"])
        potentials, _, aux = host_decode_response(frame)
        spike_word = int(case["spike_word"], 16)
        rebuilt = gen.response_frame(
            [q88.encode_q88_signed(v) for v in potentials], spike_word, aux
        )
        assert rebuilt == frame, f"case {case['name']}: response round trip"


def test_manifest_byte_strings_match_the_images(cases: list[dict], committed_frames) -> None:
    """The human-readable manifest must not drift from the machine images."""
    for case in cases:
        assert case["host_tx_bytes"] == " ".join(
            f"{b:02X}" for b in request_of(committed_frames, case["index"])
        ), case["name"]
        assert case["soc_rx_bytes"] == " ".join(
            f"{b:02X}" for b in response_of(committed_frames, case["index"])
        ), case["name"]


# --------------------------------------------------------------------------
# What the vectors actually pin: wrong decodes must fail
# --------------------------------------------------------------------------


def test_unsigned_decode_misreads_the_golden_potentials(cases: list[dict], committed_frames) -> None:
    """The regression the ``.mem`` signedness work (GH#73) was about.

    ``FixedPointEncode::encode_q88`` is unsigned; reading a response that way
    turns every inhibitory membrane into a large positive number.
    """
    disagreed = 0
    for case in cases:
        frame = response_of(committed_frames, case["index"])
        signed, _, _ = host_decode_response(frame)
        unsigned = [
            ((frame[i * 2] << 8) | frame[i * 2 + 1]) / q88.Q88_SCALE
            for i in range(gen.NUM_NEURONS)
        ]
        if any(s < 0 for s in signed):
            assert unsigned != signed, f"case {case['name']} cannot distinguish the two decodes"
            disagreed += 1
    assert disagreed >= 2, "too few golden frames carry a negative potential to pin signedness"


def test_little_endian_decode_misreads_the_golden_potentials(cases: list[dict], committed_frames) -> None:
    disagreed = 0
    for case in cases:
        frame = response_of(committed_frames, case["index"])
        signed, _, _ = host_decode_response(frame)
        swapped = [
            q88.q88_signed_to_f32(q88.q88_from_be_bytes(frame[i * 2 + 1], frame[i * 2]))
            for i in range(gen.NUM_NEURONS)
        ]
        if swapped != signed:
            disagreed += 1
    assert disagreed >= 2, "too few golden frames distinguish big- from little-endian words"


def test_reversed_lane_order_misreads_the_golden_potentials(cases: list[dict], committed_frames) -> None:
    disagreed = 0
    for case in cases:
        frame = response_of(committed_frames, case["index"])
        signed, _, _ = host_decode_response(frame)
        if list(reversed(signed)) != signed:
            disagreed += 1
    assert disagreed >= 2, "too few golden frames distinguish lane 0 first from lane 15 first"


def test_reversed_spike_bit_order_misreads_the_golden_flags(cases: list[dict], committed_frames) -> None:
    """The ``lane_walk`` / ``lane15_only`` pair exists for exactly this."""
    disagreed = 0
    for case in cases:
        _, spikes, _ = host_decode_response(response_of(committed_frames, case["index"]))
        if list(reversed(spikes)) != spikes:
            disagreed += 1
    assert disagreed >= 2, "too few golden frames distinguish bit 0 = neuron 0 from bit 15 = neuron 0"


def test_treating_the_aux_word_as_a_potential_is_detectable(cases: list[dict], committed_frames) -> None:
    """A field inserted before the aux word would shift bytes 34-35.

    If every golden aux word were 0, that shift would be invisible; requiring
    distinct non-zero aux words is what keeps the tail of the frame pinned.
    """
    aux_words = {case["aux_word"] for case in cases}
    assert len(aux_words) >= 4, "golden aux words are too uniform to pin the frame tail"
    assert any(word != "0000" for word in aux_words)


def test_spike_words_cover_both_halves_and_both_polarities(cases: list[dict]) -> None:
    """Coverage guard on the bitmap, so a stuck spike byte cannot pass."""
    words = [int(case["spike_word"], 16) for case in cases]
    assert any(word & 0x00FF for word in words), "no golden frame sets a low-byte spike bit"
    assert any(word & 0xFF00 for word in words), "no golden frame sets a high-byte spike bit"
    assert 0x0000 in words, "no all-quiet golden frame"
    assert 0xFFFF in words, "no all-spiking golden frame"
    # Complementary patterns: a byte stuck at one of them fails the other.
    assert 0x5555 in words and 0xAAAA in words


def test_clamp_saturation_lands_on_the_shared_bounds(cases: list[dict], committed_frames) -> None:
    """+/-127.99 must serialize to 0x7FFD / 0x8003, not the i16 limits.

    The clamp is applied to the unscaled f32, which is the behaviour
    silicon-bridge's STIMULUS_Q88_MIN/MAX describe.
    """
    saturating = [case for case in cases if case["name"] == "clamp_saturation"]
    assert saturating, "the clamp_saturation case disappeared"
    words = set(saturating[0]["stimuli_q88"]) | set(saturating[0]["potentials_q88"])
    assert words == {"7FFD", "8003"}, words

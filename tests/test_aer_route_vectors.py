# SPDX-License-Identifier: MIT OR Apache-2.0
"""Contract tests for generated aer-route-v1 table images."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import gen_aer_route_vectors as gen  # noqa: E402

ROUTE_DIR = REPO_ROOT / "synapse-link-hdl" / "mem"
ROUTE_IMAGE = ROUTE_DIR / "aer_routes_identity_n16.mem"
ROUTE_METADATA = ROUTE_DIR / "aer_routes_identity_n16.json"
TEST_ROUTE_IMAGE = ROUTE_DIR / "aer_routes_test_multihop_n16.mem"


def read_words(path: Path) -> list[int]:
    words: list[int] = []
    for line in path.read_text().splitlines():
        token = line.split("//", 1)[0].strip()
        if token:
            words.append(int(token, 16))
    return words


def canonical_digest(words: list[int]) -> str:
    payload = "".join(f"{word:04X}\n" for word in words).encode()
    return hashlib.sha256(payload).hexdigest()


def test_committed_identity_image_is_current() -> None:
    result = subprocess.run(
        [sys.executable, "scripts/gen_aer_route_vectors.py", "--check"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_generator_rejects_arbitrary_output_paths(tmp_path: Path) -> None:
    destination = tmp_path / "outside-repository"
    result = subprocess.run(
        [
            sys.executable,
            "scripts/gen_aer_route_vectors.py",
            "--output-dir",
            str(destination),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert not destination.exists()


def test_identity_image_has_exact_aer_route_v1_words() -> None:
    assert read_words(ROUTE_IMAGE) == [0xC000 | address for address in range(16)]


def test_generated_nonidentity_fixture_is_distinguishable_from_fallback() -> None:
    words = read_words(TEST_ROUTE_IMAGE)
    assert words[:2] == [0x8001, 0xC002]
    assert words[2:] == [0xC000 | address for address in range(2, 16)]


def test_metadata_pins_the_hardware_abi_and_image_digest() -> None:
    metadata = json.loads(ROUTE_METADATA.read_text())
    words = read_words(ROUTE_IMAGE)
    assert metadata["schema"] == "aer-route-v1"
    assert metadata["entry_width"] == 16
    assert metadata["address_width"] == 4
    assert metadata["entry_count"] == 16
    assert metadata["max_hops"] == 4
    assert metadata["route_file"] == ROUTE_IMAGE.name
    assert metadata["sha256"] == canonical_digest(words)
    assert metadata["origin"]["kind"] == "canonical-nir-input-order"
    assert metadata["origin"]["routing"] == "identity"


def test_encoder_rejects_reserved_bits_and_out_of_range_addresses() -> None:
    with pytest.raises(ValueError, match="reserved"):
        gen.encode_entry(valid=True, terminal=True, next_addr=0, reserved=1)
    with pytest.raises(ValueError, match="next_addr"):
        gen.encode_entry(valid=True, terminal=True, next_addr=16)


def test_generated_files_are_marked_and_spdx_licensed() -> None:
    image = ROUTE_IMAGE.read_text()
    assert image.startswith("// SPDX-License-Identifier: MIT OR Apache-2.0")
    assert "GENERATED FILE -- do not edit by hand." in image
    assert "gen_aer_route_vectors.py" in image
    metadata = ROUTE_METADATA.read_text()
    assert "gen_aer_route_vectors.py" in metadata
    fixture = TEST_ROUTE_IMAGE.read_text()
    assert fixture.startswith("// SPDX-License-Identifier: MIT OR Apache-2.0")
    assert "GENERATED TEST FIXTURE -- do not edit by hand." in fixture

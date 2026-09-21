#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate the canonical N=16 identity image for the aer-route-v1 ABI.

The current Spikenaut feed-forward graph has canonical input ordering but no
physical nonidentity route plan, so its honest hardware lowering is identity.
Synthetic multi-hop capability is exercised by RTL tests and board writes; it
is not encoded into this model-derived image.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = REPO_ROOT / "synapse-link-hdl" / "mem"
IMAGE_NAME = "aer_routes_identity_n16.mem"
METADATA_NAME = "aer_routes_identity_n16.json"
TEST_IMAGE_NAME = "aer_routes_test_multihop_n16.mem"

SCHEMA = "aer-route-v1"
ENTRY_WIDTH = 16
ADDRESS_WIDTH = 4
ENTRY_COUNT = 16
MAX_HOPS = 4


def encode_entry(
    *,
    valid: bool,
    terminal: bool,
    next_addr: int,
    reserved: int = 0,
) -> int:
    """Encode one aer-route-v1 entry, rejecting non-canonical fields."""
    if reserved != 0:
        raise ValueError("reserved bits must be zero")
    if not 0 <= next_addr < (1 << ADDRESS_WIDTH):
        raise ValueError(f"next_addr must fit {ADDRESS_WIDTH} bits")
    return (
        (int(valid) << 15)
        | (int(terminal) << 14)
        | (reserved << ADDRESS_WIDTH)
        | next_addr
    )


def identity_words() -> list[int]:
    return [
        encode_entry(valid=True, terminal=True, next_addr=address)
        for address in range(ENTRY_COUNT)
    ]


def test_multihop_words() -> list[int]:
    """Distinguishable generated fixture proving INIT_FILE is consumed."""
    words = identity_words()
    words[0] = encode_entry(valid=True, terminal=False, next_addr=1)
    words[1] = encode_entry(valid=True, terminal=True, next_addr=2)
    return words


def canonical_digest(words: list[int]) -> str:
    payload = "".join(f"{word:04X}\n" for word in words).encode()
    return hashlib.sha256(payload).hexdigest()


def emit(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    words = identity_words()
    banner = (
        "// SPDX-License-Identifier: MIT OR Apache-2.0\n"
        "// GENERATED FILE -- do not edit by hand.\n"
        "// Regenerate: python3 scripts/gen_aer_route_vectors.py\n"
        "// aer-route-v1 identity image for canonical NIR input ordering.\n"
    )
    body = "".join(f"{word:04X}\n" for word in words)
    (output_dir / IMAGE_NAME).write_text(banner + body)

    test_banner = (
        "// SPDX-License-Identifier: MIT OR Apache-2.0\n"
        "// GENERATED TEST FIXTURE -- do not edit by hand.\n"
        "// Regenerate: python3 scripts/gen_aer_route_vectors.py\n"
        "// Synthetic 0 -> 1 -> 2 route; not derived from the Spikenaut graph.\n"
    )
    test_body = "".join(f"{word:04X}\n" for word in test_multihop_words())
    (output_dir / TEST_IMAGE_NAME).write_text(test_banner + test_body)

    metadata = {
        "generated_by": "scripts/gen_aer_route_vectors.py",
        "schema": SCHEMA,
        "entry_width": ENTRY_WIDTH,
        "address_width": ADDRESS_WIDTH,
        "entry_count": ENTRY_COUNT,
        "max_hops": MAX_HOPS,
        "route_file": IMAGE_NAME,
        "sha256": canonical_digest(words),
        "origin": {
            "kind": "canonical-nir-input-order",
            "routing": "identity",
            "claim": (
                "Identity ordering is the lowering for the current feed-forward "
                "Spikenaut graph; it does not claim NIR edges encode FPGA hops."
            ),
        },
    }
    (output_dir / METADATA_NAME).write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n"
    )


def check_committed() -> int:
    with tempfile.TemporaryDirectory(prefix="aer-route-v1-") as temp:
        generated_dir = Path(temp)
        emit(generated_dir)
        stale: list[str] = []
        for name in (IMAGE_NAME, METADATA_NAME, TEST_IMAGE_NAME):
            committed = DEFAULT_OUTPUT_DIR / name
            generated = generated_dir / name
            if not committed.is_file() or committed.read_bytes() != generated.read_bytes():
                stale.append(name)
        if stale:
            print(
                "stale generated AER route artifact(s): "
                + ", ".join(stale)
                + "\nrun: python3 scripts/gen_aer_route_vectors.py"
            )
            return 1
    print("aer-route-v1 generated artifacts are current")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    args = parser.parse_args()
    if args.check:
        if args.output_dir != DEFAULT_OUTPUT_DIR:
            parser.error("--check uses the committed default output directory")
        return check_committed()
    emit(args.output_dir)
    print(f"wrote {args.output_dir / IMAGE_NAME}")
    print(f"wrote {args.output_dir / METADATA_NAME}")
    print(f"wrote {args.output_dir / TEST_IMAGE_NAME}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

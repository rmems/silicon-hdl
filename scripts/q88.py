# SPDX-License-Identifier: MIT OR Apache-2.0
"""Signed Q8.8 codec and ``$readmemh`` ``.mem`` I/O for silicon-hdl tooling.

This is the **single** Q8.8 codec in this repository (GH#66). Everything that
turns host ``f32`` values into ``.mem`` words — the golden-vector generator,
its tests — goes through here. Do not add a second one.

Why this exists at all instead of calling silicon-bridge's exporter
-------------------------------------------------------------------
silicon-hdl's ``.mem`` contract is **signed two's-complement Q8.8** (GH#73, see
``spikenaut-core-sv/mem/README.md``): ``0xFF00`` is ``-1.0``, not ``65280``.
silicon-bridge exposes two Q8.8 conventions, and only one can express a Dale-I
word:

===========================  ===========  ================================
silicon-bridge item          Convention   Can express a Dale-I word?
===========================  ===========  ================================
``encode_q88_signed``        signed i16   Yes (``-1.0`` -> ``0xFF00``)
``encode_q88_unsigned``      unsigned     No — negatives clamp to ``0``
===========================  ===========  ================================

As of silicon-bridge #60 (``e201514``), ``FpgaParameterExporter``'s
``FixedPointEncode::encode_q88`` — the one ``write_mem_files`` goes through —
encodes with ``encode_q88_signed``, so that crate and this contract now agree.
``encode_q88_unsigned`` is still public, but nothing in the crate builds
hardware images with it.

  *Correction:* an earlier revision of this docstring said the ``.mem`` writer
  was still on the unsigned encoder and called that "the wrong side of the
  contract". That was accurate when GH#66 landed and is no longer accurate.

This module exists because silicon-hdl's tooling is Python and cannot call into
the crate: reaching for it would make every golden-vector regeneration depend on
a Rust toolchain and a cross-repo checkout. So it mirrors ``encode_q88_signed``
/ ``q88_signed_to_f32`` (``silicon-bridge/src/fpga_export.rs``) bit for bit
— same clamp bounds, same truncate-toward-zero, same NaN handling.
``tests/test_golden_lif_vectors.py`` re-asserts that crate's own unit-test
vectors against this implementation, so the two cannot drift apart silently.
"""

from __future__ import annotations

import hashlib
import math
import re
import struct
from pathlib import Path

#: Fixed-point word width (8 integer bits + 8 fractional bits).
WORD_BITS = 16
#: Fractional scale: ``raw = value * 256``.
Q88_SCALE = 256

#: Most negative / most positive raw word a 16-bit two's-complement Q8.8 holds.
Q88_RAW_MIN = -(1 << (WORD_BITS - 1))  # -32768
Q88_RAW_MAX = (1 << (WORD_BITS - 1)) - 1  # +32767

# Clamp bounds, matching silicon-bridge's STIMULUS_Q88_MIN / STIMULUS_Q88_MAX.
# The clamp is applied to the *unscaled* f32, so saturation lands on raw
# +/-32765 (127.99 * 256 truncated), not on the i16 limits. Keeping the bound
# identical to silicon-bridge is the whole point -- do not "round it up" to
# 127.99609375 to reach +/-32767 without changing it there too.
Q88_CLAMP_MIN = -127.99
Q88_CLAMP_MAX = 127.99


def _as_f32(value: float) -> float:
    """Round a Python float to the nearest ``f32``, as Rust would hold it.

    Python floats are ``f64``, so a caller can hand us a magnitude no ``f32``
    can represent. Converting one in Rust (``as f32``) yields an infinity, so
    that is what we return -- the clamp downstream then saturates it, which is
    the documented behaviour. Packing would raise ``OverflowError`` instead.
    """
    try:
        return struct.unpack("<f", struct.pack("<f", value))[0]
    except OverflowError:
        return math.inf if value > 0 else -math.inf


def encode_q88_signed(value: float) -> int:
    """Encode one ``f32`` as a signed Q8.8 raw word (``i16``).

    Mirrors silicon-bridge ``encode_q88_signed``: NaN encodes as ``0``, the
    unscaled value clamps to ``[-127.99, 127.99]``, and the scaled result
    truncates toward zero.

    >>> encode_q88_signed(1.0)
    256
    >>> encode_q88_signed(-1.0)          # the Dale-I word 0xFF00
    -256
    >>> encode_q88_signed(-0.999)        # truncates toward zero, not away
    -255
    """
    if math.isnan(value):
        return 0
    clamped = _as_f32(min(max(_as_f32(value), Q88_CLAMP_MIN), Q88_CLAMP_MAX))
    # Multiplying an f32 by 256 is an exact binary exponent shift here, so
    # doing it in Python's f64 gives the same product Rust's f32 math does.
    return math.trunc(clamped * Q88_SCALE)


def q88_signed_to_f32(raw: int) -> float:
    """Decode a signed Q8.8 raw word back to ``f32``.

    Mirrors silicon-bridge ``q88_signed_to_f32``. Every ``i16`` is valid, so
    this is total over ``[-32768, 32767]`` -> ``[-128.0, 127.99609375]``.

    >>> q88_signed_to_f32(-256)
    -1.0
    """
    if not (Q88_RAW_MIN <= raw <= Q88_RAW_MAX):
        raise ValueError(f"raw {raw} is outside signed Q8.8 range")
    return _as_f32(raw / Q88_SCALE)


def raw_to_hex(raw: int) -> str:
    """Format a signed raw word as the 4-digit two's-complement hex ``$readmemh`` wants."""
    if not (Q88_RAW_MIN <= raw <= Q88_RAW_MAX):
        raise ValueError(f"raw {raw} is outside signed Q8.8 range")
    return f"{raw & 0xFFFF:04X}"


def hex_to_raw(word: str) -> int:
    """Parse a 4-digit ``.mem`` hex word as a signed two's-complement Q8.8 raw word."""
    unsigned = int(word, 16)
    if not (0 <= unsigned <= 0xFFFF):
        raise ValueError(f"'{word}' is not a 16-bit hex word")
    return unsigned - (1 << WORD_BITS) if unsigned & 0x8000 else unsigned


_COMMENT_RE = re.compile(r"//.*$")


def read_mem(path: str | Path) -> list[int]:
    """Read a ``$readmemh`` ``.mem`` image as a list of **signed** raw Q8.8 words.

    ``//`` comment lines (the SPDX header every image in this repo carries) and
    blank lines are skipped, matching ``$readmemh``.
    """
    words: list[int] = []
    for lineno, line in enumerate(Path(path).read_text().splitlines(), start=1):
        stripped = _COMMENT_RE.sub("", line).strip()
        if not stripped:
            continue
        for token in stripped.split():
            try:
                words.append(hex_to_raw(token))
            except ValueError as exc:
                raise ValueError(f"{path}:{lineno}: {exc}") from exc
    return words


def write_mem(path: str | Path, raws: list[int], *, header: str | None = None) -> None:
    """Write signed raw Q8.8 words as a ``$readmemh`` image, one word per line.

    Always emits the SPDX header line this repo requires; ``header`` adds
    further ``//`` provenance lines beneath it.
    """
    lines = ["// SPDX-License-Identifier: MIT OR Apache-2.0"]
    if header:
        lines.extend(f"// {line}" if line else "//" for line in header.splitlines())
    lines.extend(raw_to_hex(raw) for raw in raws)
    Path(path).write_text("\n".join(lines) + "\n")


def content_digest(path: str | Path) -> str:
    """SHA-256 over a ``.mem`` image's **canonical word stream**.

    Hashes the decoded words re-serialised as ``%04X`` lines, not the raw file
    bytes. That makes the digest a fingerprint of the *data*: editing the SPDX
    header or a provenance comment does not change it, while a single changed
    weight does. Used to pin bank provenance in
    ``scripts/gen_golden_lif_vectors.py`` -- a retrain that happens to keep the
    same word count cannot slip through a length check alone.
    """
    canonical = "".join(f"{raw & 0xFFFF:04X}\n" for raw in read_mem(path))
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def read_words(path: str | Path) -> list[int]:
    """Read a ``.mem`` image as plain **unsigned** 16-bit patterns.

    Counterpart of :func:`write_words`, and the one to use for bitmaps and
    flags: :func:`read_mem` would hand back ``0xFFFF`` as ``-1``.
    """
    return [raw & 0xFFFF for raw in read_mem(path)]


def write_words(path: str | Path, words: list[int], *, header: str | None = None) -> None:
    """Write plain unsigned 16-bit patterns as a ``$readmemh`` image.

    For companion images that are **not** Q8.8 numbers -- spike bitmaps, 0/1
    flags, vector counts. Kept separate from :func:`write_mem` so a bit pattern
    like ``0xFFFF`` (every lane spiking) is never quietly range-checked as if
    it were the fixed-point value ``-1/256``.
    """
    lines = ["// SPDX-License-Identifier: MIT OR Apache-2.0"]
    if header:
        lines.extend(f"// {line}" if line else "//" for line in header.splitlines())
    for word in words:
        if not (0 <= word <= 0xFFFF):
            raise ValueError(f"word {word} does not fit in 16 bits")
        lines.append(f"{word:04X}")
    Path(path).write_text("\n".join(lines) + "\n")


#: Hex digits per byte-stream ``.mem`` word. ``$readmemh`` sizes each token by
#: the target array element, so a byte image must not carry 4-digit words.
BYTE_HEX_DIGITS = 2


def read_bytes(path: str | Path) -> list[int]:
    """Read a ``.mem`` image as a list of **8-bit** values.

    Counterpart of :func:`write_bytes`, for wire-protocol frame images whose
    ``$readmemh`` target is a ``logic [7:0]`` array (GH#64). Rejects any token
    that is not exactly two hex digits: a 4-digit word here would be silently
    truncated to its low byte by ``$readmemh``, so the whole frame would shift
    and the mismatch would surface as a confusing byte-offset error instead of
    a load error.
    """
    values: list[int] = []
    for lineno, line in enumerate(Path(path).read_text().splitlines(), start=1):
        stripped = _COMMENT_RE.sub("", line).strip()
        if not stripped:
            continue
        for token in stripped.split():
            if len(token) != BYTE_HEX_DIGITS:
                raise ValueError(
                    f"{path}:{lineno}: '{token}' is not a {BYTE_HEX_DIGITS}-digit "
                    "hex byte; byte images must not carry 16-bit words"
                )
            try:
                value = int(token, 16)
            except ValueError as exc:
                raise ValueError(f"{path}:{lineno}: '{token}' is not hex") from exc
            values.append(value)
    return values


def write_bytes(path: str | Path, values: list[int], *, header: str | None = None) -> None:
    """Write 8-bit values as a ``$readmemh`` image, one byte per line.

    Used for the GH#64 golden UART frame images. Kept separate from
    :func:`write_words` because the element width is part of the contract: the
    testbench reads these into ``logic [7:0]``.
    """
    lines = ["// SPDX-License-Identifier: MIT OR Apache-2.0"]
    if header:
        lines.extend(f"// {line}" if line else "//" for line in header.splitlines())
    for value in values:
        if not (0 <= value <= 0xFF):
            raise ValueError(f"byte {value} does not fit in 8 bits")
        lines.append(f"{value:02X}")
    Path(path).write_text("\n".join(lines) + "\n")


def q88_to_be_bytes(raw: int) -> tuple[int, int]:
    """Split a signed raw Q8.8 word into the wire's (high, low) byte pair.

    The SiliconBridge v3.0 wire protocol is big-endian per word in both
    directions (``silicon-bridge`` ``fpga_bridge.rs``: ``q8_8.to_be_bytes()``
    on TX, ``i16::from_be_bytes`` on RX).
    """
    if not (Q88_RAW_MIN <= raw <= Q88_RAW_MAX):
        raise ValueError(f"raw {raw} is outside signed Q8.8 range")
    unsigned = raw & 0xFFFF
    return (unsigned >> 8) & 0xFF, unsigned & 0xFF


def q88_from_be_bytes(high: int, low: int) -> int:
    """Reassemble a signed raw Q8.8 word from the wire's (high, low) byte pair."""
    for name, value in (("high", high), ("low", low)):
        if not (0 <= value <= 0xFF):
            raise ValueError(f"{name} byte {value} does not fit in 8 bits")
    unsigned = (high << 8) | low
    return unsigned - (1 << WORD_BITS) if unsigned & 0x8000 else unsigned

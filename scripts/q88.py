# SPDX-License-Identifier: MIT OR Apache-2.0
"""Signed Q8.8 codec and ``$readmemh`` ``.mem`` I/O for silicon-hdl tooling.

This is the **single** Q8.8 codec in this repository (GH#66). Everything that
turns host ``f32`` values into ``.mem`` words — the golden-vector generator,
its tests — goes through here. Do not add a second one.

Why this exists at all instead of calling silicon-bridge's ``MemFileWriter``
-----------------------------------------------------------------------------
silicon-bridge ships two Q8.8 conventions, and neither one *as wired today*
writes the file this repo's RTL reads:

===========================  ===========  ================================
silicon-bridge item          Convention   Can express a Dale-I word?
===========================  ===========  ================================
``FixedPointEncode::         unsigned     No — negatives clamp to ``0``
encode_q88`` (the one
``MemFileWriter::
write_mem_files`` uses)
``encode_q88_signed``        signed i16   Yes (``-1.0`` -> ``0xFF00``)
===========================  ===========  ================================

silicon-hdl's ``.mem`` contract is **signed two's-complement Q8.8** (GH#73,
see ``spikenaut-core-sv/mem/README.md``): ``0xFF00`` is ``-1.0``, not
``65280``. So the ``.mem`` writer in silicon-bridge is on the wrong side of
that contract and would silently flatten every inhibitory weight to zero.

This module therefore mirrors silicon-bridge's **signed** function,
``encode_q88_signed`` / ``q88_signed_to_f32`` (``silicon-bridge/src/
fpga_export.rs``), bit for bit — same clamp bounds, same truncate-toward-zero,
same NaN handling. ``tests/test_golden_lif_vectors.py`` re-asserts that crate's
own unit-test vectors against this implementation, so the two cannot drift
apart silently.

Whether silicon-bridge's ``.mem`` writer should move to the signed encoder is a
question for that repo and is out of scope for GH#66. It is not tracked there
yet; the closest existing work is silicon-bridge GH#22 / RM-300 (MemFileWriter
``.mem`` round-trip tests), which would surface the mismatch.
"""

from __future__ import annotations

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
    """Round a Python float to the nearest ``f32``, as Rust would hold it."""
    return struct.unpack("<f", struct.pack("<f", value))[0]


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

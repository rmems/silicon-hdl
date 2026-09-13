# SPDX-License-Identifier: MIT OR Apache-2.0
"""Bit-exact Python mirror of ``spikenaut-core-sv/rtl/LifNeuron.sv``.

One enabled tick here == one ``step_en`` tick there. Every operation below
tracks the RTL's exact widths: the datapath widens to ``DATA_WIDTH+1`` guard
bits so leak/integrate are non-wrapping, then saturates explicitly back to
``DATA_WIDTH``. See ``docs/timestep-contract.md`` for what a tick is and
``docs/golden-lif-vectors.md`` for how this model is used.

The model is the *reference*, not a second implementation of the design: it
exists so ``scripts/gen_golden_lif_vectors.py`` can compute expected traces
that ``spikenaut-core-sv/tb/tb_LifNeuron_golden.sv`` then checks the real RTL
against. If the two ever disagree, the RTL is the source of truth for what the
silicon does and this file is what must be corrected.

``Semantics`` carries deliberate *wrong* variants (unsigned misread, one-sided
leak, wrapping instead of saturating). Those are not options for production
use -- they are the drift detectors. ``tests/test_golden_lif_vectors.py``
replays the golden vectors through each one and fails if any of them produces
the *same* trace as the correct model, which is what proves the vectors
actually discriminate the signed path from the pre-GH#73 unsigned one.
"""

from __future__ import annotations

from dataclasses import dataclass

#: Datapath width, matching ``LifNeuron``'s ``DATA_WIDTH`` / ``PARAM_WIDTH``.
DATA_WIDTH = 16
#: Guard width: exactly one bit wider, so the true sum is always representable.
GUARD_WIDTH = DATA_WIDTH + 1

#: Signed Q8.8 saturation extremes (``LifNeuron.sv`` ``MAX_MEM`` / ``MIN_MEM``).
MAX_MEM = (1 << (DATA_WIDTH - 1)) - 1  # 0x7FFF
MIN_MEM = -(1 << (DATA_WIDTH - 1))  # 0x8000


def _wrap_signed(value: int, width: int) -> int:
    """Truncate to ``width`` bits and reinterpret as two's complement."""
    masked = value & ((1 << width) - 1)
    return masked - (1 << width) if masked >> (width - 1) else masked


def _bit(value: int, index: int, width: int) -> int:
    return (value & ((1 << width) - 1)) >> index & 1


@dataclass(frozen=True)
class Semantics:
    """Which LIF arithmetic to model.

    ``Semantics()`` is the shipped signed path. The non-default fields each
    reintroduce one specific pre-GH#73 / plausible-regression behaviour so the
    golden vectors can be shown to catch it.
    """

    #: False -> read weight/membrane/threshold as unsigned, the pre-GH#73 bug
    #: where ``0xFF00`` is ``+65280`` instead of ``-1.0``.
    signed: bool = True
    #: False -> leak only ever drains a positive membrane and never recovers a
    #: negative one (the old one-sided subtractive leak).
    symmetric_leak: bool = True
    #: False -> let integration wrap the datapath instead of saturating, so
    #: strong excitation can silently alias to a negative membrane.
    saturate: bool = True


SIGNED = Semantics()


@dataclass
class LifState:
    """Registered state of one ``LifNeuron``: membrane and the ``spike_out`` flop."""

    membrane: int = 0
    spike_out: bool = False


def reset_state() -> LifState:
    """State after ``rst_n`` is asserted for one clock."""
    return LifState(membrane=0, spike_out=False)


def step(
    state: LifState,
    *,
    weight: int,
    threshold: int,
    leak: int,
    spike_in: bool,
    semantics: Semantics = SIGNED,
) -> LifState:
    """Advance one enabled tick. ``weight``/``threshold``/``leak`` are raw Q8.8 words.

    Raw words are passed as **signed** ints (what ``q88.read_mem`` returns);
    the unsigned-misread variant reinterprets them internally, exactly as
    unsigned RTL would have read the same ``.mem`` bits.
    """
    if state.spike_out:
        # Refractory tick: membrane clears and this tick's spike_in is
        # intentionally dropped, guaranteeing a single-tick spike_out pulse.
        return LifState(membrane=0, spike_out=False)

    if semantics.signed:
        return _step_signed(state, weight, threshold, leak, spike_in, semantics)
    return _step_unsigned(state, weight, threshold, leak, spike_in, semantics)


def _step_signed(
    state: LifState,
    weight: int,
    threshold: int,
    leak: int,
    spike_in: bool,
    semantics: Semantics,
) -> LifState:
    mem_wide = _wrap_signed(state.membrane, GUARD_WIDTH)
    leak_wide = _wrap_signed(leak, GUARD_WIDTH)

    if semantics.symmetric_leak:
        # Sign-selected add/subtract pulls the membrane toward the 0 resting
        # potential from either side, then a sign-flip check clamps the
        # zero crossing (RTL uses this instead of a magnitude compare because
        # the datapath is timing-critical).
        decayed = mem_wide + leak_wide if mem_wide < 0 else mem_wide - leak_wide
        decayed = _wrap_signed(decayed, GUARD_WIDTH)
        if (decayed < 0) != (mem_wide < 0):
            decayed = 0
    else:
        # Drift variant: one-sided drain. A negative membrane is pushed
        # further from rest instead of recovering toward it.
        decayed = _wrap_signed(mem_wide - leak_wide, GUARD_WIDTH)
        if mem_wide >= 0 and decayed < 0:
            decayed = 0

    total = _wrap_signed(decayed + weight, GUARD_WIDTH) if spike_in else decayed

    if semantics.saturate:
        # The guard bit disagreeing with the sign bit is exactly the condition
        # "does not fit back in DATA_WIDTH bits".
        if _bit(total, GUARD_WIDTH - 1, GUARD_WIDTH) != _bit(total, DATA_WIDTH - 1, GUARD_WIDTH):
            next_mem = MIN_MEM if total < 0 else MAX_MEM
        else:
            next_mem = _wrap_signed(total, DATA_WIDTH)
    else:
        next_mem = _wrap_signed(total, DATA_WIDTH)

    return LifState(membrane=next_mem, spike_out=next_mem >= threshold)


def _step_unsigned(
    state: LifState,
    weight: int,
    threshold: int,
    leak: int,
    spike_in: bool,
    semantics: Semantics,
) -> LifState:
    """Pre-GH#73 misread: the same ``.mem`` bits taken as unsigned magnitudes."""
    mask = (1 << DATA_WIDTH) - 1
    mem = state.membrane & mask
    weight_u = weight & mask
    threshold_u = threshold & mask
    leak_u = leak & mask

    decayed = max(mem - leak_u, 0)
    total = decayed + weight_u if spike_in else decayed
    next_mem = min(total, mask) if semantics.saturate else total & mask

    return LifState(
        membrane=_wrap_signed(next_mem, DATA_WIDTH),
        spike_out=(next_mem & mask) >= threshold_u,
    )


def run(ticks, *, semantics: Semantics = SIGNED, state: LifState | None = None):
    """Replay a sequence of ticks, yielding the state after each one.

    ``ticks`` is an iterable of ``(weight, threshold, leak, spike_in, reset_first)``
    tuples. ``reset_first`` applies one ``rst_n``-asserted clock before the
    tick, which is how the golden testbench separates scenarios.
    """
    current = state or reset_state()
    trace = []
    for weight, threshold, leak, spike_in, reset_first in ticks:
        if reset_first:
            current = reset_state()
        current = step(
            current,
            weight=weight,
            threshold=threshold,
            leak=leak,
            spike_in=spike_in,
            semantics=semantics,
        )
        trace.append(current)
    return trace

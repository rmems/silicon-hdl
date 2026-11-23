# SPDX-License-Identifier: MIT OR Apache-2.0
"""SoC-level bit-exact reference model for the GH#76 parity harness.

Builds on ``lif_reference.py`` (the bit-exact single-neuron mirror) the way
``spikenaut_soc_basys3_top`` composes ``LifNeuron``: sixteen ``LifState``s,
one per neuron row, stepped once per logical tick. What this adds on top of
the neuron model is the SoC's own semantics, mirrored from
``Basys3_Top.sv``:

- **Binary-event PE** — the SoC decodes a consumed ``0xAA`` frame's non-zero
  lanes into a pending mask and emits *one routed event per lane per logical
  tick*, lowest lane first (GH#112); the Q8.8 stimulus magnitudes themselves
  are discarded. Every neuron steps with its own ``weight[n][input_index]``
  against a shared ``spike_in`` bit
  (``docs/lif-array-connectivity-model.md``).
- **All-zero frame** — sets ``route_drop_pending``; the frame is still
  consumed at the next tick and still produces a response, but
  ``stimulus_event`` stays low: an observable leak-only tick.
- **Free-running ticks** — ticks do not wait for the host. The parity
  contract therefore schedules one stimulus frame per
  ``TICKS_PER_FRAME`` ticks: the stimulated tick followed by leak-only
  ticks while the 36-byte response (~3.1 ticks at 115200 baud) is still
  on the wire. See ``docs/supervisor-parity.md``.
- **Response snapshot** — the 36-byte response carries the post-tick state
  of the tick that consumed the frame
  (``frame_send = lif_tick_done && response_armed``).
- **OutputLayer readout** — per-tick saturating accumulate of the output
  bank over the tick's ``spike_bitmap``, argmax with lowest-class
  tie-break, one-hot result (mirrors ``OutputLayer.sv`` and
  ``gen_golden_lif_vectors.py::output_layer_vectors``). LED-only in the
  frame — a sim/board divergence in observability recorded as such.

The model is the *reference*, not a second implementation: if it and the
RTL ever disagree, the RTL defines what the silicon does and this file is
what must be corrected. ``Semantics`` drift variants live in
``lif_reference.py`` and apply unchanged here.
"""

from __future__ import annotations

from dataclasses import dataclass

import lif_reference as lif

NUM_NEURONS = 16
NUM_CHANNELS = 16
NUM_CLASSES = 3

#: Ticks between two consumed stimulus frames in the parity contract. The
#: host waits for the full 36-byte response (~3.1 ticks), delays ~0.5 ms,
#: then sends the next request (~2.9 ticks): RX_COMMIT lands mid-window at
#: ~6.5 ticks after the previous consumed tick, so the next consumed tick is
#: +7 with ~+/-500 us of margin in both directions. The 6 ticks in between
#: are leak-only ticks the reference must model.
TICKS_PER_FRAME = 7

#: Tick at which the first frame is consumed: the host waits ~0.5 ms after
#: reset release, sends (~2.9 ticks), commits mid-window at ~3.4 ticks ->
#: consumed at tick 4. Earlier ticks are leak-only no-ops on the all-zero
#: reset state, but numbering them keeps ``consumed_tick`` comparable
#: between reference, sim, and board captures.
BASE_TICK = 4


@dataclass(frozen=True)
class Bank:
    """The parameter set a parity run replays (signed Q8.8 raw words).

    ``weights``/``thresholds``/``decay``/``output_weights`` are flat arrays
    in the ``.mem`` layouts documented in ``spikenaut-core-sv/mem/README.md``:
    weights row-major ``neuron*NUM_CHANNELS + channel``, output weights
    neuron-major ``neuron*NUM_CLASSES + class``.
    """

    weights: tuple[int, ...]
    thresholds: tuple[int, ...]
    decay: tuple[int, ...]
    output_weights: tuple[int, ...]

    def __post_init__(self) -> None:
        expected = {
            "weights": NUM_NEURONS * NUM_CHANNELS,
            "thresholds": NUM_NEURONS,
            "decay": NUM_NEURONS,
            "output_weights": NUM_NEURONS * NUM_CLASSES,
        }
        for name, count in expected.items():
            if len(getattr(self, name)) != count:
                raise ValueError(
                    f"Bank.{name}: expected {count} words, got {len(getattr(self, name))}"
                )


@dataclass(frozen=True)
class Stimulus:
    """One host ``0xAA`` frame as the SoC decodes it.

    ``lanes`` is the 16-word signed Q8.8 stimulus vector. ``spike_in``/lane
    resolution follows Basys3_Top.sv (GH#112): every non-zero lane produces
    one event, consumed lowest-lane-first across consecutive ticks, and the
    AER table maps each lane to ``input_index`` (identity by
    default). An all-zero vector is a *dropped* frame — consumed, answered,
    but leak-only.
    """

    lanes: tuple[int, ...]

    def __post_init__(self) -> None:
        if len(self.lanes) != NUM_CHANNELS:
            raise ValueError(
                f"Stimulus.lanes: expected {NUM_CHANNELS} words, got {len(self.lanes)}"
            )

    def active_lanes(self) -> tuple[int, ...]:
        """Every non-zero lane, lowest first (Basys3_Top.sv ``decoded_lane_mask``)."""
        return tuple(lane for lane, word in enumerate(self.lanes) if word != 0)

    def decoded_lane(self) -> int | None:
        """Lowest non-zero lane, or None. Kept for single-lane consumers."""
        lanes = self.active_lanes()
        return lanes[0] if lanes else None


def output_class_onehot(spike_bitmap: int, output_weights: tuple[int, ...]) -> int:
    """OutputLayer mirror: per-tick saturating scores + lowest-class argmax."""
    scores = [0] * NUM_CLASSES
    for neuron in range(NUM_NEURONS):
        if not (spike_bitmap >> neuron) & 1:
            continue
        for klass in range(NUM_CLASSES):
            total = scores[klass] + output_weights[neuron * NUM_CLASSES + klass]
            scores[klass] = max(lif.MIN_MEM, min(lif.MAX_MEM, total))
    best = 0
    for klass in range(1, NUM_CLASSES):
        if scores[klass] > scores[best]:
            best = klass
    return 1 << best


@dataclass
class TickResult:
    """State committed by one logical tick (``tick_done`` snapshot)."""

    tick: int
    stimulated: bool
    input_index: int | None  # routed channel when stimulated and not dropped
    spike_bitmap: int
    potentials: list[int]
    output_class: int


def run_fixture(
    stimuli: list[Stimulus],
    bank: Bank,
    *,
    ticks_per_frame: int = TICKS_PER_FRAME,
    base_tick: int = BASE_TICK,
    route: dict[int, int] | None = None,
    semantics: lif.Semantics = lif.SIGNED,
) -> list[TickResult]:
    """Replay the parity schedule, one ``TickResult`` per logical tick.

    Consumed ticks land at ``base_tick + step*ticks_per_frame``: the first
    frame commits mid-window at ~3.4 ticks after reset release (a request
    takes ~2.9 ticks on the wire), every later frame commits in the window
    the previous response's pacing left (see ``TICKS_PER_FRAME``). The
    lead-in ticks before ``base_tick`` are leak-only no-ops on the reset
    state. ``route`` maps decoded lane -> input_index; ``None`` is the
    identity table the fixture's ``aer_routes.mem`` encodes.
    """
    route = route or {}
    states = [lif.reset_state() for _ in range(NUM_NEURONS)]
    trace: list[TickResult] = []
    tick = 0

    def step_tick(spike_in: bool, input_index: int | None) -> TickResult:
        nonlocal tick
        tick += 1
        bitmap = 0
        potentials: list[int] = []
        for n in range(NUM_NEURONS):
            weight = bank.weights[n * NUM_CHANNELS + input_index] if spike_in else 0
            states[n] = lif.step(
                states[n],
                weight=weight,
                threshold=bank.thresholds[n],
                leak=bank.decay[n],
                spike_in=spike_in,
                semantics=semantics,
            )
            potentials.append(states[n].membrane)
            if states[n].spike_out:
                bitmap |= 1 << n
        return TickResult(
            tick=tick,
            stimulated=spike_in,
            input_index=input_index,
            spike_bitmap=bitmap,
            potentials=potentials,
            output_class=output_class_onehot(bitmap, bank.output_weights),
        )

    for _ in range(base_tick - 1):
        trace.append(step_tick(spike_in=False, input_index=None))

    for stim in stimuli:
        # GH#112: one stimulated tick per non-zero lane, lowest first. An
        # all-zero frame still occupies exactly one consumed tick (route_drop).
        lanes = stim.active_lanes()
        if not lanes:
            trace.append(step_tick(spike_in=False, input_index=None))
        else:
            for lane in lanes:
                trace.append(step_tick(spike_in=True, input_index=route.get(lane, lane)))
        for _ in range(ticks_per_frame - 1):
            trace.append(step_tick(spike_in=False, input_index=None))

    return trace


def expected_steps(
    stimuli: list[Stimulus],
    bank: Bank,
    *,
    ticks_per_frame: int = TICKS_PER_FRAME,
    base_tick: int = BASE_TICK,
    route: dict[int, int] | None = None,
    semantics: lif.Semantics = lif.SIGNED,
) -> list[TickResult]:
    """Per consumed frame: the tick its 36-byte response snapshots.

    The response arms on the frame's *final* lane's tick_done (GH#112), so a
    K-lane frame's snapshot is the last stimulated tick, not the first. A
    dropped (all-zero) frame is consumed like a stimulated one — its
    response exists but carries a leak tick's state.
    """
    trace = run_fixture(
        stimuli, bank, ticks_per_frame=ticks_per_frame, base_tick=base_tick,
        route=route, semantics=semantics
    )
    # Walk the same lane-count schedule run_fixture emits: each frame's last
    # consumed tick is its K stimulated (or one dropped) ticks after the
    # previous frame's final tick.
    tick = base_tick - 1
    consumed: set[int] = set()
    for stim in stimuli:
        tick += len(stim.active_lanes()) or 1
        consumed.add(tick)
        tick += ticks_per_frame - 1
    return [r for r in trace if r.tick in consumed]

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-13 -->

# N=16 PE connectivity model

ADR for GitHub [#92](https://github.com/rmems/silicon-hdl/issues/92), raised during
review of [#73](https://github.com/rmems/silicon-hdl/issues/73) (signed Dale E/I path).

## Decision

`LifNeuronArray` implements a **per-neuron external-sensor input** model, not a
recurrent neuron-to-neuron model. Each neuron's 16-word row in the flattened
weight matrix is that neuron's own incoming weights from 16 external input
channels — it is not a row (or column) of connections to or from the other 15
neurons.

| Item | Value |
| --- | --- |
| Weight matrix shape | `weight[neuron][channel]`, flattened `neuron * NUM_NEURONS + channel` |
| `address_neuron` | The neuron currently being updated (destination) |
| `address_input` / `input_index` | The selected **external input channel**, not another neuron's index |
| Recurrence | **None.** No signal path exists from `spike_bitmap` back into `input_index` anywhere in `spikenaut_soc_basys3_top` |
| Addressing formula | `weight_addr = address_neuron * NUM_NEURONS + address_input` — **already correct** for this model; no RTL change needed |

No RTL, FSM, or arithmetic change accompanies this decision — it documents the
model the existing addressing formula already implements correctly, and
corrects comments/docs that described it ambiguously enough to read as
recurrent routing.

## Rationale

`LifNeuronArray`'s addressing (`weight_addr = address_neuron * NUM_NEURONS +
address_input`) was written for [#61](https://github.com/rmems/silicon-hdl/issues/61)
without a stated connectivity model, and its comments ("output-neuron row *
input count + selected input channel") read ambiguously enough that a #73
reviewer read `address_input` as "the index of whichever neuron just fired" —
a recurrent interpretation. Checked against both the trained bank and the
actual SoC wiring, that reading doesn't hold:

- **The trained model has no recurrence.** Per the Spikenaut-SNN architecture
  (`Input → Linear → LIF → Output`, no back edge) and the exp-025 Distill
  sidecar bank's own metadata (`_incoming/snn_model.json`: `legal_columns`,
  `unused_axons`), each neuron's 16-wide weight vector is populated from 16
  external telemetry-style input channels — 5 legal columns
  (`mem_util_pct`, `power_w`, `gpu_temp_c`, `sm_clock_mhz`, `mem_clock_mhz`)
  plus 11 structurally unused axons held at zero.
- **This is universal across the bank, not specific to inhibitory rows.**
  Checked directly against `spikenaut-core-sv/mem/merged_v2_weights.mem`: every
  one of the 16 rows (excitatory and the 12:4 bank's inhibitory rows 6-9 alike)
  has nonzero values only in columns 0-4 and zeros in columns 5-15. If
  `address_input` selected a firing neuron rather than an external channel,
  there would be no reason for *every* row to be zero at the same 11 columns —
  the pattern only makes sense as "11 unused external channels," not as
  "neurons 5-15 never fire."
- **The wired SoC has no feedback path to create recurrence anyway.**
  `spikenaut_soc_basys3_top` derives `stimulus_input_index` (and therefore
  `input_index`) purely by decoding the host's `0xAA` stimulus frame
  (`protocol_stimuli`) — never from `spike_bitmap`. `spike_bitmap` only feeds
  the host readback (`spike_flags`) and `StdpController.post_spike` (itself
  disconnected, [#70](https://github.com/rmems/silicon-hdl/issues/70)). A
  neuron's own spike can never select `input_index` for any neuron's next
  read, so "neuron 6 fires and broadcasts to column 6" cannot occur as
  described in the original #92 report.

Given that, a Dale-inhibitory row's real negative weights (columns 0-4) are
reachable exactly like every other row's: whenever the host's stimulus frame
selects one of the 5 legal channels. There is no addressing bug and no
transpose needed.

## Non-goals

- Adding recurrent neuron-to-neuron connectivity — not what the trained model
  or the current PE implement; a genuinely different feature, out of scope here
- Multi-active-lane vector accumulation (still open, see
  `docs/interface-alignment.md` §2.2 and [#54](https://github.com/rmems/silicon-hdl/issues/54))
- Changing the weight matrix layout or `MemFileWriter`/`FixedPointEncode` export shape

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-06 -->

# LED and status map

ADR for GitHub [#65](https://github.com/rmems/silicon-hdl/issues/65) /
Linear [LIM-926](https://linear.app/rpd-34/issue/LIM-926).

## Decision

| Item | Value |
| --- | --- |
| Board | Digilent Basys 3, 16 LEDs `led[15:0]` |
| Spike convention | `led[i] = neuron i` (LSB = neuron 0), same as the host spike-flag word |
| Default view | SW15 = 0 after reset: combinational `led = spike_bitmap` |
| Status view | SW15 = 1 (after 2FF sync): stretched protocol / heartbeat word |
| Stretcher | Shared `STRETCH_DIV = 6_400_000` @ 100 MHz (~64 ms) |
| Aux word | Synchronized `sw[15:0]` is response bytes `[34..35]` |
| LED driver | Combinational `SocStatusLeds` mux; no registered LED path |

No breadboard. The on-board LEDs and slide switches are the only indicators.

## Spike mode pins

SW15 = 0 (default / reset). `led[i]` is neuron `i` of the committed N=16
`spike_bitmap`.

| LED | Port | Basys 3 pin |
| --- | --- | --- |
| LD0 | `led[0]` | U16 |
| LD1 | `led[1]` | E19 |
| LD2 | `led[2]` | U19 |
| LD3 | `led[3]` | V19 |
| LD4 | `led[4]` | W18 |
| LD5 | `led[5]` | U15 |
| LD6 | `led[6]` | U14 |
| LD7 | `led[7]` | V14 |
| LD8 | `led[8]` | V13 |
| LD9 | `led[9]` | V3 |
| LD10 | `led[10]` | W3 |
| LD11 | `led[11]` | U3 |
| LD12 | `led[12]` | P3 |
| LD13 | `led[13]` | N3 |
| LD14 | `led[14]` | P1 |
| LD15 | `led[15]` | L1 |

**Expect this view to look dark.** A spike holds for exactly one logical tick
([`timestep-contract.md`](timestep-contract.md)), and `LifNeuronArray`'s
refractory rule forces a neuron that fired at tick *T* to stay low at *T+1* —
so the duty cycle is at most 50% of a 1 ms window, and an isolated spike is a
1 ms flash. Spike mode is the unfiltered view, meant for a logic analyser or a
capture; use status mode to eyeball a running demo.

## Status mode

SW15 = 1. Bits `[1]`, `[2]`, `[4]`, `[5]`, `[6]` and `spike_hold` are set on
event and cleared on the shared `stretch_tick`. `abort_sticky` clears only on
`rx_commit` or reset.

| Bit | Name | Source |
| --- | --- | --- |
| `[0]` | heartbeat | `tick_cnt[8]` after `step_en` increments (~1.95 Hz) |
| `[1]` | rx_busy | stretched `SocProtocolFsm.rx_busy` (`rx_state != RX_WAIT_SYNC`) |
| `[2]` | rx_commit | stretched `stimuli_valid` |
| `[3]` | rx_abort | sticky `SocProtocolFsm.rx_abort` (idle-timeout pulse) |
| `[4]` | tx_frame_active | stretched `tx_active` (not the `tx_busy` input) |
| `[5]` | stimuli_pending | stretched SoC pending flag |
| `[6]` | response_armed | stretched SoC armed flag |
| `[7]` | any_spike | `\|spike_hold` |
| `[12:8]` | spike_count | `$countones(spike_hold)` |
| `[15:13]` | reserved | 0 |

`rx_abort` is sticky rather than stretched on purpose: the inter-byte idle
timeout is silent everywhere else in the design, so a truncated host frame
would otherwise leave no trace on the board.

Reading the board during a healthy host session: `[0]` blinking, `[2]` and
`[4]` flickering together once per request, `[12:8]` tracking the population
response, `[3]` dark.

## Switch bus

`sw[15:0]` is synchronized with two flops at the SoC I/O boundary
(`sw_sync_0` / `sw_sync_1`) and reset to `'0` so the board powers up in spike
mode. `sw_sync_1` is the only copy used in the fabric:

- `mode_sel = sw_sync_1[15]`
- `SocProtocolFsm.aux_state = sw_sync_1` (host response bytes 34–35)

Pins (SoC-only, `constraints/basys3_soc.xdc`): SW0..SW15 = V17 V16 W16 W17
W15 V15 W14 W13 V2 T3 T2 R3 W2 U1 T1 R2.

They are kept out of the shared `constraints/basys3.xdc` because
`synapse_demo_basys3_top` reads that file and has no `sw` port: `get_ports`
would return empty, and `set_property` on an empty object list is a hard
Vivado error (`[Common 17-55]`) that aborts `synth_design`.

## Non-goals

- Live board program in CI ([#68](https://github.com/rmems/silicon-hdl/issues/68))
- STDP writeback to `WeightRam` ([#70](https://github.com/rmems/silicon-hdl/issues/70))
- Seven-segment display, PWM dimming, or a reset synchronizer

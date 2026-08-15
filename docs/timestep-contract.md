<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-08-15 -->

# Logical timestep contract

ADR for GitHub [#57](https://github.com/rmems/silicon-hdl/issues/57) /
[#60](https://github.com/rmems/silicon-hdl/issues/60).

## Decision

| Item | Value |
| --- | --- |
| Fabric clock | 100 MHz (10 ns) on Basys 3 `clk` |
| Logical tick | **1 ms** (1 kHz) = **100_000** fabric cycles |
| Enable | One-cycle `step_en` from SoC divider in `spikenaut_soc_basys3_top` |
| Core | `LifNeuron` and `StdpController` update only when `step_en` is 1 |
| STDP `WINDOW_WIDTH` | Counts **ticks**, not fabric clocks |
| Host step | Later [#62](https://github.com/rmems/silicon-hdl/issues/62) may AND/replace the divider |

No breadboard. The on-board oscillator is the only clock.

## Non-goals

- Live board program in CI ([#68](https://github.com/rmems/silicon-hdl/issues/68))
- Multi-neuron time-mux ([#61](https://github.com/rmems/silicon-hdl/issues/61))
- STDP writeback to `WeightRam` ([#70](https://github.com/rmems/silicon-hdl/issues/70))

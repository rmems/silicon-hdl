<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- resource-budget-n16.md -->
<!-- Last updated: 2026-09-07 -->

# N=16 time-multiplexed PE resource budget

The Basys 3 target is `xc7a35tcpg236-1`, with capacity for **20,800 LUTs**,
**41,600 flip-flops**, **50 × 36-Kb Block RAMs**, and **90 DSP48E1 slices**.

`LifNeuronArray` implements the N=16 path as one time-multiplexed processing
element rather than 16 parallel LIF datapaths. Its expected footprint is:

| Element | Expected implementation |
|---------|-------------------------|
| LIF arithmetic | One shared 16-bit leak, saturating-integrate, and threshold-compare datapath, used for one neuron slot per fabric cycle |
| Membrane state | One 16-entry × 16-bit register file, approximately 256 flip-flops before synthesis packing/optimization, plus one prefetched state word |
| Control | Neuron-index counter, input-index latch, result bitmap, refractory/RAM-data prefetch registers, and a small IDLE/PREFETCH/SWEEP sub-cycle FSM |
| Parameter / weight storage | Two `NeuronParamRam` instances and one `WeightRam`; the SoC preserves their block-RAM inference hints |

This single-PE choice avoids 16× arithmetic-datapath replication and is expected
to remain well within the Basys 3 budget. These are design estimates, not
measured utilization. When self-hosted Vivado CI runs,
`scripts/build_soc.tcl` produces `utilization.rpt`; that report is the
authoritative measured source. Free-runner CI gates Verilator simulation and
the Deduplication Guardian, not utilization.

## Measured utilization

Routed Vivado 2026.1 build of `spikenaut_soc_basys3_top`, self-hosted Vivado CI,
tree as merged at `8fb664b` (#85):

| Resource | Used | Available | Utilization |
|---|---|---|---|
| Slice LUTs | 892 | 20,800 | 4.29% |
| Slice Registers | 1,660 | 41,600 | 3.99% |
| Block RAM Tile | 1.5 (3 × RAMB18E1) | 50 | 3.00% |
| DSPs | 0 | 90 | 0.00% |
| Bonded IOB | 36 | 106 | 33.96% |

Timing closes at 100 MHz with **zero failing endpoints** in both directions:

| Metric | Value | Failing / total endpoints |
|---|---|---|
| WNS | **+1.230 ns** | 0 / 3205 |
| WHS | **+0.106 ns** | 0 / 3205 |
| WPWS | +4.500 ns | 0 / 1664 |

### How this moved since the #61 snapshot

The previous figures in this doc were measured at the **#61** commit and were
badly stale by the time #85 landed:

| Metric | #61 snapshot | Current (`8fb664b`) | Change |
|---|---|---|---|
| Slice LUTs | 279 (1.34%) | 892 (4.29%) | ×3.2 |
| Slice Registers | 429 (1.03%) | 1,660 (3.99%) | ×3.9 |
| Block RAM | 3 × RAMB18E1 | 3 × RAMB18E1 | unchanged |
| DSPs | 0 | 0 | unchanged |
| Bonded IOB | 20 | 36 | +16 |
| WNS | +1.200 ns | +1.230 ns | +0.030 ns |
| WHS | +0.177 ns | +0.106 ns | −0.071 ns |

Two features landed in between: [#62](https://github.com/rmems/silicon-hdl/issues/62)
(`SocProtocolFsm` — the 36-byte response serializer holds both an active and a
pending 16-word Q8.8 snapshot) and
[#65](https://github.com/rmems/silicon-hdl/issues/65) (`SocStatusLeds` — shared
stretch prescaler, held status flags, tick counter, plus the `sw` 2FF
synchronizer).

The **+16 IOBs are directly attributable** to the `sw[15:0]` port added by #65.
The LUT and flip-flop growth is *not* attributed per module here, because
`report_utilization` was flat at the time of this build. `scripts/build_soc.tcl`
now also emits `utilization_hier.rpt`, so the next self-hosted build will carry a
per-module breakdown and this section can be made specific rather than
directional.

WNS variance across recent builds of nearly identical trees has been ±0.2 ns
(1.200 / 1.323 / 1.405 / 1.230 ns), so treat small movements as placement noise
rather than as a signal about a particular change.

These figures are a build snapshot. Regenerate `utilization.rpt`,
`utilization_hier.rpt`, and `timing_summary.rpt` after later RTL or tool changes —
they are produced by `scripts/build_soc.tcl` and uploaded by the Vivado CI job as
the `vivado-ci-reports` artifact.

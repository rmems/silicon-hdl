<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- resource-budget-n16.md -->

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

For the #61 implementation, a routed Vivado 2026.1 build measured **279 LUTs**
(1.34%), **429 flip-flops** (1.03%), **three RAMB18E1s** (1.5 Block RAM tiles),
and **0 DSPs**. Timing closed at 100 MHz with WNS **+1.200 ns** and WHS
**+0.177 ns**. These figures are a build snapshot; regenerate
`utilization.rpt` and `timing_summary.rpt` after later RTL or tool changes.

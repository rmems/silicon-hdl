<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- resource-budget-n16.md -->
<!-- Last updated: 2026-09-12 -->

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

## Per-module breakdown

From `utilization_hier.rpt` (`report_utilization -hierarchical`), same routed build:

| Instance | Module | LUTs | % of LUTs | FFs | % of FFs |
|---|---|---|---:|---:|---:|
| `u_protocol_fsm` | `SocProtocolFsm` | 543 | 60.9% | 1,129 | 68.0% |
| `u_lif_array` | `LifNeuronArray` | 236 | 26.5% | 365 | 22.0% |
| `u_bridge` | `SiliconBridge` | 59 | 6.6% | 59 | 3.6% |
| `u_status_leds` | `SocStatusLeds` | 49 | 5.5% | 55 | 3.3% |
| — | top-level glue | 6 | 0.7% | 52 | 3.1% |
| **Total** | `spikenaut_soc_basys3_top` | **892** | | **1,660** | |

The LUT rows sum to 893 against a design total of **892**. That is expected, not a
transcription error — `utilization_hier.rpt` carries the explanation as a footnote:

> `* Note: The sum of lower-level cells may be larger than their parent cells total,`
> `due to cross-hierarchy LUT combining`

Two logic functions from different modules packed into one physical LUT are attributed to
both rows but counted once in the parent. **892 is the authoritative unique count**, and it
matches the flat `Slice LUTs` figure in `utilization.rpt`. The flip-flop column has no such
effect and reconciles exactly (52 + 59 + 365 + 1,129 + 55 = 1,660), so treat the per-module
LUT split as accurate to about ±1 and the FF split as exact.

Three things this settles:

- **`SocProtocolFsm` dominates**, at ~61% of LUTs and ~68% of flip-flops. That matches
  its structure: it holds *both* an active and a pending 16-word Q8.8 response snapshot
  (2 × 16 × 16 = 512 flip-flops of snapshot alone) plus the receive payload buffer. It is
  the first place to look if the budget ever gets tight, not the neuron array.
- **`SocStatusLeds` is cheap** — 49 LUTs and 55 flip-flops, ~5% and ~3%. The shared
  stretch prescaler was chosen over eight independent counters precisely to keep it that
  way, and the measurement bears that out.
- The 52 top-level glue flip-flops account for exactly the expected set: the `sw` 2FF
  synchronizer (32), the `step_cnt` divider (17) and `step_en` (1), plus `stimuli_pending`
  and `response_armed` (1 each).

`StdpController`, `WeightRam` and the two `NeuronParamRam` instances do not appear as
separate rows. The RAMs are inferred as the three top-level `RAMB18E1` primitives, and
`u_stdp` contributes no reportable logic because its writeback ports are still detached
(the [#70](https://github.com/rmems/silicon-hdl/issues/70) exclusion documented in
`AGENTS.md`) — so most of it optimizes away. Expect its cost to appear once #70 lands.

WNS variance across recent builds of nearly identical trees has been ±0.2 ns
(1.200 / 1.323 / 1.405 / 1.230 ns), so treat small movements as placement noise
rather than as a signal about a particular change.

## Update: signed Dale E/I path (#73)

Routed Vivado 2026.1 build after making `LifNeuron`/`LifNeuronArray` treat weight and
membrane state as signed Q8.8 (leak/integrate/compare, see `CHANGELOG.md`):

| Resource | Used | Available | Utilization | vs. #85 baseline |
|---|---|---|---|---|
| Slice LUTs | 913 | 20,800 | 4.39% | +21 |
| Slice Registers | 1,738 | 41,600 | 4.18% | +78 |
| Block RAM Tile | 1.5 (3 × RAMB18E1) | 50 | 3.00% | unchanged |
| DSPs | 0 | 90 | 0.00% | unchanged |
| Bonded IOB | 36 | 106 | 33.96% | unchanged |

| Metric | Value | Failing / total endpoints | vs. #85 baseline |
|---|---|---|---|
| WNS | **+0.708 ns** | 0 / — | −0.52 ns |
| WHS | +0.106 ns | 0 / — | unchanged |
| WPWS | +4.500 ns | 0 / — | unchanged |

Timing still closes with zero failing endpoints, but WNS moved beyond the ±0.2 ns
placement-noise band noted above — a real, small cost of the wider signed arithmetic
in `LifNeuronArray`'s shared leak/integrate/compare datapath (the RAM-to-LIF critical
path this file already calls out). Two rounds of simplification during this change
kept it closable without adding a pipeline stage: saturating the integrate sum via a
guard-bit/sign check instead of a magnitude compare against `MAX_MEM`/`MIN_MEM`, and
decaying the (now signed) membrane via one sign-selected add/subtract plus a
sign-flip clamp check instead of two magnitude compares. Before those two changes,
the same signed rework missed timing at −1.783 ns / 119 failing endpoints.

Per-module hierarchy attribution shifted more than the module-level changes alone
would suggest (e.g. `u_lif_array` itself measured 205 LUTs here, down from 236, while
several untouched modules' rows also moved) — consistent with this doc's existing
cross-hierarchy-LUT-combining caveat on the per-module split; the top-level totals
above are the reliable numbers. `u_lif_array`'s flip-flop count is unchanged (365):
this change widens combinational intermediates, not the `membrane_potential`
register file itself.

These figures are a build snapshot. Regenerate `utilization.rpt`,
`utilization_hier.rpt`, and `timing_summary.rpt` after later RTL or tool changes —
they are produced by `scripts/build_soc.tcl` and uploaded by the Vivado CI job as
the `vivado-ci-reports` artifact.

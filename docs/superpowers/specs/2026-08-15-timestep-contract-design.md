<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-08-15 -->

# Timestep contract + gated LIF + Vivado on main

Design spec for GitHub **#57** (logical timestep ADR), **#60** (timestep-gated LIF), and
public **Vivado CI on `push` to `main`**. Parent epic: **#54**. Linear twins: **RM-294**,
**RM-287**. Project: **Neuromorphic FPGA / HDL**.

## Goal

Stop `LifNeuron` leaking every 10 ns on the 100 MHz Basys 3 fabric clock so
`merged_v2` Q8.8 leak/threshold can integrate. Document the contract, implement
the SoC 1 ms tick, and publish self-hosted Vivado results on every merge to
`main`.

No breadboard. The on-board oscillator is the only clock.

## Decisions (locked)

| Topic | Decision |
| --- | --- |
| Fabric clock | 100 MHz (`sys_clk_pin`, 10 ns) — unchanged |
| Logical tick | **1 ms** (1 kHz) = **100_000** fabric cycles |
| Enable | One-cycle `step_en` from a SoC divider in `spikenaut_soc_basys3_top` |
| Core API | `LifNeuron` and `StdpController` grow `step_en`; default **1** so existing unit TBs stay “tick every clock” |
| STDP window | `WINDOW_WIDTH` counts **ticks**, not fabric clocks |
| Packaging | **One PR** (ADR + RTL + CI). Board program is **#68**, later, optional |
| Host step | **#62** may AND/replace the divider later. Not this PR |
| N=16 | **#61**, later |

## Architecture

```
100 MHz clk ──► step divider (100_000) ──► step_en (1 cycle / 1 ms)
                      │
                      ├──► LifNeuron.step_en     (leak / integrate / fire)
                      └──► StdpController.step_en (trace decay / LTP-LTD)
```

- **Owner of the tick:** SoC wrapper, not `lib_core` internals.
- When `step_en` is 0: hold `membrane_potential`, `spike_out`, and STDP traces;
  ignore `spike_in` for integration (sample/integrate only on the tick).
- When `step_en` is 1: existing LIF and STDP combinational update rules run for
  that cycle (including classical STDP polarity from #55).
- Reset (`rst_n` low) still clears state regardless of `step_en`.

## RTL changes

### `LifNeuron`

- Add `input logic step_en`. **Always connect it** at every instance (do not
  rely on SV port defaults). Unit TBs drive `1'b1` so existing sequences stay
  “tick every clock.” SoC drives the divider.
- Gate the existing `always_ff` body: `else if (step_en)` apply leak/integrate/
  threshold; `else` hold registers.
- Header comment: updates are per logical tick, not per fabric edge.

### `StdpController`

- Add `input logic step_en` (always connected; TBs drive `1'b1`).
- Shift traces and evaluate LTP/LTD only when `step_en` is 1; hold otherwise.
- Keep saturation `weight_we` contract from #55.

### `spikenaut_soc_basys3_top`

- Localparam `STEP_DIV = 100_000` (derived from 100 MHz × 1 ms).
- Free-running counter; pulse `step_en` for one cycle when it wraps.
- Connect `step_en` to `u_neuron` and `u_stdp`.
- Replace the E3 comment (“leak every 100 MHz cycle”) with a pointer to this
  contract and `docs/timestep-contract.md`.

Do **not** copy LIF into the SoC. Do **not** change weight/param `.mem` images.

## Documentation

- New ADR: `docs/timestep-contract.md` (this spec’s public form: decision,
  default N, owner, STDP window, non-goals, pointer to #60 implementation).
- Link from `AGENTS.md` and `docs/interface-alignment.md`.
- `CHANGELOG.md` `[Unreleased]`: gated LIF + Vivado-on-main.
- `docs/releases.md` / README: note that Vivado CI also runs on `push` to
  `main` (self-hosted).

## CI

- `.github/workflows/vivado-ci.yml`: add

  ```yaml
  push:
    branches: [main]
  ```

- Keep existing `pull_request` + `workflow_dispatch`.
- Keep job `if:` so **same-repo** PRs and dispatch run; fork PRs still skip.
- Runner remains `[self-hosted, vivado]`. **Never** a required free-runner
  check. **Never** program the Basys 3 in this workflow.
- Artifact name stays `vivado-ci-reports`.

## Tests

- Existing `tb_LifNeuron` / `tb_StdpController`: drive `step_en = 1` (or rely
  on default) so current sequences stay valid.
- Extend `tb_LifNeuron` (or add a focused case in the same file):
  - Hold `step_en` 0 for several cycles with leak and `spike_in`: membrane /
    `spike_out` must not change after reset settle.
  - Pulse `step_en` once: exactly one leak/integrate step.
- Extend `tb_StdpController`: traces do not decay while `step_en` is 0.
- SoC: no new Verilator top required this PR; comment + divider are reviewed
  in Vivado synth. Optional small comment-only note in the SoC file is enough.
- Free stack: `bash scripts/quality.sh` (guardian + four core TBs) must pass.
- After merge to `main`: confirm Actions **Vivado CI** ran on the push and
  uploaded artifacts.

## Non-goals

- Breadboard or external clock hardware
- Programming / UART smoke on CI (**#68**)
- Host “step” command / protocol FSM (**#62**)
- Multi-neuron time-mux (**#61**)
- STDP writeback into `WeightRam` (**#70**)
- Cutting `v0.1.0` (**#69**)
- Auto-release on tags

## Acceptance

- [ ] ADR merged with the locked table above and explicit non-goals
- [ ] Linked from `AGENTS.md` or `interface-alignment`
- [ ] SoC LIF does not leak every fabric cycle; `step_en` from 1 ms divider
- [ ] Unit TBs lock hold-when-disabled and one-step-when-pulsed
- [ ] Vivado CI runs on `push` to `main`; reports remain public artifacts
- [ ] Guardian + Verilator green; assign **rmems**; close #57 and #60 (and
      Linear RM-294 / RM-287)

## Implementation order (for the later plan)

1. ADR + links
2. `LifNeuron` + TB
3. `StdpController` + TB
4. SoC divider + wiring
5. Vivado workflow trigger
6. CHANGELOG / quality.sh
7. PR, trackers, assignee

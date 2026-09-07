<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-06 -->
# AGENTS.md

Companion agent guidance for `silicon-hdl`. Claude Code loads this file via `@AGENTS.md` from
`CLAUDE.md`. Entry identity and boundaries remain in `CLAUDE.md`.

## Build and test

**Local free-stack quality** (guardian + every core/bridge/SoC Verilator TB):

```bash
./scripts/quality.sh
# optional Vivado sim + SoC build (requires source ~/Xilinx/env.sh):
./scripts/quality.sh --vivado
```


No Vivado license is assumed locally. Prefer Verilator for iteration; reserve Vivado for
synthesis and bitstream generation.

**Vivado CI** (self-hosted only, never a free-runner required check):

- Workflow: `.github/workflows/vivado-ci.yml` (issue #12 / epic #23 Phase B)
- Triggers: **same-repo** pull_request (`opened` / `synchronize` / `reopened` /
  `ready_for_review`), **`push` to `main`** (intentional — reports on every
  default-branch update), plus **Actions → Vivado CI → Run workflow**
- Because `push` to `main` runs repo-controlled scripts on the self-hosted
  runner unconditionally, **branch protection on `main` is what keeps that
  path trusted** — require reviewed PRs (and/or restrict the `vivado` runner
  group) rather than relying on the workflow file alone
- **Fork PRs are skipped** when they leave this workflow file alone
  (`head.repo.full_name == github.repository` job `if:`). Residual risk: GitHub
  runs the workflow from the PR *head*, so a fork that edits `vivado-ci.yml` can
  drop the gate — keep **Require approval for all outside collaborators** (or
  restrict the self-hosted runner group) enabled for real fork isolation
- After a run, open the PR **Checks** tab or **Actions → Vivado CI**
- Runner: `silicon-hdl-vivado` labels `self-hosted`,`vivado` (`~/actions-runner/silicon-hdl-runner`)


### Verilator (core unit testbenches)

Pattern used by CI in `.github/workflows/sim.yml`:

```bash
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_LifNeuron \
  -Ispikenaut-core-sv/rtl \
  spikenaut-core-sv/rtl/LifNeuron.sv \
  spikenaut-core-sv/tb/tb_LifNeuron.sv
./obj_dir/Vtb_LifNeuron
```

To run another core unit testbench, replace the top module name and both source paths with one
of the pairs below. Prefer removing `obj_dir` first (`rm -rf obj_dir`) so different tops do not
share build artifacts; if you keep a shared `obj_dir`, re-run from a clean directory when
symbols or tops conflict.

| Top module | Device under test (DUT) / testbench (TB) sources |
|---|---|
| `tb_LifNeuron` | `spikenaut-core-sv/rtl/LifNeuron.sv` + `spikenaut-core-sv/tb/tb_LifNeuron.sv` |
| `tb_LifNeuronArray` | `spikenaut-core-sv/rtl/LifNeuronArray.sv` + `spikenaut-core-sv/tb/tb_LifNeuronArray.sv` |
| `tb_WeightRam` | `spikenaut-core-sv/rtl/WeightRam.sv` + `spikenaut-core-sv/tb/tb_WeightRam.sv` |
| `tb_WeightRam_init` | `spikenaut-core-sv/rtl/WeightRam.sv` + `spikenaut-core-sv/tb/tb_WeightRam_init.sv` — `$readmemh` of the merged_v2 weight image; needs repo-root CWD |
| `tb_NeuronParamRam` | `spikenaut-core-sv/rtl/NeuronParamRam.sv` + `spikenaut-core-sv/tb/tb_NeuronParamRam.sv` |
| `tb_NeuronParamRam_init` | `spikenaut-core-sv/rtl/NeuronParamRam.sv` + `spikenaut-core-sv/tb/tb_NeuronParamRam_init.sv` — `$readmemh` of the merged_v2 threshold image; needs repo-root CWD |
| `tb_StdpController` | `spikenaut-core-sv/rtl/StdpController.sv` + `spikenaut-core-sv/tb/tb_StdpController.sv` |
| `tb_UartRx` | `spikenaut-bridge-sv/rtl/UartRx.sv` + `spikenaut-bridge-sv/tb/tb_UartRx.sv` |
| `tb_UartTx` | `spikenaut-bridge-sv/rtl/UartTx.sv` + `spikenaut-bridge-sv/tb/tb_UartTx.sv` |
| `tb_SiliconBridge` | `spikenaut-bridge-sv/rtl/UartRx.sv` + `spikenaut-bridge-sv/rtl/UartTx.sv` + `spikenaut-bridge-sv/rtl/SiliconBridge.sv` + `spikenaut-bridge-sv/tb/tb_SiliconBridge.sv` |
| `tb_SocProtocolFsm` | `spikenaut-soc-sv/rtl/SocProtocolFsm.sv` + `spikenaut-soc-sv/tb/tb_SocProtocolFsm.sv` |
| `tb_SocStatusLeds` | `spikenaut-soc-sv/rtl/SocStatusLeds.sv` + `spikenaut-soc-sv/tb/tb_SocStatusLeds.sv` |
| `tb_SynapseRouter` | `synapse-link-hdl/src/SynapseRouter.sv` + `synapse-link-hdl/tb/tb_SynapseRouter.sv` |

`synapse_demo_basys3_top` has no testbench, so `quality.sh` and `sim.yml` elaborate it
with `verilator --lint-only` instead. Without that it is the only synthesizable top in the
repo that CI never compiles, and a broken port list would ship silently. It checks
elaboration and port consistency only — it does not simulate.

Testbenches call `$fatal` on failure and are self-checking (look for an `errors` counter and
`$display` summary at the end). Bridge TBs use a fast integer baud (`CLK_FREQ=1_000_000`,
`BAUD_RATE=100_000`) so a byte is tens of clocks, not a 100 MHz / 115200 bit time.

### SoC-level testbench

`tb_spikenaut_soc_basys3_top` (`spikenaut-soc-sv/tb/tb_Basys3_Top.sv`) is the only simulation
that covers the 1 ms `step_en` divider and the UART-event → tick-domain handoff — the core unit
TBs drive `step_en` themselves, so they cannot reach either. It needs the full
`lib_bridge` → `lib_core` → `lib_soc` source list and must run from the repo root
(`$readmemh` `INIT_FILE` paths are repo-root relative):

```bash
rm -rf obj_dir
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_spikenaut_soc_basys3_top \
  -Ispikenaut-core-sv/rtl -Ispikenaut-bridge-sv/rtl \
  spikenaut-bridge-sv/rtl/UartRx.sv spikenaut-bridge-sv/rtl/UartTx.sv \
  spikenaut-bridge-sv/rtl/SiliconBridge.sv \
  spikenaut-core-sv/rtl/LifNeuron.sv spikenaut-core-sv/rtl/LifNeuronArray.sv \
  spikenaut-core-sv/rtl/WeightRam.sv spikenaut-core-sv/rtl/NeuronParamRam.sv \
  spikenaut-core-sv/rtl/StdpController.sv \
  spikenaut-soc-sv/rtl/SocProtocolFsm.sv \
  spikenaut-soc-sv/rtl/SocStatusLeds.sv \
  spikenaut-soc-sv/rtl/Basys3_Top.sv spikenaut-soc-sv/tb/tb_Basys3_Top.sv
./obj_dir/Vtb_spikenaut_soc_basys3_top
```

Notes for editing it:

- It observes `step_en`, `step_cnt`, `stimuli_pending`, `protocol_stimuli`, `response_armed`,
  `frame_send`, and the PE membrane register file by hierarchical reference, so the synthesized
  top needs no debug ports. Renaming those nets breaks the TB.
- `step_en` is a **register**: it is set at posedge P and the cores consume it at posedge P+1.
  Sample post-tick state via `wait_tick_applied()`, not `wait_for_tick()`.
- Tick period and pulse width are checked by a free-running monitor on every tick; absolute
  first-tick latency is measured in the main sequence to keep it free of process-ordering races.
- Reset polarity is inverted at this level: the `rst_n` **port** is the active-high BTNC button,
  so the TB asserts reset with `btn_rst = 1`.

### Vivado (when available)

```bash
vivado -mode batch -source scripts/build_soc.tcl   # synth + implement + write bitstream for Basys 3
vivado -mode batch -source scripts/sim_core.tcl     # all core unit testbenches
```

`scripts/build_soc.tcl` hardcodes its register-transfer-level (RTL) source-file lists. When you
add a new RTL module under `spikenaut-core-sv/rtl`, `spikenaut-bridge-sv/rtl`, or
`spikenaut-soc-sv/rtl`, append that path to the matching `read_verilog -sv` block in
`scripts/build_soc.tcl`. `scripts/sim_core.tcl` hardcodes the same RTL lists and discovers testbench files under
`spikenaut-core-sv/tb`, `spikenaut-bridge-sv/tb`, and `spikenaut-soc-sv/tb` via glob; new
testbenches are picked up automatically, but you must append the top module name to the
`core_tb_tops` list before it will run.

A testbench top has to be named by hand in **three** unrelated places —
`scripts/quality.sh`, `scripts/sim_core.tcl` (`core_tb_tops`) and
`.github/workflows/sim.yml` (one step each). These drifted in practice:
`quality.sh` was silently missing `tb_WeightRam_init` and `tb_NeuronParamRam_init`,
the only two testbenches that exercise `$readmemh` against the merged_v2 images, so a
broken memory image passed the local gate and failed only in CI.
`scripts/check_tb_coverage.py` now reconciles all three lists against the testbenches
actually on disk and fails with a diff naming the file to edit. It runs first in both
`quality.sh` and `sim.yml`.

### Deduplication check

Run before committing any RTL change:

```bash
python scripts/check_tb_coverage.py         # exits non-zero if a TB is missing from any runner
python scripts/dedup_guardian.py            # exits non-zero on strict duplicate violations
python scripts/dedup_guardian.py --radar radar.md --threshold 0.85   # near-dup "Dupe Radar" report
```

## Architecture notes

- **Compile order matters** and is fixed by dependency direction: `lib_bridge` → `lib_core` →
  `lib_soc` / `lib_synapse`.
- Logical SNN timestep vs fabric clock: [`docs/timestep-contract.md`](docs/timestep-contract.md)
  (1 ms `step_en` from the SoC; LIF/STDP do not update every 100 MHz edge).
- LED / status map: [`docs/led-map.md`](docs/led-map.md) — SW15 selects the
  combinational spike bitmap versus the stretched protocol status word.
- `spikenaut-soc-sv/rtl` and `synapse-link-hdl/examples/basys3` should only *instantiate*
  core/bridge modules and should not contain their own copies.
- If a SoC- or demo-only wrapper needs new logic, give it a distinct module name rather than
  cloning a core/bridge implementation.
- The two `Basys3_Top.sv` files (SoC vs. synapse demo) are deliberately separate top-level
  integrations with different module names (`spikenaut_soc_basys3_top` vs
  `synapse_demo_basys3_top`); this is not a duplicate the Guardian should flag as long as the
  module names stay distinct.
- Testbenches drive/sample stimulus on `negedge clk` to stay clear of the designs under test
  (DUTs') `posedge`-triggered `always_ff` blocks — follow the same convention in new testbenches.
- Universal asynchronous receiver/transmitter (UART) default `DATA_WIDTH` is 8 (matches the wire
  protocol); this parameter is intentionally propagated through `UartRx`/`UartTx`/`SiliconBridge`
  even though the protocol is fixed at 8-bit framing.
- Licensing: dual Massachusetts Institute of Technology (MIT) / Apache-2.0. Every source file
  (`.sv`, `.tcl`, `.xdc`, docs) carries a Software Package Data Exchange (SPDX) header such as
  `SPDX-License-Identifier: MIT OR Apache-2.0` (standard SPDX dual-license syntax) — include it
  on any new file.

## Issue tracking

This project uses **bd (beads)** for issue tracking — see the beads section in the root guidance
already loaded into your context (run `bd prime` if you need the full command reference). Do not
use TodoWrite or markdown TODO lists in this repo.

`bd` is the local source of truth for agent work tracking; **GitHub Issues** under
[`rmems/silicon-hdl`](https://github.com/rmems/silicon-hdl) and **Linear** (rmems / RM team)
are used for cross-session and product visibility. Assign **rmems** on GH PRs and Linear
twins; never ship tracking without an assignee.

## Releases (tags)

Public versions use **SemVer tags** (`vMAJOR.MINOR.PATCH`) on `main` after free CI is green,
plus a matching **GitHub Release**. See [`docs/releases.md`](docs/releases.md).

- Cut `CHANGELOG.md` `[Unreleased]` → `[x.y.z] - YYYY-MM-DD` when tagging.
- Do **not** auto-publish from free-runner CI (manual / `gh release create`).
- **`v0.1.0`** is reserved for F1 demo-complete ([#69](https://github.com/rmems/silicon-hdl/issues/69)).

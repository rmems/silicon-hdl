<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-07-21 -->
# AGENTS.md

Companion agent guidance for `silicon-hdl`. Claude Code loads this file via `@AGENTS.md` from
`CLAUDE.md`. Entry identity and boundaries remain in `CLAUDE.md`.

## Build and test

**Local free-stack quality** (guardian + all four core Verilator TBs):

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
  `ready_for_review`), plus **Actions → Vivado CI → Run workflow**
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
| `tb_WeightRam` | `spikenaut-core-sv/rtl/WeightRam.sv` + `spikenaut-core-sv/tb/tb_WeightRam.sv` |
| `tb_NeuronParamRam` | `spikenaut-core-sv/rtl/NeuronParamRam.sv` + `spikenaut-core-sv/tb/tb_NeuronParamRam.sv` |
| `tb_StdpController` | `spikenaut-core-sv/rtl/StdpController.sv` + `spikenaut-core-sv/tb/tb_StdpController.sv` |

Testbenches call `$fatal` on failure and are self-checking (look for an `errors` counter and
`$display` summary at the end).

### Vivado (when available)

```bash
vivado -mode batch -source scripts/build_soc.tcl   # synth + implement + write bitstream for Basys 3
vivado -mode batch -source scripts/sim_core.tcl     # all core unit testbenches
```

`scripts/build_soc.tcl` hardcodes its register-transfer-level (RTL) source-file lists. When you
add a new RTL module under `spikenaut-core-sv/rtl`, `spikenaut-bridge-sv/rtl`, or
`spikenaut-soc-sv/rtl`, append that path to the matching `read_verilog -sv` block in
`scripts/build_soc.tcl`. `scripts/sim_core.tcl` hardcodes the same RTL lists and discovers
testbench files under `spikenaut-core-sv/tb` via glob; new testbenches are picked up
automatically, but you must append the top module name to the `core_tb_tops` list before it
will run.

### Deduplication check

Run before committing any RTL change:

```bash
python scripts/dedup_guardian.py            # exits non-zero on strict duplicate violations
python scripts/dedup_guardian.py --radar radar.md --threshold 0.85   # near-dup "Dupe Radar" report
```

## Architecture notes

- **Compile order matters** and is fixed by dependency direction: `lib_bridge` → `lib_core` →
  `lib_soc` / `lib_synapse`.
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

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-14 -->
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
  default-branch update; coverage is load-bearing — do not drop this trigger
  without a human decision), plus **Actions → Vivado CI → Run workflow**
- **Residual risk (measured, not mitigated):** `push` to `main` runs
  repo-controlled scripts (`scripts/build_soc.tcl`, `scripts/sim_core.tcl`) on
  the self-hosted Vivado workstation. Re-measured 2026-09-14: repo is
  **public**; `GET /branches/main` → `{name: main, protected: false}`;
  `GET /rulesets` → `[]`. Classic `GET /branches/main/protection` is either
  `404 Branch not protected` (admin token) or `403 Resource not accessible by
  integration` (this cloud-agent token). There is **no** review gate between a
  direct push to `main` and execution on that machine. This is not a live
  exploit — it needs write access — but do **not** treat branch protection
  or a ruleset as enabled; they are not. Runner-group restriction was not
  re-measured here — treat it as unknown until confirmed in Actions settings.
- **Fork PRs are skipped** when they leave this workflow file alone
  (`head.repo.full_name == github.repository` job `if:`). Residual risk: GitHub
  runs the workflow from the PR *head*, so a fork that edits `vivado-ci.yml` can
  drop the gate. **Require approval for all outside collaborators** (or
  restrict the `vivado` runner group) would isolate that path; this file does
  **not** assert either setting is on — confirm in the repo Actions settings.
- After a run, open the PR **Checks** tab or **Actions → Vivado CI**
- Runner: `silicon-hdl-vivado` labels `self-hosted`,`vivado` (`~/actions-runner/silicon-hdl-runner`)
- **Human follow-ups** (not enabled here; do not invent that they are):
  - Ruleset or classic branch protection on `main` requiring a pull request
    before merge
  - Decide whether `push: branches: [main]` on `vivado-ci.yml` should stay
    (current default: keep it — do not weaken coverage) or become PR +
    `workflow_dispatch` only
  - Tighten Actions `allowed_actions` (`all` → `selected`) and require SHA
    pinning for self-hosted jobs (issue #87 measured `allowed_actions: all`
    and `sha_pinning_required: false`; this token cannot re-read Actions
    permissions)
  - Confirm **Require approval for all outside collaborators** for fork
    workflows


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
| `tb_NeuronParamRam` | `spikenaut-core-sv/rtl/NeuronParamRam.sv` + `spikenaut-core-sv/tb/tb_NeuronParamRam.sv` |
| `tb_StdpController` | `spikenaut-core-sv/rtl/StdpController.sv` + `spikenaut-core-sv/tb/tb_StdpController.sv` |
| `tb_OutputLayer` | `spikenaut-core-sv/rtl/WeightRam.sv` + `spikenaut-core-sv/rtl/OutputLayer.sv` + `spikenaut-core-sv/tb/tb_OutputLayer.sv` |
| `tb_LifNeuron_golden` | `spikenaut-core-sv/rtl/LifNeuron.sv` + `spikenaut-core-sv/tb/tb_LifNeuron_golden.sv` |
| `tb_OutputLayer_golden` | `spikenaut-core-sv/rtl/WeightRam.sv` + `spikenaut-core-sv/rtl/OutputLayer.sv` + `spikenaut-core-sv/tb/tb_OutputLayer_golden.sv` |
| `tb_UartRx` | `spikenaut-bridge-sv/rtl/UartRx.sv` + `spikenaut-bridge-sv/tb/tb_UartRx.sv` |
| `tb_UartTx` | `spikenaut-bridge-sv/rtl/UartTx.sv` + `spikenaut-bridge-sv/tb/tb_UartTx.sv` |
| `tb_SiliconBridge` | `spikenaut-bridge-sv/rtl/UartRx.sv` + `spikenaut-bridge-sv/rtl/UartTx.sv` + `spikenaut-bridge-sv/rtl/SiliconBridge.sv` + `spikenaut-bridge-sv/tb/tb_SiliconBridge.sv` |
| `tb_SocProtocolFsm` | `spikenaut-soc-sv/rtl/SocProtocolFsm.sv` + `spikenaut-soc-sv/tb/tb_SocProtocolFsm.sv` |
| `tb_SocFrameGolden` | `spikenaut-soc-sv/rtl/SocProtocolFsm.sv` + `spikenaut-soc-sv/tb/tb_SocFrameGolden.sv` |
| `tb_SocStatusLeds` | `spikenaut-soc-sv/rtl/SocStatusLeds.sv` + `spikenaut-soc-sv/tb/tb_SocStatusLeds.sv` |

Testbenches call `$fatal` on failure and are self-checking (look for an `errors` counter and
`$display` summary at the end). The three golden testbenches (`tb_LifNeuron_golden`,
`tb_OutputLayer_golden`, `tb_SocFrameGolden`) additionally read their stimulus *and* their
expectations from `spikenaut-core-sv/mem/golden/` and must be run from the repo root
(those paths are repo-root relative); see the Golden vectors sections below. Bridge TBs use a fast integer baud (`CLK_FREQ=1_000_000`,
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
  spikenaut-core-sv/rtl/OutputLayer.sv \
  spikenaut-soc-sv/rtl/SocProtocolFsm.sv \
  spikenaut-soc-sv/rtl/SocStatusLeds.sv \
  spikenaut-soc-sv/rtl/Basys3_Top.sv spikenaut-soc-sv/tb/tb_Basys3_Top.sv
./obj_dir/Vtb_spikenaut_soc_basys3_top
```

Notes for editing it:

- It observes `step_en`, `step_cnt`, `stimuli_pending`, `protocol_stimuli`, `response_armed`,
  `frame_send`, RAM `we`/`addr`/`mem`, and the PE membrane register file by hierarchical
  reference, so the synthesized top needs no debug ports. Renaming those nets breaks the TB.
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

### Deduplication check

Run before committing any RTL change:

```bash
python scripts/dedup_guardian.py            # exits non-zero on strict duplicate violations
python scripts/dedup_guardian.py --radar radar.md --threshold 0.85   # near-dup "Dupe Radar" report
```

### Golden vectors (GH#66)

`spikenaut-core-sv/mem/golden/` holds **generated** f32 -> Q8.8 -> `.mem` vectors that pin the
signed LIF datapath and the GH#72 output layer against the pinned exp-025 bank. Do not hand-edit
them.

```bash
python3 scripts/gen_golden_lif_vectors.py            # regenerate
python3 scripts/gen_golden_lif_vectors.py --check    # drift gate; exits non-zero if stale
```

`--check` runs in `scripts/quality.sh`, in `.github/workflows/sim.yml`, and from
`tests/test_golden_lif_vectors.py`. A red `tb_LifNeuron_golden` / `tb_OutputLayer_golden` normally
means the **RTL** changed behaviour, not that the vectors are stale — regenerate only when the
semantics change is intended, and in the same commit as the RTL change. `scripts/q88.py` is the
single Q8.8 codec; do not add a second one. Full rationale, scenario table, and the Spikenaut bank
pin: [`docs/golden-lif-vectors.md`](docs/golden-lif-vectors.md).

### Golden UART frame vectors (GH#64)

`spikenaut-core-sv/mem/golden/frame_golden_*.mem` are **generated** request / response byte
streams that pin the **SiliconBridge v3.0 wire framing** — the contract this repo shares with
the [`rmems/silicon-bridge`](https://github.com/rmems/silicon-bridge) host crate. Do not
hand-edit them.

```bash
python3 scripts/gen_golden_frame_vectors.py --check
```

The request frame is **33 bytes** (`0xAA` + 16 big-endian Q8.8 words) and the response frame is
**36 bytes** (16 potentials + spike-flag word + aux word). **Neither length moves.** GH#72's
output-class flags are LED-only (`status_word[15:13]`); anything that needs the class over UART
is a protocol version bump, not a field appended to the response. `tb_SocFrameGolden` asserts
both lengths at elaboration, and `tests/test_golden_frame_vectors.py` asserts them against the
values the Rust host hardcodes.

These vectors pin **framing only** — byte count, byte order, lane order, spike bit order, and
signedness. What the network computes is pinned by the GH#66 goldens above. Full byte layout,
case table, and the board-in-loop runbook: [`docs/host-soc-e2e.md`](docs/host-soc-e2e.md).

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

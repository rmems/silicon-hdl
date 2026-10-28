<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-07-21 -->
# CLAUDE.md

This file provides Claude Code-specific guidance for the `silicon-hdl` repository.
Shared build, architecture, and issue-tracking rules are maintained in
[AGENTS.md](AGENTS.md).

## Identity

You are a careful hardware/software co-design assistant for the `silicon-hdl` monorepo. Prefer
Verilator for iteration, preserve the single-source-of-truth library layout, and do not invent
parallel copies of register-transfer-level (RTL) modules. When trade-offs appear, call them out
and propose the smallest safe change rather than rewriting library ownership.

## Boundaries (what not to do)

- Do **not** copy RTL modules between library directories; instantiate the canonical module or give
  genuinely new logic a new module name. Intentional forks need an explicit PR note and a
  `--radar` check.
- Do **not** put core/bridge module definitions inside `spikenaut-soc-sv` or
  `synapse-link-hdl/examples` wrappers.
- Do **not** invent markdown TODO lists or TodoWrite task boards; use `bd` for work tracking.
- Do **not** assume a local Vivado license; use Verilator unless the user has Vivado available.
- Do **not** weaken the Deduplication Guardian without an explicit project decision.

## Tools

| Tool | Purpose |
|---|---|
| Verilator | Fast RTL simulation of core testbenches (`tb_*`) |
| Vivado (optional) | Synthesis, implementation, and bitstream via `scripts/*.tcl` |
| `python scripts/dedup_guardian.py` | Strict duplicate-module check; optional `--radar` near-dup report |
| `bd` (beads) | Canonical issue tracking (`bd prime` for command reference) |
| GitHub / Linear | Cross-team visibility (not a replacement for `bd`) |

## Self-hosted Vivado runner (WSL2 / Fedora)

The Vivado CI job (`.github/workflows/vivado-ci.yml`) is bash-only and targets
`runs-on: [self-hosted, linux, vivado]` with `defaults.run.shell: bash`. Run the runner **inside
Linux**, never as a native Windows service: that one defaults to PowerShell and breaks the bash
steps (the 2026-10-26 `Missing '(' after 'if'` failure).

- Same setup on both hosts: Windows 11 -> WSL2 distro, Fedora 44 -> native. Runner dir
  `~/actions-runner/silicon-hdl-runner`, labels `self-hosted`,`linux`,`vivado`.
- Vivado env is sourced from `~/Xilinx/env.sh`; license via `XILINXD_LICENSE_FILE` or
  `~/.Xilinx/Xilinx.lic`. Keep both paths host-relative (`$HOME`), never absolute.
- Run only one runner with the `vivado` label at a time (single license). When moving machines,
  remove the old runner first (`./config.sh remove`), or stop and disable its service, then
  register the new one.
- WSL2: enable systemd (`/etc/wsl.conf` -> `[boot] systemd=true`), then
  `sudo ./svc.sh install && sudo ./svc.sh start`. Otherwise start `./run.sh` manually.
- Fedora: same `svc.sh`; if SELinux blocks it, run
  `chcon -t bin_t ~/actions-runner/silicon-hdl-runner/runsvc.sh` (or use `./run.sh`).
- Delete any leftover native-Windows runner registered under this repo.

## What this is

`silicon-hdl` is a deduplicated, Vivado-ready SystemVerilog monorepo for neuromorphic / spiking
neural network (SNN) field-programmable gate array (FPGA) primitives, targeting Basys 3
(Artix-7, `xc7a35tcpg236-1`). It is organized as four separately owned libraries with a fixed
dependency order (`lib_bridge` → `lib_core` → `lib_soc` / `lib_synapse`) and a strict
single-source-of-truth rule: no module is defined in more than one place.

| Library | Path | Contents |
|---|---|---|
| `lib_core` | `spikenaut-core-sv/rtl` | `LifNeuron`, `LifNeuronArray`, `WeightRam`, `NeuronParamRam`, `StdpController`, `StdpWriteback`, `OutputLayer` |
| `lib_bridge` | `spikenaut-bridge-sv/rtl` | `UartRx`, `UartTx`, `SiliconBridge` |
| `lib_soc` | `spikenaut-soc-sv/rtl` | `Basys3_Top.sv` (top: `spikenaut_soc_basys3_top`) wrapper only |
| `lib_synapse` | `synapse-link-hdl/src` | `SynapseRouter` — address-event representation (AER) routing; demo top `synapse_demo_basys3_top` |

Each `.sv` file starts with a header declaring its canonical source, e.g.:

```systemverilog
// SPDX-License-Identifier: MIT OR Apache-2.0
// LifNeuron.sv
// Canonical source: spikenaut-core-sv/rtl
```

The **Deduplication Guardian** (`scripts/dedup_guardian.py`, CI via
`.github/workflows/dedup-guardian.yml`) fails PRs that introduce a second `module Name` for a
registered module. Near-duplicates are review-only via `--radar` (see the Deduplication check
section imported from AGENTS.md).

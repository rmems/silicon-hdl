<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-07-21 -->
# CLAUDE.md

@AGENTS.md

This file provides Claude Code-specific guidance for the `silicon-hdl` repository.
Shared build, architecture, and issue-tracking rules are imported from `AGENTS.md` above
(via the `@AGENTS.md` import, which Claude Code loads at session start).

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
| `python scripts/check_tb_coverage.py` | Fails if a testbench is missing from `quality.sh`, `sim_core.tcl` or `sim.yml` |
| `bd` (beads) | Canonical issue tracking (`bd prime` for command reference) |
| GitHub / Linear | Cross-team visibility (not a replacement for `bd`) |

## What this is

`silicon-hdl` is a deduplicated, Vivado-ready SystemVerilog monorepo for neuromorphic / spiking
neural network (SNN) field-programmable gate array (FPGA) primitives, targeting Basys 3
(Artix-7, `xc7a35tcpg236-1`). It is organized as four separately owned libraries with a fixed
dependency order (`lib_bridge` → `lib_core` → `lib_soc` / `lib_synapse`) and a strict
single-source-of-truth rule: no module is defined in more than one place.

| Library | Path | Contents |
|---|---|---|
| `lib_core` | `spikenaut-core-sv/rtl` | `LifNeuron`, `WeightRam`, `NeuronParamRam`, `StdpController` |
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

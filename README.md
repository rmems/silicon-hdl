<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# silicon-hdl

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-blue.svg)](#license)

Deduplicated, Vivado-ready monorepo for neuromorphic / spiking neural network FPGA
primitives, targeting Digilent Basys 3 (Artix-7).

## About this repo (learning field)

I am **still early on the HDL / SystemVerilog curve** — far from expert. This
repository is my **practice ground**: real RTL, Verilator CI, optional Vivado and
Basys 3 bring-up, and experimental SNN demos (weights via `$readmemh`, multi-neuron
scale later). I rely **heavily on AI coding agents** (and review bots) to design,
debug, and keep the tree consistent (dedup guardian, free CI). Treat PRs and docs as
student-lab work in public, not as production-grade silicon or a finished product.

If you fork or review: expect sharp edges, questions in issues, and iterative
learning. Corrections and teaching-oriented reviews are welcome.

## What this tree implements

Honest hardware snapshot of **SoC wiring**, not of unit-testbench existence. Status
vocabulary is **works** / **partial** / **not wired**. The AER row remains
**partial** until its PR, Vivado evidence, cross-repo producers, and live board
acceptance exist. Parent epic:
[#54](https://github.com/rmems/silicon-hdl/issues/54). This table is the
maturity claim; [`docs/interface-alignment.md`](docs/interface-alignment.md),
[`docs/host-soc-e2e.md`](docs/host-soc-e2e.md),
[`docs/aer-routing-contract.md`](docs/aer-routing-contract.md),
[`docs/led-map.md`](docs/led-map.md), and
[`spikenaut-core-sv/mem/README.md`](spikenaut-core-sv/mem/README.md) hold the
contracts.

**Live bank:** exp-025 Dale health-PASS (12:4 E/I),
[Spikenaut-SNN#47](https://github.com/rmems/Spikenaut-SNN/pull/47) @ `6965e12a`.
Do not invent hex.

| Area | Status | What is on `main` | Evidence |
|---|---|---|---|
| Core primitives | **works** | Signed two's-complement Q8.8 `LifNeuron` / `LifNeuronArray`: Dale-I weights subtract (`0xFF00` = −1.0), leak recovers toward 0 from either side, integrate saturates at `16'h7FFF` / `16'h8000`. `WeightRam`, `NeuronParamRam`, and `OutputLayer` have self-checking Verilator TBs. | [#91](https://github.com/rmems/silicon-hdl/pull/91) / [#73](https://github.com/rmems/silicon-hdl/issues/73) |
| Basys SoC demo | **partial** | N=16 `spikenaut_soc_basys3_top`: 1 ms `step_en`, `$readmemh` INIT banks, `SocProtocolFsm` host frames, combinational LED mux. Verilator `tb_spikenaut_soc_basys3_top` covers the tick divider and UART-event → tick handoff. Live board evidence is a one-time heartbeat smoke (LED0 blink, DONE high) — **not** a UART host session. | [#68](https://github.com/rmems/silicon-hdl/issues/68) PASS @ `7208d8c`; [`docs/phase-c-board-smoke.md`](docs/phase-c-board-smoke.md) |
| STDP | **works, opt-in** | `StdpWriteback` serializes the selected column back into the single-port WeightRam when SW14 is high; the captured pre-event column is the AER-routed address. | [#70](https://github.com/rmems/silicon-hdl/issues/70) / [#103](https://github.com/rmems/silicon-hdl/pull/103) |
| Host UART protocol | **works** | SiliconBridge v3.0 remains 33-byte request / **36-byte** response. The 5-byte `0xA5` command now accepts target 3 for AER without changing frame lengths. | [#64](https://github.com/rmems/silicon-hdl/issues/64) / [#71](https://github.com/rmems/silicon-hdl/issues/71) |
| AER routing | **partial** | Canonical `AerRouteTable` consumes a generated 16-entry `aer-route-v1` image, supports bounded four-lookup routes and safe target-3 rewrites, and feeds routed addresses to LIF/STDP. Free-stack tests pass; NIR producers, Vivado candidate evidence, and live Basys proof remain closure gates. | [#71](https://github.com/rmems/silicon-hdl/issues/71) / Linear RM-259 |
| Output-class LEDs | **works** | 3-class argmax of `spike_bitmap` × `merged_v2_output_weights.mem`, latched onto `status_word[15:13]` (SW15 = 1). LED-only; `FRAME_BYTES` stays 36. | [#94](https://github.com/rmems/silicon-hdl/pull/94) / [#72](https://github.com/rmems/silicon-hdl/issues/72); SoC TB 13a |
| `.mem` INIT images | **works** | Four signed Q8.8 banks plus one generated route image load at synth/sim. Route metadata pins schema, geometry, origin, and digest; generated files are drift-checked and never hand-edited. | [#66](https://github.com/rmems/silicon-hdl/issues/66) / [#71](https://github.com/rmems/silicon-hdl/issues/71) |

### Non-goals (not on this demo path)

| Non-goal | Why it is out |
|---|---|
| Stage-1 axons 5–15 | Bank columns 5–15 are structurally zero (`unused_axons`); not a missing RTL wire. See [`docs/lif-array-connectivity-model.md`](docs/lif-array-connectivity-model.md). |
| Parsing NIR in RTL | NIR validation/lowering belongs to Spikenaut and optional-`nir-rs` silicon-bridge producer work. |
| FPGA↔Julia spike/action parity | [Spikenaut-SNN#6](https://github.com/rmems/Spikenaut-SNN/issues/6) Stage 3 — out of this repo. |
| Extending `FRAME_BYTES` | 36-byte response is the SiliconBridge v3.0 contract; class bits stay LED-only. |
| Inventing weights | Retrain/export from the vault / Hub; do not hand-author `.mem` hex. |

## Repository layout

```
silicon-hdl/
├── spikenaut-core-sv/         # lib_core  – canonical SNN logic
│   ├── rtl/                   #   LifNeuron, RAMs, StdpController, StdpWriteback, OutputLayer
│   ├── tb/                    #   Unit testbenches
│   └── doc/
├── spikenaut-soc-sv/          # lib_soc  – SoC wrappers only
│   ├── rtl/                   #   SocProtocolFsm, SocStatusLeds, spikenaut_soc_basys3_top (Basys3_Top.sv)
│   ├── tb/                    #   Integration testbenches
│   └── ip/                    #   Xilinx IP blocks
├── spikenaut-bridge-sv/       # lib_bridge  – communication primitives
│   ├── rtl/                   #   UartRx, UartTx, SiliconBridge
│   └── tb/
├── synapse-link-hdl/          # lib_synapse  – AER routing + demo
│   ├── src/                   #   AerRouteTable + standalone-demo SynapseRouter
│   ├── mem/                   #   generated aer-route-v1 image + metadata
│   ├── tb/                    #   bounded routing unit testbench
│   └── examples/
│       └── basys3/            #   synapse_demo_basys3_top (Basys3_Top.sv)
├── constraints/
│   ├── basys3.xdc
│   ├── basys3_soc.xdc         # SoC-only switch pins
│   └── artix7_trainer.xdc
└── scripts/
    ├── build_soc.tcl          # Vivado build: SoC for Basys 3
    └── sim_core.tcl           # Vivado sim: core unit tests
```

## Module ownership (no duplicates)

| Module | Canonical location |
|---|---|
| `LifNeuron` | `spikenaut-core-sv/rtl/LifNeuron.sv` |
| `LifNeuronArray` | `spikenaut-core-sv/rtl/LifNeuronArray.sv` |
| `WeightRam` | `spikenaut-core-sv/rtl/WeightRam.sv` |
| `NeuronParamRam` | `spikenaut-core-sv/rtl/NeuronParamRam.sv` |
| `StdpController` | `spikenaut-core-sv/rtl/StdpController.sv` |
| `StdpWriteback` | `spikenaut-core-sv/rtl/StdpWriteback.sv` |
| `UartRx` | `spikenaut-bridge-sv/rtl/UartRx.sv` |
| `UartTx` | `spikenaut-bridge-sv/rtl/UartTx.sv` |
| `SiliconBridge` | `spikenaut-bridge-sv/rtl/SiliconBridge.sv` |
| `SocProtocolFsm` | `spikenaut-soc-sv/rtl/SocProtocolFsm.sv` |
| `SocStatusLeds` | `spikenaut-soc-sv/rtl/SocStatusLeds.sv` |
| `SynapseRouter` | `synapse-link-hdl/src/SynapseRouter.sv` |
| `AerRouteTable` | `synapse-link-hdl/src/AerRouteTable.sv` |
| `spikenaut_soc_basys3_top` | `spikenaut-soc-sv/rtl/Basys3_Top.sv` |
| `synapse_demo_basys3_top` | `synapse-link-hdl/examples/basys3/Basys3_Top.sv` |

> **Note:** `spikenaut-soc-sv/rtl` does **not** contain copies of core or bridge modules.
> All build scripts source core modules exclusively from `spikenaut-core-sv/rtl`
> and `AerRouteTable` exclusively from `synapse-link-hdl/src`; the main SoC
> instantiates them rather than copying them.

## Vivado build

```tcl
# Synthesize + implement the SoC and generate a bitstream
vivado -mode batch -source scripts/build_soc.tcl

# Run core unit-level simulation
vivado -mode batch -source scripts/sim_core.tcl
```

## Deduplication verification

The manual greps below are enforced automatically by the **Deduplication Guardian**
(`.github/workflows/dedup-guardian.yml` + `scripts/dedup_guardian.py` — see issue #5).

Run locally for the full "Dupe Radar" + Purity Score:

```bash
python scripts/dedup_guardian.py
```

```bash
grep -R "module LifNeuron"       . --include="*.sv"  # expect 1 hit
grep -R "module WeightRam"       . --include="*.sv"  # expect 1 hit
grep -R "module NeuronParamRam"  . --include="*.sv"  # expect 1 hit
grep -R "module StdpController"  . --include="*.sv"  # expect 1 hit
grep -R "module UartRx"          . --include="*.sv"  # expect 1 hit
grep -R "module UartTx"          . --include="*.sv"  # expect 1 hit
grep -R "module SiliconBridge"   . --include="*.sv"  # expect 1 hit
grep -R "module Basys3_Top"      . --include="*.sv"  # expect 0 hits (renamed)
grep -R "module spikenaut_soc_basys3_top"  . --include="*.sv"  # expect 1 hit
grep -R "module synapse_demo_basys3_top"   . --include="*.sv"  # expect 1 hit
```

## Releases

Versions use SemVer git tags (`vX.Y.Z`) plus GitHub Releases under
[`rmems/silicon-hdl`](https://github.com/rmems/silicon-hdl/releases). Process:
[`docs/releases.md`](docs/releases.md). Changelog: [`CHANGELOG.md`](CHANGELOG.md).
F0+F1+F2 demo-complete scope is **`v0.2.0`**
([#69](https://github.com/rmems/silicon-hdl/issues/69)); do not treat git tag
`v0.1.0` as that cut.

## License

Licensed under either of

* Apache License, Version 2.0
  ([LICENSE-APACHE-2.0](LICENSE-APACHE-2.0) or <http://www.apache.org/licenses/LICENSE-2.0>)
* MIT license
  ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.

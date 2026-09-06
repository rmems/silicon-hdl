<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-06 -->

# silicon-hdl runtime / deployment boundary matrix

Planning document for GitHub [#3](https://github.com/rmems/silicon-hdl/issues/3)
and Linear [LIM-9](https://linear.app/rpd-34/issue/LIM-9/plan-rust-runtime-and-deployment-repo-boundary-matrix).
F0 honesty refresh: GitHub [#56](https://github.com/rmems/silicon-hdl/issues/56)
under finishing epic [#54](https://github.com/rmems/silicon-hdl/issues/54).

This is **documentation only** — no RTL, CI, runtime, or repo-consolidation changes.

**Canonical path (linkable from LIM-9):** `docs/boundary-matrix.md` in
[rmems/silicon-hdl](https://github.com/rmems/silicon-hdl).

> **Naming:** LIM-9 and several sibling docs still say **Spikenaut-Hardware**. That name
> referred to the FPGA/HDL layer. The living monorepo for that layer is **`silicon-hdl`**.
> Prefer `silicon-hdl` in all new docs; treat “Spikenaut-Hardware” as a historical alias
> unless pointing at the legacy GitHub repo explicitly.

---

## Purpose

`silicon-hdl` is the **hardware / FPGA layer** of the neuromorphic stack (owned under
[`rmems/silicon-hdl`](https://github.com/rmems/silicon-hdl); historically Limen-Neural): a
deduplicated, Vivado-ready SystemVerilog monorepo of neuromorphic / spiking-neural-network
(SNN) primitives targeting Basys 3 (Artix-7, `xc7a35tcpg236-1`).

It provides:

1. **Canonical RTL** for SNN compute (`LifNeuron`, `LifNeuronArray`, `WeightRam`, `NeuronParamRam`,
   `StdpController`)
2. **On-chip communication primitives** (`UartRx`, `UartTx`, `SiliconBridge`) that the
   host-side `silicon-bridge` crate talks to over UART
3. **Thin board tops** only (`spikenaut_soc_basys3_top`, `synapse_demo_basys3_top`) plus
   AER routing (`SynapseRouter`)
4. **Build / sim / quality tooling** for Verilator iteration and optional Vivado synth /
   bitstream (no assumption of a local Vivado license)

It is **not** a Rust runtime, training loop, reward shaper, host UART client, or place to
park domain adapters (trading, mining, etc.).

---

## Layer placement

| Layer | Role | Example repos |
|-------|------|---------------|
| Core SNN / traits | Neuron dynamics, shared trait contracts (software) | `neuromod` |
| Sensory / extract | Continuous→spike, MoE→SNN parameters | `axon-encoder`, `engram-parser` |
| Topology / train | Connectivity, plasticity, offline training | `synaptic-mesh`, `plasticity-lab` |
| Reward / critic | Neuromodulator-style signals | `limbic-critic` |
| Runtime host | Headless inference orchestration | `brainstem-daemon` |
| Deployment (host bridge) | Q8.8 export, UART host, optional host metrics parse | `silicon-bridge` |
| **Deployment / hardware (this repo)** | **SystemVerilog RTL, board tops, FPGA build** | **`silicon-hdl`** |

```text
training / runtime crates (Rust)
        │  float thresholds, weights, decay
        ▼
  silicon-bridge   ── .mem / UART ──►  silicon-hdl (FPGA bitstream)
        (host)                           (this repo)
```

Within `silicon-hdl`, library ownership is fixed and compile-order constrained:

```text
lib_bridge  →  lib_core  →  lib_soc / lib_synapse
 (UART)        (SNN)        (thin tops / AER demo)
```

| Library | Path | Contents |
|---------|------|----------|
| `lib_core` | `spikenaut-core-sv/rtl` | `LifNeuron`, `LifNeuronArray`, `WeightRam`, `NeuronParamRam`, `StdpController` |
| `lib_bridge` | `spikenaut-bridge-sv/rtl` | `UartRx`, `UartTx`, `SiliconBridge` |
| `lib_soc` | `spikenaut-soc-sv/rtl` | `SocProtocolFsm` application codec, `SocStatusLeds` LED/status mux, and Basys 3 SoC top (`spikenaut_soc_basys3_top`) |
| `lib_synapse` | `synapse-link-hdl/src` | `SynapseRouter`; demo top `synapse_demo_basys3_top` |

Single-source-of-truth rule: no module is defined in more than one place (enforced by the
Deduplication Guardian). SoC and demo wrappers **instantiate** core/bridge modules; they
do not redefine them.

### Maturity on `main` (F0 honesty)

This is the demo product as wired in `spikenaut_soc_basys3_top` today — not the
host `silicon-bridge` v3.0 16-neuron frame. Remaining product work lives under
finishing epic [#54](https://github.com/rmems/silicon-hdl/issues/54).

| Capability | On `main` | Tracker |
|------------|-----------|---------|
| Elaboration / bitstream `.mem` init | **Wired** — `INIT_FILE` `$readmemh` on `WeightRam` / `NeuronParamRam`; SoC defaults to `spikenaut-core-sv/mem/merged_v2_{weights,thresholds,decay}.mem`; `scripts/build_soc.tcl` overrides with absolute paths | [#51](https://github.com/rmems/silicon-hdl/issues/51) / [#52](https://github.com/rmems/silicon-hdl/issues/52) (E1/E2) |
| Runtime RAM write (UART / host rewrite) | **Off** — `we` tied low on all three SoC RAM instances | [#63](https://github.com/rmems/silicon-hdl/issues/63) |
| RAM address used by the PE | **Swept** — threshold/leak addresses walk `0..15`; the flattened weight address is `neuron_row * 16 + input_index`. #62 selects the lowest active decoded host lane, so the binary-event SoC path can walk any one input column across all 16 rows | [#61](https://github.com/rmems/silicon-hdl/issues/61) / [#62](https://github.com/rmems/silicon-hdl/issues/62) |
| Neuron count | **N=16** `LifNeuronArray` time-multiplexes one shared datapath across 16 neuron slots and commits a board-agnostic 16-bit `spike_bitmap`; `spikenaut_soc_basys3_top` maps that bitmap to `led[15:0]` in spike mode (SW15=0). SW15 selects the stretched status word. See [`docs/led-map.md`](led-map.md) | [#61](https://github.com/rmems/silicon-hdl/issues/61) / [#65](https://github.com/rmems/silicon-hdl/issues/65) |
| STDP | `StdpController` is instantiated (classical Bi–Poo, [#55](https://github.com/rmems/silicon-hdl/issues/55)) and gated by `step_en`, but **writeback is open**: `weight_we` / `weight_addr_out` / `weight_out` are unconnected; `weight_addr` is `'0` | [#70](https://github.com/rmems/silicon-hdl/issues/70) |
| Host UART protocol | **Implemented #62** — `SocProtocolFsm` consumes `0xAA` + 32 payload bytes, commits a 16-word big-endian stimulus frame, and holds it until `step_en`; it serializes 16 membrane words, spike flags, and aux state while respecting `tx_busy`. The present PE selects the lowest active binary stimulus lane; it does not yet accumulate multi-active vectors | [#62](https://github.com/rmems/silicon-hdl/issues/62) / [#64](https://github.com/rmems/silicon-hdl/issues/64) |
| Logical timestep | **1 ms** `step_en` (100_000 fabric cycles @ 100 MHz) | [#57](https://github.com/rmems/silicon-hdl/issues/57) / [#60](https://github.com/rmems/silicon-hdl/issues/60); [`docs/timestep-contract.md`](timestep-contract.md) |

---

## Owns

| Area | Detail |
|------|--------|
| SNN FPGA primitives | Canonical RTL for LIF, weight/param RAMs, on-chip STDP controller |
| On-chip host bridge RTL | UART RX/TX and `SiliconBridge` framing aligned with host `silicon-bridge` |
| AER routing primitive | `SynapseRouter` and its demo integration |
| Board integration tops | Thin Basys 3 tops only; pin/constraint ownership under `constraints/` |
| Vivado/Verilator flows | Scripts and CI hooks that build/sim **this** RTL tree |
| Vivado report **gate** in this repo | `scripts/check_wns.py` + `.github/workflows/vivado-ci.yml` fail the optional self-hosted job when WNS/WHS &lt; 0 |
| Module ownership map | README table + guardian; renames stay unique across the monorepo |
| Hardware interface contracts | Bit widths, reset polarity, RAM layouts, UART byte stream, and the SoC-owned `0xAA` / response-frame codec as implemented in RTL |

---

## Does not own

| Area | Owner |
|------|--------|
| Software LIF / HH / other neuron dynamics | `neuromod` |
| Continuous→spike encoding | `axon-encoder` |
| MoE / weight extraction from ANN stacks | `engram-parser` |
| Online / offline training loops | `plasticity-lab` |
| Reward / risk modulators and `Environment` | `limbic-critic` |
| Process orchestration / daemon lifecycle | `brainstem-daemon` |
| Host Q8.8 encode, `.mem` writers, host UART client | **`silicon-bridge`** |
| Host-side Vivado **metrics aggregation** (e.g. library parse of timing reports for tooling) | **`silicon-bridge`** (`FpgaMetrics` and similar) — **not** this repo’s CI gate (`scripts/check_wns.py` stays in silicon-hdl) |
| Domain adapters (trading PnL, mining telemetry, exchange feeds) | App / adapter repos — never this monorepo |
| Full software SNN simulator | Out of scope |
| NIR / HDF5 graph I/O | Shared IR crate (`nir-rs` if/when) — not reimplemented in HDL |
| Repo consolidation of Rust + HDL into one tree | Explicit non-goal of LIM-9 / #3 |

---

## Allowed dependencies

`silicon-hdl` is an HDL monorepo. “Dependencies” here mean **inputs it may consume** and
**tools it may rely on** — not Cargo crates.

| Dependency / input | Why | Status today |
|--------------------|-----|--------------|
| Parameter `.mem` / hex images from `silicon-bridge` (in-tree copies under `spikenaut-core-sv/mem/`) | Elaboration / bitstream init via `$readmemh`; runtime UART rewrite later | **INIT_FILE wired** (E1/E2). RAMs load when `INIT_FILE` is non-empty and not `"NONE"`; `LifNeuronArray` sweeps threshold/leak `0..15` and weight rows `0, 16, …, 240` for the current input column. SoC `we` remains low: UART/write-port load is **not** on `main` ([#63](https://github.com/rmems/silicon-hdl/issues/63)) |
| UART traffic from host `silicon-bridge` (or compatible clients) | Physical UART byte pipe via `SiliconBridge`; `SocProtocolFsm` application codec | **0xAA protocol implemented**: 16 Q8.8 words decode atomically and a 36-byte potential/spike/aux response is serialized with `tx_busy` back-pressure safety. Runtime parameter/weight writes remain #63; host-board E2E remains #64 |
| Xilinx Vivado (optional) | Synthesis, implementation, bitstream for Basys 3 | Available on self-hosted path |
| Verilator | Free-stack unit simulation of core testbenches | Required free CI path |
| Board constraints (`constraints/*.xdc`) | Pinout and timing for target FPGAs | Present |
| Documented interface contracts from `silicon-bridge` | Keep host export formats and RTL layouts aligned as load/protocol paths land | Contract docs; integration still incomplete |

Internal (within this monorepo only):

| Edge | Rule |
|------|------|
| `lib_soc` → `lib_core`, `lib_bridge` | Allowed — tops instantiate canonical modules |
| `lib_synapse` demo → `lib_bridge` / routing sources | Allowed for demo wiring only |
| `lib_core` → `lib_soc` / app logic | **Forbidden** — core stays free of board/app code |
| Duplicate `module Name` in a second tree | **Forbidden** — Deduplication Guardian fails the change |

---

## Forbidden dependencies / content

- Rust runtime crates as **owned** code inside this repo (`neuromod`, `limbic-critic`,
  `brainstem-daemon`, host logic from `silicon-bridge`)
- Domain-product logic (trading, mining, HFT adapters) in RTL, tops, or scripts
- Copying or forking core/bridge modules into `spikenaut-soc-sv` or
  `synapse-link-hdl/examples` wrappers
- Absorbing host-side Q8.8 conversion or `.mem` generation (those stay in `silicon-bridge`).
  Host-side metrics aggregation may live in `silicon-bridge`; the **CI timing gate**
  (`scripts/check_wns.py`) stays in this repo
- Secrets, machine-local absolute paths, or licensed IP blobs committed without review
- Collapsing this monorepo into a vague “catch-all hardware + software” ownership model
- Weakening the Deduplication Guardian without an explicit project decision

---

## Core-library vs supervisor/app vs deployment/hardware

| Layer | Responsibility | Example repos / trees |
|-------|----------------|------------------------|
| **Core library (software)** | Neuron dynamics, network step, generic modulators, plasticity primitives | `neuromod` |
| **Core library (hardware)** | Parameterized SNN + bridge **RTL modules** with single ownership | `lib_core`, `lib_bridge` **inside silicon-hdl** |
| **Supervisor / app** | Daemon loop, IPC, service registry, environment adapters | `brainstem-daemon`, app crates |
| **Deployment (host)** | Fixed-point export, host UART client, optional host metrics parse | `silicon-bridge` |
| **Hardware CI (this repo)** | Optional self-hosted Vivado synth + **WNS/WHS gate** (`check_wns.py`) | `silicon-hdl` |
| **Deployment / hardware** | Bitstream, board tops, constraints, FPGA-facing contracts | **`silicon-hdl`** (this repo) |

Clarifications:

- **Hardware “core” ≠ software “core”.** `lib_core` here is RTL; it is not a substitute for
  `neuromod` and must not grow software training or reward semantics.
- **Tops are deployment surfaces**, not places to invent parallel neuron implementations.
- **Supervisor/app** never lives in SystemVerilog in this monorepo; orchestration stays in Rust.

---

## Boundaries vs sibling repos

### vs `neuromod`

- **neuromod:** software dynamics and shared trait contracts.
- **silicon-hdl:** hardware approximation / implementation of neuron and memory structures
  suitable for FPGA.
- Do not port full neuromod model surface into RTL by default; keep HDL primitives small and
  explicit. Behavioral parity (if required) is a cross-repo contract, not a reason to merge
  repos.

### vs `limbic-critic`

- **limbic-critic:** reward shaping → modulator vectors.
- **silicon-hdl:** does not interpret reward. Any on-chip use of modulators would arrive as
  numeric parameters or host-written registers via the bridge — not as critic logic in RTL.

### vs `brainstem-daemon`

- **brainstem-daemon:** long-running host inference process.
- **silicon-hdl:** FPGA fabric. The daemon may *use* spikes or parameters that eventually
  reach the board through `silicon-bridge`; it does not own pinouts, bitstreams, or RTL.

### vs `silicon-bridge`

- **silicon-bridge:** host-side deployment bridge (Q8.8, `.mem` writers, UART client,
  optional host-side Vivado metrics aggregation such as `FpgaMetrics`).
- **silicon-hdl:** single source of truth for the RTL those formats target, **and** the
  in-repo Vivado timing gate (`scripts/check_wns.py` / `vivado-ci.yml`). Do not move that
  gate into silicon-bridge.
- Widths, RAM layouts, reset polarity, and UART **byte** framing are **coordinated** across both
  repos; RTL changes land only here; host format changes land only in `silicon-bridge`.
- Today’s Basys 3 SoC demo **does** load Q8.8 `.mem` images at elaboration / bitstream
  init (`INIT_FILE` / `$readmemh`) and implements the #62 host frame/readback codec.
  RAM `we` remains tied off, the N=16 PE performs its swept read addresses, and STDP
  writeback remains unconnected. Treat runtime UART configuration and host-board E2E
  as sequenced work under [#54](https://github.com/rmems/silicon-hdl/issues/54), not as
  a claim that writes or multi-active-lane accumulation are complete.

### vs legacy `Spikenaut-Hardware`

- Historical name / repo for the hardware layer in LIM-9 tracking links.
- New planning and implementation references should point at **`silicon-hdl`**.
- Do not re-open parallel ownership of the same modules under both names.

---

## Domain leaks, migration risks, and sequencing questions

### Domain leaks

| Leak | Notes |
|------|--------|
| “Spikenaut-Hardware” vs `silicon-hdl` naming | Sibling matrices and LIM-9 still mix names; standardize on `silicon-hdl` |
| Board-specific logic in `lib_core` | Core modules must stay board-agnostic; pin and clock policy stay in tops / XDC |
| Host protocol drift | UART / RAM contracts duplicated informally across repos without a shared doc |
| Demo tops becoming “second cores” | Demo may wire modules but must not redefine `LifNeuron` / UART / STDP |
| Domain telemetry in RTL | Mining/trading counters or tickers must not appear in primitives or tops |

### Migration risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Host `.mem` / Q8.8 mismatch with `WeightRam` / `NeuronParamRam` | High | Cross-link silicon-bridge export traits with explicit width/layout notes; test with known vectors |
| UART frame skew between `SiliconBridge` RTL and host client | High | Treat frame layout as a versioned contract; change both repos in sequenced PRs |
| Duplicate module definitions after copy-paste “forks” | High | Deduplication Guardian on every PR; intentional forks need radar + PR note |
| Two Basys 3 tops confused as one module | Medium | Distinct module names (`spikenaut_soc_basys3_top` vs `synapse_demo_basys3_top`) — keep them |
| Assuming Vivado everywhere | Medium | Prefer Verilator for iteration; Vivado remains optional / self-hosted |
| Repo consolidation pressure | Medium | LIM-9 non-goal: keep hardware monorepo separate from Rust runtimes |

### Sequencing questions

1. Where should the **authoritative width / RAM / UART frame** contract live — a short
   interface doc in `silicon-hdl`, export traits in `silicon-bridge`, or both with a
   parity checklist?
2. Should on-chip STDP (`StdpController`) remain the only plasticity path in RTL, with
   software STDP (`neuromod` / training crates) staying host-side only?
3. What is the minimum **bit-accurate or cycle-approximate** parity expected between
   `neuromod` LIF and `LifNeuron` for release gates?
4. Is Basys 3 the sole near-term board target, or should board packs be split before a
   second FPGA lands?
5. How should LIM-9 trackers that still say **Spikenaut-Hardware #3** be redirected so
   readers land on this file and silicon-hdl #3?

**Suggested sequence (planning only):**

1. Landed: this boundary matrix, [`docs/interface-alignment.md`](interface-alignment.md),
   and SoC `INIT_FILE` `$readmemh` (E1/E2).
2. Implemented under [#54](https://github.com/rmems/silicon-hdl/issues/54): #62's
   16-word protocol parser, deterministic single input-column selector, and TX response.
   Remaining work is runtime RAM write ([#63](https://github.com/rmems/silicon-hdl/issues/63)), host E2E
   ([#64](https://github.com/rmems/silicon-hdl/issues/64)), and STDP time-mux/writeback
   ([#70](https://github.com/rmems/silicon-hdl/issues/70)).
3. Add or extend cross-repo golden vectors (float → Q8.8 → `.mem` → RTL readback) without
   merging repositories.
4. Only then consider new board tops or extra on-chip features.

---

## Related tracking

| Tracker | Role |
|---------|------|
| [LIM-9](https://linear.app/rpd-34/issue/LIM-9/plan-rust-runtime-and-deployment-repo-boundary-matrix) | Org-wide Rust runtime / deployment boundary matrix |
| [silicon-hdl #3](https://github.com/rmems/silicon-hdl/issues/3) | This repo’s Spikenaut-Hardware / silicon-hdl planning issue |
| [silicon-hdl #54](https://github.com/rmems/silicon-hdl/issues/54) | Finishing epic: 16-neuron host E2E on Basys 3 |
| [silicon-hdl #56](https://github.com/rmems/silicon-hdl/issues/56) | F0 docs honesty: this file + interface-alignment vs `main` |
| [silicon-bridge #3](https://github.com/Limen-Neural/silicon-bridge/issues/3) | Host bridge boundary matrix (`docs/boundary-matrix.md`) |
| [neuromod #11](https://github.com/Limen-Neural/neuromod/issues/11) | Core library boundary matrix |
| [limbic-critic #4](https://github.com/Limen-Neural/limbic-critic/issues/4) | Critic boundary matrix |
| [brainstem-daemon #4](https://github.com/Limen-Neural/brainstem-daemon/issues/4) | Runtime daemon boundary notes |
| [Spikenaut-Hardware #3](https://github.com/Limen-Neural/Spikenaut-Hardware/issues/3) | Legacy LIM-9 hardware link (prefer silicon-hdl) |

Sibling boundary docs (for consistency when updating cross-links):

- `neuromod`: `docs/neuromod-boundary-matrix.md`
- `limbic-critic`: `docs/BOUNDARY_MATRIX.md`
- `silicon-bridge`: `docs/boundary-matrix.md`
- `brainstem-daemon`: README “Role and boundary matrix” section

---

## Validation (planning coverage)

This section records **what this document covers** for issue #3 / LIM-9. It is **not** a
task board — track work in GitHub issues or beads (`bd`), not markdown checkboxes.

Covered here in prose:

1. **Purpose** — Spikenaut-Hardware / silicon-hdl FPGA SNN RTL role is stated above.
2. **Owns / does-not-own** — tables under those headings.
3. **Allowed and forbidden dependencies** — including honest “status today” for `.mem` (`INIT_FILE` wired; runtime write still off) and UART (RX event only; TX off).
4. **Layer boundaries** — core software vs supervisor/app vs deployment host vs hardware RTL.
5. **Domain leaks, migration risks, sequencing** — dedicated sections above.
6. **LIM-9 linkability** — this file path (`docs/boundary-matrix.md`) plus the Related tracking table.
7. **Planning-only** — this PR deliverable does not change RTL, CI workflows, or consolidate repos.

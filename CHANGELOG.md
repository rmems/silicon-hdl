<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# Changelog

All notable changes to silicon-hdl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Dual MIT / Apache-2.0 licensing for maximum adoption in research and commercial hardware (addresses #6).
  - `LICENSE-MIT` and `LICENSE-APACHE-2.0` added at repository root.
  - SPDX-License-Identifier headers (`MIT OR Apache-2.0`) added to all `.sv`, `.tcl`, `.xdc`, and documentation sources.
  - README updated with license badge and standard dual-license section.
  - CHANGELOG introduced.
- Verilator CI for core RTL unit testbenches on GitHub-hosted runners (addresses #9).
  - `.github/workflows/sim.yml` created; runs `tb_LifNeuron`, `tb_WeightRam`, and `tb_NeuronParamRam` via Verilator on `push` (to `main`) and `pull_request`.
  - Uses explicit steps for the three testbenches; `rm -rf obj_dir` isolation + exact flags from issue notes (validated locally and matches PR #11 `$fatal` hardening).
  - Free CI (no Vivado license). Out-of-scope items tracked in #12 and #13.
- Deduplication Guardian (addresses #5).
  - `scripts/dedup_guardian.py` + `.github/workflows/dedup-guardian.yml` enforce the canonical single-source-of-truth on every PR.
  - Strict duplicate detection for all registered modules + near-duplicate "Dupe Radar" with diffs + Purity Score.
  - Fails the check on violations; posts beautiful radar comment on PRs.
- Release process doc: [`docs/releases.md`](docs/releases.md) — SemVer tags + GitHub Releases under `rmems` (see also #69 for v0.1.0).
- Logical timestep ADR: [`docs/timestep-contract.md`](docs/timestep-contract.md) — 1 ms SoC `step_en` (#57).
- SoC-level testbench `tb_spikenaut_soc_basys3_top` (`spikenaut-soc-sv/tb/tb_Basys3_Top.sv`) —
  direct simulation of the 1 ms `step_en` divider (reset phase, one-cycle pulse width, exact
  100_000-cycle period on every tick) and of the UART-event → tick-domain handoff (#60).
  Wired into `scripts/quality.sh`, `.github/workflows/sim.yml`, and `scripts/sim_core.tcl`.
- Bridge unit testbenches `tb_UartRx`, `tb_UartTx`, and `tb_SiliconBridge` (#58) — 2FF
  sync, baud-timed 8N1, and `tx_busy` handshake. Wired into `scripts/quality.sh`,
  `.github/workflows/sim.yml`, and `scripts/sim_core.tcl`.
- SoC application protocol FSM (#62) — canonical `SocProtocolFsm` decodes the
  `0xAA` + 16-word big-endian host frame, holds a completed stimulus frame for
  the next logical tick, and emits the 36-byte potential/spike/aux response
  with `tx_busy`-safe serialization. Incomplete RX frames abort after an
  inter-byte idle timeout (not mid-payload `0xAA` resync). `tb_SocProtocolFsm`
  covers decode, byte order, busy stalls, latest-wins pending snapshots, and
  RX idle-timeout recovery; the N=16 PE now exposes packed membrane readback.
- LED / status map (#65) — [`docs/led-map.md`](docs/led-map.md), combinational
  `SocStatusLeds` mux (SW15 after 2FF), FSM status outputs (`rx_busy`,
  `rx_abort`, `tx_frame_active`), and SoC-only `constraints/basys3_soc.xdc`.
- First testbench for `lib_synapse`: `tb_SynapseRouter` (`synapse-link-hdl/tb/`). The library had
  no tests and no runner references at all, so `SynapseRouter` and `synapse_demo_basys3_top` were
  never elaborated by CI. Covers one-clock latency, ordering across back-to-back beats, the
  unconditional address path, full-width addresses, and asynchronous reset. Wired into
  `scripts/quality.sh`, `scripts/sim_core.tcl` and `.github/workflows/sim.yml`.
- `synapse_demo_basys3_top` is now elaborated by `scripts/quality.sh` and
  `.github/workflows/sim.yml` (`verilator --lint-only`). It has no testbench, so nothing else
  compiled it — it was the only synthesizable top in the repo that CI never touched.
- Testbench coverage drift guard: [`scripts/check_tb_coverage.py`](scripts/check_tb_coverage.py)
  reconciles the testbench lists in `scripts/quality.sh`, `scripts/sim_core.tcl` and
  `.github/workflows/sim.yml` against the testbenches on disk, and runs first in both
  `quality.sh` and CI so drift fails fast.

### Changed

- `LifNeuron` and `StdpController` update only when `step_en` is high; SoC pulses it at 1 kHz (#60).
- `UartRx`'s `rx_sync_0`/`rx_sync_1` clock-domain-crossing pair now carries
  `(* ASYNC_REG = "TRUE" *)` (#84), so synthesis packs it into adjacent slices and will
  not replicate or retime the flops. Every 2FF synchronizer in the repo now declares it;
  the `sw` pair got the same treatment in #83.
- Vivado CI runs on `push` to `main` (self-hosted) as well as same-repository PRs / dispatch.
- Post-transfer hygiene: live docs and issue links point at
  [`rmems/silicon-hdl`](https://github.com/rmems/silicon-hdl) after return from Limen-Neural (#75).
- `StdpController` LTP/LTD polarity matches classical causal STDP (Bi–Poo): pre-then-post
  potentiates, post-then-pre depresses (#55). `tb_StdpController` updated to lock the policy.
- `spikenaut_soc_basys3_top` drives `led` from `SocStatusLeds` and publishes
  synchronized `sw` as response bytes 34–35 (`aux_state`). Default SW15=0 keeps
  the N=16 spike-bitmap view from #81.

### Fixed

- `scripts/quality.sh` was silently skipping `tb_WeightRam_init` and `tb_NeuronParamRam_init`
  while `scripts/sim_core.tcl` and `.github/workflows/sim.yml` both ran them. Those are the only
  two testbenches that exercise `$readmemh` against the merged_v2 memory images, so a broken
  image passed the documented local gate and failed only in CI. The local gate now runs 15
  checks, not 12.

- STDP polarity inversion vs Bi–Poo / Song–Miller–Abbott convention (#55).
- SoC protocol snapshot capture stays inline NBA in `always_ff` (Verilator and
  XSim reject `task automatic ... ref` from sequential logic). `frame_send` is
  armed only after a consumed host `0xAA` frame, not on every 1 ms `tick_done`
  (#62).

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

### Changed

- `LifNeuron` and `StdpController` update only when `step_en` is high; SoC pulses it at 1 kHz (#60).
- Vivado CI runs on `push` to `main` (self-hosted) as well as same-repository PRs / dispatch.
- Post-transfer hygiene: live docs and issue links point at
  [`rmems/silicon-hdl`](https://github.com/rmems/silicon-hdl) after return from Limen-Neural (#75).
- `StdpController` LTP/LTD polarity matches classical causal STDP (Bi–Poo): pre-then-post
  potentiates, post-then-pre depresses (#55). `tb_StdpController` updated to lock the policy.

### Fixed

- STDP polarity inversion vs Bi–Poo / Song–Miller–Abbott convention (#55).
- SoC protocol snapshot capture stays inline NBA in `always_ff` (Verilator and
  XSim reject `task automatic ... ref` from sequential logic). `frame_send` is
  armed only after a consumed host `0xAA` frame, not on every 1 ms `tick_done`
  (#62).

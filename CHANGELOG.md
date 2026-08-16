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

### Changed

- `LifNeuron` and `StdpController` update only when `step_en` is high; SoC pulses it at 1 kHz (#60).
- Vivado CI runs on `push` to `main` (self-hosted) as well as same-repository PRs / dispatch.
- Post-transfer hygiene: live docs and issue links point at
  [`rmems/silicon-hdl`](https://github.com/rmems/silicon-hdl) after return from Limen-Neural (#75).
- `StdpController` LTP/LTD polarity matches classical causal STDP (Bi–Poo): pre-then-post
  potentiates, post-then-pre depresses (#55). `tb_StdpController` updated to lock the policy.

### Fixed

- STDP polarity inversion vs Bi–Poo / Song–Miller–Abbott convention (#55).

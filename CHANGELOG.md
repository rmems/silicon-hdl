<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# Changelog

All notable changes to silicon-hdl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- README maturity table for what actually works on `main` (addresses #67): core
  primitives, Basys SoC demo, STDP, host UART protocol, output-class LEDs
  (`status_word[15:13]`), and `.mem` INIT banks, each with works / partial / not
  wired plus evidence PRs. Explicit non-goals: Stage-1 axons 5–15, STDP
  writeback on the demo path, FPGA↔Julia spike/action parity, extending
  `FRAME_BYTES`, inventing weights. Live bank pin: Spikenaut-SNN#47 / exp-025.

### Changed

- `AGENTS.md` no longer asserts that branch protection on `main` guards the
  self-hosted Vivado CI `push` path. Re-measured 2026-09-14: `main` is
  `protected: false` with no rulesets; a direct push still runs repo scripts on
  the Vivado workstation with no review gate. Recommended follow-ups are listed
  but not claimed as enabled (addresses #87).

- `docs/interface-alignment.md` now records the host-side `.mem` encoder as **signed**
  two's-complement Q8.8. silicon-bridge
  [#60](https://github.com/rmems/silicon-bridge/pull/60) (`e201514`) made
  `FpgaParameterExporter`'s `FixedPointEncode::encode_q88` return `encode_q88_signed`, so
  the §1.3.1 "host-encoder compatibility gap" opened by #73 is closed upstream.
  §1.1, §1.2, §1.3, §1.4, the §3 compatibility table, and the §5 findings table were
  corrected (including `FpgaParameters` fields, which are `Vec<i16>`), and §1.3.1 was
  rewritten from an open mismatch into the resolved history with an explicit *Correction:*
  note. The #73/#91 entries below are left as written — they describe what was true at the
  time. The `spikenaut_soc_basys3_top` sign-bit-set threshold/leak write guard stays: it
  defends against any host, not only an out-of-date encoder. Matches the corrections already
  made to `scripts/q88.py` and `docs/host-soc-e2e.md` in
  [#96](https://github.com/rmems/silicon-hdl/pull/96).

### Fixed

- Signed Dale E/I (inhibitory) path for `LifNeuron` / `LifNeuronArray` (addresses #73).
  - `weight` and `membrane_potential` are now read as signed two's-complement Q8.8 instead of
    unsigned, so an inhibitory weight (e.g. `0xFF00` = `-1.0`) subtracts from the membrane instead
    of misreading as a large positive integer and looking excitatory.
  - Leak now decays the membrane symmetrically toward the 0 resting potential from either side
    (a negative/inhibited membrane recovers upward, clamped at 0) instead of only draining a
    positive one; integration saturates at the signed Q8.8 extremes (`16'h7FFF` / `16'h8000`)
    instead of wrapping.
  - `tb_LifNeuron`, `tb_LifNeuronArray`, and `tb_spikenaut_soc_basys3_top` gained mixed-sign
    coverage proving no false spikes from inhibitory rows under the old unsigned misread.
  - `spikenaut-core-sv/mem/README.md` documents the signed Q8.8 contract for every `.mem` image
    and the host runtime-write path.
  - `spikenaut_soc_basys3_top` now rejects a sign-bit-set threshold write instead of storing it:
    since the threshold compare is signed, a negative threshold would make an idle neuron spike
    continuously (relevant while the host-side `FixedPointEncode` encoder is still unsigned-only,
    see `docs/interface-alignment.md` §1.3.1). Weight writes are exempt — a negative weight is the
    intended inhibitory case.

### Added

- Golden SiliconBridge v3.0 UART frame vectors and a host ↔ SoC E2E runbook (addresses #64).
  - `spikenaut-core-sv/mem/golden/frame_golden_*.mem` are generated 33-byte request / 36-byte
    response byte streams that pin the wire framing this repo shares with the
    [`rmems/silicon-bridge`](https://github.com/rmems/silicon-bridge) host crate: byte count,
    big-endian word order, lane 0 first, bit `i` = neuron `i`, and signed Q8.8. `exp-025` cases
    decode words already committed under `spikenaut-core-sv/mem/`; synthetic cases are tagged and
    reach framing edges the bank cannot express.
  - New `tb_SocFrameGolden` replays every golden pair through the real `SocProtocolFsm` in both
    directions, idle and under bridge back-pressure, and fails if a 37th response byte appears —
    one stray byte would desynchronize every later host `read_exact(36)` permanently.
  - `tb_spikenaut_soc_basys3_top` gained tests 13a/13b: 13b demodulates the real `uart_tx` line
    and checks the assembled `SocProtocolFsm` → `SiliconBridge` → `UartTx` chain delivers exactly
    36 bytes, with expectations sampled from the top-level `membrane_potentials` / `spike_bitmap` /
    `sw_sync_1` nets rather than the serializer's own snapshot registers. 13a compares
    `status_word[15:13]` against the live `OutputLayer.result` by value — test 9 could only mirror
    it against the hold register that drives it.
  - `scripts/gen_golden_frame_vectors.py --check` is a drift gate wired into `scripts/quality.sh`,
    `.github/workflows/sim.yml`, and `tests/test_golden_frame_vectors.py`.
  - `tests/test_golden_frame_vectors.py` runs a model of the crate's `process_stimuli` against the
    committed bytes and asserts that wrong decodes (unsigned, little-endian, reversed lanes,
    reversed spike bits) disagree — so a framing change made here fails here, not on a board.
  - #72's output-class flags stay LED-only (`status_word[15:13]`); both frame lengths are
    unchanged and are now asserted at elaboration and in the Python suite.
  - `scripts/q88.py` gained byte-stream `.mem` I/O (`read_bytes` / `write_bytes` /
    `q88_to_be_bytes` / `q88_from_be_bytes`); it remains the single Q8.8 codec.
  - New [`docs/host-soc-e2e.md`](docs/host-soc-e2e.md): frame layout, case table, simulation-only
    and board-in-loop runbooks, and a troubleshooting table.

- Golden f32 → Q8.8 → `.mem` → Verilator LIF vectors (addresses #66).
  - `spikenaut-core-sv/mem/golden/` holds generated stimulus and expected traces derived from
    the pinned exp-025 Dale bank (Spikenaut-SNN#47 @ `6965e12a`) — no weight is authored by
    hand, and the generator asserts the f32 round trip returns the identical bank word.
  - New `tb_LifNeuron_golden` and `tb_OutputLayer_golden` replay those traces tick-for-tick
    against the real signed `LifNeuron` datapath and the #72 `OutputLayer` argmax path.
  - `scripts/gen_golden_lif_vectors.py --check` is a drift gate wired into `scripts/quality.sh`,
    `.github/workflows/sim.yml`, and `tests/test_golden_lif_vectors.py`: committed vectors that
    no longer regenerate byte-identically fail CI.
  - `tests/test_golden_lif_vectors.py` additionally replays the vectors through deliberately
    wrong LIF variants (unsigned misread, one-sided leak, wrapping instead of saturating) and
    fails if any of them reproduces the golden trace — so the vectors are shown to discriminate
    the signed path, not merely to be reproducible.
  - `scripts/q88.py` is the single signed Q8.8 codec, mirroring silicon-bridge's
    `encode_q88_signed` (whose own test vectors are re-asserted against it). silicon-bridge's
    `MemFileWriter` was not reused: it encodes through the *unsigned* `encode_q88`, which clamps
    negatives to `0` and cannot express a Dale-I word. See
    [`docs/golden-lif-vectors.md`](docs/golden-lif-vectors.md).

- Signed output-layer weights wired into the SoC (addresses #72).
  - New `OutputLayer` (`spikenaut-core-sv/rtl/OutputLayer.sv`) reduces one tick's
    `spike_bitmap` into 3 signed Q8.8 class scores against
    `merged_v2_output_weights.mem` (row-major, `addr = neuron*3 + class`) and reports the
    argmax as a one-hot result — the bank is no longer vendored-only.
  - Accumulation reuses `LifNeuron`'s guard-bit saturating idiom at every one of the 48
    steps, so a negative (Dale-inhibitory) output weight subtracts instead of misreading
    as a large positive value, and 16 summed terms saturate at the signed Q8.8 extremes
    instead of wrapping.
  - Triggered from `LifNeuronArray.tick_done`, not `step_en`: `spike_bitmap` only updates
    on `tick_done`, so a `step_en` trigger would have scored the previous tick's spikes.
  - A second `WeightRam` instance (`u_output_wram`, `ADDR_WIDTH=6`) loads the bank via
    `OUTPUT_WEIGHT_INIT_FILE`; no runtime write path (`INIT_FILE` is the only load path).
  - Surfaced on LEDs only — `SocStatusLeds` `status_word[15:13]` (previously reserved/0)
    now carries the stretched argmax. The 36-byte UART response frame is deliberately
    unchanged (see #64).
  - New `tb_OutputLayer` proves real-bank `$readmemh` loading, signed subtraction of a
    negative weight, a real shipped-bank row cross-check, and both saturation directions.
    `tb_SocStatusLeds` and `tb_spikenaut_soc_basys3_top` updated for the new bits.
    Wired into `scripts/sim_core.tcl`, `.github/workflows/sim.yml`, and `scripts/build_soc.tcl`.
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
- Runtime weight/param RAM write (#63) — `SocProtocolFsm` decodes a 5-byte
  `0xA5` + target + addr + Q8.8 frame and pulses `wr_en` onto `WeightRam` and
  both `NeuronParamRam` instances. Writes that land during a PE sweep are held
  until idle. `INIT_FILE` cold-start is unchanged; the PE keeps the read
  address when idle. STDP writeback stays open (#70).
  `tb_SocProtocolFsm` and `tb_spikenaut_soc_basys3_top` prove a host overwrite
  and that `we` is not hard-tied 0.

### Changed

- `LifNeuron` and `StdpController` update only when `step_en` is high; SoC pulses it at 1 kHz (#60).
- [`docs/resource-budget-n16.md`](docs/resource-budget-n16.md) refreshed against a real routed
  build: 892 LUTs / 1660 FFs / 1.5 BRAM tiles / 0 DSPs / 36 IOBs, WNS +1.230 ns, WHS +0.106 ns,
  zero failing endpoints. The prior figures were the #61 snapshot and understated LUTs by 3.2x
  after #62 and #65 landed. `scripts/build_soc.tcl` now also emits `utilization_hier.rpt`,
  which attributes the total per module: `SocProtocolFsm` is ~61% of LUTs and ~68% of
  flip-flops (it holds both an active and a pending 16-word response snapshot), while
  `SocStatusLeds` costs only 49 LUTs / 55 FFs.
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

- STDP polarity inversion vs Bi–Poo / Song–Miller–Abbott convention (#55).
- SoC protocol snapshot capture stays inline NBA in `always_ff` (Verilator and
  XSim reject `task automatic ... ref` from sequential logic). `frame_send` is
  armed only after a consumed host `0xAA` frame, not on every 1 ms `tick_done`
  (#62).

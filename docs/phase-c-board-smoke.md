<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-07-22 -->
# Phase C: optional board-in-loop smoke (self-hosted only)

Design stub for **Phase C** of the quality checkup epic. This document is intentional
skeleton only — it does **not** implement hardware CI automation.

| Item | Link |
| --- | --- |
| Tracking issue | [rmems/silicon-hdl#32](https://github.com/rmems/silicon-hdl/issues/32) |
| Parent epic | [rmems/silicon-hdl#23](https://github.com/rmems/silicon-hdl/issues/23) |
| Phase B dependency | [rmems/silicon-hdl#31](https://github.com/rmems/silicon-hdl/pull/31) (optional self-hosted Vivado CI) |

## Goals

- Optional smoke that programs a **Basys 3** from a known-good SoC bitstream and checks a
  minimal live response (LED and/or UART).
- Run only on a **self-hosted** host with board attached.
- Stay out of the free-stack quality path (`./scripts/quality.sh`, Verilator, guardian).

## Non-goals

- **Never** required on free `ubuntu-latest` GitHub Actions runners.
- **Never** block pull requests when hardware is offline or absent.
- Full regression suites, multi-board farms, or production flash pipelines.
- Rework of Phase B `.github/workflows/vivado-ci.yml` as a prerequisite for this stub.

## Prerequisites

| Prerequisite | Notes |
| --- | --- |
| Basys 3 | Artix-7 `xc7a35tcpg236-1` |
| Cable | USB JTAG (+ UART if UART smoke is enabled) |
| Programmer | `openFPGALoader` **or** Vivado `hw_server` / hardware manager |
| Bitstream | From `scripts/build_soc.tcl` (Phase B artifact or on-host rebuild) |
| Runner labels | e.g. `self-hosted` plus a board label (`basys3` / `board` — TBD); align with #31 runner setup |

## Suggested approach (future work)

1. **Label-gated workflow** (name TBD, e.g. `board-smoke`):
   - Triggers: `workflow_dispatch` and/or PR label (same pattern as `vivado-ci` in Phase B).
   - Runner: self-hosted only; not listed as a required check for free runners.
2. **Obtain bitstream**:
   - Prefer artifact from a successful Phase B `build_soc` job, or rebuild with
     `vivado -mode batch -source scripts/build_soc.tcl` on the board-capable host.
3. **Program**:
   - `openFPGALoader` with the Basys 3 cable/profile, **or**
   - Vivado hardware manager / `hw_server` Tcl program sequence.
4. **Minimal smoke** (pick the smallest observable pass/fail):
   - LED: known pattern or static pin state after configuration.
   - UART: optional byte exchange through the SiliconBridge path if cabling is present.
5. **Failure policy**:
   - Job fails only when board smoke was **explicitly requested** and the host was expected
     online; document skip/disable when the board is disconnected.

## Out of scope for this skeleton PR

- No new workflow YAML.
- No programming scripts beyond what already exists for manual use.
- No change to free-runner CI required checks.

## Open questions

- Prefer `openFPGALoader` vs Vivado `hw_server` as the default programmer on the self-hosted host?
- Exact runner label name for board-capable machines?
- UART smoke baud / protocol byte sequence once SiliconBridge demo path is fixed for lab use?
- Artifact retention and path for `.bit` from Phase B jobs?

## References

- Epic #23 — Quality checkup stack (phased A→B→C)
- Phase C tracking #32
- Phase B PR #31 — optional Vivado CI on self-hosted runner
- `scripts/build_soc.tcl` — SoC synth/implement/bitstream for Basys 3
- `AGENTS.md` — free-stack vs optional Vivado CI notes

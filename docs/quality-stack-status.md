<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-07-22 -->
# Quality stack status (Epic #23)

In-repo status artifact for the phased quality checkup stack on `silicon-hdl`.
Canonical tracking remains [Epic #23](https://github.com/rmems/silicon-hdl/issues/23).
This file records what landed on `main` so the epic body and local docs stay aligned.

## Goal

Raise automated quality **without** making Vivado a required free-runner PR gate.

## Phase summary

| Phase | Name | Status | Outcome |
| -- | -- | -- | -- |
| **A** | Free CI harden | **Complete** | Stronger Verilator + guardian + hygiene on `ubuntu-latest` |
| **B** | Vivado CI | **Complete** (B1/B2) | Self-hosted optional/label-gated synth+sim+artifacts ([#12](https://github.com/rmems/silicon-hdl/issues/12), [PR #31](https://github.com/rmems/silicon-hdl/pull/31)) |
| **C** | Board-in-loop | **Next** | Optional smoke on self-hosted only (never free GHA) |

## Phase A — Free CI harden (done)

| Item | Description | Issue | PR | Notes |
| -- | -- | -- | -- | -- |
| **A1** | Artifact hygiene (`.gitignore`) + `sim_core.tcl` Vivado 2026.1 fix | [#27](https://github.com/rmems/silicon-hdl/issues/27) | [#24](https://github.com/rmems/silicon-hdl/pull/24) | Merged |
| **A2** | `sim.yml`: add `tb_StdpController` | [#28](https://github.com/rmems/silicon-hdl/issues/28) | [#25](https://github.com/rmems/silicon-hdl/pull/25) | Merged — 4/4 core Verilator TBs in free CI |
| **A3** | `scripts/quality.sh` local free-stack entrypoint | [#29](https://github.com/rmems/silicon-hdl/issues/29) | [#26](https://github.com/rmems/silicon-hdl/pull/26) | Merged |
| **A4** | Coverage (`pytest-cov` for Deduplication Guardian) | [#21](https://github.com/rmems/silicon-hdl/issues/21) | [#30](https://github.com/rmems/silicon-hdl/pull/30) | Merged 2026-07-22 |

## Phase B — Vivado CI (done for B1/B2)

| Item | Description | Issue | PR | Notes |
| -- | -- | -- | -- | -- |
| **B1/B2** | Self-hosted optional Vivado CI workflow | [#12](https://github.com/rmems/silicon-hdl/issues/12) (CLOSED) | [#31](https://github.com/rmems/silicon-hdl/pull/31) (MERGED) | Commit `1aeee57` on `main`; workflow `.github/workflows/vivado-ci.yml` |
| **B3** | Docker Vivado (later) | [#13](https://github.com/rmems/silicon-hdl/issues/13) | — | Deferred; not required for Phase B closeout |

### How Phase B runs

- Workflow: [`.github/workflows/vivado-ci.yml`](../.github/workflows/vivado-ci.yml)
- Triggers: **Actions → Vivado CI → Run workflow**, or apply PR label **`vivado-ci`**
  (only the `labeled` event for that label)
- Runner labels: `self-hosted`, `vivado` (never a free `ubuntu-latest` required check)
- Local optional path: `./scripts/quality.sh --vivado` (requires Vivado env)

## Phase C — Board-in-loop (next)

- **Next** after Phase B: optional board program + minimal smoke on self-hosted only.
- Must **not** become a required free-runner gate.
- New child issue(s) for Phase C are tracked separately (not created by this closeout).

## Non-goals (unchanged)

- Required Vivado/Basys 3 for every free-runner PR
- Docker Vivado before #12 is stable (B3 remains later)
- Native SV coverage in Codecov/Codacy as a hard gate

## Success metrics (current)

| Metric | Status |
| -- | -- |
| Free PR CI still ~5–10 min | Target retained (Phase A on free runners only) |
| 4/4 core Verilator TBs in CI | Met (A2) |
| Zero Vivado artifact commits | Met (A1 hygiene) |
| Vivado path via label/dispatch on self-hosted | Met (B1/B2, #12, #31) |

## Related links

- Epic: [rmems/silicon-hdl#23](https://github.com/rmems/silicon-hdl/issues/23)
- Phase B issue: [rmems/silicon-hdl#12](https://github.com/rmems/silicon-hdl/issues/12)
- Phase B PR: [rmems/silicon-hdl#31](https://github.com/rmems/silicon-hdl/pull/31)
- Agent guidance: [`AGENTS.md`](../AGENTS.md) (build/test + optional Vivado CI notes)

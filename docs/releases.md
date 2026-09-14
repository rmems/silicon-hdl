<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-14 -->

# Releases and GitHub tags

How `silicon-hdl` versions are published under **[`rmems/silicon-hdl`](https://github.com/rmems/silicon-hdl)**.

## Rules

1. **SemVer** tags: `vMAJOR.MINOR.PATCH` (annotated tags preferred).
2. Every public release = **git tag on `main`** + **GitHub Release**
   (`gh release create vX.Y.Z --target main …`).
3. **`CHANGELOG.md`** is the human source of truth. When cutting a release, move items
   from `[Unreleased]` into a dated `## [x.y.z] - YYYY-MM-DD` section in the same
   change that creates the tag (or immediately before).
4. Tag only from **`main`** after free CI is green (Verilator + Deduplication Guardian).
   Self-hosted **Vivado CI** also runs on `push` to `main` and publishes
   `vivado-ci-reports` (synth/sim/WNS only; no board flash).
5. Free-runner CI does **not** auto-publish tags. Optional later: a notes-only workflow
   trigger on tag push (not required for v0.y.z), for example:

   ```yaml
   on:
     push:
       tags:
         - 'v*'
   ```

   or `workflow_dispatch` for manual release-note jobs. Do not use free CI to mint tags.
   Cloud agents and bots do **not** push release tags or run `gh release create`.
6. Pre-1.0: use `v0.y.z` for milestones. **`v0.2.0`** is the F0+F1+F2 demo-complete
   cut ([#69](https://github.com/rmems/silicon-hdl/issues/69) — annotated tag + GitHub
   Release required, not optional). Annotated git tag `v0.1.0` already exists on
   `306498d` (2026-08-21, after bridge unit TBs / before N=16) with **no** GitHub
   Release; do not treat `v0.1.0` as demo-complete.

## Cutting a release (checklist)

```bash
# 1. main is green; CHANGELOG has a version section for this cut
git checkout main && git pull --ff-only

# 2. Annotated tag (example)
git tag -a v0.2.0 -m "v0.2.0: F0+F1+F2 demo-complete (epic #54 / #69)"

# 3. Push tag and create GitHub Release
git push origin v0.2.0
gh release create v0.2.0 --target main --title "v0.2.0 — demo-complete F0+F1+F2" --notes-file - <<'EOF'
See CHANGELOG.md [0.2.0] for the honest demo-complete scope.
EOF
```

Or one shot with **GitHub-generated** release notes (`--generate-notes` summarizes
commits/PRs since the previous tag; it does **not** read `CHANGELOG.md`):

```bash
gh release create v0.2.0 --target main --generate-notes
```

Paste or attach the matching `CHANGELOG.md` `[0.2.0]` section separately when you want
that text as the release body. Prefer the changelog over `--generate-notes` for this
cut: the notes must keep STDP writeback, AER, FPGA↔Julia parity, Stage-1 axons, and
board UART sessions **out** of the demo-complete claim.

## After merging the #69 CHANGELOG PR (human: Raul)

Do this on `main` only, after free CI on the merge commit is green. Do **not** tag from
the docs branch.

```bash
git checkout main && git pull --ff-only
git log -1 --oneline   # merge commit of the #69 CHANGELOG PR; descendant of ba5d521

git tag -a v0.2.0 -m "v0.2.0: F0+F1+F2 demo-complete (epic #54 / #69)"
git push origin v0.2.0

gh release create v0.2.0 --target main \
  --title "v0.2.0 — demo-complete F0+F1+F2" \
  --notes-file - <<'EOF'
F0+F1+F2 demo-complete for epic https://github.com/rmems/silicon-hdl/issues/54.

Honest scope is in CHANGELOG.md [0.2.0]: signed Dale E/I LIF, output-class LEDs
(status_word[15:13], FRAME_BYTES stays 36), golden f32→Q8.8→Verilator, SiliconBridge
36-byte E2E, Phase C heartbeat smoke, README maturity table, signed .mem encoder.

Not claimed: STDP writeback (#70), AER (#71), FPGA↔Julia parity, Stage-1 axons,
inventing weights, UART host session on the board.

EOF
```

## What not to do

- Do not cut **`v0.2.0`** until the `#69` CHANGELOG section is on `main` and free CI
  (Verilator + Deduplication Guardian) is green on that merge. Parent epic:
  [#54](https://github.com/rmems/silicon-hdl/issues/54).
- Do not rewrite published release notes silently; ship a patch release if needed.
- Do not tag from feature branches.
- Do not auto-publish from free-runner CI or from a cloud agent.

## Wiki

GitHub wiki is **enabled** on `rmems/silicon-hdl`. Prefer in-repo `docs/` (including this
file) for durable process documentation; treat the wiki as optional narrative only.
Local personal shelf clones of the wiki are not part of the published process.

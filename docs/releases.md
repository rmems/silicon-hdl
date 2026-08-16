<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-08-15 -->

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
6. Pre-1.0: use `v0.y.z` for milestones. **`v0.1.0`** is reserved for F1 demo-complete
   ([#69](https://github.com/rmems/silicon-hdl/issues/69) — tag + GitHub Release required,
   not optional).

## Cutting a release (checklist)

```bash
# 1. main is green; CHANGELOG has a version section for this cut
git checkout main && git pull --ff-only

# 2. Annotated tag (example)
git tag -a v0.0.1 -m "v0.0.1: post-transfer hygiene and classical STDP"

# 3. Push tag and create GitHub Release
git push origin v0.0.1
gh release create v0.0.1 --target main --title "v0.0.1" --notes-file - <<'EOF'
See CHANGELOG.md for details.
EOF
```

Or one shot with **GitHub-generated** release notes (`--generate-notes` summarizes
commits/PRs since the previous tag; it does **not** read `CHANGELOG.md`):

```bash
gh release create v0.0.1 --target main --generate-notes
```

Paste or attach the matching `CHANGELOG.md` section separately when you want that text
as the release body.

## What not to do

- Do not cut **`v0.1.0`** until F1 demo path acceptance on epic
  [#54](https://github.com/rmems/silicon-hdl/issues/54) is met (#69).
- Do not rewrite published release notes silently; ship a patch release if needed.
- Do not tag from feature branches.

## Wiki

GitHub wiki is **enabled** on `rmems/silicon-hdl`. Prefer in-repo `docs/` (including this
file) for durable process documentation; treat the wiki as optional narrative only.
Local personal shelf clones of the wiki are not part of the published process.

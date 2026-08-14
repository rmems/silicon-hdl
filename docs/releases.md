<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-08-14 -->

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
5. Free-runner CI does **not** auto-publish tags. Optional later: `workflow_dispatch` or
   `push: tags: ['v*']` for release notes only — not required for v0.y.z.
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

Or one shot with notes from the changelog section:

```bash
gh release create v0.0.1 --target main --generate-notes
```

## What not to do

- Do not cut **`v0.1.0`** until F1 demo path acceptance on epic
  [#54](https://github.com/rmems/silicon-hdl/issues/54) is met (#69).
- Do not rewrite published release notes silently; ship a patch release if needed.
- Do not tag from feature branches.

## Wiki

GitHub wiki is **enabled** on `rmems/silicon-hdl`. Local incubating clone (if present):
`~/rmems/limen-return/wiki/silicon-hdl.wiki`. Prefer in-repo `docs/` for durable process
docs (including this file); use the wiki for optional narrative only.

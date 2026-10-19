#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Testbench manifest helper: the one place testbench lists come from.

``scripts/tb_manifest.json`` is the single source of truth for every
testbench (name, top module, sources, include dirs, extra Verilator flags,
and which runners use it). Consumers:

* ``scripts/quality.sh`` and ``.github/workflows/sim.yml`` -- runner
  ``verilator``; they call ``list`` / ``run`` below instead of hand-copying
  source lists.
* ``scripts/sim_core.tcl`` -- runner ``xsim``; it sources the generated
  ``scripts/tb_manifest.tcl`` (``core_tb_tops`` + ``pass_banner``). Vivado has
  no reliable JSON reader, so that file is generated and drift-checked.

Usage (run from anywhere; paths resolve against the repo root)::

  python3 scripts/tb_manifest.py validate
  python3 scripts/tb_manifest.py list [--runner verilator|xsim]
  python3 scripts/tb_manifest.py cmd NAME          # print the verilator command
  python3 scripts/tb_manifest.py run NAME [NAME...]  # build + execute (repo-root CWD)
  python3 scripts/tb_manifest.py run --all [--github]
  python3 scripts/tb_manifest.py tcl [--write | --check]

``tests/test_tb_manifest.py`` fails if any consumer names a testbench the
manifest does not have, or the manifest has one a consumer cannot reach.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "scripts" / "tb_manifest.json"
TCL_PATH = ROOT / "scripts" / "tb_manifest.tcl"

RUNNERS = ("verilator", "xsim")
REQUIRED_KEYS = ("name", "top", "sources", "include_dirs", "extra_verilator_flags", "runners")
NAME_RE = re.compile(r"^tb_\w+$")
# Tcl list elements below are emitted inside braces; keep banners brace-free.
TCL_UNSAFE_RE = re.compile(r"[{}\\\[\]$]")


class ManifestError(ValueError):
    pass


def load(path: Path = MANIFEST_PATH) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def testbenches(manifest: dict, runner: Optional[str] = None) -> List[dict]:
    tbs = manifest["testbenches"]
    if runner is None:
        return list(tbs)
    return [tb for tb in tbs if runner in tb["runners"]]


def names(manifest: dict, runner: Optional[str] = None) -> List[str]:
    return [tb["name"] for tb in testbenches(manifest, runner)]


def get(manifest: dict, name: str) -> dict:
    for tb in manifest["testbenches"]:
        if tb["name"] == name:
            return tb
    raise ManifestError(f"testbench {name!r} is not in {MANIFEST_PATH.name}")


def validate(manifest: dict, root: Path = ROOT) -> List[str]:
    """Return a list of problems (empty == valid)."""
    problems: List[str] = []
    if not isinstance(manifest.get("verilator_flags"), list):
        problems.append("top-level 'verilator_flags' must be a list")
    tbs = manifest.get("testbenches")
    if not isinstance(tbs, list) or not tbs:
        return problems + ["'testbenches' must be a non-empty list"]
    seen = set()
    for i, tb in enumerate(tbs):
        label = tb.get("name", f"testbenches[{i}]")
        missing = [k for k in REQUIRED_KEYS if k not in tb]
        if missing:
            problems.append(f"{label}: missing keys {missing}")
            continue
        if not NAME_RE.match(tb["name"]):
            problems.append(f"{label}: name must match {NAME_RE.pattern}")
        if tb["name"] in seen:
            problems.append(f"{label}: duplicate name")
        seen.add(tb["name"])
        bad = [r for r in tb["runners"] if r not in RUNNERS]
        if bad or not tb["runners"]:
            problems.append(f"{label}: runners must be a non-empty subset of {RUNNERS}, got {tb['runners']}")
        if "xsim" in tb["runners"]:
            banner = tb.get("xsim_pass_banner")
            if not banner:
                problems.append(f"{label}: xsim runner needs 'xsim_pass_banner'")
            elif TCL_UNSAFE_RE.search(banner):
                problems.append(f"{label}: xsim_pass_banner must not contain Tcl metacharacters")
        for d in tb["include_dirs"]:
            if not (root / d).is_dir():
                problems.append(f"{label}: include dir {d} does not exist")
        declared = False
        for src in tb["sources"]:
            p = root / src
            if not p.is_file():
                problems.append(f"{label}: source {src} does not exist")
                continue
            if re.search(rf"^\s*module\s+{re.escape(tb['top'])}\b", p.read_text(encoding="utf-8"), re.M):
                declared = True
        if not declared:
            problems.append(f"{label}: top module {tb['top']} is not declared in any listed source")
    return problems


def verilator_argv(manifest: dict, tb: dict) -> List[str]:
    argv = ["verilator", *manifest["verilator_flags"], *tb["extra_verilator_flags"], "--top-module", tb["top"]]
    argv += [f"-I{d}" for d in tb["include_dirs"]]
    argv += list(tb["sources"])
    return argv


def command_line(manifest: dict, tb: dict) -> str:
    return " ".join(shlex.quote(a) for a in verilator_argv(manifest, tb))


def run_one(manifest: dict, tb: dict, github: bool = False) -> bool:
    """Clean obj_dir, compile, then execute. CWD must be the repo root because
    $readmemh / INIT_FILE paths in the TBs are repo-root relative."""
    if "verilator" not in tb["runners"]:
        raise ManifestError(f"{tb['name']} does not list the 'verilator' runner")
    if github:
        print(f"::group::{tb['name']}", flush=True)
    print(f"=== Verilator {tb['name']} ===", flush=True)
    shutil.rmtree(ROOT / "obj_dir", ignore_errors=True)
    print("+ " + command_line(manifest, tb), flush=True)
    ok = subprocess.run(verilator_argv(manifest, tb), cwd=ROOT).returncode == 0
    if ok:
        ok = subprocess.run([f"./obj_dir/V{tb['top']}"], cwd=ROOT).returncode == 0
    if github:
        print("::endgroup::", flush=True)
        if not ok:
            print(f"::error title=Verilator testbench failed::{tb['name']}", flush=True)
    return ok


def render_tcl(manifest: dict) -> str:
    xs = testbenches(manifest, "xsim")
    width = max(len(tb["name"]) for tb in xs)
    lines = [
        "# SPDX-License-Identifier: MIT OR Apache-2.0",
        "# GENERATED by scripts/tb_manifest.py from scripts/tb_manifest.json -- do not edit.",
        "# Regenerate: python3 scripts/tb_manifest.py tcl --write",
        "# Sourced by scripts/sim_core.tcl (testbenches whose runners include 'xsim').",
        "",
        "set core_tb_tops {" + " ".join(tb["top"] for tb in xs) + "}",
        "",
        "array set pass_banner {",
    ]
    lines += [f"    {tb['top'].ljust(width)}  {{{tb['xsim_pass_banner']}}}" for tb in xs]
    lines += ["}", ""]
    return "\n".join(lines)


TB_TOKEN_RE = re.compile(r"\btb_\w+")
# tb_* identifiers in consumers that are not testbenches: the manifest/helper
# file names and the loop variables in sim_core.tcl. Keep this list short;
# anything else that looks like tb_* must be in the manifest.
NON_TB_IDENTIFIERS = frozenset({"tb_manifest", "tb_dir", "tb_top"})


def tb_tokens(text: str) -> set:
    return set(TB_TOKEN_RE.findall(text))


def consumer_drift(manifest: dict, consumers: Dict[str, str]) -> List[str]:
    """Check consumer file texts ({repo-relative path: text}) against the manifest.

    Any ``tb_*`` token in a consumer must be a manifest testbench name or top
    (or the basename of a manifest source, e.g. tb_Basys3_Top). Verilator
    consumers must enumerate the manifest rather than hard-code tops.
    """
    known = set()
    for tb in manifest["testbenches"]:
        known |= {tb["name"], tb["top"]}
        known |= {Path(s).stem for s in tb["sources"]}
    known |= NON_TB_IDENTIFIERS
    problems: List[str] = []
    for path, text in consumers.items():
        for tok in sorted(tb_tokens(text) - known):
            problems.append(f"{path}: references {tok}, which is not in tb_manifest.json")
        if path.endswith(("quality.sh", "sim.yml")):
            if "--top-module" in text:
                problems.append(f"{path}: hard-codes a --top-module; use scripts/tb_manifest.py")
            if "tb_manifest.py" not in text:
                problems.append(f"{path}: does not run testbenches from scripts/tb_manifest.py")
        if path.endswith("sim_core.tcl"):
            if re.search(r"^\s*set\s+core_tb_tops\b", text, re.M):
                problems.append(f"{path}: defines core_tb_tops itself; source tb_manifest.tcl instead")
            if "tb_manifest.tcl" not in text:
                problems.append(f"{path}: does not source scripts/tb_manifest.tcl")
            xsim = set(names(manifest, "xsim"))
            for tok in sorted((tb_tokens(text) & known) - xsim - NON_TB_IDENTIFIERS):
                if tok in {tb["name"] for tb in manifest["testbenches"]}:
                    problems.append(f"{path}: configures {tok}, which is not an xsim testbench")
    return problems


def _main(argv: Optional[Iterable[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("validate")
    p_list = sub.add_parser("list")
    p_list.add_argument("--runner", choices=RUNNERS)
    p_cmd = sub.add_parser("cmd")
    p_cmd.add_argument("name")
    p_run = sub.add_parser("run")
    p_run.add_argument("names", nargs="*")
    p_run.add_argument("--all", action="store_true", help="every testbench with the verilator runner")
    p_run.add_argument("--github", action="store_true", help="emit GitHub Actions ::group:: / ::error::")
    p_tcl = sub.add_parser("tcl")
    g = p_tcl.add_mutually_exclusive_group()
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    args = ap.parse_args(list(argv) if argv is not None else None)

    manifest = load()
    problems = validate(manifest)
    if problems:
        for p in problems:
            print(f"tb_manifest: {p}", file=sys.stderr)
        return 1

    if args.cmd == "validate":
        print(f"tb_manifest: OK ({len(manifest['testbenches'])} testbenches)")
        return 0
    if args.cmd == "list":
        print("\n".join(names(manifest, args.runner)))
        return 0
    if args.cmd == "cmd":
        print(command_line(manifest, get(manifest, args.name)))
        return 0
    if args.cmd == "run":
        if args.all == bool(args.names):
            ap.error("run takes either --all or one or more names")
        selected = testbenches(manifest, "verilator") if args.all else [get(manifest, n) for n in args.names]
        failed = [tb["name"] for tb in selected if not run_one(manifest, tb, github=args.github)]
        print(f"=== tb_manifest run: {len(selected) - len(failed)}/{len(selected)} passed ===")
        for n in failed:
            print(f"FAIL  {n}")
        return 1 if failed else 0
    if args.cmd == "tcl":
        text = render_tcl(manifest)
        if args.write:
            TCL_PATH.write_text(text, encoding="utf-8")
            print(f"wrote {TCL_PATH.relative_to(ROOT)}")
            return 0
        if args.check:
            current = TCL_PATH.read_text(encoding="utf-8") if TCL_PATH.exists() else ""
            if current != text:
                print(f"{TCL_PATH.relative_to(ROOT)} is stale; run: python3 scripts/tb_manifest.py tcl --write",
                      file=sys.stderr)
                return 1
            print(f"{TCL_PATH.relative_to(ROOT)}: up to date")
            return 0
        sys.stdout.write(text)
        return 0
    return 2  # pragma: no cover


if __name__ == "__main__":
    sys.exit(_main())

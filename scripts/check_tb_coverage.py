#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Testbench coverage drift guard for silicon-hdl.

Every testbench top has to be listed by hand in three unrelated places:

  scripts/quality.sh              local free-stack gate (AGENTS.md tells agents to run this)
  scripts/sim_core.tcl            Vivado XSim, `core_tb_tops`
  .github/workflows/sim.yml       one explicit step per TB

Nothing tied those lists to each other or to the testbenches actually on disk,
so they drifted: quality.sh was silently missing tb_WeightRam_init and
tb_NeuronParamRam_init -- the only two TBs that exercise $readmemh against the
merged_v2 memory images. A broken image therefore passed the documented local
gate and failed only in CI.

This script asserts all four sets agree. Adding a TB without wiring it
everywhere now fails fast, with a diff naming the file to edit.

Usage:
  python scripts/check_tb_coverage.py          # exits non-zero on drift
  python scripts/check_tb_coverage.py --list   # print the reconciled set
"""

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

TB_GLOBS = ["spikenaut-*/tb/*.sv"]
MODULE_RE = re.compile(r"^\s*module\s+(tb_\w+)", re.MULTILINE)
TOP_MODULE_RE = re.compile(r"--top-module\s+(tb_\w+)")
CORE_TB_TOPS_RE = re.compile(r"set\s+core_tb_tops\s*\{([^}]*)\}")
# quality.sh drives most TBs through "dut:tb" pairs in bash arrays.
PAIR_RE = re.compile(r'"(\w+):(\w+)"')
BRIDGE_ARRAY_RE = re.compile(r"BRIDGE_TBS=\(([^)]*)\)")


def tbs_on_disk() -> set:
    found = set()
    for glob in TB_GLOBS:
        for f in REPO.glob(glob):
            found |= set(MODULE_RE.findall(f.read_text(encoding="utf-8", errors="replace")))
    return found


def tbs_in_quality_sh() -> set:
    text = (REPO / "scripts" / "quality.sh").read_text(encoding="utf-8")
    found = set(TOP_MODULE_RE.findall(text))
    # "Dut:Tb" pairs -- the loop builds tb_<second> or uses it verbatim.
    for first, second in PAIR_RE.findall(text):
        found.add(second if second.startswith("tb_") else f"tb_{second}")
    for arr in BRIDGE_ARRAY_RE.findall(text):
        found |= {f"tb_{name}" for name in arr.split()}
    return {t for t in found if t.startswith("tb_")}


def tbs_in_sim_core_tcl() -> set:
    text = (REPO / "scripts" / "sim_core.tcl").read_text(encoding="utf-8")
    m = CORE_TB_TOPS_RE.search(text)
    if not m:
        print("check_tb_coverage: could not find `set core_tb_tops {...}` in sim_core.tcl",
              file=sys.stderr)
        sys.exit(2)
    return {t for t in m.group(1).split() if t.startswith("tb_")}


def tbs_in_sim_yml() -> set:
    text = (REPO / ".github" / "workflows" / "sim.yml").read_text(encoding="utf-8")
    return set(TOP_MODULE_RE.findall(text))


SOURCES = {
    "disk (spikenaut-*/tb/*.sv)": tbs_on_disk,
    "scripts/quality.sh": tbs_in_quality_sh,
    "scripts/sim_core.tcl": tbs_in_sim_core_tcl,
    ".github/workflows/sim.yml": tbs_in_sim_yml,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="print the reconciled TB set and exit")
    args = ap.parse_args()

    sets = {name: fn() for name, fn in SOURCES.items()}
    union = set().union(*sets.values())

    if args.list:
        for tb in sorted(union):
            print(tb)
        return 0

    drift = False
    for name, found in sets.items():
        missing = sorted(union - found)
        if missing:
            drift = True
            print(f"MISSING from {name}:")
            for tb in missing:
                print(f"    {tb}")

    if drift:
        print()
        print(f"check_tb_coverage: FAIL -- {len(union)} testbench tops known, "
              "but the lists above do not all agree.")
        print("Every TB must be wired into quality.sh, sim_core.tcl and sim.yml.")
        return 1

    print(f"check_tb_coverage: OK -- all {len(union)} testbench tops "
          "are wired into every runner.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

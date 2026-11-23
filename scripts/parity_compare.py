#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Parity comparator for GH#76: expected trace vs observed trace.

Usage (from the repo root)::

    python3 scripts/parity_compare.py \
        testdata/supervisor_parity/expected_trace.json \
        testdata/supervisor_parity/observed.json \
        -o testdata/supervisor_parity/parity_report.json

Exit code 0 = parity, 1 = divergence or contract violation, 2 = bad input.

The same comparator covers both sources of ``observed.json``:
``tb_SocParity`` (Verilator replay) and a physical-board capture
(docs/supervisor-parity.md). Discrete outputs — spike words, membrane
potentials (Q8.8 raw), output class, consumed-tick alignment — require
**exact** agreement after the declared schedule; the issue allows no
tolerance without an explicit justification, and none is declared for
these observables.

Unobservable outputs are recorded, never counted as passing: a board
capture without ``output_class`` marks those checks ``not_observed`` and
excludes them from ``action_agreement`` and from ``pass``.

The report is deterministic for identical inputs (no timestamps, no host
info); ``--rtl-commit`` / ``--software-commit`` / ``--tool`` inject the
provenance fields the issue requires without baking them into the file.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def load_json(path: Path) -> dict:
    try:
        # NOSONAR: fixture paths are supplied by the operator/CI job
        data = json.loads(path.read_text())  # NOSONAR
    except (OSError, json.JSONDecodeError) as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(2)
    if not isinstance(data, dict):
        print(f"{path}: expected a JSON object at the root", file=sys.stderr)
        raise SystemExit(2)
    return data


def git_commit() -> str:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
        )
        return out.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def _cmp_scalar(checks: dict, key: str, exp: dict, obs: dict, i: int) -> str | None:
    chk = checks[key]
    chk["compared"] += 1
    exp_val = exp.get(key)
    # A missing expected value is a malformed fixture, not agreement: both
    # sides absent must fail loudly instead of counting as exact.
    if exp_val is not None and obs.get(key) == exp_val:
        chk["exact"] += 1
        return None
    chk["mismatches"].append(
        {"step": i, "expected": exp_val, "observed": obs.get(key)}
    )
    return key


def _cmp_step(
    checks: dict, exp: dict, obs: dict, i: int, source: str
) -> list[str]:
    diverged = []
    for key in ("consumed_tick", "spike_word"):
        if _cmp_scalar(checks, key, exp, obs, i):
            diverged.append(key)

    exp_pots = exp.get("potentials_raw", exp.get("potentials"))
    obs_pots = obs.get("potentials")
    chk = checks["potentials"]
    chk["compared"] += 1
    if exp_pots is not None and obs_pots == exp_pots:
        chk["exact"] += 1
    else:
        entry = {
            "step": i,
            "lanes": [
                {"lane": j, "expected": e, "observed": o}
                for j, (e, o) in enumerate(zip(exp_pots or [], obs_pots or []))
                if e != o
            ],
        }
        if exp_pots is None or obs_pots is None:
            side = "expected" if exp_pots is None else "observed"
            entry["note"] = f"potentials missing on {side} side"
        chk["mismatches"].append(entry)
        diverged.append("potentials")

    chk = checks["output_class"]
    if obs.get("output_class") is None:
        if source == "sim":
            # Sim traces always expose output_class; absence is a contract
            # violation, not an unobservable board-side signal.
            chk["compared"] += 1
            chk["mismatches"].append({
                "step": i, "expected": exp.get("output_class"),
                "observed": None, "note": "missing in sim trace",
            })
            diverged.append("output_class")
        else:
            chk["not_observed"] += 1
    elif _cmp_scalar(checks, "output_class", exp, obs, i):
        diverged.append("output_class")
    return diverged


def compare(expected: dict, observed: dict, meta: dict) -> dict:
    exp_steps = expected.get("steps", [])
    obs_steps = observed.get("steps", [])

    report = {
        "fixture": expected.get("fixture", observed.get("fixture", "unknown")),
        "contract": "exact discrete agreement after declared consumed-tick alignment",
        "schedule": {
            "ticks_per_frame_expected": expected.get("ticks_per_frame"),
            "ticks_per_frame_observed": observed.get("ticks_per_frame"),
        },
        "expected_steps": len(exp_steps),
        "observed_steps": len(obs_steps),
        "elapsed_ticks_observed": observed.get("elapsed_ticks"),
        "frame_send_count_observed": observed.get("frame_send_count"),
        "checks": {
            "spike_word": {"compared": 0, "exact": 0, "mismatches": []},
            "potentials": {"compared": 0, "exact": 0, "mismatches": []},
            "output_class": {"compared": 0, "exact": 0, "mismatches": [],
                             "not_observed": 0},
            "consumed_tick": {"compared": 0, "exact": 0, "mismatches": []},
        },
        "first_divergence_step": None,
        "divergent_steps": [],
        "meta": meta,
    }

    n = min(len(exp_steps), len(obs_steps))
    if len(exp_steps) != len(obs_steps):
        report["divergent_steps"].append({
            "step": None, "field": "step_count",
            "expected": len(exp_steps), "observed": len(obs_steps),
        })
        report["first_divergence_step"] = n

    source = meta.get("source", "board")
    for i in range(n):
        diverged_fields = _cmp_step(
            report["checks"], exp_steps[i], obs_steps[i], i, source
        )
        if diverged_fields:
            report["divergent_steps"].append(
                {"step": i, "name": exp_steps[i].get("name"),
                 "fields": diverged_fields}
            )
            if report["first_divergence_step"] is None:
                report["first_divergence_step"] = i

    def agree(key):
        chk = report["checks"][key]
        return chk["exact"] / chk["compared"] if chk["compared"] else None

    report["spike_agreement"] = agree("spike_word")
    report["potential_agreement"] = agree("potentials")
    report["action_agreement"] = agree("output_class")
    report["alignment_agreement"] = agree("consumed_tick")

    report["pass"] = (
        not report["divergent_steps"]
        and len(exp_steps) == len(obs_steps)
        and len(exp_steps) > 0
    )
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("expected", type=Path)
    parser.add_argument("observed", type=Path)
    parser.add_argument("-o", "--out", type=Path, default=None,
                        help="write parity_report.json here (default: stdout)")
    parser.add_argument("--rtl-commit", default=None)
    parser.add_argument("--software-commit", default=None)
    parser.add_argument("--tool", default=None,
                        help="tool name/version recorded in the report meta")
    parser.add_argument("--source", default="sim",
                        choices=["sim", "board"],
                        help="provenance of the observed trace")
    args = parser.parse_args(argv)

    expected = load_json(args.expected)
    observed = load_json(args.observed)
    meta = {
        "source": args.source,
        "rtl_commit": args.rtl_commit or git_commit(),
        "software_reference_commit": args.software_commit or git_commit(),
        "tool": args.tool,
        "expected_file": str(args.expected),
        "observed_file": str(args.observed),
    }

    report = compare(expected, observed, meta)
    text = json.dumps(report, indent=2) + "\n"

    if args.out:
        # NOSONAR: report destination is supplied by the operator/CI job
        args.out.write_text(text)  # NOSONAR
        print(f"parity report written to {args.out}")
    else:
        sys.stdout.write(text)

    # Keep stdout JSON-clean when the report is streamed: the human summary
    # goes to stderr in that mode so `parity_compare ... | jq` stays valid.
    out_stream = sys.stdout if args.out else sys.stderr
    if report["pass"]:
        print(
            f"PARITY: {report['expected_steps']} steps, "
            f"spike={report['spike_agreement']}, "
            f"potentials={report['potential_agreement']}, "
            f"action={report['action_agreement']}, "
            f"alignment={report['alignment_agreement']}",
            file=out_stream,
        )
        return 0

    print(
        f"PARITY FAILED: {len(report['divergent_steps'])} divergent step(s), "
        f"first divergence at step {report['first_divergence_step']}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

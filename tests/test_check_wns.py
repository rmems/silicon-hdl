# SPDX-License-Identifier: MIT OR Apache-2.0
"""Fail-closed coverage for the Vivado timing-report gate."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_wns", ROOT / "scripts/check_wns.py")
assert SPEC is not None
assert SPEC.loader is not None
CHECK_WNS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK_WNS)


def _run(monkeypatch, path: Path) -> int:
    monkeypatch.setattr(CHECK_WNS.sys, "argv", ["check_wns.py", str(path)])
    return CHECK_WNS.main()


def test_missing_report_fails_closed(monkeypatch, tmp_path: Path) -> None:
    assert _run(monkeypatch, tmp_path / "missing.rpt") == 1


def test_unparseable_report_fails_closed(monkeypatch, tmp_path: Path) -> None:
    report = tmp_path / "timing_summary.rpt"
    report.write_text("not a Vivado timing summary\n", encoding="utf-8")
    assert _run(monkeypatch, report) == 1


def test_both_setup_and_hold_are_required(monkeypatch, tmp_path: Path) -> None:
    report = tmp_path / "timing_summary.rpt"
    report.write_text("WNS = 0.125 ns\n", encoding="utf-8")
    assert _run(monkeypatch, report) == 1


def test_nonnegative_setup_and_hold_pass(monkeypatch, tmp_path: Path) -> None:
    report = tmp_path / "timing_summary.rpt"
    report.write_text("WNS = 0.125 ns\nWHS = 0.031 ns\n", encoding="utf-8")
    assert _run(monkeypatch, report) == 0


def test_negative_hold_fails(monkeypatch, tmp_path: Path) -> None:
    report = tmp_path / "timing_summary.rpt"
    report.write_text("WNS = 0.125 ns\nWHS = -0.001 ns\n", encoding="utf-8")
    assert _run(monkeypatch, report) == 1

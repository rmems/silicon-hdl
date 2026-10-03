# SPDX-License-Identifier: MIT OR Apache-2.0
"""Regression checks for the Amp orb bootstrap contract."""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SETUP = (REPO_ROOT / ".agents" / "setup").read_text()


def test_remote_installer_is_pinned_downloaded_and_verified() -> None:
    """A partial or changed remote installer must never be executed."""
    assert re.search(r"UV_VERSION=[\"']\d+\.\d+\.\d+[\"']", SETUP)
    assert "mktemp" in SETUP
    assert "sha256sum -c" in SETUP
    assert not re.search(r"curl[^\n]*\|\s*(?:ba)?sh", SETUP)


def test_python_setup_reuses_312_and_replaces_wrong_version_venv() -> None:
    """Reruns avoid downloads while stale non-3.12 environments are replaced."""
    assert re.search(r"uv python find[^\n]*3\.12", SETUP)
    assert re.search(r"uv python install[^\n]*3\.12", SETUP)
    assert re.search(r"\.venv/bin/python[^\n]*version_info", SETUP)
    assert "rm -rf .venv" in SETUP


def test_setup_requires_verilator_with_widthexpand_support() -> None:
    """The provisioned simulator must accept the repository's standard flags."""
    match = re.search(r"VERILATOR_MIN_VERSION=[\"'](\d+)\.(\d+)[\"']", SETUP)
    assert match
    assert tuple(map(int, match.groups())) >= (5, 8)
    assert re.search(r"apt_install[^\n]*\blibfl-dev\b", SETUP)


def test_generated_venv_is_ignored_by_git() -> None:
    assert "/.venv/" in (REPO_ROOT / ".gitignore").read_text().splitlines()

# SPDX-License-Identifier: MIT OR Apache-2.0
"""Single testbench manifest: stop local/CI test-list drift.

``scripts/tb_manifest.json`` is the only place testbench lists live. These
tests fail when a consumer (``scripts/quality.sh``, ``.github/workflows/sim.yml``,
``scripts/sim_core.tcl`` via the generated ``scripts/tb_manifest.tcl``)
references a testbench the manifest does not have, or the manifest has a
testbench that its declared runners cannot reach.
"""

from __future__ import annotations

import copy
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import tb_manifest as tm

ROOT = Path(__file__).resolve().parent.parent
CONSUMERS = ("scripts/quality.sh", ".github/workflows/sim.yml", "scripts/sim_core.tcl")
TB_DIRS = (
    "spikenaut-core-sv/tb",
    "spikenaut-bridge-sv/tb",
    "spikenaut-soc-sv/tb",
    "synapse-link-hdl/tb",
)


@pytest.fixture(scope="module")
def manifest() -> dict:
    return tm.load()


def _consumers() -> dict:
    return {p: (ROOT / p).read_text(encoding="utf-8") for p in CONSUMERS}


def _tcl_list(text: str, var: str) -> list:
    m = re.search(rf"^\s*set\s+{var}\s+\{{([^}}]*)\}}", text, re.M)
    assert m, f"{var} not found"
    return m.group(1).split()


def _tcl_banners(text: str) -> dict:
    block = re.search(r"array set pass_banner \{\n(.*?)\n\}", text, re.S)
    assert block, "pass_banner block not found"
    return dict(re.findall(r"^\s*(\S+)\s+\{([^}]*)\}\s*$", block.group(1), re.M))


# --- the manifest itself ---------------------------------------------------


def test_manifest_is_valid(manifest: dict) -> None:
    assert tm.validate(manifest) == []


def test_every_tb_file_on_disk_is_in_the_manifest(manifest: dict) -> None:
    listed = {s for tb in manifest["testbenches"] for s in tb["sources"]}
    on_disk = {
        p.relative_to(ROOT).as_posix()
        for d in TB_DIRS
        for p in sorted((ROOT / d).glob("tb_*.sv"))
    }
    assert on_disk, "no testbench files found"
    assert sorted(on_disk - listed) == [], "tb_*.sv files not in tb_manifest.json"


def test_every_tb_module_on_disk_is_a_manifest_top(manifest: dict) -> None:
    tops = {tb["top"] for tb in manifest["testbenches"]}
    declared = set()
    for d in TB_DIRS:
        for p in (ROOT / d).glob("tb_*.sv"):
            declared |= set(re.findall(r"^\s*module\s+(tb_\w+)", p.read_text(encoding="utf-8"), re.M))
    assert sorted(declared - tops) == [], "testbench modules with no manifest entry"


def test_the_two_init_tbs_run_under_verilator(manifest: dict) -> None:
    # Regression for the drift that motivated the manifest: quality.sh skipped
    # these two while sim.yml ran them.
    verilator = set(tm.names(manifest, "verilator"))
    assert {"tb_WeightRam_init", "tb_NeuronParamRam_init"} <= verilator


def test_verilator_argv_shape(manifest: dict) -> None:
    tb = tm.get(manifest, "tb_StdpWriteback")
    argv = tm.verilator_argv(manifest, tb)
    assert argv[:6] == [
        "verilator", "--binary", "--timing",
        "-Wno-WIDTHEXPAND", "-Wno-DECLFILENAME", "-Wno-TIMESCALEMOD",
    ]
    assert argv[argv.index("--top-module") + 1] == "tb_StdpWriteback"
    assert "-Ispikenaut-core-sv/rtl" in argv
    assert argv[-1] == "spikenaut-core-sv/tb/tb_StdpWriteback.sv"


def test_extra_verilator_flags_are_applied(manifest: dict) -> None:
    tb = copy.deepcopy(tm.get(manifest, "tb_UartRx"))
    tb["extra_verilator_flags"] = ["-Wno-UNUSED"]
    argv = tm.verilator_argv(manifest, tb)
    assert argv.index("-Wno-UNUSED") < argv.index("--top-module")


def test_validate_rejects_broken_entries(manifest: dict) -> None:
    bad = copy.deepcopy(manifest)
    bad["testbenches"].append(copy.deepcopy(bad["testbenches"][0]))  # duplicate
    bad["testbenches"][1]["runners"] = ["modelsim"]
    bad["testbenches"][2]["sources"] = ["spikenaut-core-sv/tb/tb_Nope.sv"]
    del bad["testbenches"][3]["xsim_pass_banner"]
    problems = "\n".join(tm.validate(bad))
    assert "duplicate name" in problems
    assert "runners must be" in problems
    assert "tb_Nope.sv does not exist" in problems
    assert "needs 'xsim_pass_banner'" in problems


# --- consumers ---------------------------------------------------------------


def test_consumers_reference_only_manifest_tbs(manifest: dict) -> None:
    assert tm.consumer_drift(manifest, _consumers()) == []


def test_generated_tcl_is_up_to_date(manifest: dict) -> None:
    assert (ROOT / "scripts/tb_manifest.tcl").read_text(encoding="utf-8") == tm.render_tcl(manifest)


def test_xsim_tops_and_banners_match_manifest(manifest: dict) -> None:
    tcl = (ROOT / "scripts/tb_manifest.tcl").read_text(encoding="utf-8")
    xsim = tm.testbenches(manifest, "xsim")
    assert _tcl_list(tcl, "core_tb_tops") == [tb["top"] for tb in xsim]
    assert _tcl_banners(tcl) == {tb["top"]: tb["xsim_pass_banner"] for tb in xsim}


def test_sim_core_sources_generated_list() -> None:
    text = (ROOT / "scripts/sim_core.tcl").read_text(encoding="utf-8")
    assert "source [file join $repo_root scripts tb_manifest.tcl]" in text
    assert not re.search(r"^\s*set\s+core_tb_tops\b", text, re.M)
    assert not re.search(r"^\s*array\s+set\s+pass_banner\b", text, re.M)


def test_verilator_consumers_enumerate_the_manifest() -> None:
    quality = (ROOT / "scripts/quality.sh").read_text(encoding="utf-8")
    sim = (ROOT / ".github/workflows/sim.yml").read_text(encoding="utf-8")
    assert "scripts/tb_manifest.py list --runner verilator" in quality
    assert "scripts/tb_manifest.py run --all" in sim
    for text in (quality, sim):
        assert "--top-module" not in text
        assert not re.search(r"\.sv\b", text), "consumer hard-codes .sv sources"


def test_quality_runs_pytest() -> None:
    quality = (ROOT / "scripts/quality.sh").read_text(encoding="utf-8")
    assert re.search(r"^\s*record \"pytest\"", quality, re.M)


# --- injected drift must be caught -------------------------------------------


def test_drift_unknown_tb_in_consumer_is_caught(manifest: dict) -> None:
    consumers = _consumers()
    consumers["scripts/quality.sh"] += "\n./obj_dir/Vtb_Bogus\nrun tb_Bogus\n"
    problems = tm.consumer_drift(manifest, consumers)
    assert any("tb_Bogus" in p for p in problems)


def test_drift_tb_removed_from_manifest_is_caught(manifest: dict) -> None:
    shrunk = copy.deepcopy(manifest)
    shrunk["testbenches"] = [tb for tb in shrunk["testbenches"] if tb["name"] != "tb_WeightRam_init"]
    problems = tm.consumer_drift(shrunk, _consumers())
    # sim_core.tcl still configures tb_WeightRam_init's INIT generic.
    assert any("sim_core.tcl" in p and "tb_WeightRam_init" in p for p in problems)
    # ...and the generated Tcl list would no longer match.
    assert tm.render_tcl(shrunk) != (ROOT / "scripts/tb_manifest.tcl").read_text(encoding="utf-8")


def test_drift_hardcoded_verilator_step_is_caught(manifest: dict) -> None:
    consumers = _consumers()
    consumers[".github/workflows/sim.yml"] += "\n          verilator --top-module tb_UartRx x.sv\n"
    problems = tm.consumer_drift(manifest, consumers)
    assert any("hard-codes a --top-module" in p for p in problems)


def test_drift_xsim_only_tb_configured_for_non_xsim_is_caught(manifest: dict) -> None:
    edited = copy.deepcopy(manifest)
    tm.get(edited, "tb_AerRouteTable")["runners"] = ["verilator"]
    problems = tm.consumer_drift(edited, _consumers())
    assert any("tb_AerRouteTable" in p and "not an xsim testbench" in p for p in problems)


# --- CLI ---------------------------------------------------------------------


def _cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts/tb_manifest.py"), *args],
        capture_output=True, text=True, cwd=ROOT,
    )


def test_cli_validate_and_tcl_check() -> None:
    assert _cli("validate").returncode == 0
    r = _cli("tcl", "--check")
    assert r.returncode == 0, r.stderr


def test_cli_list_and_cmd(manifest: dict) -> None:
    r = _cli("list", "--runner", "verilator")
    assert r.returncode == 0
    assert r.stdout.split() == tm.names(manifest, "verilator")
    r = _cli("cmd", "tb_LifNeuron")
    assert r.returncode == 0
    assert r.stdout.strip() == tm.command_line(manifest, tm.get(manifest, "tb_LifNeuron"))


def test_cli_unknown_tb_fails() -> None:
    r = _cli("cmd", "tb_DoesNotExist")
    assert r.returncode != 0


def test_in_process_main(capsys: pytest.CaptureFixture) -> None:
    assert tm._main(["list", "--runner", "xsim"]) == 0
    assert "tb_spikenaut_soc_basys3_top" in capsys.readouterr().out
    assert tm._main(["tcl"]) == 0
    assert "set core_tb_tops {" in capsys.readouterr().out
    assert tm._main(["tcl", "--check"]) == 0


@pytest.mark.skipif(shutil.which("tclsh") is None, reason="tclsh not installed")
def test_generated_tcl_sources_cleanly(manifest: dict) -> None:
    script = (
        f"source {{{ROOT / 'scripts/tb_manifest.tcl'}}}\n"
        "foreach t $core_tb_tops { if {![info exists pass_banner($t)]} { error \"no banner $t\" } }\n"
        "puts [llength $core_tb_tops]\n"
    )
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert int(r.stdout.strip()) == len(tm.names(manifest, "xsim"))


@pytest.mark.skipif(shutil.which("tclsh") is None, reason="tclsh not installed")
def test_sim_core_tcl_is_syntactically_complete() -> None:
    script = (
        f"set fd [open {{{ROOT / 'scripts/sim_core.tcl'}}}]; set t [read $fd]; close $fd\n"
        "if {![info complete $t]} { error incomplete }\n"
    )
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr

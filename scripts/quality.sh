#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# quality.sh — local free-stack quality entrypoint (epic #23 Phase A3)
#
# Usage:
#   ./scripts/quality.sh              # guardian + drift gates + every Verilator TB in
#                                     # scripts/tb_manifest.json + pytest
#   ./scripts/quality.sh --vivado     # also run sim_core.tcl + build_soc.tcl
#
# Vivado requires: source ~/Xilinx/env.sh  (or settings64.sh + license env)

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_VIVADO=0
for arg in "$@"; do
  case "$arg" in
    --vivado) RUN_VIVADO=1 ;;
    -h|--help)
      sed -n '2,11p' "$SCRIPT_PATH"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

pass=0
fail=0
results=()

record() {
  local name="$1" status="$2"
  results+=("$status  $name")
  if [[ "$status" == "PASS" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
}

echo "=== Deduplication Guardian ==="
if python3 scripts/dedup_guardian.py; then
  record "dedup_guardian" "PASS"
else
  record "dedup_guardian" "FAIL"
fi

# Golden-vector drift gate (GH#66). Runs before the simulations: if the
# committed vectors no longer match what the generator produces, the two
# golden TBs below would be checking the RTL against a stale trace.
echo ""
echo "=== Golden vector drift check ==="
if python3 scripts/gen_golden_lif_vectors.py --check; then
  record "golden_vectors/drift" "PASS"
else
  record "golden_vectors/drift" "FAIL"
fi

# Golden UART frame-vector drift gate (GH#64). Same reasoning as above: a stale
# frame vector set would make tb_SocFrameGolden check the wire framing against
# a trace that no longer describes the contract.
echo ""
echo "=== Golden frame vector drift check ==="
if python3 scripts/gen_golden_frame_vectors.py --check; then
  record "golden_frames/drift" "PASS"
else
  record "golden_frames/drift" "FAIL"
fi

echo ""
echo "=== AER route image drift check ==="
if python3 scripts/gen_aer_route_vectors.py --check; then
  record "aer_routes/drift" "PASS"
else
  record "aer_routes/drift" "FAIL"
fi

# Testbench manifest (single source of truth for quality.sh, sim.yml and
# sim_core.tcl). Validate it and make sure the Vivado list generated from it
# is not stale before running anything from it.
echo ""
echo "=== Testbench manifest ==="
if python3 scripts/tb_manifest.py validate && python3 scripts/tb_manifest.py tcl --check; then
  record "tb_manifest" "PASS"
else
  record "tb_manifest" "FAIL"
fi

# Every testbench whose manifest "runners" include verilator: same flags,
# sources and include dirs as .github/workflows/sim.yml, because both read
# scripts/tb_manifest.json. Each TB cleans obj_dir and runs from the repo root
# ($readmemh / INIT_FILE paths are repo-root relative).
mapfile -t VERILATOR_TBS < <(python3 scripts/tb_manifest.py list --runner verilator)
if [[ "${#VERILATOR_TBS[@]}" -eq 0 ]]; then
  record "verilator/manifest_empty" "FAIL"
fi
for tb in "${VERILATOR_TBS[@]}"; do
  echo ""
  if python3 scripts/tb_manifest.py run "$tb"; then
    record "verilator/${tb}" "PASS"
  else
    record "verilator/${tb}" "FAIL"
  fi
done

# Python tests (drift gates, Q8.8 codec, manifest consistency) -- the same
# suite coverage.yml runs in CI.
echo ""
echo "=== pytest ==="
if command -v pytest >/dev/null 2>&1; then
  PYTEST=(pytest)
else
  PYTEST=(python3 -m pytest)
fi
if "${PYTEST[@]}"; then
  record "pytest" "PASS"
else
  record "pytest" "FAIL"
fi

if [[ "$RUN_VIVADO" -eq 1 ]]; then
  echo ""
  if ! command -v vivado >/dev/null 2>&1; then
    echo "vivado not on PATH. Run: source ~/Xilinx/env.sh" >&2
    record "vivado/available" "FAIL"
  else
    echo "=== Vivado sim_core.tcl ==="
    if vivado -mode batch -source scripts/sim_core.tcl -log vivado_sim_core.log -journal vivado_sim_core.jou; then
      record "vivado/sim_core" "PASS"
    else
      record "vivado/sim_core" "FAIL"
    fi
    echo ""
    echo "=== Vivado build_soc.tcl ==="
    if vivado -mode batch -source scripts/build_soc.tcl -log vivado_build_soc.log -journal vivado_build_soc.jou; then
      record "vivado/build_soc" "PASS"
    else
      record "vivado/build_soc" "FAIL"
    fi
  fi
fi

echo ""
echo "=== Quality summary ==="
for line in "${results[@]}"; do
  printf '  %s\n' "$line"
done
echo "  ----"
echo "  PASS=$pass FAIL=$fail"

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0

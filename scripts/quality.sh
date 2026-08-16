#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# quality.sh — local free-stack quality entrypoint (epic #23 Phase A3)
#
# Usage:
#   ./scripts/quality.sh              # guardian + all core Verilator TBs
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
      sed -n '2,12p' "$SCRIPT_PATH"
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

VERILATOR_FLAGS=(--binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD)
TBS=(
  "LifNeuron:LifNeuron"
  "WeightRam:WeightRam"
  "NeuronParamRam:NeuronParamRam"
  "StdpController:StdpController"
)

for entry in "${TBS[@]}"; do
  tb="${entry%%:*}"
  dut="${entry##*:}"
  echo ""
  echo "=== Verilator tb_${tb} ==="
  rm -rf obj_dir
  if verilator "${VERILATOR_FLAGS[@]}" \
      --top-module "tb_${tb}" \
      -Ispikenaut-core-sv/rtl \
      "spikenaut-core-sv/rtl/${dut}.sv" \
      "spikenaut-core-sv/tb/tb_${tb}.sv" \
    && "./obj_dir/Vtb_${tb}"; then
    record "verilator/tb_${tb}" "PASS"
  else
    record "verilator/tb_${tb}" "FAIL"
  fi
done

echo ""
echo "=== Verilator tb_spikenaut_soc_basys3_top ==="
# SoC-level TB: the only sim that exercises the 1 ms step_en divider and the
# UART-event -> tick-domain handoff (#57 / #60). Needs lib_bridge + lib_core +
# lib_soc in dependency order, and repo-root CWD for the $readmemh INIT paths.
rm -rf obj_dir
if verilator "${VERILATOR_FLAGS[@]}" \
    --top-module tb_spikenaut_soc_basys3_top \
    -Ispikenaut-core-sv/rtl -Ispikenaut-bridge-sv/rtl \
    spikenaut-bridge-sv/rtl/UartRx.sv \
    spikenaut-bridge-sv/rtl/UartTx.sv \
    spikenaut-bridge-sv/rtl/SiliconBridge.sv \
    spikenaut-core-sv/rtl/LifNeuron.sv \
    spikenaut-core-sv/rtl/WeightRam.sv \
    spikenaut-core-sv/rtl/NeuronParamRam.sv \
    spikenaut-core-sv/rtl/StdpController.sv \
    spikenaut-soc-sv/rtl/Basys3_Top.sv \
    spikenaut-soc-sv/tb/tb_Basys3_Top.sv \
  && ./obj_dir/Vtb_spikenaut_soc_basys3_top; then
  record "verilator/tb_spikenaut_soc_basys3_top" "PASS"
else
  record "verilator/tb_spikenaut_soc_basys3_top" "FAIL"
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

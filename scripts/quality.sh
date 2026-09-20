#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# quality.sh — local free-stack quality entrypoint (epic #23 Phase A3)
#
# Usage:
#   ./scripts/quality.sh              # guardian + core/bridge/SoC Verilator TBs
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

VERILATOR_FLAGS=(--binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD)
TBS=(
  "LifNeuron:LifNeuron"
  "LifNeuron_golden:LifNeuron"
  "LifNeuronArray:LifNeuronArray"
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

# tb_StdpWriteback needs WeightRam + StdpController + StdpWriteback, so it
# does not fit the single-DUT TBS loop above.
echo ""
echo "=== Verilator tb_StdpWriteback ==="
rm -rf obj_dir
if verilator "${VERILATOR_FLAGS[@]}" \
    --top-module tb_StdpWriteback \
    -Ispikenaut-core-sv/rtl \
    spikenaut-core-sv/rtl/WeightRam.sv \
    spikenaut-core-sv/rtl/StdpController.sv \
    spikenaut-core-sv/rtl/StdpWriteback.sv \
    spikenaut-core-sv/tb/tb_StdpWriteback.sv \
  && ./obj_dir/Vtb_StdpWriteback; then
  record "verilator/tb_StdpWriteback" "PASS"
else
  record "verilator/tb_StdpWriteback" "FAIL"
fi

# tb_OutputLayer needs two DUT files (it drives a real WeightRam), so it does
# not fit the single-DUT TBS loop above.
echo ""
echo "=== Verilator tb_OutputLayer ==="
rm -rf obj_dir
if verilator "${VERILATOR_FLAGS[@]}" \
    --top-module tb_OutputLayer \
    -Ispikenaut-core-sv/rtl \
    spikenaut-core-sv/rtl/WeightRam.sv \
    spikenaut-core-sv/rtl/OutputLayer.sv \
    spikenaut-core-sv/tb/tb_OutputLayer.sv \
  && ./obj_dir/Vtb_OutputLayer; then
  record "verilator/tb_OutputLayer" "PASS"
else
  record "verilator/tb_OutputLayer" "FAIL"
fi

echo ""
echo "=== Verilator tb_OutputLayer_golden ==="
rm -rf obj_dir
if verilator "${VERILATOR_FLAGS[@]}" \
    --top-module tb_OutputLayer_golden \
    -Ispikenaut-core-sv/rtl \
    spikenaut-core-sv/rtl/WeightRam.sv \
    spikenaut-core-sv/rtl/OutputLayer.sv \
    spikenaut-core-sv/tb/tb_OutputLayer_golden.sv \
  && ./obj_dir/Vtb_OutputLayer_golden; then
  record "verilator/tb_OutputLayer_golden" "PASS"
else
  record "verilator/tb_OutputLayer_golden" "FAIL"
fi

BRIDGE_TBS=(UartRx UartTx SiliconBridge)
for tb in "${BRIDGE_TBS[@]}"; do
  echo ""
  echo "=== Verilator tb_${tb} ==="
  rm -rf obj_dir
  sources=(
    --top-module "tb_${tb}"
    -Ispikenaut-bridge-sv/rtl
  )
  case "$tb" in
    UartRx)
      sources+=(spikenaut-bridge-sv/rtl/UartRx.sv)
      ;;
    UartTx)
      sources+=(spikenaut-bridge-sv/rtl/UartTx.sv)
      ;;
    SiliconBridge)
      sources+=(
        spikenaut-bridge-sv/rtl/UartRx.sv
        spikenaut-bridge-sv/rtl/UartTx.sv
        spikenaut-bridge-sv/rtl/SiliconBridge.sv
      )
      ;;
  esac
  sources+=("spikenaut-bridge-sv/tb/tb_${tb}.sv")
  if verilator "${VERILATOR_FLAGS[@]}" "${sources[@]}" \
    && "./obj_dir/Vtb_${tb}"; then
    record "verilator/tb_${tb}" "PASS"
  else
    record "verilator/tb_${tb}" "FAIL"
  fi
done

echo ""
echo "=== Verilator tb_SocProtocolFsm ==="
rm -rf obj_dir
if verilator "${VERILATOR_FLAGS[@]}" \
    --top-module tb_SocProtocolFsm \
    -Ispikenaut-soc-sv/rtl \
    spikenaut-soc-sv/rtl/SocProtocolFsm.sv \
    spikenaut-soc-sv/tb/tb_SocProtocolFsm.sv \
  && ./obj_dir/Vtb_SocProtocolFsm; then
  record "verilator/tb_SocProtocolFsm" "PASS"
else
  record "verilator/tb_SocProtocolFsm" "FAIL"
fi

echo ""
echo "=== Verilator tb_SocStatusLeds ==="
rm -rf obj_dir
if verilator "${VERILATOR_FLAGS[@]}" \
    --top-module tb_SocStatusLeds \
    -Ispikenaut-soc-sv/rtl \
    spikenaut-soc-sv/rtl/SocStatusLeds.sv \
    spikenaut-soc-sv/tb/tb_SocStatusLeds.sv \
  && ./obj_dir/Vtb_SocStatusLeds; then
  record "verilator/tb_SocStatusLeds" "PASS"
else
  record "verilator/tb_SocStatusLeds" "FAIL"
fi

echo ""
echo "=== Verilator tb_SocFrameGolden ==="
# GH#64: replays the committed golden 33-byte request / 36-byte response frame
# pairs through the real SocProtocolFsm. Golden .mem paths are repo-root
# relative, and this script already cd'd to the repo root.
rm -rf obj_dir
if verilator "${VERILATOR_FLAGS[@]}" \
    --top-module tb_SocFrameGolden \
    -Ispikenaut-soc-sv/rtl \
    spikenaut-soc-sv/rtl/SocProtocolFsm.sv \
    spikenaut-soc-sv/tb/tb_SocFrameGolden.sv \
  && ./obj_dir/Vtb_SocFrameGolden; then
  record "verilator/tb_SocFrameGolden" "PASS"
else
  record "verilator/tb_SocFrameGolden" "FAIL"
fi

echo ""
echo "=== Verilator tb_spikenaut_soc_basys3_top ==="
# SoC-level TB: the only sim that exercises the 1 ms step_en divider and the
# UART-frame -> tick-domain handoff (#57 / #60 / #62). Needs lib_bridge + lib_core +
# lib_soc in dependency order, and repo-root CWD for the $readmemh INIT paths.
rm -rf obj_dir
if verilator "${VERILATOR_FLAGS[@]}" \
    --top-module tb_spikenaut_soc_basys3_top \
    -Ispikenaut-core-sv/rtl -Ispikenaut-bridge-sv/rtl \
    spikenaut-bridge-sv/rtl/UartRx.sv \
    spikenaut-bridge-sv/rtl/UartTx.sv \
    spikenaut-bridge-sv/rtl/SiliconBridge.sv \
    spikenaut-core-sv/rtl/LifNeuron.sv \
    spikenaut-core-sv/rtl/LifNeuronArray.sv \
    spikenaut-core-sv/rtl/WeightRam.sv \
    spikenaut-core-sv/rtl/NeuronParamRam.sv \
    spikenaut-core-sv/rtl/StdpController.sv \
    spikenaut-core-sv/rtl/StdpWriteback.sv \
    spikenaut-core-sv/rtl/OutputLayer.sv \
    spikenaut-soc-sv/rtl/SocProtocolFsm.sv \
    spikenaut-soc-sv/rtl/SocStatusLeds.sv \
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

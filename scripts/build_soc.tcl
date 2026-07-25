# SPDX-License-Identifier: MIT OR Apache-2.0
# build_soc.tcl
# Vivado build script for the SoC targeting Basys 3
#
# Library ownership (compile order matters):
#   lib_bridge  <- spikenaut-bridge-sv/rtl
#   lib_core    <- spikenaut-core-sv/rtl        (NO copies in soc-sv/rtl)
#   lib_soc     <- spikenaut-soc-sv/rtl         (wrappers + spikenaut_soc_basys3_top only)
#
# Top module: spikenaut_soc_basys3_top
#
# Usage (Vivado Tcl console or batch mode):
#   vivado -mode batch -source scripts/build_soc.tcl

# ---------------------------------------------------------------------------
# 0. Project setup
# ---------------------------------------------------------------------------
set repo_root [file normalize [file join [file dirname [info script]] ..]]

set project_name  spikenaut_soc
set project_dir   [file join $repo_root vivado_projects $project_name]
set part          xc7a35tcpg236-1

create_project -force $project_name $project_dir -part $part

# ---------------------------------------------------------------------------
# Dependency tracing (gh-14 PR#1 Greptile comment 4186983425 / 5u3.8)
# All sources explicitly listed here (no implicit globs except constraints).
# Ownership per README.md canonical table (no duplicates allowed; core/bridge
# sourced ONLY from their lib dirs, never copied into soc-sv/rtl or examples).
# Full list (traced from build order + insts in Basys3_Top + XDC):
#   bridge: UartRx.sv UartTx.sv SiliconBridge.sv (spikenaut-bridge-sv/rtl)
#   core:   LifNeuron.sv WeightRam.sv NeuronParamRam.sv StdpController.sv (spikenaut-core-sv/rtl)
#   mem:    merged_v2_{weights,thresholds,decay}.mem (spikenaut-core-sv/mem) — E2 INIT
#   soc:    Basys3_Top.sv (spikenaut-soc-sv/rtl)  -- top=spikenaut_soc_basys3_top
#   xdc:    constraints/basys3.xdc (used by both tops)
# See also sim_core.tcl, dedup greps in README, and headers in each .sv.
# To evolve: could source a manifest .f file, but explicit lists + comments kept simple.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. lib_bridge  –  spikenaut-bridge-sv/rtl
# ---------------------------------------------------------------------------
set bridge_rtl [file join $repo_root spikenaut-bridge-sv rtl]

read_verilog -sv [list \
    [file join $bridge_rtl UartRx.sv]      \
    [file join $bridge_rtl UartTx.sv]      \
    [file join $bridge_rtl SiliconBridge.sv] \
]

# ---------------------------------------------------------------------------
# 2. lib_core  –  spikenaut-core-sv/rtl
#    All four canonical modules live here and ONLY here.
#    spikenaut-soc-sv/rtl does NOT contain these files.
# ---------------------------------------------------------------------------
set core_rtl [file join $repo_root spikenaut-core-sv rtl]

read_verilog -sv [list \
    [file join $core_rtl LifNeuron.sv]       \
    [file join $core_rtl WeightRam.sv]       \
    [file join $core_rtl NeuronParamRam.sv]  \
    [file join $core_rtl StdpController.sv]  \
]

# ---------------------------------------------------------------------------
# 3. lib_soc  –  spikenaut-soc-sv/rtl
#    Only SoC wrappers and the renamed top module.
# ---------------------------------------------------------------------------
set soc_rtl [file join $repo_root spikenaut-soc-sv rtl]

read_verilog -sv [list \
    [file join $soc_rtl Basys3_Top.sv]   \
]

# ---------------------------------------------------------------------------
# 3b. E2 / #39 — merged_v2 .mem images for $readmemh BRAM init
#     Paths: absolute generics so synth works even if CWD drifts; add_files
#     keeps Vivado dependency-aware. Run batch from repo root still preferred.
# ---------------------------------------------------------------------------
set core_mem [file join $repo_root spikenaut-core-sv mem]
set weight_mem [file join $core_mem merged_v2_weights.mem]
set thresh_mem [file join $core_mem merged_v2_thresholds.mem]
set decay_mem  [file join $core_mem merged_v2_decay.mem]

foreach mem_f [list $weight_mem $thresh_mem $decay_mem] {
    if {![file isfile $mem_f]} {
        error "build_soc.tcl: missing mem image: $mem_f"
    }
}
add_files -norecurse [list $weight_mem $thresh_mem $decay_mem]
set_property file_type {Memory Initialization Files} [get_files $weight_mem]
set_property file_type {Memory Initialization Files} [get_files $thresh_mem]
set_property file_type {Memory Initialization Files} [get_files $decay_mem]

# ---------------------------------------------------------------------------
# 4. Constraints
# ---------------------------------------------------------------------------
read_xdc [file join $repo_root constraints basys3.xdc]

# ---------------------------------------------------------------------------
# 5. Synthesis
# ---------------------------------------------------------------------------
set_property top spikenaut_soc_basys3_top [current_fileset]
# Override INIT paths with absolute paths (Vivado $readmemh resolution).
synth_design -top spikenaut_soc_basys3_top -part $part \
    -generic "WEIGHT_INIT_FILE=\"$weight_mem\"" \
    -generic "THRESH_INIT_FILE=\"$thresh_mem\"" \
    -generic "LEAK_INIT_FILE=\"$decay_mem\""

# ---------------------------------------------------------------------------
# 6. Implementation
# ---------------------------------------------------------------------------
opt_design
place_design
route_design

# ---------------------------------------------------------------------------
# 7. Reports (utilization + timing for CI gating)
# ---------------------------------------------------------------------------
set output_dir [file join $project_dir output]
file mkdir $output_dir
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_summary.rpt]

# ---------------------------------------------------------------------------
# 8. Bitstream
# ---------------------------------------------------------------------------
write_bitstream -force [file join $output_dir ${project_name}.bit]

puts "=== build_soc.tcl complete: bitstream written to $output_dir ==="
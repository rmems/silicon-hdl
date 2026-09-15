# SPDX-License-Identifier: MIT OR Apache-2.0
# sim_core.tcl
# Vivado simulation script for the core unit testbenches plus the SoC-level
# testbench (#57 / #60).
#
# Library ownership:
#   lib_bridge  <- spikenaut-bridge-sv/rtl
#   lib_core    <- spikenaut-core-sv/rtl
#   lib_soc     <- spikenaut-soc-sv/rtl
#   lib_tb_core <- spikenaut-core-sv/tb + spikenaut-bridge-sv/tb + spikenaut-soc-sv/tb
#
# Usage (Vivado Tcl console or batch mode):
#   vivado -mode batch -source scripts/sim_core.tcl

# ---------------------------------------------------------------------------
# 0. Project setup
# ---------------------------------------------------------------------------
set repo_root [file normalize [file join [file dirname [info script]] ..]]

set project_name  spikenaut_sim_core
set project_dir   [file join $repo_root vivado_projects $project_name]
set part          xc7a35tcpg236-1

# Vivado 2026.1 rejects legacy -ip/-rtl_kernel boolean flags on create_project.
create_project -force $project_name $project_dir -part $part

set_property simulator_language Mixed [current_project]

# ---------------------------------------------------------------------------
# 1. lib_bridge  –  spikenaut-bridge-sv/rtl  (needed by some core TBs)
# ---------------------------------------------------------------------------
set bridge_rtl [file join $repo_root spikenaut-bridge-sv rtl]

read_verilog -sv [list \
    [file join $bridge_rtl UartRx.sv]        \
    [file join $bridge_rtl UartTx.sv]        \
    [file join $bridge_rtl SiliconBridge.sv] \
]

# ---------------------------------------------------------------------------
# 2. lib_core  –  spikenaut-core-sv/rtl (canonical, single copy)
# ---------------------------------------------------------------------------
set core_rtl [file join $repo_root spikenaut-core-sv rtl]

read_verilog -sv [list \
    [file join $core_rtl LifNeuron.sv]      \
    [file join $core_rtl LifNeuronArray.sv] \
    [file join $core_rtl WeightRam.sv]      \
    [file join $core_rtl NeuronParamRam.sv] \
    [file join $core_rtl StdpController.sv] \
    [file join $core_rtl StdpWriteback.sv]  \
    [file join $core_rtl OutputLayer.sv]    \
]

# ---------------------------------------------------------------------------
# 2b. lib_soc  –  spikenaut-soc-sv/rtl (top-level wrapper; #57 / #60)
# ---------------------------------------------------------------------------
# Needed by the SoC-level testbench, which is the only sim that exercises the
# 1 ms step_en divider and the UART-frame -> tick-domain handoff.
set soc_rtl [file join $repo_root spikenaut-soc-sv rtl]

read_verilog -sv [list \
    [file join $soc_rtl SocProtocolFsm.sv] \
    [file join $soc_rtl SocStatusLeds.sv] \
    [file join $soc_rtl Basys3_Top.sv] \
]

# ---------------------------------------------------------------------------
# 3. lib_tb_core  –  unit + SoC testbenches (#58 adds bridge TBs)
# ---------------------------------------------------------------------------
set core_tb   [file join $repo_root spikenaut-core-sv tb]
set bridge_tb [file join $repo_root spikenaut-bridge-sv tb]
set soc_tb    [file join $repo_root spikenaut-soc-sv tb]

# Add all testbench files in tb/ if any exist
foreach tb_dir [list $core_tb $bridge_tb $soc_tb] {
    if {[llength [glob -nocomplain [file join $tb_dir *.sv]]] > 0} {
        read_verilog -sv [glob [file join $tb_dir *.sv]]
    }
}

# ---------------------------------------------------------------------------
# 4. Run each unit testbench in turn
# ---------------------------------------------------------------------------
# (gh-14 5u3.8 addressed by making it run multiple; origin/main has the list
# from #11 + testbenches added.)
set core_tb_tops {tb_LifNeuron tb_LifNeuron_golden tb_LifNeuronArray tb_WeightRam tb_WeightRam_init tb_NeuronParamRam tb_NeuronParamRam_init tb_StdpController tb_StdpWriteback tb_OutputLayer tb_OutputLayer_golden tb_UartRx tb_UartTx tb_SiliconBridge tb_SocProtocolFsm tb_SocFrameGolden tb_SocStatusLeds tb_spikenaut_soc_basys3_top}

set mem_dir    [file join $repo_root spikenaut-core-sv mem]
# GH#66 golden vectors (generated; see docs/golden-lif-vectors.md).
set golden_dir [file join $mem_dir golden]

foreach tb_top $core_tb_tops {
    set_property top $tb_top [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]

    # INIT TBs: XSim CWD is the sim run directory, so pass absolute INIT paths
    # (repo-root-relative defaults work for Verilator only).
    if {$tb_top eq "tb_WeightRam_init"} {
        set_property generic "INIT=[file normalize [file join $mem_dir merged_v2_weights.mem]]" [get_filesets sim_1]
    } elseif {$tb_top eq "tb_NeuronParamRam_init"} {
        set_property generic "INIT=[file normalize [file join $mem_dir merged_v2_thresholds.mem]]" [get_filesets sim_1]
    } elseif {$tb_top eq "tb_OutputLayer"} {
        # #72 output-weight bank regression $readmemh's the shipped bank directly.
        set_property generic "INIT_FILE=[file normalize [file join $mem_dir merged_v2_output_weights.mem]]" [get_filesets sim_1]
    } elseif {$tb_top eq "tb_LifNeuron_golden"} {
        # GH#66 golden vectors. Every image is read by absolute path because
        # XSim's CWD is the sim run dir, not the repo root.
        set_property generic [list \
            "WEIGHT_FILE=[file normalize [file join $golden_dir lif_golden_weights.mem]]" \
            "THRESHOLD_FILE=[file normalize [file join $golden_dir lif_golden_thresholds.mem]]" \
            "LEAK_FILE=[file normalize [file join $golden_dir lif_golden_leaks.mem]]" \
            "SPIKE_IN_FILE=[file normalize [file join $golden_dir lif_golden_spike_in.mem]]" \
            "RESET_FILE=[file normalize [file join $golden_dir lif_golden_reset.mem]]" \
            "EXP_MEM_FILE=[file normalize [file join $golden_dir lif_golden_exp_membrane.mem]]" \
            "EXP_SPIKE_FILE=[file normalize [file join $golden_dir lif_golden_exp_spike.mem]]" \
            "COUNT_FILE=[file normalize [file join $golden_dir lif_golden_count.mem]]" \
        ] [get_filesets sim_1]
    } elseif {$tb_top eq "tb_OutputLayer_golden"} {
        set_property generic [list \
            "INIT_FILE=[file normalize [file join $mem_dir merged_v2_output_weights.mem]]" \
            "BITMAP_FILE=[file normalize [file join $golden_dir outlayer_golden_bitmap.mem]]" \
            "RESULT_FILE=[file normalize [file join $golden_dir outlayer_golden_exp_result.mem]]" \
            "COUNT_FILE=[file normalize [file join $golden_dir outlayer_golden_count.mem]]" \
        ] [get_filesets sim_1]
    } elseif {$tb_top eq "tb_SocFrameGolden"} {
        # GH#64 golden UART frame vectors, absolute for the same reason.
        set_property generic [list \
            "COUNT_FILE=[file normalize [file join $golden_dir frame_golden_count.mem]]" \
            "HOST_TX_FILE=[file normalize [file join $golden_dir frame_golden_host_tx.mem]]" \
            "SOC_RX_FILE=[file normalize [file join $golden_dir frame_golden_soc_rx.mem]]" \
            "STIMULI_FILE=[file normalize [file join $golden_dir frame_golden_stimuli.mem]]" \
            "POTENTIALS_FILE=[file normalize [file join $golden_dir frame_golden_potentials.mem]]" \
            "SPIKES_FILE=[file normalize [file join $golden_dir frame_golden_spikes.mem]]" \
            "AUX_FILE=[file normalize [file join $golden_dir frame_golden_aux.mem]]" \
        ] [get_filesets sim_1]
    } elseif {$tb_top eq "tb_spikenaut_soc_basys3_top"} {
        set_property generic [list \
            "WEIGHT_INIT=[file normalize [file join $mem_dir merged_v2_weights.mem]]" \
            "THRESH_INIT=[file normalize [file join $mem_dir merged_v2_thresholds.mem]]" \
            "LEAK_INIT=[file normalize [file join $mem_dir merged_v2_decay.mem]]" \
            "OUTPUT_WEIGHT_INIT=[file normalize [file join $mem_dir merged_v2_output_weights.mem]]" \
        ] [get_filesets sim_1]
    } elseif {$tb_top eq "tb_LifNeuronArray"} {
        # #92 bank-data regression $readmemh's the shipped bank directly.
        set_property generic [list \
            "SHIPPED_WEIGHT_MEM=[file normalize [file join $mem_dir merged_v2_weights.mem]]" \
            "SHIPPED_THRESHOLD_MEM=[file normalize [file join $mem_dir merged_v2_thresholds.mem]]" \
            "SHIPPED_DECAY_MEM=[file normalize [file join $mem_dir merged_v2_decay.mem]]" \
        ] [get_filesets sim_1]
    } else {
        # Clear any leftover generic from a prior top in this loop.
        catch {set_property generic {} [get_filesets sim_1]}
    }

    # Force re-elaboration when switching top modules to avoid stale
    # compilation artifacts / dirty directory issues in the sim fileset.
    # catch() guards the first iteration where the run may not exist yet.
    catch {reset_run sim_1}
    launch_simulation
    # run -all, NOT a fixed window.  Every TB top in core_tb_tops terminates
    # itself with exactly one $finish (or aborts on $fatal), so -all always
    # returns.  A fixed cap is actively unsafe here: XSim stops at the cap
    # without any error, so a TB that needs longer than the window is silently
    # truncated mid-run and the job still reports success.  That happened --
    # tb_SocFrameGolden needs 23.7us and was cut off by the previous 10us cap
    # after printing only its opening banner, so its assertions never ran under
    # Vivado while CI stayed green.  Sizing per-TB caps by hand just moves the
    # trap to the next testbench.  If a future TB does hang, -all fails loudly
    # against the job timeout instead of passing quietly, and the Verilator job
    # on the same PR catches it far sooner.
    run -all
    close_sim
}

puts "=== sim_core.tcl complete ==="

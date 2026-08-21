// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_Basys3_Top.sv
// SoC-level testbench for spikenaut-soc-sv/rtl/Basys3_Top.sv
// (top module spikenaut_soc_basys3_top).
//
// Covers what the core unit testbenches structurally cannot: they drive
// step_en themselves, so nothing else in the repo exercises the SoC's own
// 1 ms divider or the UART-event -> tick-domain handoff. See #57 / #60 and
// docs/timestep-contract.md.
//
// What this locks down:
//   1. Reset phase       — step_cnt / step_en / spike_pending clear.
//   2. First-tick delay  — exactly STEP_DIV cycles after reset release.
//   3. Pulse width       — step_en high for exactly one fabric cycle.
//   4. Period            — exactly STEP_DIV cycles between every tick.
//   5. Event delivery    — a UART byte arriving between ticks still reaches
//                          the N=16 LIF PE on the next tick (regression test: with
//                          rx_valid wired straight to spike_in, the one-cycle
//                          strobe missed the tick and the byte was dropped).
//   6. Decay             — with no event, the membrane leaks back to 0.
//
// (2)-(4) are checked by a free-running monitor on EVERY tick of the run, not
// just at sampled points, so an intermittent divider glitch cannot slip past.
//
// Internal nodes (step_en, step_cnt, spike_pending, PE membrane register file,
// and RAM address outputs) are
// observed by hierarchical reference rather than by adding debug ports to the
// synthesized top level.
//
// Reset polarity: the rst_n PORT is the physically active-high BTNC button
// (U18/CPU_RESET) and is inverted to the active-low `rst` inside the DUT, so
// this TB asserts reset by driving btn_rst = 1 and releases it with 0.
//
// $readmemh INIT_FILE paths are repo-root relative — run from the repo root.
//
// Stimulus is applied and sampled on negedge clk (mid-cycle) to avoid race
// conditions with the DUT's posedge-triggered always_ff blocks.

`timescale 1ns/1ps

// The INIT paths are module parameters so Vivado sim_core.tcl can pass absolute
// paths via set_property generic (XSim CWD is the sim run dir, not the repo
// root). Defaults are repo-root-relative for Verilator, matching the DUT's own
// defaults and tb_WeightRam_init / tb_NeuronParamRam_init.
module tb_spikenaut_soc_basys3_top #(
    parameter string WEIGHT_INIT = "spikenaut-core-sv/mem/merged_v2_weights.mem",
    parameter string THRESH_INIT = "spikenaut-core-sv/mem/merged_v2_thresholds.mem",
    parameter string LEAK_INIT   = "spikenaut-core-sv/mem/merged_v2_decay.mem"
);

    localparam int CLK_PERIOD   = 10;                     // 100 MHz
    localparam int CLK_FREQ     = 100_000_000;
    localparam int BAUD_RATE    = 115_200;
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;   // 868
    localparam int TICK_HZ      = 1000;
    localparam int STEP_DIV     = CLK_FREQ / TICK_HZ;     // 100_000
    localparam int NUM_NEURONS  = 16;

    // Test 5 timing budget: the UART byte is sent right after a tick, and its
    // frame plus the spike_pending hold window must complete before the NEXT
    // tick, or the hold assertion would race the tick that consumes the event.
    // Guarded at elaboration (same idiom as LifNeuron's width guard) so a
    // future change to BAUD_RATE, TICK_HZ, or HOLD_CYCLES fails loudly here
    // instead of surfacing as a confusing assertion failure mid-run.
    // SEQ_SLACK covers the handful of sequencing negedges around the checks.
    localparam int UART_FRAME_CYCLES = 10 * CLKS_PER_BIT; // 8N1: start+8+stop
    localparam int HOLD_CYCLES       = 2000;
    localparam int SEQ_SLACK         = 16;

    // Ticks are at most STEP_DIV cycles apart, so any wait that exceeds this
    // bound means the divider is broken. Fail loudly with a cycle count
    // instead of hanging until an external job timeout with no diagnostic.
    localparam int TICK_WAIT_BOUND   = STEP_DIV + SEQ_SLACK;
    generate
        if (UART_FRAME_CYCLES + HOLD_CYCLES + SEQ_SLACK >= STEP_DIV)
            $error("tb_spikenaut_soc_basys3_top: test 5 budget blown: frame (%0d) + hold (%0d) + slack (%0d) must be < STEP_DIV (%0d)",
                   UART_FRAME_CYCLES, HOLD_CYCLES, SEQ_SLACK, STEP_DIV);
    endgenerate

    logic        clk;
    logic        btn_rst;        // drives the active-high rst_n port
    logic        uart_rx_line;
    logic        uart_tx_line;
    logic [15:0] led;

    int errors = 0;
    int unsigned first_tick_cycles;
    logic [NUM_NEURONS-1:0] expected_first_spikes;
    logic [NUM_NEURONS-1:0] seen_threshold_addr;
    logic [NUM_NEURONS-1:0] seen_leak_addr;
    logic [NUM_NEURONS-1:0] seen_weight_row;
    logic                    track_sweep_addresses;

    spikenaut_soc_basys3_top #(
        .WEIGHT_INIT_FILE (WEIGHT_INIT),
        .THRESH_INIT_FILE (THRESH_INIT),
        .LEAK_INIT_FILE   (LEAK_INIT)
    ) dut (
        .clk     (clk),
        .rst_n   (btn_rst),
        .uart_rx (uart_rx_line),
        .uart_tx (uart_tx_line),
        .led     (led)
    );

    // Clock generation
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic check(input logic cond, input string msg);
        if ($isunknown(cond)) begin
            errors++;
            $display("FAIL (unknown state): %s", msg);
        end else if (!cond) begin
            errors++;
            $display("FAIL: %s", msg);
        end
    endtask

    task automatic check_int(input int unsigned actual,
                             input int unsigned expected,
                             input string msg);
        if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (expected %0d, got %0d)", msg, expected, actual);
        end
    endtask

    // ----------------------------------------------------------------
    // Free-running step_en monitor (tests 3-4)
    //
    // Checks pulse width and tick-to-tick period on EVERY tick of the run.
    // Both are deltas, so they are immune to which delta the monitor happened
    // to start counting in. The absolute first-tick latency (test 2) is
    // measured in the main sequence instead, where it is race-free.
    // ----------------------------------------------------------------
    int unsigned cyc;             // free-running fabric-cycle counter
    int unsigned last_tick_cyc;
    int unsigned tick_count;
    int unsigned width_run;

    initial begin
        cyc           = 0;
        last_tick_cyc = 0;
        tick_count    = 0;
        width_run     = 0;
    end

    always @(negedge clk) begin
        cyc++;
        if (dut.step_en === 1'b1) begin
            width_run++;
            tick_count++;
            if (tick_count > 1)
                check_int(cyc - last_tick_cyc, STEP_DIV,
                          "step_en period must be exactly STEP_DIV");
            last_tick_cyc = cyc;
        end else if (width_run != 0) begin
            check_int(width_run, 1, "step_en must be exactly one cycle wide");
            width_run = 0;
        end
    end

    // Observe the RAM addresses sampled at posedge.  During an N=16 PE sweep
    // all parameter entries and all output-neuron rows (input column 0 in the
    // current binary-event demo) must be reached.
    always @(posedge clk) begin
        if (track_sweep_addresses && dut.rst) begin
            if (dut.threshold_addr < NUM_NEURONS)
                seen_threshold_addr[dut.threshold_addr[3:0]] = 1'b1;
            if (dut.leak_addr < NUM_NEURONS)
                seen_leak_addr[dut.leak_addr[3:0]] = 1'b1;
            for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
                if (dut.weight_addr == neuron * NUM_NEURONS)
                    seen_weight_row[neuron] = 1'b1;
            end
        end
    end

    // Send one 8N1 byte, LSB first, at BAUD_RATE. Idle line is high.
    task automatic uart_send_byte(input logic [7:0] b);
        int i;
        begin
            uart_rx_line = 1'b0;                       // start bit
            repeat (CLKS_PER_BIT) @(negedge clk);
            for (i = 0; i < 8; i++) begin
                uart_rx_line = b[i];
                repeat (CLKS_PER_BIT) @(negedge clk);
            end
            uart_rx_line = 1'b1;                       // stop bit
            repeat (CLKS_PER_BIT) @(negedge clk);
        end
    endtask

    // Advance to the negedge at which step_en reads high. step_en is a
    // register set at posedge P, so at this point the tick is still "in
    // flight" — the cores consume it at posedge P+1. Bounded: $fatal if no
    // tick arrives within TICK_WAIT_BOUND cycles (broken divider).
    task automatic wait_for_tick();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.step_en === 1'b1) break;
                if (waited >= TICK_WAIT_BOUND)
                    $fatal(1, "wait_for_tick: no step_en within %0d cycles (bound %0d)",
                           waited, TICK_WAIT_BOUND);
            end
        end
    endtask

    // Advance past the posedge that actually applies the tick, so the cores'
    // post-tick state (membrane_potential, spike_pending) is observable.
    task automatic wait_tick_applied();
        begin
            wait_for_tick();
            @(negedge clk);
        end
    endtask

    // `step_en` starts the PE; its registered RAM read and 16 slots complete
    // shortly afterward.  Bound this wait so a bad sub-cycle FSM does not
    // turn the free CI test into a silent timeout.
    task automatic wait_lif_sweep_done();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.u_lif_array.tick_done === 1'b1) break;
                if (waited > NUM_NEURONS + 2)
                    $fatal(1, "wait_lif_sweep_done: no tick_done within %0d cycles", waited);
            end
        end
    endtask

    initial begin
        // ------------------------------------------------------------
        // Test 1: reset phase
        // ------------------------------------------------------------
        btn_rst      = 1'b1;    // active-high button pressed => DUT in reset
        uart_rx_line = 1'b1;    // UART idle
        track_sweep_addresses = 1'b0;
        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        repeat (5) @(negedge clk);

        check(dut.step_en === 1'b0,       "reset: step_en must be low");
        check(dut.step_cnt === '0,        "reset: step_cnt must be cleared");
        check(dut.spike_pending === 1'b0, "reset: spike_pending must be cleared");
        check(led === 16'h0000,           "reset: led must be cleared");

        // ------------------------------------------------------------
        // Test 2: first tick lands exactly STEP_DIV cycles after release
        //
        // Counted here rather than in the monitor so the measurement is a
        // single-process, race-free sequence: reset is released at this
        // negedge, and the loop below starts counting at the next one.
        // ------------------------------------------------------------
        btn_rst = 1'b0;
        first_tick_cycles = 0;
        forever begin
            @(negedge clk);
            first_tick_cycles++;
            if (dut.step_en === 1'b1) break;
            if (first_tick_cycles >= TICK_WAIT_BOUND)
                $fatal(1, "first tick: no step_en within %0d cycles of reset release (bound %0d)",
                       first_tick_cycles, TICK_WAIT_BOUND);
        end
        check_int(first_tick_cycles, STEP_DIV,
                  "first step_en must be STEP_DIV cycles after reset release");

        // ------------------------------------------------------------
        // Tests 3-4 run in the monitor. Let two more clean ticks elapse.
        // ------------------------------------------------------------
        wait_tick_applied();
        wait_tick_applied();
        check_int(tick_count, 3, "monitor must have observed three ticks");

        // No UART event has been delivered yet, so every PE slot must be idle.
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            check_int(dut.u_lif_array.membrane_potential[neuron], 0,
                      "membrane must stay 0 while no spike event arrives");
        end

        // ------------------------------------------------------------
        // Test 5: a UART byte between ticks survives to the next tick
        //
        // Regression test for the dropped-event bug: rx_valid is one fabric
        // cycle wide and the PE starts only on step_en, so without the
        // spike_pending latch this byte never reaches the sweep.
        // ------------------------------------------------------------
        uart_send_byte(8'hA5);
        check(dut.spike_pending === 1'b1, "UART byte must set spike_pending");

        repeat (HOLD_CYCLES) @(negedge clk);
        check(dut.spike_pending === 1'b1,
              "spike_pending must hold until a tick consumes it");

        track_sweep_addresses = 1'b1;
        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        wait_tick_applied();
        check(dut.spike_pending === 1'b0, "step_en must consume spike_pending");
        wait_lif_sweep_done();
        track_sweep_addresses = 1'b0;

        expected_first_spikes = '0;
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            expected_first_spikes[neuron] =
                (dut.u_wram.mem[neuron * NUM_NEURONS] >= dut.u_npram_threshold.mem[neuron]);
            check(dut.u_lif_array.membrane_potential[neuron] ==
                  dut.u_wram.mem[neuron * NUM_NEURONS],
                  "broadcast event must integrate each neuron row's input-column-0 weight");
        end
        check(led === expected_first_spikes,
              "LED bitmap must equal the merged_v2 per-neuron threshold outcomes");
        check(expected_first_spikes === 16'h0000,
              "merged_v2 input-column-0 weights are below every per-neuron threshold");
        check(seen_threshold_addr == {NUM_NEURONS{1'b1}},
              "PE sweep must request all 16 threshold RAM entries");
        check(seen_leak_addr == {NUM_NEURONS{1'b1}},
              "PE sweep must request all 16 leak RAM entries");
        check(seen_weight_row == {NUM_NEURONS{1'b1}},
              "PE sweep must request all 16 input-column-0 weight rows");

        // ------------------------------------------------------------
        // Test 6: with no further event, every neuron applies its own leak.
        // ------------------------------------------------------------
        wait_tick_applied();
        wait_lif_sweep_done();
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            if (expected_first_spikes[neuron])
                check_int(dut.u_lif_array.membrane_potential[neuron], 0,
                          "a prior spike must reset that row on the next tick");
            else if (dut.u_wram.mem[neuron * NUM_NEURONS] > dut.u_npram_leak.mem[neuron])
                check(dut.u_lif_array.membrane_potential[neuron] ==
                      (dut.u_wram.mem[neuron * NUM_NEURONS] - dut.u_npram_leak.mem[neuron]),
                      "each non-spiking row must use its own leak value");
            else
                check_int(dut.u_lif_array.membrane_potential[neuron], 0,
                          "leak must floor each row's membrane at zero");
        end

        // ------------------------------------------------------------
        // Test 7: LED bus exposes the full committed N=16 bitmap.
        // ------------------------------------------------------------
        check(led === 16'h0000,
              "merged_v2 no-input follow-up must clear the complete LED bitmap");
        $display("TB_BASYS3_TOP: merged_v2 swept all 16 parameter entries and weight rows");

        if (errors == 0) begin
            $display("TB_BASYS3_TOP: ALL TESTS PASSED (%0d ticks checked)", tick_count);
            $finish;
        end else begin
            $display("TB_BASYS3_TOP: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_BASYS3_TOP: testbench FAILED");
        end
    end

endmodule

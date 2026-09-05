// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_Basys3_Top.sv
// SoC-level testbench for spikenaut-soc-sv/rtl/Basys3_Top.sv
// (top module spikenaut_soc_basys3_top).
//
// Covers what the core unit testbenches structurally cannot: they drive
// step_en themselves, so nothing else in the repo exercises the SoC's own
// 1 ms divider or the UART-frame -> tick-domain handoff. See #57 / #60 / #62 and
// docs/timestep-contract.md.
//
// What this locks down:
//   1. Reset phase       — step_cnt / step_en / protocol pending state clear.
//   2. First-tick delay  — exactly STEP_DIV cycles after reset release.
//   3. Pulse width       — step_en high for exactly one fabric cycle.
//   4. Period            — exactly STEP_DIV cycles between every tick.
//   5. Frame delivery    — a complete 0xAA / 16-word UART frame is latched
//                          and reaches the N=16 LIF PE on the next tick.
//   6. Decay             — with no event, the membrane leaks back to 0.
//   7. Gated frame_send  — idle 1 ms ticks do not arm a UART response; a
//                          response fires only after a consumed host frame.
//
// (2)-(4) are checked by a free-running monitor on EVERY tick of the run, not
// just at sampled points, so an intermittent divider glitch cannot slip past.
//
// Internal nodes (step_en, step_cnt, protocol pending state, PE membrane
// register file, and RAM address outputs) are
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
    localparam int SPIKE_TEST_NEURON = 5;

    // A full host frame is 33 UART bytes.  It intentionally spans multiple
    // 1 ms ticks at 115200 baud; the protocol FSM must wait for all payload
    // bytes rather than turning early bytes into raw spikes.
    localparam int SEQ_SLACK         = 16;

    // Ticks are at most STEP_DIV cycles apart, so any wait that exceeds this
    // bound means the divider is broken. Fail loudly with a cycle count
    // instead of hanging until an external job timeout with no diagnostic.
    localparam int TICK_WAIT_BOUND   = STEP_DIV + SEQ_SLACK;
    logic        clk;
    logic        btn_rst;        // drives the active-high rst_n port
    logic        uart_rx_line;
    logic        uart_tx_line;
    logic [15:0] led;

    int errors = 0;
    int unsigned first_tick_cycles;
    int unsigned frame_send_count;
    logic [NUM_NEURONS-1:0] expected_first_spikes;
    logic [NUM_NEURONS-1:0] seen_threshold_addr;
    logic [NUM_NEURONS-1:0] seen_leak_addr;
    logic [NUM_NEURONS-1:0] seen_weight_row;
    logic [$clog2(NUM_NEURONS)-1:0] expected_input_index;

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
        if (dut.frame_send === 1'b1)
            frame_send_count++;
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

    // Host contract: 0xAA followed by 16 Q8.8 big-endian words.  One selected
    // lane carries 0x0001 and all others zero, making the SoC's binary-event
    // / input-column selection policy observable without a raw rx_valid hook.
    task automatic uart_send_stimulus_frame(input int active_lane);
        begin
            uart_send_byte(8'hAA);
            for (int lane = 0; lane < NUM_NEURONS; lane++) begin
                if (lane == active_lane) begin
                    uart_send_byte(8'h00);
                    uart_send_byte(8'h01);
                end else begin
                    uart_send_byte(8'h00);
                    uart_send_byte(8'h00);
                end
            end
        end
    endtask

    task automatic wait_for_stimuli_pending();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.stimuli_pending === 1'b1) break;
                if (waited > (2 * CLKS_PER_BIT + SEQ_SLACK))
                    $fatal(1, "wait_for_stimuli_pending: completed frame was not latched within %0d cycles", waited);
            end
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

    // Record the address presented for the next registered RAM read.  The
    // calling test sequence owns these maps, so coverage collection does not
    // depend on ordering between a separate monitor and the main process.
    task automatic record_sweep_addresses();
        begin
            if (dut.threshold_addr < NUM_NEURONS)
                seen_threshold_addr[dut.threshold_addr[3:0]] = 1'b1;
            if (dut.leak_addr < NUM_NEURONS)
                seen_leak_addr[dut.leak_addr[3:0]] = 1'b1;
            for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
                if (dut.weight_addr == neuron * NUM_NEURONS + expected_input_index)
                    seen_weight_row[neuron] = 1'b1;
            end
        end
    endtask

    // Advance past the posedge that actually applies the tick, so the cores'
    // post-tick state (membrane_potential, protocol pending state) is observable.
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
                record_sweep_addresses();
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
        frame_send_count    = 0;
        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        repeat (5) @(negedge clk);

        check(dut.step_en === 1'b0,       "reset: step_en must be low");
        check(dut.step_cnt === '0,        "reset: step_cnt must be cleared");
        check(dut.stimuli_pending === 1'b0,
              "reset: completed-frame pending state must be cleared");
        check(dut.response_armed === 1'b0,
              "reset: response_armed must be cleared");
        check(dut.frame_send === 1'b0,    "reset: frame_send must be low");
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
        check_int(frame_send_count, 0,
                  "idle ticks before any host frame must not arm frame_send");
        check(dut.u_protocol_fsm.tx_active === 1'b0,
              "idle ticks must not start a UART response");
        check(dut.bridge_tx_send === 1'b0,
              "idle ticks must not pulse SiliconBridge tx_send");

        // No UART event has been delivered yet, so every PE slot must be idle.
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            check(dut.u_lif_array.membrane_potential[neuron] === '0,
                  "membrane must stay 0 while no spike event arrives");
        end

        // ------------------------------------------------------------
        // Test 5: a complete UART frame reaches the next logical tick
        //
        // The 33-byte frame lasts longer than one tick at 115200 baud.  Its
        // early bytes must not produce a spike; only the completed frame may
        // arm one selected input column for the following step_en.
        // ------------------------------------------------------------
        expected_input_index = '0;
        uart_send_byte(8'hAA);
        uart_send_byte(8'h00);
        uart_send_byte(8'h01);
        check(dut.stimuli_pending === 1'b0,
              "partial UART frame must not have been consumed as a raw spike");
        for (int lane = 1; lane < NUM_NEURONS; lane++) begin
            uart_send_byte(8'h00);
            uart_send_byte(8'h00);
        end
        wait_for_stimuli_pending();
        check(dut.protocol_stimuli[0 +: 16] === 16'h0001,
              "protocol frame lane 0 must decode as big-endian Q8.8");
        for (int lane = 1; lane < NUM_NEURONS; lane++) begin
            check(dut.protocol_stimuli[lane*16 +: 16] === '0,
                  "inactive protocol lanes must retain their decoded zero words");
        end
        check(dut.stimulus_input_index === 4'd0,
              "lowest active protocol lane must select input column zero");
        check(dut.stimulus_event === 1'b1,
              "a completed non-zero stimulus frame must arm a binary PE event");

        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        // At this negedge step_en is high and the PE is still idle, so it
        // presents row 0 for the first registered RAM read.  The next
        // negedge observes the prefetched row 1 after the tick is applied.
        wait_for_tick();
        record_sweep_addresses();
        @(negedge clk);
        record_sweep_addresses();
        check(dut.stimuli_pending === 1'b0,
              "step_en must consume exactly one completed stimulus frame");
        check(dut.response_armed === 1'b1,
              "consuming a host frame must arm the post-sweep response");
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b1,
              "lif_tick_done after a consumed host frame must pulse frame_send");
        @(negedge clk); // let the free-running monitor retire this pulse
        check_int(frame_send_count, 1,
                  "exactly one response must be armed for the first consumed frame");

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
        check(dut.frame_send === 1'b0,
              "a leak-only tick must not re-arm frame_send");
        check_int(frame_send_count, 1,
                  "idle leak tick must not increment the gated response count");
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            if (expected_first_spikes[neuron])
                check(dut.u_lif_array.membrane_potential[neuron] === '0,
                      "a prior spike must reset that row on the next tick");
            else if (dut.u_wram.mem[neuron * NUM_NEURONS] > dut.u_npram_leak.mem[neuron])
                check(dut.u_lif_array.membrane_potential[neuron] ==
                      (dut.u_wram.mem[neuron * NUM_NEURONS] - dut.u_npram_leak.mem[neuron]),
                      "each non-spiking row must use its own leak value");
            else
                check(dut.u_lif_array.membrane_potential[neuron] === '0,
                      "leak must floor each row's membrane at zero");
        end

        // ------------------------------------------------------------
        // Test 7: a controlled model row selects a non-zero host frame lane,
        // creates a real PE spike, and verifies the one-tick refractory reset.
        // ------------------------------------------------------------
        // Test 5 above keeps its merged_v2 image assertions.  This controlled
        // row is deliberately configured only after those checks, so it
        // proves the PE's commit/refractory behavior without changing the
        // shipped-image coverage.
        dut.u_wram.mem[SPIKE_TEST_NEURON * NUM_NEURONS + SPIKE_TEST_NEURON] = 16'h0001;
        dut.u_npram_threshold.mem[SPIKE_TEST_NEURON]    = 16'h0001;
        dut.u_npram_leak.mem[SPIKE_TEST_NEURON]         = 16'h0000;
        expected_input_index = $clog2(NUM_NEURONS)'(SPIKE_TEST_NEURON);
        uart_send_stimulus_frame(SPIKE_TEST_NEURON);
        wait_for_stimuli_pending();
        check(dut.stimulus_input_index === SPIKE_TEST_NEURON,
              "non-zero protocol lane must select its matching matrix input column");
        check(dut.stimulus_event === 1'b1,
              "selected non-zero protocol lane must create the PE event");
        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b1,
              "second consumed host frame must arm another gated response");
        @(negedge clk); // let the free-running monitor retire this pulse
        check_int(frame_send_count, 2,
                  "each consumed host frame must arm exactly one response");
        check(dut.u_lif_array.spike_bitmap[SPIKE_TEST_NEURON] === 1'b1,
              "controlled row must commit a real spike bit");
        check(led[SPIKE_TEST_NEURON] === 1'b1,
              "controlled PE spike bit must reach its LED bit");

        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b0,
              "refractory follow-up tick must not re-arm frame_send");
        check_int(frame_send_count, 2,
                  "refractory follow-up tick must not increment the gated response count");
        check(dut.u_lif_array.membrane_potential[SPIKE_TEST_NEURON] === '0,
              "spiking row must reset to zero on the following refractory tick");

        // ------------------------------------------------------------
        // Test 8: LED bus preserves every committed N=16 bitmap bit.
        // ------------------------------------------------------------
        check(led === 16'h0000,
              "no-input refractory follow-up must clear the complete LED bitmap");
        force dut.spike_bitmap = 16'hA55A;
        #1;
        check(led === 16'hA55A,
              "LED bus must preserve every committed spike bitmap bit");
        release dut.spike_bitmap;
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

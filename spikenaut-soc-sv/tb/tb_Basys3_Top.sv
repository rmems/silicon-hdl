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
//   8. LED bitmap        — every committed N=16 spike bit is preserved (SW=0).
//   9. SW15 status mux   — 2FF sync latency, then status word from primitive
//                          refs; synchronized sw is published as aux.
//  11. Runtime RAM write — a 0xA5 host frame overwrites one INIT_FILE weight
//                          and one leak param; RAM we is not hard-tied 0.
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
    localparam int SW_SYNC_LATENCY   = 2;

    // Mirrors SocProtocolFsm's default: four 10-bit UART character times.
    // Derived from BAUD_RATE rather than a second inline 115_200, and checked
    // against the DUT's actual parameter at the top of the run -- test 10's
    // half-window waits depend on this matching, and a silent drift would move
    // the mid-window sample outside the idle window and quietly stop
    // discriminating rx_abort from rx_busy.
    localparam int IDLE_TIMEOUT_CYCLES = 4 * 10 * CLKS_PER_BIT;
    // Mirror SocProtocolFsm's default write sync.  Bound to the DUT at the
    // top of the run so a parameter change cannot silently desync this TB.
    localparam logic [7:0] WRITE_SYNC_BYTE = 8'hA5;

    // Ticks are at most STEP_DIV cycles apart, so any wait that exceeds this
    // bound means the divider is broken. Fail loudly with a cycle count
    // instead of hanging until an external job timeout with no diagnostic.
    localparam int TICK_WAIT_BOUND   = STEP_DIV + SEQ_SLACK;
    logic        clk;
    logic        btn_rst;        // drives the active-high rst_n port
    logic        uart_rx_line;
    logic        uart_tx_line;
    logic [15:0] sw;
    logic [15:0] led;

    int errors = 0;
    int unsigned first_tick_cycles;
    int unsigned frame_send_count;
    logic [NUM_NEURONS-1:0] expected_first_spikes;
    logic [NUM_NEURONS-1:0] seen_threshold_addr;
    logic [NUM_NEURONS-1:0] seen_leak_addr;
    logic [NUM_NEURONS-1:0] seen_weight_row;
    logic [$clog2(NUM_NEURONS)-1:0] expected_input_index;

    // Static copies for inject_host_strobe.  XSim rejects force/assign of
    // automatic task arguments (VRFC 10-3142); Verilator does not.
    logic [1:0]  force_host_wr_target;
    logic [7:0]  force_host_wr_addr;
    logic [15:0] force_host_wr_data;

    spikenaut_soc_basys3_top #(
        .WEIGHT_INIT_FILE (WEIGHT_INIT),
        .THRESH_INIT_FILE (THRESH_INIT),
        .LEAK_INIT_FILE   (LEAK_INIT)
    ) dut (
        .clk     (clk),
        .rst_n   (btn_rst),
        .uart_rx (uart_rx_line),
        .uart_tx (uart_tx_line),
        .sw      (sw),
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
    // Host write contract (#63): 0xA5 + target + addr + Q8.8 big-endian word.
    // Target 0=weight, 1=threshold, 2=leak. Distinct sync from the 0xAA
    // stimulus frame so the protocol FSM can share one byte pipe.
    // One-cycle host write strobe while the PE is busy.  Fabric-rate force
    // on the FSM outputs (same style as the LED bitmap force in test 8)
    // so the hold path can be tested inside the ~18-cycle sweep; UART
    // cannot finish a 5-byte frame in that window.
    task automatic inject_host_strobe(
        input logic [1:0] target,
        input logic [7:0] addr,
        input logic [15:0] data
    );
        begin
            force_host_wr_target = target;
            force_host_wr_addr   = addr;
            force_host_wr_data   = data;
            @(negedge clk);
            force dut.host_wr_en     = 1'b1;
            force dut.host_wr_target = force_host_wr_target;
            force dut.host_wr_addr   = force_host_wr_addr;
            force dut.host_wr_data   = force_host_wr_data;
            @(negedge clk);
            release dut.host_wr_en;
            release dut.host_wr_target;
            release dut.host_wr_addr;
            release dut.host_wr_data;
        end
    endtask

    task automatic uart_send_write_frame(
        input logic [7:0] target,
        input logic [7:0] addr,
        input logic [15:0] data
    );
        begin
            uart_send_byte(WRITE_SYNC_BYTE);
            uart_send_byte(target);
            uart_send_byte(addr);
            uart_send_byte(data[15:8]);
            uart_send_byte(data[7:0]);
        end
    endtask

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

    // Sample the one-cycle host write strobe mid-cycle while the UART
    // frame is still on the wire.  After uart_send_write_frame returns the
    // strobe has already fallen, so a later peek cannot prove we toggled.
    task automatic wait_for_host_write(
        input logic [1:0] expected_target,
        input string msg
    );
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.host_wr_en === 1'b1) begin
                    check(dut.host_wr_target === expected_target,
                          {msg, ": wr_target must match the frame"});
                    check(dut.weight_we === (expected_target == 2'd0),
                          {msg, ": weight we must follow target 0"});
                    check(dut.leak_we === (expected_target == 2'd2),
                          {msg, ": leak we must follow target 2"});
                    break;
                end
                if (waited > (5 * 11 * CLKS_PER_BIT + SEQ_SLACK))
                    $fatal(1, "%s: host_wr_en not seen within %0d cycles", msg, waited);
            end
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
        sw           = '0;      // SW15=0 keeps the combinational spike LED view
        frame_send_count    = 0;
        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        repeat (5) @(negedge clk);

        check_int(dut.u_protocol_fsm.IDLE_TIMEOUT_CYCLES, IDLE_TIMEOUT_CYCLES,
                  "TB idle-timeout mirror must match the DUT parameter");
        check(dut.u_protocol_fsm.WRITE_SYNC_BYTE === WRITE_SYNC_BYTE,
              "TB write-sync mirror must match the DUT parameter");
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

        // ------------------------------------------------------------
        // Test 5b: distinguish status bits 5 and 6 (#65 review).
        //
        // The first host frame is committed but no tick has consumed it yet,
        // so stimuli_pending is high while response_armed is still low -- the
        // only window in this run where the two differ.  Once each has been
        // high once, the ~64 ms stretcher holds both for the rest of the
        // ~11 ms simulation and a swapped binding becomes invisible, so the
        // check has to happen here rather than in test 9.
        //
        // sw only feeds the LED mux and aux_state, and aux_state is sampled
        // only on frame_send (which needs a tick first), so this excursion
        // cannot perturb the sequence.
        // ------------------------------------------------------------
        check(dut.stimuli_pending === 1'b1 && dut.response_armed === 1'b0,
              "test 5b: a committed frame must be pending but not yet armed");
        sw = 16'h8000;
        repeat (SW_SYNC_LATENCY + 1) @(negedge clk);
        check(led[5] === 1'b1,
              "test 5b: status bit 5 must be stimuli_pending, high in this window");
        check(led[6] === 1'b0,
              "test 5b: status bit 6 must be response_armed, still low in this window");
        sw = 16'h0000;
        repeat (SW_SYNC_LATENCY + 1) @(negedge clk);
        check(dut.stimuli_pending === 1'b1,
              "test 5b: the mode excursion must not consume the pending frame");
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
        check(sw === 16'h0000,
              "existing LED checks require SW15=0 spike mode");
        release dut.spike_bitmap;

        // ------------------------------------------------------------
        // Test 9: SW15 2FF latency, status word from primitive refs, aux.
        // Do not compare led against u_status_leds.status_word (tautology).
        // ------------------------------------------------------------
        force dut.spike_bitmap = 16'h5AA5;
        #1;
        check(led === 16'h5AA5,
              "test 9: distinguishable spike bitmap must still drive LED in spike mode");
        sw = 16'hA5A5; // SW15=1 plus a live aux pattern for bytes 34-35
        check(led === 16'h5AA5,
              "test 9: SW15 must not switch the LED mux on the same cycle");
        repeat (SW_SYNC_LATENCY - 1) @(negedge clk);
        check(led === 16'h5AA5,
              "test 9: first sync flop must keep spike mode");
        @(negedge clk);
        check(dut.sw_sync_1 === 16'hA5A5,
              "test 9: sw_sync_1 must present the switch bus after 2FF latency");
        check(led[0] === dut.u_status_leds.tick_cnt[8],
              "test 9: status[0] must follow tick_cnt[8]");
        check(led[1] === dut.u_status_leds.rx_busy_held,
              "test 9: status[1] must follow rx_busy_held");
        check(led[2] === dut.u_status_leds.rx_commit_held,
              "test 9: status[2] must follow rx_commit_held");
        check(led[3] === dut.u_status_leds.abort_sticky,
              "test 9: status[3] must follow abort_sticky");
        check(led[4] === dut.u_status_leds.tx_frame_held,
              "test 9: status[4] must follow tx_frame_held");
        check(led[5] === dut.u_status_leds.stimuli_pending_held,
              "test 9: status[5] must follow stimuli_pending_held");
        check(led[6] === dut.u_status_leds.response_armed_held,
              "test 9: status[6] must follow response_armed_held");
        check(led[7] === |dut.u_status_leds.spike_hold,
              "test 9: status[7] must be any_spike from spike_hold");
        check(led[12:8] === 5'($countones(dut.u_status_leds.spike_hold)),
              "test 9: status[12:8] must be countones(spike_hold)");
        check(led[15:13] === 3'b000,
              "test 9: reserved status[15:13] must stay 0");

        // The checks above mirror led against u_status_leds internals, so a
        // wrong Basys3_Top port binding moves both operands together and
        // passes.  These name expected VALUES instead.
        // Heartbeat counts logical ticks, so after ~11 of them tick_cnt[8] is
        // still low.  Sample three times 256 fabric clocks apart: if step_en
        // were mis-bound to something that pulses every clock, tick_cnt[8]
        // would have a 512-clock period and at least one of these samples
        // would read high.  A single sample would be a coin flip.
        check(led[0] === 1'b0,
              "test 9: heartbeat must be low after ~11 logical ticks");
        repeat (256) @(negedge clk);
        check(led[0] === 1'b0,
              "test 9: heartbeat must not advance on fabric clocks (sample 2)");
        repeat (256) @(negedge clk);
        check(led[0] === 1'b0,
              "test 9: heartbeat must not advance on fabric clocks (sample 3)");
        check(led[2] === 1'b1,
              "test 9: accepted host frames must have latched the commit bit");
        check(led[3] === 1'b0,
              "test 9: no idle timeout has occurred, so the sticky abort bit must be clear");
        check(led[7] === 1'b1,
              "test 9: spikes have been committed, so any_spike must be set");
        release dut.spike_bitmap;

        uart_send_stimulus_frame(SPIKE_TEST_NEURON);
        wait_for_stimuli_pending();
        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b1,
              "test 9: consumed host frame must still arm a response");
        @(negedge clk); // FSM consumes the combo strobe and snapshots aux
        // A prior 36-byte response may still be on the wire (~3.125 ms), so
        // this trigger is either the active snapshot or the latest-wins pend.
        check((dut.u_protocol_fsm.active_aux_state === 16'hA5A5) ||
              (dut.u_protocol_fsm.pending_aux_state === 16'hA5A5),
              "test 9: synchronized sw must reach the host response aux word");

        // ------------------------------------------------------------
        // Test 10: rx_abort actually reaches status bit 3 (#65 review).
        //
        // Test 9 can only prove bit 3 is low.  Drive it high from the UART
        // wire -- abandon a frame after its sync byte and let the FSM's
        // inter-byte idle timeout fire -- so the top-level rx_abort binding is
        // checked by a 0 -> 1 transition rather than by a mirror comparison.
        //
        // Note the analogous rx_busy check is not useful here: led[1] latched
        // high during the first host frame and the ~64 ms stretch window
        // outlives this ~11 ms simulation, so it can no longer transition.
        // ------------------------------------------------------------
        check(led[3] === 1'b0, "test 10: abort bit must still be clear before the abandon");
        uart_send_byte(8'hAA);   // sync only; never completes the payload

        // The FSM is now in RX_COLLECT with rx_busy high but no abort yet.
        // Checking bit 3 is still low HERE is what distinguishes a binding to
        // rx_abort from one to rx_busy -- without it, wiring bit 3 to rx_busy
        // passes the whole sequence.
        repeat (IDLE_TIMEOUT_CYCLES / 2) @(negedge clk);
        check(dut.rx_busy === 1'b1,
              "test 10: the abandoned frame must leave the receive FSM busy");
        check(led[3] === 1'b0,
              "test 10: a frame still inside the idle window must not look like an abort");

        repeat ((IDLE_TIMEOUT_CYCLES / 2) + SEQ_SLACK) @(negedge clk);
        check(led[3] === 1'b1,
              "test 10: an abandoned host frame must light the sticky abort bit");

        // Sticky, not stretched: it must survive until a frame is accepted.
        repeat (IDLE_TIMEOUT_CYCLES) @(negedge clk);
        check(led[3] === 1'b1,
              "test 10: the abort bit must stay lit until the next accepted frame");
        uart_send_stimulus_frame(SPIKE_TEST_NEURON);
        wait_for_stimuli_pending();
        check(led[3] === 1'b0,
              "test 10: an accepted host frame must clear the sticky abort bit");

        // ------------------------------------------------------------
        // Test 11: host runtime write (#63)
        //
        // Drain the pending stimulus from test 10 so the PE is idle, then
        // overwrite a weight and a leak that earlier merged_v2 checks do
        // not depend on.  INIT_FILE cold-start stays in place; we is muxed
        // from SocProtocolFsm rather than tied to 0.
        // ------------------------------------------------------------
        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.u_lif_array.sweep_state === 2'd0,
              "test 11: PE must be idle before the host write");
        check(dut.u_wram.we === 1'b0,
              "test 11: weight we must be low while the PE owns the address");
        check(dut.u_wram.addr === dut.weight_addr,
              "test 11: idle RAM addr must follow the PE read path");

        begin
            localparam logic [7:0] WRITE_WEIGHT_ADDR = 8'h01;
            localparam logic [7:0] WRITE_LEAK_ADDR   = 8'h0F;
            localparam logic [15:0] WRITE_WEIGHT_DATA = 16'hBEEF;
            localparam logic [15:0] WRITE_LEAK_DATA   = 16'h00A5;
            logic [15:0] weight_before;
            logic [15:0] leak_before;

            weight_before = dut.u_wram.mem[WRITE_WEIGHT_ADDR];
            leak_before   = dut.u_npram_leak.mem[WRITE_LEAK_ADDR];
            check(weight_before !== WRITE_WEIGHT_DATA,
                  "test 11: INIT_FILE weight must differ from the overwrite value");
            check(leak_before !== WRITE_LEAK_DATA,
                  "test 11: INIT_FILE leak must differ from the overwrite value");

            fork
                uart_send_write_frame(8'h00, WRITE_WEIGHT_ADDR, WRITE_WEIGHT_DATA);
                wait_for_host_write(2'd0, "test 11 weight");
            join
            check(dut.u_wram.mem[WRITE_WEIGHT_ADDR] === WRITE_WEIGHT_DATA,
                  "test 11: host must overwrite one INIT_FILE weight at runtime");
            check(dut.u_wram.we === 1'b0,
                  "test 11: weight we must return low after the one-cycle strobe");
            check(dut.u_wram.addr === dut.weight_addr,
                  "test 11: weight addr must return to the PE path after the write");

            fork
                uart_send_write_frame(8'h02, WRITE_LEAK_ADDR, WRITE_LEAK_DATA);
                wait_for_host_write(2'd2, "test 11 leak");
            join
            check(dut.u_npram_leak.mem[WRITE_LEAK_ADDR] === WRITE_LEAK_DATA,
                  "test 11: host must overwrite one INIT_FILE leak at runtime");
            check(dut.u_npram_leak.we === 1'b0,
                  "test 11: leak we must return low after the one-cycle strobe");
            check(dut.u_npram_leak.addr === dut.leak_addr,
                  "test 11: leak addr must return to the PE path after the write");
        end

        // ------------------------------------------------------------
        // Test 12: host writes that land mid-sweep are held until idle.
        // Force a one-cycle wr_en during PREFETCH/SWEEP; UART is too slow
        // to finish a 5-byte frame in that window.
        // ------------------------------------------------------------
        begin
            localparam logic [7:0] SWEEP_WEIGHT_ADDR = 8'h02;
            localparam logic [7:0] SWEEP_THRESH_ADDR = 8'h0E;
            localparam logic [7:0] SWEEP_LEAK_ADDR   = 8'h0D;
            localparam logic [15:0] SWEEP_WEIGHT_DATA = 16'hCAFE;
            localparam logic [15:0] SWEEP_THRESH_DATA = 16'h1111;
            localparam logic [15:0] SWEEP_LEAK_DATA   = 16'h2222;

            wait_for_tick();
            @(negedge clk);
            check(dut.pe_busy === 1'b1,
                  "test 12: PE must be busy after the tick starts");
            inject_host_strobe(2'd0, SWEEP_WEIGHT_ADDR, SWEEP_WEIGHT_DATA);
            check(dut.wr_pending === 1'b1,
                  "test 12: a mid-sweep weight write must be held");
            check(dut.weight_we === 1'b0,
                  "test 12: held weight write must not steal the RAM port");
            check(dut.u_wram.addr === dut.weight_addr,
                  "test 12: weight addr must stay on the PE path during the sweep");
            check(dut.u_wram.mem[SWEEP_WEIGHT_ADDR] !== SWEEP_WEIGHT_DATA,
                  "test 12: held weight write must not commit until idle");
            wait_lif_sweep_done();
            repeat (4) @(negedge clk);
            check(dut.u_wram.mem[SWEEP_WEIGHT_ADDR] === SWEEP_WEIGHT_DATA,
                  "test 12: held weight write must commit after the PE is idle");
            check(dut.wr_pending === 1'b0,
                  "test 12: weight pending must clear after the deferred strobe");

            wait_for_tick();
            @(negedge clk);
            inject_host_strobe(2'd1, SWEEP_THRESH_ADDR, SWEEP_THRESH_DATA);
            check(dut.wr_pending === 1'b1,
                  "test 12: a mid-sweep threshold write must be held");
            check(dut.thresh_we === 1'b0,
                  "test 12: held threshold write must not steal the RAM port");
            check(dut.u_npram_threshold.addr === dut.threshold_addr,
                  "test 12: threshold addr must stay on the PE path during the sweep");
            wait_lif_sweep_done();
            repeat (4) @(negedge clk);
            check(dut.u_npram_threshold.mem[SWEEP_THRESH_ADDR] === SWEEP_THRESH_DATA,
                  "test 12: held threshold write must commit after the PE is idle");

            wait_for_tick();
            @(negedge clk);
            inject_host_strobe(2'd2, SWEEP_LEAK_ADDR, SWEEP_LEAK_DATA);
            check(dut.wr_pending === 1'b1,
                  "test 12: a mid-sweep leak write must be held");
            check(dut.leak_we === 1'b0,
                  "test 12: held leak write must not steal the RAM port");
            check(dut.u_npram_leak.addr === dut.leak_addr,
                  "test 12: leak addr must stay on the PE path during the sweep");
            wait_lif_sweep_done();
            repeat (4) @(negedge clk);
            check(dut.u_npram_leak.mem[SWEEP_LEAK_ADDR] === SWEEP_LEAK_DATA,
                  "test 12: held leak write must commit after the PE is idle");
        end

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

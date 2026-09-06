// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_SocStatusLeds.sv
// Canonical source: spikenaut-soc-sv/tb
// Unit testbench for the combinational LED mux and shared status stretcher.
//
// Stimulus and checks run on negedge clk so they do not race the DUT's
// posedge-triggered always_ff blocks.

`timescale 1ns/1ps

module tb_SocStatusLeds;

    localparam int NUM_NEURONS = 16;
    localparam int LED_WIDTH   = 16;
    localparam int STRETCH_DIV = 64;
    localparam int CLK_PERIOD  = 10;
    localparam int COUNT_WIDTH = $clog2(NUM_NEURONS + 1);

    logic clk;
    logic rst_n;
    logic mode_sel;
    logic step_en;
    logic [NUM_NEURONS-1:0] spike_bitmap;
    logic rx_busy;
    logic rx_commit;
    logic rx_abort;
    logic tx_frame_active;
    logic stimuli_pending;
    logic response_armed;
    logic [LED_WIDTH-1:0] led;

    int errors = 0;
    int hold_cycles;

    SocStatusLeds #(
        .NUM_NEURONS (NUM_NEURONS),
        .LED_WIDTH   (LED_WIDTH),
        .STRETCH_DIV (STRETCH_DIV)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .mode_sel        (mode_sel),
        .step_en         (step_en),
        .spike_bitmap    (spike_bitmap),
        .rx_busy         (rx_busy),
        .rx_commit       (rx_commit),
        .rx_abort        (rx_abort),
        .tx_frame_active (tx_frame_active),
        .stimuli_pending (stimuli_pending),
        .response_armed  (response_armed),
        .led             (led)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic check(input logic condition, input string msg);
        if ($isunknown(condition)) begin
            errors++;
            $display("FAIL (unknown state): %s", msg);
        end else if (!condition) begin
            errors++;
            $display("FAIL: %s", msg);
        end
    endtask

    task automatic idle_inputs();
        begin
            mode_sel         = 1'b0;
            step_en          = 1'b0;
            spike_bitmap     = '0;
            rx_busy          = 1'b0;
            rx_commit        = 1'b0;
            rx_abort         = 1'b0;
            tx_frame_active  = 1'b0;
            stimuli_pending  = 1'b0;
            response_armed   = 1'b0;
        end
    endtask

    task automatic pulse_step_en();
        begin
            @(negedge clk);
            step_en = 1'b1;
            @(negedge clk);
            step_en = 1'b0;
        end
    endtask

    task automatic wait_stretch_tick();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.stretch_tick === 1'b1) break;
                if (waited > STRETCH_DIV + 2)
                    $fatal(1, "wait_stretch_tick: no stretch_tick within %0d cycles", waited);
            end
        end
    endtask

    // Park the DUT at the start of a fresh stretch window, using only the led
    // port.  The window phase is free-running, so hold a flag until it is lit,
    // drop it, and wait for the clear -- that clear IS the boundary.  Requires
    // mode_sel = 1 so led[1] shows the held rx_busy flag.
    task automatic align_to_window();
        begin
            idle_inputs();
            mode_sel = 1'b1;   // idle_inputs() clears it; led[1] must show the flag
            rx_busy  = 1'b1;
            repeat (2 * STRETCH_DIV + 2) @(negedge clk);
            rx_busy = 1'b0;
            while (led[1] !== 1'b0) @(negedge clk);
        end
    endtask

    function automatic logic [LED_WIDTH-1:0] expected_status();
        logic [LED_WIDTH-1:0] word;
        begin
            word        = '0;
            word[0]     = dut.tick_cnt[8];
            word[1]     = dut.rx_busy_held;
            word[2]     = dut.rx_commit_held;
            word[3]     = dut.abort_sticky;
            word[4]     = dut.tx_frame_held;
            word[5]     = dut.stimuli_pending_held;
            word[6]     = dut.response_armed_held;
            word[7]     = |dut.spike_hold;
            word[12:8]  = COUNT_WIDTH'($countones(dut.spike_hold));
            word[15:13] = '0;
            expected_status = word;
        end
    endfunction

    initial begin
        rst_n = 1'b0;
        idle_inputs();

        repeat (3) @(negedge clk);
        check(led === '0, "reset: spike-mode LED must be clear");
        check(dut.abort_sticky === 1'b0, "reset: abort_sticky must be clear");
        check(dut.tick_cnt === '0, "reset: tick_cnt must be clear");
        rst_n = 1'b1;
        @(negedge clk);

        // Spike passthrough stays combinational (force + #1 delay).
        mode_sel = 1'b0;
        force spike_bitmap = 16'hA55A;
        #1;
        check(led === 16'hA55A, "spike mode must pass every bitmap bit combinationally");
        release spike_bitmap;
        spike_bitmap = 16'h00F0;
        #1;
        check(led === 16'h00F0, "spike mode must follow a live bitmap without a clock");
        spike_bitmap = '0;
        wait_stretch_tick();
        @(negedge clk);
        check(dut.spike_hold === '0,
              "passthrough spikes must expire before status-mode checks");

        // Status mode after a single event set.
        @(negedge clk);
        mode_sel         = 1'b1;
        rx_busy          = 1'b1;
        rx_commit        = 1'b1;
        tx_frame_active  = 1'b1;
        stimuli_pending  = 1'b1;
        response_armed   = 1'b1;
        spike_bitmap     = 16'h0007;
        @(negedge clk);
        rx_busy          = 1'b0;
        rx_commit        = 1'b0;
        tx_frame_active  = 1'b0;
        stimuli_pending  = 1'b0;
        response_armed   = 1'b0;
        spike_bitmap     = '0;
        #1;
        check(led === expected_status(),
              "status mode must pack held flags, any_spike, and countones");
        check(led[1] === 1'b1, "status[1] must hold rx_busy");
        check(led[2] === 1'b1, "status[2] must hold rx_commit");
        check(led[4] === 1'b1, "status[4] must hold tx_frame_active");
        check(led[5] === 1'b1, "status[5] must hold stimuli_pending");
        check(led[6] === 1'b1, "status[6] must hold response_armed");
        check(led[7] === 1'b1, "status[7] must be any_spike from spike_hold");
        check(led[12:8] === 5'd3, "status[12:8] must count ones in spike_hold");
        check(led[15:13] === 3'b000, "reserved status[15:13] must stay 0");

        // Stretch clear drops held flags and spike_hold, not abort_sticky.
        @(negedge clk);
        rx_abort = 1'b1;
        @(negedge clk);
        rx_abort = 1'b0;
        check(dut.abort_sticky === 1'b1, "rx_abort must set abort_sticky");
        wait_stretch_tick();
        @(negedge clk);
        check(dut.rx_busy_held === 1'b0, "stretch_tick must clear rx_busy_held");
        check(dut.rx_commit_held === 1'b0, "stretch_tick must clear rx_commit_held");
        check(dut.tx_frame_held === 1'b0, "stretch_tick must clear tx_frame_held");
        check(dut.stimuli_pending_held === 1'b0,
              "stretch_tick must clear stimuli_pending_held");
        check(dut.response_armed_held === 1'b0,
              "stretch_tick must clear response_armed_held");
        check(dut.spike_hold === '0, "stretch_tick must clear spike_hold");
        check(dut.abort_sticky === 1'b1,
              "stretch_tick must not clear abort_sticky");
        check(led[3] === 1'b1, "status[3] must remain abort_sticky through stretch");

        // abort_sticky clears only on rx_commit (or reset).
        @(negedge clk);
        rx_commit = 1'b1;
        @(negedge clk);
        rx_commit = 1'b0;
        check(dut.abort_sticky === 1'b0, "rx_commit must clear abort_sticky");
        check(led[3] === 1'b0, "status[3] must fall after rx_commit");

        // Heartbeat is tick_cnt[8] after 256 step_en increments (~1.95 Hz).
        check(dut.tick_cnt === '0, "heartbeat test must start from a clear tick_cnt");
        for (int tick = 0; tick < 255; tick++)
            pulse_step_en();
        check(dut.tick_cnt === 9'd255, "255 step_en pulses must leave tick_cnt[8] low");
        check(led[0] === 1'b0, "heartbeat must stay low before the 256th tick");
        pulse_step_en();
        check(dut.tick_cnt === 9'd256, "256 step_en pulses must set tick_cnt[8]");
        check(led[0] === 1'b1, "heartbeat must follow tick_cnt[8]");

        // countones cases and reserved bits.
        @(negedge clk);
        spike_bitmap = 16'h0000;
        @(negedge clk);
        wait_stretch_tick();
        @(negedge clk);
        check(led[7] === 1'b0, "empty spike_hold must clear any_spike");
        check(led[12:8] === 5'd0, "empty spike_hold must count zero");

        spike_bitmap = 16'h8001;
        @(negedge clk);
        spike_bitmap = '0;
        #1;
        check(led[7] === 1'b1, "two-bit spike_hold must set any_spike");
        check(led[12:8] === 5'd2, "two-bit spike_hold must count two");
        check(led[15:13] === 3'b000, "reserved bits must stay 0 for a sparse bitmap");

        spike_bitmap = 16'hFFFF;
        @(negedge clk);
        spike_bitmap = '0;
        #1;
        check(led[7] === 1'b1, "all-ones spike_hold must set any_spike");
        check(led[12:8] === 5'd16, "all-ones spike_hold must count sixteen");
        check(led[15:13] === 3'b000, "reserved bits must stay 0 for a full bitmap");

        // ------------------------------------------------------------
        // Stretch window DURATION, measured through the led port only.
        //
        // The checks above use wait_stretch_tick() and dut.*_held, so they
        // confirm that a flag is held until the tick and cleared by it -- but
        // they pass for any window length, including a stretcher that expires
        // every cycle.  Visibility is the entire reason this block exists, so
        // bound the hold: a one-cycle event must stay lit for very nearly a
        // full STRETCH_DIV and must not outlive it.
        // ------------------------------------------------------------
        mode_sel = 1'b1;
        align_to_window();
        rx_busy = 1'b1;
        @(negedge clk);
        rx_busy = 1'b0;
        check(led[1] === 1'b1, "a one-cycle event must latch into the status word");

        hold_cycles = 0;
        while ((led[1] === 1'b1) && (hold_cycles <= 2 * STRETCH_DIV)) begin
            @(negedge clk);
            hold_cycles++;
        end
        check(led[1] === 1'b0, "a held flag must eventually clear");
        check(hold_cycles >= STRETCH_DIV - 2,
              "a one-cycle event must be held for very nearly a full window");
        check(hold_cycles <= STRETCH_DIV + 1,
              "a held flag must not outlive its stretch window");

        if (errors == 0) begin
            $display("TB_SOCSTATUSLEDS: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_SOCSTATUSLEDS: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_SOCSTATUSLEDS: testbench FAILED");
        end
    end

endmodule

// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_StdpWriteback.sv
// Canonical source: spikenaut-core-sv/tb
// Unit testbench for StdpWriteback.sv (GH#70). Instantiates the real
// WeightRam (not a behavioral shadow) so the registered-read snapshot,
// serialized writeback, and learn_en gate are proven on the same port the
// SoC muxes against the LIF PE.
//
// Stimulus and checks run on negedge clk to avoid races with the DUT's
// posedge-triggered always_ff blocks.

`timescale 1ns/1ps

module tb_StdpWriteback;

    localparam int DATA_WIDTH   = 16;
    localparam int NUM_NEURONS  = 4;
    localparam int INDEX_WIDTH  = 2;
    localparam int ADDR_WIDTH   = 4;   // 4x4 matrix
    localparam int WINDOW_WIDTH = 8;
    localparam int CLK_PERIOD   = 10;
    localparam int COL          = 2;
    localparam int POST_N       = 1;   // neuron 1 is the exercised post cell
    localparam int SYN_ADDR     = POST_N * NUM_NEURONS + COL;
    localparam int OTHER_ADDR   = 0 * NUM_NEURONS + COL;

    logic                    clk;
    logic                    rst_n;
    logic                    learn_en;
    logic                    step_en;
    logic                    tick_done;
    logic                    pre_spike;
    logic [NUM_NEURONS-1:0]  post_spikes;
    logic [INDEX_WIDTH-1:0]  input_index;
    logic [DATA_WIDTH-1:0]   weight_dout;
    logic                    busy;
    logic                    weight_we;
    logic [ADDR_WIDTH-1:0]   weight_addr;
    logic [DATA_WIDTH-1:0]   weight_din;

    int errors = 0;

    WeightRam #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .INIT_FILE  ("NONE")
    ) u_wram (
        .clk   (clk),
        .rst_n (rst_n),
        .we    (weight_we),
        .addr  (weight_addr),
        .din   (weight_din),
        .dout  (weight_dout)
    );

    StdpWriteback #(
        .DATA_WIDTH   (DATA_WIDTH),
        .NUM_NEURONS  (NUM_NEURONS),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .WINDOW_WIDTH (WINDOW_WIDTH)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .learn_en     (learn_en),
        .step_en      (step_en),
        .tick_done    (tick_done),
        .pre_spike    (pre_spike),
        .post_spikes  (post_spikes),
        .input_index  (input_index),
        .weight_dout  (weight_dout),
        .busy         (busy),
        .weight_we    (weight_we),
        .weight_addr  (weight_addr),
        .weight_din   (weight_din)
    );

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

    task automatic pulse_tick(
        input logic                pre,
        input logic [NUM_NEURONS-1:0] post
    );
        begin
            step_en     = 1'b1;
            pre_spike   = pre;
            post_spikes = post;
            tick_done   = 1'b0;
            @(negedge clk);
            step_en   = 1'b0;
            pre_spike = 1'b0;
            // Commit the post bitmap a few fabric cycles later, matching
            // LifNeuronArray: spike_bitmap updates on tick_done, not step_en.
            repeat (3) @(negedge clk);
            tick_done = 1'b1;
            @(negedge clk);
            tick_done   = 1'b0;
            post_spikes = '0;
        end
    endtask

    task automatic wait_idle();
        int unsigned waited;
        begin
            waited = 0;
            while (busy === 1'b1) begin
                @(negedge clk);
                waited++;
                if (waited > 8 * NUM_NEURONS + 8)
                    $fatal(1, "wait_idle: still busy after %0d cycles", waited);
            end
        end
    endtask

    initial begin
        rst_n       = 1'b0;
        learn_en    = 1'b0;
        step_en     = 1'b0;
        tick_done   = 1'b0;
        pre_spike   = 1'b0;
        post_spikes = '0;
        input_index = INDEX_WIDTH'(COL);
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // Seed a known column so LTP/LTD deltas are obvious. Other entries
        // stay 0. Hierarchical mem poke is the same pattern tb_Basys3_Top
        // uses for controlled rows.
        u_wram.mem[SYN_ADDR]   = 16'd100;
        u_wram.mem[OTHER_ADDR] = 16'd50;
        @(negedge clk);

        // learn_en=0: a pre-then-post pair must not touch the RAM or go busy.
        pulse_tick(1'b1, '0);
        check(busy == 1'b0, "learn_en=0: first tick must not start writeback");
        pulse_tick(1'b0, NUM_NEURONS'(1 << POST_N));
        check(busy == 1'b0, "learn_en=0: LTP pair must not start writeback");
        check(weight_we == 1'b0, "learn_en=0: weight_we must stay low");
        check(u_wram.mem[SYN_ADDR] == 16'd100,
              "learn_en=0: selected synapse must be unchanged");
        check(u_wram.mem[OTHER_ADDR] == 16'd50,
              "learn_en=0: unselected synapse must be unchanged");

        // Enable learning. First coincident pre+post has empty traces, so no
        // write — same as StdpController's first-tick behavior. It does load
        // traces, which the next tick consumes.
        learn_en = 1'b1;

        pulse_tick(1'b1, '0);
        check(busy == 1'b1, "learn_en=1: tick_done must start a column sweep");
        wait_idle();
        check(u_wram.mem[SYN_ADDR] == 16'd100,
              "trace-load tick must not change the synapse");

        // LTP: post while pre_trace is live.
        pulse_tick(1'b0, NUM_NEURONS'(1 << POST_N));
        wait_idle();
        check(u_wram.mem[SYN_ADDR] == 16'd101,
              "LTP: selected synapse must increment by 1 LSB");
        check(u_wram.mem[OTHER_ADDR] == 16'd50,
              "LTP: a neuron that did not spike must not change");

        // LTD: pre while post_trace is live.
        pulse_tick(1'b1, '0);
        wait_idle();
        check(u_wram.mem[SYN_ADDR] == 16'd100,
              "LTD: selected synapse must decrement by 1 LSB");
        check(u_wram.mem[OTHER_ADDR] == 16'd50,
              "LTD: a neuron that did not spike must not change");

        // Drain traces so the next pair is not still sitting in the LTD
        // window. WINDOW_WIDTH empty ticks shift both traces to zero.
        repeat (WINDOW_WIDTH + 1) begin
            pulse_tick(1'b0, '0);
            wait_idle();
        end
        check(u_wram.mem[SYN_ADDR] == 16'd100,
              "idle ticks must not change a synapse with empty traces");

        // Same-tick pre+post with a live pre_trace: LTP has priority.
        pulse_tick(1'b1, '0);
        wait_idle();
        pulse_tick(1'b1, NUM_NEURONS'(1 << POST_N));
        wait_idle();
        check(u_wram.mem[SYN_ADDR] == 16'd101,
              "same-tick pre+post with live pre_trace must LTP, not LTD");

        // Drop learn_en mid-window: traces freeze, no further writes.
        learn_en = 1'b0;
        pulse_tick(1'b0, NUM_NEURONS'(1 << POST_N));
        check(busy == 1'b0, "learn_en falling must leave the engine idle");
        check(u_wram.mem[SYN_ADDR] == 16'd101,
              "learn_en falling must freeze the last written weight");

        if (errors == 0) begin
            $display("TB_STDPWRITEBACK: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_STDPWRITEBACK: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_STDPWRITEBACK: testbench FAILED");
        end
    end

endmodule

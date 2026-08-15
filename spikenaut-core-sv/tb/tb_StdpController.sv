// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_StdpController.sv
// Unit testbench for spikenaut-core-sv/rtl/StdpController.sv
//
// Stimulus is applied and sampled on negedge clk (mid-cycle) to avoid
// race conditions with the DUT's posedge-triggered always_ff block.

`timescale 1ns/1ps

module tb_StdpController;

    localparam int DATA_WIDTH   = 16;
    localparam int ADDR_WIDTH   = 10;
    localparam int WINDOW_WIDTH = 8;
    localparam int CLK_PERIOD   = 10;

    logic                    clk;
    logic                    rst_n;
    logic                    step_en;
    logic                    pre_spike;
    logic                    post_spike;
    logic [ADDR_WIDTH-1:0]   weight_addr;
    logic [DATA_WIDTH-1:0]   weight_in;
    logic                    weight_we;
    logic [ADDR_WIDTH-1:0]   weight_addr_out;
    logic [DATA_WIDTH-1:0]   weight_out;

    int errors = 0;

    StdpController #(
        .DATA_WIDTH   (DATA_WIDTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .WINDOW_WIDTH (WINDOW_WIDTH)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .step_en        (step_en),
        .pre_spike      (pre_spike),
        .post_spike     (post_spike),
        .weight_addr    (weight_addr),
        .weight_in      (weight_in),
        .weight_we      (weight_we),
        .weight_addr_out(weight_addr_out),
        .weight_out     (weight_out)
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

    // Overload for multi-bit signals: checks for X/Z in data before
    // comparison can resolve unknowns to a false positive.
    task automatic check_data(input logic [DATA_WIDTH-1:0] actual,
                              input logic [DATA_WIDTH-1:0] expected,
                              input string msg);
        if ($isunknown(actual)) begin
            errors++;
            $display("FAIL (X/Z in data): %s", msg);
        end else if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (got %0d, expected %0d)", msg, actual, expected);
        end
    endtask

    initial begin
        // Reset
        rst_n       = 1'b0;
        step_en     = 1'b1;
        pre_spike   = 1'b0;
        post_spike  = 1'b0;
        weight_addr = '0;
        weight_in   = '0;
        repeat (2) @(negedge clk);
        check(weight_we == 1'b0, "weight_we should be 0 after reset");
        check(weight_out == '0, "weight_out should be 0 after reset");
        rst_n = 1'b1;
        @(negedge clk);

        // No change when no spikes
        weight_in = 16'd500;
        @(negedge clk);
        check(weight_out == 16'd500, "weight_out should pass through weight_in when no spikes");

        // LTP (classical): pre then post while pre_trace active -> weight + 1
        pre_spike = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        @(negedge clk);

        weight_in   = 16'd100;
        weight_addr = 10'd5;
        post_spike  = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        check(weight_we == 1'b1, "weight_we should assert on LTP (pre-then-post)");
        check(weight_out == 16'd101, "LTP: weight_out should be 101 (100+1)");
        check(weight_addr_out == 10'd5, "weight_addr_out should echo weight_addr");
        @(negedge clk);
        check(weight_we == 1'b0, "weight_we should deassert after spike cycle");

        // LTD (classical): post then pre while post_trace active -> weight - 1
        post_spike = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        @(negedge clk);

        weight_in   = 16'd100;
        weight_addr = 10'd7;
        pre_spike   = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        check(weight_we == 1'b1, "weight_we should assert on LTD (post-then-pre)");
        check(weight_out == 16'd99, "LTD: weight_out should be 99 (100-1)");
        check(weight_addr_out == 10'd7, "weight_addr_out should echo weight_addr");
        @(negedge clk);
        check(weight_we == 1'b0, "weight_we should deassert after spike cycle");

        // No change when traces have decayed (spikes too far apart)
        pre_spike = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        repeat (WINDOW_WIDTH + 1) @(negedge clk);

        weight_in  = 16'd200;
        post_spike = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        check(weight_out == 16'd200, "no change when traces have decayed");
        check(weight_we == 1'b0, "weight_we should NOT assert when traces have decayed (no actual weight change)");
        @(negedge clk);
        check(weight_we == 1'b0, "weight_we deasserts after spike cycle");

        // Saturation at max: LTP at max stays at max and must not assert weight_we
        pre_spike = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        @(negedge clk);

        weight_in  = 16'hFFFF;
        post_spike = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        check(weight_out == 16'hFFFF, "saturation: LTP at max stays at max");
        check(weight_we == 1'b0, "saturation: weight_we low when LTP at max (no change)");

        // Saturation at zero: LTD at zero stays at zero and must not assert weight_we
        post_spike = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        @(negedge clk);

        weight_in = 16'd0;
        pre_spike = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        check(weight_out == 16'd0, "saturation: LTD at zero stays at zero");
        check(weight_we == 1'b0, "saturation: weight_we low when LTD at zero (no change)");

        // step_en=0: pre_spike must not load pre_trace (no LTP on later post)
        rst_n      = 1'b0;
        step_en    = 1'b0;
        pre_spike  = 1'b0;
        post_spike = 1'b0;
        weight_in  = 16'd100;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        pre_spike = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        repeat (3) @(negedge clk);

        step_en    = 1'b1;
        post_spike = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        check(weight_we == 1'b0, "pre while step_en=0 must not arm LTP");
        check(weight_out == 16'd100, "weight unchanged when pre was gated off");

        // Contrast: pre on a tick, then hold step_en=0 longer than WINDOW_WIDTH,
        // then post on a tick — traces must still be live (decay is per tick)
        step_en   = 1'b1;
        pre_spike = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        step_en   = 1'b0;
        repeat (WINDOW_WIDTH + 2) @(negedge clk);
        weight_in  = 16'd100;
        step_en    = 1'b1;
        post_spike = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        check(weight_we == 1'b1, "trace must hold across fabric cycles without step_en");
        check(weight_out == 16'd101, "LTP after held pre_trace");

        if (errors == 0) begin
            $display("TB_STDPCONTROLLER: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_STDPCONTROLLER: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_STDPCONTROLLER: testbench FAILED");
        end
    end

endmodule

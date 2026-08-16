// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_LifNeuron.sv
// Unit testbench for spikenaut-core-sv/rtl/LifNeuron.sv
//
// Stimulus is applied and sampled on negedge clk (mid-cycle) to avoid
// race conditions with the DUT's posedge-triggered always_ff block.

`timescale 1ns/1ps

module tb_LifNeuron;

    localparam int DATA_WIDTH  = 16;
    localparam int PARAM_WIDTH = 16;
    localparam int CLK_PERIOD  = 10;

    logic                    clk;
    logic                    rst_n;
    logic                    spike_in;
    logic                    step_en;
    logic [DATA_WIDTH-1:0]   weight;
    logic [PARAM_WIDTH-1:0]  threshold;
    logic [PARAM_WIDTH-1:0]  leak;
    logic                    spike_out;

    int errors = 0;

    LifNeuron #(
        .DATA_WIDTH  (DATA_WIDTH),
        .PARAM_WIDTH (PARAM_WIDTH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .spike_in  (spike_in),
        .step_en   (step_en),
        .weight    (weight),
        .threshold (threshold),
        .leak      (leak),
        .spike_out (spike_out)
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
        // ------------------------------------------------------------
        // Reset
        // ------------------------------------------------------------
        rst_n     = 1'b0;
        spike_in  = 1'b0;
        step_en   = 1'b1;
        weight    = '0;
        threshold = 16'd100;
        leak      = 16'd1;
        repeat (2) @(negedge clk);
        check(spike_out == 1'b0, "spike_out should be 0 after reset");
        rst_n = 1'b1;

        // ------------------------------------------------------------
        // Leak with no input: membrane potential should stay at 0
        // (saturated) and never spike.
        // ------------------------------------------------------------
        repeat (5) @(negedge clk);
        check(spike_out == 1'b0, "spike_out should remain 0 with no input");

        // ------------------------------------------------------------
        // Integrate: drive spike_in with a weight large enough to cross
        // threshold quickly, and check that spike_out pulses for exactly
        // one cycle when the threshold is crossed.
        // ------------------------------------------------------------
        weight   = 16'd40;
        spike_in = 1'b1;
        @(negedge clk); // mem: 0 -> 40
        @(negedge clk); // mem: 40 -> 79 (leak of 1 each step: 40-1+40=79)
        @(negedge clk); // mem: 79 -> 118 -> crosses threshold(100)
        check(spike_out == 1'b1, "spike_out should assert once threshold is crossed");

        @(negedge clk);
        check(spike_out == 1'b0, "spike_out should deassert one cycle after pulsing (single-cycle pulse)");

        // ------------------------------------------------------------
        // After the pulse, membrane potential should have been reset to 0.
        // Verify by checking it takes the same number of cycles to spike
        // again from a fresh start (addresses Gemini/Codacy review feedback:
        // the original comment promised this check but the code never
        // performed it).
        // ------------------------------------------------------------
        spike_in = 1'b0;
        @(negedge clk);
        check(spike_out == 1'b0, "spike_out should stay low while membrane is reset and decaying");

        // Drive a second integration from the reset state and confirm the
        // neuron fires after the same 3 cycles, proving the membrane was
        // properly cleared by the spike-reset path.
        spike_in = 1'b1;
        @(negedge clk); // mem: 0 -> 40
        @(negedge clk); // mem: 40 -> 79 (40-1+40=79)
        @(negedge clk); // mem: 79 -> 118 -> crosses threshold(100)
        check(spike_out == 1'b1, "spike_out should assert again after 3 cycles of integration from reset");
        @(negedge clk); // refractory after second spike
        check(spike_out == 1'b0, "spike_out should deassert after second spike (refractory)");

        // ------------------------------------------------------------
        // Overflow saturation: when decayed_mem + weight would exceed the
        // DATA_WIDTH range, next_mem must saturate at max (all 1s) instead
        // of wrapping around. A threshold set to the max value should then
        // still fire, proving the saturation preserves the threshold
        // crossing instead of masking it.
        // ------------------------------------------------------------
        threshold = 16'hFFFF;  // max threshold
        leak      = 16'd0;     // no decay for a clean overflow test
        weight    = 16'd40000;
        spike_in  = 1'b1;
        @(negedge clk);  // mem: 0 -> 40000  (no overflow yet)
        check(spike_out == 1'b0, "no spike yet: 40000 < max threshold");
        @(negedge clk);  // mem: 40000 + 40000 -> saturates to 65535, fires
        check(spike_out == 1'b1, "spike_out should fire when membrane saturates at max (>= max threshold)");
        @(negedge clk);  // refractory reset after the saturation spike
        check(spike_out == 1'b0, "spike_out should deassert after saturation spike (refractory)");
        spike_in = 1'b0;

        // step_en=0: must not leak or integrate (would fire in a few cycles if ungated)
        rst_n     = 1'b0;
        step_en   = 1'b0;
        spike_in  = 1'b0;
        leak      = 16'd1;
        threshold = 16'd100;
        weight    = 16'd40;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        spike_in = 1'b1;
        repeat (8) @(negedge clk);
        check(spike_out == 1'b0, "step_en=0: spike_out must stay 0 (no integrate)");

        // One tick: one integrate (0 + 40), still below threshold
        step_en = 1'b1;
        @(negedge clk);
        step_en = 1'b0;
        check(spike_out == 1'b0, "one step_en pulse: 40 < 100, no spike");

        // Two more ticks with spike_in: 40-1+40=79, then 79-1+40=118 -> fire
        step_en = 1'b1;
        @(negedge clk);
        step_en = 1'b0;
        @(negedge clk);
        step_en = 1'b1;
        @(negedge clk);
        step_en = 1'b0;
        check(spike_out == 1'b1, "third step_en pulse: membrane crosses 100");

        // spike_out is a one-*tick* pulse, not a one-fabric-cycle pulse: it must
        // hold high across disabled cycles and only clear on the next enabled
        // tick (refractory). See docs/timestep-contract.md.
        repeat (6) @(negedge clk);
        check(spike_out == 1'b1, "step_en=0: spike_out must hold high between ticks");

        step_en = 1'b1;
        @(negedge clk);
        step_en = 1'b0;
        check(spike_out == 1'b0, "next step_en pulse: refractory clears spike_out");

        if (errors == 0) begin
            $display("TB_LIFNEURON: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_LIFNEURON: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_LIFNEURON: testbench FAILED");
        end
    end

endmodule
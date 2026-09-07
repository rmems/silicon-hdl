// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_SynapseRouter.sv
// Canonical source: synapse-link-hdl/tb
// Unit testbench for the address-event representation (AER) synapse router.
//
// lib_synapse had no testbenches at all: SynapseRouter and the demo top were
// never elaborated by any runner, so a syntax error or a broken port list
// would have shipped undetected. This is the first coverage for the library.
//
// Stimulus and checks run on negedge clk so they do not race the DUT's
// posedge-triggered always_ff.

`timescale 1ns/1ps

module tb_SynapseRouter;

    localparam int NEURON_ADDR_WIDTH = 8;
    localparam int CLK_PERIOD        = 10;

    logic                         clk;
    logic                         rst_n;
    logic [NEURON_ADDR_WIDTH-1:0] src_addr;
    logic                         src_valid;
    logic [NEURON_ADDR_WIDTH-1:0] dst_addr;
    logic                         dst_valid;

    int errors = 0;

    SynapseRouter #(
        .NEURON_ADDR_WIDTH (NEURON_ADDR_WIDTH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .src_addr  (src_addr),
        .src_valid (src_valid),
        .dst_addr  (dst_addr),
        .dst_valid (dst_valid)
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

    task automatic check_addr(
        input logic [NEURON_ADDR_WIDTH-1:0] actual,
        input logic [NEURON_ADDR_WIDTH-1:0] expected,
        input string msg
    );
        if ($isunknown(actual)) begin
            errors++;
            $display("FAIL (X/Z on dst_addr): %s", msg);
        end else if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (got 0x%02h, expected 0x%02h)", msg, actual, expected);
        end
    endtask

    // Present one AER beat and advance a single clock.
    task automatic drive(input logic [NEURON_ADDR_WIDTH-1:0] a, input logic v);
        begin
            src_addr  = a;
            src_valid = v;
            @(negedge clk);
        end
    endtask

    initial begin
        // ------------------------------------------------------------
        // Test 1: reset clears both outputs
        // ------------------------------------------------------------
        rst_n     = 1'b0;
        src_addr  = '0;
        src_valid = 1'b0;
        repeat (3) @(negedge clk);

        check_addr(dst_addr, '0, "reset: dst_addr must be cleared");
        check(dst_valid === 1'b0, "reset: dst_valid must be low");

        rst_n = 1'b1;
        @(negedge clk);

        // ------------------------------------------------------------
        // Test 2: exactly one clock of latency
        //
        // The address presented during a cycle appears on dst in the NEXT
        // cycle, not the same one -- this pins the registered behaviour.
        // ------------------------------------------------------------
        src_addr  = 8'hA5;
        src_valid = 1'b1;
        check_addr(dst_addr, '0,
                   "routing must not be combinational: dst holds its old value this cycle");
        check(dst_valid === 1'b0, "dst_valid must not rise on the same cycle as src_valid");

        @(negedge clk);
        check_addr(dst_addr, 8'hA5, "dst_addr must present the source address one clock later");
        check(dst_valid === 1'b1, "dst_valid must follow src_valid by one clock");

        // ------------------------------------------------------------
        // Test 3: dst_valid falls one clock after src_valid
        // ------------------------------------------------------------
        drive(8'h00, 1'b0);
        check(dst_valid === 1'b0, "dst_valid must deassert one clock after src_valid drops");

        // ------------------------------------------------------------
        // Test 4: back-to-back beats stream through in order
        //
        // drive() returns AFTER the capturing posedge, so the beat it just
        // presented is already on dst when it returns. Test 2 above is what
        // pins the one-cycle latency; this test pins ordering and that no beat
        // is dropped or duplicated when they arrive on consecutive cycles.
        // ------------------------------------------------------------
        drive(8'h11, 1'b1);
        check_addr(dst_addr, 8'h11, "first back-to-back beat must reach the output");
        check(dst_valid === 1'b1, "streaming beats must hold dst_valid high");

        drive(8'h22, 1'b1);
        check_addr(dst_addr, 8'h22, "second beat must follow in order, with no repeat of the first");
        check(dst_valid === 1'b1, "dst_valid must stay high across consecutive valid beats");

        drive(8'h33, 1'b1);
        check_addr(dst_addr, 8'h33, "third beat must follow in order");

        drive(8'h00, 1'b0);
        check(dst_valid === 1'b0, "dst_valid must return low one clock after the stream ends");

        // ------------------------------------------------------------
        // Test 5: the address path is unconditional
        //
        // dst_addr tracks src_addr even while src_valid is low -- consumers
        // must gate on dst_valid, not assume dst_addr is held. Pinning this
        // so a later "optimization" that gates the address is a deliberate
        // contract change, not a silent one.
        // ------------------------------------------------------------
        drive(8'h7E, 1'b0);
        check_addr(dst_addr, 8'h7E,
                   "dst_addr must track src_addr even when src_valid is low");
        check(dst_valid === 1'b0, "dst_valid must stay low for an invalid beat");

        // ------------------------------------------------------------
        // Test 6: full-scale address, no truncation at the parameter width
        // ------------------------------------------------------------
        drive(8'hFF, 1'b1);
        check_addr(dst_addr, 8'hFF, "all-ones address must survive the width intact");

        // ------------------------------------------------------------
        // Test 7: reset is asynchronous
        //
        // SynapseRouter uses `always_ff @(posedge clk or negedge rst_n)`, so
        // asserting rst_n mid-cycle must clear the outputs without waiting for
        // a clock edge. Checked off-edge, deliberately.
        // ------------------------------------------------------------
        drive(8'h5A, 1'b1);
        check_addr(dst_addr, 8'h5A, "precondition: a live beat is on the output");
        check(dst_valid === 1'b1, "precondition: dst_valid is high");

        rst_n = 1'b0;
        #1;   // no clock edge here
        check_addr(dst_addr, '0, "async reset must clear dst_addr without a clock edge");
        check(dst_valid === 1'b0, "async reset must clear dst_valid without a clock edge");

        rst_n = 1'b1;
        drive(8'h3C, 1'b1);
        check_addr(dst_addr, 8'h3C, "router must resume routing after reset release");

        if (errors == 0) begin
            $display("TB_SYNAPSEROUTER: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_SYNAPSEROUTER: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_SYNAPSEROUTER: testbench FAILED");
        end
    end

endmodule

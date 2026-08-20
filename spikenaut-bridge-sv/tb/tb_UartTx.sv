// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_UartTx.sv
// Unit testbench for spikenaut-bridge-sv/rtl/UartTx.sv (#58)
//
// Stimulus is applied and sampled on negedge clk (mid-cycle) to avoid
// race conditions with the DUT's posedge-triggered always_ff block.

`timescale 1ns/1ps

module tb_UartTx;

    localparam int CLK_FREQ     = 1_000_000;
    localparam int BAUD_RATE    = 100_000;
    localparam int DATA_WIDTH   = 8;
    localparam int CLK_PERIOD   = 10;
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    logic                  clk;
    logic                  rst_n;
    logic [DATA_WIDTH-1:0] data;
    logic                  send;
    logic                  tx;
    logic                  busy;

    int errors = 0;

    UartTx #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE  (BAUD_RATE),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (data),
        .send  (send),
        .tx    (tx),
        .busy  (busy)
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

    task automatic check_data(input logic [DATA_WIDTH-1:0] actual,
                              input logic [DATA_WIDTH-1:0] expected,
                              input string msg);
        if ($isunknown(actual)) begin
            errors++;
            $display("FAIL (X/Z in data): %s", msg);
        end else if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (got 0x%02h, expected 0x%02h)", msg, actual, expected);
        end
    endtask

    // Pulse send for one cycle while idle; caller must have busy==0.
    task automatic pulse_send(input logic [DATA_WIDTH-1:0] b);
        data = b;
        send = 1'b1;
        @(negedge clk);
        send = 1'b0;
    endtask

    // Reconstruct an 8N1 byte from the tx pin (sample mid-bit).
    task automatic capture_uart_byte(output logic [DATA_WIDTH-1:0] b);
        int i;
        while (tx !== 1'b0)
            @(negedge clk);
        check(busy == 1'b1, "busy should stay high through the start bit");
        repeat (CLKS_PER_BIT / 2) @(negedge clk);
        check(tx == 1'b0, "start bit should be 0 at mid-bit");
        check(busy == 1'b1, "busy should stay high through the start-bit sample");
        for (i = 0; i < DATA_WIDTH; i++) begin
            repeat (CLKS_PER_BIT) @(negedge clk);
            b[i] = tx;
            check(busy == 1'b1, "busy should stay high through data bits");
        end
        repeat (CLKS_PER_BIT) @(negedge clk);
        check(tx == 1'b1, "stop bit should be 1 at mid-bit");
        check(busy == 1'b1, "busy should stay high through the stop-bit sample");
    endtask

    task automatic send_and_capture(input logic [DATA_WIDTH-1:0] expected, input string msg);
        logic [DATA_WIDTH-1:0] got;
        pulse_send(expected);
        check(busy == 1'b1, {msg, ": busy should assert on the send handshake"});
        capture_uart_byte(got);
        check_data(got, expected, msg);
        while (busy !== 1'b0)
            @(negedge clk);
        check(tx == 1'b1, {msg, ": tx returns idle-high after the stop bit"});
        check(busy == 1'b0, {msg, ": busy should deassert after the stop bit"});
    endtask

    initial begin
        rst_n = 1'b0;
        data  = '0;
        send  = 1'b0;
        repeat (4) @(negedge clk);
        check(tx == 1'b1, "tx idle-high in reset");
        check(busy == 1'b0, "busy should be 0 in reset");
        rst_n = 1'b1;
        @(negedge clk);
        check(tx == 1'b1, "tx idle-high after reset before any send");
        check(busy == 1'b0, "busy should be 0 after reset");

        send_and_capture(8'h55, "first byte 0x55");
        send_and_capture(8'hA5, "second byte 0xA5 after busy deassert");
        send_and_capture(8'h00, "byte 0x00");
        send_and_capture(8'hFF, "byte 0xFF");

        if (errors == 0) begin
            $display("TB_UARTTX: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_UARTTX: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_UARTTX: testbench FAILED");
        end
    end

endmodule

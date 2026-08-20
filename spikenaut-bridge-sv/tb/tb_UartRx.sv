// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_UartRx.sv
// Unit testbench for spikenaut-bridge-sv/rtl/UartRx.sv (#58)
//
// Stimulus is applied and sampled on negedge clk (mid-cycle) to avoid
// race conditions with the DUT's posedge-triggered always_ff block.

`timescale 1ns/1ps

module tb_UartRx;

    localparam int CLK_FREQ     = 1_000_000;
    localparam int BAUD_RATE    = 100_000;
    localparam int DATA_WIDTH   = 8;
    localparam int CLK_PERIOD   = 10;
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    logic                  clk;
    logic                  rst_n;
    logic                  rx;
    logic [DATA_WIDTH-1:0] data;
    logic                  valid;

    int errors = 0;
    int rx_count = 0;
    int valid_hold = 0;
    logic [DATA_WIDTH-1:0] last_rx;

    UartRx #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE  (BAUD_RATE),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .rx    (rx),
        .data  (data),
        .valid (valid)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // valid is a one-cycle strobe at the end of STOP, overlapping the
    // stop-bit hold in send_uart_byte. Capture it on posedge.
    always @(posedge clk) begin
        if (valid === 1'b1) begin
            last_rx     <= data;
            rx_count    <= rx_count + 1;
            valid_hold  <= valid_hold + 1;
        end else begin
            if (valid_hold > 1) begin
                errors++;
                $display("FAIL: valid held more than one clock");
            end
            valid_hold <= 0;
        end
    end

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

    // Drive one 8N1 byte on the async pin (LSB first). Hold each bit
    // CLKS_PER_BIT clocks; the 2FF sync is covered by the idle-high
    // reset plus a later baud-timed receive.
    task automatic send_uart_byte(input logic [DATA_WIDTH-1:0] b);
        int i;
        rx = 1'b0;
        repeat (CLKS_PER_BIT) @(negedge clk);
        for (i = 0; i < DATA_WIDTH; i++) begin
            rx = b[i];
            repeat (CLKS_PER_BIT) @(negedge clk);
        end
        rx = 1'b1;
        repeat (CLKS_PER_BIT) @(negedge clk);
    endtask

    task automatic send_and_check(input logic [DATA_WIDTH-1:0] expected, input string msg);
        int prev_count;
        prev_count = rx_count;
        send_uart_byte(expected);
        repeat (CLKS_PER_BIT * 4) @(negedge clk);
        check(rx_count == prev_count + 1, {msg, ": valid should pulse once per frame"});
        check_data(last_rx, expected, msg);
        check(valid == 1'b0, {msg, ": valid should return low after the pulse"});
    endtask

    initial begin
        rst_n = 1'b0;
        rx    = 1'b1;
        repeat (4) @(negedge clk);
        check(valid == 1'b0, "valid should be 0 in reset");
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        check(valid == 1'b0, "valid should stay 0 after reset on idle-high rx");

        send_and_check(8'h00, "byte 0x00");
        check(valid == 1'b0, "valid should stay low between frames");
        send_and_check(8'hFF, "byte 0xFF");
        check(valid == 1'b0, "valid should stay low after the last frame");

        send_and_check(8'h55, "byte 0x55");
        check(valid == 1'b0, "valid should stay low between 0x55 and 0xA5");
        send_and_check(8'hA5, "byte 0xA5");
        check(valid == 1'b0, "valid should return low after 0xA5");

        if (errors == 0) begin
            $display("TB_UARTRX: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_UARTRX: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_UARTRX: testbench FAILED");
        end
    end

endmodule

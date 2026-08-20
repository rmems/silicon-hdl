// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_SiliconBridge.sv
// Unit testbench for spikenaut-bridge-sv/rtl/SiliconBridge.sv (#58)
//
// Stimulus is applied and sampled on negedge clk (mid-cycle) to avoid
// race conditions with the DUT's posedge-triggered always_ff blocks.
// Loopback ties uart_tx_pin to uart_rx_pin so TX→RX exercises the wrapper.

`timescale 1ns/1ps

module tb_SiliconBridge;

    localparam int CLK_FREQ     = 1_000_000;
    localparam int BAUD_RATE    = 100_000;
    localparam int DATA_WIDTH   = 8;
    localparam int CLK_PERIOD   = 10;
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    logic                  clk;
    logic                  rst_n;
    logic                  uart_rx_pin;
    logic                  uart_tx_pin;
    logic [DATA_WIDTH-1:0] rx_data;
    logic                  rx_valid;
    logic [DATA_WIDTH-1:0] tx_data;
    logic                  tx_send;
    logic                  tx_busy;

    int errors = 0;

    SiliconBridge #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE  (BAUD_RATE),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .uart_rx_pin (uart_rx_pin),
        .uart_tx_pin (uart_tx_pin),
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .tx_data     (tx_data),
        .tx_send     (tx_send),
        .tx_busy     (tx_busy)
    );

    assign uart_rx_pin = uart_tx_pin;

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

    task automatic pulse_send(input logic [DATA_WIDTH-1:0] b);
        check(tx_busy == 1'b0, "must wait for !tx_busy before tx_send");
        tx_data = b;
        tx_send = 1'b1;
        @(negedge clk);
        tx_send = 1'b0;
    endtask

    task automatic send_loopback(input logic [DATA_WIDTH-1:0] expected, input string msg);
        int i;
        bit seen;
        seen = 1'b0;
        pulse_send(expected);
        check(tx_busy == 1'b1, "tx_busy should assert after tx_send");
        for (i = 0; i < (CLKS_PER_BIT * 16); i++) begin
            @(negedge clk);
            if (rx_valid === 1'b1) begin
                check_data(rx_data, expected, msg);
                seen = 1'b1;
                break;
            end
        end
        check(seen, {msg, ": timed out waiting for rx_valid"});
        while (tx_busy !== 1'b0)
            @(negedge clk);
    endtask

    initial begin
        rst_n   = 1'b0;
        tx_data = '0;
        tx_send = 1'b0;
        repeat (4) @(negedge clk);
        check(tx_busy == 1'b0, "tx_busy 0 in reset");
        check(rx_valid == 1'b0, "rx_valid 0 in reset");
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        send_loopback(8'h3C, "loopback 0x3C");
        send_loopback(8'h81, "loopback 0x81");
        send_loopback(8'h00, "loopback 0x00");
        send_loopback(8'hFF, "loopback 0xFF");

        @(negedge clk);
        check(rx_valid == 1'b0, "rx_valid is a one-cycle strobe after the byte");

        if (errors == 0) begin
            $display("TB_SILICONBRIDGE: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_SILICONBRIDGE: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_SILICONBRIDGE: testbench FAILED");
        end
    end

endmodule

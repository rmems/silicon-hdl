// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_NeuronParamRam_init.sv
// Canonical source: spikenaut-core-sv/tb
// Verifies NeuronParamRam INIT_FILE / $readmemh against merged_v2 thresholds.
// Stimulus on negedge clk (matches other core testbenches).

`timescale 1ns/1ps

// INIT is a module parameter so Vivado sim_core.tcl can pass an absolute path
// via set_property generic (XSim CWD is the sim run dir, not the repo root).
// Default: repo-root-relative for Verilator CI / local `./obj_dir` from silicon-hdl/.
module tb_NeuronParamRam_init #(
    parameter string INIT = "spikenaut-core-sv/mem/merged_v2_thresholds.mem"
);

    // merged_v2_thresholds.mem has 16 data lines → ADDR_WIDTH=4.
    localparam int ADDR_WIDTH  = 4;
    localparam int PARAM_WIDTH = 16;
    localparam int CLK_PERIOD  = 10;

    logic                    clk;
    logic                    rst_n;
    logic                    we;
    logic [ADDR_WIDTH-1:0]   addr;
    logic [PARAM_WIDTH-1:0]  din;
    logic [PARAM_WIDTH-1:0]  dout;

    int errors = 0;

    NeuronParamRam #(
        .ADDR_WIDTH  (ADDR_WIDTH),
        .PARAM_WIDTH (PARAM_WIDTH),
        .INIT_FILE   (INIT)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .we    (we),
        .addr  (addr),
        .din   (din),
        .dout  (dout)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic check(input logic cond, input string msg);
        if ($isunknown(cond)) begin
            errors++;
            $display("FAIL (unknown): %s", msg);
        end else if (!cond) begin
            errors++;
            $display("FAIL: %s", msg);
        end
    endtask

    task automatic read_addr(input logic [ADDR_WIDTH-1:0] a,
                             output logic [PARAM_WIDTH-1:0] q);
        we   = 1'b0;
        addr = a;
        din  = '0;
        @(negedge clk);
        @(negedge clk);
        q = dout;
    endtask

    logic [PARAM_WIDTH-1:0] q;

    initial begin
        we    = 1'b0;
        addr  = '0;
        din   = '0;
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // exp-025 bank (GH#73): merged_v2_thresholds.mem: line0=019A, line1=0199, line2=019A
        read_addr(4'd0, q);
        check(q === 16'h019A, "mem[0] should be 019A after $readmemh");

        read_addr(4'd1, q);
        check(q === 16'h0199, "mem[1] should be 0199 after $readmemh");

        read_addr(4'd2, q);
        check(q === 16'h019A, "mem[2] should be 019A after $readmemh");

        @(negedge clk);
        we   = 1'b1;
        addr = 4'd1;
        din  = 16'hABCD;
        @(negedge clk);
        we = 1'b0;
        read_addr(4'd1, q);
        check(q === 16'hABCD, "write after init should stick");

        if (errors == 0)
            $display("tb_NeuronParamRam_init: PASS");
        else begin
            $display("tb_NeuronParamRam_init: FAIL (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end

endmodule

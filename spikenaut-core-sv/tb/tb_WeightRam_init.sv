// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_WeightRam_init.sv
// Canonical source: spikenaut-core-sv/tb
// Verifies WeightRam INIT_FILE / $readmemh against merged_v2 weight image.
// Stimulus on negedge clk (matches other core testbenches).

`timescale 1ns/1ps

// INIT is a module parameter so Vivado sim_core.tcl can pass an absolute path
// via set_property generic (XSim CWD is the sim run dir, not the repo root).
// Default: repo-root-relative for Verilator CI / local `./obj_dir` from silicon-hdl/.
module tb_WeightRam_init #(
    parameter string INIT = "spikenaut-core-sv/mem/merged_v2_weights.mem"
);

    // merged_v2_weights.mem has 256 data lines → ADDR_WIDTH=8 (not default 10).
    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 16;
    localparam int CLK_PERIOD = 10;

    logic                   clk;
    logic                   rst_n;
    logic                   we;
    logic [ADDR_WIDTH-1:0]  addr;
    logic [DATA_WIDTH-1:0]  din;
    logic [DATA_WIDTH-1:0]  dout;

    int errors = 0;

    WeightRam #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .INIT_FILE  (INIT)
    ) dut (
        .clk  (clk),
        .rst_n (rst_n),
        .we   (we),
        .addr (addr),
        .din  (din),
        .dout (dout)
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

    // Drive on negedge; allow one posedge for the synchronous read, sample next negedge.
    task automatic read_addr(input logic [ADDR_WIDTH-1:0] a,
                             output logic [DATA_WIDTH-1:0] q);
        we   = 1'b0;
        addr = a;
        din  = '0;
        @(negedge clk);
        @(negedge clk);
        q = dout;
    endtask

    logic [DATA_WIDTH-1:0] q;

    initial begin
        we   = 1'b0;
        addr = '0;
        din  = '0;
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // exp-025 bank (GH#73): merged_v2_weights.mem: line0=0134, line1=000E, line3=0001
        read_addr(8'd0, q);
        check(q === 16'h0134, "mem[0] should be 0134 after $readmemh");

        read_addr(8'd1, q);
        check(q === 16'h000E, "mem[1] should be 000E after $readmemh");

        read_addr(8'd3, q);
        check(q === 16'h0001, "mem[3] should be 0001 after $readmemh");

        // Runtime write still works over init (write on this posedge via setup at negedge)
        @(negedge clk);
        we   = 1'b1;
        addr = 8'd1;
        din  = 16'h1234;
        @(negedge clk); // write commits on intervening posedge
        we = 1'b0;
        read_addr(8'd1, q);
        check(q === 16'h1234, "write after init should stick");

        if (errors == 0)
            $display("tb_WeightRam_init: PASS");
        else begin
            $display("tb_WeightRam_init: FAIL (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end

endmodule

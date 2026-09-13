// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_OutputLayer.sv
// Canonical source: spikenaut-core-sv/tb
// Unit testbench for OutputLayer.sv (#72), instantiating the real WeightRam
// (not a behavioral shadow) so INIT_FILE loading and the accumulate datapath
// are both proven together, mirroring tb_WeightRam_init.sv's real-file
// pattern and tb_LifNeuronArray.sv's real-shipped-bank cross-check.
//
// Stimulus and checks run on negedge clk to avoid races with the DUT's
// posedge-triggered always_ff blocks.

`timescale 1ns/1ps

// INIT_FILE is a module parameter so Vivado sim_core.tcl can pass an
// absolute path via set_property generic (XSim CWD is the sim run dir, not
// the repo root). Default: repo-root-relative for Verilator CI / local
// `./obj_dir` from silicon-hdl/.
module tb_OutputLayer #(
    parameter string INIT_FILE = "spikenaut-core-sv/mem/merged_v2_output_weights.mem"
);

    localparam int DATA_WIDTH        = 16;
    localparam int NUM_NEURONS       = 16;
    localparam int NUM_CLASSES       = 3;
    localparam int WEIGHT_ADDR_WIDTH = 6;   // 2**6=64 >= 48 entries
    localparam int CLK_PERIOD        = 10;

    logic                          clk;
    logic                          rst_n;
    logic                          spike_valid;
    logic [NUM_NEURONS-1:0]        spike_bitmap;
    logic [DATA_WIDTH-1:0]         weight_dout;
    logic [WEIGHT_ADDR_WIDTH-1:0]  weight_addr;
    logic [NUM_CLASSES-1:0]        result;
    logic                          done;

    int errors = 0;

    WeightRam #(
        .ADDR_WIDTH (WEIGHT_ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .INIT_FILE  (INIT_FILE)
    ) u_wram (
        .clk  (clk),
        .rst_n (rst_n),
        .we   (1'b0),
        .addr (weight_addr),
        .din  ('0),
        .dout (weight_dout)
    );

    OutputLayer #(
        .DATA_WIDTH        (DATA_WIDTH),
        .NUM_NEURONS       (NUM_NEURONS),
        .NUM_CLASSES       (NUM_CLASSES),
        .WEIGHT_ADDR_WIDTH (WEIGHT_ADDR_WIDTH)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .spike_valid  (spike_valid),
        .spike_bitmap (spike_bitmap),
        .weight_dout  (weight_dout),
        .weight_addr  (weight_addr),
        .result       (result),
        .done         (done)
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
            $display("FAIL: %s (got 0x%04h, expected 0x%04h)", msg, actual, expected);
        end
    endtask

    task automatic run_layer(input logic [NUM_NEURONS-1:0] bitmap);
        int unsigned waited;
        begin
            spike_bitmap = bitmap;
            @(negedge clk);
            spike_valid = 1'b1;
            @(negedge clk);
            spike_valid = 1'b0;
            waited = 0;
            while (done !== 1'b1 && waited < 80) begin
                @(negedge clk);
                waited++;
            end
            check(done === 1'b1, "OutputLayer sweep must finish within 80 fabric cycles");
        end
    endtask

    initial begin
        logic [DATA_WIDTH-1:0] shipped [0:47];
        int best;

        rst_n        = 1'b0;
        spike_valid  = 1'b0;
        spike_bitmap = '0;
        repeat (2) @(negedge clk);
        check(result === '0, "reset: result must be clear");
        rst_n = 1'b1;
        @(negedge clk);

        // (a) INIT_FILE loads the real shipped bank: addr 0 (neuron 0 class
        // 0) is 0x0060 in merged_v2_output_weights.mem.
        check_data(u_wram.mem[0], 16'h0060,
                   "mem[0] should be 0060 after $readmemh");

        // (b) Synthetic negative weight subtracts, not a huge unsigned
        // misread (mirrors tb_LifNeuron.sv's inhibitory check). Override
        // neuron 0 class 0's weight; only neuron 0 fires.
        u_wram.mem[0] = -16'sd10;
        run_layer(16'h0001);
        check_data(dut.class_acc[0], -16'sd10,
                   "GH#72: a negative output weight must subtract (-10), not misread as a huge positive value");

        // (c) Real shipped-bank cross-check (mirrors tb_LifNeuronArray.sv's
        // REAL_INHIB_NEURON pattern): load the bank independently via
        // $readmemh (not hand-copied constants) and fire only neuron 15.
        $readmemh(INIT_FILE, shipped);
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        run_layer(16'h8000);
        check_data(dut.class_acc[0], shipped[45],
                   "GH#72: neuron 15's own class-0 weight must be reachable and unmodified");
        check_data(dut.class_acc[1], shipped[46],
                   "GH#72: neuron 15's own class-1 weight must be reachable and unmodified");
        check_data(dut.class_acc[2], shipped[47],
                   "GH#72: neuron 15's own class-2 weight must be reachable and unmodified");

        begin
            automatic logic signed [DATA_WIDTH-1:0] class_score [0:2];
            automatic logic signed [DATA_WIDTH-1:0] best_score;
            class_score[0] = $signed(shipped[45]);
            class_score[1] = $signed(shipped[46]);
            class_score[2] = $signed(shipped[47]);
            best       = 0;
            best_score = class_score[0];
            for (int c = 1; c < 3; c++) begin
                if (class_score[c] > best_score) begin
                    best       = c;
                    best_score = class_score[c];
                end
            end
        end
        check(result === (3'b001 << best),
              "GH#72: argmax over the real shipped row must pick the class with the highest score");

        // (d) Overflow saturation: 16 large-magnitude weights on one class
        // column, all neurons firing, must saturate instead of wrapping.
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        for (int n = 0; n < NUM_NEURONS; n++) begin
            u_wram.mem[n*NUM_CLASSES + 0] =  16'sd8000;   // sums to 128000, forces +saturate
            u_wram.mem[n*NUM_CLASSES + 1] = -16'sd8000;   // sums to -128000, forces -saturate
        end
        run_layer(16'hFFFF);
        check_data(dut.class_acc[0], 16'h7FFF,
                   "GH#72: class accumulator must saturate at MAX_MEM, not wrap, on positive overflow");
        check_data(dut.class_acc[1], 16'h8000,
                   "GH#72: class accumulator must saturate at MIN_MEM, not wrap, on negative overflow");
        check(result === 3'b001,
              "GH#72: saturated MAX class must win the argmax over the saturated MIN class");

        // (e) FSM sanity: done is a one-cycle strobe; result holds between
        // ticks rather than resetting to zero while idle.
        @(negedge clk);
        check(done === 1'b0, "done must deassert one cycle after the strobe");
        begin
            logic [NUM_CLASSES-1:0] held;
            held = result;
            repeat (20) @(negedge clk);
            check(result === held, "result must hold its value while idle between ticks");
            check(done === 1'b0, "done must stay low while idle between ticks");
        end

        if (errors == 0) begin
            $display("TB_OUTPUTLAYER: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_OUTPUTLAYER: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_OUTPUTLAYER: testbench FAILED");
        end
    end

endmodule

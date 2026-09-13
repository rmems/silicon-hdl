// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_LifNeuronArray.sv
// Canonical source: spikenaut-core-sv/tb
// Unit testbench for the time-multiplexed N=16 LifNeuronArray PE.
//
// The local RAM models preserve the synchronous, one-fabric-cycle registered
// read contract of WeightRam and NeuronParamRam.  Stimulus and checks use
// negedge clk to avoid races with the DUT and RAM models at posedge clk.

`timescale 1ns/1ps

module tb_LifNeuronArray;

    localparam int DATA_WIDTH        = 16;
    localparam int PARAM_WIDTH       = 16;
    localparam int NUM_NEURONS       = 16;
    localparam int INDEX_WIDTH       = $clog2(NUM_NEURONS);
    localparam int PARAM_ADDR_WIDTH  = 8;
    localparam int WEIGHT_ADDR_WIDTH = 8;
    localparam int CLK_PERIOD        = 10;
    localparam logic [INDEX_WIDTH-1:0] SELECTED_INPUT = 4'd3;
    // GH#73: dedicated row for the signed Dale-inhibitory regression test below.
    localparam int INHIB_NEURON = 2;

    logic                         clk;
    logic                         rst_n;
    logic                         step_en;
    logic                         spike_in;
    logic [INDEX_WIDTH-1:0]       input_index;
    logic [DATA_WIDTH-1:0]        weight_dout;
    logic [PARAM_WIDTH-1:0]       threshold_dout;
    logic [PARAM_WIDTH-1:0]       leak_dout;
    logic [PARAM_ADDR_WIDTH-1:0]  threshold_addr;
    logic [PARAM_ADDR_WIDTH-1:0]  leak_addr;
    logic [WEIGHT_ADDR_WIDTH-1:0] weight_addr;
    logic [NUM_NEURONS-1:0]       spike_bitmap;
    logic [NUM_NEURONS*DATA_WIDTH-1:0] membrane_potentials;
    logic                         tick_done;

    logic [DATA_WIDTH-1:0]  weight_mem [0:NUM_NEURONS*NUM_NEURONS-1];
    logic [PARAM_WIDTH-1:0] threshold_mem [0:NUM_NEURONS-1];
    logic [PARAM_WIDTH-1:0] leak_mem [0:NUM_NEURONS-1];

    logic [NUM_NEURONS-1:0] seen_threshold_addr;
    logic [NUM_NEURONS-1:0] seen_leak_addr;
    logic [NUM_NEURONS-1:0] seen_weight_row;
    int errors = 0;

    LifNeuronArray #(
        .DATA_WIDTH        (DATA_WIDTH),
        .PARAM_WIDTH       (PARAM_WIDTH),
        .NUM_NEURONS       (NUM_NEURONS),
        .PARAM_ADDR_WIDTH  (PARAM_ADDR_WIDTH),
        .WEIGHT_ADDR_WIDTH (WEIGHT_ADDR_WIDTH)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .step_en        (step_en),
        .spike_in       (spike_in),
        .input_index    (input_index),
        .weight_dout    (weight_dout),
        .threshold_dout (threshold_dout),
        .leak_dout      (leak_dout),
        .threshold_addr (threshold_addr),
        .leak_addr      (leak_addr),
        .weight_addr    (weight_addr),
        .spike_bitmap   (spike_bitmap),
        .membrane_potentials (membrane_potentials),
        .tick_done      (tick_done)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Registered models mirror the three external single-port RAM read paths.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            threshold_dout <= '0;
            leak_dout      <= '0;
            weight_dout    <= '0;
        end else begin
            threshold_dout <= threshold_mem[threshold_addr[INDEX_WIDTH-1:0]];
            leak_dout      <= leak_mem[leak_addr[INDEX_WIDTH-1:0]];
            weight_dout    <= weight_mem[weight_addr];
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
            $display("FAIL: %s (got %0d, expected %0d)", msg, actual, expected);
        end
    endtask

    // Record the address presented for the next registered RAM read.  This is
    // deliberately called from run_tick's single control process at negedge,
    // after the preceding posedge has settled the PE's prefetched address.
    // Keeping ownership of these coverage maps in one process avoids a
    // simulator-dependent multi-process scheduling race in the testbench.
    task automatic record_sweep_addresses();
        begin
            if (threshold_addr < NUM_NEURONS)
                seen_threshold_addr[threshold_addr[INDEX_WIDTH-1:0]] = 1'b1;
            if (leak_addr < NUM_NEURONS)
                seen_leak_addr[leak_addr[INDEX_WIDTH-1:0]] = 1'b1;
            for (int i = 0; i < NUM_NEURONS; i++) begin
                if (weight_addr == WEIGHT_ADDR_WIDTH'((i * NUM_NEURONS) + SELECTED_INPUT))
                    seen_weight_row[i] = 1'b1;
            end
        end
    endtask

    task automatic run_tick(
        input logic event_present,
        input logic [INDEX_WIDTH-1:0] selected_channel,
        output int unsigned sweep_cycles
    );
        begin
            @(negedge clk);
            spike_in   = event_present;
            input_index = selected_channel;
            step_en    = 1'b1;
            // In IDLE the PE presents row 0.  The upcoming posedge samples
            // this address into the external registered RAMs.
            record_sweep_addresses();
            @(negedge clk);
            step_en = 1'b0;
            record_sweep_addresses();

            sweep_cycles = 0;
            while (tick_done !== 1'b1 && sweep_cycles < NUM_NEURONS + 2) begin
                @(negedge clk);
                record_sweep_addresses();
                sweep_cycles++;
            end
            check(tick_done === 1'b1,
                  "time-multiplexed sweep must finish within NUM_NEURONS + 2 fabric cycles");
        end
    endtask

    initial begin
        int unsigned sweep_cycles;
        logic [NUM_NEURONS-1:0] expected_first_spikes;

        // Populate all 256 matrix entries.  The selected column has unique
        // row-specific values, so a bad row/column address changes the result.
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            threshold_mem[neuron] = DATA_WIDTH'(150 + neuron * 3);
            leak_mem[neuron]      = PARAM_WIDTH'(neuron + 1);
            for (int channel = 0; channel < NUM_NEURONS; channel++)
                weight_mem[neuron * NUM_NEURONS + channel] =
                    DATA_WIDTH'(1 + neuron * NUM_NEURONS + channel);

            if ((neuron % 4) == 0)
                weight_mem[neuron * NUM_NEURONS + SELECTED_INPUT] =
                    threshold_mem[neuron] + 16'd10;
            else
                weight_mem[neuron * NUM_NEURONS + SELECTED_INPUT] =
                    DATA_WIDTH'(50 + neuron * 2);
        end

        expected_first_spikes = 16'h1111;
        rst_n           = 1'b0;
        step_en         = 1'b0;
        spike_in        = 1'b0;
        input_index     = SELECTED_INPUT;
        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        repeat (2) @(negedge clk);
        check_data(spike_bitmap, '0, "spike bitmap must reset low");
        rst_n = 1'b1;

        // First logical tick: each neuron receives the broadcast event.  Four
        // rows cross their own threshold; the output stays uncommitted until
        // tick_done despite per-slot processing.
        @(negedge clk);
        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        run_tick(1'b1, SELECTED_INPUT, sweep_cycles);

        check(sweep_cycles <= NUM_NEURONS + 1,
              "N=16 sweep must complete far inside the 100,000-cycle SoC tick budget");
        check_data(spike_bitmap, expected_first_spikes,
                   "spike bitmap must set exactly rows that cross their own threshold");
        check(seen_threshold_addr == {NUM_NEURONS{1'b1}},
              "every threshold address 0..15 must be requested during the sweep");
        check(seen_leak_addr == {NUM_NEURONS{1'b1}},
              "every leak address 0..15 must be requested during the sweep");
        check(seen_weight_row == {NUM_NEURONS{1'b1}},
              "every neuron weight row must be requested at the selected input column");

        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            check_data(dut.membrane_potential[neuron],
                       weight_mem[neuron * NUM_NEURONS + SELECTED_INPUT],
                       "first sweep must retain each row's own integrated membrane value");
            check_data(membrane_potentials[neuron*DATA_WIDTH +: DATA_WIDTH],
                       weight_mem[neuron * NUM_NEURONS + SELECTED_INPUT],
                       "packed membrane readback must preserve each row's own state");
        end

        // Second tick has no event.  Previously spiking neurons take their
        // own refractory reset; all others use their own leak and retain no
        // state from another neuron slot.
        run_tick(1'b0, SELECTED_INPUT, sweep_cycles);
        check_data(spike_bitmap, '0,
                   "refractory/reset sweep with no input must produce no spikes");
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            if ((neuron % 4) == 0)
                check_data(dut.membrane_potential[neuron], '0,
                           "a neuron that spiked must reset only its own membrane on the next tick");
            else
                check_data(dut.membrane_potential[neuron], DATA_WIDTH'(49 + neuron),
                           "a non-spiking neuron must apply its own row's leak without cross-neuron state");
        end

        // ------------------------------------------------------------
        // GH#73: a Dale-inhibitory row must subtract, not misread as a huge
        // positive add. Reset first so this row's membrane starts from a
        // known 0, independent of the broadcast history above. Weight and
        // threshold are picked so an unsigned misread of the weight
        // (0xFF00 = 65280) would falsely cross this small positive
        // threshold, but the correct signed read (-256, i.e. -1.0 Q8.8)
        // does not.
        // ------------------------------------------------------------
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        weight_mem[INHIB_NEURON * NUM_NEURONS + SELECTED_INPUT] = 16'hFF00;  // -256 Q8.8 (-1.0)
        threshold_mem[INHIB_NEURON] = 16'd50;                                // 0.195: an unsigned misread would cross
        leak_mem[INHIB_NEURON]      = 16'd40;

        run_tick(1'b1, SELECTED_INPUT, sweep_cycles);
        check(spike_bitmap[INHIB_NEURON] == 1'b0,
              "GH#73: an inhibitory row (-256 Q8.8) must not falsely spike against a small positive threshold");
        check_data(dut.membrane_potential[INHIB_NEURON], 16'hFF00,
                   "inhibitory row's membrane must be the signed weight itself (0 + -256), not a huge positive value");

        // Leak-only tick: the negative membrane must recover toward 0 by
        // its own leak, not stay pinned or wrap.
        run_tick(1'b0, SELECTED_INPUT, sweep_cycles);
        check(spike_bitmap[INHIB_NEURON] == 1'b0,
              "leak-only recovery of an inhibited row must never spike");
        check_data(dut.membrane_potential[INHIB_NEURON], -16'sd216,
                   "inhibitory row's membrane must recover by its own leak (-256+40=-216)");

        if (errors == 0) begin
            $display("TB_LIFNEURONARRAY: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_LIFNEURONARRAY: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_LIFNEURONARRAY: testbench FAILED");
        end
    end

endmodule

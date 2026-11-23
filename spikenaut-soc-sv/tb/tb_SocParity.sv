// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_SocParity.sv
// Canonical source: spikenaut-soc-sv/tb
// GH#76 supervisor-parity harness: replays the committed
// testdata/supervisor_parity fixture through the real SoC at the UART
// wire level and writes the observed per-step trace as JSON for
// scripts/parity_compare.py.
//
// What this TB deliberately does NOT do is compare against the expected
// trace itself: the comparator is Python (parity_compare.py), so the same
// observed artifact can be diffed against either the committed
// expected_trace.json (sim run) or a physical-board capture (manual
// recipe) with identical semantics. This TB's own checks only cover the
// replay mechanics: every consumed frame is answered exactly once, and
// the schedule lands on the manifest's consumed-tick alignment.
//
// Schedule (docs/supervisor-parity.md): after a captured response the TB
// idles POST_RESPONSE_WAIT cycles, then sends the next 33-byte frame.
// Response (~3.12 ms) + wait (~0.5 ms) + request (~2.86 ms) puts RX_COMMIT
// mid-window at ~6.5 ms after the previous consumed tick, so consumed
// ticks are expected_consumed = 1 + step*TICKS_PER_FRAME (7) with a
// +/-half-tick margin. A drift in that alignment is reported, not hidden:
// the observed consumed_tick is written per step and the TB fails if it
// ever differs from the schedule the reference model assumed.
//
// $readmemh / $fopen paths are repo-root relative -- run from the repo
// root. Stimulus is applied and sampled on negedge clk, matching
// tb_Basys3_Top's race-free convention.

`timescale 1ns/1ps

module tb_SocParity #(
    parameter string STIMULI_FILE = "testdata/supervisor_parity/inputs.mem",
    parameter string COUNT_FILE   = "testdata/supervisor_parity/inputs_count.mem",
    parameter string OBSERVED_FILE = "testdata/supervisor_parity/observed.json",
    parameter string WEIGHT_INIT = "testdata/supervisor_parity/parameters_weights.mem",
    parameter string THRESH_INIT = "testdata/supervisor_parity/parameters.mem",
    parameter string LEAK_INIT   = "testdata/supervisor_parity/parameters_decay.mem",
    parameter string OUTPUT_WEIGHT_INIT = "testdata/supervisor_parity/parameters_output_weights.mem",
    parameter string ROUTE_INIT  = "testdata/supervisor_parity/aer_routes.mem"
);

    localparam int CLK_PERIOD   = 10;                     // 100 MHz
    localparam int CLK_FREQ     = 100_000_000;
    localparam int BAUD_RATE    = 115_200;
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;   // 868
    localparam int TICK_HZ      = 1000;
    localparam int STEP_DIV     = CLK_FREQ / TICK_HZ;     // 100_000
    localparam int NUM_NEURONS  = 16;

    // Parity schedule (manifest.schedule): consumed ticks are 4 + i*7.
    // A request needs ~2.86 ms on the wire, so the first frame cannot be
    // consumed before tick 3; the pre-send delay pushes its commit to
    // ~3.4 ms (mid-window) -> consumed at tick 4 = BASE_TICK.
    localparam int TICKS_PER_FRAME    = 7;
    localparam int BASE_TICK          = 4;
    localparam int PRE_SEND_WAIT      = 52_000;           // ~0.5 ms
    // Delay after the last captured response byte before the next request
    // starts: lands RX_COMMIT mid-window (~6.5 ms after the consumed tick).
    localparam int POST_RESPONSE_WAIT = 52_000;           // ~0.5 ms
    localparam int TICK_WAIT_BOUND    = STEP_DIV + 16;

    localparam int RESPONSE_BYTES    = 36;
    localparam int UART_BITS_PER_BYTE = 10;
    localparam int UART_BYTE_CLKS    = UART_BITS_PER_BYTE * CLKS_PER_BIT;
    localparam int UART_START_BOUND  = 4 * UART_BYTE_CLKS;
    // OutputLayer sweeps NUM_NEURONS x NUM_CLASSES pairs plus pipeline slack.
    localparam int OUTPUT_CLASS_BOUND = 80;
    localparam int MAX_STEPS          = 256;

    logic        clk;
    logic        btn_rst;
    logic        uart_rx_line;
    logic        uart_tx_line;
    logic [15:0] sw;
    logic [15:0] led;

    int errors = 0;
    int unsigned tick_count;
    int unsigned frame_send_count;

    logic [15:0] stimuli   [0:MAX_STEPS*NUM_NEURONS-1];
    logic [15:0] count_img [0:0];
    int          step_count;
    int          observed_fd;

    logic [7:0]  captured_frame [0:RESPONSE_BYTES-1];

    spikenaut_soc_basys3_top #(
        .WEIGHT_INIT_FILE (WEIGHT_INIT),
        .THRESH_INIT_FILE (THRESH_INIT),
        .LEAK_INIT_FILE   (LEAK_INIT),
        .OUTPUT_WEIGHT_INIT_FILE (OUTPUT_WEIGHT_INIT),
        .ROUTE_INIT_FILE  (ROUTE_INIT)
    ) dut (
        .clk     (clk),
        .rst_n   (btn_rst),
        .uart_rx (uart_rx_line),
        .uart_tx (uart_tx_line),
        .sw      (sw),
        .led     (led)
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

    // Tick / response counters, same free-running style as tb_Basys3_Top.
    initial begin
        tick_count       = 0;
        frame_send_count = 0;
    end

    always @(negedge clk) begin
        if (dut.step_en === 1'b1)
            tick_count++;
        if (dut.frame_send === 1'b1)
            frame_send_count++;
    end

    task automatic require_file(input string path);
        int fd;
        begin
            fd = $fopen(path, "r");
            if (fd == 0)
                $fatal(1, "required image missing: %s (run from repo root)", path);
            $fclose(fd);
        end
    endtask

    task automatic uart_send_byte(input logic [7:0] b);
        int i;
        begin
            uart_rx_line = 1'b0;
            repeat (CLKS_PER_BIT) @(negedge clk);
            for (i = 0; i < 8; i++) begin
                uart_rx_line = b[i];
                repeat (CLKS_PER_BIT) @(negedge clk);
            end
            uart_rx_line = 1'b1;
            repeat (CLKS_PER_BIT) @(negedge clk);
        end
    endtask

    task automatic uart_send_stimulus_words(input int base);
        begin
            uart_send_byte(8'hAA);
            for (int lane = 0; lane < NUM_NEURONS; lane++) begin
                uart_send_byte(stimuli[base + lane][15:8]);
                uart_send_byte(stimuli[base + lane][7:0]);
            end
        end
    endtask

    task automatic wait_for_stimuli_pending();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.stimuli_pending === 1'b1) break;
                if (waited > (2 * CLKS_PER_BIT + 16))
                    $fatal(1, "wait_for_stimuli_pending: frame not latched within %0d cycles", waited);
            end
        end
    endtask

    task automatic wait_for_route_resolution();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.route_resolved === 1'b1) break;
                if (waited > 32)
                    $fatal(1, "wait_for_route_resolution: route did not resolve within %0d cycles", waited);
            end
        end
    endtask

    // Advance to the negedge where step_en reads high, then past the posedge
    // that applies the tick (post-tick state observable).
    task automatic wait_tick_applied();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.step_en === 1'b1) break;
                if (waited >= TICK_WAIT_BOUND)
                    $fatal(1, "wait_tick_applied: no step_en within %0d cycles", waited);
            end
            @(negedge clk);
        end
    endtask

    task automatic wait_lif_sweep_done();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.u_lif_array.tick_done === 1'b1) break;
                if (waited > NUM_NEURONS + 2)
                    $fatal(1, "wait_lif_sweep_done: no tick_done within %0d cycles", waited);
            end
        end
    endtask

    task automatic wait_output_class_done();
        int unsigned waited;
        begin
            waited = 0;
            while (dut.output_class_valid !== 1'b1 && waited < OUTPUT_CLASS_BOUND) begin
                @(negedge clk);
                waited++;
            end
            if (dut.output_class_valid !== 1'b1)
                $fatal(1, "wait_output_class_done: no output_class_valid within %0d cycles", OUTPUT_CLASS_BOUND);
        end
    endtask

    // Receive one 8N1 character (tb_Basys3_Top's wire-level demodulator).
    task automatic uart_capture_byte(output logic [7:0] value, output bit ok);
        int unsigned waited;
        begin
            value = '0;
            ok    = 1'b0;

            waited = 0;
            while (uart_tx_line !== 1'b0 && waited < UART_START_BOUND) begin
                @(negedge clk);
                waited++;
            end
            if (uart_tx_line !== 1'b0)
                return;

            repeat (CLKS_PER_BIT / 2) @(negedge clk);
            if (uart_tx_line !== 1'b0)
                return;

            for (int bit_index = 0; bit_index < 8; bit_index++) begin
                repeat (CLKS_PER_BIT) @(negedge clk);
                value[bit_index] = uart_tx_line;
            end

            repeat (CLKS_PER_BIT) @(negedge clk);
            if (uart_tx_line !== 1'b1) begin
                errors++;
                $display("FAIL: stop bit was not high for byte 0x%02h", value);
                return;
            end
            ok = 1'b1;
        end
    endtask

    // Write one observed-step JSON object (compact, comparator-parsed).
    task automatic write_observed_step(
        input int step_index,
        input int unsigned consumed_tick,
        input logic [NUM_NEURONS-1:0] spike_word,
        input logic [15:0] aux_word,
        input logic [2:0] output_class,
        input bit last
    );
        begin
            $fwrite(observed_fd,
                    "  {\"step\":%0d,\"consumed_tick\":%0d,\"potentials\":[",
                    step_index, consumed_tick);
            for (int lane = 0; lane < NUM_NEURONS; lane++) begin
                // Response word is signed Q8.8; emit as signed decimal.
                automatic logic signed [15:0] word;
                word = {captured_frame[2*lane], captured_frame[2*lane+1]};
                $fwrite(observed_fd, "%0d", word);
                if (lane < NUM_NEURONS-1) $fwrite(observed_fd, ",");
            end
            $fdisplay(observed_fd,
                      "],\"spike_word\":%0d,\"aux_word\":%0d,\"output_class\":%0d}%s",
                      spike_word, aux_word, output_class, last ? "" : ",");
        end
    endtask

    initial begin
        btn_rst      = 1'b1;
        uart_rx_line = 1'b1;
        sw           = '0;   // STDP off (SW14=0), spike-LED view (SW15=0)

        require_file(STIMULI_FILE);
        require_file(COUNT_FILE);
        require_file(WEIGHT_INIT);
        require_file(THRESH_INIT);
        require_file(LEAK_INIT);
        require_file(OUTPUT_WEIGHT_INIT);
        require_file(ROUTE_INIT);

        $readmemh(STIMULI_FILE, stimuli);
        $readmemh(COUNT_FILE, count_img);
        step_count = int'(count_img[0]);
        if (step_count <= 0 || step_count > MAX_STEPS)
            $fatal(1, "inputs_count.mem out of range: %0d (vacuity guard)", step_count);

        repeat (10) @(negedge clk);
        btn_rst = 1'b0;
        repeat (PRE_SEND_WAIT) @(negedge clk);

        observed_fd = $fopen(OBSERVED_FILE, "w");
        if (observed_fd == 0)
            $fatal(1, "cannot open observed output file: %s", OBSERVED_FILE);

        $fdisplay(observed_fd,
                  "{\"fixture\":\"supervisor_parity_v1\",\"ticks_per_frame\":%0d,\"steps\":[",
                  TICKS_PER_FRAME);

        for (int step_index = 0; step_index < step_count; step_index++) begin
            int unsigned send_tick;
            int unsigned consumed_tick;
            logic [NUM_NEURONS-1:0] spike_word;
            logic [15:0] aux_word;
            logic [2:0] output_class;
            int unsigned expected_consumed;
            bit capture_ok;

            uart_send_stimulus_words(step_index * NUM_NEURONS);
            send_tick = tick_count;
            wait_for_stimuli_pending();
            wait_for_route_resolution();
            wait_tick_applied();
            consumed_tick = tick_count;
            wait_lif_sweep_done();
            // frame_send is a one-cycle pulse at tick_done; output_class
            // commits a few cycles later.
            check(dut.frame_send === 1'b1,
                  "consumed stimulus frame must arm one response");
            wait_output_class_done();
            output_class = dut.output_class;

            for (int b = 0; b < RESPONSE_BYTES; b++) begin
                uart_capture_byte(captured_frame[b], capture_ok);
                if (!capture_ok)
                    $fatal(1, "step %0d: no framed byte %0d of %0d on uart_tx",
                           step_index, b, RESPONSE_BYTES);
            end
            spike_word = {captured_frame[32], captured_frame[33]};
            aux_word   = {captured_frame[34], captured_frame[35]};

            expected_consumed = BASE_TICK + step_index * TICKS_PER_FRAME;
            check(consumed_tick === expected_consumed,
                  $sformatf("step %0d consumed at tick %0d, schedule says %0d",
                            step_index, consumed_tick, expected_consumed));
            check(send_tick <= consumed_tick,
                  "consumed tick must follow the send tick");

            write_observed_step(step_index, consumed_tick, spike_word, aux_word,
                                output_class, step_index == step_count-1);

            repeat (POST_RESPONSE_WAIT) @(negedge clk);
        end

        $fdisplay(observed_fd, "],\"frame_send_count\":%0d,\"elapsed_ticks\":%0d}",
                  frame_send_count, tick_count);
        $fclose(observed_fd);

        check_int(frame_send_count, step_count,
                  "exactly one response per consumed frame (no coalescing)");

        if (errors == 0) begin
            $display("TB_SOC_PARITY: ALL %0d STEPS REPLAYED (%0d ticks elapsed)",
                     step_count, tick_count);
            $display("TB_SOC_PARITY: observed trace written to %s", OBSERVED_FILE);
            $display("TB_SOC_PARITY: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_SOC_PARITY: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_SOC_PARITY: testbench FAILED");
        end
    end

    task automatic check_int(input int unsigned actual,
                             input int unsigned expected,
                             input string msg);
        if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (expected %0d, got %0d)", msg, expected, actual);
        end
    endtask

endmodule

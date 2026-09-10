// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_SocProtocolFsm.sv
// Canonical source: spikenaut-soc-sv/tb
// Unit testbench for the SoC-layer SiliconBridge v3.0 frame codec.
//
// Stimulus and checks run on negedge clk so they do not race the DUT's
// posedge-triggered state machines.

`timescale 1ns/1ps

module tb_SocProtocolFsm;

    localparam int NUM_NEURONS = 16;
    localparam int WORD_WIDTH  = 16;
    localparam int CLK_PERIOD  = 10;
    localparam int FRAME_BYTES = 36;
    localparam int WAIT_BOUND  = 32;
    // Short timeout so the abandon-path case stays cheap in Verilator.
    localparam int IDLE_TIMEOUT_CYCLES = 16;
    localparam logic [7:0] WRITE_SYNC_BYTE = 8'hA5;

    logic clk;
    logic rst_n;
    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_send;
    logic       tx_busy;
    logic [NUM_NEURONS*WORD_WIDTH-1:0] stimuli_out;
    logic                               stimuli_valid;
    logic [NUM_NEURONS*WORD_WIDTH-1:0] potentials_in;
    logic [NUM_NEURONS-1:0]             spike_flags;
    logic [WORD_WIDTH-1:0]              aux_state;
    logic                               frame_send;
    logic                               wr_en;
    logic [1:0]                         wr_target;
    logic [7:0]                         wr_addr;
    logic [WORD_WIDTH-1:0]              wr_data;
    logic                               rx_busy;
    logic                               rx_abort;
    logic                               tx_frame_active;
    logic [NUM_NEURONS*WORD_WIDTH-1:0] expected_potentials;
    logic [NUM_NEURONS-1:0]             expected_spike_flags;
    logic [WORD_WIDTH-1:0]              expected_aux_state;

    int errors = 0;
    int stimuli_valid_pulses = 0;
    int rx_abort_pulses = 0;
    int wr_en_pulses = 0;

    SocProtocolFsm #(
        .NUM_NEURONS           (NUM_NEURONS),
        .WORD_WIDTH            (WORD_WIDTH),
        .WRITE_SYNC_BYTE       (WRITE_SYNC_BYTE),
        .IDLE_TIMEOUT_CYCLES   (IDLE_TIMEOUT_CYCLES)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .rx_data       (rx_data),
        .rx_valid      (rx_valid),
        .tx_data       (tx_data),
        .tx_send       (tx_send),
        .tx_busy       (tx_busy),
        .stimuli_out   (stimuli_out),
        .stimuli_valid (stimuli_valid),
        .potentials_in (potentials_in),
        .spike_flags   (spike_flags),
        .aux_state       (aux_state),
        .frame_send      (frame_send),
        .wr_en           (wr_en),
        .wr_target       (wr_target),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .rx_busy         (rx_busy),
        .rx_abort        (rx_abort),
        .tx_frame_active (tx_frame_active)
    );

    // NUM_NEURONS=1 makes PAYLOAD_BYTES=2, so RX_COUNT_WIDTH must still
    // count a 4-byte write payload.  Separate RX pins so this instance
    // does not consume the N=16 stimulus stream.
    logic [7:0] rx_data_n1;
    logic       rx_valid_n1;
    logic       wr_en_n1;
    logic [1:0] wr_target_n1;
    logic [7:0] wr_addr_n1;
    logic [WORD_WIDTH-1:0] wr_data_n1;

    SocProtocolFsm #(
        .NUM_NEURONS         (1),
        .WORD_WIDTH          (WORD_WIDTH),
        .WRITE_SYNC_BYTE     (WRITE_SYNC_BYTE),
        .IDLE_TIMEOUT_CYCLES (IDLE_TIMEOUT_CYCLES)
    ) dut_n1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .rx_data       (rx_data_n1),
        .rx_valid      (rx_valid_n1),
        .tx_data       (),
        .tx_send       (),
        .tx_busy       (1'b0),
        .stimuli_out   (),
        .stimuli_valid (),
        .potentials_in ('0),
        .spike_flags   ('0),
        .aux_state     ('0),
        .frame_send    (1'b0),
        .wr_en         (wr_en_n1),
        .wr_target     (wr_target_n1),
        .wr_addr       (wr_addr_n1),
        .wr_data       (wr_data_n1),
        .rx_busy       (),
        .rx_abort      (),
        .tx_frame_active ()
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    always @(negedge clk) begin
        if (stimuli_valid === 1'b1)
            stimuli_valid_pulses++;
        if (rx_abort === 1'b1)
            rx_abort_pulses++;
        if (wr_en === 1'b1)
            wr_en_pulses++;
    end

    task automatic check(input logic condition, input string msg);
        if ($isunknown(condition)) begin
            errors++;
            $display("FAIL (unknown state): %s", msg);
        end else if (!condition) begin
            errors++;
            $display("FAIL: %s", msg);
        end
    endtask

    task automatic check_byte(
        input logic [7:0] actual,
        input logic [7:0] expected,
        input string msg
    );
        if ($isunknown(actual)) begin
            errors++;
            $display("FAIL (X/Z in byte): %s", msg);
        end else if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (got 0x%02h, expected 0x%02h)", msg, actual, expected);
        end
    endtask

    task automatic check_word(
        input logic [WORD_WIDTH-1:0] actual,
        input logic [WORD_WIDTH-1:0] expected,
        input string msg
    );
        if ($isunknown(actual)) begin
            errors++;
            $display("FAIL (X/Z in word): %s", msg);
        end else if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (got 0x%04h, expected 0x%04h)", msg, actual, expected);
        end
    endtask

    task automatic send_n1_rx_byte(input logic [7:0] value);
        begin
            @(negedge clk);
            rx_data_n1  = value;
            rx_valid_n1 = 1'b1;
            @(negedge clk);
            rx_valid_n1 = 1'b0;
        end
    endtask

    task automatic send_write_frame(
        input logic [7:0] target,
        input logic [7:0] addr,
        input logic [WORD_WIDTH-1:0] data
    );
        begin
            send_rx_byte(WRITE_SYNC_BYTE);
            send_rx_byte(target);
            send_rx_byte(addr);
            send_rx_byte(data[15:8]);
            send_rx_byte(data[7:0]);
        end
    endtask

    task automatic send_rx_byte(input logic [7:0] value);
        begin
            @(negedge clk);
            rx_data  = value;
            rx_valid = 1'b1;
            @(negedge clk);
            rx_valid = 1'b0;
        end
    endtask

    task automatic trigger_response();
        begin
            @(negedge clk);
            frame_send = 1'b1;
            @(negedge clk);
            frame_send = 1'b0;
        end
    endtask

    // Distinct per-lane potentials so a stale pending snapshot cannot match.
    task automatic load_live_snapshot(
        input logic [WORD_WIDTH-1:0] pot_base,
        input logic [NUM_NEURONS-1:0] spikes,
        input logic [WORD_WIDTH-1:0] aux
    );
        begin
            for (int lane = 0; lane < NUM_NEURONS; lane++)
                potentials_in[lane*WORD_WIDTH +: WORD_WIDTH] =
                    pot_base + WORD_WIDTH'(lane * 16'h0101);
            spike_flags = spikes;
            aux_state   = aux;
        end
    endtask

    task automatic remember_expected();
        begin
            expected_potentials  = potentials_in;
            expected_spike_flags = spike_flags;
            expected_aux_state   = aux_state;
        end
    endtask

    task automatic collect_response_bytes(input int unsigned start_index, input string msg);
        logic [7:0] captured;
        begin
            for (int byte_index = start_index; byte_index < FRAME_BYTES; byte_index++) begin
                wait_for_tx_byte(captured);
                check_byte(captured, expected_response_byte(byte_index), msg);
            end
        end
    endtask

    task automatic wait_for_tx_byte(output logic [7:0] captured);
        int unsigned waited;
        begin
            captured = '0;
            waited = 0;
            while (tx_send !== 1'b1 && waited < WAIT_BOUND) begin
                @(negedge clk);
                waited++;
            end
            check(tx_send === 1'b1,
                  "response serializer must present a byte within the bounded wait");
            check(tx_busy === 1'b0,
                  "tx_send may assert only while tx_busy is low");
            captured = tx_data;
            // Let the registered send pulse be consumed and deassert before a
            // caller asks for the next byte; otherwise consecutive task calls
            // would observe the same level-high strobe twice.
            @(negedge clk);
        end
    endtask

    function automatic logic [7:0] expected_response_byte(input int unsigned byte_index);
        begin
            if (byte_index < NUM_NEURONS * 2) begin
                expected_response_byte = expected_potentials[(byte_index / 2) * WORD_WIDTH +
                    ((1 - (byte_index % 2)) * 8) +: 8];
            end else if (byte_index < NUM_NEURONS * 2 + 2) begin
                expected_response_byte = expected_spike_flags
                    [(1 - ((byte_index - NUM_NEURONS * 2) % 2)) * 8 +: 8];
            end else begin
                expected_response_byte = expected_aux_state
                    [(1 - ((byte_index - NUM_NEURONS * 2 - 2) % 2)) * 8 +: 8];
            end
        end
    endfunction

    initial begin
        logic [7:0] observed;
        int baseline_pulses;

        rst_n         = 1'b0;
        rx_data       = '0;
        rx_valid      = 1'b0;
        rx_data_n1    = '0;
        rx_valid_n1   = 1'b0;
        tx_busy       = 1'b0;
        potentials_in = '0;
        spike_flags   = '0;
        aux_state     = '0;
        frame_send    = 1'b0;
        for (int lane = 0; lane < NUM_NEURONS; lane++)
            potentials_in[lane*WORD_WIDTH +: WORD_WIDTH] =
                WORD_WIDTH'(16'h4200 + lane * 16'h0101);
        spike_flags = 16'hA55A;
        aux_state   = 16'hC33C;
        expected_potentials  = potentials_in;
        expected_spike_flags = spike_flags;
        expected_aux_state   = aux_state;

        repeat (3) @(negedge clk);
        check(stimuli_out === '0, "reset must clear the packed stimulus bus");
        check(stimuli_valid === 1'b0, "reset must keep stimuli_valid low");
        check(wr_en === 1'b0, "reset must keep wr_en low");
        check(rx_busy === 1'b0, "reset must keep rx_busy low in RX_WAIT_SYNC");
        check(rx_abort === 1'b0, "reset must keep rx_abort low");
        rst_n = 1'b1;

        // A non-sync byte cannot start a frame or pulse the output-valid bit.
        baseline_pulses = stimuli_valid_pulses;
        send_rx_byte(8'h55);
        repeat (3) @(negedge clk);
        check(stimuli_valid === 1'b0, "non-sync byte must leave receive FSM idle");
        check(stimuli_valid_pulses === baseline_pulses,
              "non-sync byte must not create a stimulus-valid pulse");

        // Decode a complete 0xAA frame with idle cycles between every valid
        // strobe.  Every lane is unique, so swapped word or byte order fails.
        baseline_pulses = stimuli_valid_pulses;
        send_rx_byte(8'hAA);
        check(rx_busy === 1'b1, "rx_busy must track RX_COLLECT after sync");
        for (int lane = 0; lane < NUM_NEURONS; lane++) begin
            send_rx_byte(8'(8'h10 + lane));
            send_rx_byte(8'(8'h80 + lane));
        end
        check(rx_busy === 1'b1, "rx_busy must stay high through RX_COMMIT");
        @(negedge clk); // RX_COMMIT has now published the stable packed frame.
        check(stimuli_valid === 1'b1, "complete frame must pulse stimuli_valid exactly once");
        for (int lane = 0; lane < NUM_NEURONS; lane++) begin
            check_word(stimuli_out[lane*WORD_WIDTH +: WORD_WIDTH],
                       {8'(8'h10 + lane), 8'(8'h80 + lane)},
                       "receive path must assemble every Q8.8 lane big-endian");
        end
        @(negedge clk);
        check(stimuli_valid === 1'b0, "stimuli_valid must deassert after one fabric cycle");
        check(rx_busy === 1'b0, "rx_busy must return to RX_WAIT_SYNC after commit");
        check(stimuli_valid_pulses === baseline_pulses + 1,
              "complete frame must create exactly one stimulus-valid pulse");

        // Serialize the response in documented order with no back-pressure.
        // Change all live inputs after the trigger: every emitted byte must
        // still come from the snapshot held by the active frame buffer.
        trigger_response();
        potentials_in = '0;
        spike_flags   = '0;
        aux_state     = '0;
        for (int byte_index = 0; byte_index < FRAME_BYTES; byte_index++) begin
            wait_for_tx_byte(observed);
            check_byte(observed, expected_response_byte(byte_index),
                       "response frame byte order and big-endian packing must match the contract");
        end
        repeat (3) @(negedge clk);
        check(tx_send === 1'b0, "serializer must stop after exactly 36 bytes");

        // Repeat with busy asserted immediately after the first byte.  The
        // active byte must be held, no send may appear while busy, and the
        // resumed sequence must continue at byte one (never repeat byte zero).
        potentials_in = expected_potentials;
        spike_flags   = expected_spike_flags;
        aux_state     = expected_aux_state;
        trigger_response();
        wait_for_tx_byte(observed);
        check_byte(observed, expected_response_byte(0),
                   "skid test must begin with response byte zero");
        tx_busy = 1'b1;
        repeat (5) begin
            @(negedge clk);
            check(tx_send === 1'b0, "busy stall must suppress tx_send");
        end
        tx_busy = 1'b0;
        for (int byte_index = 1; byte_index < FRAME_BYTES; byte_index++) begin
            wait_for_tx_byte(observed);
            check_byte(observed, expected_response_byte(byte_index),
                       "busy release must resume without dropped or repeated bytes");
        end

        // Latest-wins pending: three distinguishable frame_send pulses while
        // the first response is still serializing. The first extra pulse is
        // aligned to a send_pending cycle (tx_send high) so a one-cycle SoC
        // tick cannot be dropped. The active frame must stay snapshot A;
        // the next frame must be snapshot D (latest pending), not B or C.
        load_live_snapshot(16'h1100, 16'h0001, 16'hA001);
        remember_expected();
        trigger_response();
        begin
            int unsigned waited;
            waited = 0;
            while (tx_send !== 1'b1 && waited < WAIT_BOUND) begin
                @(negedge clk);
                waited++;
            end
            check(tx_send === 1'b1,
                  "latest-wins active frame must present byte zero");
            check_byte(tx_data, expected_response_byte(0),
                       "latest-wins active frame must start with snapshot A");
            // tx_send high means send_pending is set; pulse here so a
            // one-cycle SoC tick is captured instead of dropped.
            load_live_snapshot(16'h2200, 16'h0002, 16'hB002);
            frame_send = 1'b1;
            @(negedge clk);
            frame_send = 1'b0;
            // Stall the remainder of A so later triggers cannot race the
            // serializer while we apply snapshots C and D.
            tx_busy = 1'b1;
        end
        load_live_snapshot(16'h3300, 16'h0004, 16'hC003);
        trigger_response();
        load_live_snapshot(16'h4400, 16'h0008, 16'hD004);
        trigger_response();
        load_live_snapshot(16'hFFFF, 16'hFFFF, 16'hFFFF);
        tx_busy = 1'b0;
        collect_response_bytes(1, "active frame must remain snapshot A while later triggers pend");
        load_live_snapshot(16'h4400, 16'h0008, 16'hD004);
        remember_expected();
        collect_response_bytes(0, "next frame must be the latest pending snapshot D");
        repeat (3) @(negedge clk);
        check(tx_send === 1'b0, "serializer must stop after the promoted pending frame");

        // RX abandon: start a frame, send a few payload bytes (including a
        // legal mid-payload 0xAA), idle past the timeout, then prove a fresh
        // 0xAA+payload commits cleanly instead of mixing with the remnant.
        baseline_pulses = stimuli_valid_pulses;
        send_rx_byte(8'hAA);
        check(rx_busy === 1'b1, "partial frame must keep rx_busy in RX_COLLECT");
        send_rx_byte(8'hAA);
        send_rx_byte(8'h11);
        send_rx_byte(8'h22);
        repeat (IDLE_TIMEOUT_CYCLES + 4) @(negedge clk);
        check(stimuli_valid === 1'b0, "idle timeout must not commit a partial RX frame");
        check(stimuli_valid_pulses === baseline_pulses,
              "idle timeout must not pulse stimuli_valid");
        check(rx_abort_pulses === 1, "idle timeout must pulse rx_abort");
        check(rx_busy === 1'b0, "idle timeout must return rx_busy to RX_WAIT_SYNC");
        send_rx_byte(8'hAA);
        for (int lane = 0; lane < NUM_NEURONS; lane++) begin
            send_rx_byte(8'(8'h30 + lane));
            send_rx_byte(8'(8'h40 + lane));
        end
        @(negedge clk);
        check(stimuli_valid === 1'b1, "fresh frame after idle timeout must commit");
        for (int lane = 0; lane < NUM_NEURONS; lane++) begin
            check_word(stimuli_out[lane*WORD_WIDTH +: WORD_WIDTH],
                       {8'(8'h30 + lane), 8'(8'h40 + lane)},
                       "post-timeout receive must assemble a complete new frame");
        end
        @(negedge clk);
        check(stimuli_valid === 1'b0, "post-timeout stimuli_valid must deassert after one cycle");
        check(stimuli_valid_pulses === baseline_pulses + 1,
              "post-timeout commit must create exactly one stimulus-valid pulse");

        // Write path (#63): a distinct 0xA5 frame overwrites one location
        // without publishing a stimulus or colliding with 0xAA decode.
        baseline_pulses = stimuli_valid_pulses;
        begin
            int baseline_writes;
            int baseline_aborts;
            baseline_writes = wr_en_pulses;
            send_write_frame(8'h00, 8'h07, 16'h1234);
            check(wr_en === 1'b1, "complete weight write must pulse wr_en");
            check(wr_target === 2'd0, "weight write target must be 0");
            check(wr_addr === 8'h07, "weight write must present the frame address");
            check_word(wr_data, 16'h1234, "weight write must assemble Q8.8 big-endian");
            @(negedge clk);
            check(wr_en === 1'b0, "wr_en must be a one-cycle strobe");
            check(wr_en_pulses === baseline_writes + 1,
                  "complete weight write must pulse wr_en once");
            check(stimuli_valid_pulses === baseline_pulses,
                  "a RAM write must not publish a stimulus frame");
            check(rx_busy === 1'b0, "write commit must return to RX_WAIT_SYNC");

            baseline_writes = wr_en_pulses;
            send_write_frame(8'h01, 8'h03, 16'hBEEF);
            check(wr_en === 1'b1, "complete threshold write must pulse wr_en");
            check(wr_target === 2'd1, "threshold write target must be 1");
            check(wr_addr === 8'h03, "threshold write must present the frame address");
            check_word(wr_data, 16'hBEEF, "threshold write must assemble Q8.8 big-endian");
            @(negedge clk);
            check(wr_en_pulses === baseline_writes + 1,
                  "complete threshold write must pulse wr_en once");

            baseline_writes = wr_en_pulses;
            send_write_frame(8'h03, 8'h01, 16'h00FF);
            check(wr_en === 1'b0, "invalid write target must not pulse wr_en");
            check(wr_en_pulses === baseline_writes,
                  "invalid write target must not increment wr_en");
            check(stimuli_valid_pulses === baseline_pulses,
                  "invalid write target must not publish a stimulus frame");

            // Mid-payload WRITE_SYNC_BYTE in a stimulus frame is data, not a write sync.
            baseline_writes = wr_en_pulses;
            send_rx_byte(8'hAA);
            send_rx_byte(WRITE_SYNC_BYTE);
            send_rx_byte(8'h5A);
            for (int lane = 1; lane < NUM_NEURONS; lane++) begin
                send_rx_byte(8'(8'h50 + lane));
                send_rx_byte(8'(8'h60 + lane));
            end
            @(negedge clk);
            check(stimuli_valid === 1'b1,
                  "stimulus with mid-payload WRITE_SYNC_BYTE must still commit");
            check_word(stimuli_out[15:0], {WRITE_SYNC_BYTE, 8'h5A},
                       "lane 0 must keep WRITE_SYNC_BYTE as Q8.8 data, not a write opcode");
            check(wr_en_pulses === baseline_writes,
                  "mid-payload WRITE_SYNC_BYTE must not create a RAM write");

            // Abandoned write uses the same idle timeout as stimulus RX.
            baseline_writes = wr_en_pulses;
            baseline_aborts = rx_abort_pulses;
            send_rx_byte(WRITE_SYNC_BYTE);
            send_rx_byte(8'h00);
            send_rx_byte(8'h02);
            repeat (IDLE_TIMEOUT_CYCLES + 4) @(negedge clk);
            check(wr_en === 1'b0, "idle timeout must not commit a partial write");
            check(wr_en_pulses === baseline_writes,
                  "idle timeout must not pulse wr_en");
            check(rx_abort_pulses === baseline_aborts + 1,
                  "write idle timeout must pulse rx_abort");
            check(rx_busy === 1'b0, "write idle timeout must return to RX_WAIT_SYNC");

            baseline_writes = wr_en_pulses;
            send_write_frame(8'h02, 8'h04, 16'h00A1);
            check(wr_en === 1'b1, "fresh leak write after timeout must pulse wr_en");
            check(wr_target === 2'd2, "leak write target must be 2");
            check(wr_addr === 8'h04, "leak write must present the frame address");
            check_word(wr_data, 16'h00A1, "leak write must assemble Q8.8 big-endian");
            @(negedge clk);
            check(wr_en === 1'b0, "leak wr_en must deassert after one fabric cycle");
            check(wr_en_pulses === baseline_writes + 1,
                  "fresh leak write must pulse wr_en once");
        end

        // NUM_NEURONS=1 must still complete a 4-byte write payload.
        send_n1_rx_byte(WRITE_SYNC_BYTE);
        send_n1_rx_byte(8'h00);
        send_n1_rx_byte(8'h09);
        send_n1_rx_byte(8'h12);
        send_n1_rx_byte(8'h34);
        check(wr_en_n1 === 1'b1, "NUM_NEURONS=1 write frame must pulse wr_en");
        check(wr_target_n1 === 2'd0, "NUM_NEURONS=1 write target must be 0");
        check(wr_addr_n1 === 8'h09, "NUM_NEURONS=1 write must present the frame address");
        check_word(wr_data_n1, 16'h1234, "NUM_NEURONS=1 write must assemble Q8.8 big-endian");
        @(negedge clk);
        check(wr_en_n1 === 1'b0, "NUM_NEURONS=1 wr_en must be a one-cycle strobe");

        if (errors == 0) begin
            $display("TB_SOCPROTOCOLFSM: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_SOCPROTOCOLFSM: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_SOCPROTOCOLFSM: testbench FAILED");
        end
    end

endmodule

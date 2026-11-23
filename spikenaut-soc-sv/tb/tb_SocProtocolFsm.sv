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
    localparam logic [7:0] READ_SYNC_BYTE  = 8'hA6;

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
    logic                               rd_req;
    logic [1:0]                         rd_target;
    logic [7:0]                         rd_addr;
    logic                               rd_ack;
    logic [WORD_WIDTH-1:0]              rd_dout;
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
    int rd_ack_pulses = 0;

    // #113 read-path model.  rd_grant_en gates the port grant: rd_ack marks
    // the request cycle, and rd_dout returns the addressed word one cycle
    // later — the registered read latency of WeightRam / NeuronParamRam.
    logic rd_grant_en;
    logic [WORD_WIDTH-1:0] rd_mem [0:255];

    assign rd_ack = rd_req && rd_grant_en;
    always_ff @(posedge clk) begin
        if (rd_ack)
            rd_dout <= rd_mem[rd_addr];
    end

    // Byte-stream monitor (#113).  Sending a 5-byte read frame takes ~10
    // fabric cycles while the serializer emits a byte every ~2 cycles into
    // an idle bridge, so sequenced task calls cannot observe every byte of
    // an interleaved response/dump stream.  Capture each tx_send byte into a
    // queue instead: stream_rd consumes it in order, and a fixed count is
    // the proof a stall or rejection emitted nothing.
    localparam int TX_STREAM_MAX = 4096;
    logic [7:0] tx_stream [0:TX_STREAM_MAX-1];
    int tx_stream_count = 0;
    int stream_rd = 0;

    always @(negedge clk) begin
        if ((rst_n === 1'b1) && (tx_send === 1'b1) &&
            (tx_stream_count < TX_STREAM_MAX)) begin
            tx_stream[tx_stream_count] = tx_data;
            tx_stream_count++;
        end
    end

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
        .rd_req          (rd_req),
        .rd_target       (rd_target),
        .rd_addr         (rd_addr),
        .rd_ack          (rd_ack),
        .rd_dout         (rd_dout),
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
        .rd_req        (),
        .rd_target     (),
        .rd_addr       (),
        .rd_ack        (1'b0),
        .rd_dout       ('0),
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
        if (rd_ack === 1'b1)
            rd_ack_pulses++;
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

    task automatic check_int(input int unsigned actual,
                             input int unsigned expected,
                             input string msg);
        if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (got %0d, expected %0d)", msg, actual, expected);
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

    task automatic send_read_frame(
        input logic [7:0] target,
        input logic [7:0] addr,
        input logic [15:0] len
    );
        begin
            send_rx_byte(READ_SYNC_BYTE);
            send_rx_byte(target);
            send_rx_byte(addr);
            send_rx_byte(len[15:8]);
            send_rx_byte(len[7:0]);
        end
    endtask

    // Discard everything captured so far; the next expectation applies to
    // bytes emitted from this point on.
    task automatic drain_stream();
        begin
            stream_rd = tx_stream_count;
        end
    endtask

    // Wait for the stream monitor to deliver one byte, then check it.  The
    // bound covers request/header latency plus a modest rd_ack stall; an
    // absent byte fails rather than hanging the run.
    task automatic expect_stream_byte(
        input logic [7:0] expected,
        input string msg
    );
        int unsigned waited;
        begin
            waited = 0;
            while ((stream_rd >= tx_stream_count) && (waited < WAIT_BOUND * 4)) begin
                @(negedge clk);
                waited++;
            end
            if (stream_rd >= tx_stream_count) begin
                errors++;
                $display("FAIL: %s (no byte arrived within %0d cycles)",
                         msg, WAIT_BOUND * 4);
            end else begin
                check_byte(tx_stream[stream_rd], expected, msg);
                stream_rd++;
            end
        end
    endtask

    // Check the five echoed header bytes plus `len` big-endian payload
    // words of one 0xA6 dump frame against the rd_mem model.
    task automatic expect_stream_dump(
        input logic [7:0] exp_target,
        input logic [7:0] exp_addr,
        input int unsigned len,
        input string msg
    );
        begin
            expect_stream_byte(READ_SYNC_BYTE, {msg, ": header sync"});
            expect_stream_byte(exp_target, {msg, ": header target"});
            expect_stream_byte(exp_addr, {msg, ": header addr"});
            expect_stream_byte(8'(len[15:8]), {msg, ": header len_hi"});
            expect_stream_byte(8'(len[7:0]), {msg, ": header len_lo"});
            for (int w = 0; w < len; w++) begin
                logic [15:0] exp_word;
                exp_word = rd_mem[exp_addr + 8'(w)];
                expect_stream_byte(exp_word[15:8],
                                   {msg, $sformatf(": word %0d hi", w)});
                expect_stream_byte(exp_word[7:0],
                                   {msg, $sformatf(": word %0d lo", w)});
            end
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
            check(wr_en === 1'b1, "complete AER route write must pulse wr_en");
            check(wr_target === 2'd3, "AER route write target must be 3");
            check(wr_addr === 8'h01, "AER route write must present the frame address");
            check_word(wr_data, 16'h00FF,
                       "AER route write must assemble its 16-bit entry big-endian");
            @(negedge clk);
            check(wr_en_pulses === baseline_writes + 1,
                  "complete AER route write must pulse wr_en once");

            baseline_writes = wr_en_pulses;
            send_write_frame(8'h04, 8'h01, 16'h00FF);
            check(wr_en === 1'b0, "target 4 must not pulse wr_en");
            check(wr_en_pulses === baseline_writes,
                  "target 4 must not increment wr_en");
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
            send_rx_byte(8'h03);
            send_rx_byte(8'h02);
            repeat (IDLE_TIMEOUT_CYCLES + 4) @(negedge clk);
            check(wr_en === 1'b0, "idle timeout must not commit a partial AER write");
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

        // ----------------------------------------------------------------
        // Read path (#113): a 0xA6 frame streams RAM words back through the
        // same serializer the 36-byte stimulus responses use.  The rd_mem
        // model makes every address return a distinct word, and the
        // tx_stream monitor catches bytes that arrive while read commands
        // are still being sent.
        // ----------------------------------------------------------------
        begin : read_tests
            int baseline_reads;
            int baseline_aborts;
            int stall_count;

            for (int i = 0; i < 256; i++)
                rd_mem[i] = 16'(16'hA000 + i);
            rd_grant_en = 1'b1;

            // Valid weight read: echoed 5-byte header, then payload words in
            // ascending address order, big-endian per word.
            baseline_reads = rd_ack_pulses;
            drain_stream();
            send_read_frame(8'h00, 8'h10, 16'd4);
            expect_stream_dump(8'h00, 8'h10, 4, "weight dump");
            check(rd_target === 2'd0,
                  "weight dump must hold rd_target = 0 through the request");
            check_int(rd_ack_pulses, baseline_reads + 4,
                      "a 4-word dump must fetch exactly four words");
            // The monitor records the last byte on the negedge it is
            // presented; the consume that clears dump_active lands on the
            // following posedge, so settle one cycle before checking.
            @(negedge clk);
            check(dut.dump_active === 1'b0 && tx_frame_active === 1'b0,
                  "dump must release dump_active/tx_frame_active after the last word");
            repeat (3) @(negedge clk);
            check_int(tx_stream_count, stream_rd,
                      "dump serializer must stop after the last payload byte");

            // Threshold and leak reads use the same machinery with their own
            // target echo; a request starting at 0xFE wraps the 8-bit space.
            drain_stream();
            send_read_frame(8'h01, 8'h21, 16'd2);
            expect_stream_dump(8'h01, 8'h21, 2, "threshold dump");
            check(rd_target === 2'd1,
                  "threshold dump must hold rd_target = 1 through the request");
            drain_stream();
            send_read_frame(8'h02, 8'hFE, 16'd3);
            expect_stream_dump(8'h02, 8'hFE, 3, "leak dump wrapping at 256");

            // Rejected requests are consumed silently, like invalid write
            // targets: no header, no rd_req, no lingering tx activity.
            baseline_reads = rd_ack_pulses;
            drain_stream();
            send_read_frame(8'h03, 8'h00, 16'd4);
            repeat (8) @(negedge clk);
            check(rd_req === 1'b0, "target 3 (AER table) must not issue a RAM read");
            check_int(rd_ack_pulses, baseline_reads,
                      "target 3 read must not fetch any words");
            check_int(tx_stream_count, stream_rd,
                      "target 3 read must not emit a dump frame");
            send_read_frame(8'h00, 8'h00, 16'd0);
            repeat (8) @(negedge clk);
            check(rd_req === 1'b0, "length 0 read must not issue a RAM read");
            check_int(rd_ack_pulses, baseline_reads,
                      "length 0 read must not fetch any words");
            check_int(tx_stream_count, stream_rd,
                      "length 0 read must not emit a dump frame");

            // A read that lands while a response serializes queues behind
            // the frame; the dump follows the last response byte.  The
            // stream monitor keeps the interleaved ordering checkable.
            drain_stream();
            load_live_snapshot(16'h5500, 16'h00F0, 16'hC0DE);
            remember_expected();
            trigger_response();
            send_read_frame(8'h00, 8'h30, 16'd2);
            for (int b = 0; b < FRAME_BYTES; b++)
                expect_stream_byte(expected_response_byte(b),
                                   "in-flight response must drain before the queued dump");
            expect_stream_dump(8'h00, 8'h30, 2, "queued dump after response");

            // Grant stall: with the RAM port withheld mid-dump the
            // serializer holds — no byte emits, no word is skipped — and the
            // stream resumes unbroken once the grant returns.
            drain_stream();
            send_read_frame(8'h00, 8'h40, 16'd3);
            expect_stream_byte(READ_SYNC_BYTE, "stalled dump: header sync");
            expect_stream_byte(8'h00, "stalled dump: header target");
            expect_stream_byte(8'h40, "stalled dump: header addr");
            expect_stream_byte(8'h00, "stalled dump: header len_hi");
            expect_stream_byte(8'h03, "stalled dump: header len_lo");
            expect_stream_byte(rd_mem[8'h40][15:8], "stalled dump: word 0 hi");
            expect_stream_byte(rd_mem[8'h40][7:0], "stalled dump: word 0 lo");
            rd_grant_en = 1'b0;
            stall_count = tx_stream_count;
            repeat (12) @(negedge clk);
            check(rd_req === 1'b1, "stalled dump must hold rd_req until granted");
            check(rd_addr === 8'h41, "stalled dump must hold the pending read address");
            check_int(tx_stream_count, stall_count,
                      "stalled dump must not emit bytes while ungranted");
            rd_grant_en = 1'b1;
            expect_stream_byte(rd_mem[8'h41][15:8], "stalled dump: resumes at held word 1 hi");
            expect_stream_byte(rd_mem[8'h41][7:0], "stalled dump: resumes at held word 1 lo");
            expect_stream_byte(rd_mem[8'h42][15:8], "stalled dump: resumes at held word 2 hi");
            expect_stream_byte(rd_mem[8'h42][7:0], "stalled dump: resumes at held word 2 lo");

            // A frame_send trigger mid-dump still produces the response —
            // after the dump completes, as the usual pending snapshot.
            drain_stream();
            load_live_snapshot(16'h6600, 16'h0F0F, 16'hDEAD);
            remember_expected();
            send_read_frame(8'h00, 8'h50, 16'd2);
            expect_stream_byte(READ_SYNC_BYTE, "mid-dump trigger: header sync");
            trigger_response();
            expect_stream_byte(8'h00, "mid-dump trigger: header target");
            expect_stream_byte(8'h50, "mid-dump trigger: header addr");
            expect_stream_byte(8'h00, "mid-dump trigger: header len_hi");
            expect_stream_byte(8'h02, "mid-dump trigger: header len_lo");
            expect_stream_byte(rd_mem[8'h50][15:8],
                               "dump payload must not be disturbed by a mid-dump trigger");
            expect_stream_byte(rd_mem[8'h50][7:0],
                               "dump payload must not be disturbed by a mid-dump trigger");
            expect_stream_byte(rd_mem[8'h51][15:8],
                               "dump payload must not be disturbed by a mid-dump trigger");
            expect_stream_byte(rd_mem[8'h51][7:0],
                               "dump payload must not be disturbed by a mid-dump trigger");
            for (int b = 0; b < FRAME_BYTES; b++)
                expect_stream_byte(expected_response_byte(b),
                                   "mid-dump trigger must stream as a response after the dump");
            @(negedge clk);   // last-byte consume clears tx_active
            check(tx_frame_active === 1'b0 && dut.dump_active === 1'b0,
                  "pipe must be idle after dump-then-response");

            // Starvation guard: a queued dump wins the frame boundary ahead
            // of a pending response snapshot — the bounded host read can
            // never wait forever behind stimulus traffic.  The held
            // snapshot still streams once the dump completes, carrying the
            // second trigger's snapshot (distinct so a replayed first frame
            // cannot pass).
            drain_stream();
            load_live_snapshot(16'h7700, 16'h0FF0, 16'h5EED);
            remember_expected();
            trigger_response();
            send_read_frame(8'h00, 8'h80, 16'd2);
            load_live_snapshot(16'h8800, 16'hF00F, 16'hB0DE);
            trigger_response();
            for (int b = 0; b < FRAME_BYTES; b++)
                expect_stream_byte(expected_response_byte(b),
                                   "in-flight response drains before dump and pending response");
            expect_stream_dump(8'h00, 8'h80, 2,
                               "queued dump must win the boundary over a pending response");
            remember_expected();
            for (int b = 0; b < FRAME_BYTES; b++)
                expect_stream_byte(expected_response_byte(b),
                                   "pending snapshot must still stream once the dump drains");

            // Yield-when-done the other direction: with a pending response
            // and a queued read both behind an active dump, the snapshot
            // wins the dump boundary and the read still streams after it.
            // Live inputs change after the trigger so the response must
            // prove it replayed the captured snapshot, not the boundary's.
            drain_stream();
            load_live_snapshot(16'h9900, 16'h3C3C, 16'hCAFE);
            remember_expected();
            send_read_frame(8'h00, 8'hA0, 16'd2);
            expect_stream_byte(READ_SYNC_BYTE, "yield: dump header sync");
            trigger_response();
            load_live_snapshot(16'hAB00, 16'hAAAA, 16'hFACE);
            send_read_frame(8'h02, 8'hB0, 16'd1);
            expect_stream_byte(8'h00, "yield: dump header target");
            expect_stream_byte(8'hA0, "yield: dump header addr");
            expect_stream_byte(8'h00, "yield: dump header len_hi");
            expect_stream_byte(8'h02, "yield: dump header len_lo");
            expect_stream_byte(rd_mem[8'hA0][15:8], "yield: dump word 0 hi");
            expect_stream_byte(rd_mem[8'hA0][7:0], "yield: dump word 0 lo");
            expect_stream_byte(rd_mem[8'hA1][15:8], "yield: dump word 1 hi");
            expect_stream_byte(rd_mem[8'hA1][7:0], "yield: dump word 1 lo");
            for (int b = 0; b < FRAME_BYTES; b++)
                expect_stream_byte(expected_response_byte(b),
                                   "pending response must win the dump boundary");
            expect_stream_dump(8'h02, 8'hB0, 1,
                               "queued read must still stream after the yielded response");

            // Read commands arriving mid-dump share a one-entry queue that
            // is latest-wins: two queued requests collapse to the second,
            // so exactly two dumps stream — the active one, then the last.
            drain_stream();
            send_read_frame(8'h00, 8'h60, 16'd6);
            send_read_frame(8'h01, 8'h71, 16'd1);
            send_read_frame(8'h02, 8'h70, 16'd1);
            expect_stream_dump(8'h00, 8'h60, 6,
                               "first dump must complete before the queued second");
            expect_stream_dump(8'h02, 8'h70, 1,
                               "latest-wins queue must keep the last read, not the first");
            repeat (8) @(negedge clk);
            check_int(tx_stream_count, stream_rd,
                      "superseded queued read must never emit a third dump");

            // An abandoned read frame trips the same idle timeout as writes:
            // rx_abort, no dump, and a fresh frame still parses afterwards.
            baseline_reads = rd_ack_pulses;
            baseline_aborts = rx_abort_pulses;
            drain_stream();
            send_rx_byte(READ_SYNC_BYTE);
            send_rx_byte(8'h00);
            send_rx_byte(8'h05);
            repeat (IDLE_TIMEOUT_CYCLES + 4) @(negedge clk);
            check(rd_req === 1'b0, "abandoned read must not issue a RAM read");
            check_int(rd_ack_pulses, baseline_reads,
                      "abandoned read must not fetch words");
            check_int(rx_abort_pulses, baseline_aborts + 1,
                      "read idle timeout must pulse rx_abort");
            check(rx_busy === 1'b0, "read idle timeout must return to RX_WAIT_SYNC");
            check_int(tx_stream_count, stream_rd,
                      "abandoned read must not emit a dump frame");
            send_read_frame(8'h00, 8'h80, 16'd1);
            expect_stream_dump(8'h00, 8'h80, 1, "fresh read after abandon");

            // Mid-payload READ_SYNC_BYTE inside a stimulus frame is data,
            // not a resync — the same rule WRITE_SYNC_BYTE already follows.
            baseline_reads = rd_ack_pulses;
            send_rx_byte(8'hAA);
            send_rx_byte(READ_SYNC_BYTE);
            send_rx_byte(8'h6A);
            for (int lane = 1; lane < NUM_NEURONS; lane++) begin
                send_rx_byte(8'(8'h70 + lane));
                send_rx_byte(8'(8'h80 + lane));
            end
            @(negedge clk);
            check(stimuli_valid === 1'b1,
                  "stimulus with mid-payload READ_SYNC_BYTE must still commit");
            check_word(stimuli_out[15:0], {READ_SYNC_BYTE, 8'h6A},
                       "lane 0 must keep READ_SYNC_BYTE as Q8.8 data, not a read opcode");
            check_int(rd_ack_pulses, baseline_reads,
                      "mid-payload READ_SYNC_BYTE must not create a RAM read");
            rd_grant_en = 1'b0;
        end

        if (errors == 0) begin
            $display("TB_SOCPROTOCOLFSM: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TB_SOCPROTOCOLFSM: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_SOCPROTOCOLFSM: testbench FAILED");
        end
    end

endmodule

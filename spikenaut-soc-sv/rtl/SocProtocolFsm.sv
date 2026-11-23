// SPDX-License-Identifier: MIT OR Apache-2.0
// SocProtocolFsm.sv
// Canonical source: spikenaut-soc-sv/rtl
//
// Application-layer codec for the SiliconBridge byte transport.  The bridge
// remains a UART-only module: this FSM owns the 0xAA host stimulus frame,
// the 0xA5 RAM-write frame (#63), the 0xA6 RAM-read frame (#113), response
// serialization, and back-pressure handling at the SoC boundary.
//
// Write frame (5 bytes, distinct sync so it cannot be mistaken for a 33-byte
// 0xAA stimulus and does not need a parallel HostWriteFsm on the same byte
// pipe):
//   [0]    = 0xA5                 write sync
//   [1]    = target               0=WeightRam, 1=threshold, 2=leak,
//                                  3=AER route table
//   [2]    = addr                 8-bit RAM address
//   [3:4]  = Q8.8 data            big-endian, same packing as stimulus words
// A complete write pulses wr_en for one fabric cycle.  Invalid targets and
// idle-timeout abandons leave wr_en low.  Writes do not arm a UART response.
//
// Read frame (5 bytes, #113 — dump learned weights / params back to the host):
//   [0]    = 0xA6                 read sync
//   [1]    = target               0=WeightRam, 1=threshold, 2=leak
//   [2]    = addr                 first 8-bit RAM address
//   [3:4]  = length               big-endian 16-bit word count (>= 1)
// A complete, valid read streams one dump frame back over tx_data:
//   [0:4]  = the same five bytes  echoed header (0xA6, target, addr, len)
//   [5:]   = length x Q8.8        big-endian words, addr ascending
// Each word is fetched through rd_req/rd_addr/rd_target -> rd_ack -> rd_dout;
// the SoC grants the RAM port for exactly the cycle rd_ack is high.  Dumps
// share the serializer with stimulus responses: an in-flight 36-byte response
// drains to its last byte, a queued dump (latest-wins) then wins the frame
// boundary ahead of any pending response — the pending snapshot still
// streams once the dump completes, so reads can never starve — and a
// trigger arriving mid-dump still coalesces into that snapshot.  Targets
// >= 3 and length 0 are consumed but emit no dump, matching the write
// path's silent-drop rule for invalid targets.
//
// A response transfer has one active frame and one pending snapshot.  At the
// Basys 3 default 115200 baud a 36-byte response takes about 3.125 ms, longer
// than the 1 ms logical tick, so triggers received while a frame is active are
// deliberately coalesced into the latest single pending snapshot.
//
// RX_COLLECT, RX_WRITE_COLLECT, and RX_READ_COLLECT recover from an abandoned
// host frame with an inter-byte idle timeout only.  Mid-payload 0xAA / 0xA5 /
// 0xA6 is legal Q8.8 data and is never a resync.  Hosts that retry a
// truncated request must idle at least IDLE_TIMEOUT_CYCLES fabric clocks
// before the next sync.
//
// Status outputs feed SocStatusLeds (docs/led-map.md): rx_busy is high
// outside RX_WAIT_SYNC, rx_abort pulses on idle-timeout, and
// tx_frame_active mirrors the internal tx_active frame (not the tx_busy
// input).

module SocProtocolFsm #(
    parameter int NUM_NEURONS = 16,
    parameter int WORD_WIDTH  = 16,
    parameter logic [7:0] SYNC_BYTE = 8'hAA,
    // Distinct from SYNC_BYTE: a shared 0xAA would make a 5-byte write look
    // like a truncated stimulus (or steal the first bytes of a real one).
    parameter logic [7:0] WRITE_SYNC_BYTE = 8'hA5,
    // Distinct from both syncs above for the same single-byte-pipe reason
    // (#113 read dump).
    parameter logic [7:0] READ_SYNC_BYTE = 8'hA6,
    // Four 10-bit UART character times at 100 MHz / 115200 (CLKS_PER_BIT=868).
    parameter int IDLE_TIMEOUT_CYCLES = 4 * 10 * (100_000_000 / 115_200)
)(
    input  logic                                 clk,
    input  logic                                 rst_n,

    // SiliconBridge byte-transport side.
    input  logic [7:0]                           rx_data,
    input  logic                                 rx_valid,
    output logic [7:0]                           tx_data,
    output logic                                 tx_send,
    input  logic                                 tx_busy,

    // SoC/core side. Lane 0 occupies the least-significant WORD_WIDTH bits
    // of each packed vector.
    output logic [NUM_NEURONS*WORD_WIDTH-1:0]    stimuli_out,
    output logic                                 stimuli_valid,
    input  logic [NUM_NEURONS*WORD_WIDTH-1:0]    potentials_in,
    input  logic [NUM_NEURONS-1:0]               spike_flags,
    input  logic [WORD_WIDTH-1:0]                aux_state,
    input  logic                                 frame_send,

    // Host RAM write path (#63).  wr_en is a one-cycle strobe after a
    // complete 0xA5 frame with target 0/1/2/3. The SoC muxes these onto the
    // RAM and AER configuration ports and restores the read paths afterward.
    output logic                                 wr_en,
    output logic [1:0]                           wr_target,
    output logic [7:0]                           wr_addr,
    output logic [WORD_WIDTH-1:0]                wr_data,

    // Host RAM read path (#113).  rd_req asks the SoC to drive rd_addr onto
    // the bank selected by rd_target (same numbering as wr_target; targets
    // >= 3 are never requested).  rd_ack marks the single fabric cycle the
    // address is actually driven, and rd_dout carries that word on the
    // following cycle (registered RAM read latency).  A blocked rd_ack only
    // stalls the dump — UART serialization is orders of magnitude slower
    // than one PE sweep, so no word is ever dropped.
    output logic                                 rd_req,
    output logic [1:0]                           rd_target,
    output logic [7:0]                           rd_addr,
    input  logic                                 rd_ack,
    input  logic [WORD_WIDTH-1:0]                rd_dout,

    // Status outputs for SocStatusLeds (docs/led-map.md).  tx_frame_active
    // mirrors tx_active; do not name this port tx_busy (that is an input).
    output logic                                 rx_busy,
    output logic                                 rx_abort,
    output logic                                 tx_frame_active
);

    localparam int BYTES_PER_WORD = WORD_WIDTH / 8;
    localparam int PAYLOAD_BYTES  = NUM_NEURONS * BYTES_PER_WORD;
    localparam int WRITE_PAYLOAD_BYTES = 4;
    localparam int READ_PAYLOAD_BYTES  = 4;
    localparam int MAX_RX_PAYLOAD_BYTES =
        (PAYLOAD_BYTES > WRITE_PAYLOAD_BYTES) ? PAYLOAD_BYTES : WRITE_PAYLOAD_BYTES;
    localparam logic [7:0] WR_TARGET_MAX = 8'd3;
    // Readable targets are a subset of the write targets: the AER route
    // table has no config read port, so 0..2 only.
    localparam logic [7:0] RD_TARGET_MAX = 8'd2;
    // Dump frame header: echoed 0xA6, target, addr, len_hi, len_lo.
    localparam int RD_HDR_BYTES = 5;
    localparam int FRAME_BYTES    = PAYLOAD_BYTES + (2 * BYTES_PER_WORD);
    localparam int RX_COUNT_WIDTH = (MAX_RX_PAYLOAD_BYTES > 1)
        ? $clog2(MAX_RX_PAYLOAD_BYTES) : 1;
    localparam int TX_COUNT_WIDTH = (FRAME_BYTES > 1) ? $clog2(FRAME_BYTES) : 1;
    localparam int IDLE_COUNT_WIDTH = (IDLE_TIMEOUT_CYCLES > 1)
        ? $clog2(IDLE_TIMEOUT_CYCLES + 1) : 1;

    typedef enum logic [2:0] {
        RX_WAIT_SYNC,
        RX_COLLECT,
        RX_COMMIT,
        RX_WRITE_COLLECT,
        RX_READ_COLLECT
    } rx_state_t;
    rx_state_t rx_state;

    // Read-dump serializer phases (#113).  Only the *_SEND_* / DUMP_HEADER
    // phases drive tx_send; DUMP_REQ / DUMP_WAIT own the rd_* handshake.
    typedef enum logic [2:0] {
        DUMP_HEADER,
        DUMP_REQ,
        DUMP_WAIT,
        DUMP_SEND_HI,
        DUMP_SEND_LO
    } dump_phase_t;
    dump_phase_t dump_phase;

    logic [RX_COUNT_WIDTH-1:0] rx_byte_count;
    logic [IDLE_COUNT_WIDTH-1:0] rx_idle_count;
    logic [NUM_NEURONS*WORD_WIDTH-1:0] rx_payload;
    logic [7:0] wr_target_byte;
    logic [7:0] wr_addr_byte;
    logic [7:0] wr_data_hi;
    logic [7:0] rd_cmd_target_byte;
    logic [7:0] rd_cmd_addr_byte;
    logic [7:0] rd_cmd_len_hi;

    // One-cycle read-command strobe from the RX FSM to the TX serializer,
    // with the decoded operands held for whichever cycle consumes it.
    logic        rd_cmd_valid;
    logic [1:0]  rd_cmd_target;
    logic [7:0]  rd_cmd_addr;
    logic [15:0] rd_cmd_len;

    // The active response frame is held in word form so byte serialization is
    // unambiguous and all source values are sampled atomically at frame start.
    logic [WORD_WIDTH-1:0] active_potentials [0:NUM_NEURONS-1];
    logic [WORD_WIDTH-1:0] pending_potentials [0:NUM_NEURONS-1];
    logic [WORD_WIDTH-1:0] active_spike_flags;
    logic [WORD_WIDTH-1:0] active_aux_state;
    logic [WORD_WIDTH-1:0] pending_spike_flags;
    logic [WORD_WIDTH-1:0] pending_aux_state;
    logic [TX_COUNT_WIDTH-1:0] tx_byte_index;
    logic tx_active;
    logic tx_pending;
    // UartTx observes tx_send one clock later than this FSM drives it.  This
    // guard prevents a second apparent !tx_busy cycle from advancing the
    // serializer before the bridge has accepted the first byte.
    logic send_pending;

    // 0xA6 dump machinery.  dump_active owns the byte pipe; dump_pending is
    // a one-entry latest-wins queue for a read command that arrives while a
    // response or another dump is in flight.
    logic dump_active;
    logic dump_pending;
    logic [1:0]  dump_target;
    logic [7:0]  dump_addr;
    logic [15:0] dump_len;
    logic [2:0]  dump_hdr_index;
    logic [WORD_WIDTH-1:0] dump_word;
    logic [1:0]  pd_target;
    logic [7:0]  pd_addr;
    logic [15:0] pd_len;

    generate
        if (NUM_NEURONS < 1)
            $error("SocProtocolFsm: NUM_NEURONS (%0d) must be at least one", NUM_NEURONS);
        if ((WORD_WIDTH < 8) || ((WORD_WIDTH % 8) != 0))
            $error("SocProtocolFsm: WORD_WIDTH (%0d) must be a positive multiple of 8", WORD_WIDTH);
        if (NUM_NEURONS > WORD_WIDTH)
            $error("SocProtocolFsm: NUM_NEURONS (%0d) must not exceed WORD_WIDTH (%0d)", NUM_NEURONS, WORD_WIDTH);
        if (IDLE_TIMEOUT_CYCLES < 1)
            $error("SocProtocolFsm: IDLE_TIMEOUT_CYCLES (%0d) must be at least one", IDLE_TIMEOUT_CYCLES);
        if (WRITE_SYNC_BYTE == SYNC_BYTE)
            $error("SocProtocolFsm: WRITE_SYNC_BYTE must differ from SYNC_BYTE");
        if ((READ_SYNC_BYTE == SYNC_BYTE) || (READ_SYNC_BYTE == WRITE_SYNC_BYTE))
            $error("SocProtocolFsm: READ_SYNC_BYTE must differ from SYNC_BYTE and WRITE_SYNC_BYTE");
        if (WORD_WIDTH != 16)
            $error("SocProtocolFsm: WORD_WIDTH (%0d) must be 16; the 0xA5 write frame is two Q8.8 bytes", WORD_WIDTH);
    endgenerate

    // Receive 0xAA followed by NUM_NEURONS big-endian words.  RX_COLLECT
    // advances only on rx_valid; short idle gaps between UART bytes are
    // harmless.  An idle stretch of IDLE_TIMEOUT_CYCLES clocks aborts back
    // to RX_WAIT_SYNC and clears the partial byte count so a retried 0xAA
    // can start a fresh frame.  RX_COMMIT keeps partially assembled payloads
    // invisible to the core and produces a precisely one-cycle stimuli_valid
    // strobe.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_state       <= RX_WAIT_SYNC;
            rx_byte_count  <= '0;
            rx_idle_count  <= '0;
            rx_payload     <= '0;
            stimuli_out    <= '0;
            stimuli_valid  <= 1'b0;
            wr_en          <= 1'b0;
            wr_target      <= '0;
            wr_addr        <= '0;
            wr_data        <= '0;
            wr_target_byte <= '0;
            wr_addr_byte   <= '0;
            wr_data_hi     <= '0;
            rd_cmd_target_byte <= '0;
            rd_cmd_addr_byte   <= '0;
            rd_cmd_len_hi      <= '0;
            rd_cmd_valid   <= 1'b0;
            rd_cmd_target  <= '0;
            rd_cmd_addr    <= '0;
            rd_cmd_len     <= '0;
            rx_abort       <= 1'b0;
        end else begin
            stimuli_valid <= 1'b0;
            wr_en         <= 1'b0;
            rd_cmd_valid  <= 1'b0;
            rx_abort      <= 1'b0;

            case (rx_state)
                RX_WAIT_SYNC: begin
                    if (rx_valid && (rx_data == SYNC_BYTE)) begin
                        rx_byte_count <= '0;
                        rx_idle_count <= '0;
                        rx_state      <= RX_COLLECT;
                    end else if (rx_valid && (rx_data == WRITE_SYNC_BYTE)) begin
                        rx_byte_count <= '0;
                        rx_idle_count <= '0;
                        rx_state      <= RX_WRITE_COLLECT;
                    end else if (rx_valid && (rx_data == READ_SYNC_BYTE)) begin
                        rx_byte_count <= '0;
                        rx_idle_count <= '0;
                        rx_state      <= RX_READ_COLLECT;
                    end
                end

                RX_COLLECT: begin
                    if (rx_valid) begin
                        // The host transmits each word high byte first.  The
                        // packed vector uses lane 0 at the LSB, hence this
                        // indexed part-select maps byte 0 to lane 0's MSB.
                        rx_payload[(rx_byte_count / BYTES_PER_WORD) * WORD_WIDTH +
                                   ((BYTES_PER_WORD - 1 - (rx_byte_count % BYTES_PER_WORD)) * 8) +: 8]
                            <= rx_data;
                        rx_idle_count <= '0;
                        if (rx_byte_count == PAYLOAD_BYTES - 1) begin
                            rx_state <= RX_COMMIT;
                        end else begin
                            rx_byte_count <= rx_byte_count + 1'b1;
                        end
                    end else if (rx_idle_count == IDLE_COUNT_WIDTH'(IDLE_TIMEOUT_CYCLES - 1)) begin
                        rx_byte_count <= '0;
                        rx_idle_count <= '0;
                        rx_state      <= RX_WAIT_SYNC;
                        rx_abort      <= 1'b1;
                    end else begin
                        rx_idle_count <= rx_idle_count + 1'b1;
                    end
                end

                RX_COMMIT: begin
                    stimuli_out   <= rx_payload;
                    stimuli_valid <= 1'b1;
                    rx_state      <= RX_WAIT_SYNC;
                end

                // Collect target, addr, data_hi, data_lo.  Mid-payload 0xAA
                // or 0xA5 is legal data, never a resync.  The last byte both
                // assembles wr_* and pulses wr_en when the target is 0/1/2/3.
                RX_WRITE_COLLECT: begin
                    if (rx_valid) begin
                        rx_idle_count <= '0;
                        if (rx_byte_count == '0)
                            wr_target_byte <= rx_data;
                        else if (rx_byte_count == 1)
                            wr_addr_byte <= rx_data;
                        else if (rx_byte_count == 2)
                            wr_data_hi <= rx_data;

                        if (rx_byte_count == WRITE_PAYLOAD_BYTES - 1) begin
                            wr_addr   <= wr_addr_byte;
                            wr_target <= wr_target_byte[1:0];
                            wr_data   <= WORD_WIDTH'({wr_data_hi, rx_data});
                            if (wr_target_byte <= WR_TARGET_MAX)
                                wr_en <= 1'b1;
                            rx_byte_count <= '0;
                            rx_state      <= RX_WAIT_SYNC;
                        end else begin
                            rx_byte_count <= rx_byte_count + 1'b1;
                        end
                    end else if (rx_idle_count == IDLE_COUNT_WIDTH'(IDLE_TIMEOUT_CYCLES - 1)) begin
                        rx_byte_count <= '0;
                        rx_idle_count <= '0;
                        rx_state      <= RX_WAIT_SYNC;
                        rx_abort      <= 1'b1;
                    end else begin
                        rx_idle_count <= rx_idle_count + 1'b1;
                    end
                end

                // Collect target, start addr, len_hi, len_lo.  Mid-payload
                // sync-valued bytes are data, never a resync.  The last byte
                // arms the TX dump only when the target is readable and the
                // length is nonzero; a rejected request is silently consumed
                // like an invalid write target.
                RX_READ_COLLECT: begin
                    if (rx_valid) begin
                        rx_idle_count <= '0;
                        if (rx_byte_count == '0)
                            rd_cmd_target_byte <= rx_data;
                        else if (rx_byte_count == 1)
                            rd_cmd_addr_byte <= rx_data;
                        else if (rx_byte_count == 2)
                            rd_cmd_len_hi <= rx_data;

                        if (rx_byte_count == READ_PAYLOAD_BYTES - 1) begin
                            if ((rd_cmd_target_byte <= RD_TARGET_MAX) &&
                                ({rd_cmd_len_hi, rx_data} != '0)) begin
                                rd_cmd_valid  <= 1'b1;
                                rd_cmd_target <= rd_cmd_target_byte[1:0];
                                rd_cmd_addr   <= rd_cmd_addr_byte;
                                rd_cmd_len    <= {rd_cmd_len_hi, rx_data};
                            end
                            rx_byte_count <= '0;
                            rx_state      <= RX_WAIT_SYNC;
                        end else begin
                            rx_byte_count <= rx_byte_count + 1'b1;
                        end
                    end else if (rx_idle_count == IDLE_COUNT_WIDTH'(IDLE_TIMEOUT_CYCLES - 1)) begin
                        rx_byte_count <= '0;
                        rx_idle_count <= '0;
                        rx_state      <= RX_WAIT_SYNC;
                        rx_abort      <= 1'b1;
                    end else begin
                        rx_idle_count <= rx_idle_count + 1'b1;
                    end
                end

                default: rx_state <= RX_WAIT_SYNC;
            endcase
        end
    end

    assign rx_busy = (rx_state != RX_WAIT_SYNC);
    // tx_frame_active covers either frame kind holding the byte pipe: a
    // 36-byte response (tx_active) or a 0xA6 RAM dump (dump_active).
    assign tx_frame_active = tx_active || dump_active;

    // The dump engine presents its read request combinationally while it
    // waits for the SoC to grant the RAM port.  rd_ack marks the single
    // fabric cycle the address is driven; DUMP_WAIT captures rd_dout on the
    // following cycle.
    assign rd_req    = dump_active && (dump_phase == DUMP_REQ);
    assign rd_target = dump_target;
    assign rd_addr   = dump_addr;

    // Present the next held byte combinationally.  tx_byte_index changes only
    // after send_pending confirms a prior tx_send was accepted, so tx_data is
    // stable throughout a back-pressure stall and cannot skip or duplicate a
    // byte.  The dump serializer follows the same rule: dump_phase only
    // advances on a consume, so a header or payload byte is held for the
    // whole stall.  dump_addr / dump_len still carry the request's start
    // values while DUMP_HEADER runs — they first mutate on the last payload
    // byte of word zero.
    always_comb begin
        tx_data = '0;
        if (dump_active) begin
            case (dump_phase)
                DUMP_HEADER: begin
                    case (dump_hdr_index)
                        3'd0:    tx_data = READ_SYNC_BYTE;
                        3'd1:    tx_data = {6'b0, dump_target};
                        3'd2:    tx_data = dump_addr;
                        3'd3:    tx_data = dump_len[15:8];
                        default: tx_data = dump_len[7:0];
                    endcase
                end
                DUMP_SEND_HI: tx_data = dump_word[WORD_WIDTH-1 -: 8];
                DUMP_SEND_LO: tx_data = dump_word[7:0];
                default:      tx_data = '0;
            endcase
        end else if (tx_active) begin
            if (tx_byte_index < PAYLOAD_BYTES) begin
                tx_data = active_potentials[tx_byte_index / BYTES_PER_WORD]
                    [(BYTES_PER_WORD - 1 - (tx_byte_index % BYTES_PER_WORD)) * 8 +: 8];
            end else if (tx_byte_index < PAYLOAD_BYTES + BYTES_PER_WORD) begin
                tx_data = active_spike_flags
                    [(BYTES_PER_WORD - 1 - ((tx_byte_index - PAYLOAD_BYTES) % BYTES_PER_WORD)) * 8 +: 8];
            end else begin
                tx_data = active_aux_state
                    [(BYTES_PER_WORD - 1 - ((tx_byte_index - PAYLOAD_BYTES - BYTES_PER_WORD) % BYTES_PER_WORD)) * 8 +: 8];
            end
        end
    end

    // Serialize a frame through the bridge.  Only one frame kind occupies the
    // byte pipe at a time: active_* / pending_* are the response buffers as
    // before (one active frame, one latest-wins pending snapshot), and a 0xA6
    // dump is a second, self-paced frame type behind the same
    // send_pending/tx_busy handshake.  An in-flight response drains before a
    // queued dump starts; a queued dump runs before the pipe goes idle.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tx_send            <= 1'b0;
            tx_byte_index      <= '0;
            tx_active          <= 1'b0;
            tx_pending         <= 1'b0;
            send_pending       <= 1'b0;
            active_spike_flags <= '0;
            active_aux_state   <= '0;
            pending_spike_flags <= '0;
            pending_aux_state   <= '0;
            dump_active        <= 1'b0;
            dump_pending       <= 1'b0;
            dump_target        <= '0;
            dump_addr          <= '0;
            dump_len           <= '0;
            dump_hdr_index     <= '0;
            dump_word          <= '0;
            dump_phase         <= DUMP_HEADER;
            pd_target          <= '0;
            pd_addr            <= '0;
            pd_len             <= '0;
            for (int lane = 0; lane < NUM_NEURONS; lane++) begin
                active_potentials[lane]  <= '0;
                pending_potentials[lane] <= '0;
            end
        end else begin
            tx_send <= 1'b0;

            if (dump_active) begin
                // Word-fetch handshake.  rd_req (combinational, above) holds
                // until the SoC grants the RAM port for one fabric cycle;
                // rd_dout is the registered read of that address one cycle
                // later.  The port is only borrowed — not held — so PE
                // sweeps and STDP writeback keep the RAM between requests.
                if ((dump_phase == DUMP_REQ) && rd_ack) begin
                    dump_phase <= DUMP_WAIT;
                end else if (dump_phase == DUMP_WAIT) begin
                    dump_word  <= rd_dout;
                    dump_phase <= DUMP_SEND_HI;
                end

                // A trigger mid-dump takes the same latest-wins pending
                // snapshot it would mid-response.  The last consume cycle is
                // excluded because DUMP_SEND_LO below captures that trigger
                // straight into the active or pending slot.
                if (frame_send &&
                    !(send_pending && (dump_phase == DUMP_SEND_LO) &&
                      (dump_len == 16'd1))) begin
                    for (int lane = 0; lane < NUM_NEURONS; lane++)
                        pending_potentials[lane] <=
                            potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                    pending_spike_flags <= WORD_WIDTH'(spike_flags);
                    pending_aux_state   <= aux_state;
                    tx_pending          <= 1'b1;
                end

                if (send_pending) begin
                    // Same consume semantics as the response path: the byte
                    // presented on the preceding cycle was accepted now.
                    send_pending <= 1'b0;

                    case (dump_phase)
                        DUMP_HEADER: begin
                            if (dump_hdr_index == RD_HDR_BYTES - 1)
                                dump_phase <= DUMP_REQ;
                            else
                                dump_hdr_index <= dump_hdr_index + 1'b1;
                        end
                        DUMP_SEND_HI: dump_phase <= DUMP_SEND_LO;
                        DUMP_SEND_LO: begin
                            if (dump_len == 16'd1) begin
                                // End of dump.  A queued dump wins the pipe
                                // (bounded and host-requested; a pending
                                // snapshot still streams afterward), then a
                                // pending snapshot, then a coincident
                                // trigger, then idle.
                                if (dump_pending) begin
                                    dump_target    <= pd_target;
                                    dump_addr      <= pd_addr;
                                    dump_len       <= pd_len;
                                    dump_hdr_index <= '0;
                                    dump_phase     <= DUMP_HEADER;
                                    dump_pending   <= 1'b0;
                                    if (frame_send) begin
                                        for (int lane = 0; lane < NUM_NEURONS; lane++)
                                            pending_potentials[lane] <=
                                                potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                                        pending_spike_flags <= WORD_WIDTH'(spike_flags);
                                        pending_aux_state   <= aux_state;
                                        tx_pending          <= 1'b1;
                                    end
                                end else if (tx_pending) begin
                                    for (int lane = 0; lane < NUM_NEURONS; lane++)
                                        active_potentials[lane] <= pending_potentials[lane];
                                    active_spike_flags <= pending_spike_flags;
                                    active_aux_state   <= pending_aux_state;
                                    tx_byte_index      <= '0;
                                    tx_active          <= 1'b1;
                                    dump_active        <= 1'b0;
                                    if (frame_send) begin
                                        for (int lane = 0; lane < NUM_NEURONS; lane++)
                                            pending_potentials[lane] <=
                                                potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                                        pending_spike_flags <= WORD_WIDTH'(spike_flags);
                                        pending_aux_state   <= aux_state;
                                    end else begin
                                        tx_pending <= 1'b0;
                                    end
                                end else if (frame_send) begin
                                    for (int lane = 0; lane < NUM_NEURONS; lane++)
                                        active_potentials[lane] <=
                                            potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                                    active_spike_flags <= WORD_WIDTH'(spike_flags);
                                    active_aux_state   <= aux_state;
                                    tx_byte_index      <= '0;
                                    tx_active          <= 1'b1;
                                    dump_active        <= 1'b0;
                                end else begin
                                    dump_active <= 1'b0;
                                end
                            end else begin
                                dump_len   <= dump_len - 1'b1;
                                dump_addr  <= dump_addr + 1'b1;
                                dump_phase <= DUMP_REQ;
                            end
                        end
                        default: ;
                    endcase
                end else if ((dump_phase == DUMP_HEADER) ||
                             (dump_phase == DUMP_SEND_HI) ||
                             (dump_phase == DUMP_SEND_LO)) begin
                    // Launch only into an idle bridge, exactly like the
                    // response serializer.  DUMP_REQ / DUMP_WAIT drive no
                    // byte, so a stalled rd_ack can never emit one.
                    if (!tx_busy) begin
                        tx_send      <= 1'b1;
                        send_pending <= 1'b1;
                    end
                end

                // A read command landing mid-dump queues behind the current
                // one (latest-wins against an earlier queued request).  Kept
                // after the frame-end logic so a command arriving on the
                // final consume cycle queues rather than reloading the
                // just-promoted pending operand.
                if (rd_cmd_valid) begin
                    dump_pending <= 1'b1;
                    pd_target    <= rd_cmd_target;
                    pd_addr      <= rd_cmd_addr;
                    pd_len       <= rd_cmd_len;
                end
            end else if (tx_active) begin
                if (send_pending) begin
                    // A tx_send was asserted during the preceding cycle while
                    // tx_busy was low, so UartTx consumes this exact byte now.
                    // A one-cycle frame_send can land on this consume cycle;
                    // capture it as the latest-wins pending snapshot.
                    send_pending <= 1'b0;

                    if (tx_byte_index == FRAME_BYTES - 1) begin
                        if (dump_pending) begin
                            // A queued read command wins the frame boundary:
                            // it is bounded and host-requested, while a held
                            // pending response is only a snapshot that still
                            // streams once the dump drains — promoting
                            // tx_pending first would starve the dump under
                            // continuous stimulus traffic.
                            dump_target    <= pd_target;
                            dump_addr      <= pd_addr;
                            dump_len       <= pd_len;
                            dump_hdr_index <= '0;
                            dump_phase     <= DUMP_HEADER;
                            dump_active    <= 1'b1;
                            dump_pending   <= 1'b0;
                            tx_active      <= 1'b0;
                            // A coincident trigger refreshes the pending
                            // snapshot rather than queuing behind it.
                            if (frame_send) begin
                                for (int lane = 0; lane < NUM_NEURONS; lane++)
                                    pending_potentials[lane] <=
                                        potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                                pending_spike_flags <= WORD_WIDTH'(spike_flags);
                                pending_aux_state   <= aux_state;
                                tx_pending          <= 1'b1;
                            end
                        end else if (tx_pending) begin
                            for (int lane = 0; lane < NUM_NEURONS; lane++)
                                active_potentials[lane] <= pending_potentials[lane];
                            active_spike_flags <= pending_spike_flags;
                            active_aux_state   <= pending_aux_state;
                            tx_byte_index      <= '0;
                            // If a trigger lands at this boundary, preserve it
                            // as the new one-entry pending snapshot while the
                            // prior pending frame becomes active.
                            if (frame_send) begin
                                for (int lane = 0; lane < NUM_NEURONS; lane++)
                                    pending_potentials[lane] <=
                                        potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                                pending_spike_flags <= WORD_WIDTH'(spike_flags);
                                pending_aux_state   <= aux_state;
                                tx_pending          <= 1'b1;
                            end else begin
                                tx_pending <= 1'b0;
                            end
                        end else if (frame_send) begin
                            for (int lane = 0; lane < NUM_NEURONS; lane++)
                                active_potentials[lane] <=
                                    potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                            active_spike_flags <= WORD_WIDTH'(spike_flags);
                            active_aux_state   <= aux_state;
                            tx_byte_index      <= '0;
                        end else begin
                            tx_active <= 1'b0;
                        end
                    end else begin
                        tx_byte_index <= tx_byte_index + 1'b1;
                        if (frame_send) begin
                            for (int lane = 0; lane < NUM_NEURONS; lane++)
                                pending_potentials[lane] <=
                                    potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                            pending_spike_flags <= WORD_WIDTH'(spike_flags);
                            pending_aux_state   <= aux_state;
                            tx_pending          <= 1'b1;
                        end
                    end
                end else begin
                    // Launch only into an idle bridge.  send_pending absorbs
                    // UartTx's registered-busy latency on the next cycle.
                    if (!tx_busy) begin
                        tx_send      <= 1'b1;
                        send_pending <= 1'b1;
                    end
                    if (frame_send) begin
                        for (int lane = 0; lane < NUM_NEURONS; lane++)
                            pending_potentials[lane] <=
                                potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                        pending_spike_flags <= WORD_WIDTH'(spike_flags);
                        pending_aux_state   <= aux_state;
                        tx_pending          <= 1'b1;
                    end
                end

                // A read command landing mid-response queues for the gap
                // after this frame.  Kept after the frame-end promotion so a
                // command arriving on the last consume cycle queues behind
                // any already-pending dump instead of clobbering it.
                if (rd_cmd_valid) begin
                    dump_pending <= 1'b1;
                    pd_target    <= rd_cmd_target;
                    pd_addr      <= rd_cmd_addr;
                    pd_len       <= rd_cmd_len;
                end
            end else begin
                if (frame_send) begin
                    for (int lane = 0; lane < NUM_NEURONS; lane++)
                        active_potentials[lane] <= potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                    active_spike_flags <= WORD_WIDTH'(spike_flags);
                    active_aux_state   <= aux_state;
                    tx_byte_index      <= '0;
                    tx_active          <= 1'b1;
                    tx_pending         <= 1'b0;
                    // A stimulus won the pipe by arriving on the same cycle;
                    // queue the read behind it instead of dropping it.
                    if (rd_cmd_valid) begin
                        dump_pending <= 1'b1;
                        pd_target    <= rd_cmd_target;
                        pd_addr      <= rd_cmd_addr;
                        pd_len       <= rd_cmd_len;
                    end
                end else if (rd_cmd_valid || dump_pending) begin
                    if (rd_cmd_valid) begin
                        dump_target <= rd_cmd_target;
                        dump_addr   <= rd_cmd_addr;
                        dump_len    <= rd_cmd_len;
                    end else begin
                        dump_target <= pd_target;
                        dump_addr   <= pd_addr;
                        dump_len    <= pd_len;
                    end
                    dump_hdr_index <= '0;
                    dump_phase     <= DUMP_HEADER;
                    dump_active    <= 1'b1;
                    dump_pending   <= 1'b0;
                end
            end
        end
    end

endmodule

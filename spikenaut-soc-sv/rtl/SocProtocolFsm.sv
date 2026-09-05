// SPDX-License-Identifier: MIT OR Apache-2.0
// SocProtocolFsm.sv
// Canonical source: spikenaut-soc-sv/rtl
//
// Application-layer codec for the SiliconBridge byte transport.  The bridge
// remains a UART-only module: this FSM owns the 0xAA host frame, response
// serialization, and back-pressure handling at the SoC boundary.
//
// A response transfer has one active frame and one pending snapshot.  At the
// Basys 3 default 115200 baud a 36-byte response takes about 3.125 ms, longer
// than the 1 ms logical tick, so triggers received while a frame is active are
// deliberately coalesced into the latest single pending snapshot.
//
// RX_COLLECT recovers from an abandoned host frame with an inter-byte idle
// timeout only.  Mid-payload 0xAA is legal Q8.8 data and is never a resync.
// Hosts that retry a truncated request must idle at least
// IDLE_TIMEOUT_CYCLES fabric clocks before the next 0xAA.

module SocProtocolFsm #(
    parameter int NUM_NEURONS = 16,
    parameter int WORD_WIDTH  = 16,
    parameter logic [7:0] SYNC_BYTE = 8'hAA,
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
    input  logic                                 frame_send
);

    localparam int BYTES_PER_WORD = WORD_WIDTH / 8;
    localparam int PAYLOAD_BYTES  = NUM_NEURONS * BYTES_PER_WORD;
    localparam int FRAME_BYTES    = PAYLOAD_BYTES + (2 * BYTES_PER_WORD);
    localparam int RX_COUNT_WIDTH = (PAYLOAD_BYTES > 1) ? $clog2(PAYLOAD_BYTES) : 1;
    localparam int TX_COUNT_WIDTH = (FRAME_BYTES > 1) ? $clog2(FRAME_BYTES) : 1;
    localparam int IDLE_COUNT_WIDTH = (IDLE_TIMEOUT_CYCLES > 1)
        ? $clog2(IDLE_TIMEOUT_CYCLES + 1) : 1;

    typedef enum logic [1:0] {RX_WAIT_SYNC, RX_COLLECT, RX_COMMIT} rx_state_t;
    rx_state_t rx_state;

    logic [RX_COUNT_WIDTH-1:0] rx_byte_count;
    logic [IDLE_COUNT_WIDTH-1:0] rx_idle_count;
    logic [NUM_NEURONS*WORD_WIDTH-1:0] rx_payload;

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

    generate
        if (NUM_NEURONS < 1)
            $error("SocProtocolFsm: NUM_NEURONS (%0d) must be at least one", NUM_NEURONS);
        if ((WORD_WIDTH < 8) || ((WORD_WIDTH % 8) != 0))
            $error("SocProtocolFsm: WORD_WIDTH (%0d) must be a positive multiple of 8", WORD_WIDTH);
        if (NUM_NEURONS > WORD_WIDTH)
            $error("SocProtocolFsm: NUM_NEURONS (%0d) must not exceed WORD_WIDTH (%0d)", NUM_NEURONS, WORD_WIDTH);
        if (IDLE_TIMEOUT_CYCLES < 1)
            $error("SocProtocolFsm: IDLE_TIMEOUT_CYCLES (%0d) must be at least one", IDLE_TIMEOUT_CYCLES);
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
        end else begin
            stimuli_valid <= 1'b0;

            case (rx_state)
                RX_WAIT_SYNC: begin
                    if (rx_valid && (rx_data == SYNC_BYTE)) begin
                        rx_byte_count <= '0;
                        rx_idle_count <= '0;
                        rx_state      <= RX_COLLECT;
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
                    end else begin
                        rx_idle_count <= rx_idle_count + 1'b1;
                    end
                end

                RX_COMMIT: begin
                    stimuli_out   <= rx_payload;
                    stimuli_valid <= 1'b1;
                    rx_state      <= RX_WAIT_SYNC;
                end

                default: rx_state <= RX_WAIT_SYNC;
            endcase
        end
    end

    // Present the next held byte combinationally.  tx_byte_index changes only
    // after send_pending confirms a prior tx_send was accepted, so tx_data is
    // stable throughout a back-pressure stall and cannot skip or duplicate a
    // byte.
    always_comb begin
        tx_data = '0;
        if (tx_active) begin
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

    // Serialize a frame through the bridge.  active_* is the byte hold buffer
    // for the current frame; pending_* is a one-entry, latest-wins response
    // queue for tick triggers that arrive while UART serialization is active.
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
            for (int lane = 0; lane < NUM_NEURONS; lane++) begin
                active_potentials[lane]  <= '0;
                pending_potentials[lane] <= '0;
            end
        end else begin
            tx_send <= 1'b0;

            if (tx_active) begin
                if (send_pending) begin
                    // A tx_send was asserted during the preceding cycle while
                    // tx_busy was low, so UartTx consumes this exact byte now.
                    // A one-cycle frame_send can land on this consume cycle;
                    // capture it as the latest-wins pending snapshot.
                    send_pending <= 1'b0;

                    if (tx_byte_index == FRAME_BYTES - 1) begin
                        if (tx_pending) begin
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
            end else if (frame_send) begin
                for (int lane = 0; lane < NUM_NEURONS; lane++)
                    active_potentials[lane] <= potentials_in[lane*WORD_WIDTH +: WORD_WIDTH];
                active_spike_flags <= WORD_WIDTH'(spike_flags);
                active_aux_state   <= aux_state;
                tx_byte_index      <= '0;
                tx_active          <= 1'b1;
                tx_pending         <= 1'b0;
            end
        end
    end

endmodule

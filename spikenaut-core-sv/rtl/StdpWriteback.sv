// SPDX-License-Identifier: MIT OR Apache-2.0
// StdpWriteback.sv
// Canonical source: spikenaut-core-sv/rtl
// Closed-loop STDP writeback into a single-port WeightRam (GH#70).
//
// Instantiates one StdpController per post-synaptic neuron so the Bi–Poo
// polarity, signed Q8.8 ±1 saturate, and registered weight_we handoff stay
// in the canonical module rather than being copied here. This wrapper owns
// the time-multiplexed RAM port that the original single-address controller
// cannot drive: WeightRam is busy with the LIF PE from step_en through
// tick_done, and spike_bitmap only commits on tick_done.
//
// Per-tick contract:
//   1. step_en latches this tick's pre_spike. input_index is captured only
//      on a pre event so the column walk follows the originating pre
//      channel: a later post (or an idle SoC tick that defaults
//      input_index to 0) must not LTP a different synapse from that
//      pre-trace. Those combos are gone by tick_done — stimuli_pending
//      clears on the tick edge.
//   2. tick_done && learn_en starts a column snapshot: read
//      weight[neuron][column] for every post neuron (registered RAM latency).
//   3. One local stdp_tick pulses every StdpController together, so traces
//      still count logical ticks, not fabric clocks (docs/timestep-contract.md).
//   4. The handoff cycle captures weight_we / weight_out / weight_addr_out
//      and serializes any writes back into WeightRam while the PE is idle.
//
// learn_en is the optional-online-learn gate. It is sampled only in ST_IDLE.
// When low the engine stays idle — no new RAM access, traces frozen — so
// the F1 demo path is unchanged until SW14 (or a TB force) enables it. An
// in-flight walk (tens of fabric cycles) always finishes: ST_UPDATE already
// advances traces, so aborting ST_WRITEBACK would leave WeightRam stale.
//
// Addressing matches LifNeuronArray / docs/lif-array-connectivity-model.md:
//   addr = neuron_row * NUM_NEURONS + input_column.

module StdpWriteback #(
    parameter int DATA_WIDTH   = 16,
    parameter int NUM_NEURONS  = 16,
    parameter int ADDR_WIDTH   = 8,
    parameter int WINDOW_WIDTH = 8,
    parameter int INDEX_WIDTH  = (NUM_NEURONS > 1) ? $clog2(NUM_NEURONS) : 1
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         learn_en,
    input  logic                         step_en,
    input  logic                         tick_done,
    input  logic                         pre_spike,
    input  logic [NUM_NEURONS-1:0]       post_spikes,
    input  logic [INDEX_WIDTH-1:0]       input_index,
    input  logic [DATA_WIDTH-1:0]        weight_dout,
    output logic                         busy,
    output logic                         weight_we,
    output logic [ADDR_WIDTH-1:0]        weight_addr,
    output logic [DATA_WIDTH-1:0]        weight_din
);

    generate
        if (NUM_NEURONS < 1)
            $error("StdpWriteback: NUM_NEURONS (%0d) must be at least 1", NUM_NEURONS);
        if (ADDR_WIDTH < ((NUM_NEURONS > 1) ? $clog2(NUM_NEURONS * NUM_NEURONS) : 1))
            $error("StdpWriteback: ADDR_WIDTH (%0d) is too small for a %0dx%0d matrix",
                   ADDR_WIDTH, NUM_NEURONS, NUM_NEURONS);
    endgenerate

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_READ_REQ,
        ST_READ_CAP,
        ST_UPDATE,
        ST_HANDOFF,
        ST_WRITEBACK
    } state_t;

    state_t state;
    logic [INDEX_WIDTH-1:0] slot;
    logic                   pre_q;
    logic [INDEX_WIDTH-1:0] col_q;
    logic [NUM_NEURONS-1:0] post_q;

    logic [DATA_WIDTH-1:0]  snap         [0:NUM_NEURONS-1];
    logic                   pending_we   [0:NUM_NEURONS-1];
    logic [ADDR_WIDTH-1:0]  pending_addr [0:NUM_NEURONS-1];
    logic [DATA_WIDTH-1:0]  pending_din  [0:NUM_NEURONS-1];

    logic                   stdp_tick;
    logic [NUM_NEURONS-1:0] stdp_we;
    logic [ADDR_WIDTH-1:0]  stdp_addr_out [0:NUM_NEURONS-1];
    logic [DATA_WIDTH-1:0]  stdp_data_out [0:NUM_NEURONS-1];

    function automatic logic [ADDR_WIDTH-1:0] synapse_addr(
        input logic [INDEX_WIDTH-1:0] neuron
    );
        synapse_addr = ADDR_WIDTH'((neuron * NUM_NEURONS) + col_q);
    endfunction

    assign busy      = (state != ST_IDLE);
    assign stdp_tick = (state == ST_UPDATE);

    genvar neuron;
    generate
        for (neuron = 0; neuron < NUM_NEURONS; neuron++) begin : g_stdp
            StdpController #(
                .DATA_WIDTH   (DATA_WIDTH),
                .ADDR_WIDTH   (ADDR_WIDTH),
                .WINDOW_WIDTH (WINDOW_WIDTH)
            ) u_stdp (
                .clk             (clk),
                .rst_n           (rst_n),
                .step_en         (stdp_tick),
                .pre_spike       (pre_q),
                .post_spike      (post_q[neuron]),
                .weight_addr     (synapse_addr(INDEX_WIDTH'(neuron))),
                .weight_in       (snap[neuron]),
                .weight_we       (stdp_we[neuron]),
                .weight_addr_out (stdp_addr_out[neuron]),
                .weight_out      (stdp_data_out[neuron])
            );
        end
    endgenerate

    always_comb begin
        weight_we   = 1'b0;
        weight_addr = '0;
        weight_din  = '0;
        case (state)
            ST_READ_REQ, ST_READ_CAP: begin
                weight_addr = synapse_addr(slot);
            end
            ST_WRITEBACK: begin
                weight_addr = pending_addr[slot];
                weight_din  = pending_din[slot];
                weight_we   = pending_we[slot];
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state  <= ST_IDLE;
            slot   <= '0;
            pre_q  <= 1'b0;
            col_q  <= '0;
            post_q <= '0;
            for (int i = 0; i < NUM_NEURONS; i++) begin
                snap[i]         <= '0;
                pending_we[i]   <= 1'b0;
                pending_addr[i] <= '0;
                pending_din[i]  <= '0;
            end
        end else begin
            if (step_en) begin
                pre_q <= pre_spike;
                // Hold the last pre's column across post-only / idle ticks
                // so LTP writes the originating synapse, not the PE's
                // current (or default-0) input_index.
                if (pre_spike)
                    col_q <= input_index;
            end

            case (state)
                ST_IDLE: begin
                    if (tick_done && learn_en) begin
                        post_q <= post_spikes;
                        slot   <= '0;
                        state  <= ST_READ_REQ;
                    end
                end

                ST_READ_REQ: begin
                    // Address is on the bus this cycle; WeightRam dout is
                    // registered, so the word is captured on the next edge.
                    state <= ST_READ_CAP;
                end

                ST_READ_CAP: begin
                    snap[slot] <= weight_dout;
                    if (slot == INDEX_WIDTH'(NUM_NEURONS - 1)) begin
                        slot  <= '0;
                        state <= ST_UPDATE;
                    end else begin
                        slot  <= slot + 1'b1;
                        state <= ST_READ_REQ;
                    end
                end

                ST_UPDATE: begin
                    // One-cycle local tick: every controller updates traces
                    // and computes LTP/LTD from the snapshot. weight_we is
                    // valid on the following fabric cycle (StdpController
                    // handoff contract).
                    state <= ST_HANDOFF;
                end

                ST_HANDOFF: begin
                    for (int i = 0; i < NUM_NEURONS; i++) begin
                        pending_we[i]   <= stdp_we[i];
                        pending_addr[i] <= stdp_addr_out[i];
                        pending_din[i]  <= stdp_data_out[i];
                    end
                    slot  <= '0;
                    state <= ST_WRITEBACK;
                end

                ST_WRITEBACK: begin
                    if (slot == INDEX_WIDTH'(NUM_NEURONS - 1))
                        state <= ST_IDLE;
                    else
                        slot <= slot + 1'b1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

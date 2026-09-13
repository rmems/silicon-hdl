// SPDX-License-Identifier: MIT OR Apache-2.0
// OutputLayer.sv
// Canonical source: spikenaut-core-sv/rtl
// Wires the 3-class output-layer weight bank (GH#72) into the SoC: reduces
// one tick's NUM_NEURONS spike_bitmap into NUM_CLASSES signed Q8.8 scores and
// reports the argmax as a one-hot result.
//
// Pipeline position (see docs/lif-array-connectivity-model.md): the LIF
// stage's documented "output" is spike_bitmap, not membrane_potentials, so
// this module consumes spike_bitmap -- Input -> Linear -> LIF -> (this)
// Output. It must be triggered from LifNeuronArray's tick_done, not raw
// step_en: spike_bitmap only updates on tick_done, ~17 cycles after step_en
// fires, so triggering on step_en would score the *previous* tick's spikes.
//
// Per-tick snapshot, not a persistent accumulator: score[k] is recomputed
// fresh every logical tick from that tick's spike_bitmap alone, matching the
// existing convention that spike_bitmap/membrane_potentials/spike_count are
// all live per-tick values with nothing carried across ticks today.
//
// Addressing is row-major, addr = neuron*NUM_CLASSES + class (verified
// against the real merged_v2_output_weights.mem: addr 0 = neuron 0 class 0).
// Signed Q8.8 saturating accumulate mirrors LifNeuron.sv's guard-bit idiom
// exactly, applied at every one of the NUM_NEURONS*NUM_CLASSES accumulate
// steps (16 worst-case Q8.8 terms can reach +/-2048, well outside +/-128
// without per-step saturation).
//
// Result encoding: argmax-of-3(N) one-hot, ties won by the lowest class
// index -- mirrors the "lowest active lane wins" convention already used in
// Basys3_Top.sv's stimulus decode. This is the SoC's only LED-visible
// consequence (status_word[15:13] in SocStatusLeds); the UART response frame
// is unchanged (see #64).

module OutputLayer #(
    parameter int DATA_WIDTH        = 16,
    parameter int NUM_NEURONS       = 16,
    parameter int NUM_CLASSES       = 3,
    // Guard the degenerate 1x1 layer: $clog2(1) is 0, which would make the
    // address port and its casts zero-width. Same idiom as
    // LifNeuronArray's INDEX_WIDTH.
    parameter int WEIGHT_ADDR_WIDTH =
        (NUM_NEURONS * NUM_CLASSES > 1) ? $clog2(NUM_NEURONS * NUM_CLASSES) : 1
)(
    input  logic                         clk,
    input  logic                         rst_n,
    // Pulse from the LIF array's tick_done -- see header note above.
    input  logic                         spike_valid,
    input  logic [NUM_NEURONS-1:0]       spike_bitmap,
    input  logic [DATA_WIDTH-1:0]        weight_dout,
    output logic [WEIGHT_ADDR_WIDTH-1:0] weight_addr,
    // Registered; holds its value between ticks (no reset-to-zero while idle).
    output logic [NUM_CLASSES-1:0]       result,
    // One-cycle strobe alongside a new result.
    output logic                         done
);

    localparam int TOTAL_PAIRS = NUM_NEURONS * NUM_CLASSES;
    localparam int COUNT_WIDTH = $clog2(TOTAL_PAIRS + 1);
    localparam int NIDX_WIDTH  = (NUM_NEURONS > 1) ? $clog2(NUM_NEURONS) : 1;
    localparam int CIDX_WIDTH  = (NUM_CLASSES > 1) ? $clog2(NUM_CLASSES) : 1;

    generate
        if (NUM_NEURONS < 1)
            $error("OutputLayer: NUM_NEURONS (%0d) must be at least 1", NUM_NEURONS);
        if (NUM_CLASSES < 1)
            $error("OutputLayer: NUM_CLASSES (%0d) must be at least 1", NUM_CLASSES);
        if (WEIGHT_ADDR_WIDTH < $clog2(TOTAL_PAIRS))
            $error("OutputLayer: WEIGHT_ADDR_WIDTH (%0d) is too small for %0d neurons x %0d classes",
                   WEIGHT_ADDR_WIDTH, NUM_NEURONS, NUM_CLASSES);
    endgenerate

    typedef enum logic [1:0] {IDLE, SWEEP, FINISH} sweep_state_t;
    sweep_state_t state;

    // req_idx walks 0..TOTAL_PAIRS-1, one address requested per SWEEP cycle.
    // consume_idx trails req_idx by one cycle -- WeightRam's dout is
    // registered, so weight_dout at any cycle reflects the address that was
    // on weight_addr the *previous* cycle (mirrors tb_WeightRam_init's
    // read_addr task: address at cycle N, data valid at cycle N+1).
    logic [COUNT_WIDTH-1:0] req_idx;
    logic [COUNT_WIDTH-1:0] consume_idx;
    logic                   consume_valid;
    logic                   req_valid;

    logic signed [DATA_WIDTH-1:0] class_acc [0:NUM_CLASSES-1];

    // Signed Q8.8 saturation extremes (mirrors LifNeuron.sv, GH#73).
    localparam logic signed [DATA_WIDTH-1:0] MAX_MEM = {1'b0, {(DATA_WIDTH-1){1'b1}}};
    localparam logic signed [DATA_WIDTH-1:0] MIN_MEM = {1'b1, {(DATA_WIDTH-1){1'b0}}};

    assign req_valid   = (state == SWEEP) && (req_idx < COUNT_WIDTH'(TOTAL_PAIRS));
    // address = neuron*NUM_CLASSES + class (class sweeps fastest), i.e.
    // req_idx itself by construction -- verified row-major against the real
    // merged_v2_output_weights.mem in the module header.
    assign weight_addr = req_valid ? WEIGHT_ADDR_WIDTH'(req_idx) : '0;

    // NUM_CLASSES is a small compile-time constant (3): constant divide/
    // modulo synthesizes to trivial combinational logic, not an actual
    // divider.
    logic [NIDX_WIDTH-1:0] consume_neuron;
    logic [CIDX_WIDTH-1:0] consume_class;
    assign consume_neuron = NIDX_WIDTH'(consume_idx / NUM_CLASSES);
    assign consume_class  = CIDX_WIDTH'(consume_idx % NUM_CLASSES);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= IDLE;
            req_idx       <= '0;
            consume_idx   <= '0;
            consume_valid <= 1'b0;
            done          <= 1'b0;
            result        <= '0;
            for (int c = 0; c < NUM_CLASSES; c++)
                class_acc[c] <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (spike_valid) begin
                        for (int c = 0; c < NUM_CLASSES; c++)
                            class_acc[c] <= '0;
                        req_idx       <= COUNT_WIDTH'(1);
                        consume_idx   <= '0;
                        consume_valid <= 1'b1;
                        state         <= SWEEP;
                    end
                end

                SWEEP: begin
                    automatic logic signed [DATA_WIDTH:0] sum_wide;
                    // Sign-extend both operands to the guard width BEFORE
                    // adding. SystemVerilog's context-determined sizing
                    // would already widen the add to sum_wide's width, but
                    // spelling it out keeps the no-wrap guarantee from
                    // resting on that rule -- and keeps it intact if this
                    // expression is ever moved into a self-determined
                    // context. Mirrors LifNeuron.sv, where the accumulator
                    // operand (decayed_wide) is already guard-width.
                    automatic logic signed [DATA_WIDTH:0] acc_wide;
                    automatic logic signed [DATA_WIDTH:0] weight_wide;

                    acc_wide    = $signed(class_acc[consume_class]);
                    weight_wide = $signed(weight_dout);

                    if (consume_valid) begin
                        sum_wide = spike_bitmap[consume_neuron]
                            ? (acc_wide + weight_wide)
                            : acc_wide;
                        if (sum_wide[DATA_WIDTH] != sum_wide[DATA_WIDTH-1])
                            class_acc[consume_class] <= sum_wide[DATA_WIDTH] ? MIN_MEM : MAX_MEM;
                        else
                            class_acc[consume_class] <= sum_wide[DATA_WIDTH-1:0];
                    end

                    consume_idx   <= req_idx;
                    consume_valid <= req_valid;

                    if (req_valid)
                        req_idx <= req_idx + COUNT_WIDTH'(1);

                    if (!req_valid && !consume_valid)
                        // Request pipeline and its one-cycle-trailing consume
                        // have both drained: every pair has been accumulated.
                        state <= FINISH;
                end

                FINISH: begin
                    automatic logic [NUM_CLASSES-1:0] winner;
                    automatic int best;

                    winner = '0;
                    best   = 0;
                    for (int c = 1; c < NUM_CLASSES; c++) begin
                        if ($signed(class_acc[c]) > $signed(class_acc[best]))
                            best = c;
                    end
                    winner[best] = 1'b1;

                    result <= winner;
                    done   <= 1'b1;
                    state  <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

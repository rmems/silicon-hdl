// SPDX-License-Identifier: MIT OR Apache-2.0
// LifNeuronArray.sv
// Canonical source: spikenaut-core-sv/rtl
// Time-multiplexed leaky integrate-and-fire processing element for one
// NUM_NEURONS-neuron logical tick.  One shared datapath handles one neuron
// slot per fabric cycle after fill; parameter/weight RAM reads and the
// selected membrane state are prefetched before the slot consumes them.
//
// Signed Dale E/I path (GH#73): weight_dout and the per-neuron membrane state
// are signed two's-complement Q8.8 (see spikenaut-core-sv/mem/README.md), so
// an inhibitory weight subtracts instead of misreading as a large positive
// integer. Mirrors LifNeuron.sv's signed leak/integrate/compare exactly (see
// that file's header for the saturation and symmetric-leak rationale).

module LifNeuronArray #(
    parameter int DATA_WIDTH        = 16,
    parameter int PARAM_WIDTH       = 16,
    parameter int NUM_NEURONS       = 16,
    parameter int INDEX_WIDTH       = (NUM_NEURONS > 1) ? $clog2(NUM_NEURONS) : 1,
    parameter int PARAM_ADDR_WIDTH  = 8,
    parameter int WEIGHT_ADDR_WIDTH = 2 * INDEX_WIDTH
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         step_en,
    input  logic                         spike_in,
    // The binary-event SoC drives input_index=0 today.  A future #62 frame
    // parser can select channels 0..NUM_NEURONS-1 without changing this PE.
    input  logic [INDEX_WIDTH-1:0]       input_index,
    input  logic [DATA_WIDTH-1:0]        weight_dout,
    input  logic [PARAM_WIDTH-1:0]       threshold_dout,
    input  logic [PARAM_WIDTH-1:0]       leak_dout,
    output logic [PARAM_ADDR_WIDTH-1:0]  threshold_addr,
    output logic [PARAM_ADDR_WIDTH-1:0]  leak_addr,
    output logic [WEIGHT_ADDR_WIDTH-1:0] weight_addr,
    output logic [NUM_NEURONS-1:0]       spike_bitmap,
    // Packed readback view of the per-neuron register file.  Lane 0 is the
    // least-significant DATA_WIDTH slice; the SoC protocol FSM serializes
    // each lane big-endian for the host response frame.
    output logic [NUM_NEURONS*DATA_WIDTH-1:0] membrane_potentials,
    output logic                         tick_done
);

    typedef enum logic [1:0] {IDLE, PREFETCH, SWEEP} sweep_state_t;

    sweep_state_t sweep_state;
    logic [INDEX_WIDTH-1:0] neuron_index;
    logic [INDEX_WIDTH-1:0] sweep_input_index;
    logic                   sweep_spike_in;
    logic                   sweep_refractory;
    logic [NUM_NEURONS-1:0] sweep_spikes;

    // One state word per neuron.  This is intentionally a register file, not
    // 16 replicated LIF datapaths.
    logic [DATA_WIDTH-1:0] membrane_potential [0:NUM_NEURONS-1];

    genvar membrane_lane;
    generate
        for (membrane_lane = 0; membrane_lane < NUM_NEURONS; membrane_lane++) begin : g_membrane_readback
            assign membrane_potentials[membrane_lane*DATA_WIDTH +: DATA_WIDTH] =
                membrane_potential[membrane_lane];
        end
    endgenerate

    logic [INDEX_WIDTH-1:0] address_neuron;
    logic [INDEX_WIDTH-1:0] address_input;
    // Keep this explicit retiming boundary: the BRAM outputs must settle in
    // these registers before the shared arithmetic consumes a neuron slot.
    // Without it, synthesis can absorb the stage into the RAM output path and
    // recreate a BRAM -> subtract -> add -> compare critical path.
    (* keep = "true", dont_touch = "true" *) logic [DATA_WIDTH-1:0]  weight_q;
    (* keep = "true", dont_touch = "true" *) logic [PARAM_WIDTH-1:0] threshold_q;
    (* keep = "true", dont_touch = "true" *) logic [PARAM_WIDTH-1:0] leak_q;
    // This state-word prefetch similarly removes the variable-index register
    // file mux from the shared leak/integrate/compare stage.
    (* keep = "true", dont_touch = "true" *) logic [DATA_WIDTH-1:0]  membrane_q;
    logic [DATA_WIDTH-1:0]  next_membrane;
    logic [DATA_WIDTH-1:0]  decayed_membrane;
    logic [DATA_WIDTH-1:0]  leak_value;
    logic [DATA_WIDTH-1:0]  threshold_value;
    logic                   next_spike;
    logic [NUM_NEURONS-1:0] sweep_spikes_next;

    // Signed Q8.8 saturation extremes (see file header, GH#73).
    localparam logic signed [DATA_WIDTH-1:0] MAX_MEM = {1'b0, {(DATA_WIDTH-1){1'b1}}};
    localparam logic signed [DATA_WIDTH-1:0] MIN_MEM = {1'b1, {(DATA_WIDTH-1){1'b0}}};
    // One extra bit so leak/integrate arithmetic is exact (no wraparound)
    // before the explicit saturate-to-DATA_WIDTH step.
    logic signed [DATA_WIDTH:0] mem_wide;
    logic signed [DATA_WIDTH:0] leak_wide;
    logic signed [DATA_WIDTH:0] decayed_wide;
    logic signed [DATA_WIDTH:0] sum_wide;

    generate
        if (NUM_NEURONS < 1)
            $error("LifNeuronArray: NUM_NEURONS (%0d) must be at least 1", NUM_NEURONS);
        if (PARAM_WIDTH != DATA_WIDTH)
            $error("LifNeuronArray: PARAM_WIDTH (%0d) must equal DATA_WIDTH (%0d)",
                   PARAM_WIDTH, DATA_WIDTH);
        if (PARAM_ADDR_WIDTH < INDEX_WIDTH)
            $error("LifNeuronArray: PARAM_ADDR_WIDTH (%0d) is too small for %0d neurons",
                   PARAM_ADDR_WIDTH, NUM_NEURONS);
        if (WEIGHT_ADDR_WIDTH < 2 * INDEX_WIDTH)
            $error("LifNeuronArray: WEIGHT_ADDR_WIDTH (%0d) is too small for a %0dx%0d matrix",
                   WEIGHT_ADDR_WIDTH, NUM_NEURONS, NUM_NEURONS);
    endgenerate

    // The RAMs have synchronous, one-cycle registered reads.  On the tick
    // edge while IDLE, address 0 is sampled.  PREFETCH captures that dout
    // into the PE's timing register while requesting row 1.  Once SWEEP is
    // full, one row is processed every fabric cycle while the next row is
    // captured and the address advances another slot ahead.
    always_comb begin
        address_neuron = '0;
        address_input  = input_index;

        if (sweep_state != IDLE) begin
            address_input = sweep_input_index;
            if (NUM_NEURONS > 1) begin
                if (sweep_state == PREFETCH) begin
                    address_neuron = INDEX_WIDTH'(1);
                end else if (neuron_index < NUM_NEURONS - 2) begin
                    address_neuron = neuron_index + INDEX_WIDTH'(2);
                end else begin
                    address_neuron = INDEX_WIDTH'(NUM_NEURONS - 1);
                end
            end
        end

        threshold_addr = '0;
        leak_addr      = '0;
        weight_addr    = '0;
        threshold_addr = address_neuron;
        leak_addr      = address_neuron;
        // Flattened matrix policy: address = output-neuron row * input count
        //                                  + selected input channel.
        weight_addr = WEIGHT_ADDR_WIDTH'((address_neuron * NUM_NEURONS) + address_input);
    end

    // Shared leak -> integrate -> compare datapath.  sweep_refractory is
    // prefetched with each slot, so the shared arithmetic has no same-cycle
    // variable-index lookup into the prior-tick spike bitmap.
    always_comb begin
        leak_value      = leak_q;
        threshold_value = threshold_q;
        decayed_membrane = '0;
        next_membrane    = '0;
        next_spike       = 1'b0;
        sweep_spikes_next = sweep_spikes;

        mem_wide     = '0;
        leak_wide    = '0;
        decayed_wide = '0;
        sum_wide     = '0;

        if (sweep_refractory) begin
            next_membrane = '0;
            next_spike    = 1'b0;
        end else begin
            mem_wide  = $signed(membrane_q);
            leak_wide = $signed(leak_value);

            // Leak pulls the membrane toward the 0 resting potential from
            // either side (GH#73): mirrors LifNeuron.sv exactly -- one
            // sign-selected add/subtract plus a sign-flip clamp check
            // instead of a magnitude compare, since this shared datapath is
            // timing-critical (see the retiming comments above).
            decayed_wide = mem_wide[DATA_WIDTH] ? (mem_wide + leak_wide) : (mem_wide - leak_wide);
            if (decayed_wide[DATA_WIDTH] != mem_wide[DATA_WIDTH])
                decayed_wide = '0;  // crossed past 0 resting potential -- clamp
            decayed_membrane = decayed_wide[DATA_WIDTH-1:0];

            // Integrate, then saturate to the signed Q8.8 extremes instead of
            // wrapping (positive overflow from strong excitation, negative
            // overflow from strong inhibition).
            sum_wide = sweep_spike_in ? (decayed_wide + $signed(weight_q)) : decayed_wide;

            // sum_wide is exactly one bit wider than needed, so it always
            // holds the true (non-wrapping) sum: it fits back in DATA_WIDTH
            // bits iff the guard bit matches the sign bit. Cheap bit compare
            // instead of a wide magnitude compare against MAX_MEM/MIN_MEM --
            // this shared datapath is timing-critical (see the retiming
            // comments above on weight_q/threshold_q/leak_q/membrane_q).
            if (sum_wide[DATA_WIDTH] != sum_wide[DATA_WIDTH-1])
                next_membrane = sum_wide[DATA_WIDTH] ? MIN_MEM : MAX_MEM;
            else
                next_membrane = sum_wide[DATA_WIDTH-1:0];

            // Signed compare: next_membrane can now be negative (inhibited);
            // threshold_value is always non-negative in shipped banks.
            next_spike = ($signed(next_membrane) >= $signed(threshold_value));
        end

        sweep_spikes_next[neuron_index] = next_spike;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sweep_state      <= IDLE;
            neuron_index     <= '0;
            sweep_input_index <= '0;
            sweep_spike_in   <= 1'b0;
            sweep_refractory <= 1'b0;
            sweep_spikes     <= '0;
            weight_q         <= '0;
            threshold_q      <= '0;
            leak_q           <= '0;
            membrane_q       <= '0;
            spike_bitmap     <= '0;
            tick_done        <= 1'b0;
            for (int i = 0; i < NUM_NEURONS; i++)
                membrane_potential[i] <= '0;
        end else begin
            tick_done <= 1'b0;

            case (sweep_state)
                IDLE: begin
                    if (step_en) begin
                        // Capture the selected binary event before the SoC
                        // consumes its completed protocol frame on this edge.
                        neuron_index      <= '0;
                        sweep_input_index <= input_index;
                        sweep_spike_in    <= spike_in;
                        // RAM row 0 is sampled on this edge, captured in the
                        // PREFETCH state, then processed in the first SWEEP
                        // cycle. Prefetch its prior-tick spike state now for
                        // that refractory decision.
                        sweep_refractory  <= spike_bitmap[0];
                        membrane_q        <= membrane_potential[0];
                        sweep_spikes      <= '0;
                        sweep_state       <= PREFETCH;
                    end
                end

                PREFETCH: begin
                    // The row-0 RAM read sampled on the tick edge is now
                    // available.  Retiming it here breaks the BRAM-to-LIF
                    // arithmetic path without reducing one-slot-per-cycle
                    // steady-state throughput.
                    weight_q    <= weight_dout;
                    threshold_q <= threshold_dout;
                    leak_q      <= leak_dout;
                    sweep_state <= SWEEP;
                end

                SWEEP: begin
                    // Capture the prefetch requested by the previous cycle
                    // while the shared datapath consumes the current row.
                    weight_q    <= weight_dout;
                    threshold_q <= threshold_dout;
                    leak_q      <= leak_dout;
                    membrane_potential[neuron_index] <= next_membrane;
                    sweep_spikes <= sweep_spikes_next;

                    if (neuron_index == NUM_NEURONS - 1) begin
                        // Publish a coherent result only after every slot has
                        // been processed; this also becomes next tick's
                        // refractory-state bitmap.
                        spike_bitmap <= sweep_spikes_next;
                        tick_done    <= 1'b1;
                        sweep_state  <= IDLE;
                    end else begin
                        neuron_index <= neuron_index + 1'b1;
                        // Prefetch the next slot's refractory state while
                        // the shared datapath processes this one.
                        sweep_refractory <= spike_bitmap[neuron_index + 1'b1];
                        membrane_q <= membrane_potential[neuron_index + 1'b1];
                    end
                end

                default: sweep_state <= IDLE;
            endcase
        end
    end

endmodule

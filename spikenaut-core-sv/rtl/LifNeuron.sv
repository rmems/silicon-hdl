// SPDX-License-Identifier: MIT OR Apache-2.0
// LifNeuron.sv
// Canonical source: spikenaut-core-sv/rtl
// Leaky Integrate-and-Fire neuron model
// Updates (leak, integrate, fire) occur only when step_en is 1. spike_out is
// therefore high for one *enabled tick*, not one fabric cycle: while step_en is
// 0 it holds its last value until the next enabled edge clears it.
// See docs/timestep-contract.md. Unit TBs drive step_en=1 every cycle, where a
// tick and a fabric cycle coincide.
//
// Signed Dale E/I path (GH#73): weight and membrane_potential are signed
// two's-complement Q8.8 (see spikenaut-core-sv/mem/README.md), so an
// inhibitory weight subtracts from the membrane instead of misreading as a
// large positive integer. Integration saturates at the signed Q8.8 extremes
// (MAX_MEM / MIN_MEM), and leak decays the membrane toward the 0 resting
// potential from either side (mirrored for negative membrane) rather than
// only draining a positive one. threshold/leak are always non-negative in
// shipped banks; only the compare against membrane needs to be signed.

module LifNeuron #(
    parameter int DATA_WIDTH  = 16,
    parameter int PARAM_WIDTH = 16
)(
    input  logic                   clk, 
    input  logic                   rst_n,
    input  logic                   step_en,
    input  logic                   spike_in,
    input  logic [DATA_WIDTH-1:0]  weight,
    input  logic [PARAM_WIDTH-1:0] threshold,
    input  logic [PARAM_WIDTH-1:0] leak,
    output logic                   spike_out
);

    logic [DATA_WIDTH-1:0] membrane_potential;

    // Signed Q8.8 saturation extremes (see file header, GH#73).
    localparam logic signed [DATA_WIDTH-1:0] MAX_MEM = {1'b0, {(DATA_WIDTH-1){1'b1}}};
    localparam logic signed [DATA_WIDTH-1:0] MIN_MEM = {1'b1, {(DATA_WIDTH-1){1'b0}}};

    // Elaboration-time guard: PARAM_WIDTH must equal DATA_WIDTH. Uses a
    // generate-if so the check fires during elaboration/synthesis (not just
    // at simulation time 0 like an initial block), catching width mismatches
    // at Vivado build time.
    generate
        if (PARAM_WIDTH != DATA_WIDTH)
            $error("LifNeuron: PARAM_WIDTH (%0d) must equal DATA_WIDTH (%0d)",
                   PARAM_WIDTH, DATA_WIDTH);
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            membrane_potential <= '0;
            spike_out          <= 1'b0;
        end else if (step_en) begin
            // Reset membrane on the tick following the spike to ensure a
            // single-tick pulse on spike_out.
            automatic logic [DATA_WIDTH-1:0]        next_mem;
            automatic logic [DATA_WIDTH-1:0]        leak_val;
            automatic logic [DATA_WIDTH-1:0]        threshold_val;
            automatic logic                         next_spike;
            // One extra bit so leak/integrate arithmetic is exact (no
            // wraparound) before the explicit saturate-to-DATA_WIDTH step.
            automatic logic signed [DATA_WIDTH:0]   mem_wide;
            automatic logic signed [DATA_WIDTH:0]   leak_wide;
            automatic logic signed [DATA_WIDTH:0]   decayed_wide;
            automatic logic signed [DATA_WIDTH:0]   sum_wide;

            // Use assignment-based resize so SystemVerilog handles any width
            // mismatch safely (zero-extend/truncate) instead of raw bit-slicing
            // which is unsafe when PARAM_WIDTH != DATA_WIDTH.
            leak_val      = leak;
            threshold_val = threshold;

            if (spike_out) begin
                // Refractory period: after a spike the membrane is reset to
                // zero and incoming spikes during this single reset tick are
                // intentionally ignored. This mirrors biological LIF neuron
                // behavior (absolute refractory period) and guarantees a clean
                // single-tick pulse on spike_out.
                next_mem   = '0;
                next_spike = 1'b0;
            end else begin
                mem_wide  = $signed(membrane_potential);
                leak_wide = $signed(leak_val);

                // Leak pulls the membrane toward the 0 resting potential from
                // either side (GH#73): a positive membrane still drains
                // toward 0 (original behavior); a negative (inhibited)
                // membrane now recovers toward 0 the same way. Implemented as
                // one conditional add/subtract (sign-selected) plus a
                // sign-flip check for the zero-crossing clamp, instead of a
                // magnitude compare -- this shared datapath is
                // timing-critical (see LifNeuronArray.sv's retiming
                // comments), and a magnitude compare here missed timing.
                decayed_wide = mem_wide[DATA_WIDTH] ? (mem_wide + leak_wide) : (mem_wide - leak_wide);
                if (decayed_wide[DATA_WIDTH] != mem_wide[DATA_WIDTH])
                    decayed_wide = '0;  // crossed past 0 resting potential -- clamp

                // Integrate spike input, then saturate to the signed Q8.8
                // extremes to prevent arithmetic wraparound (positive
                // overflow from strong excitation, negative overflow from
                // strong inhibition) that could mask or fake a threshold
                // crossing.
                sum_wide = spike_in ? (decayed_wide + $signed(weight)) : decayed_wide;

                // sum_wide is exactly one bit wider than needed, so it always
                // holds the true (non-wrapping) sum: it fits back in
                // DATA_WIDTH bits iff the guard bit matches the sign bit.
                // This is a cheap bit compare instead of a wide magnitude
                // compare against MAX_MEM/MIN_MEM, which matters here --
                // this datapath is a timing-critical shared resource (see
                // LifNeuronArray.sv's retiming comments).
                if (sum_wide[DATA_WIDTH] != sum_wide[DATA_WIDTH-1])
                    next_mem = sum_wide[DATA_WIDTH] ? MIN_MEM : MAX_MEM;
                else
                    next_mem = sum_wide[DATA_WIDTH-1:0];

                // Compare against the freshly-integrated value so a spike is
                // registered as soon as it is crossed (fixes a one-cycle
                // delay bug from comparing the pre-integration value).
                // Signed compare: next_mem can now be negative (inhibited);
                // threshold_val is always non-negative in shipped banks.
                next_spike = ($signed(next_mem) >= $signed(threshold_val));
            end

            membrane_potential <= next_mem;
            spike_out          <= next_spike;
        end
    end

endmodule

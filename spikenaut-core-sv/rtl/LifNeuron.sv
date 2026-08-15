// SPDX-License-Identifier: MIT OR Apache-2.0
// LifNeuron.sv
// Canonical source: spikenaut-core-sv/rtl
// Leaky Integrate-and-Fire neuron model
// Updates (leak, integrate, fire) occur only when step_en is 1.
// See docs/timestep-contract.md. Unit TBs drive step_en=1 every cycle.

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
            // Reset membrane in the same cycle as the spike to ensure a
            // single-cycle pulse on spike_out.
            automatic logic [DATA_WIDTH-1:0] next_mem;
            automatic logic [DATA_WIDTH-1:0] decayed_mem;
            automatic logic [DATA_WIDTH-1:0] leak_val;
            automatic logic [DATA_WIDTH-1:0] threshold_val;
            automatic logic                  next_spike;

            // Use assignment-based resize so SystemVerilog handles any width
            // mismatch safely (zero-extend/truncate) instead of raw bit-slicing
            // which is unsafe when PARAM_WIDTH != DATA_WIDTH.
            leak_val      = leak;
            threshold_val = threshold;

            if (spike_out) begin
                // Refractory period: after a spike the membrane is reset to
                // zero and incoming spikes during this single reset cycle are
                // intentionally ignored. This mirrors biological LIF neuron
                // behavior (absolute refractory period) and guarantees a clean
                // single-cycle pulse on spike_out.
                next_mem   = '0;
                next_spike = 1'b0;
            end else begin
                // Apply leak with saturation to prevent underflow
                if (membrane_potential > leak_val)
                    decayed_mem = membrane_potential - leak_val;
                else
                    decayed_mem = '0;

                // Integrate spike input with saturation to prevent arithmetic
                // wraparound that could mask a threshold crossing.
                if (spike_in) begin
                    if (decayed_mem > ({DATA_WIDTH{1'b1}} - weight))
                        next_mem = {DATA_WIDTH{1'b1}};  // saturate at max
                    else
                        next_mem = decayed_mem + weight;
                end else begin
                    next_mem = decayed_mem;
                end

                // Compare against the freshly-integrated value so a spike is
                // registered as soon as it is crossed (fixes a one-cycle
                // delay bug from comparing the pre-integration value).
                next_spike = (next_mem >= threshold_val);
            end

            membrane_potential <= next_mem;
            spike_out          <= next_spike;
        end
    end

endmodule

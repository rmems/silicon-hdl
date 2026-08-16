// SPDX-License-Identifier: MIT OR Apache-2.0
// StdpController.sv
// Canonical source: spikenaut-core-sv/rtl
// Spike-Timing-Dependent Plasticity controller
//
// Polarity policy (classical causal STDP / Bi–Poo convention, GH#55):
//   - Pre-then-post (post_spike while pre_trace active) → LTP (weight + 1)
//   - Post-then-pre (pre_spike while post_trace active) → LTD (weight - 1)
// Prior to #55 the LTP/LTD arms were inverted relative to this convention.
//
// Traces and LTP/LTD update only when step_en is 1. WINDOW_WIDTH is in
// logical ticks, not fabric clocks (docs/timestep-contract.md).
//
// Output contract under gating: weight_out and weight_addr_out hold their
// last enabled-tick value while step_en is 0 (they are NOT a per-fabric-cycle
// passthrough of weight_in/weight_addr). weight_we is forced low on every
// disabled cycle, so the "weight changed" strobe stays one tick wide.
// Consumers must sample these outputs on the tick, not on arbitrary cycles.

module StdpController #(
    parameter int DATA_WIDTH   = 16,
    parameter int ADDR_WIDTH   = 10,
    parameter int WINDOW_WIDTH = 8
)(
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   step_en,
    input  logic                   pre_spike,
    input  logic                   post_spike,
    input  logic [ADDR_WIDTH-1:0]  weight_addr,
    input  logic [DATA_WIDTH-1:0]  weight_in,
    output logic                   weight_we,
    output logic [ADDR_WIDTH-1:0]  weight_addr_out,
    output logic [DATA_WIDTH-1:0]  weight_out
);

    logic [WINDOW_WIDTH-1:0] pre_trace;
    logic [WINDOW_WIDTH-1:0] post_trace;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pre_trace       <= '0;
            post_trace      <= '0;
            weight_we       <= 1'b0;
            weight_addr_out <= '0;
            weight_out      <= '0;
        end else if (step_en) begin
            pre_trace  <= pre_spike  ? {WINDOW_WIDTH{1'b1}} : (pre_trace  >> 1);
            post_trace <= post_spike ? {WINDOW_WIDTH{1'b1}} : (post_trace >> 1);
            // weight_we asserts only when the selected LTP/LTD branch changes weight.
            // LTP has priority if both conditions are true in the same cycle.
            // Saturation (LTP at max / LTD at zero) holds weight_out and keeps weight_we low.
            // Basys3_Top leaves weight_we unconnected; consumers treat it as "weight changed".
            weight_addr_out <= weight_addr;
            if (post_spike && pre_trace != '0) begin
                // LTP (classical): pre-then-post – saturate at maximum value
                if (weight_in == {DATA_WIDTH{1'b1}}) begin
                    weight_out <= weight_in;
                    weight_we  <= 1'b0;
                end else begin
                    weight_out <= weight_in + 1;
                    weight_we  <= 1'b1;
                end
            end else if (pre_spike && post_trace != '0) begin
                // LTD (classical): post-then-pre – saturate at zero
                if (weight_in == '0) begin
                    weight_out <= weight_in;
                    weight_we  <= 1'b0;
                end else begin
                    weight_out <= weight_in - 1;
                    weight_we  <= 1'b1;
                end
            end else begin
                weight_out <= weight_in;
                weight_we  <= 1'b0;
            end
        end else begin
            weight_we <= 1'b0;
            // hold traces, weight_addr_out, weight_out
        end
    end

endmodule

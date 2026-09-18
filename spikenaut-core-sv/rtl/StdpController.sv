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
// Arithmetic is signed two's-complement Q8.8 (GH#73 / GH#70): ±1 LSB with
// saturate at the signed extremes 16'h7FFF / 16'h8000. Unsigned saturate at
// 16'hFFFF would wrap a max-excitatory weight into max-inhibitory, and would
// treat 16'hFFFF (−1) as "already max" so an inhibitory synapse could never
// LTP back toward zero. Timing locked by tb_StdpController.
//
// Traces and LTP/LTD update only when step_en is 1. WINDOW_WIDTH is in
// logical ticks, not fabric clocks (docs/timestep-contract.md).
//
// Output contract under gating (registered handoff): outputs register at the
// enabled edge, so they are valid during the fabric cycle AFTER the tick.
// weight_we is a one-fabric-cycle strobe in that handoff cycle — the only
// cycle it can be high while step_en is low — and weight_out /
// weight_addr_out are aligned with it, then hold their values until the next
// tick's update (they are NOT a per-fabric-cycle passthrough of
// weight_in / weight_addr). A fabric-clocked RAM write port therefore latches
// each change exactly once. Consumers must not assume weight_we overlaps
// step_en itself. Timing locked by the handoff checks in tb_StdpController.

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

    // Signed Q8.8 saturation extremes (see file header, GH#73 / GH#70).
    localparam logic signed [DATA_WIDTH-1:0] MAX_W = {1'b0, {(DATA_WIDTH-1){1'b1}}};
    localparam logic signed [DATA_WIDTH-1:0] MIN_W = {1'b1, {(DATA_WIDTH-1){1'b0}}};

    logic signed [DATA_WIDTH-1:0] weight_signed;
    assign weight_signed = $signed(weight_in);

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
            // Saturation (LTP at signed max / LTD at signed min) holds weight_out
            // and keeps weight_we low.
            weight_addr_out <= weight_addr;
            if (post_spike && pre_trace != '0) begin
                // LTP (classical): pre-then-post – saturate at signed maximum
                if (weight_signed == MAX_W) begin
                    weight_out <= weight_in;
                    weight_we  <= 1'b0;
                end else begin
                    weight_out <= weight_signed + 1;
                    weight_we  <= 1'b1;
                end
            end else if (pre_spike && post_trace != '0) begin
                // LTD (classical): post-then-pre – saturate at signed minimum
                if (weight_signed == MIN_W) begin
                    weight_out <= weight_in;
                    weight_we  <= 1'b0;
                end else begin
                    weight_out <= weight_signed - 1;
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

// SPDX-License-Identifier: MIT OR Apache-2.0
// Basys3_Top.sv
// Canonical source: spikenaut-soc-sv/rtl
//
// Top-level SoC wrapper for the Basys 3 FPGA board.
// Module name is spikenaut_soc_basys3_top (unique; avoids collision with
// synapse_demo_basys3_top in synapse-link-hdl/examples/basys3/).
//
// E2 / #39: RAM instances load merged_v2 Q8.8 images via INIT_FILE at
// elaboration / bitstream init. Paths are relative to the tool CWD — run
// Vivado batch and Verilator from the repo root (see mem/README.md).
// build_soc.tcl may override with absolute paths via -generic.
//
// RTL dependencies (compiled in lib_core / lib_bridge before this file):
//   spikenaut-core-sv/rtl/LifNeuron.sv
//   spikenaut-core-sv/rtl/WeightRam.sv
//   spikenaut-core-sv/rtl/NeuronParamRam.sv
//   spikenaut-core-sv/rtl/StdpController.sv
//   spikenaut-bridge-sv/rtl/UartRx.sv
//   spikenaut-bridge-sv/rtl/UartTx.sv
//   spikenaut-bridge-sv/rtl/SiliconBridge.sv

module spikenaut_soc_basys3_top #(
    // merged_v2 defaults (repo-root relative). Override from build_soc.tcl.
    parameter string WEIGHT_INIT_FILE = "spikenaut-core-sv/mem/merged_v2_weights.mem",
    parameter string THRESH_INIT_FILE = "spikenaut-core-sv/mem/merged_v2_thresholds.mem",
    parameter string LEAK_INIT_FILE   = "spikenaut-core-sv/mem/merged_v2_decay.mem",
    // 256-entry weight image => ADDR_WIDTH=8 (not core default 10).
    parameter int    WEIGHT_ADDR_W    = 8,
    parameter int    NEURON_ADDR_W    = 8
)(
    input  logic        clk,       // 100 MHz on-board oscillator
    input  logic        rst_n,     // Physically active-high button (U18/BTNC/CPU_RESET); inverted to rst (active-low) internally per gh-14 5u3.5. XDC port name kept for compatibility.
    // UART
    input  logic        uart_rx,
    output logic        uart_tx,
    // LEDs (lower 16 bits of spike output bus)
    output logic [15:0] led
);

    // ----------------------------------------------------------------
    // Parameters
    // ----------------------------------------------------------------
    localparam int CLK_FREQ        = 100_000_000;
    localparam int BAUD_RATE       = 115_200;
    localparam int DATA_WIDTH      = 16;
    localparam int PARAM_WIDTH     = 16;

    // gh-14 5u3.5 (P1): inversion in RTL (XDC pin/port rst_n kept for compatibility;
    // BTNC/CPU_RESET U18 is active-high). Use 'rst' (active-low) for all submodules + local logic.
    logic rst;
    assign rst = ~rst_n;

    // ----------------------------------------------------------------
    // Bridge
    // ----------------------------------------------------------------
    logic [7:0] bridge_rx_data;
    logic       bridge_rx_valid;
    logic       bridge_tx_busy;

    SiliconBridge #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_bridge (
        .clk          (clk),
        .rst_n        (rst),
        .uart_rx_pin  (uart_rx),
        .uart_tx_pin  (uart_tx),
        .rx_data      (bridge_rx_data),
        .rx_valid     (bridge_rx_valid),
        .tx_data      (bridge_rx_data),
        .tx_send      (1'b0),
        .tx_busy      (bridge_tx_busy)
    );
    // Bridge: 8b UART stream (DATA_WIDTH=8 fixed in SiliconBridge/UARTs per gh-14 5u3.7 cleanup);
    // top-level DATA_WIDTH=16 / PARAM=16 used only for core (neuron/ram/weights). Widths reviewed.
    // tx_send=1'b0 (disabled in SoC demo); tx_busy wired for 5u3.4 race review (if tx ever enabled, gate with !busy per synapse fix).

    // ----------------------------------------------------------------
    // Neuron parameter RAM
    // ----------------------------------------------------------------
    // Per NeuronParamRam contract (gh-14 5u3.6/5u3.7): stores ONE param per addr.
    // Multiple param types (threshold/leak) require separate RAM instances.
    // E2: $readmemh from merged_v2; host UART rewrite remains a later path.
    // we=0, addr=0 => dout settles to image word 0 after first post-reset read.
    // Note (E3 board smoke): LifNeuron applies leak every 100 MHz cycle while
    // UART rx_valid is 1 cycle/byte — continuous UART traffic alone will not
    // integrate to threshold with these Q8.8 values. E3 should gate updates to
    // protocol timesteps or use a demo stim path, not rely on raw UART bytes.
    logic [PARAM_WIDTH-1:0] threshold_param;
    logic [PARAM_WIDTH-1:0] leak_param;

    NeuronParamRam #(
        .ADDR_WIDTH  (NEURON_ADDR_W),
        .PARAM_WIDTH (PARAM_WIDTH),
        .INIT_FILE   (THRESH_INIT_FILE)
    ) u_npram_threshold (
        .clk  (clk),
        .rst_n (rst),
        .we   (1'b0),
        .addr ('0),
        .din  ('0),
        .dout (threshold_param)
    );

    NeuronParamRam #(
        .ADDR_WIDTH  (NEURON_ADDR_W),
        .PARAM_WIDTH (PARAM_WIDTH),
        .INIT_FILE   (LEAK_INIT_FILE)
    ) u_npram_leak (
        .clk  (clk),
        .rst_n (rst),
        .we   (1'b0),
        .addr ('0),
        .din  ('0),
        .dout (leak_param)
    );

    // ----------------------------------------------------------------
    // Weight RAM
    // ----------------------------------------------------------------
    logic [DATA_WIDTH-1:0] weight_dout;

    WeightRam #(
        .ADDR_WIDTH (WEIGHT_ADDR_W),
        .DATA_WIDTH (DATA_WIDTH),
        .INIT_FILE  (WEIGHT_INIT_FILE)
    ) u_wram (
        .clk  (clk),
        .rst_n (rst),
        .we   (1'b0),
        .addr ('0),
        .din  ('0),
        .dout (weight_dout)
    );

    // ----------------------------------------------------------------
    // LIF neuron
    // ----------------------------------------------------------------
    // gh-14 / 5u3.2 (P0): reviewed widths for neuron threshold/leak params
    // (from NeuronParamRam) + weight + SoC inst site.
    // Note: PARAM_WIDTH for params, DATA_WIDTH for weights/neuron data.
    // Bridge iface is 8b (see below); DATA_WIDTH=16 here is *not* for UART.
    // Both variants checked (synapse variant has no neuron/RAMs).
    // Threshold and leak sourced from separate NeuronParamRam instances per contract.
    logic spike_out;

    LifNeuron #(
        .DATA_WIDTH  (DATA_WIDTH),
        .PARAM_WIDTH (PARAM_WIDTH)
    ) u_neuron (
        .clk       (clk),
        .rst_n     (rst),
        .spike_in  (bridge_rx_valid),
        .weight    (weight_dout),
        .threshold (threshold_param),
        .leak      (leak_param),
        .spike_out (spike_out)
    );

    // ----------------------------------------------------------------
    // STDP controller
    // ----------------------------------------------------------------
    // gh-14 5u3.2: width review at ~109 area (DATA_WIDTH paths to Stdp);
    // connections match declared widths (no mismatch post-cast review).
    StdpController #(
        .DATA_WIDTH   (DATA_WIDTH),
        .ADDR_WIDTH   (WEIGHT_ADDR_W)
    ) u_stdp (
        .clk            (clk),
        .rst_n          (rst),
        .pre_spike      (bridge_rx_valid),
        .post_spike     (spike_out),
        .weight_addr    ('0),
        .weight_in      (weight_dout),
        .weight_we      (),
        .weight_addr_out(),
        .weight_out     ()
    );

    // ----------------------------------------------------------------
    // LED output
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst)
            led <= '0;
        else
            led <= {15'b0, spike_out};
    end

endmodule

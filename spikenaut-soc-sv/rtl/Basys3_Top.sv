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
//   spikenaut-core-sv/rtl/LifNeuronArray.sv
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
    localparam int NUM_NEURONS     = 16;

    // gh-14 5u3.5 (P1): inversion in RTL (XDC pin/port rst_n kept for compatibility;
    // BTNC/CPU_RESET U18 is active-high). Use 'rst' (active-low) for all submodules + local logic.
    logic rst;
    assign rst = ~rst_n;

    localparam int TICK_HZ   = 1000;
    localparam int STEP_DIV  = CLK_FREQ / TICK_HZ; // 100_000
    logic [$clog2(STEP_DIV)-1:0] step_cnt;
    logic                        step_en;

    always_ff @(posedge clk) begin
        if (!rst) begin
            step_cnt <= '0;
            step_en  <= 1'b0;
        end else if (step_cnt == STEP_DIV - 1) begin
            step_cnt <= '0;
            step_en  <= 1'b1;
        end else begin
            step_cnt <= step_cnt + 1'b1;
            step_en  <= 1'b0;
        end
    end

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
    // UART event -> logical tick domain (#60)
    // ----------------------------------------------------------------
    // rx_valid is a ONE fabric-cycle strobe, but the cores sample their inputs
    // only on the one-cycle step_en tick (1 per 100_000 cycles). Feeding
    // rx_valid straight in drops ~all received bytes. Latch each event until
    // the next tick consumes it.
    //
    // Set (rx_valid) has priority over clear (step_en), so a byte landing on
    // the same edge as a tick is carried to the *next* tick instead of being
    // lost. Multiple bytes inside one tick collapse to a single spike: the
    // demo input is a binary event per tick, not a count. A counting/FIFO
    // interface belongs with the host step path (#62).
    logic spike_pending;

    always_ff @(posedge clk) begin
        if (!rst)
            spike_pending <= 1'b0;
        else if (bridge_rx_valid)
            spike_pending <= 1'b1;
        else if (step_en)
            spike_pending <= 1'b0;
    end

    // ----------------------------------------------------------------
    // Neuron parameter RAM
    // ----------------------------------------------------------------
    // Per NeuronParamRam contract (gh-14 5u3.6/5u3.7): stores ONE param per addr.
    // Multiple param types (threshold/leak) require separate RAM instances.
    // E2: $readmemh from merged_v2; host UART rewrite remains a later path.
    // we=0: the PE owns read addressing while #63 owns runtime host writes.
    // The time-multiplexed LIF PE sweeps the 16 parameter entries on each
    // logical tick; its address outputs account for registered RAM read latency.
    // Timestep: LifNeuronArray / StdpController update only on step_en (1 ms).
    // See docs/timestep-contract.md (#57 / #60).
    logic [PARAM_WIDTH-1:0] threshold_param;
    logic [PARAM_WIDTH-1:0] leak_param;
    logic [NEURON_ADDR_W-1:0] threshold_addr;
    logic [NEURON_ADDR_W-1:0] leak_addr;

    NeuronParamRam #(
        .ADDR_WIDTH  (NEURON_ADDR_W),
        .PARAM_WIDTH (PARAM_WIDTH),
        .INIT_FILE   (THRESH_INIT_FILE)
    ) u_npram_threshold (
        .clk  (clk),
        .rst_n (rst),
        .we   (1'b0),
        .addr (threshold_addr),
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
        .addr (leak_addr),
        .din  ('0),
        .dout (leak_param)
    );

    // ----------------------------------------------------------------
    // Weight RAM
    // ----------------------------------------------------------------
    logic [DATA_WIDTH-1:0] weight_dout;
    logic [WEIGHT_ADDR_W-1:0] weight_addr;

    WeightRam #(
        .ADDR_WIDTH (WEIGHT_ADDR_W),
        .DATA_WIDTH (DATA_WIDTH),
        .INIT_FILE  (WEIGHT_INIT_FILE)
    ) u_wram (
        .clk  (clk),
        .rst_n (rst),
        .we   (1'b0),
        .addr (weight_addr),
        .din  ('0),
        .dout (weight_dout)
    );

    // ----------------------------------------------------------------
    // Time-multiplexed N=16 LIF processing element
    // ----------------------------------------------------------------
    // gh-14 / 5u3.2 (P0): reviewed widths for neuron threshold/leak params
    // (from NeuronParamRam) + weight + SoC inst site.
    // Note: PARAM_WIDTH for params, DATA_WIDTH for weights/neuron data;
    // bridge DATA_WIDTH remains 8b.  The current binary UART event broadcasts
    // to all 16 output-neuron rows at input column 0.  #62 will provide the
    // 16-channel frame parser / selectable input column.
    logic [NUM_NEURONS-1:0] spike_bitmap;

    LifNeuronArray #(
        .DATA_WIDTH        (DATA_WIDTH),
        .PARAM_WIDTH       (PARAM_WIDTH),
        .NUM_NEURONS       (NUM_NEURONS),
        .PARAM_ADDR_WIDTH  (NEURON_ADDR_W),
        .WEIGHT_ADDR_WIDTH (WEIGHT_ADDR_W)
    ) u_lif_array (
        .clk            (clk),
        .rst_n          (rst),
        .step_en        (step_en),
        .spike_in       (spike_pending),
        .input_index    ('0),
        .weight_dout    (weight_dout),
        .threshold_dout (threshold_param),
        .leak_dout      (leak_param),
        .threshold_addr (threshold_addr),
        .leak_addr      (leak_addr),
        .weight_addr    (weight_addr),
        .spike_bitmap   (spike_bitmap),
        .tick_done      ()
    );

    // ----------------------------------------------------------------
    // STDP controller
    // ----------------------------------------------------------------
    // #70 exclusion: STDP is still the original single-address controller.
    // Time-multiplexed STDP and WeightRam writeback are intentionally out of
    // scope, so it observes output row 0 and its write ports remain detached.
    StdpController #(
        .DATA_WIDTH   (DATA_WIDTH),
        .ADDR_WIDTH   (WEIGHT_ADDR_W)
    ) u_stdp (
        .clk            (clk),
        .rst_n          (rst),
        .step_en        (step_en),
        .pre_spike      (spike_pending),
        .post_spike     (spike_bitmap[0]),
        .weight_addr    ('0),
        .weight_in      (weight_dout),
        .weight_we      (),
        .weight_addr_out(),
        .weight_out     ()
    );

    // ----------------------------------------------------------------
    // LED output
    // ----------------------------------------------------------------
    assign led = spike_bitmap;

endmodule

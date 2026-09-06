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
//   spikenaut-soc-sv/rtl/SocProtocolFsm.sv
//   spikenaut-soc-sv/rtl/SocStatusLeds.sv

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
    // Switches: SW15 selects LED mode; the full bus is published as aux. See docs/led-map.md.
    input  logic [15:0] sw,
    // LEDs: spike bitmap or status word. See docs/led-map.md.
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

    // 2FF synchronizer at the I/O boundary. Synchronous reset to '0 keeps
    // the default LED view in spike mode (SW15=0). Use sw_sync_1 everywhere.
    logic [15:0] sw_sync_0;
    logic [15:0] sw_sync_1;

    always_ff @(posedge clk) begin
        if (!rst) begin
            sw_sync_0 <= '0;
            sw_sync_1 <= '0;
        end else begin
            sw_sync_0 <= sw;
            sw_sync_1 <= sw_sync_0;
        end
    end

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
    logic [7:0] bridge_tx_data;
    logic       bridge_tx_send;
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
        .tx_data      (bridge_tx_data),
        .tx_send      (bridge_tx_send),
        .tx_busy      (bridge_tx_busy)
    );
    // Bridge: 8b UART stream (DATA_WIDTH=8 fixed in SiliconBridge/UARTs per gh-14 5u3.7 cleanup);
    // top-level DATA_WIDTH=16 / PARAM=16 used only for core (neuron/ram/weights). Widths reviewed.
    // The SoC-owned SocProtocolFsm below supplies the multi-byte protocol and
    // gates every tx_send with tx_busy.  SiliconBridge remains transport-only.

    // ----------------------------------------------------------------
    // Protocol stimulus -> logical tick domain (#62)
    // ----------------------------------------------------------------
    // The protocol FSM exposes a complete packed frame only after all 32
    // payload bytes are present.  Hold its one-cycle valid strobe until the
    // next logical tick, with set priority over clear for a frame that lands
    // exactly on a tick edge.
    logic [NUM_NEURONS*DATA_WIDTH-1:0] protocol_stimuli;
    logic                               protocol_stimuli_valid;
    logic                               stimuli_pending;
    logic                               stimulus_event;
    logic [$clog2(NUM_NEURONS)-1:0]     stimulus_input_index;

    always_ff @(posedge clk) begin
        if (!rst)
            stimuli_pending <= 1'b0;
        else if (protocol_stimuli_valid)
            stimuli_pending <= 1'b1;
        else if (step_en)
            stimuli_pending <= 1'b0;
    end

    // LifNeuronArray is currently a binary-event PE with one selected matrix
    // input column per logical tick.  Preserve that established core contract
    // by decoding a non-zero Q8.8 lane as an event and choosing the lowest
    // active input lane deterministically.  The complete 16-word frame stays
    // available in protocol_stimuli for a future vector-accumulation PE; it is
    // not mistaken for a raw UART-byte event.
    always_comb begin
        logic input_found;

        input_found         = 1'b0;
        stimulus_event      = 1'b0;
        stimulus_input_index = '0;
        for (int input_lane = 0; input_lane < NUM_NEURONS; input_lane++) begin
            if (!input_found &&
                (protocol_stimuli[input_lane*DATA_WIDTH +: DATA_WIDTH] != '0)) begin
                input_found          = 1'b1;
                stimulus_input_index = input_lane[$clog2(NUM_NEURONS)-1:0];
            end
        end
        stimulus_event = stimuli_pending && input_found;
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
    // bridge DATA_WIDTH remains 8b.  #62 supplies the selected event/input
    // column from its completed 16-word host frame.
    logic [NUM_NEURONS-1:0] spike_bitmap;
    logic [NUM_NEURONS*DATA_WIDTH-1:0] membrane_potentials;
    logic                              lif_tick_done;

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
        .spike_in       (stimulus_event),
        .input_index    (stimulus_input_index),
        .weight_dout    (weight_dout),
        .threshold_dout (threshold_param),
        .leak_dout      (leak_param),
        .threshold_addr (threshold_addr),
        .leak_addr      (leak_addr),
        .weight_addr    (weight_addr),
        .spike_bitmap   (spike_bitmap),
        .membrane_potentials (membrane_potentials),
        .tick_done      (lif_tick_done)
    );

    // ----------------------------------------------------------------
    // SoC application protocol (0xAA frame codec + TX readback)
    // ----------------------------------------------------------------
    // Host contract (#62): one 36-byte response per consumed 0xAA stimulus
    // frame. Arm on the step_en that consumes stimuli_pending; fire on the
    // subsequent lif_tick_done so the snapshot is that tick's post-sweep
    // membrane/spike result. Idle 1 ms ticks must not stream UART responses
    // before any host frame (or between host frames).
    // The FSM still coalesces a later armed trigger while UART is busy; a
    // 36-byte response cannot physically complete within the 1 ms tick at
    // 115200 baud.
    logic response_armed;
    logic frame_send;
    logic rx_busy;
    logic rx_abort;
    logic tx_frame_active;

    always_ff @(posedge clk) begin
        if (!rst)
            response_armed <= 1'b0;
        else if (step_en && stimuli_pending)
            response_armed <= 1'b1;
        else if (lif_tick_done)
            response_armed <= 1'b0;
    end

    assign frame_send = lif_tick_done && response_armed;

    SocProtocolFsm #(
        .NUM_NEURONS (NUM_NEURONS),
        .WORD_WIDTH  (DATA_WIDTH)
    ) u_protocol_fsm (
        .clk           (clk),
        .rst_n         (rst),
        .rx_data       (bridge_rx_data),
        .rx_valid      (bridge_rx_valid),
        .tx_data       (bridge_tx_data),
        .tx_send       (bridge_tx_send),
        .tx_busy       (bridge_tx_busy),
        .stimuli_out   (protocol_stimuli),
        .stimuli_valid (protocol_stimuli_valid),
        .potentials_in   (membrane_potentials),
        .spike_flags     (spike_bitmap),
        .aux_state       (sw_sync_1),
        .frame_send      (frame_send),
        .rx_busy         (rx_busy),
        .rx_abort        (rx_abort),
        .tx_frame_active (tx_frame_active)
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
        .pre_spike      (stimulus_event),
        .post_spike     (spike_bitmap[0]),
        .weight_addr    ('0),
        .weight_in      (weight_dout),
        .weight_we      (),
        .weight_addr_out(),
        .weight_out     ()
    );

    // ----------------------------------------------------------------
    // LED output — spike bitmap or stretched status. See docs/led-map.md.
    // ----------------------------------------------------------------
    SocStatusLeds #(
        .NUM_NEURONS (NUM_NEURONS),
        .LED_WIDTH   (16)
    ) u_status_leds (
        .clk             (clk),
        .rst_n           (rst),
        .mode_sel        (sw_sync_1[15]),
        .step_en         (step_en),
        .spike_bitmap    (spike_bitmap),
        .rx_busy         (rx_busy),
        .rx_commit       (protocol_stimuli_valid),
        .rx_abort        (rx_abort),
        .tx_frame_active (tx_frame_active),
        .stimuli_pending (stimuli_pending),
        .response_armed  (response_armed),
        .led             (led)
    );

endmodule

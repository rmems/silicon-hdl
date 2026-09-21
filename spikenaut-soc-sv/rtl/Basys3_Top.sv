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
//   spikenaut-core-sv/rtl/StdpWriteback.sv
//   spikenaut-core-sv/rtl/OutputLayer.sv
//   spikenaut-bridge-sv/rtl/UartRx.sv
//   spikenaut-bridge-sv/rtl/UartTx.sv
//   spikenaut-bridge-sv/rtl/SiliconBridge.sv
//   synapse-link-hdl/src/AerRouteTable.sv
//   spikenaut-soc-sv/rtl/SocProtocolFsm.sv
//   spikenaut-soc-sv/rtl/SocStatusLeds.sv

module spikenaut_soc_basys3_top #(
    // merged_v2 defaults (repo-root relative). Override from build_soc.tcl.
    parameter string WEIGHT_INIT_FILE = "spikenaut-core-sv/mem/merged_v2_weights.mem",
    parameter string THRESH_INIT_FILE = "spikenaut-core-sv/mem/merged_v2_thresholds.mem",
    parameter string LEAK_INIT_FILE   = "spikenaut-core-sv/mem/merged_v2_decay.mem",
    parameter string ROUTE_INIT_FILE  = "synapse-link-hdl/mem/aer_routes_identity_n16.mem",
    // GH#72: output-layer bank (16 neurons x 3 classes, 48 entries).
    parameter string OUTPUT_WEIGHT_INIT_FILE = "spikenaut-core-sv/mem/merged_v2_output_weights.mem",
    // 256-entry weight image => ADDR_WIDTH=8 (not core default 10).
    parameter int    WEIGHT_ADDR_W    = 8,
    parameter int    NEURON_ADDR_W    = 8,
    // 48-entry output-weight image => ADDR_WIDTH=6 (2**6=64 >= 48).
    parameter int    OUTPUT_WEIGHT_ADDR_W = 6
)(
    input  logic        clk,       // 100 MHz on-board oscillator
    input  logic        rst_n,     // Physically active-high button (U18/BTNC/CPU_RESET); inverted to rst (active-low) internally per gh-14 5u3.5. XDC port name kept for compatibility.
    // UART
    input  logic        uart_rx,
    output logic        uart_tx,
    // Switches: SW15 selects LED mode; SW14 enables optional STDP writeback.
    // The full bus is published as aux. See docs/led-map.md.
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
    // GH#72: output classes in the exp-025 bank ("n_outputs": 3). Fixed at 3
    // because SocStatusLeds' status_word[15:13] field is exactly 3 bits wide.
    localparam int NUM_OUTPUT_CLASSES = 3;

    // gh-14 5u3.5 (P1): inversion in RTL (XDC pin/port rst_n kept for compatibility;
    // BTNC/CPU_RESET U18 is active-high). Use 'rst' (active-low) for all submodules + local logic.
    logic rst;
    assign rst = ~rst_n;

    // 2FF synchronizer at the I/O boundary. Synchronous reset to '0 keeps
    // the default LED view in spike mode (SW15=0). Use sw_sync_1 everywhere.
    // ASYNC_REG keeps the pair packed into adjacent slices and stops synthesis
    // from replicating or retiming them, which would defeat the MTBF the two
    // stages exist to buy.  Adjacency in the source is not a constraint.
    (* ASYNC_REG = "TRUE" *) logic [15:0] sw_sync_0;
    (* ASYNC_REG = "TRUE" *) logic [15:0] sw_sync_1;

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
    // payload bytes are present. Decode its lowest active input lane, resolve
    // that source through the bounded AER table, and retain the request until
    // the next logical tick after resolution.
    logic [NUM_NEURONS*DATA_WIDTH-1:0] protocol_stimuli;
    logic                               protocol_stimuli_valid;
    logic                               stimuli_pending;
    logic                               stimulus_event;
    logic [$clog2(NUM_NEURONS)-1:0]     stimulus_input_index;
    logic                               decoded_input_found;
    logic [$clog2(NUM_NEURONS)-1:0]     decoded_input_index;
    logic                               route_request_pending;
    logic                               route_lookup_pending;
    logic                               route_resolved;
    logic                               route_drop_pending;
    logic [$clog2(NUM_NEURONS)-1:0]     route_source_addr;
    logic [$clog2(NUM_NEURONS)-1:0]     routed_input_index;
    logic                               route_in_valid;
    logic                               route_in_ready;
    logic                               route_out_valid;
    logic [$clog2(NUM_NEURONS)-1:0]     route_out_addr;
    logic                               route_busy;
    logic                               aer_route_fault;
    logic                               route_cfg_fault;
    logic                               route_fault;
    logic                               aer_cfg_we;
    logic                               consume_pending;
    logic [7:0]                         wr_sel_addr;
    logic [DATA_WIDTH-1:0]              wr_sel_data;

    // LifNeuronArray is currently a binary-event PE with one selected matrix
    // input column per logical tick.  Preserve that established core contract
    // by decoding a non-zero Q8.8 lane as an event and choosing the lowest
    // active input lane deterministically.  The complete 16-word frame stays
    // available in protocol_stimuli for a future vector-accumulation PE; it is
    // not mistaken for a raw UART-byte event.
    always_comb begin
        decoded_input_found = 1'b0;
        decoded_input_index = '0;
        for (int input_lane = 0; input_lane < NUM_NEURONS; input_lane++) begin
            if (!decoded_input_found &&
                (protocol_stimuli[input_lane*DATA_WIDTH +: DATA_WIDTH] != '0)) begin
                decoded_input_found = 1'b1;
                decoded_input_index = input_lane[$clog2(NUM_NEURONS)-1:0];
            end
        end
    end

    assign route_in_valid       = route_request_pending;
    assign consume_pending      = step_en && stimuli_pending && route_resolved;
    assign stimulus_event       = stimuli_pending && route_resolved && !route_drop_pending;
    assign stimulus_input_index = routed_input_index;
    assign route_fault          = aer_route_fault || route_cfg_fault;

    AerRouteTable #(
        .ADDR_WIDTH  ($clog2(NUM_NEURONS)),
        .ENTRY_COUNT (NUM_NEURONS),
        .MAX_HOPS    (4),
        .INIT_FILE   (ROUTE_INIT_FILE)
    ) u_aer_router (
        .clk         (clk),
        .rst_n       (rst),
        .in_valid    (route_in_valid),
        .in_ready    (route_in_ready),
        .in_addr     (route_source_addr),
        .out_valid   (route_out_valid),
        .out_addr    (route_out_addr),
        .busy        (route_busy),
        .route_fault (aer_route_fault),
        .cfg_we      (aer_cfg_we),
        .cfg_addr    (wr_sel_addr[$clog2(NUM_NEURONS)-1:0]),
        .cfg_data    (wr_sel_data)
    );

    always_ff @(posedge clk) begin
        if (!rst) begin
            stimuli_pending     <= 1'b0;
            route_request_pending <= 1'b0;
            route_lookup_pending  <= 1'b0;
            route_resolved        <= 1'b0;
            route_drop_pending    <= 1'b0;
            route_source_addr     <= '0;
            routed_input_index    <= '0;
        end else if (protocol_stimuli_valid) begin
            stimuli_pending       <= 1'b1;
            route_request_pending <= decoded_input_found;
            route_lookup_pending  <= 1'b0;
            route_resolved        <= !decoded_input_found;
            route_drop_pending    <= !decoded_input_found;
            route_source_addr     <= decoded_input_index;
            routed_input_index    <= '0;
        end else begin
            if (route_request_pending && route_in_ready) begin
                route_request_pending <= 1'b0;
                route_lookup_pending  <= 1'b1;
            end

            // Ignore a completion from a lookup that a newer accepted frame
            // superseded. The router still drains that old lookup, but only a
            // result associated with the frame we are awaiting may resolve it.
            if (route_out_valid && route_lookup_pending) begin
                route_lookup_pending <= 1'b0;
                route_resolved       <= 1'b1;
                route_drop_pending   <= 1'b0;
                routed_input_index   <= route_out_addr;
            end else if (route_lookup_pending && aer_route_fault && !route_busy) begin
                route_lookup_pending <= 1'b0;
                route_resolved       <= 1'b1;
                route_drop_pending   <= 1'b1;
            end

            if (consume_pending) begin
                stimuli_pending       <= 1'b0;
                route_request_pending <= 1'b0;
                route_lookup_pending  <= 1'b0;
                route_resolved        <= 1'b0;
                route_drop_pending    <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Neuron parameter RAM
    // ----------------------------------------------------------------
    // Per NeuronParamRam contract (gh-14 5u3.6/5u3.7): stores ONE param per addr.
    // Multiple param types (threshold/leak) require separate RAM instances.
    // E2: $readmemh from merged_v2 remains the cold-start path.  #63 drives
    // we/addr/din from SocProtocolFsm; the SoC holds a write that lands
    // during PREFETCH/SWEEP and applies it only while the PE is idle, so
    // a one-cycle host strobe cannot steal a sweep read.  STDP writeback
    // (#70) is a third WeightRam client: it runs after tick_done and the
    // host path also waits for stdp_busy.
    // The time-multiplexed LIF PE sweeps the 16 parameter entries on each
    // logical tick; its address outputs account for registered RAM read latency.
    // Timestep: LifNeuronArray / StdpController update only on step_en (1 ms).
    // See docs/timestep-contract.md (#57 / #60).
    logic [PARAM_WIDTH-1:0] threshold_param;
    logic [PARAM_WIDTH-1:0] leak_param;
    logic [NEURON_ADDR_W-1:0] threshold_addr;
    logic [NEURON_ADDR_W-1:0] leak_addr;
    logic        host_wr_en;
    logic [1:0]  host_wr_target;
    logic [7:0]  host_wr_addr;
    logic [DATA_WIDTH-1:0] host_wr_data;
    logic        weight_we;
    logic        thresh_we;
    logic        leak_we;
    logic                              lif_tick_done;
    logic        pe_ram_busy;
    logic        pe_busy;
    logic        stdp_busy;
    logic        wr_block;
    logic        wr_pending;
    logic        wr_fire;
    logic [1:0]  wr_pending_target;
    logic [7:0]  wr_pending_addr;
    logic [DATA_WIDTH-1:0] wr_pending_data;
    logic [1:0]  wr_sel_target;

    // Busy from the tick that starts a sweep through the cycle that
    // completes it.  Include step_en itself so the first registered RAM
    // sample (addr 0 while still IDLE) is not stolen.
    always_ff @(posedge clk) begin
        if (!rst)
            pe_ram_busy <= 1'b0;
        else if (step_en)
            pe_ram_busy <= 1'b1;
        else if (lif_tick_done)
            pe_ram_busy <= 1'b0;
    end

    assign pe_busy  = pe_ram_busy || step_en;
    assign wr_block = pe_busy || stdp_busy || route_busy || route_request_pending;

    always_ff @(posedge clk) begin
        if (!rst) begin
            wr_pending        <= 1'b0;
            wr_pending_target <= '0;
            wr_pending_addr   <= '0;
            wr_pending_data   <= '0;
        end else if (host_wr_en && wr_block) begin
            wr_pending        <= 1'b1;
            wr_pending_target <= host_wr_target;
            wr_pending_addr   <= host_wr_addr;
            wr_pending_data   <= host_wr_data;
        end else if (wr_fire) begin
            wr_pending <= 1'b0;
        end
    end

    always_comb begin
        wr_fire       = 1'b0;
        wr_sel_target = wr_pending_target;
        wr_sel_addr   = wr_pending_addr;
        wr_sel_data   = wr_pending_data;
        if (!wr_block) begin
            if (host_wr_en) begin
                wr_fire       = 1'b1;
                wr_sel_target = host_wr_target;
                wr_sel_addr   = host_wr_addr;
                wr_sel_data   = host_wr_data;
            end else if (wr_pending) begin
                wr_fire = 1'b1;
            end
        end
    end

    // Target encoding matches SocProtocolFsm:
    // 0=weight, 1=threshold, 2=leak, 3=AER route table.
    assign weight_we = wr_fire && (wr_sel_target == 2'd0);
    // #73 follow-up: LifNeuronArray's threshold compare is signed, so a
    // sign-bit-set threshold word -- whether from a host still using the
    // unsigned FixedPointEncode contract (docs/interface-alignment.md
    // §1.3.1) or simply malformed -- would make an idle neuron spike
    // continuously (almost any signed membrane satisfies next_mem >=
    // threshold once threshold is negative). Reject the write instead of
    // storing it; NeuronParamRam keeps its prior value. Weight is exempt:
    // a negative weight is the whole point of #73 (Dale inhibition).
    assign thresh_we = wr_fire && (wr_sel_target == 2'd1) && !wr_sel_data[DATA_WIDTH-1];
    // Same guard, same reason, for leak: a sign-bit-set leak makes the
    // symmetric-decay math in LifNeuronArray ADD to the membrane every idle
    // tick instead of draining it (0 - (-leak) = +leak), climbing to a
    // positive threshold with no input at all. Only weight may be negative.
    assign leak_we   = wr_fire && (wr_sel_target == 2'd2) && !wr_sel_data[DATA_WIDTH-1];
    assign aer_cfg_we = wr_fire && (wr_sel_target == 2'd3) && !(|wr_sel_addr[7:4]);
    assign route_cfg_fault =
        wr_fire && (wr_sel_target == 2'd3) && (|wr_sel_addr[7:4]);

    NeuronParamRam #(
        .ADDR_WIDTH  (NEURON_ADDR_W),
        .PARAM_WIDTH (PARAM_WIDTH),
        .INIT_FILE   (THRESH_INIT_FILE)
    ) u_npram_threshold (
        .clk  (clk),
        .rst_n (rst),
        .we   (thresh_we),
        .addr (thresh_we ? wr_sel_addr[NEURON_ADDR_W-1:0] : threshold_addr),
        .din  (wr_sel_data),
        .dout (threshold_param)
    );

    NeuronParamRam #(
        .ADDR_WIDTH  (NEURON_ADDR_W),
        .PARAM_WIDTH (PARAM_WIDTH),
        .INIT_FILE   (LEAK_INIT_FILE)
    ) u_npram_leak (
        .clk  (clk),
        .rst_n (rst),
        .we   (leak_we),
        .addr (leak_we ? wr_sel_addr[NEURON_ADDR_W-1:0] : leak_addr),
        .din  (wr_sel_data),
        .dout (leak_param)
    );

    // ----------------------------------------------------------------
    // Weight RAM
    // ----------------------------------------------------------------
    logic [DATA_WIDTH-1:0] weight_dout;
    logic [WEIGHT_ADDR_W-1:0] weight_addr;
    logic        stdp_we;
    logic [WEIGHT_ADDR_W-1:0] stdp_addr;
    logic [DATA_WIDTH-1:0] stdp_din;
    logic        wram_we;
    logic [WEIGHT_ADDR_W-1:0] wram_addr;
    logic [DATA_WIDTH-1:0] wram_din;
    logic        learn_en;

    assign learn_en = sw_sync_1[14];

    always_comb begin
        wram_we   = 1'b0;
        wram_addr = weight_addr;
        wram_din  = wr_sel_data;
        if (pe_busy) begin
            wram_addr = weight_addr;
        end else if (stdp_busy) begin
            wram_we   = stdp_we;
            wram_addr = stdp_addr;
            wram_din  = stdp_din;
        end else if (weight_we) begin
            wram_we   = 1'b1;
            wram_addr = wr_sel_addr[WEIGHT_ADDR_W-1:0];
            wram_din  = wr_sel_data;
        end
    end

    WeightRam #(
        .ADDR_WIDTH (WEIGHT_ADDR_W),
        .DATA_WIDTH (DATA_WIDTH),
        .INIT_FILE  (WEIGHT_INIT_FILE)
    ) u_wram (
        .clk  (clk),
        .rst_n (rst),
        .we   (wram_we),
        .addr (wram_addr),
        .din  (wram_din),
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
    // Output layer (#72): 3-class argmax readout over that tick's
    // spike_bitmap, surfaced on LEDs only (status_word[15:13]) -- no UART
    // frame change (see docs/interface-alignment.md / #64). Triggered on
    // lif_tick_done, not step_en: spike_bitmap only updates on tick_done,
    // so triggering on step_en would score the *previous* tick's spikes.
    // No runtime write path for this bank -- we/din tied off, matching the
    // precedent of u_stdp's intentionally-dangling write ports below.
    // ----------------------------------------------------------------
    logic [DATA_WIDTH-1:0] output_weight_dout;
    logic [OUTPUT_WEIGHT_ADDR_W-1:0] output_weight_addr;
    logic [NUM_OUTPUT_CLASSES-1:0] output_class;
    logic output_class_valid;

    WeightRam #(
        .ADDR_WIDTH (OUTPUT_WEIGHT_ADDR_W),
        .DATA_WIDTH (DATA_WIDTH),
        .INIT_FILE  (OUTPUT_WEIGHT_INIT_FILE)
    ) u_output_wram (
        .clk  (clk),
        .rst_n (rst),
        .we   (1'b0),
        .addr (output_weight_addr),
        .din  ('0),
        .dout (output_weight_dout)
    );

    OutputLayer #(
        .DATA_WIDTH        (DATA_WIDTH),
        .NUM_NEURONS       (NUM_NEURONS),
        .NUM_CLASSES       (NUM_OUTPUT_CLASSES),
        .WEIGHT_ADDR_WIDTH (OUTPUT_WEIGHT_ADDR_W)
    ) u_output_layer (
        .clk          (clk),
        .rst_n        (rst),
        .spike_valid  (lif_tick_done),
        .spike_bitmap (spike_bitmap),
        .weight_dout  (output_weight_dout),
        .weight_addr  (output_weight_addr),
        .result       (output_class),
        // Gates the LED latch: result is a held one-hot that never returns
        // to '0, so SocStatusLeds must replace the whole vector on this
        // strobe rather than OR-ing bits into a stretched hold.
        .done         (output_class_valid)
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
        else if (consume_pending)
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
        .wr_en           (host_wr_en),
        .wr_target       (host_wr_target),
        .wr_addr         (host_wr_addr),
        .wr_data         (host_wr_data),
        .rx_busy         (rx_busy),
        .rx_abort        (rx_abort),
        .tx_frame_active (tx_frame_active)
    );

    // ----------------------------------------------------------------
    // STDP writeback (#70)
    // ----------------------------------------------------------------
    StdpWriteback #(
        .DATA_WIDTH  (DATA_WIDTH),
        .NUM_NEURONS (NUM_NEURONS),
        .ADDR_WIDTH  (WEIGHT_ADDR_W)
    ) u_stdp (
        .clk         (clk),
        .rst_n       (rst),
        .learn_en    (learn_en),
        .step_en     (step_en),
        .tick_done   (lif_tick_done),
        .pre_spike   (stimulus_event),
        .post_spikes (spike_bitmap),
        .input_index (stimulus_input_index),
        .weight_dout (weight_dout),
        .busy        (stdp_busy),
        .weight_we   (stdp_we),
        .weight_addr (stdp_addr),
        .weight_din  (stdp_din)
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
        .route_fault     (route_fault),
        .tx_frame_active (tx_frame_active),
        .stimuli_pending (stimuli_pending),
        .response_armed  (response_armed),
        .output_class       (output_class),
        .output_class_valid (output_class_valid),
        .led                (led)
    );

endmodule

// SPDX-License-Identifier: MIT OR Apache-2.0
// SocStatusLeds.sv
// Canonical source: spikenaut-soc-sv/rtl
//
// Combinational LED mux plus a shared ~64 ms stretcher for the Basys 3
// status view.  SW15 (already synchronized at the SoC I/O boundary) selects
// spike-bitmap passthrough versus the status word in docs/led-map.md.
//
// led is combinational: spike mode is a straight rename of spike_bitmap, so
// a testbench force plus #1 delay still observes the bus.

module SocStatusLeds #(
    parameter int NUM_NEURONS = 16,
    parameter int LED_WIDTH   = 16,
    parameter int STRETCH_DIV = 6_400_000
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    mode_sel,
    input  logic                    step_en,
    input  logic [NUM_NEURONS-1:0]  spike_bitmap,
    input  logic                    rx_busy,
    input  logic                    rx_commit,
    input  logic                    rx_abort,
    input  logic                    tx_frame_active,
    input  logic                    stimuli_pending,
    input  logic                    response_armed,
    output logic [LED_WIDTH-1:0]    led
);

    localparam int COUNT_WIDTH = $clog2(NUM_NEURONS + 1);

    generate
        if (NUM_NEURONS > LED_WIDTH)
            $error("SocStatusLeds: NUM_NEURONS (%0d) must not exceed LED_WIDTH (%0d)",
                   NUM_NEURONS, LED_WIDTH);
        if ((8 + COUNT_WIDTH) > LED_WIDTH)
            $error("SocStatusLeds: status field 8+COUNT_WIDTH (%0d) must not exceed LED_WIDTH (%0d)",
                   8 + COUNT_WIDTH, LED_WIDTH);
    endgenerate

    logic [$clog2(STRETCH_DIV)-1:0] stretch_cnt;
    logic                           stretch_tick;
    logic                           rx_busy_held;
    logic                           rx_commit_held;
    logic                           tx_frame_held;
    logic                           stimuli_pending_held;
    logic                           response_armed_held;
    logic [NUM_NEURONS-1:0]         spike_hold;
    logic                           abort_sticky;
    logic [8:0]                     tick_cnt;
    logic                           heartbeat;
    logic [LED_WIDTH-1:0]           status_word;

    assign heartbeat = tick_cnt[8];

    // Shared stretcher.  Synchronous reset matches SocProtocolFsm /
    // Basys3_Top (`@(posedge clk) if (!rst_n)`), not the async UartRx style.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stretch_cnt  <= '0;
            stretch_tick <= 1'b0;
        end else if (stretch_cnt == STRETCH_DIV - 1) begin
            stretch_cnt  <= '0;
            stretch_tick <= 1'b1;
        end else begin
            stretch_cnt  <= stretch_cnt + 1'b1;
            stretch_tick <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_busy_held         <= 1'b0;
            rx_commit_held       <= 1'b0;
            tx_frame_held        <= 1'b0;
            stimuli_pending_held <= 1'b0;
            response_armed_held  <= 1'b0;
            spike_hold           <= '0;
            abort_sticky         <= 1'b0;
            tick_cnt             <= '0;
        end else begin
            if (rx_busy)
                rx_busy_held <= 1'b1;
            else if (stretch_tick)
                rx_busy_held <= 1'b0;

            if (rx_commit)
                rx_commit_held <= 1'b1;
            else if (stretch_tick)
                rx_commit_held <= 1'b0;

            if (tx_frame_active)
                tx_frame_held <= 1'b1;
            else if (stretch_tick)
                tx_frame_held <= 1'b0;

            if (stimuli_pending)
                stimuli_pending_held <= 1'b1;
            else if (stretch_tick)
                stimuli_pending_held <= 1'b0;

            if (response_armed)
                response_armed_held <= 1'b1;
            else if (stretch_tick)
                response_armed_held <= 1'b0;

            for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
                if (spike_bitmap[neuron])
                    spike_hold[neuron] <= 1'b1;
                else if (stretch_tick)
                    spike_hold[neuron] <= 1'b0;
            end

            if (rx_commit)
                abort_sticky <= 1'b0;
            else if (rx_abort)
                abort_sticky <= 1'b1;

            if (step_en)
                tick_cnt <= tick_cnt + 1'b1;
        end
    end

    always_comb begin
        status_word        = '0;
        status_word[0]     = heartbeat;
        status_word[1]     = rx_busy_held;
        status_word[2]     = rx_commit_held;
        status_word[3]     = abort_sticky;
        status_word[4]     = tx_frame_held;
        status_word[5]     = stimuli_pending_held;
        status_word[6]     = response_armed_held;
        status_word[7]     = |spike_hold;
        status_word[12:8]  = COUNT_WIDTH'($countones(spike_hold));
        status_word[15:13] = '0;
    end

    assign led = mode_sel ? status_word : LED_WIDTH'(spike_bitmap);

endmodule

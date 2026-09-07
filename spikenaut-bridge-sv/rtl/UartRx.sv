// SPDX-License-Identifier: MIT OR Apache-2.0
// UartRx.sv
// Canonical source: spikenaut-bridge-sv/rtl
// UART receiver

module UartRx #(
    parameter int CLK_FREQ  = 100_000_000,
    parameter int BAUD_RATE = 115_200,
    parameter int DATA_WIDTH = 8   // gh-14 5u3.7: propagated from SiliconBridge for consistency (UART framing uses this as data bits; default 8 per serial protocol).
)(
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  rx,
    output logic [DATA_WIDTH-1:0] data,
    output logic                  valid
);

    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    typedef enum logic [1:0] {
        IDLE  = 2'b00,
        START = 2'b01,
        DATA  = 2'b10,
        STOP  = 2'b11
    } state_t;

    state_t              state;
    logic [$clog2(CLKS_PER_BIT)-1:0] clk_cnt;
    logic [$clog2(DATA_WIDTH)-1:0] bit_idx;
    logic [DATA_WIDTH-1:0] shift_reg;

    // 2FF synchronizer for async serial rx (from external UART line).
    // gh-14 / Greptile comment 3035928747 (P1 Critical): prevents metastability
    // when sampling into FPGA clk domain. Per beads silicon-hdl-5u3.1.
    //
    // ASYNC_REG (#84) names the pair as a synchronizer so Vivado packs it into
    // adjacent slices and will not replicate or retime the flops. Without it
    // the protection is purely positional -- being written next to each other
    // is not a constraint, and either transform spends the MTBF the second
    // stage exists to buy. Matches the sw pair in spikenaut_soc_basys3_top (#83).
    (* ASYNC_REG = "TRUE" *) logic rx_sync_0;
    (* ASYNC_REG = "TRUE" *) logic rx_sync_1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            clk_cnt  <= '0;
            bit_idx  <= '0;
            shift_reg <= '0;
            data     <= '0;
            valid    <= 1'b0;
            rx_sync_0 <= 1'b1;
            rx_sync_1 <= 1'b1;
        end else begin
            // Sync the async rx input (use rx_sync_1 for all logic below).
            rx_sync_0 <= rx;
            rx_sync_1 <= rx_sync_0;

            valid <= 1'b0;
            case (state)
                IDLE: begin
                    if (!rx_sync_1) begin
                        state   <= START;
                        clk_cnt <= '0;
                    end
                end
                START: begin
                    if (clk_cnt == (CLKS_PER_BIT / 2) - 1) begin
                        state   <= DATA;
                        clk_cnt <= '0;
                        bit_idx <= '0;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
                DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt            <= '0;
                        shift_reg[bit_idx] <= rx_sync_1;
                        if (bit_idx == DATA_WIDTH-1) begin
                            state <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
                STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        data  <= shift_reg;
                        valid <= 1'b1;
                        state <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule

// SPDX-License-Identifier: MIT OR Apache-2.0
// AerRouteTable.sv
// Bounded single-event lookup engine for the aer-route-v1 table format.

module AerRouteTable #(
    parameter int    ADDR_WIDTH  = 4,
    parameter int    ENTRY_COUNT = 16,
    parameter int    MAX_HOPS    = 4,
    parameter string INIT_FILE   = ""
)(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  in_valid,
    output logic                  in_ready,
    input  logic [ADDR_WIDTH-1:0] in_addr,

    output logic                  out_valid,
    output logic [ADDR_WIDTH-1:0] out_addr,
    output logic                  busy,
    output logic                  route_fault,

    input  logic                  cfg_we,
    input  logic [ADDR_WIDTH-1:0] cfg_addr,
    input  logic [15:0]           cfg_data
);
    localparam int HOP_COUNT_WIDTH = (MAX_HOPS > 1) ? $clog2(MAX_HOPS) : 1;

    logic [15:0] route_mem [0:ENTRY_COUNT-1];
    logic [ADDR_WIDTH-1:0] current_addr;
    logic [HOP_COUNT_WIDTH-1:0] hop_count;
    logic [15:0] current_entry;
    logic current_addr_valid;
    logic current_reserved_clear;
    logic cfg_addr_valid;
    logic cfg_reserved_clear;

    integer init_index;
    initial begin
        for (init_index = 0; init_index < ENTRY_COUNT; init_index = init_index + 1)
            route_mem[init_index] = {
                1'b1,
                1'b1,
                {(14-ADDR_WIDTH){1'b0}},
                ADDR_WIDTH'(init_index)
            };
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, route_mem);
    end

    generate
        if ((ADDR_WIDTH < 1) || (ADDR_WIDTH > 14)) begin : gen_bad_addr_width
            $error("AerRouteTable: ADDR_WIDTH (%0d) must be in [1, 14]", ADDR_WIDTH);
        end
        if ((ENTRY_COUNT < 1) || (ENTRY_COUNT > (1 << ADDR_WIDTH))) begin : gen_bad_entry_count
            $error("AerRouteTable: ENTRY_COUNT (%0d) does not fit ADDR_WIDTH (%0d)",
                   ENTRY_COUNT, ADDR_WIDTH);
        end
        if (MAX_HOPS < 1) begin : gen_bad_max_hops
            $error("AerRouteTable: MAX_HOPS (%0d) must be at least one", MAX_HOPS);
        end
    endgenerate

    always_comb begin
        current_addr_valid = (current_addr < ENTRY_COUNT);
        cfg_addr_valid     = (cfg_addr < ENTRY_COUNT);
        cfg_reserved_clear = !(|cfg_data[13:ADDR_WIDTH]);
        current_entry      = '0;
        if (current_addr_valid)
            current_entry = route_mem[current_addr];
        current_reserved_clear = !(|current_entry[13:ADDR_WIDTH]);
    end

    // Configuration owns the idle cycle in which cfg_we is asserted, so a
    // source cannot be acknowledged while the table is being changed.
    assign in_ready = !busy && !cfg_we;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_addr <= '0;
            hop_count    <= '0;
            out_valid    <= 1'b0;
            out_addr     <= '0;
            busy         <= 1'b0;
            route_fault  <= 1'b0;
        end else begin
            out_valid   <= 1'b0;
            route_fault <= 1'b0;

            if (busy) begin
                // Writes are rejected while a lookup is in flight. The route
                // itself continues so a host collision cannot strand it.
                if (cfg_we)
                    route_fault <= 1'b1;

                if (!current_addr_valid || !current_entry[15] ||
                    !current_reserved_clear) begin
                    busy        <= 1'b0;
                    route_fault <= 1'b1;
                end else if (current_entry[14]) begin
                    out_addr  <= current_entry[ADDR_WIDTH-1:0];
                    out_valid <= 1'b1;
                    busy      <= 1'b0;
                end else if (hop_count == HOP_COUNT_WIDTH'(MAX_HOPS - 1)) begin
                    busy        <= 1'b0;
                    route_fault <= 1'b1;
                end else begin
                    current_addr <= current_entry[ADDR_WIDTH-1:0];
                    hop_count    <= hop_count + 1'b1;
                end
            end else if (cfg_we) begin
                if (cfg_addr_valid && cfg_reserved_clear)
                    route_mem[cfg_addr] <= cfg_data;
                else
                    route_fault <= 1'b1;
            end else if (in_valid) begin
                current_addr <= in_addr;
                hop_count    <= '0;
                busy         <= 1'b1;
            end
        end
    end
endmodule

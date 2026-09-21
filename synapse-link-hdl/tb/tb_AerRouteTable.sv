// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_AerRouteTable.sv
// Behavioral contract for the bounded aer-route-v1 lookup table.

`timescale 1ns/1ps

module tb_AerRouteTable #(
    parameter string NONIDENTITY_INIT_FILE =
        "synapse-link-hdl/mem/aer_routes_test_multihop_n16.mem"
);
    localparam int ADDR_WIDTH = 4;
    localparam int MAX_HOPS   = 4;

    logic                  clk;
    logic                  rst_n;
    logic                  in_valid;
    logic                  in_ready;
    logic [ADDR_WIDTH-1:0] in_addr;
    logic                  out_valid;
    logic [ADDR_WIDTH-1:0] out_addr;
    logic                  busy;
    logic                  route_fault;
    logic                  cfg_we;
    logic [ADDR_WIDTH-1:0] cfg_addr;
    logic [15:0]           cfg_data;
    logic                  init_in_valid;
    logic                  init_in_ready;
    logic [ADDR_WIDTH-1:0] init_in_addr;
    logic                  init_out_valid;
    logic [ADDR_WIDTH-1:0] init_out_addr;
    logic                  init_busy;
    logic                  init_route_fault;
    logic                  wide_in_valid;
    logic                  wide_in_ready;
    logic [13:0]           wide_in_addr;
    logic                  wide_out_valid;
    logic [13:0]           wide_out_addr;
    logic                  wide_busy;
    logic                  wide_route_fault;
    logic                  wide_cfg_we;
    logic [13:0]           wide_cfg_addr;
    logic [15:0]           wide_cfg_data;

    int errors = 0;

    always #5 clk = ~clk;

    AerRouteTable #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .ENTRY_COUNT(16),
        .MAX_HOPS   (MAX_HOPS)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (in_valid),
        .in_ready   (in_ready),
        .in_addr    (in_addr),
        .out_valid  (out_valid),
        .out_addr   (out_addr),
        .busy       (busy),
        .route_fault(route_fault),
        .cfg_we     (cfg_we),
        .cfg_addr   (cfg_addr),
        .cfg_data   (cfg_data)
    );

    // Boundary instance: with ADDR_WIDTH=14 there are no reserved bits below
    // terminal. This catches accidental [13:14] checks that reject bit 14.
    AerRouteTable #(
        .ADDR_WIDTH (14),
        .ENTRY_COUNT(2),
        .MAX_HOPS   (MAX_HOPS)
    ) wide_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (wide_in_valid),
        .in_ready   (wide_in_ready),
        .in_addr    (wide_in_addr),
        .out_valid  (wide_out_valid),
        .out_addr   (wide_out_addr),
        .busy       (wide_busy),
        .route_fault(wide_route_fault),
        .cfg_we     (wide_cfg_we),
        .cfg_addr   (wide_cfg_addr),
        .cfg_data   (wide_cfg_data)
    );

    AerRouteTable #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .ENTRY_COUNT(16),
        .MAX_HOPS   (MAX_HOPS),
        .INIT_FILE  (NONIDENTITY_INIT_FILE)
    ) init_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (init_in_valid),
        .in_ready   (init_in_ready),
        .in_addr    (init_in_addr),
        .out_valid  (init_out_valid),
        .out_addr   (init_out_addr),
        .busy       (init_busy),
        .route_fault(init_route_fault),
        .cfg_we     (1'b0),
        .cfg_addr   ('0),
        .cfg_data   ('0)
    );

    function automatic logic [15:0] route_entry(
        input logic valid,
        input logic terminal,
        input logic [ADDR_WIDTH-1:0] next_addr
    );
        route_entry = {valid, terminal, 10'b0, next_addr};
    endfunction

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $display("FAIL: %s", message);
            errors++;
        end
    endtask

    task automatic write_entry(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [15:0] data
    );
        @(negedge clk);
        cfg_addr = addr;
        cfg_data = data;
        cfg_we   = 1'b1;
        @(negedge clk);
        cfg_we   = 1'b0;
    endtask

    task automatic expect_route(
        input logic [ADDR_WIDTH-1:0] source,
        input logic expect_success,
        input logic [ADDR_WIDTH-1:0] expected_addr,
        input int expected_lookups,
        input string label
    );
        int lookups;
        logic saw_output;
        logic saw_fault;

        while (!in_ready)
            @(negedge clk);
        in_addr  = source;
        in_valid = 1'b1;
        @(negedge clk);
        in_valid = 1'b0;

        lookups   = 0;
        saw_output = 1'b0;
        saw_fault  = 1'b0;
        while (busy || (!out_valid && !route_fault)) begin
            @(negedge clk);
            if (busy || out_valid || route_fault)
                lookups++;
            if (out_valid)
                saw_output = 1'b1;
            if (route_fault)
                saw_fault = 1'b1;
            if (lookups > MAX_HOPS + 2) begin
                check(1'b0, $sformatf("%s did not terminate", label));
                break;
            end
        end

        if (out_valid)
            saw_output = 1'b1;
        if (route_fault)
            saw_fault = 1'b1;

        check(saw_output == expect_success,
              $sformatf("%s output-valid mismatch", label));
        check(saw_fault == !expect_success,
              $sformatf("%s route-fault mismatch", label));
        if (expect_success)
            check(out_addr == expected_addr,
                  $sformatf("%s expected address %0d, got %0d",
                            label, expected_addr, out_addr));
        check(lookups == expected_lookups,
              $sformatf("%s expected %0d lookups, got %0d",
                        label, expected_lookups, lookups));
        @(negedge clk);
        check(!out_valid && !route_fault,
              $sformatf("%s completion pulses must last one cycle", label));
    endtask

    initial begin
        clk      = 1'b0;
        rst_n    = 1'b0;
        in_valid = 1'b0;
        in_addr  = '0;
        cfg_we   = 1'b0;
        cfg_addr = '0;
        cfg_data = '0;
        init_in_valid = 1'b0;
        init_in_addr  = '0;
        wide_in_valid = 1'b0;
        wide_in_addr  = '0;
        wide_cfg_we   = 1'b0;
        wide_cfg_addr = '0;
        wide_cfg_data = '0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        check(in_ready && !busy && !out_valid && !route_fault,
              "reset must leave the router idle and ready");

        // At the maximum supported address width, bit 14 remains terminal;
        // there is no reserved field, so this write and route must succeed.
        wide_cfg_addr = 14'd0;
        wide_cfg_data = {1'b1, 1'b1, 14'd1};
        wide_cfg_we   = 1'b1;
        @(negedge clk);
        wide_cfg_we   = 1'b0;
        check(!wide_route_fault,
              "ADDR_WIDTH=14 terminal write must not be rejected as reserved");
        wide_in_addr  = 14'd0;
        wide_in_valid = 1'b1;
        @(negedge clk);
        wide_in_valid = 1'b0;
        while (!wide_out_valid && !wide_route_fault)
            @(negedge clk);
        check(wide_out_valid && !wide_route_fault && wide_out_addr == 14'd1,
              "ADDR_WIDTH=14 terminal entry must route successfully");
        @(negedge clk);

        // The generated fixture differs from the built-in identity fallback,
        // so 0 -> 2 proves $readmemh actually populated this second instance.
        check(init_in_ready, "INIT_FILE router must be ready after reset");
        init_in_addr  = 4'd0;
        init_in_valid = 1'b1;
        @(negedge clk);
        init_in_valid = 1'b0;
        while (!init_out_valid && !init_route_fault)
            @(negedge clk);
        check(init_out_valid && !init_route_fault && init_out_addr == 4'd2,
              "nonidentity INIT_FILE must route source 0 through 1 to 2");
        @(negedge clk);

        // A missing INIT_FILE must produce the backwards-compatible identity
        // table. A wrong default mapping makes every existing SoC stimulus
        // select the wrong weight column.
        for (int address = 0; address < 16; address++)
            expect_route(ADDR_WIDTH'(address), 1'b1, ADDR_WIDTH'(address), 1,
                         $sformatf("identity route %0d", address));

        // Two-, three-, and four-lookup chains catch off-by-one hop budgets.
        write_entry(4'd0, route_entry(1'b1, 1'b0, 4'd1));
        write_entry(4'd1, route_entry(1'b1, 1'b1, 4'd2));
        expect_route(4'd0, 1'b1, 4'd2, 2, "two-lookup route");

        write_entry(4'd3, route_entry(1'b1, 1'b0, 4'd4));
        write_entry(4'd4, route_entry(1'b1, 1'b0, 4'd5));
        write_entry(4'd5, route_entry(1'b1, 1'b1, 4'd6));
        expect_route(4'd3, 1'b1, 4'd6, 3, "three-lookup route");

        write_entry(4'd8,  route_entry(1'b1, 1'b0, 4'd9));
        write_entry(4'd9,  route_entry(1'b1, 1'b0, 4'd10));
        write_entry(4'd10, route_entry(1'b1, 1'b0, 4'd11));
        write_entry(4'd11, route_entry(1'b1, 1'b1, 4'd12));
        expect_route(4'd8, 1'b1, 4'd12, 4, "four-lookup route");

        // Invalid entries and cycles must terminate as drops rather than
        // hanging the ready/valid interface.
        write_entry(4'd13, route_entry(1'b0, 1'b0, 4'd0));
        expect_route(4'd13, 1'b0, '0, 1, "invalid-entry drop");

        write_entry(4'd14, route_entry(1'b1, 1'b0, 4'd14));
        expect_route(4'd14, 1'b0, '0, MAX_HOPS, "self-cycle hop limit");

        write_entry(4'd15, route_entry(1'b1, 1'b0, 4'd12));
        write_entry(4'd12, route_entry(1'b1, 1'b0, 4'd15));
        expect_route(4'd15, 1'b0, '0, MAX_HOPS,
                     "multi-entry cycle hop limit");

        // Reserved bits are fail-closed. The rejected write must not corrupt
        // the pre-existing identity entry.
        write_entry(4'd7, 16'h4017);
        check(route_fault, "reserved-bit configuration must pulse route_fault");
        @(negedge clk);
        check(!route_fault, "configuration route_fault must be one cycle");
        expect_route(4'd7, 1'b1, 4'd7, 1,
                     "malformed write leaves prior entry intact");

        // A configuration collision is rejected while the in-flight route is
        // allowed to finish. in_ready also stays low until completion.
        write_entry(4'd0, route_entry(1'b1, 1'b0, 4'd1));
        write_entry(4'd1, route_entry(1'b1, 1'b0, 4'd2));
        write_entry(4'd2, route_entry(1'b1, 1'b1, 4'd3));
        while (!in_ready) @(negedge clk);
        in_addr  = 4'd0;
        in_valid = 1'b1;
        @(negedge clk);
        in_valid = 1'b0;
        check(busy && !in_ready, "active route must deassert in_ready");
        cfg_addr = 4'd1;
        cfg_data = route_entry(1'b1, 1'b1, 4'd9);
        cfg_we   = 1'b1;
        @(negedge clk);
        cfg_we   = 1'b0;
        check(route_fault, "configuration collision must pulse route_fault");
        while (!out_valid)
            @(negedge clk);
        check(out_addr == 4'd3,
              "rejected configuration collision must not alter the active route");
        @(negedge clk);
        check(in_ready && !busy && !out_valid && !route_fault,
              "router must recover after collision and successful completion");

        // Keep valid asserted with a new address as the first terminal route
        // completes. The second request is accepted only when ready returns;
        // neither the busy cycle nor the completion pulse may overwrite it.
        write_entry(4'd6, route_entry(1'b1, 1'b1, 4'd6));
        write_entry(4'd7, route_entry(1'b1, 1'b1, 4'd7));
        while (!in_ready) @(negedge clk);
        in_addr  = 4'd6;
        in_valid = 1'b1;
        @(negedge clk);
        check(busy && !in_ready,
              "back-to-back: first accepted request must make router busy");
        in_addr = 4'd7;
        @(negedge clk);
        check(out_valid && out_addr == 4'd6,
              "back-to-back: first request must produce exactly its result");
        @(negedge clk);
        in_valid = 1'b0;
        check(busy && !out_valid,
              "back-to-back: held second request must be accepted when ready");
        @(negedge clk);
        check(out_valid && out_addr == 4'd7 && !route_fault,
              "back-to-back: second accepted request must produce one result");
        @(negedge clk);
        check(in_ready && !busy && !out_valid && !route_fault,
              "back-to-back: completion pulses must clear after one cycle");

        if (errors == 0) begin
            $display("TB_AER_ROUTE_TABLE: ALL TESTS PASSED");
            $finish;
        end else begin
            $fatal(1, "TB_AER_ROUTE_TABLE: %0d TEST(S) FAILED", errors);
        end
    end
endmodule

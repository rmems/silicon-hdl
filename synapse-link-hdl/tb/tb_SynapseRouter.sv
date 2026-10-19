// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_SynapseRouter.sv
// Self-checking contract for SynapseRouter, alone and composed behind the
// canonical AerRouteTable.
//
// SynapseRouter is the identity-only standalone demo router (see
// docs/aer-routing-contract.md): a one-cycle registered passthrough with an
// asynchronous active-low reset and no backpressure. It does not instantiate
// AerRouteTable. Routing (single-hop, multi-hop, unrouted, backpressure) is
// therefore exercised through a TB-only composition
//     AerRouteTable --(out_valid/out_addr)--> SynapseRouter
// so the routed spike is checked at the SynapseRouter output, against an
// independent TB reference model of the aer-route-v1 table.
//
// Sections:
//   A. Standalone NEURON_ADDR_WIDTH=8 router: exact 1-cycle latency, every
//      address, back-to-back events every cycle, valid gaps, 3-stage cascade.
//   B. Asynchronous reset: outputs clear without a clock edge and stay clear
//      while reset is held.
//   C. Composition: identity single-hop, 2/3/4-lookup multi-hop, invalid
//      entry and cyclic (hop-budget) unrouted drops, committed INIT_FILE
//      fixture, end-to-end latency = lookups + 1 cycles.
//   D. Composition stream: held-valid back-to-back requests under in_ready
//      backpressure over randomized (seeded, deterministic) tables.
//
// All stimulus is driven on negedge clk (repo convention); the scoreboard
// samples on posedge before the DUT non-blocking updates land.

`timescale 1ns/1ps

module tb_SynapseRouter #(
    parameter string MULTIHOP_INIT_FILE =
        "synapse-link-hdl/mem/aer_routes_test_multihop_n16.mem",
    parameter int unsigned SEED = 32'h5EED_0104
);
    localparam int W8       = 8;   // standalone demo width (synapse_demo_basys3_top)
    localparam int AW       = 4;   // aer-route-v1 address width
    localparam int ENTRIES  = 16;
    localparam int MAX_HOPS = 4;
    localparam int STREAM_EVENTS = 400;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    int errors = 0;

    task automatic check(input logic cond, input string msg);
        if (!cond) begin
            $display("FAIL @%0t: %s", $time, msg);
            errors++;
        end
    endtask

    // xorshift32: deterministic across simulators, independent of $urandom.
    int unsigned rng = SEED;
    function automatic int unsigned next_rand();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    // =====================================================================
    // A/B. Standalone 8-bit router + 3-stage cascade (separate async reset)
    // =====================================================================
    logic          sr_rst_n;
    logic [W8-1:0] sr_src_addr;
    logic          sr_src_valid;
    logic [W8-1:0] sr_dst_addr;
    logic          sr_dst_valid;
    logic [W8-1:0] c1_addr, c2_addr, c3_addr;
    logic          c1_valid, c2_valid, c3_valid;

    SynapseRouter #(.NEURON_ADDR_WIDTH(W8)) u_sr (
        .clk(clk), .rst_n(sr_rst_n),
        .src_addr(sr_src_addr), .src_valid(sr_src_valid),
        .dst_addr(sr_dst_addr), .dst_valid(sr_dst_valid)
    );

    SynapseRouter #(.NEURON_ADDR_WIDTH(W8)) u_c1 (
        .clk(clk), .rst_n(sr_rst_n),
        .src_addr(sr_src_addr), .src_valid(sr_src_valid),
        .dst_addr(c1_addr), .dst_valid(c1_valid)
    );
    SynapseRouter #(.NEURON_ADDR_WIDTH(W8)) u_c2 (
        .clk(clk), .rst_n(sr_rst_n),
        .src_addr(c1_addr), .src_valid(c1_valid),
        .dst_addr(c2_addr), .dst_valid(c2_valid)
    );
    SynapseRouter #(.NEURON_ADDR_WIDTH(W8)) u_c3 (
        .clk(clk), .rst_n(sr_rst_n),
        .src_addr(c2_addr), .src_valid(c2_valid),
        .dst_addr(c3_addr), .dst_valid(c3_valid)
    );

    // Reference pipelines: history of driven (valid, addr) at each posedge.
    logic          hist_v [0:3];
    logic [W8-1:0] hist_a [0:3];
    int            sr_checked_events = 0;
    int            cascade_checked_events = 0;
    logic          sr_monitor_en = 1'b0;

    always @(posedge clk) begin
        if (sr_monitor_en && sr_rst_n) begin
            // Pre-edge outputs reflect the input sampled 1 (or 3) edges ago.
            check(sr_dst_valid === hist_v[0],
                  $sformatf("SR: dst_valid=%b expected %b", sr_dst_valid, hist_v[0]));
            if (hist_v[0]) begin
                check(sr_dst_addr === hist_a[0],
                      $sformatf("SR: dst_addr=0x%02h expected 0x%02h",
                                sr_dst_addr, hist_a[0]));
                sr_checked_events++;
            end
            check(c3_valid === hist_v[2],
                  $sformatf("cascade: c3_valid=%b expected %b", c3_valid, hist_v[2]));
            if (hist_v[2]) begin
                check(c3_addr === hist_a[2],
                      $sformatf("cascade: c3_addr=0x%02h expected 0x%02h",
                                c3_addr, hist_a[2]));
                cascade_checked_events++;
            end
        end
        hist_v[2] <= hist_v[1]; hist_a[2] <= hist_a[1];
        hist_v[1] <= hist_v[0]; hist_a[1] <= hist_a[0];
        hist_v[0] <= sr_rst_n ? sr_src_valid : 1'b0;
        hist_a[0] <= sr_src_addr;
    end

    // =====================================================================
    // C/D. AerRouteTable -> SynapseRouter composition
    // =====================================================================
    logic          rst_n;
    logic          rt_in_valid;
    logic          rt_in_ready;
    logic [AW-1:0] rt_in_addr;
    logic          rt_out_valid;
    logic [AW-1:0] rt_out_addr;
    logic          rt_busy;
    logic          rt_route_fault;
    logic          rt_cfg_we;
    logic [AW-1:0] rt_cfg_addr;
    logic [15:0]   rt_cfg_data;
    logic [AW-1:0] cp_dst_addr;
    logic          cp_dst_valid;

    AerRouteTable #(
        .ADDR_WIDTH(AW), .ENTRY_COUNT(ENTRIES), .MAX_HOPS(MAX_HOPS)
    ) u_rt (
        .clk(clk), .rst_n(rst_n),
        .in_valid(rt_in_valid), .in_ready(rt_in_ready), .in_addr(rt_in_addr),
        .out_valid(rt_out_valid), .out_addr(rt_out_addr),
        .busy(rt_busy), .route_fault(rt_route_fault),
        .cfg_we(rt_cfg_we), .cfg_addr(rt_cfg_addr), .cfg_data(rt_cfg_data)
    );

    SynapseRouter #(.NEURON_ADDR_WIDTH(AW)) u_cp (
        .clk(clk), .rst_n(rst_n),
        .src_addr(rt_out_addr), .src_valid(rt_out_valid),
        .dst_addr(cp_dst_addr), .dst_valid(cp_dst_valid)
    );

    // Second composition loaded from the committed synthetic 0 -> 1 -> 2
    // fixture. Expectations below are hard-coded, not re-read from the file.
    logic          ini_in_valid;
    logic          ini_in_ready;
    logic [AW-1:0] ini_in_addr;
    logic          ini_out_valid;
    logic [AW-1:0] ini_out_addr;
    logic          ini_busy;
    logic          ini_route_fault;
    logic [AW-1:0] ini_dst_addr;
    logic          ini_dst_valid;

    AerRouteTable #(
        .ADDR_WIDTH(AW), .ENTRY_COUNT(ENTRIES), .MAX_HOPS(MAX_HOPS),
        .INIT_FILE(MULTIHOP_INIT_FILE)
    ) u_ini_rt (
        .clk(clk), .rst_n(rst_n),
        .in_valid(ini_in_valid), .in_ready(ini_in_ready), .in_addr(ini_in_addr),
        .out_valid(ini_out_valid), .out_addr(ini_out_addr),
        .busy(ini_busy), .route_fault(ini_route_fault),
        .cfg_we(1'b0), .cfg_addr('0), .cfg_data('0)
    );

    SynapseRouter #(.NEURON_ADDR_WIDTH(AW)) u_ini_sr (
        .clk(clk), .rst_n(rst_n),
        .src_addr(ini_out_addr), .src_valid(ini_out_valid),
        .dst_addr(ini_dst_addr), .dst_valid(ini_dst_valid)
    );

    // ---- independent reference model of aer-route-v1 ----
    logic [15:0] ref_mem [0:ENTRIES-1];

    function automatic logic [15:0] entry(
        input logic valid, input logic terminal, input logic [AW-1:0] next
    );
        return {valid, terminal, 10'b0, next};
    endfunction

    // Returns ok; dst/lookups by reference. Written without early return so
    // the output arguments are assigned on every path.
    function automatic logic ref_lookup(
        input  logic [AW-1:0] src,
        output logic [AW-1:0] dst,
        output int            lookups
    );
        logic [AW-1:0] a;
        logic [15:0]   e;
        logic          done;
        logic          ok;
        a       = src;
        dst     = '0;
        done    = 1'b0;
        ok      = 1'b0;
        lookups = 0;
        for (int hop = 0; hop < MAX_HOPS; hop++) begin
            if (!done) begin
                e       = ref_mem[a];
                lookups = lookups + 1;
                if (!e[15] || (|e[13:AW])) begin
                    done = 1'b1;
                end else if (e[14]) begin
                    dst  = e[AW-1:0];
                    ok   = 1'b1;
                    done = 1'b1;
                end else begin
                    a = e[AW-1:0];
                end
            end
        end
        return ok;
    endfunction

    typedef struct packed {
        logic          ok;
        logic [AW-1:0] dst;
    } exp_t;

    exp_t          exp_q[$];
    logic          rt_out_valid_d = 1'b0;
    logic [AW-1:0] rt_out_addr_d  = '0;
    int            cp_routed  = 0;
    int            cp_dropped = 0;
    int            cp_accepts = 0;
    int            cp_stalls  = 0;

    // Composition scoreboard. Runs every posedge on pre-edge values.
    always @(posedge clk) begin
        if (rst_n) begin
            // 1) SynapseRouter stage: registered copy of AerRouteTable output.
            check(cp_dst_valid === rt_out_valid_d,
                  $sformatf("CP: dst_valid=%b but table out_valid one cycle ago=%b",
                            cp_dst_valid, rt_out_valid_d));
            if (cp_dst_valid && rt_out_valid_d)
                check(cp_dst_addr === rt_out_addr_d,
                      $sformatf("CP: dst_addr=%0d but table out_addr one cycle ago=%0d",
                                cp_dst_addr, rt_out_addr_d));

            check(!(rt_out_valid && rt_route_fault),
                  "CP: out_valid and route_fault must not pulse together");

            // 2) End-to-end ordering against the reference model.
            if (cp_dst_valid) begin
                if (exp_q.size() == 0) begin
                    check(1'b0, $sformatf("CP: unexpected routed spike to %0d", cp_dst_addr));
                end else begin
                    exp_t e = exp_q.pop_front();
                    check(e.ok, $sformatf("CP: spike to %0d but reference says unrouted",
                                          cp_dst_addr));
                    check(cp_dst_addr === e.dst,
                          $sformatf("CP: routed to %0d expected %0d", cp_dst_addr, e.dst));
                    cp_routed++;
                end
            end
            if (rt_route_fault) begin
                if (exp_q.size() == 0) begin
                    check(1'b0, "CP: unexpected route_fault");
                end else begin
                    exp_t e = exp_q.pop_front();
                    check(!e.ok, $sformatf("CP: route_fault but reference routes to %0d",
                                           e.dst));
                    cp_dropped++;
                end
            end

            // 3) Configuration writes (only legal writes while idle are issued).
            if (rt_cfg_we) begin
                check(!rt_busy, "TB bug: configuration write issued while busy");
                ref_mem[rt_cfg_addr] = rt_cfg_data;
            end

            // 4) Handshake: one request accepted per in_valid && in_ready edge.
            if (rt_in_valid) begin
                if (rt_in_ready) begin
                    exp_t          e;
                    logic [AW-1:0] d;
                    int            n;
                    e.ok  = ref_lookup(rt_in_addr, d, n);
                    e.dst = d;
                    exp_q.push_back(e);
                    cp_accepts++;
                end else begin
                    cp_stalls++;
                end
            end
        end
        rt_out_valid_d <= rst_n ? rt_out_valid : 1'b0;
        rt_out_addr_d  <= rt_out_addr;
    end

    // ---- composition driver tasks (negedge) ----
    task automatic write_entry(input logic [AW-1:0] addr, input logic [15:0] data);
        while (rt_busy) @(negedge clk);
        rt_cfg_addr = addr;
        rt_cfg_data = data;
        rt_cfg_we   = 1'b1;
        @(negedge clk);
        rt_cfg_we   = 1'b0;
    endtask

    task automatic drain(input string label);
        int guard = 0;
        while ((exp_q.size() != 0 || rt_busy || rt_out_valid || cp_dst_valid)
               && guard < 32) begin
            @(negedge clk);
            guard++;
        end
        check(exp_q.size() == 0,
              $sformatf("%s: %0d expected event(s) never arrived", label, exp_q.size()));
        check(guard < 32, $sformatf("%s: pipeline did not drain", label));
    endtask

    // Directed: one request, measure end-to-end latency at the router output.
    task automatic route_and_check(input logic [AW-1:0] src, input string label);
        logic [AW-1:0] exp_dst;
        int            exp_lookups;
        logic          exp_ok;
        int            cycles;
        logic          saw_spike;
        logic          saw_fault;

        exp_ok = ref_lookup(src, exp_dst, exp_lookups);
        while (!rt_in_ready) @(negedge clk);
        rt_in_addr  = src;
        rt_in_valid = 1'b1;
        @(negedge clk);              // accepted on the posedge just passed
        rt_in_valid = 1'b0;

        cycles    = 0;
        saw_spike = 1'b0;
        saw_fault = 1'b0;
        // Success: table out_valid after exp_lookups edges, router +1 edge.
        // Fault:   route_fault after exp_lookups edges; watch 3 more for a stray spike.
        while (cycles <= exp_lookups + 3) begin
            if (cp_dst_valid) begin
                check(!saw_spike, $sformatf("%s: more than one routed spike", label));
                saw_spike = 1'b1;
                if (exp_ok) begin
                    check(cycles == exp_lookups + 1,
                          $sformatf("%s: end-to-end latency %0d expected %0d",
                                    label, cycles, exp_lookups + 1));
                    check(cp_dst_addr === exp_dst,
                          $sformatf("%s: routed to %0d expected %0d",
                                    label, cp_dst_addr, exp_dst));
                end
            end
            if (rt_route_fault) begin
                saw_fault = 1'b1;
                if (!exp_ok)
                    check(cycles == exp_lookups,
                          $sformatf("%s: fault after %0d cycles expected %0d",
                                    label, cycles, exp_lookups));
            end
            @(negedge clk);
            cycles++;
        end
        check(saw_spike == exp_ok,
              $sformatf("%s: routed-spike presence %b expected %b", label, saw_spike, exp_ok));
        check(saw_fault == !exp_ok,
              $sformatf("%s: route_fault presence %b expected %b", label, saw_fault, !exp_ok));
        drain(label);
    endtask

    // Directed on the INIT_FILE composition with hard-coded expectations.
    task automatic init_route_check(
        input logic [AW-1:0] src, input logic [AW-1:0] exp_dst,
        input int exp_lookups, input string label
    );
        int cycles = 0;
        logic seen = 1'b0;
        while (!ini_in_ready) @(negedge clk);
        ini_in_addr  = src;
        ini_in_valid = 1'b1;
        @(negedge clk);
        ini_in_valid = 1'b0;
        while (cycles <= exp_lookups + 3) begin
            check(!ini_route_fault, $sformatf("%s: unexpected route_fault", label));
            if (ini_dst_valid) begin
                check(!seen, $sformatf("%s: more than one spike", label));
                seen = 1'b1;
                check(cycles == exp_lookups + 1,
                      $sformatf("%s: latency %0d expected %0d", label, cycles, exp_lookups + 1));
                check(ini_dst_addr === exp_dst,
                      $sformatf("%s: routed to %0d expected %0d", label, ini_dst_addr, exp_dst));
            end
            @(negedge clk);
            cycles++;
        end
        check(seen, $sformatf("%s: no routed spike", label));
    endtask

    // Watchdog: a hung handshake must fail, not hang CI.
    initial begin
        #2_000_000;
        $fatal(1, "TB_SYNAPSE_ROUTER: watchdog timeout");
    end

    initial begin
        // ---------------- reset ----------------
        sr_rst_n     = 1'b0;
        sr_src_addr  = '0;
        sr_src_valid = 1'b0;
        rst_n        = 1'b0;
        rt_in_valid  = 1'b0;
        rt_in_addr   = '0;
        rt_cfg_we    = 1'b0;
        rt_cfg_addr  = '0;
        rt_cfg_data  = '0;
        ini_in_valid = 1'b0;
        ini_in_addr  = '0;
        for (int i = 0; i < ENTRIES; i++)
            ref_mem[i] = entry(1'b1, 1'b1, AW'(i));   // documented identity default
        for (int i = 0; i < 4; i++) begin
            hist_v[i] = 1'b0;
            hist_a[i] = '0;
        end

        repeat (3) @(negedge clk);
        check(sr_dst_valid === 1'b0 && sr_dst_addr === '0,
              "reset: standalone router outputs must be zero");
        check(cp_dst_valid === 1'b0 && ini_dst_valid === 1'b0,
              "reset: composition router outputs must be zero");
        sr_rst_n = 1'b1;
        rst_n    = 1'b1;
        @(negedge clk);
        sr_monitor_en = 1'b1;

        // ---------------- A1: every 8-bit address, back-to-back every cycle ----
        for (int a = 0; a < (1 << W8); a++) begin
            sr_src_addr  = W8'(a);
            sr_src_valid = 1'b1;
            @(negedge clk);
        end
        sr_src_valid = 1'b0;
        repeat (4) @(negedge clk);
        check(sr_checked_events == (1 << W8),
              $sformatf("A1: checked %0d of %0d back-to-back events",
                        sr_checked_events, 1 << W8));

        // ---------------- A2: random addresses with random valid gaps -------
        for (int i = 0; i < 512; i++) begin
            int unsigned r = next_rand();
            sr_src_addr  = W8'(r);
            sr_src_valid = r[8] | r[9];        // ~75% duty, includes gaps
            @(negedge clk);
        end
        sr_src_valid = 1'b0;
        repeat (4) @(negedge clk);

        // ---------------- A3: address changes while invalid must not leak ---
        sr_src_valid = 1'b0;
        for (int i = 0; i < 8; i++) begin
            sr_src_addr = W8'(next_rand());
            @(negedge clk);
            check(!sr_dst_valid, "A3: dst_valid must stay low while src_valid is low");
        end

        // ---------------- B: asynchronous reset ----------------------------
        sr_src_addr  = 8'hA5;
        sr_src_valid = 1'b1;
        @(negedge clk);                       // posedge captured 0xA5 / valid
        check(sr_dst_valid && sr_dst_addr == 8'hA5, "B: pre-reset capture");
        @(posedge clk);
        #2;                                   // mid-cycle, away from any edge
        sr_monitor_en = 1'b0;
        sr_rst_n = 1'b0;
        #1;
        check(sr_dst_valid === 1'b0 && sr_dst_addr === 8'h00,
              "B: async reset must clear outputs without a clock edge");
        check(c1_valid === 1'b0 && c2_valid === 1'b0 && c3_valid === 1'b0,
              "B: async reset must clear every cascade stage");
        repeat (3) @(negedge clk);            // valid input held through reset edges
        check(sr_dst_valid === 1'b0 && c3_valid === 1'b0,
              "B: outputs must stay clear while reset is held");
        sr_src_valid = 1'b0;
        sr_rst_n = 1'b1;
        repeat (4) @(negedge clk);
        sr_monitor_en = 1'b1;
        sr_src_addr  = 8'h3C;
        sr_src_valid = 1'b1;
        @(negedge clk);
        sr_src_valid = 1'b0;
        check(sr_dst_valid && sr_dst_addr == 8'h3C, "B: router must recover after reset");
        repeat (4) @(negedge clk);
        check(cascade_checked_events > 0, "A/B: cascade checks must not be vacuous");

        // ---------------- C1: identity single-hop, all 16 sources ----------
        for (int s = 0; s < ENTRIES; s++)
            route_and_check(AW'(s), $sformatf("C1 identity %0d", s));

        // ---------------- C2: multi-hop chains (2/3/4 lookups) -------------
        write_entry(4'd0, entry(1'b1, 1'b0, 4'd1));
        write_entry(4'd1, entry(1'b1, 1'b1, 4'd2));
        route_and_check(4'd0, "C2 two-lookup 0->1=>2");

        write_entry(4'd3, entry(1'b1, 1'b0, 4'd4));
        write_entry(4'd4, entry(1'b1, 1'b0, 4'd5));
        write_entry(4'd5, entry(1'b1, 1'b1, 4'd9));
        route_and_check(4'd3, "C2 three-lookup 3->4->5=>9");

        write_entry(4'd8,  entry(1'b1, 1'b0, 4'd10));
        write_entry(4'd10, entry(1'b1, 1'b0, 4'd11));
        write_entry(4'd11, entry(1'b1, 1'b0, 4'd12));
        write_entry(4'd12, entry(1'b1, 1'b1, 4'd15));
        route_and_check(4'd8, "C2 four-lookup 8->10->11->12=>15");
        route_and_check(4'd11, "C2 mid-chain entry 11->12=>15");

        // ---------------- C3: unrouted addresses ---------------------------
        write_entry(4'd13, entry(1'b0, 1'b1, 4'd13));
        route_and_check(4'd13, "C3 invalid entry drop");
        write_entry(4'd6, entry(1'b1, 1'b0, 4'd13));
        route_and_check(4'd6, "C3 valid hop into invalid entry drop");
        write_entry(4'd14, entry(1'b1, 1'b0, 4'd14));
        route_and_check(4'd14, "C3 self-cycle hop budget drop");
        write_entry(4'd7, entry(1'b1, 1'b0, 4'd8));   // 7->8->10->11->12=>15 needs 5
        route_and_check(4'd7, "C3 five-lookup chain exceeds MAX_HOPS");
        // The table and router must recover and route normally afterwards.
        route_and_check(4'd9, "C3 recovery identity 9");

        // ---------------- C4: committed INIT_FILE fixture ------------------
        init_route_check(4'd0, 4'd2, 2, "C4 fixture 0->1=>2");
        init_route_check(4'd1, 4'd2, 1, "C4 fixture 1=>2");
        for (int s = 2; s < ENTRIES; s++)
            init_route_check(AW'(s), AW'(s), 1, $sformatf("C4 fixture identity %0d", s));

        // ---------------- D: back-to-back stream under backpressure --------
        for (int burst = 0; burst < 8; burst++) begin
            // Randomize the table: mostly valid, mix of terminal / hop / drop.
            for (int i = 0; i < ENTRIES; i++) begin
                int unsigned r = next_rand();
                write_entry(AW'(i), entry(r[7:0] != 8'h00 && r[3:0] != 4'h0,
                                          r[5:4] != 2'b00, AW'(r >> 8)));
            end
            // Held-valid stream: in_valid stays high across requests; the
            // address only advances after an accepting edge.
            for (int n = 0; n < STREAM_EVENTS / 8; n++) begin
                int unsigned r = next_rand();
                rt_in_addr  = AW'(r);
                rt_in_valid = 1'b1;
                while (!rt_in_ready) @(negedge clk);   // stalled: hold addr/valid
                @(negedge clk);                       // accepted
                if (r[12:10] == 3'b000) begin          // occasional idle gap
                    rt_in_valid = 1'b0;
                    repeat (r[15:13]) @(negedge clk);
                end
            end
            rt_in_valid = 1'b0;
            drain($sformatf("D burst %0d", burst));
        end

        check(cp_stalls > 0, "D: backpressure (in_valid && !in_ready) never exercised");
        check(cp_routed > 0 && cp_dropped > 0,
              "D: stream must contain both routed and unrouted events");

        $display("TB_SYNAPSE_ROUTER: standalone events=%0d cascade=%0d | composition accepts=%0d routed=%0d dropped=%0d stall_cycles=%0d",
                 sr_checked_events, cascade_checked_events, cp_accepts, cp_routed,
                 cp_dropped, cp_stalls);
        if (errors == 0) begin
            $display("TB_SYNAPSE_ROUTER: ALL TESTS PASSED");
            $finish;
        end else begin
            $fatal(1, "TB_SYNAPSE_ROUTER: %0d TEST(S) FAILED", errors);
        end
    end
endmodule

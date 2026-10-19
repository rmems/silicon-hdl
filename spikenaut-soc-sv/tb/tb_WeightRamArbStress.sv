// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_WeightRamArbStress.sv
// Canonical source: spikenaut-soc-sv/tb
// Randomized, self-checking stress test for the sweep-safe WeightRam
// arbitration in spikenaut-soc-sv/rtl/Basys3_Top.sv
// (top module spikenaut_soc_basys3_top).
//
// Arbitration contract under test (#103):
//   LIF neuron sweep  >  STDP column walk (StdpWriteback, SW14)  >  host 0xA5
//   runtime write (held in wr_pending while blocked).
// tb_Basys3_Top test 12/14 cover this with directed cases. This TB throws
// host writes at $urandom cycle offsets around every logical tick: just before
// step_en, on the tick edge, inside PREFETCH/SWEEP, on tick_done, inside every
// StdpWriteback state, and while the fabric is idle. It runs three learn
// modes: SW14=0 (STDP off), SW14=1 (STDP on), and SW14 toggled at random
// cycles near tick_done.
//
// Checks (all against an SV reference model; nothing is read back from the
// DUT's own memory until the end-of-run comparison):
//   * Every registered read of WeightRam / threshold / leak RAM returns the
//     model word for the address presented on the previous edge (read-first).
//     This covers PE sweep reads and the STDP snapshot reads: no torn, stale
//     or stolen word.
//   * No RAM write lands while the PE is sweeping (step_en .. last SWEEP
//     slot), and the RAM address stays on the PE path during the sweep.
//   * During the STDP walk the only WeightRam writes are exactly the
//     StdpWriteback client's requests, and each is an atomic
//     read-modify-write: new = model[addr] +/- 1.
//   * Every host write lands exactly once, in order, at the right target,
//     address and data, outside both windows, within LAND_BOUND cycles.
//     Nothing lands that the host did not issue.
//   * The full 256-word WeightRam and both parameter RAMs equal the model at
//     the end of the run.
//
// Envelope: one host write outstanding at a time. A 5-byte 0xA5 frame takes
// ~43k fabric cycles at 115200 baud, far longer than any blocked window
// (<~75 cycles), so two writes cannot queue behind one sweep/walk on real
// hardware and SocProtocolFsm's single wr_pending slot is sufficient.
//
// Time compression: the SoC's own 1 ms divider is kept, but step_cnt is
// force-advanced to a random point a few cycles before rollover while the
// fabric is idle, so step_en is still the DUT's real one-cycle register
// pulse. This TB therefore does NOT check the tick period; tb_Basys3_Top
// does. Stimulus frames are injected at the decoded-frame boundary
// (protocol_stimuli / protocol_stimuli_valid) and host writes at the FSM
// write-strobe outputs, the same fabric-rate force style as tb_Basys3_Top's
// inject_host_strobe; UART is far too slow to land inside a sweep.
//
// Seed: +seed=N (default 1). The seed is logged at start and in the result
// banner; any FAIL line is reproducible with the same +seed.
// Ticks per learn mode: +ticks=N (default 256).
//
// Stimulus is applied on negedge clk; the monitor samples at negedge + 1 ns
// so it sees the TB's forces settled and stays clear of DUT posedges.
// $readmemh INIT_FILE paths are repo-root relative — run from the repo root.

`timescale 1ns/1ps

module tb_WeightRamArbStress #(
    parameter string WEIGHT_INIT = "spikenaut-core-sv/mem/merged_v2_weights.mem",
    parameter string THRESH_INIT = "spikenaut-core-sv/mem/merged_v2_thresholds.mem",
    parameter string LEAK_INIT   = "spikenaut-core-sv/mem/merged_v2_decay.mem",
    parameter string OUTPUT_WEIGHT_INIT = "spikenaut-core-sv/mem/merged_v2_output_weights.mem",
    parameter string ROUTE_INIT = "synapse-link-hdl/mem/aer_routes_identity_n16.mem"
);

    localparam int CLK_PERIOD  = 10;
    localparam int STEP_DIV    = 100_000;   // 100 MHz / 1 kHz, mirrors the DUT
    localparam int NUM_NEURONS = 16;
    localparam int RAM_DEPTH   = 256;       // WEIGHT_ADDR_W = NEURON_ADDR_W = 8
    localparam int LAND_BOUND  = 128;       // max cycles a host write may wait
    localparam int TICK_BOUND  = 400;       // per-tick watchdog (cycles)
    localparam int NUM_MODES   = 3;         // 0: SW14=0, 1: SW14=1, 2: toggled

    // StdpWriteback state encoding (state_t order in StdpWriteback.sv).
    localparam logic [2:0] ST_IDLE      = 3'd0;
    localparam logic [2:0] ST_READ_REQ  = 3'd1;
    localparam logic [2:0] ST_READ_CAP  = 3'd2;
    localparam logic [2:0] ST_UPDATE    = 3'd3;
    localparam logic [2:0] ST_HANDOFF   = 3'd4;
    localparam logic [2:0] ST_WRITEBACK = 3'd5;

    logic        clk;
    logic        btn_rst;
    logic        uart_rx_line;
    logic        uart_tx_line;
    logic [15:0] sw;
    logic [15:0] led;

    spikenaut_soc_basys3_top #(
        .WEIGHT_INIT_FILE (WEIGHT_INIT),
        .THRESH_INIT_FILE (THRESH_INIT),
        .LEAK_INIT_FILE   (LEAK_INIT),
        .OUTPUT_WEIGHT_INIT_FILE (OUTPUT_WEIGHT_INIT),
        .ROUTE_INIT_FILE  (ROUTE_INIT)
    ) dut (
        .clk     (clk),
        .rst_n   (btn_rst),
        .uart_rx (uart_rx_line),
        .uart_tx (uart_tx_line),
        .sw      (sw),
        .led     (led)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ----------------------------------------------------------------
    // Reference model
    // ----------------------------------------------------------------
    logic [15:0] wmodel [0:RAM_DEPTH-1];
    logic [15:0] tmodel [0:RAM_DEPTH-1];
    logic [15:0] lmodel [0:RAM_DEPTH-1];
    logic [15:0] wimg   [0:RAM_DEPTH-1];
    logic [15:0] timg   [0:RAM_DEPTH-1];
    logic [15:0] limg   [0:RAM_DEPTH-1];
    // Set when the oldest outstanding host write is held while STDP owns the
    // port (proves the STDP > host leg of the priority was exercised).
    bit          hq_saw_stdp;

    // Expected registered-read results for the next cycle.
    logic        exp_valid;
    logic [15:0] w_exp, t_exp, l_exp;

    // Outstanding host writes (FIFO; the stimulus keeps at most one in flight).
    localparam int HQ_DEPTH = 8;
    logic [1:0]  hq_target [0:HQ_DEPTH-1];
    logic [7:0]  hq_addr   [0:HQ_DEPTH-1];
    logic [15:0] hq_data   [0:HQ_DEPTH-1];
    longint      hq_cyc    [0:HQ_DEPTH-1];
    int          hq_cat    [0:HQ_DEPTH-1];
    int          hq_count;

    int          errors;
    longint      cyc;
    bit          mon_en;
    int unsigned seed;
    int unsigned ticks_per_mode;
    int          cur_mode;
    int          cur_tick;

    // Coverage / statistics.
    int cov_inject_sweep, cov_inject_tickedge, cov_inject_tickdone;
    int cov_inject_stdp_read, cov_inject_stdp_upd, cov_inject_stdp_wb;
    int cov_inject_idle;
    int cov_deferred, cov_deferred_by_stdp;
    int cov_stdp_walks, cov_stdp_writes, cov_stdp_ltp, cov_stdp_ltd;
    int cov_host_w, cov_host_t, cov_host_l;
    int cov_reads_sweep, cov_reads_stdp;
    int cov_frames, cov_learn_toggles;
    longint max_land_latency;
    int mode_stdp_walks [0:NUM_MODES-1];

    // Static force sources (XSim rejects force from automatic args).
    logic [1:0]  f_target;
    logic [7:0]  f_addr;
    logic [15:0] f_data;
    logic [16:0] f_step_cnt;
    logic [NUM_NEURONS*16-1:0] f_stimuli;

    task automatic fail(input string msg);
        errors++;
        $display("FAIL [seed=%0d mode=%0d tick=%0d cyc=%0d]: %s",
                 seed, cur_mode, cur_tick, cyc, msg);
        if (errors >= 25)
            $fatal(1, "TB_WEIGHTRAM_ARB_STRESS: too many failures (seed=%0d)", seed);
    endtask

    // ----------------------------------------------------------------
    // Host write landing (called by the monitor)
    // ----------------------------------------------------------------
    task automatic host_land(input logic [1:0] target,
                             input logic [7:0] addr,
                             input logic [15:0] data);
        longint lat;
        if ($test$plusargs("trace")) $display("  [trace cyc=%0d] land t=%0d a=0x%02h d=0x%04h hq=%0d", cyc, target, addr, data, hq_count);
        if (hq_count == 0) begin
            fail($sformatf("spurious write: target %0d addr 0x%02h data 0x%04h landed with no host write outstanding",
                           target, addr, data));
        end else if (hq_target[0] !== target) begin
            fail($sformatf("host write applied to wrong target: issued target %0d addr 0x%02h, landed target %0d addr 0x%02h",
                           hq_target[0], hq_addr[0], target, addr));
        end else if (hq_addr[0] !== addr || hq_data[0] !== data) begin
            fail($sformatf("host write mangled: issued addr 0x%02h data 0x%04h, landed addr 0x%02h data 0x%04h (target %0d)",
                           hq_addr[0], hq_data[0], addr, data, target));
        end
        // Model follows what the HOST issued, never what the port carried, so a
        // misdirected write also surfaces in the final RAM comparison.
        if (hq_count != 0) begin
            case (hq_target[0])
                2'd0: begin wmodel[hq_addr[0]] = hq_data[0]; cov_host_w++; end
                2'd1: begin tmodel[hq_addr[0]] = hq_data[0]; cov_host_t++; end
                2'd2: begin lmodel[hq_addr[0]] = hq_data[0]; cov_host_l++; end
                default: ;
            endcase
            lat = cyc - hq_cyc[0];
            if (lat > max_land_latency) max_land_latency = lat;
            if (lat > LAND_BOUND)
                fail($sformatf("host write landed after %0d cycles (bound %0d)", lat, LAND_BOUND));
            if (lat > 0) cov_deferred++;
            if (hq_saw_stdp) cov_deferred_by_stdp++;
            hq_saw_stdp = 1'b0;
            for (int i = 0; i < HQ_DEPTH - 1; i++) begin
                hq_target[i] = hq_target[i+1];
                hq_addr[i]   = hq_addr[i+1];
                hq_data[i]   = hq_data[i+1];
                hq_cyc[i]    = hq_cyc[i+1];
                hq_cat[i]    = hq_cat[i+1];
            end
            hq_count--;
        end
    endtask

    // ----------------------------------------------------------------
    // Monitor: negedge + 1 ns, every cycle after reset
    // ----------------------------------------------------------------
    task automatic monitor_cycle();
        logic        sweep_win, stdp_win;
        logic [2:0]  stdp_state;
        logic        w_we, t_we, l_we;
        logic [7:0]  w_addr, t_addr, l_addr;
        logic [15:0] w_din, t_din, l_din;
        logic signed [16:0] delta;

        cyc++;

        // 1. Registered reads from the previous edge (read-first semantics).
        if (exp_valid) begin
            if (dut.u_wram.dout !== w_exp)
                fail($sformatf("WeightRam read returned 0x%04h, model 0x%04h (torn/stale read)",
                               dut.u_wram.dout, w_exp));
            if (dut.u_npram_threshold.dout !== t_exp)
                fail($sformatf("threshold RAM read returned 0x%04h, model 0x%04h",
                               dut.u_npram_threshold.dout, t_exp));
            if (dut.u_npram_leak.dout !== l_exp)
                fail($sformatf("leak RAM read returned 0x%04h, model 0x%04h",
                               dut.u_npram_leak.dout, l_exp));
        end

        // 2. Port values that the next posedge will act on.
        sweep_win  = (dut.step_en === 1'b1) || (2'(dut.u_lif_array.sweep_state) != 2'd0);
        stdp_state = 3'(dut.u_stdp.state);
        stdp_win   = (stdp_state != ST_IDLE);

        w_we = dut.u_wram.we;            w_addr = dut.u_wram.addr;            w_din = dut.u_wram.din;
        t_we = dut.u_npram_threshold.we; t_addr = dut.u_npram_threshold.addr; t_din = dut.u_npram_threshold.din;
        l_we = dut.u_npram_leak.we;      l_addr = dut.u_npram_leak.addr;      l_din = dut.u_npram_leak.din;

        if ($isunknown({w_we, w_addr, t_we, t_addr, l_we, l_addr}))
            fail("X/Z on a RAM control port");

        w_exp = wmodel[w_addr];
        t_exp = tmodel[t_addr];
        l_exp = lmodel[l_addr];
        exp_valid = 1'b1;

        if (sweep_win && stdp_win)
            fail("PE sweep and STDP walk overlap on WeightRam");
        // The SoC retires a host write (clears wr_pending / consumes the
        // strobe) on wr_fire.  For a weight write that must coincide with the
        // WeightRam port actually carrying it, or the write is silently lost.
        if (dut.wr_fire === 1'b1 && dut.wr_sel_target === 2'd0) begin
            if (!(w_we === 1'b1 && w_addr === dut.wr_sel_addr && w_din === dut.wr_sel_data))
                fail($sformatf("host weight write dropped/misdirected: wr_fire for 0x%02h<=0x%04h but WeightRam port we=%0b 0x%02h<=0x%04h (sweep=%0b stdp_state=%0d)",
                               dut.wr_sel_addr, dut.wr_sel_data, w_we, w_addr, w_din, sweep_win, stdp_state));
        end
        if (stdp_win && hq_count != 0 && dut.wr_pending === 1'b1)
            hq_saw_stdp = 1'b1;

        if (sweep_win) begin
            cov_reads_sweep++;
            if (w_addr !== dut.u_lif_array.weight_addr)
                fail($sformatf("sweep read stolen: WeightRam addr 0x%02h, PE wants 0x%02h",
                               w_addr, dut.u_lif_array.weight_addr));
            if (t_addr !== dut.u_lif_array.threshold_addr)
                fail("sweep read stolen: threshold RAM address left the PE path");
            if (l_addr !== dut.u_lif_array.leak_addr)
                fail("sweep read stolen: leak RAM address left the PE path");
            if (w_we) fail($sformatf("WeightRam write during sweep (addr 0x%02h data 0x%04h)", w_addr, w_din));
            if (t_we) fail("threshold RAM write during sweep");
            if (l_we) fail("leak RAM write during sweep");
        end else if (stdp_win) begin
            if (stdp_state == ST_READ_REQ || stdp_state == ST_READ_CAP) begin
                cov_reads_stdp++;
                if (w_addr !== dut.u_stdp.weight_addr)
                    fail($sformatf("STDP snapshot read stolen: WeightRam addr 0x%02h, STDP wants 0x%02h",
                                   w_addr, dut.u_stdp.weight_addr));
            end
            if (dut.u_stdp.weight_we === 1'b1) begin
                if (!w_we || w_addr !== dut.u_stdp.weight_addr || w_din !== dut.u_stdp.weight_din) begin
                    fail($sformatf("STDP write dropped/mangled: client 0x%02h<=0x%04h, port we=%0b 0x%02h<=0x%04h",
                                   dut.u_stdp.weight_addr, dut.u_stdp.weight_din, w_we, w_addr, w_din));
                end
                // Atomic RMW: StdpController emits snapshot +/- 1.
                delta = $signed({dut.u_stdp.weight_din[15], dut.u_stdp.weight_din})
                      - $signed({wmodel[dut.u_stdp.weight_addr][15], wmodel[dut.u_stdp.weight_addr]});
                if (delta == 1)       cov_stdp_ltp++;
                else if (delta == -1) cov_stdp_ltd++;
                else
                    fail($sformatf("STDP RMW not atomic: addr 0x%02h model 0x%04h, STDP wrote 0x%04h",
                                   dut.u_stdp.weight_addr, wmodel[dut.u_stdp.weight_addr],
                                   dut.u_stdp.weight_din));
                wmodel[dut.u_stdp.weight_addr] = dut.u_stdp.weight_din;
                cov_stdp_writes++;
            end else if (w_we) begin
                fail($sformatf("foreign WeightRam write during STDP walk (state %0d, addr 0x%02h data 0x%04h)",
                               stdp_state, w_addr, w_din));
            end
            if (t_we) host_land(2'd1, t_addr, t_din);
            if (l_we) host_land(2'd2, l_addr, l_din);
        end else begin
            if (w_we) host_land(2'd0, w_addr, w_din);
            if (t_we) host_land(2'd1, t_addr, t_din);
            if (l_we) host_land(2'd2, l_addr, l_din);
        end
    endtask

    always @(negedge clk) begin
        #1;
        if (mon_en) monitor_cycle();
    end

    // Count STDP walks (rising edge of busy) per mode.
    logic stdp_busy_q;
    always @(negedge clk) begin
        #1;
        if (mon_en) begin
            if (dut.stdp_busy === 1'b1 && !stdp_busy_q) begin
                cov_stdp_walks++;
                mode_stdp_walks[cur_mode]++;
            end
            stdp_busy_q = (dut.stdp_busy === 1'b1);
        end else begin
            stdp_busy_q = 1'b0;
        end
    end

    // ----------------------------------------------------------------
    // Stimulus helpers (caller is at a negedge)
    // ----------------------------------------------------------------
    task automatic sample_inject_category(input int o);
        logic [2:0] st;
        st = 3'(dut.u_stdp.state);
        if (dut.step_en === 1'b1)                       cov_inject_tickedge++;
        else if (dut.u_lif_array.tick_done === 1'b1)    cov_inject_tickdone++;
        else if (2'(dut.u_lif_array.sweep_state) != 0)  cov_inject_sweep++;
        else if (st == ST_READ_REQ || st == ST_READ_CAP) cov_inject_stdp_read++;
        else if (st == ST_UPDATE || st == ST_HANDOFF)   cov_inject_stdp_upd++;
        else if (st == ST_WRITEBACK)                    cov_inject_stdp_wb++;
        else                                            cov_inject_idle++;
    endtask

    // Push the expected write, then force a one-cycle FSM write strobe.  The
    // caller releases it at the next negedge (release_host_strobe).
    task automatic force_host_strobe(input logic [1:0] target,
                                     input logic [7:0] addr,
                                     input logic [15:0] data,
                                     input int cat);
        if (hq_count >= HQ_DEPTH)
            $fatal(1, "host queue overflow (TB bug)");
        hq_target[hq_count] = target;
        hq_addr[hq_count]   = addr;
        hq_data[hq_count]   = data;
        hq_cyc[hq_count]    = cyc + 1;   // monitor increments cyc at this negedge+1
        hq_cat[hq_count]    = cat;
        hq_count++;
        if ($test$plusargs("trace")) $display("  [trace cyc=%0d] host strobe t=%0d a=0x%02h d=0x%04h", cyc, target, addr, data);
        f_target = target;
        f_addr   = addr;
        f_data   = data;
        force dut.host_wr_en     = 1'b1;
        force dut.host_wr_target = f_target;
        force dut.host_wr_addr   = f_addr;
        force dut.host_wr_data   = f_data;
    endtask

    // host_wr_en is a register output of SocProtocolFsm. Per IEEE 1800
    // force/release semantics a released variable KEEPS the forced value until
    // its next procedural assignment, so a bare release here would stretch
    // the strobe to two cycles (two writes). Drop it to 0 under force for one
    // cycle (the FSM re-assigns 0 at that posedge), then release it.
    task automatic release_host_strobe();
        force dut.host_wr_en = 1'b0;
        release dut.host_wr_target;
        release dut.host_wr_addr;
        release dut.host_wr_data;
    endtask

    task automatic release_host_en();
        release dut.host_wr_en;
    endtask

    // Random host write: mostly weights, some threshold/leak.  Param data is
    // kept non-negative (sign-bit-set param words are rejected by design,
    // #73 follow-up, and would read as "dropped" here).
    task automatic random_write(output logic [1:0] target,
                                output logic [7:0] addr,
                                output logic [15:0] data);
        int unsigned r;
        r = $urandom % 10;
        if (r < 8) begin
            target = 2'd0;
            // Bias half the weight writes into rows/cols the PE and STDP are
            // actually touching this run (any row, low columns).
            if (($urandom % 2) != 0) addr = 8'($urandom % RAM_DEPTH);
            else              addr = 8'(($urandom % NUM_NEURONS) * NUM_NEURONS + ($urandom % 4));
            case ($urandom % 4)
                0: data = 16'($urandom);                    // full signed range
                1: data = 16'h0200 + 16'($urandom % 16'h0400); // strongly excitatory
                2: data = 16'h7FFF - 16'($urandom % 2);    // LTP saturation edge
                default: data = 16'h8000 + 16'($urandom % 2); // LTD saturation edge
            endcase
        end else if (r == 8) begin
            target = 2'd1;
            addr   = 8'($urandom % NUM_NEURONS);
            data   = 16'h0080 + 16'($urandom % 16'h0300);
        end else begin
            target = 2'd2;
            addr   = 8'($urandom % NUM_NEURONS);
            data   = 16'($urandom % 16'h0100);
        end
    endtask

    // Decoded-frame injection (same boundary as tb_Basys3_Top test 12b).
    task automatic inject_frame(input int lane);
        int waited;
        f_stimuli = '0;
        f_stimuli[lane*16 +: 16] = 16'h0001;
        @(negedge clk);
        force dut.protocol_stimuli       = f_stimuli;
        force dut.protocol_stimuli_valid = 1'b1;
        @(negedge clk);
        release dut.protocol_stimuli_valid;
        release dut.protocol_stimuli;
        waited = 0;
        while (dut.route_resolved !== 1'b1) begin
            @(negedge clk);
            waited++;
            if (waited > 32) begin
                fail("stimulus frame route did not resolve");
                break;
            end
        end
        cov_frames++;
    endtask

    function automatic bit fabric_idle();
        return (dut.step_en === 1'b0)
            && (2'(dut.u_lif_array.sweep_state) == 2'd0)
            && (dut.u_lif_array.tick_done === 1'b0)
            && (dut.stdp_busy === 1'b0)
            && (dut.wr_pending === 1'b0)
            && (dut.route_busy === 1'b0)
            && (dut.route_request_pending === 1'b0)
            && (hq_count == 0);
    endfunction

    // ----------------------------------------------------------------
    // One logical tick with an optional randomly placed host write.
    // o = cycle offset of the host strobe relative to the negedge at which
    // step_en reads high (o < 0: before the tick edge).
    //   cat 0: sweep window and its edges      o in [-3, 20]
    //   cat 1: STDP walk window and its edges  o in [16, 72]
    //   cat 2: idle                            o in [-gap, -4] or [76, 90]
    // ----------------------------------------------------------------
    // Cycle offsets (relative to the negedge where step_en reads high) of the
    // arbitration boundaries for the shipped N=16 PE / StdpWriteback timing:
    // PREFETCH o=1, SWEEP o=2..17, tick_done o=18, STDP READ o=19..50,
    // UPDATE o=51, HANDOFF o=52, WRITEBACK o=53..68. Only used to bias
    // stimulus; checks never assume them.
    int edge_sweep [0:6] = '{-1, 0, 1, 2, 17, 18, 19};
    int edge_stdp  [0:7] = '{18, 19, 20, 51, 52, 53, 68, 69};

    task automatic run_tick();
        int unsigned gap;
        int          cat;
        bit          do_write;
        int          o_write;
        bit          do_flip;
        int          o_flip;
        bit          started;
        bit          written;
        bit          rel_pending;
        bit          rel2_pending;
        int          o;
        int          guard;
        logic [1:0]  tgt;
        logic [7:0]  adr;
        logic [15:0] dat;

        // Wait for a fully idle fabric (previous write landed, walk done).
        guard = 0;
        while (!fabric_idle()) begin
            @(negedge clk);
            guard++;
            if (guard > TICK_BOUND) begin
                fail($sformatf("fabric never went idle (pending=%0b stdp_busy=%0b hq=%0d) -- host write starved or dropped",
                               dut.wr_pending, dut.stdp_busy, hq_count));
                hq_count = 0;
                break;
            end
        end

        // Optional pre-synaptic event for this tick.
        if (($urandom % 4) != 0)
            inject_frame(int'($urandom % NUM_NEURONS));

        gap      = 6 + ($urandom % 40);
        cat      = int'($urandom % 3);
        do_write = (($urandom % 8) != 0);
        // Half of the in-window strobes are pinned to a window boundary
        // (tick edge, first PREFETCH cycle, last SWEEP slot, tick_done, first
        // STDP read, UPDATE/HANDOFF, first/last WRITEBACK slot, walk exit),
        // where an off-by-one in the arbiter would show.
        case (cat)
            0: o_write = (($urandom % 2) != 0) ? edge_sweep[$urandom % 7]
                                               : -3 + int'($urandom % 24);
            1: o_write = (($urandom % 2) != 0) ? edge_stdp[$urandom % 8]
                                               : 16 + int'($urandom % 57);
            default: o_write = (($urandom % 2) != 0) ? -int'(gap) + int'($urandom % (gap - 3))
                                              : 76 + int'($urandom % 15);
        endcase
        do_flip = (cur_mode == 2) && (($urandom % 2) != 0);
        // SW14 passes a 2FF sync, so flips at o in [12, 22] move learn_en
        // across the tick_done sample point.
        o_flip  = 12 + int'($urandom % 11);
        random_write(tgt, adr, dat);

        // Fast-forward the DUT's own divider to `gap` cycles before rollover.
        @(negedge clk);
        f_step_cnt = 17'(STEP_DIV - gap);
        force dut.step_cnt = f_step_cnt;
        @(negedge clk);
        release dut.step_cnt;

        started     = 1'b0;
        written     = 1'b0;
        rel_pending = 1'b0;
        rel2_pending = 1'b0;
        o           = -int'(gap);
        guard       = 0;
        forever begin
            if (!started) begin
                if (dut.step_en === 1'b1) begin
                    started = 1'b1;
                    o = 0;
                end else begin
                    o = int'(dut.step_cnt) - STEP_DIV;
                end
            end else begin
                o++;
            end

            if (rel2_pending) begin
                release_host_en();
                rel2_pending = 1'b0;
            end
            if (rel_pending) begin
                release_host_strobe();
                rel_pending  = 1'b0;
                rel2_pending = 1'b1;
            end
            if (do_write && !written && o == o_write) begin
                sample_inject_category(o);
                force_host_strobe(tgt, adr, dat, cat);
                written     = 1'b1;
                rel_pending = 1'b1;
            end
            if (do_flip && started && o == o_flip) begin
                sw[14] = ~sw[14];
                cov_learn_toggles++;
            end

            if (started && o >= 90 && !rel_pending && !rel2_pending && fabric_idle())
                break;

            @(negedge clk);
            guard++;
            if (guard > TICK_BOUND + int'(gap)) begin
                if (rel_pending) release_host_strobe();
                release_host_en();
                fail($sformatf("tick did not complete -- host write never landed (dropped?) (started=%0b o=%0d hq=%0d pending=%0b)",
                               started, o, hq_count, dut.wr_pending));
                hq_count = 0;
                break;
            end
        end
    endtask

    task automatic compare_rams(input string tag);
        int mism;
        mism = 0;
        for (int a = 0; a < RAM_DEPTH; a++) begin
            if (dut.u_wram.mem[a] !== wmodel[a]) begin
                mism++;
                if (mism <= 8)
                    fail($sformatf("%s: WeightRam[0x%02h] = 0x%04h, model 0x%04h",
                                   tag, a, dut.u_wram.mem[a], wmodel[a]));
            end
            if (dut.u_npram_threshold.mem[a] !== tmodel[a]) begin
                mism++;
                if (mism <= 8)
                    fail($sformatf("%s: threshold[0x%02h] = 0x%04h, model 0x%04h",
                                   tag, a, dut.u_npram_threshold.mem[a], tmodel[a]));
            end
            if (dut.u_npram_leak.mem[a] !== lmodel[a]) begin
                mism++;
                if (mism <= 8)
                    fail($sformatf("%s: leak[0x%02h] = 0x%04h, model 0x%04h",
                                   tag, a, dut.u_npram_leak.mem[a], lmodel[a]));
            end
        end
        if (mism != 0)
            $display("  %s: %0d RAM word(s) differ from the model", tag, mism);
    endtask

    // ----------------------------------------------------------------
    // Main
    // ----------------------------------------------------------------
    initial begin
        errors = 0; cyc = 0; mon_en = 1'b0; exp_valid = 1'b0; hq_count = 0; hq_saw_stdp = 1'b0;
        cur_mode = 0; cur_tick = 0; max_land_latency = 0;
        cov_inject_sweep = 0; cov_inject_tickedge = 0; cov_inject_tickdone = 0;
        cov_inject_stdp_read = 0; cov_inject_stdp_upd = 0; cov_inject_stdp_wb = 0;
        cov_inject_idle = 0; cov_deferred = 0; cov_deferred_by_stdp = 0;
        cov_stdp_walks = 0; cov_stdp_writes = 0; cov_stdp_ltp = 0; cov_stdp_ltd = 0;
        cov_host_w = 0; cov_host_t = 0; cov_host_l = 0;
        cov_reads_sweep = 0; cov_reads_stdp = 0; cov_frames = 0; cov_learn_toggles = 0;
        for (int m = 0; m < NUM_MODES; m++) mode_stdp_walks[m] = 0;

        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("ticks=%d", ticks_per_mode)) ticks_per_mode = 256;
        void'($urandom(seed));
        $display("TB_WEIGHTRAM_ARB_STRESS: seed=%0d ticks/mode=%0d modes=%0d",
                 seed, ticks_per_mode, NUM_MODES);

        btn_rst      = 1'b1;
        uart_rx_line = 1'b1;
        sw           = '0;
        repeat (5) @(negedge clk);

        // Model starts from the same images the DUT $readmemh's. The images
        // are loaded independently here and checked against the DUT; words
        // beyond an image (param RAMs hold 16 of 256) take the simulator's
        // own power-up value, which no test write or read ever touches.
        for (int a = 0; a < RAM_DEPTH; a++) begin
            wimg[a] = 'x; timg[a] = 'x; limg[a] = 'x;
        end
        $readmemh(WEIGHT_INIT, wimg);
        $readmemh(THRESH_INIT, timg);
        $readmemh(LEAK_INIT,   limg);
        for (int a = 0; a < RAM_DEPTH; a++) begin
            if (!$isunknown(wimg[a]) && dut.u_wram.mem[a] !== wimg[a])
                fail($sformatf("post-reset WeightRam[0x%02h] != image", a));
            if (!$isunknown(timg[a]) && dut.u_npram_threshold.mem[a] !== timg[a])
                fail($sformatf("post-reset threshold[0x%02h] != image", a));
            if (!$isunknown(limg[a]) && dut.u_npram_leak.mem[a] !== limg[a])
                fail($sformatf("post-reset leak[0x%02h] != image", a));
            wmodel[a] = $isunknown(wimg[a]) ? dut.u_wram.mem[a]            : wimg[a];
            tmodel[a] = $isunknown(timg[a]) ? dut.u_npram_threshold.mem[a] : timg[a];
            lmodel[a] = $isunknown(limg[a]) ? dut.u_npram_leak.mem[a]      : limg[a];
        end
        if ($isunknown(wimg[RAM_DEPTH-1]))
            fail("weight image does not cover all 256 WeightRam words");

        btn_rst = 1'b0;
        @(negedge clk);
        mon_en = 1'b1;

        for (int m = 0; m < NUM_MODES; m++) begin
            cur_mode = m;
            sw[14] = (m == 1);
            repeat (4) @(negedge clk);
            for (int t = 0; t < int'(ticks_per_mode); t++) begin
                cur_tick = t;
                run_tick();
            end
            // Drain and compare after each mode so a failure names its mode.
            repeat (100) @(negedge clk);
            compare_rams($sformatf("end of mode %0d", m));
        end

        if (hq_count != 0)
            fail($sformatf("%0d host write(s) never landed (dropped)", hq_count));

        $display("  coverage: host-strobe placement  sweep=%0d tick_edge=%0d tick_done=%0d stdp_read=%0d stdp_update=%0d stdp_writeback=%0d idle=%0d",
                 cov_inject_sweep, cov_inject_tickedge, cov_inject_tickdone,
                 cov_inject_stdp_read, cov_inject_stdp_upd, cov_inject_stdp_wb, cov_inject_idle);
        $display("  coverage: host writes landed  weight=%0d threshold=%0d leak=%0d deferred=%0d (by_stdp=%0d) max_latency=%0d",
                 cov_host_w, cov_host_t, cov_host_l, cov_deferred, cov_deferred_by_stdp, max_land_latency);
        $display("  coverage: STDP walks=%0d (mode0=%0d mode1=%0d mode2=%0d) writes=%0d ltp=%0d ltd=%0d learn_toggles=%0d",
                 cov_stdp_walks, mode_stdp_walks[0], mode_stdp_walks[1], mode_stdp_walks[2],
                 cov_stdp_writes, cov_stdp_ltp, cov_stdp_ltd, cov_learn_toggles);
        $display("  coverage: checked reads sweep=%0d stdp_snapshot=%0d frames=%0d cycles=%0d",
                 cov_reads_sweep, cov_reads_stdp, cov_frames, cyc);

        // Coverage gates: a run that never reached the contested windows
        // proves nothing, so treat missing bins as failures.
        if (cov_inject_sweep == 0)     fail("coverage: no host strobe landed inside the sweep");
        if (cov_inject_tickedge == 0)  fail("coverage: no host strobe landed on the tick edge");
        if (cov_inject_tickdone == 0)  fail("coverage: no host strobe landed on tick_done");
        if (cov_inject_stdp_read + cov_inject_stdp_upd + cov_inject_stdp_wb == 0)
            fail("coverage: no host strobe landed inside the STDP walk");
        if (cov_deferred_by_stdp == 0) fail("coverage: no host write was deferred by an STDP walk");
        if (mode_stdp_walks[0] != 0)   fail("SW14=0 mode started an STDP walk");
        if (mode_stdp_walks[1] == 0)   fail("coverage: SW14=1 mode never started an STDP walk");
        if (cov_stdp_writes == 0)      fail("coverage: STDP never wrote WeightRam");

        if (errors == 0) begin
            $display("TB_WEIGHTRAM_ARB_STRESS: ALL TESTS PASSED (seed=%0d)", seed);
            $finish;
        end else begin
            $display("TB_WEIGHTRAM_ARB_STRESS: %0d CHECK(S) FAILED (seed=%0d)", errors, seed);
            $fatal(1, "TB_WEIGHTRAM_ARB_STRESS: testbench FAILED (reproduce with +seed=%0d)", seed);
        end
    end

endmodule

// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_Basys3_Top.sv
// Canonical source: spikenaut-soc-sv/tb
// SoC-level testbench for spikenaut-soc-sv/rtl/Basys3_Top.sv
// (top module spikenaut_soc_basys3_top).
//
// Covers what the core unit testbenches structurally cannot: they drive
// step_en themselves, so nothing else in the repo exercises the SoC's own
// 1 ms divider or the UART-frame -> tick-domain handoff. See #57 / #60 / #62 and
// docs/timestep-contract.md.
//
// What this locks down:
//   1. Reset phase       — step_cnt / step_en / protocol pending state clear.
//   2. First-tick delay  — exactly STEP_DIV cycles after reset release.
//   3. Pulse width       — step_en high for exactly one fabric cycle.
//   4. Period            — exactly STEP_DIV cycles between every tick.
//   5. Frame delivery    — a complete 0xAA / 16-word UART frame is latched
//                          and reaches the N=16 LIF PE on the next tick.
//   6. Decay             — with no event, the membrane leaks back to 0.
//   7. Gated frame_send  — idle 1 ms ticks do not arm a UART response; a
//                          response fires only after a consumed host frame.
//   8. LED bitmap        — every committed N=16 spike bit is preserved (SW=0).
//   9. SW15 status mux   — 2FF sync latency, then status word from primitive
//                          refs; synchronized sw is published as aux.
//  11. Runtime RAM write — a 0xA5 host frame overwrites one INIT_FILE weight
//                          and one leak param; RAM we is not hard-tied 0.
//  12. Deferred writes   — a write landing mid-sweep is held until the PE is
//                          idle and does not steal the RAM port.
//  13. Wire-level frame  — (a) status_word[15:13] carries the OutputLayer's
//                          live one-hot result, by value, not by mirroring the
//                          hold register that drives it; (b) the real uart_tx
//                          line delivers exactly 36 bytes and then stops
//                          (GH#64, docs/host-soc-e2e.md).
//  14. Host RAM read    — a 0xA6 frame over the real UART echoes its request
//                          then streams big-endian RAM words off uart_tx
//                          (GH#113): the runtime 0xA5 writes read back, at
//                          least one 1 ms tick interrupts a long dump without
//                          corrupting it, the port grant is gated like the
//                          write grant mid-sweep, and target 3 stays silent.
//  15. STDP writeback    — SW14=0 leaves WeightRam untouched by STDP, even
//                          with live traces; SW14=1 applies the signed
//                          Bi–Poo LTP +1 update to the routed column after
//                          tick_done, and a host 0xA5 weight write that
//                          lands during the walk is held until stdp_busy
//                          clears (GH#70; restores the SoC-level coverage #103
//                          added as test 14 and #104 removed, GH#109).
//
// (2)-(4) are checked by a free-running monitor on EVERY tick of the run, not
// just at sampled points, so an intermittent divider glitch cannot slip past.
//
// Internal nodes (step_en, step_cnt, protocol pending state, PE membrane
// register file, and RAM address outputs) are
// observed by hierarchical reference rather than by adding debug ports to the
// synthesized top level.
//
// Reset polarity: the rst_n PORT is the physically active-high BTNC button
// (U18/CPU_RESET) and is inverted to the active-low `rst` inside the DUT, so
// this TB asserts reset by driving btn_rst = 1 and releases it with 0.
//
// $readmemh INIT_FILE paths are repo-root relative — run from the repo root.
//
// Stimulus is applied and sampled on negedge clk (mid-cycle) to avoid race
// conditions with the DUT's posedge-triggered always_ff blocks.

`timescale 1ns/1ps

// The INIT paths are module parameters so Vivado sim_core.tcl can pass absolute
// paths via set_property generic (XSim CWD is the sim run dir, not the repo
// root). Defaults are repo-root-relative for Verilator, matching the DUT's own
// defaults and tb_WeightRam_init / tb_NeuronParamRam_init.
module tb_spikenaut_soc_basys3_top #(
    parameter string WEIGHT_INIT = "spikenaut-core-sv/mem/merged_v2_weights.mem",
    parameter string THRESH_INIT = "spikenaut-core-sv/mem/merged_v2_thresholds.mem",
    parameter string LEAK_INIT   = "spikenaut-core-sv/mem/merged_v2_decay.mem",
    parameter string OUTPUT_WEIGHT_INIT = "spikenaut-core-sv/mem/merged_v2_output_weights.mem",
    parameter string ROUTE_INIT = "synapse-link-hdl/mem/aer_routes_identity_n16.mem"
);

    localparam int CLK_PERIOD   = 10;                     // 100 MHz
    localparam int CLK_FREQ     = 100_000_000;
    localparam int BAUD_RATE    = 115_200;
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;   // 868
    localparam int TICK_HZ      = 1000;
    localparam int STEP_DIV     = CLK_FREQ / TICK_HZ;     // 100_000
    localparam int NUM_NEURONS  = 16;
    localparam int SPIKE_TEST_NEURON = 5;

    // A full host frame is 33 UART bytes.  It intentionally spans multiple
    // 1 ms ticks at 115200 baud; the protocol FSM must wait for all payload
    // bytes rather than turning early bytes into raw spikes.
    localparam int SEQ_SLACK         = 16;
    localparam int SW_SYNC_LATENCY   = 2;

    // Mirrors SocProtocolFsm's default: four 10-bit UART character times.
    // Derived from BAUD_RATE rather than a second inline 115_200, and checked
    // against the DUT's actual parameter at the top of the run -- test 10's
    // half-window waits depend on this matching, and a silent drift would move
    // the mid-window sample outside the idle window and quietly stop
    // discriminating rx_abort from rx_busy.
    localparam int IDLE_TIMEOUT_CYCLES = 4 * 10 * CLKS_PER_BIT;
    // Mirror SocProtocolFsm's default write and read syncs.  Bound to the
    // DUT at the top of the run so a parameter change cannot silently
    // desync this TB.
    localparam logic [7:0] WRITE_SYNC_BYTE = 8'hA5;
    localparam logic [7:0] READ_SYNC_BYTE  = 8'hA6;

    // Ticks are at most STEP_DIV cycles apart, so any wait that exceeds this
    // bound means the divider is broken. Fail loudly with a cycle count
    // instead of hanging until an external job timeout with no diagnostic.
    localparam int TICK_WAIT_BOUND   = STEP_DIV + SEQ_SLACK;

    // ----------------------------------------------------------------
    // Wire-level response capture (test 13, GH#64).
    //
    // The response frame is 36 bytes and GH#64 does not move that: GH#72's
    // output-class flags are LED-only (status_word[15:13], docs/led-map.md).
    // tb_SocFrameGolden.sv pins the byte *layout* against the committed golden
    // vectors at the SocProtocolFsm boundary; what only this level can prove is
    // that the assembled chain -- FSM, SiliconBridge, UartTx, the serial line
    // itself -- delivers exactly those 36 bytes and then stops.
    // ----------------------------------------------------------------
    localparam int RESPONSE_BYTES = 36;
    // 8N1: start + 8 data + stop.
    localparam int UART_BITS_PER_BYTE = 10;
    localparam int UART_BYTE_CLKS     = UART_BITS_PER_BYTE * CLKS_PER_BIT;
    // Generous bound for the first start bit of a frame; within a frame the FSM
    // relaunches immediately, so this is slack, not a schedule.
    localparam int UART_START_BOUND   = 4 * UART_BYTE_CLKS;
    // How long the line must stay idle-high to call the frame finished. Longer
    // than one byte time, so "no 37th byte" is a stronger claim than "we did
    // not wait long enough to see one".
    localparam int UART_QUIET_CLKS    = 2 * UART_BYTE_CLKS;
    // OutputLayer sweeps NUM_NEURONS x NUM_CLASSES pairs plus pipeline
    // fill/drain; 80 is the bound tb_OutputLayer.sv uses.
    localparam int OUTPUT_CLASS_BOUND = 80;

    logic        clk;
    logic        btn_rst;        // drives the active-high rst_n port
    logic        uart_rx_line;
    logic        uart_tx_line;
    logic [15:0] sw;
    logic [15:0] led;

    int errors = 0;
    int unsigned first_tick_cycles;
    int unsigned frame_send_count;
    int unsigned aer_cfg_write_count;
    logic [NUM_NEURONS-1:0] expected_first_spikes;
    logic [NUM_NEURONS-1:0] seen_threshold_addr;
    logic [NUM_NEURONS-1:0] seen_leak_addr;
    logic [NUM_NEURONS-1:0] seen_weight_row;
    logic [$clog2(NUM_NEURONS)-1:0] expected_input_index;

    // Static copies for inject_host_strobe.  XSim rejects force/assign of
    // automatic task arguments (VRFC 10-3142); Verilator does not.
    logic [1:0]  force_host_wr_target;
    logic [7:0]  force_host_wr_addr;
    logic [15:0] force_host_wr_data;
    logic [NUM_NEURONS*16-1:0] force_protocol_stimuli;

    // Test 13 (GH#64): the demodulated response frame, plus the SoC-side
    // sources sampled on the same negedge the FSM's capture posedge sees. The
    // expectations are taken from the top-level nets (membrane_potentials,
    // spike_bitmap, sw_sync_1) and not from the FSM's own hold registers, so
    // this compares the wire against the design rather than against the
    // serializer's copy of itself.
    logic [7:0]  captured_frame [0:RESPONSE_BYTES-1];
    logic [NUM_NEURONS*16-1:0] expected_wire_potentials;
    logic [NUM_NEURONS-1:0]    expected_wire_spikes;
    logic [15:0]               expected_wire_aux;

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

    // Clock generation
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic check(input logic cond, input string msg);
        if ($isunknown(cond)) begin
            errors++;
            $display("FAIL (unknown state): %s", msg);
        end else if (!cond) begin
            errors++;
            $display("FAIL: %s", msg);
        end
    endtask

    task automatic check_int(input int unsigned actual,
                             input int unsigned expected,
                             input string msg);
        if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (expected %0d, got %0d)", msg, expected, actual);
        end
    endtask

    // ----------------------------------------------------------------
    // Free-running step_en monitor (tests 3-4)
    //
    // Checks pulse width and tick-to-tick period on EVERY tick of the run.
    // Both are deltas, so they are immune to which delta the monitor happened
    // to start counting in. The absolute first-tick latency (test 2) is
    // measured in the main sequence instead, where it is race-free.
    // ----------------------------------------------------------------
    int unsigned cyc;             // free-running fabric-cycle counter
    int unsigned last_tick_cyc;
    int unsigned tick_count;
    int unsigned width_run;
    logic suppress_tick_monitor;
    // Grant pulses while a dump runs — a fsm_rd_ack held past its
    // one-cycle port window shows up as a count above the word total.
    int unsigned rd_grant_count;

    initial begin
        cyc           = 0;
        last_tick_cyc = 0;
        tick_count    = 0;
        width_run     = 0;
        suppress_tick_monitor = 1'b0;
        rd_grant_count = 0;
    end

    always @(negedge clk) begin
        cyc++;
        if (dut.frame_send === 1'b1)
            frame_send_count++;
        if (dut.aer_cfg_we === 1'b1)
            aer_cfg_write_count++;
        if (dut.u_protocol_fsm.dump_active === 1'b1 && dut.fsm_rd_ack === 1'b1)
            rd_grant_count++;
        if (!suppress_tick_monitor && dut.step_en === 1'b1) begin
            width_run++;
            tick_count++;
            if (tick_count > 1)
                check_int(cyc - last_tick_cyc, STEP_DIV,
                          "step_en period must be exactly STEP_DIV");
            last_tick_cyc = cyc;
        end else if (!suppress_tick_monitor && width_run != 0) begin
            check_int(width_run, 1, "step_en must be exactly one cycle wide");
            width_run = 0;
        end
    end

    // Send one 8N1 byte, LSB first, at BAUD_RATE. Idle line is high.
    task automatic uart_send_byte(input logic [7:0] b);
        int i;
        begin
            uart_rx_line = 1'b0;                       // start bit
            repeat (CLKS_PER_BIT) @(negedge clk);
            for (i = 0; i < 8; i++) begin
                uart_rx_line = b[i];
                repeat (CLKS_PER_BIT) @(negedge clk);
            end
            uart_rx_line = 1'b1;                       // stop bit
            repeat (CLKS_PER_BIT) @(negedge clk);
        end
    endtask

    // Host contract: 0xAA followed by 16 Q8.8 big-endian words.  One selected
    // lane carries 0x0001 and all others zero, making the SoC's binary-event
    // / input-column selection policy observable without a raw rx_valid hook.
    // Host write contract (#63): 0xA5 + target + addr + Q8.8 big-endian word.
    // Target 0=weight, 1=threshold, 2=leak, 3=AER route table. Distinct sync from the 0xAA
    // stimulus frame so the protocol FSM can share one byte pipe.
    // One-cycle host write strobe while the PE is busy.  Fabric-rate force
    // on the FSM outputs (same style as the LED bitmap force in test 8)
    // so the hold path can be tested inside the ~18-cycle sweep; UART
    // cannot finish a 5-byte frame in that window.
    task automatic inject_host_strobe(
        input logic [1:0] target,
        input logic [7:0] addr,
        input logic [15:0] data
    );
        begin
            force_host_wr_target = target;
            force_host_wr_addr   = addr;
            force_host_wr_data   = data;
            @(negedge clk);
            force dut.host_wr_en     = 1'b1;
            force dut.host_wr_target = force_host_wr_target;
            force dut.host_wr_addr   = force_host_wr_addr;
            force dut.host_wr_data   = force_host_wr_data;
            @(negedge clk);
            release dut.host_wr_en;
            release dut.host_wr_target;
            release dut.host_wr_addr;
            release dut.host_wr_data;
        end
    endtask

    task automatic uart_send_write_frame(
        input logic [7:0] target,
        input logic [7:0] addr,
        input logic [15:0] data
    );
        begin
            uart_send_byte(WRITE_SYNC_BYTE);
            uart_send_byte(target);
            uart_send_byte(addr);
            uart_send_byte(data[15:8]);
            uart_send_byte(data[7:0]);
        end
    endtask

    task automatic uart_send_stimulus_frame(input int active_lane);
        begin
            uart_send_byte(8'hAA);
            for (int lane = 0; lane < NUM_NEURONS; lane++) begin
                if (lane == active_lane) begin
                    uart_send_byte(8'h00);
                    uart_send_byte(8'h01);
                end else begin
                    uart_send_byte(8'h00);
                    uart_send_byte(8'h00);
                end
            end
        end
    endtask

    task automatic wait_for_stimuli_pending();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.stimuli_pending === 1'b1) break;
                if (waited > (2 * CLKS_PER_BIT + SEQ_SLACK))
                    $fatal(1, "wait_for_stimuli_pending: completed frame was not latched within %0d cycles", waited);
            end
        end
    endtask

    // Advance to the negedge at which step_en reads high. step_en is a
    // register set at posedge P, so at this point the tick is still "in
    // flight" — the cores consume it at posedge P+1. Bounded: $fatal if no
    // tick arrives within TICK_WAIT_BOUND cycles (broken divider).
    task automatic wait_for_tick();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.step_en === 1'b1) break;
                if (waited >= TICK_WAIT_BOUND)
                    $fatal(1, "wait_for_tick: no step_en within %0d cycles (bound %0d)",
                           waited, TICK_WAIT_BOUND);
            end
        end
    endtask

    // Record the address presented for the next registered RAM read.  The
    // calling test sequence owns these maps, so coverage collection does not
    // depend on ordering between a separate monitor and the main process.
    task automatic record_sweep_addresses();
        begin
            if (dut.threshold_addr < NUM_NEURONS)
                seen_threshold_addr[dut.threshold_addr[3:0]] = 1'b1;
            if (dut.leak_addr < NUM_NEURONS)
                seen_leak_addr[dut.leak_addr[3:0]] = 1'b1;
            for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
                if (dut.weight_addr == neuron * NUM_NEURONS + expected_input_index)
                    seen_weight_row[neuron] = 1'b1;
            end
        end
    endtask

    // Advance past the posedge that actually applies the tick, so the cores'
    // post-tick state (membrane_potential, protocol pending state) is observable.
    task automatic wait_tick_applied();
        begin
            wait_for_tick();
            @(negedge clk);
        end
    endtask

    // Sample the one-cycle host write strobe mid-cycle while the UART
    // frame is still on the wire.  After uart_send_write_frame returns the
    // strobe has already fallen, so a later peek cannot prove we toggled.
    task automatic wait_for_host_write(
        input logic [1:0] expected_target,
        input string msg
    );
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.host_wr_en === 1'b1) begin
                    check(dut.host_wr_target === expected_target,
                          {msg, ": wr_target must match the frame"});
                    check(dut.weight_we === (expected_target == 2'd0),
                          {msg, ": weight we must follow target 0"});
                    check(dut.leak_we === (expected_target == 2'd2),
                          {msg, ": leak we must follow target 2"});
                    check(dut.aer_cfg_we === (expected_target == 2'd3),
                          {msg, ": AER cfg_we must follow target 3"});
                    break;
                end
                if (waited > (5 * 11 * CLKS_PER_BIT + SEQ_SLACK))
                    $fatal(1, "%s: host_wr_en not seen within %0d cycles", msg, waited);
            end
        end
    endtask

    // Host read contract (#113): 0xA6 + target + start addr + big-endian
    // 16-bit word count.  A valid request streams back the same five bytes
    // as an echoed header, then len big-endian words, address ascending.
    task automatic uart_send_read_frame(
        input logic [7:0] target,
        input logic [7:0] addr,
        input logic [15:0] len
    );
        begin
            uart_send_byte(READ_SYNC_BYTE);
            uart_send_byte(target);
            uart_send_byte(addr);
            uart_send_byte(len[15:8]);
            uart_send_byte(len[7:0]);
        end
    endtask

    // Demodulate one dump byte off the real serial line and compare it,
    // test-13 style: the FSM -> SiliconBridge -> UartTx chain and its 8N1
    // framing are in the loop, not just the FSM's tx_data port.
    task automatic expect_dump_byte(input logic [7:0] expected, input string msg);
        logic [7:0] captured;
        bit         byte_ok;
        begin
            uart_capture_byte(captured, byte_ok);
            if (!byte_ok) begin
                errors++;
                $display("FAIL: %s (no framed byte on uart_tx)", msg);
            end else if (captured !== expected) begin
                errors++;
                $display("FAIL: %s (got 0x%02h, expected 0x%02h)",
                         msg, captured, expected);
            end
        end
    endtask

    // Check one complete dump frame off the wire: echoed 5-byte header,
    // then len big-endian payload words.  Expectations come from the DUT's
    // own RAM arrays, mirroring the RTL's address progression — the 8-bit
    // start address increments and wraps inside the same 256-entry space
    // for all three readable banks (NEURON_ADDR_W == WEIGHT_ADDR_W == 8).
    task automatic check_dump_frame(
        input logic [7:0] target,
        input logic [7:0] addr,
        input int unsigned len,
        input string msg
    );
        begin
            expect_dump_byte(READ_SYNC_BYTE, {msg, ": header sync"});
            expect_dump_byte(target,         {msg, ": header target"});
            expect_dump_byte(addr,           {msg, ": header addr"});
            expect_dump_byte(8'(len[15:8]),  {msg, ": header len_hi"});
            expect_dump_byte(8'(len[7:0]),   {msg, ": header len_lo"});
            for (int w = 0; w < len; w++) begin
                automatic logic [7:0]  word_addr = 8'(addr + w);
                automatic logic [15:0] exp_word;
                case (target)
                    8'h01:   exp_word = dut.u_npram_threshold.mem[word_addr];
                    8'h02:   exp_word = dut.u_npram_leak.mem[word_addr];
                    default: exp_word = dut.u_wram.mem[word_addr];
                endcase
                expect_dump_byte(exp_word[15:8],
                                 {msg, $sformatf(": word %0d hi", w)});
                expect_dump_byte(exp_word[7:0],
                                 {msg, $sformatf(": word %0d lo", w)});
            end
        end
    endtask

    task automatic wait_for_route_resolution();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                if (dut.route_resolved === 1'b1) break;
                if (waited > 16)
                    $fatal(1, "wait_for_route_resolution: route did not resolve within %0d cycles", waited);
            end
        end
    endtask

    // `step_en` starts the PE; its registered RAM read and 16 slots complete
    // shortly afterward.  Bound this wait so a bad sub-cycle FSM does not
    // turn the free CI test into a silent timeout.
    task automatic wait_lif_sweep_done();
        int unsigned waited;
        begin
            waited = 0;
            forever begin
                @(negedge clk);
                waited++;
                record_sweep_addresses();
                if (dut.u_lif_array.tick_done === 1'b1) break;
                if (waited > NUM_NEURONS + 2)
                    $fatal(1, "wait_lif_sweep_done: no tick_done within %0d cycles", waited);
            end
        end
    endtask

    // STDP writeback starts the cycle after tick_done and walks one column.
    // Bound: 2 cycles/read * 16 + update/handoff + 16 writes, plus slack.
    // Always sample one cycle first so a call on the tick_done negedge does
    // not return before the engine has left IDLE.
    task automatic wait_stdp_idle();
        int unsigned waited;
        begin
            @(negedge clk);
            waited = 0;
            while (dut.stdp_busy === 1'b1) begin
                @(negedge clk);
                waited++;
                if (waited > 8 * NUM_NEURONS + 16)
                    $fatal(1, "wait_stdp_idle: still busy after %0d cycles", waited);
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Test 13 helpers (GH#64): demodulate the real serial line.
    // ----------------------------------------------------------------

    // Block until the transmit line has been continuously idle-high for a full
    // quiet window.  Earlier tests leave a ~3.1 ms response in flight, so a
    // wire-level capture has to start from a known-idle line or it would latch
    // onto the tail of the previous frame.
    task automatic wait_uart_line_idle();
        int unsigned quiet;
        int unsigned waited;
        begin
            quiet  = 0;
            waited = 0;
            while (quiet < UART_QUIET_CLKS) begin
                @(negedge clk);
                waited++;
                if (uart_tx_line === 1'b1 &&
                    dut.u_protocol_fsm.tx_frame_active === 1'b0)
                    quiet++;
                else
                    quiet = 0;
                // Two whole frames plus the quiet window: long enough for any
                // legitimate in-flight response to drain.
                if (waited > (2 * RESPONSE_BYTES * UART_BYTE_CLKS + UART_QUIET_CLKS))
                    $fatal(1, "wait_uart_line_idle: transmit line never went idle (%0d cycles)", waited);
            end
        end
    endtask

    // Receive one 8N1 character: find the start bit, then sample each data bit
    // at its midpoint, LSB first.  UartTx registers `tx`, so the start bit is
    // one fabric cycle wider than a data bit; sampling mid-cell leaves ~half a
    // bit time of margin, so that skew cannot move a sample into a neighbour.
    task automatic uart_capture_byte(output logic [7:0] value, output bit ok);
        int unsigned waited;
        begin
            value = '0;
            ok    = 1'b0;

            waited = 0;
            while (uart_tx_line !== 1'b0 && waited < UART_START_BOUND) begin
                @(negedge clk);
                waited++;
            end
            if (uart_tx_line !== 1'b0)
                return;

            // Midpoint of the start bit, then confirm it is still low: a
            // one-cycle glitch on an idle line is not a frame.
            repeat (CLKS_PER_BIT / 2) @(negedge clk);
            if (uart_tx_line !== 1'b0) begin
                errors++;
                $display("FAIL: test 13: start bit did not hold low to its midpoint");
                return;
            end

            for (int bit_index = 0; bit_index < 8; bit_index++) begin
                repeat (CLKS_PER_BIT) @(negedge clk);
                value[bit_index] = uart_tx_line;
            end

            repeat (CLKS_PER_BIT) @(negedge clk);
            if (uart_tx_line !== 1'b1) begin
                errors++;
                $display("FAIL: test 13: stop bit was not high for byte 0x%02h", value);
                return;
            end
            ok = 1'b1;
        end
    endtask

    // The output layer starts on lif_tick_done and needs a bounded sweep before
    // its one-hot result is committed and latched into status_word[15:13].
    task automatic wait_output_class_done();
        int unsigned waited;
        begin
            waited = 0;
            while (dut.output_class_valid !== 1'b1 && waited < OUTPUT_CLASS_BOUND) begin
                @(negedge clk);
                waited++;
            end
            if (dut.output_class_valid !== 1'b1)
                $fatal(1, "wait_output_class_done: no output_class_valid within %0d cycles", OUTPUT_CLASS_BOUND);
        end
    endtask

    // Byte `index` of the response frame, derived from the snapshot taken on the
    // FSM's capture edge.  Layout (docs/host-soc-e2e.md, GH#64):
    //   [0..31]  16 potentials, signed Q8.8, lane 0 first, big-endian per word
    //   [32..33] spike-flag word, big-endian, bit i = neuron i
    //   [34..35] aux word (synchronized switch bus), big-endian
    function automatic logic [7:0] expected_wire_byte(input int index);
        int lane;
        // The FSM widens spike_flags to WORD_WIDTH before serializing it; with
        // NUM_NEURONS == WORD_WIDTH that is the identity, but naming the widened
        // word keeps this function correct if NUM_NEURONS is ever narrowed.
        logic [15:0] spike_word;
        begin
            spike_word = 16'(expected_wire_spikes);
            if (index < 2 * NUM_NEURONS) begin
                lane = index / 2;
                expected_wire_byte = (index % 2 == 0)
                    ? expected_wire_potentials[lane*16 + 8 +: 8]
                    : expected_wire_potentials[lane*16 +: 8];
            end else if (index == 2 * NUM_NEURONS) begin
                expected_wire_byte = spike_word[15:8];
            end else if (index == 2 * NUM_NEURONS + 1) begin
                expected_wire_byte = spike_word[7:0];
            end else if (index == 2 * NUM_NEURONS + 2) begin
                expected_wire_byte = expected_wire_aux[15:8];
            end else begin
                expected_wire_byte = expected_wire_aux[7:0];
            end
        end
    endfunction

    initial begin
        // ------------------------------------------------------------
        // Test 1: reset phase
        // ------------------------------------------------------------
        btn_rst      = 1'b1;    // active-high button pressed => DUT in reset
        uart_rx_line = 1'b1;    // UART idle
        sw           = '0;      // SW15=0 keeps the combinational spike LED view
        frame_send_count    = 0;
        aer_cfg_write_count = 0;
        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        repeat (5) @(negedge clk);

        check_int(dut.u_protocol_fsm.IDLE_TIMEOUT_CYCLES, IDLE_TIMEOUT_CYCLES,
                  "TB idle-timeout mirror must match the DUT parameter");
        check(dut.u_protocol_fsm.WRITE_SYNC_BYTE === WRITE_SYNC_BYTE,
              "TB write-sync mirror must match the DUT parameter");
        check(dut.u_protocol_fsm.READ_SYNC_BYTE === READ_SYNC_BYTE,
              "TB read-sync mirror must match the DUT parameter");
        check(dut.step_en === 1'b0,       "reset: step_en must be low");
        check(dut.step_cnt === '0,        "reset: step_cnt must be cleared");
        check(dut.stimuli_pending === 1'b0,
              "reset: completed-frame pending state must be cleared");
        check(dut.response_armed === 1'b0,
              "reset: response_armed must be cleared");
        check(dut.frame_send === 1'b0,    "reset: frame_send must be low");
        check(led === 16'h0000,           "reset: led must be cleared");

        // ------------------------------------------------------------
        // Test 2: first tick lands exactly STEP_DIV cycles after release
        //
        // Counted here rather than in the monitor so the measurement is a
        // single-process, race-free sequence: reset is released at this
        // negedge, and the loop below starts counting at the next one.
        // ------------------------------------------------------------
        btn_rst = 1'b0;
        first_tick_cycles = 0;
        forever begin
            @(negedge clk);
            first_tick_cycles++;
            if (dut.step_en === 1'b1) break;
            if (first_tick_cycles >= TICK_WAIT_BOUND)
                $fatal(1, "first tick: no step_en within %0d cycles of reset release (bound %0d)",
                       first_tick_cycles, TICK_WAIT_BOUND);
        end
        check_int(first_tick_cycles, STEP_DIV,
                  "first step_en must be STEP_DIV cycles after reset release");

        // ------------------------------------------------------------
        // Tests 3-4 run in the monitor. Let two more clean ticks elapse.
        // ------------------------------------------------------------
        wait_tick_applied();
        wait_tick_applied();
        check_int(tick_count, 3, "monitor must have observed three ticks");
        check_int(frame_send_count, 0,
                  "idle ticks before any host frame must not arm frame_send");
        check(dut.u_protocol_fsm.tx_active === 1'b0,
              "idle ticks must not start a UART response");
        check(dut.bridge_tx_send === 1'b0,
              "idle ticks must not pulse SiliconBridge tx_send");

        // No UART event has been delivered yet, so every PE slot must be idle.
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            check(dut.u_lif_array.membrane_potential[neuron] === '0,
                  "membrane must stay 0 while no spike event arrives");
        end

        // ------------------------------------------------------------
        // Test 5: a complete UART frame reaches the next logical tick
        //
        // The 33-byte frame lasts longer than one tick at 115200 baud.  Its
        // early bytes must not produce a spike; only the completed frame may
        // arm one selected input column for the following step_en.
        // ------------------------------------------------------------
        expected_input_index = '0;
        uart_send_byte(8'hAA);
        uart_send_byte(8'h00);
        uart_send_byte(8'h01);
        check(dut.stimuli_pending === 1'b0,
              "partial UART frame must not have been consumed as a raw spike");
        for (int lane = 1; lane < NUM_NEURONS; lane++) begin
            uart_send_byte(8'h00);
            uart_send_byte(8'h00);
        end
        wait_for_stimuli_pending();
        check(dut.protocol_stimuli[0 +: 16] === 16'h0001,
              "protocol frame lane 0 must decode as big-endian Q8.8");
        for (int lane = 1; lane < NUM_NEURONS; lane++) begin
            check(dut.protocol_stimuli[lane*16 +: 16] === '0,
                  "inactive protocol lanes must retain their decoded zero words");
        end
        check(dut.stimulus_input_index === 4'd0,
              "lowest active protocol lane must select input column zero");

        // ------------------------------------------------------------
        // Test 5b: distinguish status bits 5 and 6 (#65 review).
        //
        // The first host frame is committed but no tick has consumed it yet,
        // so stimuli_pending is high while response_armed is still low -- the
        // only window in this run where the two differ.  Once each has been
        // high once, the ~64 ms stretcher holds both for the rest of the
        // ~11 ms simulation and a swapped binding becomes invisible, so the
        // check has to happen here rather than in test 9.
        //
        // sw only feeds the LED mux and aux_state, and aux_state is sampled
        // only on frame_send (which needs a tick first), so this excursion
        // cannot perturb the sequence.
        // ------------------------------------------------------------
        check(dut.stimuli_pending === 1'b1 && dut.response_armed === 1'b0,
              "test 5b: a committed frame must be pending but not yet armed");
        sw = 16'h8000;
        repeat (SW_SYNC_LATENCY + 1) @(negedge clk);
        check(led[5] === 1'b1,
              "test 5b: status bit 5 must be stimuli_pending, high in this window");
        check(led[6] === 1'b0,
              "test 5b: status bit 6 must be response_armed, still low in this window");
        sw = 16'h0000;
        repeat (SW_SYNC_LATENCY + 1) @(negedge clk);
        check(dut.stimuli_pending === 1'b1,
              "test 5b: the mode excursion must not consume the pending frame");
        check(dut.stimulus_event === 1'b1,
              "a completed non-zero stimulus frame must arm a binary PE event");

        seen_threshold_addr = '0;
        seen_leak_addr      = '0;
        seen_weight_row     = '0;
        // At this negedge step_en is high and the PE is still idle, so it
        // presents row 0 for the first registered RAM read.  The next
        // negedge observes the prefetched row 1 after the tick is applied.
        wait_for_tick();
        record_sweep_addresses();
        @(negedge clk);
        record_sweep_addresses();
        check(dut.stimuli_pending === 1'b0,
              "step_en must consume exactly one completed stimulus frame");
        check(dut.response_armed === 1'b1,
              "consuming a host frame must arm the post-sweep response");
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b1,
              "lif_tick_done after a consumed host frame must pulse frame_send");
        @(negedge clk); // let the free-running monitor retire this pulse
        check_int(frame_send_count, 1,
                  "exactly one response must be armed for the first consumed frame");

        expected_first_spikes = '0;
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            // GH#73: LifNeuronArray now reads weight/threshold as signed
            // Q8.8, so Dale I rows (negative col0 words, e.g. 0xFF00)
            // correctly compare below their (positive) threshold instead of
            // misreading as a huge positive integer.
            expected_first_spikes[neuron] =
                ($signed(dut.u_wram.mem[neuron * NUM_NEURONS]) >=
                 $signed(dut.u_npram_threshold.mem[neuron]));
            check(dut.u_lif_array.membrane_potential[neuron] ==
                  dut.u_wram.mem[neuron * NUM_NEURONS],
                  "broadcast event must integrate each neuron row's input-column-0 weight");
        end
        check(led === expected_first_spikes,
              "LED bitmap must equal the merged_v2 per-neuron threshold outcomes");
        check(expected_first_spikes === 16'h0000,
              {"exp-025 Dale bank: signed col0 weights (E ~1.2, I ~-1.0) are below every ",
               "per-neuron threshold (~1.6 / ~0.45) -- no false spikes from I rows"});
        check(seen_threshold_addr == {NUM_NEURONS{1'b1}},
              "PE sweep must request all 16 threshold RAM entries");
        check(seen_leak_addr == {NUM_NEURONS{1'b1}},
              "PE sweep must request all 16 leak RAM entries");
        check(seen_weight_row == {NUM_NEURONS{1'b1}},
              "PE sweep must request all 16 input-column-0 weight rows");

        // ------------------------------------------------------------
        // Test 6: with no further event, every neuron applies its own leak.
        // ------------------------------------------------------------
        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b0,
              "a leak-only tick must not re-arm frame_send");
        check_int(frame_send_count, 1,
                  "idle leak tick must not increment the gated response count");
        for (int neuron = 0; neuron < NUM_NEURONS; neuron++) begin
            // GH#73: leak is signed and symmetric around the 0 resting
            // potential, mirroring LifNeuronArray's leak_wide/decayed_wide
            // logic exactly -- an I row's negative membrane (e.g. exp-025's
            // -1.0 Q8.8 rows) now decays back *up* toward 0, not just a
            // positive membrane decaying down.
            // Mirrors LifNeuronArray's own wide-domain arithmetic exactly
            // (sign-selected add/subtract + sign-flip clamp) rather than a
            // magnitude compare with a plain 16-bit negation: negating
            // 16'h8000 (the most-negative Q8.8 value) in 16 bits overflows
            // back to itself, which would silently diverge from the RTL for
            // a future bank containing that exact word. The RTL never hits
            // this because its own decay arithmetic is done in one extra
            // guard bit; give the reference model here the same guard bit.
            automatic logic signed [16:0] mem1_wide =
                $signed(dut.u_wram.mem[neuron * NUM_NEURONS]);
            automatic logic signed [16:0] lk_wide =
                $signed(dut.u_npram_leak.mem[neuron]);
            automatic logic signed [16:0] expected_wide;
            automatic logic signed [15:0] expected_mem2;

            if (expected_first_spikes[neuron]) begin
                check(dut.u_lif_array.membrane_potential[neuron] === '0,
                      "a prior spike must reset that row on the next tick");
            end else begin
                expected_wide = mem1_wide[16] ? (mem1_wide + lk_wide) : (mem1_wide - lk_wide);
                if (expected_wide[16] != mem1_wide[16])
                    expected_wide = '0;
                expected_mem2 = expected_wide[15:0];
                check(dut.u_lif_array.membrane_potential[neuron] == expected_mem2,
                      "each non-spiking row must apply its own row's signed, symmetric leak");
            end
        end

        // ------------------------------------------------------------
        // Test 7: a controlled model row selects a non-zero host frame lane,
        // creates a real PE spike, and verifies the one-tick refractory reset.
        // ------------------------------------------------------------
        // Test 5 above keeps its merged_v2 image assertions.  This controlled
        // row is deliberately configured only after those checks, so it
        // proves the PE's commit/refractory behavior without changing the
        // shipped-image coverage.
        dut.u_wram.mem[SPIKE_TEST_NEURON * NUM_NEURONS + SPIKE_TEST_NEURON] = 16'h0001;
        dut.u_npram_threshold.mem[SPIKE_TEST_NEURON]    = 16'h0001;
        dut.u_npram_leak.mem[SPIKE_TEST_NEURON]         = 16'h0000;
        expected_input_index = $clog2(NUM_NEURONS)'(SPIKE_TEST_NEURON);
        uart_send_stimulus_frame(SPIKE_TEST_NEURON);
        wait_for_stimuli_pending();
        check(dut.stimulus_input_index === SPIKE_TEST_NEURON,
              "non-zero protocol lane must select its matching matrix input column");
        check(dut.stimulus_event === 1'b1,
              "selected non-zero protocol lane must create the PE event");
        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b1,
              "second consumed host frame must arm another gated response");
        @(negedge clk); // let the free-running monitor retire this pulse
        check_int(frame_send_count, 2,
                  "each consumed host frame must arm exactly one response");
        check(dut.u_lif_array.spike_bitmap[SPIKE_TEST_NEURON] === 1'b1,
              "controlled row must commit a real spike bit");
        check(led[SPIKE_TEST_NEURON] === 1'b1,
              "controlled PE spike bit must reach its LED bit");

        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b0,
              "refractory follow-up tick must not re-arm frame_send");
        check_int(frame_send_count, 2,
                  "refractory follow-up tick must not increment the gated response count");
        check(dut.u_lif_array.membrane_potential[SPIKE_TEST_NEURON] === '0,
              "spiking row must reset to zero on the following refractory tick");

        // ------------------------------------------------------------
        // Test 8: LED bus preserves every committed N=16 bitmap bit.
        // ------------------------------------------------------------
        check(led === 16'h0000,
              "no-input refractory follow-up must clear the complete LED bitmap");
        force dut.spike_bitmap = 16'hA55A;
        #1;
        check(led === 16'hA55A,
              "LED bus must preserve every committed spike bitmap bit");
        check(sw === 16'h0000,
              "existing LED checks require SW15=0 spike mode");
        release dut.spike_bitmap;

        // ------------------------------------------------------------
        // Test 9: SW15 2FF latency, status word from primitive refs, aux.
        // Do not compare led against u_status_leds.status_word (tautology).
        // ------------------------------------------------------------
        force dut.spike_bitmap = 16'h5AA5;
        #1;
        check(led === 16'h5AA5,
              "test 9: distinguishable spike bitmap must still drive LED in spike mode");
        sw = 16'hA5A5; // SW15=1 plus a live aux pattern for bytes 34-35
        check(led === 16'h5AA5,
              "test 9: SW15 must not switch the LED mux on the same cycle");
        repeat (SW_SYNC_LATENCY - 1) @(negedge clk);
        check(led === 16'h5AA5,
              "test 9: first sync flop must keep spike mode");
        @(negedge clk);
        check(dut.sw_sync_1 === 16'hA5A5,
              "test 9: sw_sync_1 must present the switch bus after 2FF latency");
        check(led[0] === dut.u_status_leds.tick_cnt[8],
              "test 9: status[0] must follow tick_cnt[8]");
        check(led[1] === dut.u_status_leds.rx_busy_held,
              "test 9: status[1] must follow rx_busy_held");
        check(led[2] === dut.u_status_leds.rx_commit_held,
              "test 9: status[2] must follow rx_commit_held");
        check(led[3] === dut.u_status_leds.ingress_fault_sticky,
              "test 9: status[3] must follow ingress_fault_sticky");
        check(led[4] === dut.u_status_leds.tx_frame_held,
              "test 9: status[4] must follow tx_frame_held");
        check(led[5] === dut.u_status_leds.stimuli_pending_held,
              "test 9: status[5] must follow stimuli_pending_held");
        check(led[6] === dut.u_status_leds.response_armed_held,
              "test 9: status[6] must follow response_armed_held");
        check(led[7] === |dut.u_status_leds.spike_hold,
              "test 9: status[7] must be any_spike from spike_hold");
        check(led[12:8] === 5'($countones(dut.u_status_leds.spike_hold)),
              "test 9: status[12:8] must be countones(spike_hold)");
        check(led[15:13] === dut.u_status_leds.output_class_hold,
              "test 9: status[15:13] must follow the output-layer hold register (GH#72)");

        // The checks above mirror led against u_status_leds internals, so a
        // wrong Basys3_Top port binding moves both operands together and
        // passes.  These name expected VALUES instead.
        // Heartbeat counts logical ticks, so after ~11 of them tick_cnt[8] is
        // still low.  Sample three times 256 fabric clocks apart: if step_en
        // were mis-bound to something that pulses every clock, tick_cnt[8]
        // would have a 512-clock period and at least one of these samples
        // would read high.  A single sample would be a coin flip.
        check(led[0] === 1'b0,
              "test 9: heartbeat must be low after ~11 logical ticks");
        repeat (256) @(negedge clk);
        check(led[0] === 1'b0,
              "test 9: heartbeat must not advance on fabric clocks (sample 2)");
        repeat (256) @(negedge clk);
        check(led[0] === 1'b0,
              "test 9: heartbeat must not advance on fabric clocks (sample 3)");
        check(led[2] === 1'b1,
              "test 9: accepted host frames must have latched the commit bit");
        check(led[3] === 1'b0,
              "test 9: no idle timeout has occurred, so the sticky abort bit must be clear");
        check(led[7] === 1'b1,
              "test 9: spikes have been committed, so any_spike must be set");
        release dut.spike_bitmap;

        uart_send_stimulus_frame(SPIKE_TEST_NEURON);
        wait_for_stimuli_pending();
        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.frame_send === 1'b1,
              "test 9: consumed host frame must still arm a response");
        @(negedge clk); // FSM consumes the combo strobe and snapshots aux
        // A prior 36-byte response may still be on the wire (~3.125 ms), so
        // this trigger is either the active snapshot or the latest-wins pend.
        check((dut.u_protocol_fsm.active_aux_state === 16'hA5A5) ||
              (dut.u_protocol_fsm.pending_aux_state === 16'hA5A5),
              "test 9: synchronized sw must reach the host response aux word");

        // ------------------------------------------------------------
        // Test 10: rx_abort actually reaches status bit 3 (#65 review).
        //
        // Test 9 can only prove bit 3 is low.  Drive it high from the UART
        // wire -- abandon a frame after its sync byte and let the FSM's
        // inter-byte idle timeout fire -- so the top-level rx_abort binding is
        // checked by a 0 -> 1 transition rather than by a mirror comparison.
        //
        // Note the analogous rx_busy check is not useful here: led[1] latched
        // high during the first host frame and the ~64 ms stretch window
        // outlives this ~11 ms simulation, so it can no longer transition.
        // ------------------------------------------------------------
        check(led[3] === 1'b0, "test 10: abort bit must still be clear before the abandon");
        uart_send_byte(8'hAA);   // sync only; never completes the payload

        // The FSM is now in RX_COLLECT with rx_busy high but no abort yet.
        // Checking bit 3 is still low HERE is what distinguishes a binding to
        // rx_abort from one to rx_busy -- without it, wiring bit 3 to rx_busy
        // passes the whole sequence.
        repeat (IDLE_TIMEOUT_CYCLES / 2) @(negedge clk);
        check(dut.rx_busy === 1'b1,
              "test 10: the abandoned frame must leave the receive FSM busy");
        check(led[3] === 1'b0,
              "test 10: a frame still inside the idle window must not look like an abort");

        repeat ((IDLE_TIMEOUT_CYCLES / 2) + SEQ_SLACK) @(negedge clk);
        check(led[3] === 1'b1,
              "test 10: an abandoned host frame must light the sticky abort bit");

        // Sticky, not stretched: it must survive until a frame is accepted.
        repeat (IDLE_TIMEOUT_CYCLES) @(negedge clk);
        check(led[3] === 1'b1,
              "test 10: the abort bit must stay lit until the next accepted frame");
        uart_send_stimulus_frame(SPIKE_TEST_NEURON);
        wait_for_stimuli_pending();
        check(led[3] === 1'b0,
              "test 10: an accepted host frame must clear the sticky abort bit");

        // ------------------------------------------------------------
        // Test 11: host runtime write (#63)
        //
        // Drain the pending stimulus from test 10 so the PE is idle, then
        // overwrite a weight and a leak that earlier merged_v2 checks do
        // not depend on.  INIT_FILE cold-start stays in place; we is muxed
        // from SocProtocolFsm rather than tied to 0.
        // ------------------------------------------------------------
        wait_tick_applied();
        wait_lif_sweep_done();
        check(dut.u_lif_array.sweep_state === 2'd0,
              "test 11: PE must be idle before the host write");
        check(dut.u_wram.we === 1'b0,
              "test 11: weight we must be low while the PE owns the address");
        check(dut.u_wram.addr === dut.weight_addr,
              "test 11: idle RAM addr must follow the PE read path");

        begin
            localparam logic [7:0] WRITE_WEIGHT_ADDR = 8'h01;
            localparam logic [7:0] WRITE_LEAK_ADDR   = 8'h0F;
            localparam logic [15:0] WRITE_WEIGHT_DATA = 16'hBEEF;
            localparam logic [15:0] WRITE_LEAK_DATA   = 16'h00A5;
            logic [15:0] weight_before;
            logic [15:0] leak_before;

            weight_before = dut.u_wram.mem[WRITE_WEIGHT_ADDR];
            leak_before   = dut.u_npram_leak.mem[WRITE_LEAK_ADDR];
            check(weight_before !== WRITE_WEIGHT_DATA,
                  "test 11: INIT_FILE weight must differ from the overwrite value");
            check(leak_before !== WRITE_LEAK_DATA,
                  "test 11: INIT_FILE leak must differ from the overwrite value");

            fork
                uart_send_write_frame(8'h00, WRITE_WEIGHT_ADDR, WRITE_WEIGHT_DATA);
                wait_for_host_write(2'd0, "test 11 weight");
            join
            check(dut.u_wram.mem[WRITE_WEIGHT_ADDR] === WRITE_WEIGHT_DATA,
                  "test 11: host must overwrite one INIT_FILE weight at runtime");
            check(dut.u_wram.we === 1'b0,
                  "test 11: weight we must return low after the one-cycle strobe");
            check(dut.u_wram.addr === dut.weight_addr,
                  "test 11: weight addr must return to the PE path after the write");

            fork
                uart_send_write_frame(8'h02, WRITE_LEAK_ADDR, WRITE_LEAK_DATA);
                wait_for_host_write(2'd2, "test 11 leak");
            join
            check(dut.u_npram_leak.mem[WRITE_LEAK_ADDR] === WRITE_LEAK_DATA,
                  "test 11: host must overwrite one INIT_FILE leak at runtime");
            check(dut.u_npram_leak.we === 1'b0,
                  "test 11: leak we must return low after the one-cycle strobe");
            check(dut.u_npram_leak.addr === dut.leak_addr,
                  "test 11: leak addr must return to the PE path after the write");
        end

        // ------------------------------------------------------------
        // Test 11b (#73 follow-up): a sign-bit-set threshold write must be
        // rejected, not stored -- LifNeuronArray's threshold compare is
        // signed, so a negative threshold would make an idle neuron spike
        // continuously. A non-negative write to the same address must
        // still commit normally right after, proving the guard is
        // sign-specific, not a general threshold-write block.
        // ------------------------------------------------------------
        begin
            localparam logic [7:0] WRITE_THRESH_ADDR        = 8'h03;
            localparam logic [15:0] WRITE_THRESH_REJECT_DATA = 16'hF000;  // sign bit set (-16.0)
            localparam logic [15:0] WRITE_THRESH_ACCEPT_DATA = 16'h0200;  // 2.0
            logic [15:0] thresh_before;

            thresh_before = dut.u_npram_threshold.mem[WRITE_THRESH_ADDR];
            check(thresh_before !== WRITE_THRESH_REJECT_DATA && thresh_before !== WRITE_THRESH_ACCEPT_DATA,
                  "test 11b: INIT_FILE threshold must differ from both test values");

            fork
                uart_send_write_frame(8'h01, WRITE_THRESH_ADDR, WRITE_THRESH_REJECT_DATA);
                wait_for_host_write(2'd1, "test 11b threshold (rejected)");
            join
            check(dut.thresh_we === 1'b0,
                  "test 11b: a sign-bit-set threshold write must never assert thresh_we");
            check(dut.u_npram_threshold.mem[WRITE_THRESH_ADDR] === thresh_before,
                  "test 11b: a sign-bit-set threshold write must be rejected, not stored");

            fork
                uart_send_write_frame(8'h01, WRITE_THRESH_ADDR, WRITE_THRESH_ACCEPT_DATA);
                wait_for_host_write(2'd1, "test 11b threshold (accepted)");
            join
            check(dut.u_npram_threshold.mem[WRITE_THRESH_ADDR] === WRITE_THRESH_ACCEPT_DATA,
                  "test 11b: a non-negative threshold write to the same address must still commit");
        end

        // ------------------------------------------------------------
        // Test 11c (#73 follow-up): a sign-bit-set leak write must also be
        // rejected. Unlike threshold, a negative leak doesn't just fail to
        // decay -- with a positive membrane it flips the arithmetic to
        // *add* every idle tick (0 - (-leak) = +leak), climbing to a
        // positive threshold from a fresh (zero) membrane with no input.
        // wait_for_host_write() can't be reused for the rejected case: it
        // asserts leak_we === (target==2'd2), which assumes target-2
        // writes always commit -- true before this guard, not after.
        // ------------------------------------------------------------
        begin
            localparam logic [7:0] WRITE_LEAK_ADDR2        = 8'h04;
            localparam logic [15:0] WRITE_LEAK_REJECT_DATA = 16'hFF00;  // sign bit set (-1.0)
            localparam logic [15:0] WRITE_LEAK_ACCEPT_DATA = 16'h0080;  // 0.5
            logic [15:0] leak_before2;
            int unsigned waited;

            leak_before2 = dut.u_npram_leak.mem[WRITE_LEAK_ADDR2];
            check(leak_before2 !== WRITE_LEAK_REJECT_DATA && leak_before2 !== WRITE_LEAK_ACCEPT_DATA,
                  "test 11c: INIT_FILE leak must differ from both test values");

            waited = 0;
            fork
                uart_send_write_frame(8'h02, WRITE_LEAK_ADDR2, WRITE_LEAK_REJECT_DATA);
                begin
                    forever begin
                        @(negedge clk);
                        waited++;
                        if (dut.host_wr_en === 1'b1) break;
                        if (waited > (5 * 11 * CLKS_PER_BIT + SEQ_SLACK))
                            $fatal(1, "test 11c leak (rejected): host_wr_en not seen within %0d cycles", waited);
                    end
                end
            join
            check(dut.leak_we === 1'b0,
                  "test 11c: a sign-bit-set leak write must never assert leak_we");
            check(dut.u_npram_leak.mem[WRITE_LEAK_ADDR2] === leak_before2,
                  "test 11c: a sign-bit-set leak write must be rejected, not stored");

            fork
                uart_send_write_frame(8'h02, WRITE_LEAK_ADDR2, WRITE_LEAK_ACCEPT_DATA);
                wait_for_host_write(2'd2, "test 11c leak (accepted)");
            join
            check(dut.u_npram_leak.mem[WRITE_LEAK_ADDR2] === WRITE_LEAK_ACCEPT_DATA,
                  "test 11c: a non-negative leak write to the same address must still commit");
        end

        // ------------------------------------------------------------
        // Test 12: host writes that land mid-sweep are held until idle.
        // Force a one-cycle wr_en during PREFETCH/SWEEP; UART is too slow
        // to finish a 5-byte frame in that window.
        // ------------------------------------------------------------
        begin
            localparam logic [7:0] SWEEP_WEIGHT_ADDR = 8'h02;
            localparam logic [7:0] SWEEP_THRESH_ADDR = 8'h0E;
            localparam logic [7:0] SWEEP_LEAK_ADDR   = 8'h0D;
            localparam logic [15:0] SWEEP_WEIGHT_DATA = 16'hCAFE;
            localparam logic [15:0] SWEEP_THRESH_DATA = 16'h1111;
            localparam logic [15:0] SWEEP_LEAK_DATA   = 16'h2222;

            wait_for_tick();
            @(negedge clk);
            check(dut.pe_busy === 1'b1,
                  "test 12: PE must be busy after the tick starts");
            inject_host_strobe(2'd0, SWEEP_WEIGHT_ADDR, SWEEP_WEIGHT_DATA);
            check(dut.wr_pending === 1'b1,
                  "test 12: a mid-sweep weight write must be held");
            check(dut.weight_we === 1'b0,
                  "test 12: held weight write must not steal the RAM port");
            check(dut.u_wram.addr === dut.weight_addr,
                  "test 12: weight addr must stay on the PE path during the sweep");
            check(dut.u_wram.mem[SWEEP_WEIGHT_ADDR] !== SWEEP_WEIGHT_DATA,
                  "test 12: held weight write must not commit until idle");
            wait_lif_sweep_done();
            repeat (4) @(negedge clk);
            check(dut.u_wram.mem[SWEEP_WEIGHT_ADDR] === SWEEP_WEIGHT_DATA,
                  "test 12: held weight write must commit after the PE is idle");
            check(dut.wr_pending === 1'b0,
                  "test 12: weight pending must clear after the deferred strobe");

            wait_for_tick();
            @(negedge clk);
            inject_host_strobe(2'd1, SWEEP_THRESH_ADDR, SWEEP_THRESH_DATA);
            check(dut.wr_pending === 1'b1,
                  "test 12: a mid-sweep threshold write must be held");
            check(dut.thresh_we === 1'b0,
                  "test 12: held threshold write must not steal the RAM port");
            check(dut.u_npram_threshold.addr === dut.threshold_addr,
                  "test 12: threshold addr must stay on the PE path during the sweep");
            wait_lif_sweep_done();
            repeat (4) @(negedge clk);
            check(dut.u_npram_threshold.mem[SWEEP_THRESH_ADDR] === SWEEP_THRESH_DATA,
                  "test 12: held threshold write must commit after the PE is idle");

            wait_for_tick();
            @(negedge clk);
            inject_host_strobe(2'd2, SWEEP_LEAK_ADDR, SWEEP_LEAK_DATA);
            check(dut.wr_pending === 1'b1,
                  "test 12: a mid-sweep leak write must be held");
            check(dut.leak_we === 1'b0,
                  "test 12: held leak write must not steal the RAM port");
            check(dut.u_npram_leak.addr === dut.leak_addr,
                  "test 12: leak addr must stay on the PE path during the sweep");
            wait_lif_sweep_done();
            repeat (4) @(negedge clk);
            check(dut.u_npram_leak.mem[SWEEP_LEAK_ADDR] === SWEEP_LEAK_DATA,
                  "test 12: held leak write must commit after the PE is idle");
        end

        // ------------------------------------------------------------
        // Test 12b: RM-259 AER routing on the complete SoC path.
        //
        // Program a synthetic 0 -> 1 -> 2 route through the real five-byte
        // 0xA5 target-3 command. The routed column must feed both the LIF
        // matrix address and StdpWriteback's pre-event capture. Invalid and
        // cyclic routes are consumed as no-input ticks, still arm exactly one
        // normal response, and set the shared sticky ingress-fault LED.
        // ------------------------------------------------------------
        begin
            int unsigned response_before;
            int unsigned cfg_before;
            logic [3:0] routed_before;
            logic resolved_before;
            logic drop_before;

            // The top-level high-address gate and the route table's reserved
            // bit validation are distinct failure sources. Exercise both
            // through the real UART dispatcher and prove neither partially
            // changes the table.
            cfg_before = aer_cfg_write_count;
            uart_send_write_frame(8'h03, 8'h10, 16'hC009);
            @(negedge clk);
            check_int(aer_cfg_write_count, cfg_before,
                      "test 12b: out-of-range route address must not assert cfg_we");
            check(dut.u_aer_router.route_mem[0] === 16'hC000,
                  "test 12b: out-of-range route address must not alias entry 0");
            check(dut.u_status_leds.ingress_fault_sticky === 1'b1,
                  "test 12b: out-of-range route address must set ingress fault");

            cfg_before = aer_cfg_write_count;
            uart_send_write_frame(8'h03, 8'h02, 16'hC012);
            @(negedge clk);
            check_int(aer_cfg_write_count, cfg_before + 1,
                      "test 12b: reserved-bit entry must reach router validation once");
            check(dut.u_aer_router.route_mem[2] === 16'hC002,
                  "test 12b: reserved-bit entry must leave prior table word intact");
            check(dut.u_status_leds.ingress_fault_sticky === 1'b1,
                  "test 12b: reserved-bit rejection must set ingress fault");

            cfg_before = aer_cfg_write_count;
            uart_send_write_frame(8'h03, 8'h00, 16'h8001);
            @(negedge clk);
            check_int(aer_cfg_write_count, cfg_before + 1,
                      "test 12b: target-3 frame must assert one AER write");
            cfg_before = aer_cfg_write_count;
            uart_send_write_frame(8'h03, 8'h01, 16'hC002);
            @(negedge clk);
            check_int(aer_cfg_write_count, cfg_before + 1,
                      "test 12b: second target-3 frame must assert one AER write");
            check(dut.u_aer_router.route_mem[0] === 16'h8001,
                  "test 12b: target-3 write must program route entry 0");
            check(dut.u_aer_router.route_mem[1] === 16'hC002,
                  "test 12b: target-3 write must program route entry 1");

            // A drained/superseded lookup may still pulse the router output.
            // With no lookup associated with the pending frame, that stale
            // completion must not mutate the SoC handoff state.
            check(dut.route_lookup_pending === 1'b0,
                  "test 12b: stale-result guard precondition must be idle");
            routed_before   = dut.routed_input_index;
            resolved_before = dut.route_resolved;
            drop_before     = dut.route_drop_pending;
            force dut.route_out_valid = 1'b1;
            force dut.route_out_addr = 4'd9;
            @(negedge clk);
            release dut.route_out_valid;
            release dut.route_out_addr;
            check(dut.route_resolved === resolved_before &&
                  dut.route_drop_pending === drop_before &&
                  dut.routed_input_index === routed_before,
                  "test 12b: stale route result must be ignored without a pending lookup");

            expected_input_index = 4'd2;
            response_before = frame_send_count;
            // The UART transaction is intentionally bypassed for this one
            // fabric-cycle boundary test: a complete stop bit outlives the
            // two-hop lookup. Inject the already-decoded frame, then force an
            // otherwise imminent logical tick while routing is active.
            force_protocol_stimuli = '0;
            force_protocol_stimuli[15:0] = 16'h0001;
            force dut.protocol_stimuli = force_protocol_stimuli;
            force dut.protocol_stimuli_valid = 1'b1;
            @(negedge clk);
            release dut.protocol_stimuli_valid;
            release dut.protocol_stimuli;
            wait_for_stimuli_pending();
            while (dut.route_busy !== 1'b1)
                @(negedge clk);
            suppress_tick_monitor = 1'b1;
            force dut.step_en = 1'b1;
            @(negedge clk);
            check(dut.stimuli_pending === 1'b1,
                  "test 12b: tick during lookup must retain the pending frame");
            check(dut.consume_pending === 1'b0,
                  "test 12b: tick during lookup must not consume a partial route");
            check(dut.response_armed === 1'b0,
                  "test 12b: tick during lookup must not arm a response");
            check_int(frame_send_count, response_before,
                      "test 12b: tick during lookup must not send a response");
            release dut.step_en;
            // Keep the period monitor suppressed through the next divider
            // edge, when the underlying step_en register returns low after
            // release. Otherwise simulator process ordering can count the
            // forced pulse as the start of a real STEP_DIV interval.
            @(negedge clk);
            tick_count = 0;
            width_run = 0;
            last_tick_cyc = cyc;
            suppress_tick_monitor = 1'b0;

            wait_for_route_resolution();
            check(dut.stimulus_event === 1'b1,
                  "test 12b: successful multi-hop route must produce one PE event");
            check(dut.stimulus_input_index === 4'd2,
                  "test 12b: source lane 0 must resolve to routed column 2");
            seen_weight_row = '0;
            wait_for_tick();
            record_sweep_addresses();
            @(negedge clk);
            record_sweep_addresses();
            check(dut.u_stdp.col_q === 4'd2,
                  "test 12b: STDP must capture routed column 2, not source lane 0");
            wait_lif_sweep_done();
            check(seen_weight_row == {NUM_NEURONS{1'b1}},
                  "test 12b: LIF sweep must select routed weight column 2 in every row");
            @(negedge clk);
            check_int(frame_send_count, response_before + 1,
                      "test 12b: deferred routed frame must produce exactly one response");

            // Invalid but well-formed entry: configuration succeeds; lookup
            // fails later. Status mode is already selected by sw[15].
            uart_send_write_frame(8'h03, 8'h03, 16'h0000);
            @(negedge clk);
            response_before = frame_send_count;
            uart_send_stimulus_frame(3);
            wait_for_stimuli_pending();
            wait_for_route_resolution();
            check(dut.stimulus_event === 1'b0,
                  "test 12b: invalid route must be dropped before the PE");
            check(dut.u_status_leds.ingress_fault_sticky === 1'b1,
                  "test 12b: invalid route must set sticky ingress fault");
            wait_tick_applied();
            wait_lif_sweep_done();
            @(negedge clk);
            check_int(frame_send_count, response_before + 1,
                      "test 12b: invalid route must still produce one response");

            // Two-entry cycle. MAX_HOPS, not simulation timeout, must end it.
            uart_send_write_frame(8'h03, 8'h04, 16'h8005);
            @(negedge clk);
            uart_send_write_frame(8'h03, 8'h05, 16'h8004);
            @(negedge clk);
            response_before = frame_send_count;
            uart_send_stimulus_frame(4);
            wait_for_stimuli_pending();
            wait_for_route_resolution();
            check(dut.stimulus_event === 1'b0,
                  "test 12b: hop-budget exhaustion must drop the input event");
            check(dut.route_fault === 1'b1 ||
                  dut.u_status_leds.ingress_fault_sticky === 1'b1,
                  "test 12b: hop-budget exhaustion must report a route fault");
            wait_tick_applied();
            wait_lif_sweep_done();
            @(negedge clk);
            check_int(frame_send_count, response_before + 1,
                      "test 12b: hop-budget failure must still produce one response");

            // Restore address 3 to identity and prove the next completely
            // accepted, valid frame clears the combined sticky status bit.
            uart_send_write_frame(8'h03, 8'h03, 16'hC003);
            @(negedge clk);
            expected_input_index = 4'd3;
            uart_send_stimulus_frame(3);
            wait_for_stimuli_pending();
            wait_for_route_resolution();
            check(dut.stimulus_event === 1'b1,
                  "test 12b: restored identity route must deliver the event");
            check(dut.u_status_leds.ingress_fault_sticky === 1'b0,
                  "test 12b: next accepted valid frame must clear sticky ingress fault");
            wait_tick_applied();
            wait_lif_sweep_done();
        end

        // ------------------------------------------------------------
        // Test 13a: GH#72's output class reaches status_word[15:13] by VALUE.
        //
        // Test 9 can only mirror led[15:13] against u_status_leds'
        // output_class_hold, which moves with it under a wrong Basys3_Top
        // binding.  This compares the LED field against the OutputLayer's own
        // live result instead, and asserts the one-hot property docs/led-map.md
        // claims.  No UART is involved: the output layer runs on every
        // lif_tick_done, armed frame or not.
        //
        // SW15 is still 1 from test 9 (sw = 16'hA5A5), so the LED bus is the
        // status word here, not the spike bitmap.
        // ------------------------------------------------------------
        check(dut.sw_sync_1[15] === 1'b1,
              "test 13a: SW15 must still select status mode for the [15:13] check");
        wait_for_tick();
        wait_lif_sweep_done();
        wait_output_class_done();
        @(negedge clk);   // let output_class_hold latch the committed vector
        check($countones(led[15:13]) === 1,
              "test 13a: status[15:13] must be one-hot -- argmax always picks a winner (GH#72)");
        check(led[15:13] === dut.u_output_layer.result,
              "test 13a: status[15:13] must carry the OutputLayer's live one-hot result, not a stale or mis-bound field");

        // ------------------------------------------------------------
        // Test 13b: the real serial line carries exactly 36 bytes (GH#64).
        //
        // Every other response check in this file reads the FSM's internal
        // snapshot registers by hierarchical reference.  This one demodulates
        // uart_tx, so the assembled SocProtocolFsm -> SiliconBridge -> UartTx
        // chain and its 8N1 framing are in the loop -- the same bytes
        // rmems/silicon-bridge's host reads with read_exact(36)
        // (src/fpga_bridge.rs).  Expectations come from the top-level
        // membrane_potentials / spike_bitmap / sw_sync_1 nets sampled on the
        // FSM's capture edge, not from the serializer's own hold buffer.
        //
        // The 37th-byte check is the one that keeps "36-byte parsers intact"
        // honest: an extra byte would desynchronize every later host read
        // permanently, and no existing test would see it.
        // ------------------------------------------------------------
        begin
            logic [7:0] captured;
            bit         byte_ok;
            int         mismatches;

            wait_uart_line_idle();

            uart_send_stimulus_frame(SPIKE_TEST_NEURON);
            wait_for_stimuli_pending();
            wait_tick_applied();
            wait_lif_sweep_done();
            check(dut.frame_send === 1'b1,
                  "test 13b: consumed host frame must arm the response to capture");

            // Sampled on the negedge whose following posedge is the FSM's
            // capture edge, so these are the values the frame must carry.
            expected_wire_potentials = dut.membrane_potentials;
            expected_wire_spikes     = dut.spike_bitmap;
            expected_wire_aux        = dut.sw_sync_1;

            mismatches = 0;
            for (int b = 0; b < RESPONSE_BYTES; b++) begin
                uart_capture_byte(captured, byte_ok);
                if (!byte_ok) begin
                    errors++;
                    $display("FAIL: test 13b: no framed byte %0d of %0d on uart_tx",
                             b, RESPONSE_BYTES);
                    mismatches++;
                    break;
                end
                captured_frame[b] = captured;
                if (captured !== expected_wire_byte(b)) begin
                    errors++;
                    mismatches++;
                    $display("FAIL: test 13b: response byte %0d is 0x%02h, expected 0x%02h",
                             b, captured, expected_wire_byte(b));
                end
            end

            if (mismatches == 0)
                $display("TB_BASYS3_TOP: test 13b captured %0d response bytes off uart_tx (potentials, spike word %04h, aux %04h)",
                         RESPONSE_BYTES, expected_wire_spikes, expected_wire_aux);

            // No 37th byte.  Bytes 34-35 were the aux word above, so GH#72's
            // class flags demonstrably did not extend the frame.
            begin : no_extra_byte
                automatic int unsigned quiet = 0;
                while (quiet < UART_QUIET_CLKS) begin
                    @(negedge clk);
                    if (uart_tx_line === 1'b0) begin
                        errors++;
                        $display("FAIL: test 13b: a %0dth byte started %0d cycles after the frame ended -- the frame is no longer %0d bytes",
                                 RESPONSE_BYTES + 1, quiet, RESPONSE_BYTES);
                        break;
                    end
                    quiet++;
                end
            end
        end

        // ------------------------------------------------------------
        // Test 14: host RAM readback over the real UART (#113).
        //
        //   14a  Weight dump — echoed 5-byte header, then big-endian words
        //        that must equal u_wram.mem, including the runtime 0xA5
        //        writes from tests 11/12 (0xBEEF @ 0x01, 0xCAFE @ 0x02).
        //        The 13-byte dump outlives one 100k-cycle tick, so a real
        //        LIF sweep overlaps it and the deferred port grant is
        //        exercised end-to-end without corrupting the stream.
        //   14b  Threshold and leak dumps — target echo and payload values,
        //        including 0x0200 @ threshold[3] and 0x0080 @ leak[4] from
        //        the accepted writes in tests 11b/11c.
        //   14c  Port grant gating — a forced rd_req mid-sweep must not be
        //        acknowledged and must not steal the weight port; once the
        //        PE is idle the same request is granted and rd_dout carries
        //        the registered word one cycle later.
        //   14d  Target 3 (AER route table) is silently consumed: no dump
        //        frame, matching the write path's invalid-target rule and
        //        the FSM's no-read-port reality for the table.
        // ------------------------------------------------------------
        begin
            int unsigned ticks_before_dump;
            int unsigned grant_waited;
            bit          ack_during_sweep;

            wait_uart_line_idle();

            // 14a: weight bank, four words starting at 0 — covers the two
            // runtime-written entries plus two untouched INIT_FILE words.
            // The 5-byte request plus 13-byte dump (~156k cycles) overlaps
            // at least one 100k-cycle tick whichever phase it starts in.
            ticks_before_dump = tick_count;
            uart_send_read_frame(8'h00, 8'h00, 16'd4);
            check_dump_frame(8'h00, 8'h00, 4, "test 14a weight dump");
            check(dut.u_wram.mem[8'h01] === 16'hBEEF &&
                  dut.u_wram.mem[8'h02] === 16'hCAFE,
                  "test 14a: dump must carry the runtime-written weights, not just INIT");
            check(tick_count > ticks_before_dump,
                  "test 14a: at least one 1 ms tick must overlap the request+dump window");

            // 14b: param banks — two threshold words across the accepted
            // write at 0x03, then one leak word at the accepted write 0x04.
            uart_send_read_frame(8'h01, 8'h03, 16'd2);
            check_dump_frame(8'h01, 8'h03, 2, "test 14b threshold dump");
            uart_send_read_frame(8'h02, 8'h04, 16'd1);
            check_dump_frame(8'h02, 8'h04, 1, "test 14b leak dump");

            wait_uart_line_idle();

            // 14c: grant gating.  Force fsm_rd_req through a whole PE sweep
            // (same style as the test-12 host-write strobe force): the grant
            // must stay low for every busy cycle, then fire once the PE
            // drains.  fsm_rd_dout must carry the registered word on the
            // cycle after the granted cycle.
            wait_for_tick();
            @(negedge clk);
            check(dut.pe_busy === 1'b1,
                  "test 14c: PE must be busy after the tick starts");
            force dut.fsm_rd_req    = 1'b1;
            force dut.fsm_rd_target = 2'd0;
            force dut.fsm_rd_addr   = 8'h05;
            @(negedge clk);
            check(dut.fsm_rd_ack === 1'b0,
                  "test 14c: a host read must not be granted mid-sweep");
            check(dut.u_wram.addr === dut.weight_addr,
                  "test 14c: weight port must stay on the PE path mid-sweep");
            ack_during_sweep = 1'b0;
            fork
                wait_lif_sweep_done();
                begin
                    while (dut.u_lif_array.tick_done !== 1'b1) begin
                        @(negedge clk);
                        if (dut.fsm_rd_ack === 1'b1)
                            ack_during_sweep = 1'b1;
                    end
                end
            join
            check(!ack_during_sweep,
                  "test 14c: the read grant must wait out the whole sweep, not just its first cycle");

            // pe_ram_busy clears the cycle after tick_done; the stalled
            // request is granted on the first idle cycle it observes.
            grant_waited = 0;
            while (dut.fsm_rd_ack !== 1'b1 && grant_waited < SEQ_SLACK) begin
                @(negedge clk);
                grant_waited++;
            end
            check(dut.fsm_rd_ack === 1'b1,
                  "test 14c: a held read must be granted once the sweep drains");
            check(dut.u_wram.addr === 8'h05,
                  "test 14c: granted read must drive its address onto the weight port");
            @(negedge clk);   // registered RAM read latency
            check(dut.fsm_rd_dout === dut.u_wram.mem[8'h05],
                  "test 14c: rd_dout must carry the registered weight word after the grant");
            release dut.fsm_rd_req;
            release dut.fsm_rd_target;
            release dut.fsm_rd_addr;
            // XSim keeps a released force on a collapsed port net until the
            // driver produces an event (Verilator re-evaluates on release),
            // and fsm_rd_req's driver only toggles when a dump arms — no
            // real read frame means the net could read stale here.  A real
            // request toggles every driver in the path under both sims and
            // doubles as an end-to-end "still healthy after force/release"
            // check.  Addr 8'h05 equals the forced value, so the dump is
            // correct even if a stale addr lingers into the REQ cycle.
            rd_grant_count = 0;
            uart_send_read_frame(8'h00, 8'h05, 16'd1);
            check_dump_frame(8'h00, 8'h05, 1, "test 14c post-release weight dump");
            check_int(rd_grant_count, 1,
                      "test 14c: a one-word dump must grant exactly one port cycle");
            check(dut.fsm_rd_req === 1'b0,
                  "test 14c: read request line must drop once the dump completes");
            check(dut.fsm_rd_ack === 1'b0,
                  "test 14c: read grant must drop once the request releases");
            check(dut.u_wram.addr === dut.weight_addr,
                  "test 14c: weight port must return to the PE path after the read");

            // 14d: target 3 is consumed without a dump — the route table has
            // no config read port, so nothing may touch uart_tx.
            uart_send_read_frame(8'h03, 8'h00, 16'd4);
            begin : target3_quiet
                automatic int unsigned quiet = 0;
                while (quiet < UART_QUIET_CLKS) begin
                    @(negedge clk);
                    if (uart_tx_line !== 1'b1) begin
                        errors++;
                        $display("FAIL: test 14d: target-3 read emitted a byte %0d cycles after the request",
                                 quiet);
                        break;
                    end
                    quiet++;
                end
            end
            check(dut.fsm_rd_req === 1'b0,
                  "test 14d: rejected read must leave the read-request line low");
            check(dut.u_protocol_fsm.dump_active === 1'b0,
                  "test 14d: rejected read must not arm the dump serializer");
        end

        // ------------------------------------------------------------
        // Test 15: optional STDP writeback on the full SoC path (GH#70;
        // restores the SoC-level coverage #103 added as test 14 and #104
        // removed, GH#109).
        //
        // SW14 is the learn gate and powers up 0, so every test above must
        // still see INIT_FILE / host-written weights. This block first proves
        // a pre-then-post pair is a no-op with the switch low, then flips
        // SW14, replays the pair, and checks the routed column synapse moved
        // by exactly +1 LSB while the source column is untouched. A second
        // learn-off replay while the traces are still live proves the gate
        // itself, not empty traces, suppresses the write. A host weight
        // write that lands while stdp_busy is high must wait, matching test
        // 12's PE-hold pattern. Every stimulus resolves through u_aer_router
        // first, so each frame waits for route resolution before the
        // consuming tick; lane 5 routes to column 10 (non-identity) so the
        // writeback address can only come from the routed column.
        // ------------------------------------------------------------
        begin
            localparam int STDP_ROW = SPIKE_TEST_NEURON;
            localparam int STDP_PRE_COL = 10;
            localparam logic [7:0] STDP_WEIGHT_ADDR = 8'(STDP_ROW * NUM_NEURONS + STDP_PRE_COL);
            localparam logic [7:0] STDP_SOURCE_ADDR = 8'(STDP_ROW * NUM_NEURONS + STDP_ROW);
            localparam logic [15:0] STDP_WEIGHT_SEED = 16'd200;
            localparam logic [15:0] STDP_SOURCE_SEED = 16'd300;
            localparam logic [7:0] STDP_HOST_ADDR = 8'h06;
            localparam logic [15:0] STDP_HOST_DATA = 16'h3456;

            check(dut.learn_en === 1'b0,
                  "test 15: SW14 must still be low after the status-mode tests");
            check(dut.stdp_busy === 1'b0,
                  "test 15: STDP engine must be idle while learn is off");

            // Test 12b left entries 0/1 programmed as the multi-hop route and
            // entries 4/5 as the two-entry cycle. Restore 0/1/4 to identity
            // and route lane 5 to column 10 through the real 0xA5 target-3
            // path -- a non-identity route, so the writeback checks below can
            // only pass when STDP follows the routed column, not the source
            // lane.
            uart_send_write_frame(8'h03, 8'h00, 16'hC000);
            @(negedge clk);
            uart_send_write_frame(8'h03, 8'h01, 16'hC001);
            @(negedge clk);
            uart_send_write_frame(8'h03, 8'h04, 16'hC004);
            @(negedge clk);
            uart_send_write_frame(8'h03, 8'h05, 16'hC00A);
            @(negedge clk);
            check(dut.u_aer_router.route_mem[STDP_ROW] === 16'hC00A,
                  "test 15: lane-5 route must target column 10, not identity");

            dut.u_wram.mem[STDP_WEIGHT_ADDR]        = STDP_WEIGHT_SEED;
            dut.u_wram.mem[STDP_SOURCE_ADDR]        = STDP_SOURCE_SEED;
            dut.u_npram_threshold.mem[STDP_ROW]     = 16'h0001;
            dut.u_npram_leak.mem[STDP_ROW]          = 16'h0000;

            expected_input_index = $clog2(NUM_NEURONS)'(STDP_PRE_COL);
            uart_send_stimulus_frame(STDP_ROW);
            wait_for_stimuli_pending();
            wait_for_route_resolution();
            check(dut.stimulus_input_index === $clog2(NUM_NEURONS)'(STDP_PRE_COL),
                  "test 15: lane-5 stimulus must resolve to routed column 10");
            wait_tick_applied();
            wait_lif_sweep_done();
            check(dut.u_lif_array.spike_bitmap[STDP_ROW] === 1'b1,
                  "test 15: gated-off pair must still produce a PE spike");
            @(negedge clk);
            check(dut.stdp_busy === 1'b0,
                  "test 15: learn_en=0 must not start a column walk after tick_done");
            check(dut.u_wram.mem[STDP_WEIGHT_ADDR] === STDP_WEIGHT_SEED,
                  "test 15: learn_en=0 must leave the selected synapse unchanged");

            sw = sw | 16'h4000; // SW14=1, keep SW15 status mode
            repeat (SW_SYNC_LATENCY) @(negedge clk);
            check(dut.learn_en === 1'b1,
                  "test 15: SW14 must enable learn_en after 2FF sync");

            // First coincident pre+post with empty traces: no write, traces load.
            uart_send_stimulus_frame(STDP_ROW);
            wait_for_stimuli_pending();
            wait_for_route_resolution();
            wait_tick_applied();
            wait_lif_sweep_done();
            @(negedge clk);
            check(dut.stdp_busy === 1'b1,
                  "test 15: learn_en=1 must start a column walk after tick_done");
            wait_stdp_idle();
            check(dut.u_wram.mem[STDP_WEIGHT_ADDR] === STDP_WEIGHT_SEED,
                  "test 15: the trace-load tick must not change the synapse");

            // Refractory follow-up: traces decay one tick, stay live.
            wait_tick_applied();
            wait_lif_sweep_done();
            wait_stdp_idle();

            // Second event: post while pre_trace is live → LTP +1.
            uart_send_stimulus_frame(STDP_ROW);
            wait_for_stimuli_pending();
            wait_for_route_resolution();
            wait_tick_applied();
            wait_lif_sweep_done();
            wait_stdp_idle();
            check(dut.u_wram.mem[STDP_WEIGHT_ADDR] === 16'(STDP_WEIGHT_SEED + 16'd1),
                  "test 15: pre-then-post with learn on must LTP the routed synapse");
            check(dut.u_wram.mem[STDP_SOURCE_ADDR] === STDP_SOURCE_SEED,
                  "test 15: writeback must not touch the source-lane column");

            // Gate under live traces: drop SW14 and replay the pair. The
            // earlier learn-off leg cannot distinguish "gated" from "nothing
            // to write" (empty traces produce no update anyway); with the
            // traces live a real LTP/LTD would land if the gate leaked.
            sw = sw & ~16'h4000;
            repeat (SW_SYNC_LATENCY) @(negedge clk);
            check(dut.learn_en === 1'b0,
                  "test 15: SW14 low must disable learn_en after 2FF sync");
            uart_send_stimulus_frame(STDP_ROW);
            wait_for_stimuli_pending();
            wait_for_route_resolution();
            wait_tick_applied();
            wait_lif_sweep_done();
            @(negedge clk);
            check(dut.stdp_busy === 1'b0,
                  "test 15: learn off with live traces must not start a column walk");
            check(dut.u_wram.mem[STDP_WEIGHT_ADDR] === 16'(STDP_WEIGHT_SEED + 16'd1),
                  "test 15: learn off with live traces must not write the synapse");
            // The one-shot sample above only catches an immediate launch.
            // Watch a full-walk-length window so a delayed launch -- and any
            // write it could sneak in -- cannot slip past the gate check.
            begin : learn_off_window
                repeat (8 * NUM_NEURONS + 16) begin
                    @(negedge clk);
                    check(dut.stdp_busy === 1'b0,
                          "test 15: learn off with live traces must never start a walk");
                end
            end
            check(dut.u_wram.mem[STDP_WEIGHT_ADDR] === 16'(STDP_WEIGHT_SEED + 16'd1),
                  "test 15: learn off with live traces must not write the synapse late");

            // Re-enable for the deferred-host-write check.
            sw = sw | 16'h4000;
            repeat (SW_SYNC_LATENCY) @(negedge clk);
            check(dut.learn_en === 1'b1,
                  "test 15: SW14 must re-enable learn_en for the write-hold leg");

            // Host weight write held across the STDP walk, then committed.
            wait_tick_applied();
            wait_lif_sweep_done();
            @(negedge clk);
            check(dut.stdp_busy === 1'b1,
                  "test 15: a learn-enabled tick must keep stdp_busy high after the sweep");
            check(dut.pe_busy === 1'b0,
                  "test 15: the STDP walk must run while the LIF PE is idle");
            inject_host_strobe(2'd0, STDP_HOST_ADDR, STDP_HOST_DATA);
            check(dut.wr_pending === 1'b1,
                  "test 15: a mid-walk host weight write must be held");
            check(dut.weight_we === 1'b0,
                  "test 15: held host write must not steal the RAM port from STDP");
            check(dut.u_wram.mem[STDP_HOST_ADDR] !== STDP_HOST_DATA,
                  "test 15: held host write must not commit until STDP is idle");
            // One-cycle samples cannot prove the hold: watch every fabric
            // cycle of the walk so a host write that steals the port or
            // commits early is caught, and so STDP's own writes are seen
            // only while the LIF PE is idle.
            begin : held_write_monitor
                automatic int unsigned held_cycles = 0;
                while (dut.stdp_busy === 1'b1) begin
                    @(negedge clk);
                    // Re-sample busy at the same negedge as the signals
                    // below: the cycle stdp_busy drops is exactly when the
                    // deferred write legally fires, so it is out of scope.
                    if (dut.stdp_busy === 1'b1) begin
                        held_cycles++;
                        check(dut.wr_pending === 1'b1,
                              "test 15: host write must stay pending for the whole walk");
                        check(dut.weight_we === 1'b0,
                              "test 15: weight we must stay low for the whole walk");
                        check(dut.u_wram.mem[STDP_HOST_ADDR] !== STDP_HOST_DATA,
                              "test 15: host value must not commit while STDP walks");
                        check(dut.u_wram.addr === dut.stdp_addr,
                              "test 15: STDP must own the RAM port for the whole walk");
                        check(dut.pe_busy === 1'b0,
                              "test 15: the LIF PE must stay idle for the whole walk");
                        if (held_cycles > 8 * NUM_NEURONS + 16)
                            $fatal(1, "test 15: stdp_busy never cleared during held-write monitor");
                    end
                end
                check(held_cycles > 0,
                      "test 15: held-write monitor must observe at least one walk cycle");
            end
            repeat (4) @(negedge clk);
            check(dut.u_wram.mem[STDP_HOST_ADDR] === STDP_HOST_DATA,
                  "test 15: held host write must commit after STDP is idle");
            check(dut.wr_pending === 1'b0,
                  "test 15: host pending must clear after the deferred strobe");
        end

        $display("TB_BASYS3_TOP: merged_v2 swept all 16 parameter entries and weight rows");

        if (errors == 0) begin
            $display("TB_BASYS3_TOP: ALL TESTS PASSED (%0d ticks checked)", tick_count);
            $finish;
        end else begin
            $display("TB_BASYS3_TOP: %0d TEST(S) FAILED", errors);
            $fatal(1, "TB_BASYS3_TOP: testbench FAILED");
        end
    end

endmodule

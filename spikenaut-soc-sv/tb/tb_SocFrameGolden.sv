// SPDX-License-Identifier: MIT OR Apache-2.0
// tb_SocFrameGolden.sv
// Canonical source: spikenaut-soc-sv/tb
// Golden-vector testbench for the SiliconBridge v3.0 wire framing (GH#64).
//
// Replays the committed golden frame pairs from spikenaut-core-sv/mem/golden/
// through the real SocProtocolFsm in both directions:
//
//   request  33 golden bytes on rx_data  ->  stimuli_out must unpack to the
//            golden Q8.8 lane words
//   response golden lane words on potentials_in/spike_flags/aux_state  ->
//            tx_data must serialize the golden 36 bytes, and nothing after them
//
// Those same bytes are what rmems/silicon-bridge's host parses
// (src/fpga_bridge.rs, FpgaBridge::process_stimuli), so this testbench and
// tests/test_golden_frame_vectors.py check the two ends of one contract
// against one committed byte stream. See docs/host-soc-e2e.md.
//
// Same contract as tb_LifNeuron_golden.sv / tb_OutputLayer_golden.sv: every
// expectation comes from the generated images, nothing is asserted from
// hand-written constants, and the *_FILE paths are repo-root relative.
//
// This is deliberately a framing test, not a behavioural one: it never claims
// the SoC would compute these potentials from these stimuli. What the network
// does is pinned by the GH#66 LIF and output-layer goldens.
//
// Stimulus and checks run on negedge clk, matching every other SoC TB.

`timescale 1ns/1ps

module tb_SocFrameGolden #(
    parameter string COUNT_FILE      = "spikenaut-core-sv/mem/golden/frame_golden_count.mem",
    parameter string HOST_TX_FILE    = "spikenaut-core-sv/mem/golden/frame_golden_host_tx.mem",
    parameter string SOC_RX_FILE     = "spikenaut-core-sv/mem/golden/frame_golden_soc_rx.mem",
    parameter string STIMULI_FILE    = "spikenaut-core-sv/mem/golden/frame_golden_stimuli.mem",
    parameter string POTENTIALS_FILE = "spikenaut-core-sv/mem/golden/frame_golden_potentials.mem",
    parameter string SPIKES_FILE     = "spikenaut-core-sv/mem/golden/frame_golden_spikes.mem",
    parameter string AUX_FILE        = "spikenaut-core-sv/mem/golden/frame_golden_aux.mem"
);

    localparam int NUM_NEURONS = 16;
    localparam int WORD_WIDTH  = 16;
    localparam int CLK_PERIOD  = 10;

    // Wire geometry, mirroring SocProtocolFsm's localparams. The generated
    // images are laid out against these, so they are checked below rather than
    // trusted.
    localparam int BYTES_PER_WORD = WORD_WIDTH / 8;
    localparam int PAYLOAD_BYTES  = NUM_NEURONS * BYTES_PER_WORD;   // 32
    localparam int FRAME_BYTES    = PAYLOAD_BYTES + 2 * BYTES_PER_WORD;  // 36
    localparam int REQUEST_BYTES  = 1 + PAYLOAD_BYTES;              // 33

    localparam int MAX_CASES   = 32;
    localparam int MAX_TX_MEM  = MAX_CASES * REQUEST_BYTES;
    localparam int MAX_RX_MEM  = MAX_CASES * FRAME_BYTES;
    localparam int MAX_WORDS   = MAX_CASES * NUM_NEURONS;

    // Bounded waits. The serializer presents a byte every few cycles into an
    // idle bridge; 32 is the bound tb_SocProtocolFsm.sv uses.
    localparam int WAIT_BOUND   = 32;
    localparam int COMMIT_BOUND = 8;
    // How long to watch for a 37th byte after a complete frame. Must exceed
    // WAIT_BOUND so "nothing arrived" is a stronger statement than "we did not
    // wait as long as we do for a byte we expect".
    localparam int QUIET_BOUND  = 2 * WAIT_BOUND;
    // Back-pressure stall applied on odd-indexed cases, long enough to span
    // several would-be byte slots.
    localparam int STALL_CYCLES = 5;

    // GH#64 is explicit that the frame length does not move. A parameter sweep
    // or a well-meaning "add a field" change trips this at elaboration rather
    // than as 36 confusing byte mismatches.
    if (FRAME_BYTES != 36)
        $error("tb_SocFrameGolden: response FRAME_BYTES is %0d, but the SiliconBridge v3.0 contract and every golden image are 36 (GH#64)", FRAME_BYTES);
    if (REQUEST_BYTES != 33)
        $error("tb_SocFrameGolden: request frame is %0d bytes, but the contract and every golden image are 33 (GH#64)", REQUEST_BYTES);

    logic clk;
    logic rst_n;
    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_send;
    logic       tx_busy;
    logic [NUM_NEURONS*WORD_WIDTH-1:0] stimuli_out;
    logic                              stimuli_valid;
    logic [NUM_NEURONS*WORD_WIDTH-1:0] potentials_in;
    logic [NUM_NEURONS-1:0]            spike_flags;
    logic [WORD_WIDTH-1:0]             aux_state;
    logic                              frame_send;
    logic                              wr_en;
    logic [1:0]                        wr_target;
    logic [7:0]                        wr_addr;
    logic [WORD_WIDTH-1:0]             wr_data;
    logic                              rx_busy;
    logic                              rx_abort;
    logic                              tx_frame_active;

    int errors = 0;
    int n_cases;
    int stimuli_valid_pulses = 0;
    int rx_abort_pulses = 0;
    int wr_en_pulses = 0;

    logic [7:0]  host_tx_mem    [0:MAX_TX_MEM-1];
    logic [7:0]  soc_rx_mem     [0:MAX_RX_MEM-1];
    logic [15:0] stimuli_mem    [0:MAX_WORDS-1];
    logic [15:0] potentials_mem [0:MAX_WORDS-1];
    logic [15:0] spikes_mem     [0:MAX_CASES-1];
    logic [15:0] aux_mem        [0:MAX_CASES-1];
    logic [15:0] count_mem      [0:0];

    SocProtocolFsm #(
        .NUM_NEURONS (NUM_NEURONS),
        .WORD_WIDTH  (WORD_WIDTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .rx_data         (rx_data),
        .rx_valid        (rx_valid),
        .tx_data         (tx_data),
        .tx_send         (tx_send),
        .tx_busy         (tx_busy),
        .stimuli_out     (stimuli_out),
        .stimuli_valid   (stimuli_valid),
        .potentials_in   (potentials_in),
        .spike_flags     (spike_flags),
        .aux_state       (aux_state),
        .frame_send      (frame_send),
        .wr_en           (wr_en),
        .wr_target       (wr_target),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .rx_busy         (rx_busy),
        .rx_abort        (rx_abort),
        .tx_frame_active (tx_frame_active)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Free-running monitors. A golden replay must never abort a frame or look
    // like a 0xA5 RAM write, even though mid-payload 0xAA / 0xA5 bytes are
    // legal Q8.8 data and do appear in these vectors.
    always @(negedge clk) begin
        if (rst_n === 1'b1) begin
            if (stimuli_valid === 1'b1) stimuli_valid_pulses++;
            if (rx_abort === 1'b1)      rx_abort_pulses++;
            if (wr_en === 1'b1)         wr_en_pulses++;
        end
    end

    task automatic check(input logic condition, input string msg);
        if ($isunknown(condition)) begin
            errors++;
            $display("FAIL (unknown state): %s", msg);
        end else if (!condition) begin
            errors++;
            $display("FAIL: %s", msg);
        end
    endtask

    task automatic check_int(input int unsigned actual,
                             input int unsigned expected,
                             input string msg);
        if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (got %0d, expected %0d)", msg, actual, expected);
        end
    endtask

    task automatic require_file(input string path);
        int fd;
        fd = $fopen(path, "r");
        if (fd == 0)
            $fatal(1, "TB_SOC_FRAME_GOLDEN: cannot open '%s' (run from the repo root, or override the *_FILE parameters)", path);
        $fclose(fd);
    endtask

    task automatic send_rx_byte(input logic [7:0] value);
        begin
            @(negedge clk);
            rx_data  = value;
            rx_valid = 1'b1;
            @(negedge clk);
            rx_valid = 1'b0;
        end
    endtask

    // Drive one golden request frame and check the FSM unpacked it into the
    // golden lane words. The expectation comes from frame_golden_stimuli.mem,
    // a separate image, not from re-unpacking the bytes we just sent -- that
    // would only re-check this testbench's own arithmetic against the DUT's.
    task automatic replay_request(input int case_index);
        int unsigned waited;
        int base_byte;
        int base_word;
        logic [WORD_WIDTH-1:0] got;
        logic [WORD_WIDTH-1:0] want;
        begin
            base_byte = case_index * REQUEST_BYTES;
            base_word = case_index * NUM_NEURONS;

            check_byte(host_tx_mem[base_byte], 8'hAA,
                       $sformatf("case %0d: golden request must start with the 0xAA sync byte", case_index));

            for (int b = 0; b < REQUEST_BYTES; b++)
                send_rx_byte(host_tx_mem[base_byte + b]);

            waited = 0;
            while (stimuli_valid !== 1'b1 && waited < COMMIT_BOUND) begin
                @(negedge clk);
                waited++;
            end
            if (stimuli_valid !== 1'b1) begin
                errors++;
                $display("FAIL: case %0d: a complete golden request did not commit within %0d cycles",
                         case_index, COMMIT_BOUND);
            end else begin
                for (int lane = 0; lane < NUM_NEURONS; lane++) begin
                    got  = stimuli_out[lane*WORD_WIDTH +: WORD_WIDTH];
                    want = stimuli_mem[base_word + lane];
                    if ($isunknown(got)) begin
                        errors++;
                        $display("FAIL: case %0d lane %0d: stimuli_out has X/Z", case_index, lane);
                    end else if (got !== want) begin
                        errors++;
                        $display("FAIL: case %0d lane %0d: stimuli_out %04h != golden %04h",
                                 case_index, lane, got, want);
                    end
                end
            end
        end
    endtask

    task automatic check_byte(
        input logic [7:0] actual,
        input logic [7:0] expected,
        input string msg
    );
        if ($isunknown(actual)) begin
            errors++;
            $display("FAIL (X/Z in byte): %s", msg);
        end else if (actual !== expected) begin
            errors++;
            $display("FAIL: %s (got 0x%02h, expected 0x%02h)", msg, actual, expected);
        end
    endtask

    // Wait for the serializer to present one byte. tx_byte_index only advances
    // once the FSM has seen its own tx_send accepted, so sampling tx_data on
    // the strobe cycle cannot catch a half-updated byte.
    task automatic wait_for_tx_byte(output logic [7:0] captured, output bit got_byte);
        int unsigned waited;
        begin
            captured = '0;
            waited   = 0;
            while (tx_send !== 1'b1 && waited < WAIT_BOUND) begin
                @(negedge clk);
                waited++;
            end
            got_byte = (tx_send === 1'b1);
            if (got_byte) begin
                check(tx_busy === 1'b0,
                      "tx_send may assert only while tx_busy is low");
                captured = tx_data;
            end
            // Let the registered strobe be consumed and deassert before the
            // caller asks for the next byte, or consecutive calls would read
            // the same level-high pulse twice.
            @(negedge clk);
        end
    endtask

    // Snapshot one golden response and check the exact byte stream, then check
    // the stream stops. `stall` inserts bridge back-pressure between bytes: the
    // byte values must not depend on it.
    task automatic replay_response(input int case_index, input bit stall);
        int base_byte;
        int base_word;
        logic [7:0] captured;
        bit got_byte;
        begin
            base_byte = case_index * FRAME_BYTES;
            base_word = case_index * NUM_NEURONS;

            @(negedge clk);
            for (int lane = 0; lane < NUM_NEURONS; lane++)
                potentials_in[lane*WORD_WIDTH +: WORD_WIDTH] = potentials_mem[base_word + lane];
            spike_flags = spikes_mem[case_index][NUM_NEURONS-1:0];
            aux_state   = aux_mem[case_index];

            @(negedge clk);
            frame_send = 1'b1;
            @(negedge clk);
            frame_send = 1'b0;

            for (int b = 0; b < FRAME_BYTES; b++) begin
                if (stall) begin
                    tx_busy = 1'b1;
                    repeat (STALL_CYCLES) @(negedge clk);
                    tx_busy = 1'b0;
                end
                wait_for_tx_byte(captured, got_byte);
                if (!got_byte) begin
                    errors++;
                    $display("FAIL: case %0d: response stalled at byte %0d of %0d (waited %0d cycles)%s",
                             case_index, b, FRAME_BYTES, WAIT_BOUND, stall ? " [back-pressure]" : "");
                    return;
                end
                check_byte(captured, soc_rx_mem[base_byte + b],
                           $sformatf("case %0d response byte %0d%s",
                                     case_index, b, stall ? " [back-pressure]" : ""));
            end

            // The frame must be exactly FRAME_BYTES long. A 37th byte would
            // desynchronize the host's next read_exact(36) permanently, so this
            // is the check that keeps "36-byte parsers intact" honest.
            for (int q = 0; q < QUIET_BOUND; q++) begin
                if (tx_send === 1'b1) begin
                    errors++;
                    $display("FAIL: case %0d: serializer emitted a byte (0x%02h) after the %0dth, %0d cycles past the frame end",
                             case_index, tx_data, FRAME_BYTES, q);
                    return;
                end
                @(negedge clk);
            end
            check(tx_frame_active === 1'b0,
                  $sformatf("case %0d: tx_frame_active must fall once the frame is fully sent", case_index));
        end
    endtask

    initial begin
        require_file(COUNT_FILE);
        require_file(HOST_TX_FILE);
        require_file(SOC_RX_FILE);
        require_file(STIMULI_FILE);
        require_file(POTENTIALS_FILE);
        require_file(SPIKES_FILE);
        require_file(AUX_FILE);

        $readmemh(COUNT_FILE,      count_mem);
        $readmemh(HOST_TX_FILE,    host_tx_mem);
        $readmemh(SOC_RX_FILE,     soc_rx_mem);
        $readmemh(STIMULI_FILE,    stimuli_mem);
        $readmemh(POTENTIALS_FILE, potentials_mem);
        $readmemh(SPIKES_FILE,     spikes_mem);
        $readmemh(AUX_FILE,        aux_mem);

        n_cases = int'(count_mem[0]);
        if (n_cases <= 0 || n_cases > MAX_CASES)
            $fatal(1, "TB_SOC_FRAME_GOLDEN: case count %0d is out of range 1..%0d", n_cases, MAX_CASES);

        // Vacuity guard. One golden case is deliberately the all-zero frame, so
        // an unloaded $readmemh array would match it byte for byte. Requiring a
        // non-zero byte somewhere in the loaded range is what separates "the
        // images loaded" from "we are comparing zeros to zeros". Exact file
        // lengths are checked by tests/test_golden_frame_vectors.py.
        begin : vacuity_guard
            automatic bit saw_request  = 1'b0;
            automatic bit saw_response = 1'b0;
            for (int b = 0; b < n_cases * REQUEST_BYTES; b++)
                if (host_tx_mem[b] != '0) saw_request = 1'b1;
            for (int b = 0; b < n_cases * FRAME_BYTES; b++)
                if (soc_rx_mem[b] != '0) saw_response = 1'b1;
            if (!saw_request || !saw_response)
                $fatal(1, "TB_SOC_FRAME_GOLDEN: golden frame images look empty or unloaded -- run from the repo root and regenerate with scripts/gen_golden_frame_vectors.py");
        end

        $display("TB_SOC_FRAME_GOLDEN: replaying %0d golden frame pairs (%0d-byte request, %0d-byte response)",
                 n_cases, REQUEST_BYTES, FRAME_BYTES);

        rst_n         = 1'b0;
        rx_data       = '0;
        rx_valid      = 1'b0;
        tx_busy       = 1'b0;
        potentials_in = '0;
        spike_flags   = '0;
        aux_state     = '0;
        frame_send    = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        for (int i = 0; i < n_cases; i++) begin
            replay_request(i);
            // Alternate bridge back-pressure so every golden byte stream is
            // checked both into an idle bridge and across a stall.
            replay_response(i, (i % 2) == 1);
        end

        // Exactly one commit per request, and none of these frames may have
        // looked like an abandoned frame or a 0xA5 RAM write -- mid-payload
        // 0xAA / 0xA5 bytes are legal data and several cases contain them.
        check_int(stimuli_valid_pulses, n_cases,
                  "each golden request must commit exactly once");
        check_int(rx_abort_pulses, 0,
                  "a back-to-back golden replay must never trip the inter-byte idle timeout");
        check_int(wr_en_pulses, 0,
                  "a golden stimulus replay must never be mistaken for a 0xA5 RAM write");

        if (errors == 0) begin
            $display("TB_SOC_FRAME_GOLDEN: ALL %0d GOLDEN FRAME PAIRS MATCHED (%0d request + %0d response bytes)",
                     n_cases, n_cases * REQUEST_BYTES, n_cases * FRAME_BYTES);
            $finish;
        end else begin
            $display("TB_SOC_FRAME_GOLDEN: %0d MISMATCH(ES)", errors);
            $display("  Case indices map to entries in spikenaut-core-sv/mem/golden/frame_golden_vectors.json.");
            $display("  This testbench pins the host<->SoC wire framing, not network behaviour:");
            $display("  a failure here means the byte layout moved, which breaks the");
            $display("  silicon-bridge host parser (docs/host-soc-e2e.md). If the change is");
            $display("  intended, regenerate (python3 scripts/gen_golden_frame_vectors.py)");
            $display("  in the same commit and update the host crate.");
            $fatal(1, "TB_SOC_FRAME_GOLDEN: testbench FAILED");
        end
    end

endmodule

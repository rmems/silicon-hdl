<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-13 -->

# Host ↔ SoC end-to-end runbook (SiliconBridge v3.0)

Runbook for driving the F1 16-neuron SoC from the
[`rmems/silicon-bridge`](https://github.com/rmems/silicon-bridge) host crate, plus
the golden frame vectors that keep the two repositories' parsers agreeing without
a board in the loop.

GitHub [#64](https://github.com/rmems/silicon-hdl/issues/64) /
Linear [RM-288](https://linear.app/rpd-34/issue/RM-288). Parent epic
[#54](https://github.com/rmems/silicon-hdl/issues/54).

| Item | Value |
| --- | --- |
| Wire protocol | SiliconBridge v3.0, N = 16, 16-bit Q8.8 words |
| Request frame | **33 bytes** — `0xAA` sync + 16 big-endian Q8.8 stimuli |
| Response frame | **36 bytes** — 16 potentials + spike-flag word + aux word |
| RAM-write frame | **5 bytes** — `0xA5` sync + target + addr + Q8.8 data ([#63](https://github.com/rmems/silicon-hdl/issues/63)) |
| Link | 115200 baud, 8N1, no flow control |
| SoC codec | [`spikenaut-soc-sv/rtl/SocProtocolFsm.sv`](../spikenaut-soc-sv/rtl/SocProtocolFsm.sv) |
| Host codec | `silicon-bridge` `src/fpga_bridge.rs` (`FpgaBridge::process_stimuli`) |
| Q8.8 convention | Signed two's-complement ([#73](https://github.com/rmems/silicon-hdl/issues/73)) |
| Live bank | exp-025 Dale health-PASS, Spikenaut-SNN#47 @ `6965e12a` |

## The frame contract

Both frames are **big-endian per 16-bit word**, and **lane 0 is first on the
wire**. Lane 0 is the least-significant `WORD_WIDTH` bits of the packed RTL
vectors, so "first on the wire" and "LSB of the vector" are the same lane —
getting that backwards is the single easiest way to break this path.

### Request — host → SoC, 33 bytes

| Byte | Field |
| --- | --- |
| `0` | `0xAA` sync |
| `1..2` | lane 0 stimulus, signed Q8.8, high byte first |
| `3..4` | lane 1 stimulus |
| … | … |
| `31..32` | lane 15 stimulus |

The FSM collects all 32 payload bytes before it commits anything to the core, so
early bytes never turn into raw spikes. **Mid-payload `0xAA` and `0xA5` are legal
Q8.8 data and are never a resync** — a host that retries a truncated request must
idle for at least `IDLE_TIMEOUT_CYCLES` fabric clocks (four UART character times
by default) before sending the next sync byte.

### Response — SoC → host, 36 bytes

| Byte | Field |
| --- | --- |
| `0..31` | 16 membrane potentials, signed Q8.8, lane 0 first |
| `32..33` | spike-flag word, big-endian; **bit `i` is neuron `i`**, so bit 0 is neuron 0 |
| `34..35` | aux word — the synchronized switch bus `sw_sync_1`, sampled at `frame_send` |

At 115200 baud a 36-byte response takes about 3.125 ms, longer than the 1 ms
logical tick ([`timestep-contract.md`](timestep-contract.md)). Triggers that
arrive while a frame is serializing are **coalesced into a single latest-wins
pending snapshot** — the host sees the most recent state, not a backlog. Plan for
one response per request, not one per tick.

### What is *not* in the frame

[#72](https://github.com/rmems/silicon-hdl/issues/72)'s output-class flags are
**LED-only**: they live in `status_word[15:13]` (see
[`led-map.md`](led-map.md)) and add no response bytes. The response is 36 bytes
before and after #72. Anything that needs the class over UART is a protocol
version bump, not a field appended to this frame.

## Golden frame vectors

`spikenaut-core-sv/mem/golden/frame_golden_*.mem` are **generated** request /
response byte streams that pin the contract above. Do not hand-edit them.

Regenerate:

```bash
python3 scripts/gen_golden_frame_vectors.py
```

Drift gate:

```bash
python3 scripts/gen_golden_frame_vectors.py --check
```

`--check` runs in `scripts/quality.sh`, in `.github/workflows/sim.yml`, and from
`tests/test_golden_frame_vectors.py`.

| File | Contents |
| --- | --- |
| `frame_golden_count.mem` | Case count (one word) |
| `frame_golden_host_tx.mem` | Request bytes, 33 per case |
| `frame_golden_soc_rx.mem` | Response bytes, 36 per case |
| `frame_golden_stimuli.mem` | Expected unpacked stimulus lane words, 16 per case |
| `frame_golden_potentials.mem` | Response potential source words, 16 per case |
| `frame_golden_spikes.mem` | Spike-flag word, one per case |
| `frame_golden_aux.mem` | Aux word, one per case |
| `frame_golden_vectors.json` | Manifest: per-case provenance, `f32`, Q8.8, and full byte strings |

### Cases

| Case | Source | What it pins |
| --- | --- | --- |
| `bank_ei_column` | exp-025 | Mixed Dale E/I (`0xFF00` on neurons 6–9); an unsigned host decode reads 255.0 where the SoC sent −1.0 |
| `bank_inhibitory_row` | exp-025 | An all-non-positive frame; aux `0xA5A5`, the same switch pattern the SoC testbench drives |
| `lane_walk` | synthetic | Adjacent lanes one Q8.8 LSB apart — catches a transposition, lane offset, or byte-swapped word; `spike_word = 0x0001` pins bit 0 = neuron 0 |
| `lane15_only` | synthetic | The other end of the vector; swaps with `lane_walk` under a reversed lane or bit order |
| `all_ones` | synthetic | `0xFFFF` spike and aux words as *bit patterns*, not the Q8.8 value −1/256 |
| `all_zeros` | synthetic | The all-zero frame is still 36 bytes |
| `clamp_saturation` | synthetic | ±127.99 lands on `0x7FFD` / `0x8003`, so the clamp stays on the unscaled `f32` |
| `bank_decay_thresholds` | exp-025 | Real bank words with `0xAAAA`, the complement of `clamp_saturation`'s bitmap |

Cases tagged **exp-025** take every `f32` from a decode of a word already
committed under `spikenaut-core-sv/mem/`, and the generator asserts the
re-encode returns the identical word — no trained weight is authored here.
Cases tagged **synthetic** reach framing edges the bank cannot express and carry
no claim about the network.

These vectors pin **framing only**. What the SoC computes from a stimulus is
pinned separately by the GH#66 LIF and output-layer goldens
([`golden-lif-vectors.md`](golden-lif-vectors.md)); no vector here asserts that
the SoC would produce these potentials from these stimuli.

### Who checks what

| Layer | Check | Where |
| --- | --- | --- |
| Vectors | Regenerating is a no-op; image lengths; bank provenance | `tests/test_golden_frame_vectors.py` |
| Host codec | A model of `process_stimuli` reproduces every golden request and recovers every golden response; wrong decodes (unsigned, little-endian, reversed lanes, reversed spike bits) must disagree | `tests/test_golden_frame_vectors.py` |
| SoC codec | Golden bytes replayed through the real `SocProtocolFsm`, both directions, idle and under back-pressure; no 37th byte | `tb_SocFrameGolden` |
| Assembled chain | 36 bytes demodulated off the real `uart_tx` line; `status_word[15:13]` compared against the live `OutputLayer.result` | `tb_Basys3_Top` tests 13a / 13b |
| Board | Program, LED heartbeat, live host session | [`phase-c-board-smoke.md`](phase-c-board-smoke.md) and below |

The host model in `tests/test_golden_frame_vectors.py` is a transcription of the
Rust decode, not the crate itself. Running the **real** crate against these bytes
belongs to silicon-bridge's own suite; what the model buys is that a framing
change made in *this* repository fails in *this* repository's CI rather than on a
board.

## Runbook A — simulation only (no board)

Everything below runs on a free runner and is what CI gates.

```bash
./scripts/quality.sh
```

That covers both drift gates, `tb_SocFrameGolden`, and the SoC-level
`tb_spikenaut_soc_basys3_top` (including the wire-level capture). To run just the
framing pieces:

```bash
python3 scripts/gen_golden_frame_vectors.py --check
```

```bash
rm -rf obj_dir && verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD --top-module tb_SocFrameGolden -Ispikenaut-soc-sv/rtl spikenaut-soc-sv/rtl/SocProtocolFsm.sv spikenaut-soc-sv/tb/tb_SocFrameGolden.sv && ./obj_dir/Vtb_SocFrameGolden
```

The Python side needs `pip install -r requirements-dev.txt`:

```bash
python3 -m pytest tests/test_golden_frame_vectors.py -q
```

Both golden testbenches read their images by **repo-root-relative** path — run
them from the repo root, or override the `*_FILE` parameters.

## Runbook B — board in the loop

Prerequisites: a programmed Basys 3 (see
[`phase-c-board-smoke.md`](phase-c-board-smoke.md) for the bitstream and JTAG
steps) and the `silicon-bridge` crate checked out.

1. **Program and confirm the design is alive.** Press BTNC to reset, set SW15
   high for status mode, and confirm LED0 (`heartbeat`, ~1.95 Hz) is blinking.
   A dark LED0 means the 1 ms divider is not running and no UART session will
   work.

2. **Find the serial port.** The Basys 3's FTDI bridge appears as
   `/dev/ttyUSB*` on Linux, `/dev/cu.usbserial-*` on macOS, `COM*` on Windows.

   ```bash
   ls -l /dev/serial/by-id/
   ```

   Prefer a stable `by-id` symlink and pass it to `FpgaBridge::open`.
   `FpgaBridge::new()` guesses: it orders candidates by USB vendor id and
   accepts the first port that *opens*. It does **not** verify the peer — the
   protocol carries no identifying marker, so a 36-byte reply from any serial
   device reads as valid. On a machine with more than one adapter, name the
   port.

3. **Leave the switches somewhere recognisable.** Bytes 34–35 of every response
   echo `sw[15:0]`, so a distinctive pattern (SW15 high plus anything) gives you
   a free liveness check on the tail of the frame. The FSM samples the switches
   at `frame_send` and holds them for the whole ~3.1 ms frame, so a switch
   flipped mid-transmission shows up in the *next* response.

4. **Send one request and read one response.** From the host crate:

   ```rust
   let mut bridge = silicon_bridge::FpgaBridge::open("/dev/serial/by-id/usb-Digilent_...")?;
   let (potentials, spikes) = bridge.process_stimuli(&[0.5; 16])?;
   ```

   `process_stimuli` encodes with `encode_q88_signed` — **not** the
   unsigned-magnitude `encode_q88_unsigned`, which flattens every inhibitory
   input to `0`.

5. **Read the board against the response.** With SW15 high, `status_word[12:8]`
   is `$countones(spike_hold)` and should agree with the population count of the
   spike word you just parsed. `status_word[15:13]` is the output-layer argmax
   and is *not* in the frame — exactly one of LD15/LD14/LD13 should be lit.

6. **Confirm the frame length on the wire.** If the host ever blocks in
   `read_exact`, or returns data that looks shifted by a byte or two, the frame
   length is the first thing to check — not the network.

   Two things this has to get right, and both are easy to get wrong:

   - **You must send a request.** Idle 1 ms ticks deliberately emit nothing, so
     a reader started against a quiet board blocks forever and tells you
     nothing. Arm a response first.
   - **Do not cap the read at 36 bytes.** A `head -c 36` truncates by
     construction and so can never see the 37th byte you are looking for. Read
     until the line goes idle, *then* count.

   Configure the port once. `-hupcl` keeps closing the fd from toggling the
   modem lines, which some boards see as a reset:

   ```bash
   stty -F /dev/ttyUSB0 115200 raw -echo -hupcl
   ```

   Start the reader **before** sending, let it end on its own idle timeout, then
   send an all-zero 33-byte request (`0xAA` + 32 zero bytes — the same shape as
   the `all_zeros` golden case):

   ```bash
   timeout 2 cat /dev/ttyUSB0 > /tmp/soc-response.bin & sleep 0.3; { printf '\xAA'; printf '\x00%.0s' $(seq 32); } > /dev/ttyUSB0; wait
   ```

   Now count and inspect. **Exactly 36** is the pass condition — 37 or more is
   the desynchronizing bug, and fewer means the response was cut short or never
   armed:

   ```bash
   wc -c < /tmp/soc-response.bin && od -Ad -tx1 /tmp/soc-response.bin
   ```

   (`od` is coreutils and always present; `xxd -g1` gives nicer output if you
   have it, but it ships with vim rather than with the base system.)

   In the dump, bytes `32`–`33` are the spike word and `34`–`35` echo the switch
   bus, so a recognisable switch pattern from step 3 confirms you are looking at
   a real response and not at noise.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Host blocks in `read_exact` | No response armed. Idle 1 ms ticks deliberately do **not** send a frame; a response fires only after a consumed host request. Check `status_word[2]` (`rx_commit`) flickered. |
| Every potential is a large positive number | Unsigned Q8.8 decode. `0xFF00` is −1.0, not 65280 ([#73](https://github.com/rmems/silicon-hdl/issues/73)). |
| Potentials look plausible but the wrong way round | Byte or lane order. Replay `lane_walk` / `lane15_only` against your parser. |
| Spike bits are mirrored | Bit order. Bit 0 is neuron 0; `lane_walk` (`0x0001`) and `lane15_only` (`0x8000`) are the pair that separates the two conventions. |
| Responses drift out of sync over a session | An extra or missing byte. One stray byte desynchronizes every later `read_exact(36)` permanently — `tb_Basys3_Top` test 13b is the check that catches this in simulation. |
| `status_word[3]` is lit | Sticky `rx_abort`: a host request was abandoned mid-frame and the inter-byte idle timeout fired. Idle the link before retrying. |
| Inhibitory weights have no effect *in a bank you exported yourself* | Not the UART path. Check the encoder the export used: `encode_q88_unsigned` flattens every negative to `0`. As of silicon-bridge [#60](https://github.com/rmems/silicon-bridge/pull/60) (`e201514`) `FpgaParameterExporter` encodes `.mem` images through `encode_q88_signed`, so a current crate is correct here; an older export is not. |

## Out of scope

- Changing either frame length, or adding a field to the response.
- Retraining or replacing the exp-025 bank.
- Stage-1 / STDP writeback over the host path
  ([#70](https://github.com/rmems/silicon-hdl/issues/70)).
- Any claim of numerical parity between the FPGA and a software simulator —
  these vectors pin framing, not equivalence.
- Inventing weights: every `exp-025` value here is a decode of a committed bank
  word.

## Related

- [`golden-lif-vectors.md`](golden-lif-vectors.md) — GH#66 LIF / output-layer goldens
- [`led-map.md`](led-map.md) — status word, including the LED-only `[15:13]` class field
- [`timestep-contract.md`](timestep-contract.md) — the 1 ms logical tick
- [`interface-alignment.md`](interface-alignment.md) — module-boundary signal map
- [`phase-c-board-smoke.md`](phase-c-board-smoke.md) — programming and board smoke

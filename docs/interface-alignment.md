<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-13 -->
# HDL ↔ silicon-bridge interface alignment

Cross-repo contract between **silicon-hdl** (SystemVerilog RTL) and
**[silicon-bridge](https://github.com/Limen-Neural/silicon-bridge)** (Rust host
traits and tools). Tracks GitHub issue
[#8](https://github.com/rmems/silicon-hdl/issues/8)
(related closed issue
[#10](https://github.com/rmems/silicon-hdl/issues/10)).
F0 honesty refresh:
[#56](https://github.com/rmems/silicon-hdl/issues/56)
under finishing epic
[#54](https://github.com/rmems/silicon-hdl/issues/54).

This document is the silicon-hdl source of truth for widths, memory encoding,
and UART layering. Prefer updating this file (and the cited RTL headers) when
either side of the contract changes.

## Scope and status

| Item | Status | Notes |
|------|--------|-------|
| Q8.8 / 16-bit memory layout vs `FixedPointEncode` / `MemFileWriter` | **Documented + SoC init wired** | Widths match. SoC demo loads `merged_v2_weights.mem`, `merged_v2_thresholds.mem`, `merged_v2_decay.mem`, and (since [#72](https://github.com/rmems/silicon-hdl/issues/72)) `merged_v2_output_weights.mem` via `INIT_FILE` `$readmemh` ([#51](https://github.com/rmems/silicon-hdl/issues/51) / [#52](https://github.com/rmems/silicon-hdl/issues/52) / #72). The output-weight bank feeds `OutputLayer`'s 3-class argmax, surfaced on LEDs only (`status_word[15:13]`) — no UART frame change (see [#64](https://github.com/rmems/silicon-hdl/issues/64)). Runtime UART rewrite is on via `SocProtocolFsm` `0xA5` frames ([#63](https://github.com/rmems/silicon-hdl/issues/63)) for the weight/threshold/leak banks only; the output-weight bank has no runtime write path |
| SiliconBridge UART framing vs `FpgaBridge` | **Implemented at SoC layer** | `SiliconBridge` remains transport-only (8-bit bytes); canonical `SocProtocolFsm` owns the host multi-byte frames ([#62](https://github.com/rmems/silicon-hdl/issues/62)) |
| Compatibility table (Rust ↔ SV) | **Documented** | See below |
| Real wire-level width mismatch requiring RTL fix | **None found** | No logic change in this work |
| Vivado resource / timing CI | **Satisfied** | Merged PR [#31](https://github.com/rmems/silicon-hdl/pull/31) (`.github/workflows/vivado-ci.yml`) |
| Logical timestep / `step_en` | **Documented** | [`docs/timestep-contract.md`](timestep-contract.md); SoC 1 ms divider (#57 / #60) |
| SoC demo maturity (F0 honesty) | **Partial** | `INIT_FILE`, N=16 time-multiplexed LIF, 0xAA frame decode, UART TX readback, and runtime `0xA5` RAM writes are wired. Multi-active-lane vector accumulation, STDP writeback, and host E2E remain sequenced work. See [#54](https://github.com/rmems/silicon-hdl/issues/54) |

Foundational RTL correctness that supports this alignment landed earlier via
PR [#11](https://github.com/rmems/silicon-hdl/pull/11) (comment on #8).

Host-side boundary ownership (what silicon-bridge owns vs does not own) is
described in silicon-bridge
[`docs/boundary-matrix.md`](https://github.com/Limen-Neural/silicon-bridge/blob/main/docs/boundary-matrix.md).

---

## 1. Fixed-point and memory format

### 1.1 Host encoding (silicon-bridge)

Trait surface (`src/fpga_export.rs`):

| Trait | Role |
|-------|------|
| `FixedPointEncode` | `f32` → signed two's-complement Q8.8 `i16` |
| `ParameterExport` | Build `FpgaParameters` bundle |
| `MemFileWriter` | Write Vivado `$readmemh` `.mem` files + JSON metadata |

**Signed two's-complement Q8.8** (export path — parameters / weights / decay):

```text
encode: raw_i16 = clamp(value, -127.99, 127.99) × 256.0, truncated toward zero
decode: value   = raw_i16 / 256.0

Encoder clamp (f32 → word):  −127.99 … +127.99        (raw −32765 … +32765)
Format range  (word → f32):  −128.0  … +127.99609375  (raw −32768 … +32767)
Example: 1.0 → 0x0100, 0.5 → 0x0080, −1.0 → 0xFF00
```

**The decode side is deliberately wider than the encoder.** `encode_q88_signed`
clamps the *unscaled* `f32` to `STIMULUS_Q88_MIN..=STIMULUS_Q88_MAX`
(`±127.99`), so it saturates at raw ±32765 and never emits the two extreme
words. `q88_signed_to_f32` accepts every `i16`. A host decoder must therefore
cover the **full** `−32768..=32767`, not just what the encoder can produce:
`LifNeuron` integration saturates at `16'h8000` / `16'h7FFF` (§1.3) — exactly
the two values outside the encoder's clamp — so a membrane readback can carry
−128.0 or +127.99609375 even though no host-encoded parameter ever will.

`EXPORT_FORMAT_VERSION` is currently `"Spikenaut-v2"` (historical tag retained
for tooling that keys on the string).

The optional UART stimulus/readback path (`src/fpga_bridge.rs`, feature `uart`)
uses the **same** convention: `i16` big-endian, clamp approximately ±127.99.
As of silicon-bridge
[#60](https://github.com/rmems/silicon-bridge/pull/60) (`e201514`) these are
literally the same function — `FixedPointEncode::encode_q88` returns
`encode_q88_signed(value)` — so there is one signed Q8.8 convention across the
crate, not one per path. This matches
[#73](https://github.com/rmems/silicon-hdl/issues/73), under which core LIF
arithmetic in silicon-hdl treats 16-bit words as **signed saturating** Q8.8
values (see §1.3). §1.3.1 records how that alignment was reached.

> *Correction:* revisions of this document before this one described the
> `.mem` export encoder as unsigned-only `u16`. That was accurate until
> silicon-bridge #60 and is no longer accurate; `encode_q88_unsigned` remains
> public in that crate but nothing there builds hardware images with it.

### 1.2 `.mem` file contract

`MemFileWriter::write_mem_files` produces one hex word per line (`{:04X}`):

| File | Contents | Maps to (intended) |
|------|----------|--------------------|
| `parameters.mem` | Thresholds, one signed `i16` Q8.8 word per line | `NeuronParamRam` instance used for thresholds |
| `parameters_weights.mem` | Flattened weight matrix `[neurons × channels]` | `WeightRam` |
| `parameters_decay.mem` | Decay / leak rates, one signed `i16` Q8.8 word per line | `NeuronParamRam` instance used for leak |
| `parameters.json` | Full `FpgaParameters` + `FpgaMetadata` | Host / CI metadata only |

Example line: `0100` loads as 16'h0100 (Q8.8 value 1.0).

**Endianness on the wire for UART multi-byte fields** (host protocol): big-endian
`i16` / `u16`. **`.mem` lines** are whole 16-bit words, not byte-swapped pairs.

### 1.3 RTL storage and arithmetic (silicon-hdl)

RTL does **not** implement fixed-point multiply/shift. Modules store opaque
16-bit words; `WeightRam`/`NeuronParamRam` are agnostic to sign, but as of
[#73](https://github.com/rmems/silicon-hdl/issues/73) `LifNeuron`/`LifNeuronArray`
read weight, membrane, and threshold as **signed two's-complement Q8.8**, not
unsigned. The host-side `.mem` encoder was updated to match in silicon-bridge
[#60](https://github.com/rmems/silicon-bridge/pull/60); §1.3.1 below records
that history and what is still worth knowing about it.

| Module | Path | Default width | Depth (default) | Role |
|--------|------|---------------|-----------------|------|
| `WeightRam` | `spikenaut-core-sv/rtl/WeightRam.sv` | `DATA_WIDTH = 16` | `2**ADDR_WIDTH`, `ADDR_WIDTH = 10` → 1024 | Synaptic weights |
| `NeuronParamRam` | `spikenaut-core-sv/rtl/NeuronParamRam.sv` | `PARAM_WIDTH = 16` | `2**ADDR_WIDTH`, `ADDR_WIDTH = 8` → 256 | **One** parameter type per instance (threshold **or** leak, not both) |
| `LifNeuron` | `spikenaut-core-sv/rtl/LifNeuron.sv` | `DATA_WIDTH = 16`, `PARAM_WIDTH = 16` | n/a | LIF dynamics; requires `PARAM_WIDTH == DATA_WIDTH` at elaborate time |
| `LifNeuronArray` | `spikenaut-core-sv/rtl/LifNeuronArray.sv` | `DATA_WIDTH = 16`, `PARAM_WIDTH = 16`, `NUM_NEURONS = 16` | 16 membrane words + one shared datapath | Time-multiplexed N=16 LIF PE; commits a 16-bit bitmap and exports packed membrane readback after each sweep |
| `StdpController` | `spikenaut-core-sv/rtl/StdpController.sv` | `DATA_WIDTH = 16` | n/a | Classical causal STDP (Bi–Poo): pre-then-post LTP +1, post-then-pre LTD −1; unsigned saturate (#55). `WINDOW_WIDTH` is in logical ticks; traces update only on `step_en`. |

**LIF semantics vs Q8.8 (signed as of #73):**

- `membrane` decays toward the 0 resting potential by `leak` from either side (a positive
  membrane floors at 0 draining down; a negative/inhibited membrane ceilings at 0 recovering
  up), then on `spike_in` adds `weight` with saturation at the signed extremes
  (`16'h7FFF` / `16'h8000`) instead of wrapping.
- Spike when integrated membrane `>= threshold`, compared **signed**: on that **enabled**
  clock edge (`step_en = 1`) `spike_out` goes high while `membrane_potential` still holds the
  **threshold-crossing** value (`next_mem`).
- **Refractory (next tick):** when the previous `spike_out` is observed, the FSM forces
  `next_mem = 0` and clears `spike_out` on the following **enabled** edge — so membrane reset
  is **one tick after** the spike pulse is generated, not simultaneous with it. A future
  UART potential-readback FSM must sample carefully on spike ticks.
- **Pulse width is one logical tick, not one fabric cycle.** While `step_en` is 0 the neuron
  holds `spike_out`, so in the SoC (1 kHz tick) a spike stays asserted for up to 100_000
  fabric cycles until the next enabled edge. Only in the unit TBs — which drive `step_en = 1`
  every cycle — do a tick and a fabric cycle coincide.

#### 1.3.1 Host-encoder gap opened by #73 — resolved upstream by silicon-bridge #60

**Status: closed.** Both sides of this contract are signed two's-complement
Q8.8 today. This subsection is kept as the history, because the older reading
is still reachable from the #73 / #91 record and from any pinned silicon-bridge
older than `e201514`.

**What the gap was.** [#73](https://github.com/rmems/silicon-hdl/issues/73)
made `LifNeuron`/`LifNeuronArray` read weight, membrane, and threshold as
signed, while silicon-bridge's `FixedPointEncode` (§1.1) still clamped to
unsigned `u16` Q8.8 (0.0 … 255.996). The two failure directions were:

- A weight/threshold/leak word in `0x8000..0xFFFF` written by the then-unsigned
  `FixedPointEncode` would be read as **negative** by `LifNeuronArray` — e.g.
  an intended `0xC880` (≈200.5 unsigned) reads as ≈ −55.5. A negative
  *threshold* or *leak* can make an otherwise-idle neuron spike with no input
  at all: a negative threshold satisfies `next_mem >= threshold` for almost any
  membrane value, and a negative leak *adds* to the membrane every idle tick
  instead of draining it (`0 - (-leak) = +leak`), so it climbs to a positive
  threshold on its own.
- Negative weights from a signed-aware producer (e.g. the exp-025 Distill
  sidecar bank, which does not go through `FixedPointEncode`) could not
  round-trip through `FixedPointEncode`/`MemFileWriter` at all — that encoder
  clamped negative `f32` input to `0x0000`, flattening every Dale-inhibitory
  word.

**How it was resolved.** silicon-bridge
[#60](https://github.com/rmems/silicon-bridge/pull/60) (`e201514`, tip of
`rmems/silicon-bridge` `origin/main`) changed `FpgaParameterExporter`'s
`FixedPointEncode::encode_q88` to return `encode_q88_signed(value)`, so the
`.mem` export path and the UART stimulus path share one encoder and one clamp
(±127.99). `encode_q88_unsigned` / `q88_to_f32` remain public in that crate as
an unsigned-magnitude pair, but they are **not** the `.mem` convention and
nothing in the crate builds hardware images with them — so the second bullet
above no longer applies, and the first can only be reproduced by pinning a
silicon-bridge older than `e201514`.

**What survives the fix, and why.** The RTL-side mitigation raised in PR
[#91](https://github.com/rmems/silicon-hdl/pull/91) review is still in place
and is still correct: `spikenaut_soc_basys3_top` rejects a sign-bit-set
*threshold or leak* runtime write instead of storing it, while **weight is
deliberately exempt** because a negative weight is the intended
Dale-inhibitory case. That guard is defence against any host — not only an
out-of-date `FixedPointEncode` — sending a nonsensical negative threshold or
leak, so it does not go away now that the upstream encoder is signed.

The exp-025 `.mem` images shipped from #73 onward come from the separate
Distill sidecar export, not from `FixedPointEncode`; that is unchanged by #60.

> *Correction:* this subsection previously described the host encoder as "the
> one part of this gap still open" and said `FixedPointEncode` "still can't
> produce a signed word on purpose". That was accurate when #73 landed and was
> superseded by silicon-bridge #60. The parallel notes in
> [`scripts/q88.py`](../scripts/q88.py) and
> [`docs/host-soc-e2e.md`](host-soc-e2e.md) were corrected in
> [PR #96](https://github.com/rmems/silicon-hdl/pull/96); this file is the
> remaining catch-up.

**SoC demo note (`spikenaut_soc_basys3_top`):** `INIT_FILE` is wired. Weight,
threshold, and leak RAMs load `merged_v2_weights.mem`, `merged_v2_thresholds.mem`,
and `merged_v2_decay.mem` at elaboration; a fourth RAM (`u_output_wram`) loads
`merged_v2_output_weights.mem` for `OutputLayer` (#72), which reduces one
tick's `spike_bitmap` into a 3-class argmax surfaced on LEDs only
(`status_word[15:13]`) — the 36-byte UART response frame is unchanged (see
#64). Vivado: `build_soc.tcl` `-generic` absolute paths so `$readmemh`
resolves. `LifNeuronArray` starts a 16-slot sweep on each `step_en` and pipelines
the RAM address one fabric cycle ahead of its registered `dout` consumption.
Threshold and leak walk neuron addresses `0..15`; the weight map is
`flat_addr = neuron_row * 16 + input_index` over the 256-word image, where
`neuron_row` is the neuron being updated and `input_index` selects one of 16
**external input channels** for that neuron's own row — not another neuron's
index. There is no neuron-to-neuron recurrence: `input_index` is decoded
purely from the host's stimulus frame, never from the PE's own
`spike_bitmap`. Per the exp-025 bank's metadata (`legal_columns` /
`unused_axons` in its `snn_model.json`), only 5 of the 16 channels carry
telemetry today; the remaining 11 are structurally zero for every neuron.
See [`docs/lif-array-connectivity-model.md`](lif-array-connectivity-model.md)
(#92) for the full rationale. The SoC protocol mapping selects the
lowest-index non-zero decoded stimulus lane as the binary-event `input_index`,
so each frame can address any channel `0..15`; a frame with more than one
active lane is not vector-accumulated by the current shared-event PE. Host
`0xA5` write frames from `SocProtocolFsm` (#63) pulse `we` for one cycle and
steal `addr` only while `wr_en` is high; the PE read path is restored when
idle. `INIT_FILE` remains the cold start. This closes the
N=16 addressing gap in [#61](https://github.com/rmems/silicon-hdl/issues/61)
and the runtime rewrite path in [#63](https://github.com/rmems/silicon-hdl/issues/63).

### 1.4 Width alignment summary

| Concept | silicon-bridge | silicon-hdl | Align? |
|---------|----------------|-------------|--------|
| Parameter / weight word | `i16` Q8.8 (signed two's complement) | 16-bit `logic` (`DATA_WIDTH` / `PARAM_WIDTH`) | Yes |
| Threshold vector | `FpgaParameters.thresholds: Vec<i16>` | `NeuronParamRam` (threshold instance) | Yes (format) |
| Decay / leak vector | `FpgaParameters.decay_rates: Vec<i16>` | `NeuronParamRam` (leak instance) | Yes (format) |
| Weight matrix flat | `FpgaParameters.weights: Vec<i16>` | `WeightRam` | Yes; implemented as `neuron_row * 16 + input_index` over the 16×16 image |
| Max weight depth (default) | sized by export metadata | 1024 entries @ 16-bit | Host must not exceed RAM depth for a given parameterization |
| Max param depth (default) | `num_neurons` | 256 entries @ 16-bit | Host `num_neurons` ≤ 256 at default `ADDR_WIDTH` |

---

## 2. SiliconBridge UART protocol

### 2.1 Physical / framing (RTL — implemented)

`SiliconBridge` (`spikenaut-bridge-sv/rtl/SiliconBridge.sv`) is a **thin dual
UART wrapper** around `UartRx` and `UartTx`. It does **not** parse opcodes,
sync bytes, or multi-byte frames.

| Parameter / pin | Default / width | Meaning |
|-----------------|-----------------|---------|
| `CLK_FREQ` | `100_000_000` | FPGA clock (Basys 3 oscillator) |
| `BAUD_RATE` | `115_200` | Matches silicon-bridge `serialport` open |
| `DATA_WIDTH` | `8` | Serial **data bits** per character (UART 8N1-style: start + 8 data LSB-first + stop; no parity) |
| `uart_rx_pin` / `uart_tx_pin` | 1-bit | Board UART pins |
| `rx_data` / `rx_valid` | 8-bit + strobe | Received byte; `rx_valid` one cycle after stop bit |
| `tx_data` / `tx_send` / `tx_busy` | 8-bit + handshake | Transmit byte; wait for `!tx_busy` before next `tx_send` |

`DATA_WIDTH` is intentionally parameterized and propagated to both UARTs even
though the product protocol is fixed at 8-bit characters (gh-14 / 5u3.7).

Receiver path uses a 2-flop synchronizer on `rx` (metastability hardening).

### 2.2 Host multi-byte protocol (silicon-bridge ↔ SoC application layer)

`FpgaBridge::process_stimuli` documents **SiliconBridge v3.0** (16-neuron demo
frame). This is a **host ↔ SoC application protocol** layered **on top of** the
byte pipe. It is implemented by the canonical
`spikenaut-soc-sv/rtl/SocProtocolFsm.sv` ([#62](https://github.com/rmems/silicon-hdl/issues/62)),
not inside `SiliconBridge.sv`.

```text
Host → FPGA (33 bytes):
  [0]      = 0xAA                    // sync
  [1..32]  = 16 × Q8.8 stimuli       // i16 big-endian each

FPGA → Host (36 bytes):
  [0..31]  = 16 × Q8.8 potentials    // i16 big-endian each
  [32..33] = spike flags             // u16 BE, bit i = neuron i spiked
  [34..35] = switch / aux state      // u16 BE, synchronized `sw` sampled at frame_send

Host → FPGA write (5 bytes, #63):
  [0]      = 0xA5                    // write sync (not 0xAA)
  [1]      = target                  // 0=weight, 1=threshold, 2=leak
  [2]      = addr                    // 8-bit RAM address
  [3..4]   = Q8.8 data               // signed two's-complement, big-endian, since #73 -- same as RAM/LIF math.
                                      // The host-side encoder (FixedPointEncode) emits signed
                                      // words too, as of silicon-bridge #60; see §1.3.1.
```

| Layer | Owner | Status in this monorepo |
|-------|-------|-------------------------|
| 8-bit UART transport | `UartRx` / `UartTx` / `SiliconBridge` | Implemented |
| 0xAA + multi-word frame codec | `SocProtocolFsm` in `lib_soc` (not in bridge lib) | **Implemented** in `spikenaut_soc_basys3_top`: atomic 32-byte receive decode plus held 36-byte response serialization |
| 0xA5 RAM-write frame | `SocProtocolFsm` write extension | **Implemented** (#63): one-cycle `wr_en` onto weight / threshold / leak RAMs; PE addr restored when idle |
| Host client | silicon-bridge `FpgaBridge` (`uart` feature) | Implemented in Rust |

Current SoC wiring (`spikenaut-soc-sv/rtl/Basys3_Top.sv`):

- Instantiates `SiliconBridge` at 100 MHz / 115200 baud (default `DATA_WIDTH=8`).
- `SocProtocolFsm` waits for `0xAA`, assembles all 32 payload bytes as 16
  big-endian Q8.8 words, atomically publishes the packed bus, and pulses
  `stimuli_valid`. The SoC holds that completed frame until the next 1 ms
  `step_en`; partial frames and raw `rx_valid` pulses cannot stimulate the PE.
  An incomplete receive is abandoned after `IDLE_TIMEOUT_CYCLES` fabric clocks
  without `rx_valid` (default four 10-bit UART character times at
  100 MHz / 115200) and returns to waiting for `0xAA`. Mid-payload `0xAA` is
  legal Q8.8 data and is not a resync; a retried host frame must idle at least
  that long before the next sync byte. A distinct `0xA5` write frame
  (target, address, big-endian Q8.8) pulses `wr_en` for one cycle and does
  not publish `stimuli_valid`. Mid-payload `0xA5` inside a stimulus frame is
  legal Q8.8 data. Writes use the same inter-byte idle timeout.
- One `LifNeuronArray` time-multiplexes 16 neuron slots. It sweeps threshold
  and leak entries `0..15` and maps `WeightRam` as
  `neuron_row * 16 + input_index`. The current shared-event PE maps the
  lowest-index non-zero frame lane to one selected input column for that tick;
  it does not yet sum multiple simultaneously active lanes.
- The PE exports all 16 committed membrane words and the 16-bit spike bitmap to
  the FSM. The SoC arms `frame_send` only after a host `0xAA` frame is consumed
  by `step_en`; the subsequent `tick_done` then snapshots that tick's result.
  Idle 1 ms ticks do not stream responses. `aux_state` is the 2FF-synchronized
  switch bus (`sw_sync_1`). `SocProtocolFsm` latches it into
  `active_aux_state` / `pending_aux_state` on the `frame_send` capture edge, so
  response bytes 34–35 are that sampled value held for the whole ~3.1 ms
  transmission — not a live view of the switches.
- `StdpController` is instantiated (classical Bi–Poo, `step_en`-gated) but
  writeback is **open**: `weight_we` / `weight_addr_out` / `weight_out` are left
  unconnected ([#70](https://github.com/rmems/silicon-hdl/issues/70)).
- TX emits the documented 36 bytes in big-endian order. It asserts `tx_send`
  only when `tx_busy` is low and holds the current byte across stalls. Because
  one 36-byte 115200-baud response takes about 3.125 ms, the FSM keeps one
  latest-wins pending snapshot if another consumed-frame trigger arrives while
  UART serialization is still active.

The codec is implemented above the bridge. End-to-end host/board exercise
remains separately scoped under [#64](https://github.com/rmems/silicon-hdl/issues/64).
Runtime RAM writes are implemented as a `SocProtocolFsm` extension (#63).

### 2.3 No opcodes in `SiliconBridge`

There is **no** opcode register map inside `SiliconBridge`. The implemented
`SocProtocolFsm` owns stimulus/readback framing and the #63 RAM-write
extension while preserving the bridge as the canonical byte transport:

1. Consumes `rx_data`/`rx_valid` and respects `tx_busy` when driving `tx_send`.
2. Drives `WeightRam` / `NeuronParamRam` write ports from a 5-byte `0xA5`
   frame (`target`, `addr`, big-endian Q8.8). Target `0` = weight, `1` =
   threshold, `2` = leak. `we` is a one-cycle strobe; `addr` returns to the
   PE read path when idle. `INIT_FILE` remains the cold start. STDP
   writeback stays unconnected ([#70](https://github.com/rmems/silicon-hdl/issues/70)).
3. Keeps the 8-bit transport module unchanged (single source of truth).

The write sync is **not** `0xAA`. Reusing the stimulus sync would make a
5-byte write look like a truncated 33-byte stimulus (idle-timeout abort) or
steal the first payload bytes of a real host frame. A parallel
`HostWriteFsm` on the same `rx_valid` pipe would have the same collision.

---

## 3. Compatibility table (Rust concepts ↔ SV modules / ports)

| Rust (silicon-bridge) | SV module / port / artifact | Match notes |
|-----------------------|-----------------------------|-------------|
| `FixedPointEncode::encode_q88` | 16-bit `din`/`dout` on RAMs; `weight` / `threshold` / `leak` on `LifNeuronArray` | Same 16-bit word size; both signed two's-complement Q8.8 — RTL since #73, host encoder since silicon-bridge #60 (§1.3.1) |
| `q88_to_f32` / `format_q88_hex` | Host-side only | No RTL equivalent required |
| `FpgaParameters.thresholds` | `NeuronParamRam` (threshold instance) `.din`/`.dout` | 16-bit; separate RAM from leak |
| `FpgaParameters.decay_rates` | `NeuronParamRam` (leak instance) | Mapped as **leak** in LIF (`membrane -= leak`) |
| `FpgaParameters.weights` | `WeightRam` `.din`/`.dout` | Flattened 16×16 matrix → `neuron_row * 16 + input_index` |
| `MemFileWriter` `.mem` lines | SoC `INIT_FILE` `$readmemh` into RAM arrays | **Wired** in demo top (`merged_v2` defaults); host rewrite via `0xA5` frames (#63) |
| `EXPORT_FORMAT_VERSION` | Metadata only | No RTL parse |
| `FpgaBridge` open @ 115200 | `SiliconBridge` `BAUD_RATE=115_200` | Match |
| UART 8 data bits | `DATA_WIDTH=8` on bridge/UART | Match |
| Host TX frame `0xAA` + 32 B | `SocProtocolFsm` application layer above bridge | Implemented in SoC; words decode big-endian and commit atomically |
| Host TX write `0xA5` + 4 B | `SocProtocolFsm` `wr_en` / `wr_target` / `wr_addr` / `wr_data` | Implemented (#63); target 0/1/2 selects weight / threshold / leak |
| Host RX 36 B response | `SocProtocolFsm` application layer above bridge | Implemented in SoC; 16 potentials, spike word, then aux word; `tx_busy` respected |
| Spike flag word (16 bits) | `LifNeuronArray.spike_bitmap` / LED bus | `led[i] = neuron i` in spike mode (SW15=0). SW15=1 shows the stretched status word. Bytes 34–35 carry synchronized `sw` sampled at `frame_send`. See [`docs/led-map.md`](led-map.md) |
| `FpgaMetrics::parse_from_report` (WNS) | Vivado timing summary from SoC build | CI: see §4 |
| `serialport` USB path | Board USB-UART (`uart_rx`/`uart_tx` on Basys 3) | Physical |

### Port-level bridge interface (for integrators)

```text
SiliconBridge
  clk, rst_n
  uart_rx_pin  →  UartRx.rx
  uart_tx_pin  ←  UartTx.tx
  rx_data[7:0], rx_valid     // to protocol / spike path
  tx_data[7:0], tx_send, tx_busy  // from protocol (gate send on !busy)
```

---

## 4. Vivado resource / timing CI (issue #8 acceptance)

Issue #8 asked for Vivado CI covering resource and timing reporting. That work
is **already merged** and must not be re-implemented here:

| Deliverable | Location | PR |
|-------------|----------|-----|
| Optional self-hosted Vivado workflow | `.github/workflows/vivado-ci.yml` | [#31](https://github.com/rmems/silicon-hdl/pull/31) |
| SoC synth / implement / bitstream | `scripts/build_soc.tcl` | used by workflow |
| Core unit sim under Vivado | `scripts/sim_core.tcl` | used by workflow |
| WNS / WHS gate | `scripts/check_wns.py` on `timing_summary.rpt` | workflow step |
| Report artifacts | upload-artifact of `*.rpt` / logs | workflow |

**How to run:** Actions → **Vivado CI** → Run workflow, or label a PR with
exact label `vivado-ci` (labeled event only). Runner labels:
`self-hosted`, `vivado`. Not a required free-runner check.

silicon-bridge `FpgaMetrics` can parse WNS from a timing summary for host-side
gating; silicon-hdl CI enforces non-negative WNS/WHS on the SoC build when the
self-hosted job runs.

---

## 5. Wire-mismatch review (this change)

Reviewed paths for real bit-width or pin mismatches between documented host
contracts and RTL ports:

| Check | Result |
|-------|--------|
| Bridge UART `DATA_WIDTH` vs host 8-bit serial | Match (default 8) |
| Core RAM / LIF 16-bit vs export `i16` | Match (width and signedness) |
| `LifNeuron` `PARAM_WIDTH == DATA_WIDTH` | Enforced by generate `$error` |
| SoC instantiation of bridge vs core widths | Documented split: bridge 8-bit, core 16-bit (by design) |
| Host v3.0 multi-byte frame vs bridge RTL | **Layer gap** (protocol not in bridge); not a port-width bug |
| Signed UART Q8.8 vs unsigned LIF / export | **Resolved.** LIF is signed since #73; the `.mem` export path (`FixedPointEncode`) is signed since silicon-bridge #60 (`e201514`) — see §1.3.1 |

**Conclusion:** documentation-only change. No RTL logic edit required for #8
acceptance. Clarifying comments only may be added on `SiliconBridge.sv`.

### Follow-ups (out of scope for this doc PR)

`$readmemh` / `INIT_FILE` is **already on `main`** (E1/E2). Remaining product work is
tracked under finishing epic
[#54](https://github.com/rmems/silicon-hdl/issues/54), not as a missing mem-init path:

- Runtime RAM writes are implemented in `SocProtocolFsm` (#63). Vector
  accumulation for multiple active stimulus lanes remains outside the
  binary-event PE mapping.
- STDP time-multiplexing and writeback into `WeightRam` ([#70](https://github.com/rmems/silicon-hdl/issues/70))

---

## 6. Related links

| Resource | Link |
|----------|------|
| Issue #8 (open alignment + historical CI ask) | [silicon-hdl#8](https://github.com/rmems/silicon-hdl/issues/8) |
| Issue #10 (closed; similar doc/align scope) | [silicon-hdl#10](https://github.com/rmems/silicon-hdl/issues/10) |
| Issue #54 finishing epic (16-neuron host E2E) | [silicon-hdl#54](https://github.com/rmems/silicon-hdl/issues/54) |
| Issue #56 F0 docs honesty (this refresh) | [silicon-hdl#56](https://github.com/rmems/silicon-hdl/issues/56) |
| PR #11 foundational RTL correctness | [silicon-hdl#11](https://github.com/rmems/silicon-hdl/pull/11) |
| PR #31 Vivado CI (util/timing) | [silicon-hdl#31](https://github.com/rmems/silicon-hdl/pull/31) |
| Issues #51 / #52 `INIT_FILE` `$readmemh` (E1/E2) | [silicon-hdl#51](https://github.com/rmems/silicon-hdl/issues/51), [#52](https://github.com/rmems/silicon-hdl/issues/52) |
| silicon-bridge export traits | [`fpga_export.rs`](https://github.com/Limen-Neural/silicon-bridge/blob/main/src/fpga_export.rs) |
| silicon-bridge #60 signed `.mem` export (closes §1.3.1) | [silicon-bridge#60](https://github.com/rmems/silicon-bridge/pull/60) |
| silicon-bridge UART host | [`fpga_bridge.rs`](https://github.com/Limen-Neural/silicon-bridge/blob/main/src/fpga_bridge.rs) |
| silicon-bridge boundary matrix | [`docs/boundary-matrix.md`](https://github.com/Limen-Neural/silicon-bridge/blob/main/docs/boundary-matrix.md) |

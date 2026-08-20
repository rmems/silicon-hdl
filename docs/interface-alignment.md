<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-08-19 -->
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
| Q8.8 / 16-bit memory layout vs `FixedPointEncode` / `MemFileWriter` | **Documented + SoC init wired** | Widths match. SoC demo loads `merged_v2_weights.mem`, `merged_v2_thresholds.mem`, and `merged_v2_decay.mem` via `INIT_FILE` `$readmemh` ([#51](https://github.com/rmems/silicon-hdl/issues/51) / [#52](https://github.com/rmems/silicon-hdl/issues/52)); `merged_v2_output_weights.mem` is vendored, not wired. Runtime UART rewrite is still off (`we = 0`) |
| SiliconBridge UART framing vs `FpgaBridge` | **Documented** | RTL is transport-only (8-bit bytes); host multi-byte frame is SoC/protocol layer — **not** on `main` |
| Compatibility table (Rust ↔ SV) | **Documented** | See below |
| Real wire-level width mismatch requiring RTL fix | **None found** | No logic change in this work |
| Vivado resource / timing CI | **Satisfied** | Merged PR [#31](https://github.com/rmems/silicon-hdl/pull/31) (`.github/workflows/vivado-ci.yml`) |
| Logical timestep / `step_en` | **Documented** | [`docs/timestep-contract.md`](timestep-contract.md); SoC 1 ms divider (#57 / #60) |
| SoC demo maturity (F0 honesty) | **Partial** | `INIT_FILE` yes; 1 neuron; `addr = 0`; STDP writeback open; `tx_send = 0`. See [#54](https://github.com/rmems/silicon-hdl/issues/54) |

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
| `FixedPointEncode` | `f32` → unsigned Q8.8 `u16` |
| `ParameterExport` | Build `FpgaParameters` bundle |
| `MemFileWriter` | Write Vivado `$readmemh` `.mem` files + JSON metadata |

**Unsigned Q8.8** (export path — parameters / weights / decay):

```text
raw_u16 = clamp(value × 256.0, 0.0, 65535.0) as u16
value   = raw_u16 / 256.0

Representable range (non-negative): ~0.0 … ~255.996
Example: 1.0 → 0x0100, 0.5 → 0x0080, 0.85 → 0x00D9
```

`EXPORT_FORMAT_VERSION` is currently `"Spikenaut-v2"` (historical tag retained
for tooling that keys on the string).

**Signed Q8.8** appears only on the optional UART stimulus/readback path
(`src/fpga_bridge.rs`, feature `uart`): stimuli and membrane readback use
`i16` big-endian with clamp approximately ±127.99. That path is **not** the
same encoder as `FixedPointEncode` / `.mem` export. Core LIF arithmetic in
silicon-hdl treats 16-bit words as **unsigned saturating** values (see §1.3).

### 1.2 `.mem` file contract

`MemFileWriter::write_mem_files` produces one hex word per line (`{:04X}`):

| File | Contents | Maps to (intended) |
|------|----------|--------------------|
| `parameters.mem` | Thresholds, one `u16` Q8.8 per line | `NeuronParamRam` instance used for thresholds |
| `parameters_weights.mem` | Flattened weight matrix `[neurons × channels]` | `WeightRam` |
| `parameters_decay.mem` | Decay / leak rates, one `u16` Q8.8 per line | `NeuronParamRam` instance used for leak |
| `parameters.json` | Full `FpgaParameters` + `FpgaMetadata` | Host / CI metadata only |

Example line: `0100` loads as 16'h0100 (Q8.8 value 1.0).

**Endianness on the wire for UART multi-byte fields** (host protocol): big-endian
`i16` / `u16`. **`.mem` lines** are whole 16-bit words, not byte-swapped pairs.

### 1.3 RTL storage and arithmetic (silicon-hdl)

RTL does **not** implement fixed-point multiply/shift. Modules store and
operate on opaque 16-bit words whose host interpretation is unsigned Q8.8.

| Module | Path | Default width | Depth (default) | Role |
|--------|------|---------------|-----------------|------|
| `WeightRam` | `spikenaut-core-sv/rtl/WeightRam.sv` | `DATA_WIDTH = 16` | `2**ADDR_WIDTH`, `ADDR_WIDTH = 10` → 1024 | Synaptic weights |
| `NeuronParamRam` | `spikenaut-core-sv/rtl/NeuronParamRam.sv` | `PARAM_WIDTH = 16` | `2**ADDR_WIDTH`, `ADDR_WIDTH = 8` → 256 | **One** parameter type per instance (threshold **or** leak, not both) |
| `LifNeuron` | `spikenaut-core-sv/rtl/LifNeuron.sv` | `DATA_WIDTH = 16`, `PARAM_WIDTH = 16` | n/a | LIF dynamics; requires `PARAM_WIDTH == DATA_WIDTH` at elaborate time |
| `StdpController` | `spikenaut-core-sv/rtl/StdpController.sv` | `DATA_WIDTH = 16` | n/a | Classical causal STDP (Bi–Poo): pre-then-post LTP +1, post-then-pre LTD −1; unsigned saturate (#55). `WINDOW_WIDTH` is in logical ticks; traces update only on `step_en`. |

**LIF semantics vs Q8.8 (unsigned):**

- `membrane -= leak` (floor at 0), then on `spike_in` add `weight` with saturate to all-ones.
- Spike when integrated membrane `>= threshold`: on that **enabled** clock edge (`step_en = 1`)
  `spike_out` goes high while `membrane_potential` still holds the **threshold-crossing**
  value (`next_mem`).
- **Refractory (next tick):** when the previous `spike_out` is observed, the FSM forces
  `next_mem = 0` and clears `spike_out` on the following **enabled** edge — so membrane reset
  is **one tick after** the spike pulse is generated, not simultaneous with it. A future
  UART potential-readback FSM must sample carefully on spike ticks.
- **Pulse width is one logical tick, not one fabric cycle.** While `step_en` is 0 the neuron
  holds `spike_out`, so in the SoC (1 kHz tick) a spike stays asserted for up to 100_000
  fabric cycles until the next enabled edge. Only in the unit TBs — which drive `step_en = 1`
  every cycle — do a tick and a fabric cycle coincide.
- These ops are consistent with **non-negative** Q8.8 words from
  `FixedPointEncode`. Negative host values must not be written into these RAMs
  via the export path.

**SoC demo note (`spikenaut_soc_basys3_top`):** `INIT_FILE` is wired. Weight,
threshold, and leak RAMs load `merged_v2_weights.mem`, `merged_v2_thresholds.mem`,
and `merged_v2_decay.mem` at elaboration (`merged_v2_output_weights.mem` is
vendored only). Vivado: `build_soc.tcl` `-generic` absolute paths so `$readmemh`
resolves. Ports remain `we = 0`, `addr = 0`, so after the first post-reset read
`dout` is **image word 0** — not a walked array. UART/config loader
([#63](https://github.com/rmems/silicon-hdl/issues/63)) and multi-neuron
addressing ([#61](https://github.com/rmems/silicon-hdl/issues/61)) are still
open. That is a **scale / protocol** gap, not a missing `$readmemh` path.

### 1.4 Width alignment summary

| Concept | silicon-bridge | silicon-hdl | Align? |
|---------|----------------|-------------|--------|
| Parameter / weight word | `u16` Q8.8 | 16-bit `logic` (`DATA_WIDTH` / `PARAM_WIDTH`) | Yes |
| Threshold vector | `FpgaParameters.thresholds: Vec<u16>` | `NeuronParamRam` (threshold instance) | Yes (format) |
| Decay / leak vector | `FpgaParameters.decay_rates: Vec<u16>` | `NeuronParamRam` (leak instance) | Yes (format) |
| Weight matrix flat | `FpgaParameters.weights: Vec<u16>` | `WeightRam` | Yes (format); address mapping is SoC policy |
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

### 2.2 Host multi-byte protocol (silicon-bridge — host only)

`FpgaBridge::process_stimuli` documents **SiliconBridge v3.0** (16-neuron demo
frame). This is a **host ↔ SoC application protocol** layered **on top of** the
byte pipe. It is **not** implemented inside `SiliconBridge.sv`.

```text
Host → FPGA (33 bytes):
  [0]      = 0xAA                    // sync
  [1..32]  = 16 × Q8.8 stimuli       // i16 big-endian each

FPGA → Host (36 bytes):
  [0..31]  = 16 × Q8.8 potentials    // i16 big-endian each
  [32..33] = spike flags             // u16 BE, bit i = neuron i spiked
  [34..35] = switch / aux state      // u16 BE (host currently ignores)
```

| Layer | Owner | Status in this monorepo |
|-------|-------|-------------------------|
| 8-bit UART transport | `UartRx` / `UartTx` / `SiliconBridge` | Implemented |
| 0xAA + multi-word frame codec | Future SoC / protocol FSM (not in bridge lib) | **Not** in `spikenaut_soc_basys3_top` today |
| Host client | silicon-bridge `FpgaBridge` (`uart` feature) | Implemented in Rust |

Current SoC demo wiring (`spikenaut-soc-sv/rtl/Basys3_Top.sv`):

- Instantiates `SiliconBridge` at 100 MHz / 115200 baud (default `DATA_WIDTH=8`).
- Latches `bridge_rx_valid` into `spike_pending` until the next 1 ms `step_en`
  (a one-cycle UART strobe would otherwise miss the gated neuron). Any received
  byte is a binary event; payload bits are not decoded. Multiple bytes inside
  one tick collapse to a single spike.
- One `LifNeuron`; RAMs sit at `addr = 0` after `$readmemh` init (word 0 of each
  wired merged_v2 image).
- `StdpController` is instantiated (classical Bi–Poo, `step_en`-gated) but
  writeback is **open**: `weight_we` / `weight_addr_out` / `weight_out` are left
  unconnected ([#70](https://github.com/rmems/silicon-hdl/issues/70)).
- TX path is disabled (`tx_send = 0`); no spike/potential readback frame.

Until a protocol FSM is added above the bridge, end-to-end
`FpgaBridge::process_stimuli` will not interoperate with the demo bitstream.
That is intentional layering, not a pin-width bug.

### 2.3 No opcodes in RTL

There is **no** opcode register map inside `SiliconBridge`. Any future commands
(load weight, step network, read spikes) belong in a separate SoC protocol
module that:

1. Consumes `rx_data`/`rx_valid` and respects `tx_busy` when driving `tx_send`.
2. Drives `WeightRam` / `NeuronParamRam` write ports and neuron arrays.
3. Keeps the 8-bit transport module unchanged (single source of truth).

---

## 3. Compatibility table (Rust concepts ↔ SV modules / ports)

| Rust (silicon-bridge) | SV module / port / artifact | Match notes |
|-----------------------|-----------------------------|-------------|
| `FixedPointEncode::encode_q88` | 16-bit `din`/`dout` on RAMs; `weight` / `threshold` / `leak` on `LifNeuron` | Same 16-bit word size; RTL unsigned ops |
| `q88_to_f32` / `format_q88_hex` | Host-side only | No RTL equivalent required |
| `FpgaParameters.thresholds` | `NeuronParamRam` (threshold instance) `.din`/`.dout` | 16-bit; separate RAM from leak |
| `FpgaParameters.decay_rates` | `NeuronParamRam` (leak instance) | Mapped as **leak** in LIF (`membrane -= leak`) |
| `FpgaParameters.weights` | `WeightRam` `.din`/`.dout` | Flattened matrix → linear addresses (SoC policy) |
| `MemFileWriter` `.mem` lines | SoC `INIT_FILE` `$readmemh` into RAM arrays | **Wired** in demo top (`merged_v2` defaults); host rewrite later (#63) |
| `EXPORT_FORMAT_VERSION` | Metadata only | No RTL parse |
| `FpgaBridge` open @ 115200 | `SiliconBridge` `BAUD_RATE=115_200` | Match |
| UART 8 data bits | `DATA_WIDTH=8` on bridge/UART | Match |
| Host TX frame `0xAA` + 32 B | *Application layer above bridge* | Not in `SiliconBridge.sv` |
| Host RX 36 B response | *Application layer above bridge* | Not in demo top (`tx_send=0`) |
| Spike flag word (16 bits) | Could map to `spike_out` vector / LED bus | Demo exposes 1 neuron on `led[0]` |
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
| Core RAM / LIF 16-bit vs export `u16` | Match |
| `LifNeuron` `PARAM_WIDTH == DATA_WIDTH` | Enforced by generate `$error` |
| SoC instantiation of bridge vs core widths | Documented split: bridge 8-bit, core 16-bit (by design) |
| Host v3.0 multi-byte frame vs bridge RTL | **Layer gap** (protocol not in bridge); not a port-width bug |
| Signed UART Q8.8 vs unsigned LIF / export | **Semantic gap** on live stimulus path; export path stays unsigned |

**Conclusion:** documentation-only change. No RTL logic edit required for #8
acceptance. Clarifying comments only may be added on `SiliconBridge.sv`.

### Follow-ups (out of scope for this doc PR)

`$readmemh` / `INIT_FILE` is **already on `main`** (E1/E2). Remaining product work is
tracked under finishing epic
[#54](https://github.com/rmems/silicon-hdl/issues/54), not as a missing mem-init path:

- SoC protocol FSM for SiliconBridge v3.0 frames above `SiliconBridge`, TX enabled,
  `tx_busy` respected ([#62](https://github.com/rmems/silicon-hdl/issues/62))
- UART / write-port load of RAMs at runtime ([#63](https://github.com/rmems/silicon-hdl/issues/63))
- Multi-neuron array plus spike-bitmap packing for the 16-neuron host frame
  ([#61](https://github.com/rmems/silicon-hdl/issues/61) / [#64](https://github.com/rmems/silicon-hdl/issues/64))
- Explicit address map from the flattened weight matrix onto `WeightRam` (today: `addr = 0`)
- STDP writeback into `WeightRam` ([#70](https://github.com/rmems/silicon-hdl/issues/70))

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
| silicon-bridge UART host | [`fpga_bridge.rs`](https://github.com/Limen-Neural/silicon-bridge/blob/main/src/fpga_bridge.rs) |
| silicon-bridge boundary matrix | [`docs/boundary-matrix.md`](https://github.com/Limen-Neural/silicon-bridge/blob/main/docs/boundary-matrix.md) |

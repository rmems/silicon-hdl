<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-11-23 -->

# Supervisor parity harness (GH#76)

Replay one public deterministic fixture through the software reference, RTL
simulation, and (manually) a physical Basys 3 — and diff the results with
**exact discrete agreement** as the contract. This is the "reproducible Basys 3
reference path" deliverable of
[#76](https://github.com/rmems/silicon-hdl/issues/76) /
[RM-616](https://linear.app/rpd-34/issue/RM-616).

| Item | Value |
| --- | --- |
| Fixture | `testdata/supervisor_parity/` (`supervisor_parity_v1`) |
| Reference model | `scripts/soc_reference.py` (on `scripts/lif_reference.py`) |
| Generator | `scripts/gen_parity_fixture.py` (`--check` drift gate) |
| Sim testbench | `spikenaut-soc-sv/tb/tb_SocParity.sv` (wire-level UART) |
| Comparator | `scripts/parity_compare.py` → `parity_report.json` |
| Host/HDL profile | silicon-bridge `silicon-hdl-v3-compatible`, contract `silicon-bridge-silicon-hdl-v3-contract-v2` (crate **0.4.0**) |
| Pinned HDL revision | `d45163f` (profile pin; ancestor of `main`) |
| Bank | exp-025 Dale health-PASS, Spikenaut-SNN `6965e12a`, digest-pinned |

## The contract

**Input.** A time-ordered sequence of already-encoded `0xAA` stimulus frames
(16 signed Q8.8 lanes, big-endian, SiliconBridge v3.0). Raw telemetry parsing
stays outside HDL. `inputs.mem` is flat step-major; `inputs_count.mem` bounds
the loop.

**Stimulus semantics.** Binary-event PE: the SoC decodes the *lowest non-zero
lane*, resolves it through the AER table (fixture: identity), and discards
magnitudes — `0x7FFF` and `0xFF00` integrate the same weight as `0x0001`.
An all-zero frame is still consumed and answered, but leak-only
(`route_drop_pending`).

**Schedule (timestep alignment).** Ticks free-run at 1 kHz; a 36-byte response
needs ~3.1 ticks. The contract therefore paces exactly one frame per
**7 ticks**:

- first frame: send ~0.5 ms after reset release → RX_COMMIT ~3.4 ms →
  consumed at **tick 4** (`base_tick`)
- every later frame: capture the full response, wait ~0.5 ms, send →
  RX_COMMIT mid-window ~6.5 ms after the previous consumed tick →
  consumed at `base + i*7` with ±500 µs margin
- the 6 ticks between consumed ticks are leak-only and part of the model.

**Outputs.** Per consumed frame, the 36-byte response = 16 potentials +
spike-flag word + aux (switch) word — post-tick state of the consuming tick.
`output_class` is LED-only and **not** in the frame: recorded as
`sim_only`/unobservable on board runs, never counted as passing.

**Reset.** All membranes/spikes/output_class = 0. `sw=0x0000`: STDP off,
spike-LED view. Parameters are baked into the bitstream via `INIT_FILE`
`$readmemh` — the supported route for this fixture (runtime `0xA5` writes are
covered by #63, not exercised here).

**Tolerance.** None. Spike words, potentials (Q8.8 raw), output class, and the
consumed-tick schedule must match exactly; the report records any divergence
with first-divergence step instead of rounding it away.

## Cold start (simulation, no board)

```bash
# 1. (Re)generate the fixture — digest-gated on the pinned bank
python3 scripts/gen_parity_fixture.py            # or --check to verify

# 2. Replay through the real SoC at UART wire level (run from repo root)
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_SocParity \
  -Ispikenaut-core-sv/rtl -Ispikenaut-bridge-sv/rtl \
  spikenaut-bridge-sv/rtl/{UartRx,UartTx,SiliconBridge}.sv \
  spikenaut-core-sv/rtl/{LifNeuron,LifNeuronArray,WeightRam,NeuronParamRam,StdpController,StdpWriteback,OutputLayer}.sv \
  synapse-link-hdl/src/AerRouteTable.sv \
  spikenaut-soc-sv/rtl/{SocProtocolFsm,SocStatusLeds,Basys3_Top}.sv \
  spikenaut-soc-sv/tb/tb_SocParity.sv
./obj_dir/Vtb_SocParity        # writes testdata/supervisor_parity/observed.json

# 3. Compare → machine-readable report
python3 scripts/parity_compare.py \
  testdata/supervisor_parity/expected_trace.json \
  testdata/supervisor_parity/observed.json \
  -o testdata/supervisor_parity/parity_report.json
```

Exit 0 = parity. Both steps are in `scripts/quality.sh` and CI `sim.yml`.

## Fixture provenance / export route

The parameter images under `testdata/supervisor_parity/` are the pinned
exp-025 bank — byte-identical to what the public Rust API exports:

```rust
// silicon-bridge 0.4.0 (rmems/silicon-bridge)
let mut exporter = FpgaParameterExporter::from_params(thresholds, weights, decay);
exporter.set_output_weights(readout);          // KxN = 3 rows x 16 cols
exporter.write_with_config(dir, &ExportConfig::silicon_hdl_v3())?;
```

Mapping to fixture names: `parameters.mem`/`parameters_decay.mem`/
`parameters_weights.mem` map 1:1; **`hdl_readout_neuron_major.mem` (N×K) is
the fixture's `parameters_output_weights.mem`** — the crate's class-major
`parameters_output_weights.mem` is *not* what `OutputLayer` consumes.

## Board replay (manual, pending)

Shadow/replay only — the board never sends process-control commands.

1. Build/obtain the bitstream matching the fixture parameters (they are
   `INIT_FILE`-baked: the stock `spikenaut_soc_basys3_top` build already
   carries the same pinned bank).
2. Program: `vivado -mode batch -source scripts/program_basys3.tcl` (or the
   batch JTAG script).
3. Explicitly select the serial device (e.g. `COM3` / `/dev/ttyUSB*`), 115200 8N1.
4. Replay `inputs.mem`: per step send the 33-byte `0xAA` frame **only after**
   the previous 36-byte response fully arrived plus ~0.5 ms — that lands
   each frame on consumed tick `4 + i*7` (±0.5 ms margin).
5. Capture each response into the observed.json shape
   (`{step, consumed_tick?, potentials[16], spike_word, aux_word}`; tick index
   is host-inferred from response cadence — record gaps if uncertain).
6. `parity_compare.py --source board` → report; missing `output_class` marks
   the LED-only observable `not_observed`.

**Status: pending hardware capture.** Simulation parity is green; a gated or
unavailable board is pending validation, not completion — per the issue.

## What is deliberately not here

- No STDP writeback parity (optional phase; #70 is merged but learning is off
  in this fixture).
- No wall-clock latency claims: the report separates fabric ticks from
  transport by only ever comparing tick-aligned state, never baud time.
- No multi-lane vector accumulation (binary-event PE per
  `docs/lif-array-connectivity-model.md` / `docs/interface-alignment.md` §2.2).

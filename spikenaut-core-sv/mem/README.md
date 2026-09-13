<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# FPGA parameter / weight images (Q8.8)

Hex `.mem` files for `$readmemh` into `WeightRam` / `NeuronParamRam`.

**Active profile: `merged_v2`** (Spikenaut-SNN best-of 16-neuron export).

| File | Lines | Source (vault) | Meaning |
|---|---|---|---|
| `merged_v2_thresholds.mem` | 16 | `dataset/merged_v2/parameters.mem` | Neuron thresholds |
| `merged_v2_decay.mem` | 16 | `dataset/merged_v2/parameters_decay.mem` | Leak / decay rates |
| `merged_v2_weights.mem` | 256 | `dataset/merged_v2/parameters_weights.mem` | 16×16 hidden weights |
| `merged_v2_output_weights.mem` | 48 | `dataset/merged_v2/parameters_output_weights.mem` | Output layer (signed Q8.8) |

**Format:** one 16-bit Q8.8 hex word per line  
(`0120` = 288/256 = 1.125; `FFF9` = signed −7/256 ≈ −0.027).  
Leading `// SPDX-...` comment lines are allowed (`$readmemh` skips `//` comments).

**Signedness contract (GH#73):** every word in every `.mem` image — weights,
thresholds, decay, output weights — is read as **signed two's-complement Q8.8**
by `LifNeuron`/`LifNeuronArray` (not just `merged_v2_output_weights.mem`).
`0xFF00` is a Dale-inhibitory weight of `-256/256 = -1.0`, not `65280`; it
subtracts from the membrane instead of adding. Thresholds and leak/decay
values happen to never set the sign bit in shipped banks, so they read the
same either way, but the RTL comparisons treat them as signed too — there is
no silent unsigned compare anywhere in the leak/integrate/threshold path. The
host runtime-write path (`SocProtocolFsm` `wr_data`, see
`docs/timestep-contract.md`) carries this same contract: a host writing a
weight/threshold/leak word at runtime must send signed two's-complement Q8.8,
not an unsigned magnitude.

**RTL default:** `parameter string INIT_FILE = "NONE"`. Prefer typed `string`
over bare untyped string parameters: some tools size untyped defaults
narrowly and path overrides misbehave (saw this on free-runner Verilator).
`$fopen` precheck is `` `ifndef SYNTHESIS `` only and fails loudly if the
path is bad; synthesis still uses `$readmemh` for BRAM init.

**Canonical vault path:** `~/Spikenaut-Vault/Spikenaut-SNN/dataset/merged_v2/`  
(also HF `rmems/Spikenaut-SNN`). Re-copy from vault after retrain; do not invent hex by hand.

**Not used here:** `v1_fpga` (8-neuron toy), per-asset `*_v2` clones — use only when a profile switch (E9) is implemented.

Paths passed to `INIT_FILE` are relative to the tool working directory (**repo root**
in free-runner CI and recommended local Verilator). **`scripts/build_soc.tcl`**
`add_files` the three active images and passes **absolute** paths via
`synth_design -generic` (`WEIGHT_INIT_FILE` / `THRESH_INIT_FILE` /
`LEAK_INIT_FILE`) so Vivado `$readmemh` resolves even if the project lives
under `vivado_projects/`.

**SoC (E2 / #39):** `spikenaut_soc_basys3_top` wires:
| Instance | Image | ADDR_WIDTH |
|---|---|---|
| `u_wram` | `merged_v2_weights.mem` | 8 (256 entries) |
| `u_npram_threshold` | `merged_v2_thresholds.mem` | 8 |
| `u_npram_leak` | `merged_v2_decay.mem` | 8 |

`merged_v2_output_weights.mem` is vendored only (not wired until multi-layer).

**Depth:** `$readmemh` loads `min(file lines, 2**ADDR_WIDTH)` words. Match width to the image, e.g. `WeightRam` with `merged_v2_weights.mem` (256 lines) should use `ADDR_WIDTH=8` (not the default 10). Thresholds/decay (16 lines) fit `NeuronParamRam` default `ADDR_WIDTH=8` with room to spare.

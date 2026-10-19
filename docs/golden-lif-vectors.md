<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# Golden LIF vectors (f32 → Q8.8 → `.mem` → Verilator)

Reproducible golden vectors that pin the **signed** LIF datapath (GH#73 / #91)
and the GH#72 output layer against the shipped exp-025 bank.

- Issue: [GH#66](https://github.com/rmems/silicon-hdl/issues/66) / RM-281 (epic
  [#54](https://github.com/rmems/silicon-hdl/issues/54))
- Generated artifacts: [`spikenaut-core-sv/mem/golden/`](../spikenaut-core-sv/mem/golden/)

## What this is for

`tb_LifNeuron.sv` asserts hand-written properties of the signed path. These
vectors are the complementary half: a **numeric trace** taken from real bank
words, replayed tick-for-tick against the RTL, that fails on any drift in the
leak, the integrate, the saturate, or the threshold compare — including the
specific pre-GH#73 regression where `0xFF00` is misread as `+65280` instead of
`-1.0`.

## The path

```
exp-025 bank .mem        scripts/q88.py            scripts/lif_reference.py
(committed, pinned)  ->  decode to f32        ->   bit-exact LIF model
                         re-encode to Q8.8
                              |                          |
                              v                          v
                    spikenaut-core-sv/mem/golden/*.mem  (stimulus + expectations)
                              |
                              v
             tb_LifNeuron_golden / tb_OutputLayer_golden  (Verilator / XSim)
                              |
                              v
                    real LifNeuron.sv / OutputLayer.sv RTL
```

Weights are never authored here. Every `exp-025` scenario word is a decode of a
word already committed under `spikenaut-core-sv/mem/`, and the generator
asserts the re-encode returns that identical word — so the `f32 → Q8.8` leg is
lossless rather than decorative. A small number of scenarios are tagged
`synthetic` in the manifest: they reach behaviour the trained bank cannot
express at all (datapath saturation needs magnitudes near ±128; the bank's
largest word is `410/256` = 1.6).

## Pinned bank

| Item | Value |
|---|---|
| Source | `rmems/Spikenaut-SNN` `dataset/merged_v2/` (exp-025 Dale health-PASS bank) |
| Promoted by | [Spikenaut-SNN#47](https://github.com/rmems/Spikenaut-SNN/pull/47) |
| **Commit pin** | **`6965e12a`** |
| Images | `merged_v2_weights.mem`, `merged_v2_thresholds.mem`, `merged_v2_decay.mem`, `merged_v2_output_weights.mem` |

The committed images under `spikenaut-core-sv/mem/` are byte-identical to the
vault at that commit.

The pin is **enforced, not just recorded**. `BANK_DIGESTS` in
`scripts/gen_golden_lif_vectors.py` holds a SHA-256 for each image and the
generator refuses to run if any of them changes. A length check alone would not
catch a retrain that happened to keep the same word count: every vector would
silently regenerate against new weights while the manifest still claimed
`6965e12a`. The digests are over each image's **canonical word stream** (see
`q88.content_digest`), not its raw bytes, so editing an SPDX header or a
provenance comment does not trip the pin but a single changed weight does. Both
the commit and the digests are echoed into `golden_vectors.json`.

**After an intentional retrain:**

1. Re-copy the images from the vault into `spikenaut-core-sv/mem/`.
2. Bump `SPIKENAUT_BANK_COMMIT`.
3. Recompute the digests:

   ```bash
   python3 -c "import sys; sys.path.insert(0, 'scripts'); import q88; \
     from gen_golden_lif_vectors import BANK_DIGESTS; \
     [print(f'    \"{n}\": \"{q88.content_digest(\"spikenaut-core-sv/mem/\" + n)}\",') for n in BANK_DIGESTS]"
   ```

4. Paste them into `BANK_DIGESTS` and regenerate.

A digest mismatch you did **not** expect means the working tree's bank images
have drifted from the pinned export — investigate that before regenerating.

## Regenerating

```bash
python3 scripts/gen_golden_lif_vectors.py
```

To check without writing (this is the CI gate):

```bash
python3 scripts/gen_golden_lif_vectors.py --check
```

`--check` regenerates into a temporary directory and diffs. It exits non-zero
if the committed vectors differ, so a change to the reference model, the codec,
or the pinned bank cannot land without the vectors being refreshed in the same
commit. It runs in `scripts/quality.sh`, in `.github/workflows/sim.yml`, and
from `tests/test_golden_lif_vectors.py`.

**Regenerate only when the change is intended.** A red golden testbench is
normally telling you the RTL changed behaviour, not that the vectors are stale.

## Running the testbenches

```bash
rm -rf obj_dir
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_LifNeuron_golden \
  -Ispikenaut-core-sv/rtl \
  spikenaut-core-sv/rtl/LifNeuron.sv \
  spikenaut-core-sv/tb/tb_LifNeuron_golden.sv
./obj_dir/Vtb_LifNeuron_golden
```

```bash
rm -rf obj_dir
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_OutputLayer_golden \
  -Ispikenaut-core-sv/rtl \
  spikenaut-core-sv/rtl/WeightRam.sv \
  spikenaut-core-sv/rtl/OutputLayer.sv \
  spikenaut-core-sv/tb/tb_OutputLayer_golden.sv
./obj_dir/Vtb_OutputLayer_golden
```

Both must run **from the repo root** — the golden `.mem` paths are repo-root
relative, matching `tb_WeightRam_init.sv`. Under Vivado, `scripts/sim_core.tcl`
passes absolute paths via `set_property generic`, because XSim's CWD is the sim
run directory.

## What each scenario pins

Full per-tick detail, including every expected membrane value, is in
`spikenaut-core-sv/mem/golden/golden_vectors.json`.

| Scenario | Source | Catches |
|---|---|---|
| `dale_i_subtracts` | exp-025 | `0xFF00` misread as `+65280`. Unsigned, this fires on tick 0 against the row's `115/256` threshold; signed, it must never fire. |
| `dale_i_leak_recovery` | exp-025 | A one-sided leak. The real decay word must pull an inhibited membrane back to exactly `0` without overshooting. |
| `exc_crosses_threshold` | exp-025 | A wrong leak **magnitude** (not just sign): the leak delays the crossing by a tick. Also pins the single-tick pulse and the refractory clear. |
| `mixed_sign_alternating` | exp-025 | Sign handling across repeated zero crossings in both directions. |
| `inhibit_from_positive` | exp-025 | `0xFFFF` (`-1/256`) subtracting from an already-positive membrane. The sharpest unsigned probe in the bank: misread it is `+65535`. |
| `dale_i_row_spike_and_recover` | exp-025 | One real Dale row across fire → refractory → inhibition → recovery. |
| `saturate_positive` | synthetic | A wrapping datapath. Two `+100.0` ticks must pin at `0x7FFF` and fire, not wrap negative and stay silent. |
| `saturate_negative` | synthetic | The mirror: must pin at `0x8000` and never fire. |
| `f32_truncation` | synthetic | Encoder drift: truncate-toward-zero on both signs (`±0.999` → `±255`) and the `1/256` LSB quantum. |

Output-layer vectors sweep ten `spike_bitmap` patterns through the real
`merged_v2_output_weights.mem`, chosen so each of the three classes wins at
least once and so neurons 12–15 (whose output weights are all ≤ 0) drive the
scores negative — which an unsigned misread of that bank would flip.

## How drift is actually proven

Reproducibility alone would not show the vectors assert anything interesting,
so `tests/test_golden_lif_vectors.py` replays the committed vectors through
three deliberately wrong LIF variants (`scripts/lif_reference.py`'s
`Semantics`) and fails if any of them reproduces the golden trace:

| Variant | Must diverge in | Because |
|---|---|---|
| `signed=False` | `dale_i_subtracts` | unsigned misread of the bank |
| `symmetric_leak=False` | `dale_i_leak_recovery` | pre-GH#73 one-sided leak |
| `saturate=False` | `saturate_positive`, `saturate_negative` | wrapping instead of saturating |

The scenario column matters: asserting only "diverges somewhere" would let
unrelated drift mask the failure of the very vector written to catch a variant.
Each variant must diverge **inside its designated scenario**.

The suite also checks codec agreement with silicon-bridge, the f32 round trip
over every word in all four bank images, exact `.mem` lengths, and that every
`exp-025` word sits at the bank address the manifest claims.

## Q8.8 codec: one implementation, and why it lives here

`scripts/q88.py` is the only Q8.8 codec in this repository. It mirrors
silicon-bridge's **signed** `encode_q88_signed` / `q88_signed_to_f32` bit for
bit — same `±127.99` clamp, same truncate-toward-zero, same NaN handling — and
also `encode_q88_signed_full`, the full-range parameter encoder that
silicon-bridge's `.mem` writer actually uses (`-128.0` → `0x8000`, where the
UART clamp gives `0x8003`). The LIF generator below still encodes parameter
words with the UART clamp; that is harmless for the pinned bank (no word has
`|v| > 127.99`) but is an open finding — see the Q8.8 boundary-vector PR. And
`tests/test_golden_lif_vectors.py` re-asserts that crate's own unit-test
vectors against it, so the two cannot drift apart silently.

silicon-bridge's `MemFileWriter::write_mem_files` was **not** reused, because it
encodes through the *unsigned* `FixedPointEncode::encode_q88`, where negatives
clamp to `0`. That path cannot express a Dale-I word at all and would flatten
every inhibitory weight in these vectors to zero — it is on the wrong side of
this repo's signed `.mem` contract (see
[`spikenaut-core-sv/mem/README.md`](../spikenaut-core-sv/mem/README.md)).

> *Stale as of silicon-bridge `1bbb460`:* `FixedPointEncode::encode_q88` now
> encodes with the signed, full-range `encode_q88_signed_full`, so the crate's
> `.mem` writer is on the signed side of this contract. The reason for not
> reusing it today is the cross-repo toolchain dependency, not signedness.

Whether to align silicon-bridge's `.mem` export with the signed convention is a
question for that repo and out of scope here. It is **not tracked there yet** —
the closest existing work is silicon-bridge GH#22 / RM-300 (`MemFileWriter`
`.mem` round-trip tests), which would surface the mismatch.

## Q8.8 saturation boundaries

The vectors above never take the STDP weight path, and the output-layer set
only checks the one-hot argmax of a bank that stays far from ±128. A second
generator, `scripts/gen_golden_q88_boundary.py`, pins the **saturate, never
wrap** half of the Q8.8 contract at the signed edges directly:

| Testbench | What it checks | Vectors |
|---|---|---|
| `tb_StdpController_q88` | `weight_out` / `weight_we` / `weight_addr_out` in the handoff cycle for hold, LTP, LTD and LTP-priority on every boundary weight | 88 |
| `tb_StdpWriteback_q88` | The same updates closed-loop through a real `WeightRam` (RAM word after the sweep, write strobe iff the weight changed, no off-column writes) | 96 (24 groups of 4) |
| `tb_OutputLayer_q88` | Exact `class_acc` words and argmax for cases that land on, step past and back off `0x7FFF` / `0x8000`, plus cases where per-step saturation and a final clamp differ | 13 |

The boundary weights are `0x7FFD..0x7FFF`, `0x8000..0x8002`, `0x0000`,
`0x0001`, `0xFFFF`, `0xFFFE`, plus f32 values run through the **parameter**
encoder `q88.encode_q88_signed_full` (`-128.0` → `0x8000`, `127.99609375` →
`0x7FFF`, `±1e6` saturating to `0x7FFF` / `0x8000`, `±127.99` → `±32765`,
`±0.999` → `±255`, `±1/256`, NaN → `0`, `-1.0` → `0xFF00`), so the encoder's
truncate-toward-zero and i16 saturation feed the same replay. Weights are
parameter words, so they do not use the `±127.99` UART stimulus clamp of
`q88.encode_q88_signed`; silicon-bridge's `.mem` writer
(`encode_q88_signed_full`) and its `docs/host-hdl-contract.md` draw the same
line. The model is plain integer arithmetic over `q88.Q88_RAW_MIN` /
`q88.Q88_RAW_MAX`, written from the contract rather than from the RTL.
`tests/test_golden_q88_boundary.py` checks the model, decodes the committed
images back through it, and shows that wrapping, unsigned saturation, a
final-only clamp and write-on-saturate would each produce different vectors.

```bash
python3 scripts/gen_golden_q88_boundary.py            # regenerate
python3 scripts/gen_golden_q88_boundary.py --check    # drift gate
```

## Files

| Path | Role |
|---|---|
| `scripts/q88.py` | Signed Q8.8 codec + `.mem` read/write |
| `scripts/lif_reference.py` | Bit-exact Python mirror of `LifNeuron.sv`, plus the drift variants |
| `scripts/gen_golden_lif_vectors.py` | Generator and `--check` drift gate |
| `spikenaut-core-sv/mem/golden/*.mem` | Generated stimulus and expectations |
| `spikenaut-core-sv/mem/golden/golden_vectors.json` | Provenance manifest (bank pin, per-tick detail) |
| `spikenaut-core-sv/tb/tb_LifNeuron_golden.sv` | Replays the LIF trace against the RTL |
| `spikenaut-core-sv/tb/tb_OutputLayer_golden.sv` | Replays the argmax vectors against the RTL |
| `tests/test_golden_lif_vectors.py` | Codec, reproducibility, provenance, and drift-discrimination checks |
| `scripts/gen_golden_q88_boundary.py` | Q8.8 saturation-boundary model, generator and `--check` drift gate |
| `spikenaut-core-sv/mem/golden/q88b_*.mem`, `q88_boundary_vectors.json` | Generated boundary vectors and manifest |
| `spikenaut-core-sv/tb/tb_{StdpController,StdpWriteback,OutputLayer}_q88.sv` | Replay the boundary vectors against the RTL |
| `tests/test_golden_q88_boundary.py` | Model, reproducibility and discrimination checks for the boundary vectors |

## Related

- [`docs/timestep-contract.md`](timestep-contract.md) — what one `step_en` tick is
- [`docs/lif-array-connectivity-model.md`](lif-array-connectivity-model.md) — the row/column meaning of the weight bank (#92)
- [`spikenaut-core-sv/mem/README.md`](../spikenaut-core-sv/mem/README.md) — the signed Q8.8 `.mem` contract (GH#73)
- [`docs/host-soc-e2e.md`](host-soc-e2e.md) — the sibling GH#64 golden vectors, which pin the UART **wire framing** rather than network behaviour

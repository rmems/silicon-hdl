<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# Timestep-gated LIF + Vivado on main Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate `LifNeuron` / `StdpController` on a 1 ms SoC `step_en` so `merged_v2` Q8.8 values can integrate, document that contract, and run self-hosted Vivado CI on every push to `main`.

**Architecture:** Fabric clock stays 100 MHz. A divider in `spikenaut_soc_basys3_top` pulses `step_en` one cycle every 100_000 clocks. Core modules update leak/integrate/STDP traces only when `step_en` is 1. Unit TBs always drive `step_en` (1 for existing sequences). No new modules; no board program in CI.

**Tech Stack:** SystemVerilog, Verilator (`bash scripts/quality.sh`), GitHub Actions self-hosted Vivado (`.github/workflows/vivado-ci.yml`), docs under `docs/`.

**Spec:** `docs/superpowers/specs/2026-08-15-timestep-contract-design.md`  
**Issues:** GH #57, #60 · Linear RM-294, RM-287 · assignee **rmems** · project Neuromorphic FPGA / HDL

**Worktree:** Implement on branch `feat/timestep-gated-lif` from current `docs/timestep-contract-spec` (or `main` plus the spec commit). Do not merge the spec-only branch separately.

---

## File map

| File | Responsibility |
| --- | --- |
| `docs/timestep-contract.md` | Public ADR (create) |
| `docs/interface-alignment.md` | Link + `step_en` / tick note |
| `AGENTS.md` | Link ADR under Architecture notes |
| `spikenaut-core-sv/tb/tb_LifNeuron.sv` | Drive `step_en`; hold / one-step cases |
| `spikenaut-core-sv/rtl/LifNeuron.sv` | `step_en` port; gate update |
| `spikenaut-core-sv/tb/tb_StdpController.sv` | Drive `step_en`; traces hold when 0 |
| `spikenaut-core-sv/rtl/StdpController.sv` | `step_en` port; gate traces + LTP/LTD |
| `spikenaut-soc-sv/rtl/Basys3_Top.sv` | 100_000 divider; wire `step_en` |
| `.github/workflows/vivado-ci.yml` | `push: branches: [main]` + job `if:` |
| `docs/releases.md` | Note Vivado on `push` main |
| `CHANGELOG.md` | Unreleased entries |

Do **not** edit: `.mem` images, `synapse-link-hdl`, `WeightRam`, guardian registry, `sim.yml` (same TB names).

---

### Task 1: Public ADR

**Files:**
- Create: `docs/timestep-contract.md`
- Modify: `AGENTS.md` (Architecture notes, after compile-order bullet)
- Modify: `docs/interface-alignment.md` (scope table + Stdp/LIF rows if present)

- [ ] **Step 1: Write `docs/timestep-contract.md`**

```markdown
<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-08-15 -->

# Logical timestep contract

ADR for GitHub [#57](https://github.com/rmems/silicon-hdl/issues/57) /
[#60](https://github.com/rmems/silicon-hdl/issues/60).

## Decision

| Item | Value |
| --- | --- |
| Fabric clock | 100 MHz (10 ns) on Basys 3 `clk` |
| Logical tick | **1 ms** (1 kHz) = **100_000** fabric cycles |
| Enable | One-cycle `step_en` from SoC divider in `spikenaut_soc_basys3_top` |
| Core | `LifNeuron` and `StdpController` update only when `step_en` is 1 |
| STDP `WINDOW_WIDTH` | Counts **ticks**, not fabric clocks |
| Host step | Later [#62](https://github.com/rmems/silicon-hdl/issues/62) may AND/replace the divider |

No breadboard. The on-board oscillator is the only clock.

## Non-goals

- Live board program in CI ([#68](https://github.com/rmems/silicon-hdl/issues/68))
- Multi-neuron time-mux ([#61](https://github.com/rmems/silicon-hdl/issues/61))
- STDP writeback to `WeightRam` ([#70](https://github.com/rmems/silicon-hdl/issues/70))
```

- [ ] **Step 2: Link from `AGENTS.md`**

After the compile-order bullet in `## Architecture notes`, add:

```markdown
- Logical SNN timestep vs fabric clock: [`docs/timestep-contract.md`](docs/timestep-contract.md)
  (1 ms `step_en` from the SoC; LIF/STDP do not update every 100 MHz edge).
```

- [ ] **Step 3: Link from `docs/interface-alignment.md`**

In the scope table, add a row:

```markdown
| Logical timestep / `step_en` | **Documented** | [`docs/timestep-contract.md`](timestep-contract.md); SoC 1 ms divider (#57 / #60) |
```

On the `StdpController` row (search `StdpController`), append: `WINDOW_WIDTH` is in logical ticks; traces update only on `step_en`.

- [ ] **Step 4: Commit**

```bash
git add docs/timestep-contract.md AGENTS.md docs/interface-alignment.md
git commit -m "docs: logical timestep ADR (1 ms SoC step_en) (#57)

Co-authored-by: Grok Build <grok@x.ai>"
```

---

### Task 2: Failing LIF `step_en` tests

**Files:**
- Modify: `spikenaut-core-sv/tb/tb_LifNeuron.sv`

Membrane is not a port. Observe via `spike_out` only.

- [ ] **Step 1: Wire `step_en` and keep existing tests at 1**

Add `logic step_en;` next to `spike_in`. Connect `.step_en (step_en)` on the DUT. In the reset block set `step_en = 1'b1;` so the current integrate/overflow sequences are unchanged.

- [ ] **Step 2: Append hold + one-step cases before the `errors == 0` check**

After `spike_in = 1'b0;` following the overflow test, add:

```systemverilog
        // step_en=0: must not leak or integrate (would fire in a few cycles if ungated)
        rst_n     = 1'b0;
        step_en   = 1'b0;
        spike_in  = 1'b0;
        leak      = 16'd1;
        threshold = 16'd100;
        weight    = 16'd40;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        spike_in = 1'b1;
        repeat (8) @(negedge clk);
        check(spike_out == 1'b0, "step_en=0: spike_out must stay 0 (no integrate)");

        // One tick: one integrate (0 + 40), still below threshold
        step_en = 1'b1;
        @(negedge clk);
        step_en = 1'b0;
        check(spike_out == 1'b0, "one step_en pulse: 40 < 100, no spike");

        // Two more ticks with spike_in: 40-1+40=79, then 79-1+40=118 -> fire
        step_en = 1'b1;
        @(negedge clk);
        step_en = 1'b0;
        @(negedge clk);
        step_en = 1'b1;
        @(negedge clk);
        step_en = 1'b0;
        check(spike_out == 1'b1, "third step_en pulse: membrane crosses 100");
```

- [ ] **Step 3: Run TB — expect compile fail (`step_en` unknown on DUT)**

```bash
rm -rf obj_dir
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_LifNeuron \
  -Ispikenaut-core-sv/rtl \
  spikenaut-core-sv/rtl/LifNeuron.sv \
  spikenaut-core-sv/tb/tb_LifNeuron.sv
```

Expected: Verilator error that `step_en` is not a port of `LifNeuron`.

- [ ] **Step 4: Commit the TB only**

```bash
git add spikenaut-core-sv/tb/tb_LifNeuron.sv
git commit -m "test(core): LifNeuron step_en hold and one-tick cases (#60)

Co-authored-by: Grok Build <grok@x.ai>"
```

---

### Task 3: Implement `LifNeuron.step_en`

**Files:**
- Modify: `spikenaut-core-sv/rtl/LifNeuron.sv`

- [ ] **Step 1: Add port and header**

After `input logic rst_n,` add `input logic step_en,`.

Extend the file header:

```systemverilog
// Updates (leak, integrate, fire) occur only when step_en is 1.
// See docs/timestep-contract.md. Unit TBs drive step_en=1 every cycle.
```

- [ ] **Step 2: Gate the update**

Change the `always_ff` else-branch so hold is explicit:

```systemverilog
        end else if (step_en) begin
            // existing body unchanged (automatic next_mem ... spike_out <= next_spike)
        end
        // else: hold membrane_potential and spike_out
```

Reset still ignores `step_en`.

- [ ] **Step 3: Run TB — expect PASS**

```bash
rm -rf obj_dir
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_LifNeuron \
  -Ispikenaut-core-sv/rtl \
  spikenaut-core-sv/rtl/LifNeuron.sv \
  spikenaut-core-sv/tb/tb_LifNeuron.sv
./obj_dir/Vtb_LifNeuron
```

Expected: `TB_LIFNEURON: ALL TESTS PASSED`

- [ ] **Step 4: Commit**

```bash
git add spikenaut-core-sv/rtl/LifNeuron.sv
git commit -m "feat(core): gate LifNeuron leak/integrate on step_en (#60)

Co-authored-by: Grok Build <grok@x.ai>"
```

---

### Task 4: Failing STDP `step_en` tests

**Files:**
- Modify: `spikenaut-core-sv/tb/tb_StdpController.sv`

Traces are not ports. Infer hold: a pre-spike while `step_en=0` must not arm LTP.

- [ ] **Step 1: Wire `step_en`**

Add `logic step_en;`, connect `.step_en (step_en)`, set `step_en = 1'b1` in reset so existing LTP/LTD/saturation cases stay valid.

- [ ] **Step 2: Append hold case before the final `errors == 0` block**

```systemverilog
        // step_en=0: pre_spike must not load pre_trace (no LTP on later post)
        rst_n      = 1'b0;
        step_en    = 1'b0;
        pre_spike  = 1'b0;
        post_spike = 1'b0;
        weight_in  = 16'd100;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        pre_spike = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        repeat (3) @(negedge clk);

        step_en    = 1'b1;
        post_spike = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        check(weight_we == 1'b0, "pre while step_en=0 must not arm LTP");
        check(weight_out == 16'd100, "weight unchanged when pre was gated off");

        // Contrast: pre on a tick, then hold step_en=0 longer than WINDOW_WIDTH,
        // then post on a tick — traces must still be live (decay is per tick)
        step_en   = 1'b1;
        pre_spike = 1'b1;
        @(negedge clk);
        pre_spike = 1'b0;
        step_en   = 1'b0;
        repeat (WINDOW_WIDTH + 2) @(negedge clk);
        weight_in  = 16'd100;
        step_en    = 1'b1;
        post_spike = 1'b1;
        @(negedge clk);
        post_spike = 1'b0;
        check(weight_we == 1'b1, "trace must hold across fabric cycles without step_en");
        check(weight_out == 16'd101, "LTP after held pre_trace");
```

- [ ] **Step 3: Compile — expect `step_en` not a port**

```bash
rm -rf obj_dir
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_StdpController \
  -Ispikenaut-core-sv/rtl \
  spikenaut-core-sv/rtl/StdpController.sv \
  spikenaut-core-sv/tb/tb_StdpController.sv
```

Expected: Verilator error on `step_en`.

- [ ] **Step 4: Commit TB**

```bash
git add spikenaut-core-sv/tb/tb_StdpController.sv
git commit -m "test(core): StdpController step_en holds traces (#60)

Co-authored-by: Grok Build <grok@x.ai>"
```

---

### Task 5: Implement `StdpController.step_en`

**Files:**
- Modify: `spikenaut-core-sv/rtl/StdpController.sv`

- [ ] **Step 1: Add port**

After `input logic rst_n,` add `input logic step_en,`. Header note: traces and LTP/LTD only on `step_en`; `WINDOW_WIDTH` is in ticks (`docs/timestep-contract.md`).

- [ ] **Step 2: Gate the non-reset body**

```systemverilog
        end else if (step_en) begin
            // existing pre_trace / post_trace / weight_we / weight_out body
        end else begin
            weight_we <= 1'b0;
            // hold traces, weight_addr_out, weight_out
        end
```

When `step_en` is 0, do **not** shift traces and do **not** assert `weight_we`.

- [ ] **Step 3: Run TB — expect PASS**

```bash
rm -rf obj_dir
verilator --binary --timing -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --top-module tb_StdpController \
  -Ispikenaut-core-sv/rtl \
  spikenaut-core-sv/rtl/StdpController.sv \
  spikenaut-core-sv/tb/tb_StdpController.sv
./obj_dir/Vtb_StdpController
```

Expected: `TB_STDPCONTROLLER: ALL TESTS PASSED`

- [ ] **Step 4: Commit**

```bash
git add spikenaut-core-sv/rtl/StdpController.sv
git commit -m "feat(core): gate StdpController traces on step_en (#60)

Co-authored-by: Grok Build <grok@x.ai>"
```

---

### Task 6: SoC 1 ms divider

**Files:**
- Modify: `spikenaut-soc-sv/rtl/Basys3_Top.sv`

`CLK_FREQ` is already `100_000_000`. Divider = `CLK_FREQ / 1000` = 100_000.

- [ ] **Step 1: Add tick generator after `assign rst = ~rst_n;`**

```systemverilog
    localparam int TICK_HZ   = 1000;
    localparam int STEP_DIV  = CLK_FREQ / TICK_HZ; // 100_000
    logic [$clog2(STEP_DIV)-1:0] step_cnt;
    logic                        step_en;

    always_ff @(posedge clk) begin
        if (!rst) begin
            step_cnt <= '0;
            step_en  <= 1'b0;
        end else if (step_cnt == STEP_DIV - 1) begin
            step_cnt <= '0;
            step_en  <= 1'b1;
        end else begin
            step_cnt <= step_cnt + 1'b1;
            step_en  <= 1'b0;
        end
    end
```

- [ ] **Step 2: Wire ports**

On `u_neuron` add `.step_en (step_en),`.  
On `u_stdp` add `.step_en (step_en),`.

- [ ] **Step 3: Replace the E3 leak comment (lines ~86–89)**

```systemverilog
    // Timestep: LifNeuron / StdpController update only on step_en (1 ms).
    // See docs/timestep-contract.md (#57 / #60).
```

- [ ] **Step 4: Commit**

```bash
git add spikenaut-soc-sv/rtl/Basys3_Top.sv
git commit -m "feat(soc): 1 ms step_en divider for LIF and STDP (#60)

Co-authored-by: Grok Build <grok@x.ai>"
```

No new SoC Verilator top. Guardian must still see a single `module LifNeuron` / `StdpController`.

---

### Task 7: Vivado CI on `push` to `main`

**Files:**
- Modify: `.github/workflows/vivado-ci.yml`
- Modify: `docs/releases.md` (Rules item 4 or a short “CI” sentence)

- [ ] **Step 1: Triggers**

Replace the `on:` block with:

```yaml
on:
  workflow_dispatch:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
```

Update the file header comment: auto-runs on same-repo PRs, **push to main**, and dispatch.

- [ ] **Step 2: Job `if:` must allow `push`**

```yaml
    if: >
      github.event_name == 'workflow_dispatch' ||
      github.event_name == 'push' ||
      (github.event_name == 'pull_request' &&
       github.event.pull_request.head.repo.full_name == github.repository)
```

Do **not** add board program steps. Do **not** change runner labels. Artifact name stays `vivado-ci-reports`.

- [ ] **Step 3: `docs/releases.md`**

After “Tag only from **`main`** after free CI is green…”, add: self-hosted **Vivado CI** also runs on `push` to `main` and publishes `vivado-ci-reports` (synth/sim/WNS only; no board flash).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/vivado-ci.yml docs/releases.md
git commit -m "ci: run Vivado workflow on push to main

Co-authored-by: Grok Build <grok@x.ai>"
```

---

### Task 8: CHANGELOG + free-stack verify + PR

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Unreleased notes**

Under `### Added`:

```markdown
- Logical timestep ADR: [`docs/timestep-contract.md`](docs/timestep-contract.md) — 1 ms SoC `step_en` (#57).
```

Under `### Changed`:

```markdown
- `LifNeuron` and `StdpController` update only when `step_en` is high; SoC pulses it at 1 kHz (#60).
- Vivado CI runs on `push` to `main` (self-hosted) as well as PRs / dispatch.
```

- [ ] **Step 2: Run quality**

```bash
bash scripts/quality.sh
```

Expected:

```text
  PASS  dedup_guardian
  PASS  verilator/tb_LifNeuron
  PASS  verilator/tb_WeightRam
  PASS  verilator/tb_NeuronParamRam
  PASS  verilator/tb_StdpController
  ----
  PASS=5 FAIL=0
```

- [ ] **Step 3: Commit CHANGELOG if not already in prior commits**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for timestep gate and Vivado-on-main

Co-authored-by: Grok Build <grok@x.ai>"
```

- [ ] **Step 4: Push and open PR**

```bash
git push -u origin HEAD
gh pr create -R rmems/silicon-hdl \
  --title "feat: 1 ms step_en, gated LIF/STDP, Vivado on main (#57 #60)" \
  --body "$(cat <<'EOF'
## Summary

- ADR: `docs/timestep-contract.md` (1 ms logical tick, SoC-owned `step_en`).
- `LifNeuron` / `StdpController` update only on `step_en`; SoC 100_000-cycle divider.
- Vivado CI: `push` to `main` (self-hosted, reports artifact; no board flash).

Closes #57
Closes #60
EOF
)"
gh pr edit --add-assignee rmems --add-label "hardware,documentation,enhancement"
```

Comment on Linear **RM-294** and **RM-287** with the PR URL, cited **Grok Build: Grok 4.6**. After merge, confirm Actions **Vivado CI** ran on the `main` push.

---

## Spec coverage (self-review)

| Spec item | Task |
| --- | --- |
| 1 ms / 100_000 / SoC owner | 1, 6 |
| Gate LIF | 2–3 |
| Gate STDP; window in ticks | 4–5 |
| Always connect `step_en` | 2, 4, 6 |
| ADR + AGENTS + interface-alignment | 1 |
| Vivado `push` main, no board | 7 |
| TBs hold + one-step | 2, 4 |
| quality.sh | 8 |
| Close #57 #60 / Linear / rmems | 8 |
| Non-goals #61 #62 #68 #69 #70 | not scheduled |

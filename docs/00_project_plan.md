# 00 — Project Plan and Phase Definitions

**IP:** `mlc_cache_controller` — Multi-Level (L1/L2/L3) Cache Controller
**Interfaces:** Custom valid/ready (CPU side) / AXI4 (memory side)
**Document status:** Phase 0 — Baseline, revised after spec review (D-013, D-014).
**Revision:** 0.2 · 2026-09-28

---

## 1. Repository Structure

Merges this project's RTL/doc organization with the flow layout already validated in this
portfolio's `Full-Adder` project (Yosys -> OpenSTA -> OpenROAD, single Makefile, `sky130hd/`
copied in directly) and adds the two verification tiers fixed in D-013.

```
mlc_cache_controller/
├── rtl/
│   ├── top/            mlc_cache_top.sv          integration only, no logic
│   ├── l1/              l1_icache_ctrl.sv, l1_dcache_ctrl.sv
│   ├── l2/              l2_cache_ctrl.sv
│   ├── l3/              l3_cache_ctrl.sv
│   ├── adapter/         l2_l3_width_adapter.sv    line-size adaptation (32B <-> 64B)
│   ├── replace/         plru_tree.sv              parameterized N-way tree-PLRU
│   ├── mem_if/          axi4_fill_engine.sv        AXI4 burst master (L3 <-> memory)
│   └── common/          mlc_pkg.sv, reset_sync.sv
│
├── sim/                          Tier 1 — smoke tests: plain Verilog, class-free, Icarus-runnable
│   ├── tb_l1_icache.v, tb_l1_dcache.v
│   ├── tb_l2.v, tb_plru.v
│   ├── tb_l3.v, tb_adapter.v
│   ├── tb_top.v                  + a small behavioral AXI4 memory model (plain Verilog)
│   └── waveform*.vcd             generated (gitignored except one representative capture)
│
├── tb_uvm/                       Tier 2 — UVM environment: SystemVerilog classes, EXTERNAL simulator
│   ├── transaction.sv, sequence.sv, sequencer.sv
│   ├── driver.sv, monitor.sv, agent.sv
│   ├── scoreboard.sv, env.sv, config.sv, test.sv
│   ├── tb_top_uvm.sv
│   └── README.md                 exact `make uvm SIMULATOR=<tool>` invocation (D-013)
│
├── assertions/          SVA property files (Verilator/formal only — not runnable on Icarus)
├── formal/              SymbiYosys .sby scripts (tool not installed — documented as such)
├── constraints/         SDC (this design is sequential, unlike Full-Adder's purely-combinational
│                        example, so a real clock constraint is required for meaningful STA/PnR)
│
├── scripts/             ALL flow scripts, matching Full-Adder's convention
│   ├── synth.ys                  Yosys synthesis -> Sky130HD
│   ├── sta.tcl                   OpenSTA timing/power
│   ├── pnr_flow.tcl              OpenROAD floorplan/place/route/extract
│   ├── floorplan.tcl, flow_helpers.tcl, helpers.tcl, view_design.tcl
│   └── ppa_sweep.py              capacity/associativity sweep driver
│
├── config/              floorplan.tcl + platform.tcl wrapper (Full-Adder convention)
├── sky130hd/             Sky130HD liberty/LEF/tracks copied in (not symlinked — keeps the repo
│                        self-contained and reproducible without depending on an external path)
│
├── build/
│   └── reports/         stat.txt, timing.txt, power_report.txt (checked in)
├── pnr_results/          final routed DEF/DB/SPEF + routing-DRC report (checked in, PD-04)
├── results/              measured PPA sweep data + generated tables
│
├── docs/                 this documentation set
├── Makefile              synth / sta / pnr / sim / uvm / all / summary / view / clean / distclean
└── README.md
```

**Why this structure.**

1. **RTL is grouped by architectural role, matching the hierarchy itself.** `rtl/l1/`, `rtl/l2/`,
   `rtl/l3/` are separate because each level makes a genuinely different organization/policy
   choice (`01_requirements.md` §1.1); `rtl/adapter/` and `rtl/replace/` are standalone, reusable
   modules used by more than one instance.
2. **Every tool that produces numbers has a script and a checked-in report/results location**, so
   every figure in a document is traceable to a file, never asserted (`no-unverified-numbers`
   policy — `01_requirements.md` §12).
3. **Verification is split into exactly the two tiers this machine's toolchain forces (D-013),
   and each tier's directory says so by its name.** `sim/` is plain Verilog because that is what
   Icarus 12 can actually execute (no classes) — matching `Full-Adder`'s own `sim/` convention
   exactly. `tb_uvm/` is real SystemVerilog UVM, deliberately kept in its own top-level directory
   (not nested under `sim/`) specifically *because* it cannot be run by this repository's own
   tooling — the separation is a statement of fact about execution capability, not a style choice.
4. **The synthesis/STA/PnR flow is unified into `scripts/`+`build/`+`pnr_results/`, matching
   `Full-Adder`**, rather than the earlier `synthesis/`+`sta/` split — this project now runs the
   same one-Makefile, one-`scripts/`-directory flow shape already proven in that project.

---

## 2. Phase Definitions

Each phase has an explicit **Definition of Done**. A phase is not complete because code exists;
it is complete when its acceptance criteria have been *executed* and the results recorded. For
the UVM tier specifically, "executed" means executed by the user on their external simulator —
this repository's own Definition of Done for that tier is scoped to "written, structurally
complete, and documented," never to a pass/fail this session cannot produce (D-013).

---

### PHASE 0 — Requirements and Architecture

| | |
|---|---|
| **Objective** | Fix the hierarchy shape, the interfaces, the address/sizing contract and the architecture before any RTL is written. |
| **Deliverables** | `00_project_plan.md`, `01_requirements.md`, `02_architecture.md`, `03_microarchitecture.md`, `04_interfaces.md`, `engineering_log.md`, `README.md` |
| **Verification** | Design review with the project owner; every scope decision recorded with a tradeoff in `engineering_log.md`, including two revisions made during review itself (D-013, D-014) |
| **Definition of Done** | Hierarchy shape fixed with written justification against alternatives; every requirement tiered MUST/SHOULD/NICE; architecture diagram with named blocks; address partitioning derived and internally consistent; every decision logged with tradeoffs; no un-justified numeric constant |

---

### PHASE 1 — L1 Controllers (I$ and D$), standalone

| | |
|---|---|
| **Objective** | A working, protocol-legal direct-mapped write-through cache controller, smoke-tested standalone, before L2/L3 exist. |
| **Files** | `rtl/common/mlc_pkg.sv`, `rtl/common/reset_sync.sv`, `rtl/l1/l1_icache_ctrl.sv`, `rtl/l1/l1_dcache_ctrl.sv`, `sim/tb_l1_icache.v`, `sim/tb_l1_dcache.v` |
| **Work** | Tag/valid array; 4-state FSM (`IDLE -> TAG_CHECK -> ALLOC_FILL -> UPDATE_TAG`, no eviction state — D-006); single-cycle hit path; byte-enable write merge; downstream port standing in for L2 (driven by a small behavioral stub until Phase 2 exists) |
| **Tests (Tier 1, this repo)** | Reset; cold-miss fill; repeated hit; every byte-enable pattern on a write; back-to-back requests; downstream backpressure held indefinitely; reset mid-fill; I$ instance rejects/ignores write requests — each a directed, self-checking (`$fatal` on mismatch) case in `sim/tb_l1_*.v` |
| **Done when** | `make sim` runs all Tier-1 L1 smoke cases with zero failures on Icarus; Yosys elaborates both modules with zero inferred latches. Comprehensive randomized/coverage-driven verification of L1 is carried by the Tier-2 UVM environment (Phase 5), not this phase. |

---

### PHASE 2 — L2 Controller, standalone

| | |
|---|---|
| **Objective** | A working set-associative write-back controller with tree-PLRU, smoke-tested standalone. |
| **Files** | `rtl/replace/plru_tree.sv`, `rtl/l2/l2_cache_ctrl.sv`, `sim/tb_l2.v`, `sim/tb_plru.v` |
| **Work** | Tag/valid/dirty array per way; PLRU tree (3 bits/set for 4-way, per `03_microarchitecture.md` §2); 5-state FSM including `EVICT_WRITEBACK`; victim write-back only when the selected way's dirty bit is set |
| **Tests (Tier 1)** | `tb_plru.v` exhaustively replays the hand-verified sequences from `03_microarchitecture.md` §2.1 (reset -> access way0 -> access way2, expecting victim=way1) plus every other short sequence up to the same bound, checked against hardcoded expected values — the state space is small enough that this is a genuine exhaustive check, not a sampled one. `tb_l2.v` covers: dirty-victim eviction produces exactly one write-back; clean-victim eviction produces zero; conflict-miss thrashing across all 4 ways in a set. |
| **Done when** | `make sim` runs all Tier-1 L2/PLRU cases with zero failures on Icarus; Yosys elaborates with zero inferred latches. Randomized/coverage-driven verification is Tier 2 (Phase 5). |

---

### PHASE 3 — L3 Controller and Line-Size Adapter

| | |
|---|---|
| **Objective** | The last-level cache, its wider line, the L2<->L3 line-size adapter, and the AXI4 fill engine to memory. |
| **Files** | `rtl/l3/l3_cache_ctrl.sv`, `rtl/adapter/l2_l3_width_adapter.sv`, `rtl/mem_if/axi4_fill_engine.sv`, `sim/tb_l3.v`, `sim/tb_adapter.v` |
| **Work** | The same parameterized write-back controller as L2, elaborated at L3's parameters (FR-17, D-009); adapter sequences the single-half routing described in `03_microarchitecture.md` §3; AXI4 fill engine issues one fixed-length `INCR` burst per line fill/write-back |
| **Tests (Tier 1)** | `tb_adapter.v`: every request routes to the correct half (address bit 5) in both fill and write-back directions, directed. `tb_l3.v`: AXI4 burst shape is fixed and known in advance (D-012), so `ARLEN`/`ARSIZE`/`AWLEN`/`AWSIZE`/burst-type are checked against hardcoded expected values by a small directed Verilog checker — no protocol-assertion framework needed because misalignment cannot occur by construction. |
| **Done when** | `make sim` runs all Tier-1 L3/adapter cases with zero failures on Icarus. Randomized AXI4 traffic and full protocol coverage is Tier 2 (Phase 5). |

---

### PHASE 4 — Full Hierarchy Integration

| | |
|---|---|
| **Objective** | L1-I, L1-D, L2, L3 and the AXI4 memory-side connected as one IP, with a small behavioral memory model standing in for DRAM. |
| **Files** | `rtl/top/mlc_cache_top.sv`, `sim/tb_top.v` (includes a plain-Verilog behavioral AXI4 memory model — feasible because every transfer has the one fixed shape fixed by D-012) |
| **Work** | Wire L1-I/L1-D each to L2; L2 to L3 through the adapter; L3 to the AXI4 fill engine; the fill engine to the behavioral memory model |
| **Tests (Tier 1)** | A directed regression mixing I-fetch and D-access traffic, hand- and script-generated, exercising hits/misses at every level (L1-only, L1+L2, all three) and write-back chains across levels, checked in `sim/tb_top.v` |
| **Done when** | `make sim` runs the Tier-1 integration regression with zero failures on Icarus; zero deadlocks observed under directed backpressure sequences. The **comprehensive** (>=large-N, constrained-random, maximum-coverage) regression this design ultimately needs is the Tier-2 UVM environment (Phase 5) — this phase's directed regression is a bring-up gate, not the final verification claim. |

---

### PHASE 5 — Verification Closure: Tier-2 UVM Environment

| | |
|---|---|
| **Objective** | Build the comprehensive, constrained-random, coverage-driven UVM environment (VR-05..VR-11), matching the structure of this portfolio's `APB_Design_and_Verification` project. |
| **Files** | `tb_uvm/transaction.sv`, `sequence.sv`, `sequencer.sv`, `driver.sv`, `monitor.sv`, `agent.sv`, `scoreboard.sv`, `env.sv`, `config.sv`, `test.sv`, `tb_top_uvm.sv`, `tb_uvm/README.md` |
| **Work** | `uvm_sequence_item` transaction(s) with `rand`/`constraint` fields (VR-06); sequences for cold-miss, repeated-hit, conflict-thrash, dirty/clean eviction, bounded PLRU-exhaustive, and constrained-random mixed traffic (VR-07); a scoreboard driven by a SystemVerilog predictor model of cache state (VR-08); functional coverage groups for hit/miss, eviction dirty/clean, PLRU way selected, backpressure patterns at both interfaces (VR-09) |
| **This repo's Definition of Done** | The environment is structurally complete (every file above exists, compiles conceptually against the standard IEEE 1800.2 UVM API, matches the `APB_Design_and_Verification` file layout), and `tb_uvm/README.md` states the exact external invocation (`make uvm SIMULATOR=<tool>`, OQ-5). **The regression's actual pass/fail result and coverage numbers are explicitly NOT part of this phase's local Definition of Done** — per D-013/VR-10, they cannot be produced without a class-capable simulator this machine does not have. They are recorded, with the log checked in, only once the user runs the environment externally. |

---

### PHASE 6 — Assertions and Formal (best-effort, toolchain-limited)

| | |
|---|---|
| **Objective** | Static proof of properties simulation can only sample, to the extent the installed toolchain allows. |
| **Files** | `assertions/*.sv`, `formal/*.sby` |
| **Work** | AXI4 protocol SVA; FSM reachability; PLRU tree invariant (never selects an invalid way when a valid one exists in the set) |
| **Done when** | Each property is either **proved** (solver output checked in) or **explicitly documented as not attempted / not proved, with the reason** — Verilator and SymbiYosys are not installed on this machine today, so this phase's default outcome is "documented as not run" unless those tools are installed first. |

---

### PHASE 7 — Synthesis (Yosys + Sky130HD)

| | |
|---|---|
| **Objective** | Real gate-level results on Sky130HD. |
| **Files** | `scripts/synth.ys`, `build/reports/` |
| **Work** | Yosys flow targeting `sky130hd_tt.lib` (copied into `sky130hd/` per the repo-structure decision above); zero inferred latches/tri-states; area and cell reports per configuration |
| **Done when** | Synthesis completes with zero errors and zero latch inferences for the default configuration and for each point in the capacity/associativity sweep; reports checked in; **measured** area and cell counts recorded (`make synth`) |

---

### PHASE 8 — Static Timing Analysis

| | |
|---|---|
| **Objective** | Know the critical path, not guess it. |
| **Files** | `constraints/*.sdc`, `scripts/sta.tcl`, `build/reports/timing.txt`, `power_report.txt` |
| **Work** | SDC with clock and I/O delays; OpenSTA setup/hold against `sky130hd_tt.lib`; Fmax by constraint sweep |
| **Done when** | Worst slack, critical path and logic depth reported from checked-in report files (`make sta`) for each configuration; the tag-compare critical-path prediction from `03_microarchitecture.md` §5 compared against measurement and any discrepancy explained |

---

### PHASE 9 — Place and Route (OpenROAD)

| | |
|---|---|
| **Objective** | Carry the synthesized netlist through a real physical implementation on Sky130HD (PD-01..PD-05, D-014). |
| **Files** | `scripts/pnr_flow.tcl`, `scripts/floorplan.tcl`, `config/floorplan.tcl`, `config/platform.tcl`, `pnr_results/` |
| **Work** | Floorplan, PDN generation, global placement, detailed placement, detailed routing, extraction, via OpenROAD (confirmed installed and runnable, `v2.0-25346-gc62be3f952`) |
| **Done when** | `make pnr` completes with a legal, DRC-clean routed design **on the L1 instance first** (PD-03's staged approach), with results checked into `pnr_results/`; the full hierarchy attempted next, with runtime and any congestion/DRC issues reported honestly if full-size P&R does not close (OQ-6) rather than silently substituting the smaller result |

---

### PHASE 10 — PPA Sweep

| | |
|---|---|
| **Objective** | Treat the direct-mapped-vs-set-associative and write-through-vs-write-back tradeoffs as measured experiments, not assertions. |
| **Files** | `scripts/ppa_sweep.py`, `results/` |
| **Work** | Sweep capacity/associativity per level and true-LRU-vs-PLRU replacement-state area, recording area/Fmax at each point |
| **Done when** | Each comparison documented as *configuration -> measured area -> measured Fmax -> tradeoff observed*, with numbers from checked-in reports only |

---

### PHASE 11 — Final Integration and Regression

| | |
|---|---|
| **Objective** | Everything this repository can itself run is green simultaneously, from a clean clone. |
| **Done when** | Fresh clone -> `make sim`, `make synth`, `make sta`, `make pnr` all succeed with only the toolchain listed in §5; `tb_uvm/` is present, documented, and its external invocation is a copy-paste away; no stale reports; no requirement left un-traced |

---

### PHASE 12 — Documentation and Portfolio Packaging

| | |
|---|---|
| **Objective** | Make the work legible to a reviewer in ten minutes. |
| **Done when** | Every number in the README cites a report file or is labelled **NOT YET MEASURED** (locally-runnable figures) or **NOT YET RUN (external simulator required)** (the UVM tier), never conflated; build/simulate/synthesize/PnR instructions verified by following them literally on a clean checkout |

---

## 3. Cross-Phase Rules

1. **No number without provenance.** Any figure in any document either cites a checked-in report
   file or carries the label **NOT YET MEASURED** / **NOT YET RUN (external simulator required)**
   as appropriate (`01_requirements.md` §12, DR-03). Applies retroactively to earlier documents.
2. **No phase closes on inspection.** Acceptance criteria are executed, and their output recorded
   — except where a phase's own Definition of Done explicitly scopes execution to outside this
   session (Phase 5's UVM tier), in which case "done" means "correctly written and documented,"
   stated as such, never quietly reinterpreted as "passing."
3. **Architecture changes are documented before they are implemented.** Sequence: log the reason
   -> update `02_architecture.md` -> update affected documents -> then change RTL.
4. **The engineering log is updated in the phase the decision is made**, not reconstructed later
   — including mid-review revisions, as D-013/D-014 demonstrate.
5. **Failed experiments are kept.** A documented failed optimization or a P&R run that doesn't
   close is evidence of engineering judgement, not something to hide.

---

## 4. Risks and Technical Challenges

| # | Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|---|
| R1 | Blocking-miss decision (D-004) understates real cache performance behavior a reviewer might expect | Portfolio piece reads as "textbook" rather than "high-performance" | Medium | README states the blocking-miss scope explicitly as a deliberate v1 boundary; non-blocking/MSHR named as a future phase |
| R2 | The Tier-2 UVM regression's pass/fail result depends entirely on the user running it on an external simulator (D-013) | The comprehensive, "maximum coverage" verification this project's owner explicitly asked for may never actually be executed and checked in | **Confirmed, active** | Tier 1 (plain-Verilog smoke, this repo) guarantees the project is never left with zero locally-verified evidence; `tb_uvm/README.md` gives the exact external command so running it is a copy-paste; every UVM figure stays labelled NOT YET RUN until it happens |
| R3 | L2<->L3 line-size adapter (2:1 ratio) has an off-by-one or ordering bug in the beat sequencer | Silent data corruption on lines that cross the adapter | Medium | Phase 3 DoD requires an exhaustive directed test of both split and merge directions |
| R4 | Direct-mapped L1 thrashes badly on adversarial access patterns in the integration regression, understating L2/L3 test coverage | Weak measured evidence for L2/L3 logic at Tier 1 | Medium | Phase 4 Tier-1 regression includes a directed pattern designed to force L1 conflict misses specifically to drive traffic into L2/L3 |
| R5 | Yosys+ABC synthesis runtime at 8-way/512-set L3 (the largest tag/PLRU array) is slow | PPA sweep truncated | Medium | Bring the flow up on L1 (smallest) first; scale up recording runtime at each step |
| R6 | Scope creep toward non-blocking misses or coherency mid-project | Project never reaches synthesis/STA/PnR | Medium | D-001/D-004 fix these out of v1 scope; any revisit requires a new logged decision |
| R7 | OpenROAD P&R (Phase 9) does not close cleanly at full hierarchy size — congestion, routing runtime, or DRC violations on the largest (L3) tag/PLRU array | PnR deliverable incomplete at full size | Medium, **not yet known either way** | PD-03: attempt P&R on L1 alone first, scale up; if full-size P&R does not close, report the actual outcome (including which stage failed) rather than substituting a smaller result silently (D-014) |

---

## 5. Toolchain — Verified State

| Tool | Status | Version | Use |
|---|---|---|---|
| Icarus Verilog | **installed** | 12.0 | Tier-1 smoke-test simulator |
| Yosys | **installed** | 0.33 | Synthesis |
| OpenSTA | **installed** | 2.7.0 | Timing analysis |
| OpenROAD | **installed, verified runnable** | v2.0-25346-gc62be3f952 (`/usr/local/bin/openroad`) | Place and route (Phase 9, D-014) |
| GTKWave | **installed** | — | Waveform viewing |
| Python | **installed** | 3.13.9 | PPA sweep driver / report parsing (not part of Tier-1 verification — see D-013) |
| Sky130HD Liberty (`sky130hd_tt.lib`) | **present** | — | Copied into `sky130hd/`; primary synthesis/STA/PnR target |
| Sky130HD LEF | **present** | — | Copied into `sky130hd/`; used by Phase 9 P&R |
| A class-capable SystemVerilog simulator (VCS / Questa / Xcelium) | **not installed** | — | Required only for the Tier-2 UVM environment (`tb_uvm/`), supplied externally by the user (D-013) |
| UVM library (IEEE 1800.2 / Accellera UVM 1.2) | **not installed** | — | Bundled with, or supplied alongside, whichever external simulator runs `tb_uvm/` |
| Verilator | **not installed** | — | Phase 6 prerequisite |
| SymbiYosys + solver | **not installed** | — | Phase 6 prerequisite |

**Notable constraint, verified directly (not assumed) during spec review (D-013):** attempting to
compile this portfolio's existing `APB_Design_and_Verification` UVM testbench on this machine
fails immediately (`Include file uvm_macros.svh not found`) — no UVM library is installed, and
Icarus 12 has no SystemVerilog class support regardless. This is why verification is split into
two tiers rather than being UVM-only: Tier 1 (plain Verilog, this repo, Icarus) always runs here;
Tier 2 (UVM, `tb_uvm/`) is written to the full standard but requires the user's external
simulator to actually execute.

---

*See `engineering_log.md` for the reasoning behind every decision referenced above.*
*Next document: `01_requirements.md`*

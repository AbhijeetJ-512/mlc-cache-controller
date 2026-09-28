# 00 — Project Plan and Phase Definitions

**IP:** `mlc_cache_controller` — Multi-Level (L1/L2/L3) Cache Controller
**Interfaces:** Custom valid/ready (CPU side) / AXI4 (memory side)
**Document status:** Phase 0 — Baseline. Approved for Phase 1 entry pending spec review.
**Revision:** 0.1 · 2026-09-28

---

## 1. Repository Structure

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
├── tb/
│   └── cocotb/
│       ├── model/       Python functional golden model (cache state, not timing)
│       ├── env/         CPU-side driver/monitor, AXI4 driver/monitor, scoreboard, coverage
│       └── tests/       one file per test scenario
│
├── assertions/          SVA property files (Verilator/formal only — not runnable on Icarus)
├── formal/              SymbiYosys .sby scripts (tool not installed — documented as such)
├── constraints/         SDC per configuration
├── scripts/             build glue, capacity/associativity sweep driver, report parsers
├── sim/                 simulation build artefacts (gitignored)
├── synthesis/
│   ├── scripts/         Yosys scripts (Sky130HD liberty path as only external dependency)
│   └── reports/         checked-in synthesis reports
├── sta/
│   ├── scripts/         OpenSTA scripts
│   └── reports/         checked-in timing reports
├── results/             measured PPA sweep data + generated tables
├── docs/                this documentation set
└── README.md
```

**Why this structure.**

1. **RTL is grouped by architectural role, matching the hierarchy itself.** `rtl/l1/`, `rtl/l2/`,
   `rtl/l3/` are separate because each level makes a genuinely different organization/policy
   choice (see `01_requirements.md` §1.1); `rtl/adapter/` and `rtl/replace/` are pulled out as
   standalone, reusable modules rather than folded into a specific level's controller, because
   the line-size adapter and the PLRU tree are both used by more than one instance and neither
   is conceptually part of "being a cache controller."
2. **Every tool that produces numbers has a `scripts/`/`reports/` pair, checked in**, so every
   figure in a document is traceable to a file, never asserted (`no-unverified-numbers` policy —
   see engineering log D-000 note below and `01_requirements.md` §12).
3. **Verification is separated by what can execute it.** `tb/cocotb/` runs on Icarus today.
   `assertions/` and `formal/` need tools not currently installed on this machine (Verilator,
   SymbiYosys) and are kept isolated so a reviewer with only Icarus still gets a working
   regression — same rationale as prior portfolio IP, and a direct consequence of the toolchain
   constraints recorded in memory (`vlsi-toolchain-reality`).

---

## 2. Phase Definitions

Each phase has an explicit **Definition of Done**. A phase is not complete because code exists;
it is complete when its acceptance criteria have been *executed* and the results recorded.

---

### PHASE 0 — Requirements and Architecture

| | |
|---|---|
| **Objective** | Fix the hierarchy shape, the interfaces, the address/sizing contract and the architecture before any RTL is written. |
| **Deliverables** | `00_project_plan.md`, `01_requirements.md`, `02_architecture.md`, `03_microarchitecture.md`, `04_interfaces.md`, `engineering_log.md`, `README.md` |
| **Verification** | Design review with the project owner (this brainstorming session); every scope decision recorded with a tradeoff in `engineering_log.md` |
| **Definition of Done** | Hierarchy shape (levels, associativity, write policy, inclusion policy, miss handling) fixed with written justification against alternatives; every requirement tiered MUST/SHOULD/NICE; architecture diagram with named blocks and stated responsibilities; address partitioning derived and internally consistent across all three levels; every decision logged with tradeoffs; no un-justified numeric constant |

---

### PHASE 1 — L1 Controllers (I$ and D$), standalone

| | |
|---|---|
| **Objective** | A working, protocol-legal direct-mapped write-through cache controller, verified standalone against a golden model, before L2/L3 exist. |
| **Files** | `rtl/common/mlc_pkg.sv`, `rtl/common/reset_sync.sv`, `rtl/l1/l1_icache_ctrl.sv`, `rtl/l1/l1_dcache_ctrl.sv`, `tb/cocotb/model/l1_ref.py`, `tb/cocotb/env/cpu_driver.py`, `tb/cocotb/tests/test_l1.py` |
| **Work** | Tag/valid array; 4-state FSM (`IDLE -> TAG_CHECK -> ALLOC_FILL -> UPDATE_TAG`, no eviction/write-back state — see D-006); single-cycle hit path; byte-enable write merge; downstream request/response port standing in for L2 (driven by a behavioral model until Phase 2 exists) |
| **Tests** | Cold-miss fill; repeated hit; every byte-enable pattern on a write; back-to-back requests; downstream backpressure held indefinitely; reset mid-fill; I$ instance rejects/ignores write requests |
| **Done when** | All tests pass under cocotb+Icarus against the Python reference for >= 100k randomized CPU-side transactions per instance; Yosys elaborates both modules with zero inferred latches |

---

### PHASE 2 — L2 Controller, standalone

| | |
|---|---|
| **Objective** | A working set-associative write-back controller with tree-PLRU, verified standalone against a golden model. |
| **Files** | `rtl/replace/plru_tree.sv`, `rtl/l2/l2_cache_ctrl.sv`, `tb/cocotb/model/l2_ref.py`, `tb/cocotb/tests/test_l2.py`, `tb/cocotb/tests/test_plru.py` |
| **Work** | Tag/valid/dirty array per way; PLRU tree (3 bits/set for 4-way); 5-state FSM including `EVICT_WRITEBACK`; victim write-back only when the selected way's dirty bit is set |
| **Tests** | PLRU tree exhaustively checked against a reference permutation model for every access sequence up to a bounded length; dirty-victim eviction produces exactly one write-back per eviction; clean-victim eviction produces zero write-backs; conflict-miss thrashing across all 4 ways in a set |
| **Done when** | Bit-exact match against the Python reference for the cache-state model (which lines are present, which are dirty, which way PLRU would select) across a randomized access-sequence regression; Yosys elaborates with zero inferred latches |

---

### PHASE 3 — L3 Controller and Line-Size Adapter

| | |
|---|---|
| **Objective** | The last-level cache, its wider line, the L2<->L3 line-size adapter, and the AXI4 fill engine to memory. |
| **Files** | `rtl/l3/l3_cache_ctrl.sv`, `rtl/adapter/l2_l3_width_adapter.sv`, `rtl/mem_if/axi4_fill_engine.sv`, `tb/cocotb/env/axi4_driver.py` (AXI4 memory-side responder model), `tb/cocotb/tests/test_l3.py`, `tb/cocotb/tests/test_adapter.py` |
| **Work** | 8-way write-back L2 controller variant reused with L3 parameters (see `01_requirements.md` PM-xx — the same `rtl/l2/`-style controller is instantiated for L3 as it shares the write-back+PLRU organization; only `rtl/adapter/` and `rtl/mem_if/` are new modules; see D-009); adapter sequences 2 L2-line beats per L3 line; AXI4 fill engine issues one fixed-length `INCR` burst per line fill/write-back |
| **Tests** | Adapter correctly splits/merges every L3 line into exactly 2 ordered L2-line beats in both directions; AXI4 burst length/size fixed and correct for the configured `L3_LINE_BYTES`/`AXI_DATA_W`; AXI4 protocol assertions (from a lightweight cocotb-based checker, since SVA is not runnable here) pass on every transfer |
| **Done when** | End-to-end line fill and write-back verified byte-exact against the reference model through the full L2<->adapter<->L3<->AXI4 path; zero AXI4 protocol violations over a randomized regression |

---

### PHASE 4 — Full Hierarchy Integration

| | |
|---|---|
| **Objective** | L1-I, L1-D, L2, L3 and the AXI4 memory-side connected as one IP, with a behavioral memory model standing in for DRAM. |
| **Files** | `rtl/top/mlc_cache_top.sv`, `tb/cocotb/env/mem_model.py` (AXI4 slave behavioral memory), `tb/cocotb/tests/test_integration.py` |
| **Work** | Wire L1-I/L1-D each to L2; L2 to L3 through the adapter; L3 to the AXI4 fill engine; the fill engine to the behavioral memory model |
| **Tests** | End-to-end load/store traffic mixing I-fetch and D-access streams; every miss propagates correctly through however many levels are actually missed (L1-only, L1+L2, or all three); write-back chains correctly across levels on eviction; sustained random traffic with no data corruption |
| **Done when** | >= 1,000,000 randomized CPU-side transactions (mixed I$/D$) match the Python reference bit-exactly; zero deadlocks under randomized backpressure at every interface |

---

### PHASE 5 — Verification Closure

| | |
|---|---|
| **Objective** | Turn the growing test collection into a real regression with coverage. |
| **Files** | `tb/cocotb/env/scoreboard.py`, `tb/cocotb/env/coverage.py`, full `tb/cocotb/tests/` |
| **Work** | End-of-test drain checking; functional coverage model (hit/miss per level, eviction dirty/clean, PLRU way selection, backpressure patterns, reset-mid-operation); regression runner |
| **Tests** | All scenarios listed in `01_requirements.md` §8 |
| **Done when** | Single `make regress` runs the full suite on a clean machine; **measured** functional coverage reported against closure criteria stated in advance; no test passes by absence of checking |

---

### PHASE 6 — Assertions and Formal (best-effort, toolchain-limited)

| | |
|---|---|
| **Objective** | Static proof of properties simulation can only sample, to the extent the installed toolchain allows. |
| **Files** | `assertions/*.sv`, `formal/*.sby` |
| **Work** | AXI4 protocol SVA; FSM reachability; PLRU tree invariant (never selects an invalid way when a valid one exists in the set) |
| **Done when** | Each property is either **proved** (solver output checked in) or **explicitly documented as not attempted / not proved, with the reason** — per `vlsi-toolchain-reality`, Verilator and SymbiYosys are not installed on this machine today, so this phase's default outcome is "documented as not run" unless those tools are installed first. No property is reported as proved without a checked-in result. |

---

### PHASE 7 — Synthesis (Yosys + Sky130HD)

| | |
|---|---|
| **Objective** | Real gate-level results on Sky130HD. |
| **Files** | `synthesis/scripts/synth.ys`, `synthesis/reports/` |
| **Work** | Yosys flow targeting `sky130hd_tt.lib` (present on this machine at `/home/abhi/Documents/VLSI/OpenROAD/test/sky130hd/`); zero inferred latches/tri-states; area and cell reports per configuration |
| **Done when** | Synthesis completes with zero errors and zero latch inferences for the default configuration and for each point in the capacity/associativity sweep (PM-xx); reports checked in; **measured** area and cell counts recorded |

---

### PHASE 8 — Static Timing Analysis

| | |
|---|---|
| **Objective** | Know the critical path, not guess it. |
| **Files** | `constraints/*.sdc`, `sta/scripts/sta.tcl`, `sta/reports/` |
| **Work** | SDC with clock and I/O delays; OpenSTA setup/hold against `sky130hd_tt.lib`; Fmax by constraint sweep |
| **Done when** | Worst slack, critical path and logic depth reported from checked-in report files for each configuration; the tag-compare critical-path prediction from `03_microarchitecture.md` compared against measurement and any discrepancy explained |

---

### PHASE 9 — PPA Sweep

| | |
|---|---|
| **Objective** | Treat the direct-mapped-vs-set-associative and write-through-vs-write-back tradeoffs as measured experiments, not assertions. |
| **Files** | `scripts/ppa_sweep.py`, `results/` |
| **Work** | Sweep capacity/associativity per level and true-LRU-vs-PLRU replacement-state area, recording area/Fmax at each point |
| **Done when** | Each comparison documented as *configuration -> measured area -> measured Fmax -> tradeoff observed*, with numbers from checked-in reports only |

---

### PHASE 10 — Final Integration and Regression

| | |
|---|---|
| **Objective** | Everything green simultaneously, from a clean clone. |
| **Done when** | Fresh clone -> `make regress`, `make synth`, `make sta` all succeed on a machine with only the open-source toolchain listed in §5; no stale reports; no requirement left un-traced |

---

### PHASE 11 — Documentation and Portfolio Packaging

| | |
|---|---|
| **Objective** | Make the work legible to a reviewer in ten minutes. |
| **Done when** | Every number in the README cites a report file or is labelled **NOT YET MEASURED**; build/simulate/synthesize instructions verified by following them literally on a clean checkout |

---

## 3. Cross-Phase Rules

1. **No number without provenance.** Any figure in any document either cites a checked-in report
   file or carries the label **NOT YET MEASURED**. Applies retroactively to earlier documents.
2. **No phase closes on inspection.** Acceptance criteria are executed, and their output recorded.
3. **Architecture changes are documented before they are implemented.** Sequence: log the reason
   -> update `02_architecture.md` -> update affected documents -> then change RTL.
4. **The engineering log is updated in the phase the decision is made**, not reconstructed later.
5. **Failed experiments are kept.** A documented failed optimization is evidence of engineering
   judgement, not something to hide.

---

## 4. Risks and Technical Challenges

| # | Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|---|
| R1 | Blocking-miss decision (D-004) understates real cache performance behavior a reviewer might expect | Portfolio piece reads as "textbook" rather than "high-performance" | Medium | README states the blocking-miss scope explicitly as a deliberate v1 boundary, with non-blocking/MSHR called out as a named, scoped stretch phase — not hidden |
| R2 | Icarus 12 has no classes/covergroups/concurrent SVA (`vlsi-toolchain-reality`) | UVM-style verification physically cannot run | **Confirmed, active** | cocotb-based verification from Phase 1 onward; SVA/formal isolated to Phase 6 and explicitly marked toolchain-limited |
| R3 | L2<->L3 line-size adapter (2:1 ratio) has an off-by-one or ordering bug in the beat sequencer | Silent data corruption on lines that cross the adapter | Medium | Phase 3 DoD requires an exhaustive directed test of both split (L3->L2) and merge (L2->L3) directions before integration |
| R4 | Direct-mapped L1 thrashes badly on adversarial (conflicting) access patterns in the integration regression, making the regression's effective coverage of L2/L3 miss paths low | Weak measured evidence for L2/L3 logic | Medium | Phase 4 test plan includes a directed address pattern designed to force L1 conflict misses on every access, specifically to drive traffic into L2/L3 |
| R5 | Yosys+ABC synthesis runtime at 8-way/512-set L3 (the largest tag/PLRU array) is slow | PPA sweep truncated | Medium | Bring the flow up on L1 (smallest) first; scale up recording runtime at each step, as done in prior portfolio IP for the `MAC_UNITS` sweep |
| R6 | Scope creep toward non-blocking misses or coherency mid-project | Project never reaches synthesis/STA | Medium | D-001/D-004 fix these out of v1 scope in the engineering log; any revisit requires a new logged decision, not a quiet expansion |

---

## 5. Toolchain — Verified State

Per memory (`vlsi-toolchain-reality`), checked 2026-08-17 on this machine:

| Tool | Status | Version | Use |
|---|---|---|---|
| Icarus Verilog | **installed** | 12.0 | Primary simulator |
| Yosys | **installed** | 0.33 | Synthesis |
| OpenSTA | **installed** | 2.7.0 | Timing analysis |
| GTKWave | **installed** | — | Waveform viewing |
| Python | **installed** | 3.13.9 | Reference model |
| Sky130HD Liberty (`sky130hd_tt.lib`) | **present** | — | `/home/abhi/Documents/VLSI/OpenROAD/test/sky130hd/` — primary synthesis target |
| Sky130HD LEF | **present** | — | same directory — available if a P&R step is added later (not in current scope; user asked for synthesis, not full P&R) |
| cocotb | **not installed** | — | Phase 1 prerequisite (`pip install cocotb`) |
| Verilator | **not installed** | — | Phase 6 prerequisite |
| SymbiYosys + solver | **not installed** | — | Phase 6 prerequisite (risk R2 in this doc corresponds to `vlsi-toolchain-reality` memory) |

**Notable constraint (unchanged from prior portfolio IP):** Icarus 12 supports no classes, no
`randomize()`, no covergroups and no concurrent SVA — a UVM testbench cannot run here. This is
why verification is cocotb-based from Phase 1, not a stylistic preference.

---

*See `engineering_log.md` for the reasoning behind every decision referenced above.*
*Next document: `01_requirements.md`*

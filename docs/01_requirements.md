# 01 — Requirements Specification

**IP:** `mlc_cache_controller` — Multi-Level (L1/L2/L3) Cache Controller
**Interfaces:** Custom valid/ready (CPU side) / AXI4 (memory side)
**Document status:** Phase 0 — Baseline. Approved for Phase 1 entry pending spec review.
**Revision:** 0.1

---

## 1. Project Objective

Design, verify and synthesize a reusable, parameterized, single-core, three-level cache
hierarchy controller suitable for sitting between a CPU core (or a CPU-side test harness
standing in for one) and a memory system.

The IP shall:

- present a split L1 instruction and data cache to the CPU side, each direct-mapped and
  write-through,
- present a unified L2 (set-associative, write-back) and a unified L3 (set-associative,
  write-back, wider line) behind L1,
- adapt L2's line size to L3's wider line at the L2/L3 boundary,
- fetch and write back cache lines to main memory over AXI4 from L3,
- scale per-level capacity and associativity through parameters alone, with no source changes,
- be synthesizable to Sky130HD standard cells via Yosys with zero inferred latches.

### 1.1 Non-Objectives

Explicitly out of scope, to bound the project. Each exclusion was a decision made during
brainstorming, not an oversight — see the cross-referenced engineering log entry for the full
reasoning.

| Excluded | Reason | Log |
|---|---|---|
| Multi-core cache coherency (MESI/MSI, snooping) | A coherency protocol's verification matrix (snoop races, invalidation ordering across agents) is realistically its own multi-phase project, not a sub-scope of a single-core controller; see D-001. | D-001 |
| Non-blocking misses / MSHRs / hit-under-miss | Multiplies verification state space (miss merging, replay ordering, MSHR-full backpressure) well beyond what a v1 scope should carry; named as an explicit future phase, not silently dropped. | D-004 |
| Virtual memory / TLB / address translation | This is a cache controller project, not an MMU project. The CPU-side interface takes physical addresses directly. | D-011 |
| Inclusive or exclusive inter-level policy (back-invalidation, victim-insertion) | Both exist primarily to bound coherency snoop traffic, which does not apply in a single-core, no-coherency design; paying either policy's complexity here buys no offsetting benefit. | D-008 |
| Unaligned / narrow / partial AXI4 transfers | Every fill or write-back is exactly one cache line; keeps the AXI4 compliance surface small and matches how a real LLC talks to memory. | D-012 |
| Full physical place-and-route | The stated deliverable is synthesis with Yosys targeting Sky130HD, not a full P&R flow. Sky130HD LEF files are present on this machine if P&R is added as a later, explicitly-scoped phase. | — |

---

## 2. Requirement Tiers

Requirements are tagged:

- **[M]** MUST HAVE — the IP is not functional or not sign-off-able without it.
- **[S]** SHOULD HAVE — expected in the final deliverable; may be deferred one phase.
- **[N]** NICE TO HAVE — implemented only if schedule permits; never blocks sign-off.

Each requirement carries an ID of the form `FR-nn` (functional), `NR-nn` (address/sizing),
`PF-nn` (performance), `CR-nn` (clock/reset), `PM-nn` (parameterization), `VR-nn`
(verification), `SR-nn` (synthesis), `TR-nn` (timing), `AR-nn`/`PW-nn` (area/power), `DR-nn`
(documentation).

---

## 3. Functional Requirements

### 3.1 Common Behavior (all levels)

| ID | Tier | Requirement |
|---|---|---|
| FR-01 | M | Each level shall accept one outstanding CPU/upstream-side request at a time and respond either combinationally (hit) or after a fill (miss) — no level shall silently drop a request. |
| FR-02 | M | A hit shall be detected by comparing the request address's tag field against the stored tag of the addressed set/way(s), qualified by the valid bit. |
| FR-03 | M | On a read hit, the addressed word shall be returned in the same cycle the request is accepted (see PF-01). |
| FR-04 | M | On a write hit, the byte-enabled bytes of the addressed line shall be updated in the array in the same cycle the request is accepted. |
| FR-05 | M | On a miss, the controller shall deassert its upstream-facing ready signal for the full duration of the resulting fill (and any write-back it triggers), per the blocking-miss decision (D-004). |
| FR-06 | M | Reset shall clear every valid bit at every level. Tag, data and dirty-bit contents are don't-care until a line is validated by a fill. |

### 3.2 L1 (Direct-Mapped, Write-Through)

| ID | Tier | Requirement |
|---|---|---|
| FR-07 | M | L1 shall be direct-mapped: each set contains exactly one way, so no way-select/PLRU logic exists at L1 (see D-003). |
| FR-08 | M | L1 shall be write-through: a write hit shall be forwarded to L2 in the same operation as the local array update, and L1 lines shall never carry a dirty bit. |
| FR-09 | M | On an L1 miss, the replaced line shall simply be overwritten with the incoming fill — no eviction write-back state exists at L1 (direct consequence of FR-08; see D-003). |
| FR-10 | M | The L1-I instance shall not accept write requests (`req_we` tied low at the CPU-side port; any write attempt is a testbench/integration error, not a hardware-handled case). |
| FR-11 | M | L1-I and L1-D shall be structurally identical modules (`rtl/l1/`), differing only in the tie-off of write support and in elaboration-time instance name — not two independently-maintained implementations. |

### 3.3 L2 and L3 (Set-Associative, Write-Back)

| ID | Tier | Requirement |
|---|---|---|
| FR-12 | M | L2 and L3 shall be N-way set-associative (N=4 for L2, N=8 for L3 — see §4) with per-way valid and dirty bits. |
| FR-13 | M | On a miss, if the PLRU-selected victim way's dirty bit is set, its line shall be written back to the next level (or to memory, for L3) before the new line is filled into that way. |
| FR-14 | M | On a miss, if the PLRU-selected victim way's dirty bit is clear, no write-back shall occur; the way is simply overwritten. |
| FR-15 | M | A write hit at L2 or L3 shall set that line's dirty bit and update the array; it shall not propagate to the next level immediately (write-back semantics). |
| FR-16 | M | The PLRU state for a set shall be updated on every access to that set (hit or fill), not only on misses. |
| FR-17 | M | L2 and L3 shall be instantiated from the same parameterized controller module, differing only in elaboration parameters (ways, sets, line size) — not duplicated RTL (see D-002, D-009). |

### 3.4 Inter-Level Line-Size Adaptation (L2 <-> L3)

| ID | Tier | Requirement |
|---|---|---|
| FR-18 | M | L3's line size shall be exactly 2x L2's line size (64B vs 32B — see §4); the ratio shall be a derived parameter, not an independent magic number. |
| FR-19 | M | An L3 line fill from memory shall be split into exactly 2 ordered L2-line-sized beats when forwarded to a requesting L2 miss. |
| FR-20 | M | An L2 write-back to L3 shall be treated as a partial update to the containing L3 line: the L3 line's dirty bit shall be set and only the affected half updated; L3 shall not require both L2-halves to be written back together. |
| FR-21 | M | The adapter (`rtl/adapter/l2_l3_width_adapter.sv`) shall be a standalone module, not logic folded into either the L2 or L3 controller (see D-009). |

### 3.5 Memory-Side Fill/Write-back (L3 <-> AXI4)

| ID | Tier | Requirement |
|---|---|---|
| FR-22 | M | Every L3 miss shall generate exactly one AXI4 `AR` burst of length `L3_LINE_BYTES / AXI_DATA_BYTES` beats to fetch the missing line. |
| FR-23 | M | Every L3 dirty-victim eviction shall generate exactly one AXI4 `AW`+`W` burst of the same length to write the line back. |
| FR-24 | M | No AXI4 transfer shall be narrower than, wider than, or misaligned to a full cache line (see D-012). |

### 3.6 Error Handling

| ID | Tier | Requirement |
|---|---|---|
| FR-25 | M | A CPU-side request asserted while the addressed level's ready signal is low shall be ignored by the level (standard valid/ready backpressure — not an error condition). |
| FR-26 | S | An AXI4 error response (`SLVERR`/`DECERR`) on a fill or write-back shall be latched into a sticky `mem_err` status output at the top level; the controller is not required to retry or recover the transaction (out of v1 scope — recovery policy is an integration-level decision). |

---

## 4. Address and Sizing Requirements

Full derivation and the address-field diagrams are in `02_architecture.md` §2. Binding contract:

| ID | Tier | Requirement |
|---|---|---|
| NR-01 | M | The CPU-side physical address shall be 32 bits, with no virtual-to-physical translation performed anywhere in this IP (see D-011). |
| NR-02 | M | L1 (each of I$/D$): capacity 4 KiB, line 32 B, direct-mapped (1-way) -> 128 sets, offset 5 bits, index 7 bits, tag 20 bits. |
| NR-03 | M | L2: capacity 32 KiB, line 32 B, 4-way -> 256 sets, offset 5 bits, index 8 bits, tag 19 bits. |
| NR-04 | M | L3: capacity 256 KiB, line 64 B, 8-way -> 512 sets, offset 6 bits, index 9 bits, tag 17 bits. |
| NR-05 | M | Every field width in NR-02..NR-04 shall be `$clog2`-derived from the capacity/line/ways parameters at elaboration, never hardcoded, so that re-parameterizing a level cannot silently desynchronize its tag/index/offset split. |
| NR-06 | M | `L3_LINE_BYTES = 2 * L2_LINE_BYTES` shall be enforced at elaboration (`$fatal` in a generate block on mismatch), since the adapter (FR-18..FR-21) assumes exactly a 2:1 ratio and is not written to handle an arbitrary ratio. |

---

## 5. Performance Requirements

### 5.1 Latency

| ID | Tier | Requirement |
|---|---|---|
| PF-01 | M | A hit at any level shall complete in the same cycle the request is accepted (combinational tag-compare, registered data mux) — no bubble on the common case, at any level, independent of associativity. |
| PF-02 | M | Miss penalty at a level shall be deterministic given which further levels also miss, and shall be documented exactly (in cycles, as a function of parameters) in `03_microarchitecture.md`. |
| PF-03 | S | Miss penalty shall be verified by simulation, not only predicted. **Actual measured miss-penalty cycle counts: NOT YET MEASURED** — to be filled from simulation in Phase 4. |

### 5.2 Throughput

| ID | Tier | Requirement |
|---|---|---|
| PF-04 | M | Under an all-hit access pattern, the IP shall sustain one CPU-side request accepted per cycle at L1 (`req_ready` held high), independent of data values. |
| PF-05 | S | Effective hit rate under a representative randomized-with-locality access pattern shall be measured and reported per level. **NOT YET MEASURED** — this is a functional-correctness project, not a hit-rate-optimization project; the figure is reported for interest, not held to a target. |

### 5.3 Observability

| ID | Tier | Requirement |
|---|---|---|
| PF-06 | N | Per-level hit/miss counters, readable through a debug port, to support the PPA/behavior discussion in the README without requiring a waveform capture. |

---

## 6. Clock and Reset Requirements

| ID | Tier | Requirement |
|---|---|---|
| CR-01 | M | The design shall be single-clock, driven by `clk`, positive-edge triggered, across CPU-side, inter-level, and AXI4 memory-side interfaces (no CDC in v1 scope). |
| CR-02 | M | Reset `rst_n` shall be active-low, asynchronously asserted, synchronously de-asserted, per the reset synchronizer in `rtl/common/`. |
| CR-03 | M | All architectural state (tag/valid/dirty arrays, PLRU state, FSMs) shall be reset to a defined value. No state shall rely on power-up randomness. |
| CR-04 | M | Reset assertion mid-transaction (mid-fill or mid-write-back) is architecturally legal and shall leave every level in a clean idle state; in-flight AXI4 transactions are not required to be gracefully drained — this is documented behavior, not a violation, since reset is defined as a full-system event in this IP's scope. |

---

## 7. Parameterization Requirements

| ID | Tier | Parameter | Default | Legal range | Requirement |
|---|---|---|---|---|---|
| PM-01 | M | `L1_CAPACITY_B` | 4096 | power of 2 | L1 capacity in bytes (applies to both I$ and D$ instances). |
| PM-02 | M | `L1_LINE_B` | 32 | power of 2 | L1 line size in bytes. |
| PM-03 | M | `L2_CAPACITY_B` | 32768 | power of 2 | L2 capacity in bytes. |
| PM-04 | M | `L2_LINE_B` | 32 | power of 2 | L2 line size in bytes. |
| PM-05 | M | `L2_WAYS` | 4 | power of 2, >= 2 | L2 associativity. |
| PM-06 | M | `L3_CAPACITY_B` | 262144 | power of 2 | L3 capacity in bytes. |
| PM-07 | M | `L3_LINE_B` | 64 | `2 * L2_LINE_B` (enforced, NR-06) | L3 line size in bytes. |
| PM-08 | M | `L3_WAYS` | 8 | power of 2, >= 2 | L3 associativity. |
| PM-09 | M | `ADDR_W` | 32 | 32 | Physical address width. |
| PM-10 | M | `DATA_W` | 32 | 32, 64 | CPU-side word width. |
| PM-11 | M | `AXI_DATA_W` | 32 | 32, 64, 128 | AXI4 data bus width; must evenly divide `L3_LINE_B` (this is what fixes `ARLEN`/`AWLEN` per FR-22/FR-23). |
| PM-12 | M | — | — | — | Illegal parameter combinations (e.g. `L3_LINE_B != 2*L2_LINE_B`, `AXI_DATA_W` not dividing `L3_LINE_B`) shall be caught at elaboration with `$fatal` in a generate block, not silently mis-synthesized. |
| PM-13 | M | — | — | — | Changing any parameter shall require no source edit; every tag/index/offset width and every PLRU tree size shall be derived, never hardcoded. |

---

## 8. Verification Requirements

Full plan to be detailed in a future `05_verification_plan.md` when Phase 5 opens; binding
requirements fixed now because they constrain how RTL is written from Phase 1 onward:

| ID | Tier | Requirement |
|---|---|---|
| VR-01 | M | Verification shall be **cocotb-based**, not UVM/class-based SystemVerilog, because Icarus Verilog 12 (the only simulator installed) supports no classes, `randomize()`, covergroups, or concurrent SVA (`vlsi-toolchain-reality`). |
| VR-02 | M | A Python functional golden model (cache-state model: which lines are present, dirty, and which way PLRU would select — not a timing model) shall be the reference for every level. |
| VR-03 | M | All RTL output shall be automatically checked against the reference model by a scoreboard. No test shall pass on visual waveform inspection. |
| VR-04 | M | The testbench shall be able to independently stall the CPU-side response path and the AXI4 response path, including indefinite one-sided stalls. |
| VR-05 | M | The following shall each have at least one directed test: reset, cold miss, repeated hit, every byte-enable pattern, conflict-miss thrashing (L1 and per-set at L2/L3), dirty-victim eviction, clean-victim eviction, PLRU exhaustive check up to a bounded sequence length, line-size-adapter split and merge, AXI4 burst length/alignment, reset mid-fill, sustained random mixed I$/D$ traffic. |
| VR-06 | M | Functional coverage shall be defined and collected for: hit/miss per level, eviction dirty vs. clean, PLRU way selected (each way, each set-depth in the tree), CPU-side backpressure patterns, AXI4 backpressure patterns. |
| VR-07 | S | Coverage closure criteria shall be defined before Phase 5 sign-off. Reported coverage shall be measured, never estimated. |
| VR-08 | N | Best-effort formal proofs (PLRU-tree invariant, FSM reachability, AXI4 protocol properties) attempted in Phase 6, contingent on installing Verilator/SymbiYosys, which are not present on this machine today. Any property not attempted or not proved shall be documented as such, never reported as proved. |
| VR-09 | M | The regression shall be runnable via a single `make` target on a clean Linux machine with no proprietary tools. |

---

## 9. Synthesis Requirements

| ID | Tier | Requirement |
|---|---|---|
| SR-01 | M | The RTL shall be synthesizable by Yosys 0.33 with zero errors. |
| SR-02 | M | Synthesis shall produce zero inferred latches and zero inferred tri-states. |
| SR-03 | M | Synthesis shall produce no warnings about width mismatch, incomplete sensitivity, or multiply-driven nets. |
| SR-04 | M | The technology target shall be **Sky130HD** (`sky130hd_tt.lib`, present at `/home/abhi/Documents/VLSI/OpenROAD/test/sky130hd/` on this machine), as explicitly requested for this project. |
| SR-05 | M | No vendor primitives, no `(* ... *)` vendor attributes, no black boxes in the RTL. Technology mapping is the tool's job. |
| SR-06 | M | The design shall contain no clock gating, no latches, and no combinational feedback loops. |
| SR-07 | M | Synthesis shall be reproducible: a single script, checked in, with the library path as the only external dependency. |
| SR-08 | S | Synthesis shall be run at each point of the capacity/associativity sweep defined in `00_project_plan.md` Phase 9, to make the direct-mapped-vs-set-associative and true-LRU-vs-PLRU area tradeoffs measurable rather than asserted. |

---

## 10. Timing Requirements

| ID | Tier | Requirement |
|---|---|---|
| TR-01 | M | STA shall be performed with OpenSTA 2.7.0 against the synthesized netlist and `sky130hd_tt.lib`. |
| TR-02 | S | Maximum achievable frequency shall be determined empirically by constraint sweep, not asserted. |
| TR-03 | M | The critical path shall be identified, reported, and explained (expected to be the L3 tag-compare-and-way-select, being the widest associativity — to be confirmed, not assumed, against measurement). |
| TR-04 | M | All timing numbers in all documents shall be traceable to a checked-in report file. Unmeasured values shall be labelled **NOT YET MEASURED**. |

**Current status of all timing figures: NOT YET MEASURED.** No RTL exists yet (Phase 0).

---

## 11. Area and Power Requirements

| ID | Tier | Requirement |
|---|---|---|
| AR-01 | S | Cell area shall be reported per level and per configuration in the capacity/associativity sweep. |
| AR-02 | S | Tag/valid/dirty array area vs. data array area shall be reported separately, so the "how much does associativity cost" question (direct-mapped L1 vs 4-way L2 vs 8-way L3) is visible as a measured split, not a guess. |
| AR-03 | N | True-LRU vs tree-PLRU replacement-state area shall be compared at a fixed associativity (a small side-experiment reusing the PM-05/PM-08 parameters), since D-007 chose PLRU specifically to bound this cost and the claim should be checkable. |
| PW-01 | N | Power shall be estimated with OpenSTA's `report_power` using switching-activity defaults, explicitly labelled as a static estimate, not a simulation-driven (SAIF/VCD) measurement. |

**All area and power figures: NOT YET MEASURED.**

---

## 12. Documentation and Deliverable Requirements

| ID | Tier | Requirement |
|---|---|---|
| DR-01 | M | Every architectural decision shall be recorded in `docs/engineering_log.md` with options considered, decision, reason, and tradeoff — this is the direct answer to the project's stated requirement that every tradeoff be explained. |
| DR-02 | M | The README shall state exactly how to reproduce every number it reports. |
| DR-03 | M | No number shall appear in any document without either a report-file reference or a **NOT YET MEASURED** label (`no-unverified-numbers` policy). |

---

## 13. Requirement Summary by Tier

| Tier | Count | Blocking for |
|---|---|---|
| MUST | 71 | RTL sign-off |
| SHOULD | 8 | Final release |
| NICE | 4 | Neither |

---

## 14. Open Questions

| # | Question | Owner | Resolve by |
|---|---|---|---|
| OQ-1 | Should the L1<->L2 link reuse the same valid/ready request/response shape as the CPU<->L1 link (uniform interface at every boundary), or should it carry extra fields (e.g. a full-line fill payload) that the CPU-facing port doesn't need? | Design | Phase 1 |
| OQ-2 | Is a single shared victim/write-buffer register enough at L2/L3 (one write-back in flight at a time, consistent with blocking misses), or does the write-back-then-fill sequencing need a dedicated buffer per level? | Design | Phase 2 |
| OQ-3 | Should the AXI4 fill engine support outstanding-transaction pipelining (issuing the next AR before the previous R burst completes), or is one AXI4 transaction at a time sufficient given blocking misses already serialize at L3? | Design | Phase 3 |
| OQ-4 | Will Yosys elaboration/synthesis runtime for the L3 configuration (8-way, 512 sets, widest tag/PLRU array) be tractable on this machine? | Impl | Phase 7 |

---

*Next document: `02_architecture.md`*

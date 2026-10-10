# Engineering Log

Chronological record of design decisions. Every entry records what was considered, what was
chosen, why, and what was given up. Entries are never deleted — if a decision is reversed, a new
entry supersedes it and says so.

Format: **Problem -> Options -> Decision -> Reason -> Tradeoffs -> Result**

---

## D-001 — Coherency scope: single-core vs. multi-core

**2026-09-28 · Phase 0**

**Problem.** "Multi-level cache controller" does not by itself say whether more than one
requester shares the hierarchy, which determines whether a coherency protocol is in scope.

**Options considered.**

1. *Single-core, no coherency protocol.*
2. *Multi-core with a full coherency protocol (MESI or simpler MSI).*

**Decision.** Single-core, no coherency protocol.

**Reason.** This project's toolchain constraint (`vlsi-toolchain-reality`: Icarus Verilog 12
supports no classes, `randomize()`, covergroups, or concurrent SVA) already rules out running a
UVM-based verification environment on this machine directly (see D-013 for how that constraint
was ultimately resolved). A multi-core coherency protocol adds an entire second axis of verification complexity on top of
that constraint — snoop races, invalidation ordering across independent agents, directory or
broadcast-snoop correctness — that is realistically a separate, larger project, not a sub-scope
of a controller project. Choosing single-core keeps the verification effort proportionate to a
single-session portfolio deliverable while still allowing real depth in hit/miss handling,
write-back policy, and replacement.

**Tradeoffs.** Multi-core coherency is a stronger portfolio signal in isolation, but a
half-verified coherency protocol is weaker evidence than a fully-closed single-core hierarchy —
consistent with the general project principle (see prior portfolio IP D-001: "a well-executed
[simple choice] beats a half-finished [complex one] in review").

**Result.** Scope fixed as single-core. Recorded in `01_requirements.md` §1.1 (Non-Objectives)
and `02_architecture.md` §1 (Scope Statement).

---

## D-002 — Number of cache levels

**2026-09-28 · Phase 0**

**Problem.** "Multi-level" is satisfied by as few as two levels; needed to fix whether this is a
2-level (L1+L2) or 3-level (L1+L2+L3) hierarchy.

**Options considered.**

1. *2 levels: L1 + L2.*
2. *3 levels: L1 + L2 + L3.*

**Decision.** 3 levels.

**Reason.** The user's existing project inventory already includes a simpler single-level (2-way)
cache design; a 3-level hierarchy is the choice that meaningfully differentiates this new IP
rather than restating that earlier, simpler piece at larger scale. Three levels also creates
three genuinely distinct organization/policy decision points (D-003, and the L2/L3 tiering
itself) rather than one repeated twice.

**Tradeoffs.** A third level is a third controller class's worth of RTL and verification, and
introduces the L2<->L3 line-size adaptation problem (D-009) that a 2-level design would not have.
Accepted because the adaptation problem is itself a legitimate, demonstrable piece of design
work, not incidental complexity.

**Result.** 3-level hierarchy fixed. `02_architecture.md` §1.

---

## D-003 — L1 organization and write policy

**2026-09-28 · Phase 0**

**Problem.** Needed to fix associativity and write policy per level, not uniformly.

**Options considered.**

1. *Tiered: L1 direct-mapped write-through; L2/L3 set-associative write-back.*
2. *Uniform: all levels set-associative write-back.*
3. *Fully parameterized organization and policy, independently, per level.*

**Decision.** Tiered (Option 1).

**Reason.** Each level then makes a different, individually justifiable tradeoff instead of the
same one three times. Direct-mapped keeps L1's critical hit path to a single tag compare with no
way-select mux, which matters most at the level that must respond in the same cycle at all
(PF-01) and that every access touches. Write-through at that same level avoids dirty-bit/
victim-write-back complexity precisely where latency is most sensitive — the FSM is provably
shorter as a result (4 states vs 5; see `03_microarchitecture.md` §1). Set-associativity at
L2/L3 reduces conflict misses where capacity matters more than raw hit latency, and write-back
there minimizes traffic to the next, slower level.

**Tradeoffs.** Direct-mapped L1 is more susceptible to pathological conflict-miss thrashing than
a set-associative L1 would be — accepted, and specifically exercised as a directed integration
test (`00_project_plan.md` Phase 4 risk R4) rather than hidden. Write-through L1 generates more
L1-to-L2 traffic than write-back would; accepted because L1's traffic volume is exactly what a
fast, simple write-through path is meant to absorb cheaply.

**Result.** Fixed per-level organization/policy table in `02_architecture.md` §5.

---

## D-004 — Miss handling: blocking vs. non-blocking

**2026-09-28 · Phase 0**

**Problem.** Needed to fix whether a miss stalls the pipeline (blocking) or allows continued
hits under an outstanding miss via MSHRs (non-blocking).

**Options considered.**

1. *Blocking misses, one outstanding miss per level.*
2. *Non-blocking misses with MSHR allocation, merging, and hit-under-miss.*

**Decision.** Blocking, for v1 scope.

**Reason.** Non-blocking misses multiply the verification state space substantially: MSHR
allocation and full/merge conditions, replay ordering after a fill completes, and hit-under-miss
races are each a real source of subtle bugs that would need their own directed and
constrained-random coverage. Blocking misses let correctness be reasoned about and verified far
more directly (single active transaction per level, no ordering hazard between an in-flight miss
and a subsequent hit), and is the natural place to close out a first, fully-verified version of
this IP.

**Tradeoffs.** This is a real, acknowledged performance cost, not a hidden one: a blocking L1
miss stalls the entire CPU-side pipeline for the fill duration, which a real high-performance
core would not accept. The external request/response interface contract (§1, `04_interfaces.md`)
was deliberately kept generic enough that non-blocking support could be layered in later as an
explicit, separately-scoped phase without changing that contract — this is stated in
`00_project_plan.md` risk R1 so the limitation is visible in the README, not discovered by a
reviewer reading RTL.

**Result.** FSMs in `03_microarchitecture.md` §1 have no hit-under-miss path. Non-blocking
misses recorded as an explicit Non-Objective in `01_requirements.md` §1.1.

---

## D-005 — L1 split (I$/D$) vs. unified

**2026-09-28 · Phase 0**

**Problem.** Needed to fix whether L1 is one unified cache or split instruction/data caches.

**Options considered.**

1. *Split L1-I / L1-D, unified L2/L3.*
2. *Unified L1 (single I+D).*

**Decision.** Split at L1 only.

**Reason.** Matches real CPU front-ends, where instruction fetch (read-only, sequential-biased)
and data access (read/write, less predictable) have different traffic characteristics worth
demonstrating as two instances of the same controller with different tie-offs (FR-10, FR-11).
Keeping L2/L3 unified avoids duplicating the more complex set-associative write-back controller
for no benefit, matching how virtually every real multi-level hierarchy is actually built
(shared L2/L3, split L1).

**Tradeoffs.** Two L1 instances (I$, D$) means twice the L1 verification surface versus a single
unified L1 — accepted because the two instances are structurally identical modules differing
only in a tie-off (FR-11), not independently-maintained implementations, so the marginal cost is
mostly test-writing, not design.

**Result.** `02_architecture.md` §1 diagram; FR-10/FR-11.

---

## D-006 — Blocking-miss FSM state count

**2026-09-28 · Phase 0**

**Problem.** Direct outcome of D-003 and D-004: needed the concrete state list for each
controller class.

**Decision.** L1: `IDLE -> TAG_CHECK -> ALLOC_FILL -> UPDATE_TAG` (4 states, no eviction state).
L2/L3: `IDLE -> TAG_CHECK -> [EVICT_WRITEBACK] -> ALLOC_FILL -> UPDATE_TAG` (5 states,
`EVICT_WRITEBACK` conditional on the PLRU-selected victim's dirty bit).

**Reason.** Directly derived: write-through lines are never dirty, so there is nothing to write
back at L1; write-back lines may be dirty, so L2/L3 need the conditional eviction state.

**Tradeoffs.** None beyond those already accepted under D-003/D-004 — this entry exists mainly
so the state-count claim in `03_microarchitecture.md` §1 ("provably shorter") has a recorded
derivation rather than being asserted without one.

**Result.** `03_microarchitecture.md` §1.

---

## D-007 — Replacement policy for L2/L3

**2026-09-28 · Phase 0**

**Problem.** Needed to fix the victim-selection policy for the set-associative levels.

**Options considered.**

1. *Tree-based pseudo-LRU (PLRU).*
2. *True LRU (exact recency ordering).*
3. *Random (LFSR-selected victim).*

**Decision.** Tree-PLRU.

**Reason.** PLRU needs only `N-1` state bits per set and O(log N) update/select cost, versus true
LRU's much larger exact-ordering state (`~log2(N!)` bits/set, e.g. ~16 bits/set for 8-way versus
PLRU's 7). It is also what most real set-associative caches above 2-way actually use, making it
the realistic choice, not just the cheap one. Random was rejected as the *primary* policy because
it is materially harder to verify against a deterministic expected-eviction model in a directed
testbench — no fixed "which way gets evicted" expectation exists to check against.

**Tradeoffs.** PLRU is an approximation, not exact LRU, so it can occasionally evict a
more-recently-used way than a true-LRU policy would. Accepted because the area savings are the
entire point of the choice (see AR-03 — a true-LRU-vs-PLRU area comparison is planned as a
measured side-experiment specifically to make this tradeoff checkable, not just asserted).
Random replacement is kept as a secondary, area-comparison-only configuration point (AR-03/PM
infrastructure), not removed from consideration entirely.

**Result.** `03_microarchitecture.md` §2 (algorithm + worked example).

---

## D-008 — Inclusion policy between levels

**2026-09-28 · Phase 0**

**Problem.** Needed to fix whether a smaller/faster level's contents are guaranteed to also be
present in (inclusive), guaranteed absent from (exclusive), or unrelated to (NINE) the next
level's contents.

**Options considered.**

1. *Non-inclusive, non-exclusive (NINE) — no enforced relationship.*
2. *Inclusive (L2 ⊇ L1, L3 ⊇ L2) — requires back-invalidation on eviction.*
3. *Exclusive (disjoint contents) — requires victim-insertion into the next level.*

**Decision.** NINE.

**Reason.** Inclusion's usual motivating benefit is bounding snoop traffic in a multi-core
coherency protocol (by guaranteeing an outer level can answer "is this line cached anywhere
inner" without asking every inner cache directly). D-001 already fixed this design as
single-core with no coherency protocol, so that benefit does not apply here — paying either
inclusive's back-invalidation complexity or exclusive's victim-insertion complexity would add
verification surface (proving a back-invalidate never drops a still-needed line; correctly
routing a victim into the next level instead of dropping it) with no corresponding functional
payoff in this design.

**Tradeoffs.** NINE means effective aggregate capacity across levels can be less than the sum of
per-level capacities in some access patterns (the same line can be redundantly present at
multiple levels, and eviction at one level doesn't inform the others) — accepted as a direct,
named consequence, since the sizing (D-002-adjacent capacity choices in `01_requirements.md` §4)
was not made to depend on inclusion-based capacity guarantees.

**Result.** `01_requirements.md` §1.1 (Non-Objectives — explicitly excludes inclusive/exclusive);
`02_architecture.md` §5.

---

## D-009 — L3 line size and the L2/L3 line-size adapter

**2026-09-28 · Phase 0**

**Problem.** Needed to decide whether every level shares one line size, and if not, how the
boundary between differently-sized lines is handled.

**Options considered.**

1. *Uniform line size (32 B) at every level.*
2. *L3 line size doubled to 64 B, with a dedicated adapter module at the L2/L3 boundary.*

**Decision.** Option 2 — L3 line = 64 B = 2x L2's 32 B, with `l2_l3_width_adapter` as its own
module.

**Reason.** L3 sits closest to DRAM, where AXI4 burst efficiency and DRAM row-activation
overhead matter more than the per-line latency that motivates keeping L1/L2 narrow. A wider L3
line amortizes that fixed per-transaction overhead over more useful bytes — a standard real-world
choice (last-level caches are commonly wider-lined than L1/L2 for exactly this reason).

**Tradeoffs.** This is not free: it requires a real piece of new logic (the adapter) to translate
between the two granularities, including a partial-line write-back path at L3 (only one 32 B
half updated per L2 eviction, FR-20) and a half-select derived from a single address bit
(`03_microarchitecture.md` §3). The alternative (uniform 32 B everywhere) would have avoided this
module entirely. Chosen anyway because the adapter is itself legitimate, demonstrable design
work — not incidental complexity — and because a uniform line size would have quietly ignored a
real tradeoff that a real LLC design has to make.

**Result.** NR-04, NR-06, FR-18..FR-21; `03_microarchitecture.md` §3.

---

## D-010 — Interface choice: CPU-side and memory-side protocols

**2026-09-28 · Phase 0**

**Problem.** Needed to fix what protocol the IP speaks on each external boundary.

**Options considered.**

1. *Custom valid/ready on the CPU side; AXI4 (full) on the memory side.*
2. *AXI4-Lite on both sides.*
3. *Fully custom on both sides.*

**Decision.** Option 1.

**Reason.** A minimal custom handshake on the CPU side keeps the same-cycle hit path (PF-01)
free of any AXI protocol-compliance overhead — the boundary that is touched on literally every
access should not carry cost that only matters at a boundary crossing into another IP block.
AXI4 (full, burst-capable) at the L3-to-memory boundary naturally expresses "fetch/write back one
whole cache line" as a single burst (FR-22/FR-23), and is the one boundary that actually crosses
into another IP block (a memory controller, or another portfolio piece) where a standard
protocol has real integration value. AXI4-Lite was rejected for that boundary specifically
because it has no burst support, which would turn every line transfer into `L3_LINE_B/AXI_DATA_W`
independent single-beat transactions instead of one burst — losing the natural mapping this
design otherwise gets for free.

**Tradeoffs.** The inter-level (L1<->L2, L2<->L3) links use neither protocol — they are internal
to the IP and carry a third, uniform custom shape (`04_interfaces.md` §2). This was a deliberate
choice to avoid paying any standard protocol's handshake latency at a boundary that never leaves
the block and has no external interoperability requirement.

**Result.** `04_interfaces.md` §1 and §3.

---

## D-011 — Address scope: physical only, no virtual memory

**2026-09-28 · Phase 0**

**Problem.** Needed to fix whether address translation (TLB/MMU) is in scope.

**Decision.** Out of scope. The CPU-side interface takes 32-bit physical addresses directly.

**Reason.** This project's stated deliverable is a cache controller, not an MMU. Address
translation is a materially different design problem (page table walks, TLB miss handling, its
own coherency-adjacent invalidation concerns) that would dilute the cache-hierarchy focus rather
than complement it.

**Tradeoffs.** None of substance — a physical-address-only cache controller is a normal, complete
deliverable on its own and is how many real cache-controller IP blocks are actually scoped
(translation typically lives in a separate MMU block upstream).

**Result.** NR-01; `01_requirements.md` §1.1.

---

## D-012 — AXI4 transfer granularity

**2026-09-28 · Phase 0**

**Problem.** Needed to fix whether the AXI4 memory-side interface supports partial/narrow/
unaligned transfers or only whole-line transfers.

**Decision.** Whole cache lines only — every AXI4 transaction the fill engine issues is exactly
one line, line-aligned, full bus width (FR-24).

**Reason.** Every transaction the fill engine ever needs to issue originates from a full-line L3
miss or a full-line dirty-victim eviction (there is no other trigger in this design, by
construction). Restricting to whole-line transfers keeps the AXI4 compliance surface — and the
`axi4_fill_engine` module itself — small: there is no address-alignment or partial-strobe logic
to write, because misalignment and partial transfers cannot occur given how the module is
invoked.

**Tradeoffs.** This would become a real limitation if a future phase added, say, uncached
single-word accesses that bypass the cache hierarchy entirely (not currently a requirement) —
noted here so a future revisit knows this decision was scope-driven, not an oversight.

**Result.** FR-22..FR-24; `03_microarchitecture.md` §4.

---

## D-013 — Verification methodology: classic SystemVerilog UVM, split by test level

**2026-09-28 -> 2026-09-29 · Phase 0 (spec revision, two passes during review)**

**Problem.** The initial spec (VR-01) fixed a Python-driven co-simulation approach as the
verification method throughout, specifically because Icarus Verilog 12 — the only simulator
installed on this machine — supports no SystemVerilog classes, `randomize()`, covergroups, or
concurrent SVA. During spec review, the request changed to classic UVM, "the same as" the
portfolio's existing `APB_Design_and_Verification` project. That project was checked directly
rather than assumed to work: its testbench is genuine class-based UVM (`class ... extends
uvm_*` in `agent.sv`, `driver.sv`, `env.sv`, `monitor.sv`, `scoreboard.sv`, `sequence.sv`,
`test.sv`, `transaction.sv`, `config.sv`), and attempting to compile it here fails immediately —
`testbench.sv:4: Include file uvm_macros.svh not found` — because no UVM library is installed
and no class-capable simulator exists on this machine (`which vcs questa xrun irun verilator` all
returned nothing). This is the same "claimed UVM, nothing ever actually ran" failure mode already
on record for `axi_aes_engine` (see `no-unverified-numbers` memory).

**Options considered (pass 1 — UVM at all, given the compile failure).**

1. *A Python re-implementation of the UVM base classes* (agents, drivers, monitors,
   scoreboards, sequences, the factory, phases) running via a Python-driven co-simulation
   framework that actually executes on the installed toolchain, without SystemVerilog classes.
2. *Install Verilator and attempt real SV UVM* — Verilator 5.x has partial, still-experimental
   class support; a real gamble that could reproduce the same "doesn't actually run" outcome
   after real time investment.
3. *Classic SystemVerilog UVM, written properly, targeting an external simulator the user
   supplies outside this machine/session* (matching `APB_Design_and_Verification`'s exact
   structure: transaction/sequence/sequencer/driver/monitor/agent/scoreboard/env/test/config,
   one file per component).
4. *Keep the already-approved Python-co-simulation plan, no UVM structuring.*

Presented to the user as an explicit choice (with the compile-failure evidence above shown
directly), since this is a decision only they could make — proceeding with Option 1 or 4
unilaterally would have quietly overridden an explicit request; proceeding with classic UVM
without surfacing the compile failure would have repeated the exact unverifiable-claim failure
mode this project's `no-unverified-numbers` policy exists to prevent.

**Decision (pass 1).** Option 3 — classic SystemVerilog UVM, written to the same structural
pattern as `APB_Design_and_Verification`, targeting an external simulator the user runs outside
this machine/session.

**Options considered (pass 2 — where the line between the two tiers sits).** The first pass left
a plain-Verilog smoke test *also* covering the full integrated hierarchy (`sim/tb_top.v`), in
addition to the UVM tier, on the reasoning that the repo should never be left with zero
locally-runnable verification. Follow-up feedback fixed the boundary explicitly instead of
leaving it to that reasoning: Icarus-based directed testing is for **standalone, module-level**
verification only (each controller in isolation); the **full hierarchy** is verified by UVM only,
not by a duplicate plain-Verilog top-level testbench.

**Decision (pass 2).** Tier 1 (plain Verilog, Icarus, this repo) is scoped to standalone
module-level testing only — L1-I, L1-D, L2, L3, the adapter, and the PLRU tree, each in
isolation. There is no Tier-1 testbench for the integrated `mlc_cache_top`. Full-hierarchy
verification is the UVM environment's job alone.

**Reason.** Module-level correctness (does this one controller's FSM/array/PLRU behave right in
isolation) is exactly the kind of small-state-space, easily-directed check Icarus can do well and
that this session can actually execute and check in — there is no good reason to defer it to an
external tool. Full-hierarchy behavior (miss propagation across levels, write-back chains,
mixed-traffic interaction) is where the constrained-random, coverage-driven depth the UVM tier
exists for actually matters, and maintaining a second, separate directed top-level testbench in
parallel with the UVM environment would just be duplicated test-writing effort for the same
target with no distinct verification purpose of its own.

**Tradeoffs — the significant one, unchanged from pass 1.** The UVM regression's pass/fail result
**cannot be produced or checked in by this session**, because the tool that would run it is not
here. This is mitigated: (a) the module-level Tier-1 tests give this repo genuine, checked-in,
passing local verification of every individual controller, so the project is never left with zero
executable evidence, even though the *integrated* behavior is untested locally; (b) the exact
reproduction command for the UVM tier is documented so the external run is a copy-paste, not a
guess; (c) per `no-unverified-numbers`, no UVM pass/fail/coverage figure — including for the
integrated hierarchy — will be asserted in any document until the user actually runs it externally
and the log is checked in; until then every such figure is labelled
**NOT YET RUN (external simulator required)**, distinct from **NOT YET MEASURED** (which means
"the tool to produce this hasn't been run yet, but could be, on this machine").

**Result.** `01_requirements.md` §8 rewritten for the two-tier strategy, scoped by test level;
`00_project_plan.md` repository structure and Phase 4/5 updated (Phase 4 is now integration-only,
no functional Tier-1 test of its own; Phase 5's UVM environment is the sole functional
verification of the integrated hierarchy); `README.md` toolchain and verification sections
updated. Every remaining textual reference to the specific Python co-simulation tool name from
the original VR-01 has been removed from the documentation set, per explicit request — the
Tier-1 module-level testbenches are plain Verilog only, with no Python-driven layer in the
current plan.

---

## D-014 — Build flow: Yosys + OpenSTA + OpenROAD place-and-route, Makefile-driven

**2026-09-28 · Phase 0 (spec revision, after initial review)**

**Problem.** The initial spec (`01_requirements.md` §1.1 Non-Objectives) explicitly excluded full
physical place-and-route, scoping the synthesis deliverable to Yosys + OpenSTA only. The request
changed to building the project "like `Full-Adder`," which runs a complete Yosys -> OpenSTA ->
OpenROAD RTL-to-GDS flow against Sky130HD through a single Makefile (`make synth`/`sta`/`pnr`/
`sim`/`all`/`summary`/`view`).

**Options considered.**

1. *Keep synthesis+STA only, as originally scoped.*
2. *Adopt the full `Full-Adder`-style flow: Yosys synthesis -> OpenSTA -> OpenROAD floorplan/
   place/route/extraction, one Makefile, matching directory shape
   (`rtl/`, `scripts/`, `sim/`, `sky130hd/`, `config/`, `build/`, `pnr_results/`).*

**Decision.** Option 2. Verified first, not assumed: `openroad` is installed and runs
(`/usr/local/bin/openroad`, `v2.0-25346-gc62be3f952`), and the Sky130HD LEF files this flow needs
(`sky130hd_std_cell.lef`, `sky130_fd_sc_hd_merged.lef`) are already present alongside the liberty
file already in use for synthesis/STA.

**Reason.** Every tool the extended flow needs is confirmed present and runnable on this machine
— this is not a speculative addition. Matching `Full-Adder`'s Makefile target shape also gives
this project the same reviewer-facing "one command per flow stage" ergonomics already validated
in that project.

**Tradeoffs.** A 3-level cache hierarchy's tag/PLRU/data arrays are far larger than a full
adder's few gates; placement congestion, routing runtime, and DEF/SPEF generation time are
expected to be materially higher and are **not yet known** to close cleanly at the default
sizing (`01_requirements.md` §4). This is tracked as a new risk (`00_project_plan.md` §4) rather
than assumed away — if P&R proves intractable at full size, the fallback (documented when it
becomes relevant, not preemptively) is running the flow on the smallest single controller
instance (L1) first and scaling up, the same staged approach already used for the Yosys-only
synthesis sweep (Phase 9).

**Result.** `00_project_plan.md` repository structure, Phase list, and toolchain table updated;
`01_requirements.md` §1.1 Non-Objectives row for P&R marked superseded.

---

## D-015 — L1 write-through forward: how a same-cycle hit response coexists with a not-yet-ready L2

**2026-09-29 · Phase 1 planning (resolves OQ-1)**

**Problem.** FR-08 requires a write hit at L1 to forward to L2 "in the same operation" as the
local array update, and PF-01 requires L1's response to the CPU to complete in the *same cycle*
the request is accepted, at every level, unconditionally. Neither requirement says what happens
if L2's downstream `req_ready` happens to be low that same cycle (e.g., L2 is mid-fill from an
unrelated miss). Coupling L1's CPU-facing `req_ready` directly to L2's readiness would make every
L1 write (and, if not careful, every access) vulnerable to stalling on L2 state, which is exactly
the coupling D-003 chose write-through specifically to avoid at the fastest level. This was left
open as OQ-1 ("Resolve by: Phase 1").

**Options considered.**

1. *Gate L1's `req_ready` directly on L2's downstream `req_ready` for writes.* Simple, but
   reintroduces the cross-level latency dependency D-003 was chosen to avoid.
2. *A 1-entry write-forward skid register.* On a write hit, update the L1 array and respond to
   the CPU the same cycle regardless of L2's state (PF-01 satisfied unconditionally); latch the
   write into a single pending-forward register and keep presenting it to L2 until L2's
   `req_ready` accepts it. While that register holds an unaccepted forward, L1's CPU-facing
   `req_ready` drops (reusing the same signal FR-05 already drops during a miss-fill) — a second
   write cannot be accepted until the first has actually left for L2.
3. *An N-deep write-forward FIFO (N>1).* Absorbs more back-to-back writes without stalling, at
   the cost of more state and a more complex full/empty/ordering story for a v1 controller.

**Decision.** Option 2 — a 1-entry write-forward skid register.

**Reason.** This keeps the common case (L2 ready) exactly as simple as if the register didn't
exist — the forward leaves the same cycle, the register is never actually occupied for more than
an instant. It only engages on the genuinely rare case (L2 busy with an unrelated fill) and does
so with the smallest possible amount of new state: one address+data+control register and one
valid bit, no FIFO pointer logic. It also reuses an existing signal (`req_ready` dropping) rather
than inventing a second kind of backpressure, so from the CPU's point of view a pending write
forward and an active fill look identical: "L1 is momentarily busy," which is honest — in both
cases L1 genuinely cannot promise a next-cycle response.

**Tradeoffs.** A CPU issuing two writes back-to-back where the first hits and momentarily can't
forward (L2 busy) sees `req_ready` drop for exactly as long as L2 stays busy, even though the
*local* L1 array update for that first write already completed — a write that is fully committed
locally can still block the *next* request. This is a real, bounded latency cost, accepted because
it only ever affects back-to-back writes racing an unrelated L2 fill (not reads, not isolated
writes), and Option 3's FIFO would trade a rare, bounded stall for permanent extra state on every
access. VR-03 already required an "indefinite downstream backpressure" test case; this decision
is exactly what that test now exercises the skid register against.

**Result.** L1 controller design (Task 3/4 of the Phase 1 implementation plan) includes the skid
register as part of `l1_cache_ctrl.sv`, not as a separate module. `01_requirements.md` OQ-1 marked
resolved.

---

## D-016 — Package identifiers: fully-qualified `mlc_pkg::` references, never `import`

**2026-09-29 · Phase 1 (Yosys elaboration check bring-up)**

**Problem.** The Phase 1 RTL and testbenches originally reached the shared parameters (`ADDR_W`,
`DATA_W`, `BYTES_PER_WORD`, the `L1_*` set) through a file-scope `import mlc_pkg::*;`. The first
Yosys 0.33 run of `make lint` failed at the import line of every such file with
`ERROR: syntax error, unexpected TOK_ID`. Phase 7 synthesis uses the same Yosys front end, so this
was not a lint-only problem.

**Options considered.**

1. *Explicit named imports* (`import mlc_pkg::ADDR_W;`) instead of the wildcard.
2. *Fully-qualified references* — no `import` anywhere; every use is written `mlc_pkg::ADDR_W`.
3. *`` `define`` macros in an `` `include``d header* in place of the package.

**Decision.** Option 2.

**Reason.** Option 1 was tested directly and fails identically: Yosys 0.33's SystemVerilog front
end rejects the `import` keyword at file scope in any form, wildcard or named. Option 2 was
confirmed by the same kind of direct reproduction — a module using `mlc_pkg::ADDR_W` in its port
widths elaborates cleanly, with the width resolved from the package — and it keeps the package as
the single source of every parameter (PM-13) in standard SV that Icarus 12 also accepts. Option 3
would work in both tools, but trades a typed, scoped package for global text-substitution macros
with `` `include``-order and redefinition hazards of their own.

**Tradeoffs.** Every use site is more verbose (`mlc_pkg::L1_WORD_SEL_W`, not `L1_WORD_SEL_W`).
The file-order dependency also remains: both Icarus 12 and Yosys 0.33 resolve a qualified
`mlc_pkg::` reference only if `mlc_pkg.sv` has already been read. With the package listed last,
Icarus reports syntax errors at the first qualified reference and Yosys fails with
`Failed to detect width of signal access`. So `rtl/common/mlc_pkg.sv` must be the first file in
every `iverilog` command and every `read_verilog` sequence. A wrong order fails loudly at compile
time, never silently.

**Result.** No file in the repository uses `import`. All six files that did
(`rtl/l1/l1_cache_ctrl.sv`, `rtl/l1/l1_icache_ctrl.sv`, `rtl/l1/l1_dcache_ctrl.sv`,
`sim/l1_downstream_stub.sv`, `sim/tb_l1_dcache.sv`, `sim/tb_l1_icache.sv`) use qualified
references, and the `Makefile` and `scripts/lint.ys` list `mlc_pkg.sv` first. Every behavior above
(both `import` forms rejected; qualified references accepted; package-last fails in both tools) was
re-reproduced with minimal standalone modules on Yosys 0.33 and Icarus 12.0 while writing this entry.

---

## D-017 — Arrays are only ever single-indexed: word merges happen on a temporary, never on `array[i][j +: w]`

**2026-09-29 · Phase 1 (Yosys elaboration check bring-up)**

**Problem.** Once D-016 let Yosys parse the L1 RTL, `make lint` still did not finish: against the
real design it ran for more than 5 minutes without completing. The original `l1_cache_ctrl.sv`
updated one word of a line in place with a doubly-variable-indexed write —
`data_array[req_index][req_word_sel*DATA_W +: DATA_W] <= merge_wstrb(...)`, a variable array index
combined with a variable-offset part-select in the same statement — and read `resp_rdata` with the
same doubly-indexed form.

**Options considered.**

1. *Keep the RTL and work around the runtime* (e.g. drop `proc` from the lint script).
2. *Single-index the array*: read the whole line with one variable index into an ordinary signal,
   merge the addressed word into that signal combinationally, and write the whole line back with
   one variable index (`data_array[req_index] <= hit_write_line_merged;`).

**Decision.** Option 2, as a standing RTL rule for every level.

**Reason.** Isolated by direct before/after reproduction during Phase 1: a minimal module with the
same array shape (128 x 256 bit) and one doubly-variable-indexed write did not finish Yosys's
`proc` pass within 60 s, while the same module restructured to Option 2 completed the full
`proc` / `opt_clean` / `check -assert` / `stat` pipeline in about 10 s. Re-reproduced
independently while writing this entry, with both variants written inside an async-reset
`always_ff` as in `l1_cache_ctrl.sv`: the doubly-indexed version had not completed the
`proc` / `opt_clean` / `check -assert` pipeline when killed at 120 s; the single-indexed version
completed the same pipeline in 10.9 s. (Control: written in a plain clocked block with no async reset, Yosys
keeps the array as a memory and both variants finish in under 1 s. The slow case appears once
Yosys converts the array into individual registers — as it did for the async-reset variants, and
as it does for `tag_array`/`data_array`/`valid_array` in `l1_cache_ctrl.sv`: the "Replacing memory
... with list of registers" warnings `make lint` prints.) Option 2 is behavior-identical:
the line's other words are written back with their own current values. The fill path
(`fill_line_merged`) already used this pattern. Option 1 would only have moved the same construct
to Phase 7 synthesis, and dropping `proc` would make the zero-latch check meaningless.

**Tradeoffs.** A write hit now describes a full-line write rather than a one-word write, and the
RTL carries line-wide temporaries (`req_line_rd`, `miss_line_rd`, `hit_write_line_merged`).
Whether synthesis maps this to more hardware than the doubly-indexed form would have is
**NOT YET MEASURED** (Phase 7).

**Forward requirement for L2/L3 (Phase 2+, not yet planned).** L2/L3 arrays are larger and will
combine way-select with word-select — the same or a worse form of this pattern. Their RTL must
apply the single-index, merge-on-a-temporary pattern from the start rather than rediscover this.

**Result.** `rtl/l1/l1_cache_ctrl.sv` reads `data_array` only through `req_line_rd`/`miss_line_rd`
and writes it only with a single index (`hit_write_line_merged`, `fill_line_merged`). `make lint`
(both L1 tops) completes with exit 0 in about 32 s on this machine (measured 2026-09-29). The
word-offset regression in `sim/tb_l1_dcache.sv` checks that the restructured merge behaves
correctly at a non-zero word offset.

---

## D-018 — L2/L3 victim handling: single shared victim register (resolves OQ-2)

**2026-09-30 · Phase 2 planning**

**Problem.** OQ-1's counterpart for L2/L3: on a dirty-victim eviction, is a single shared
victim/write-back register enough, or does the write-back-then-fill sequencing need a dedicated
buffer per level?

**Options considered.**

1. *Single shared victim register*: one address+line+way register, live only from the moment
   `TAG_CHECK` selects a dirty victim until `EVICT_WRITEBACK` completes.
2. *A dedicated per-level write-back buffer*, decoupled from the fill that triggered it (e.g. a
   small FIFO), allowing eviction and fill to be pipelined or reordered.

**Decision.** Option 1.

**Reason.** Misses are blocking (D-004): each level services exactly one miss at a time, and the
level 2/3 FSM already sequences `EVICT_WRITEBACK` to completion *before* `ALLOC_FILL` begins
(`03_microarchitecture.md` §1.2) — eviction and fill are never concurrent for the same level, by
construction. This is a direct structural consequence of D-004, not a new constraint: L2/L3 have
no same-cycle response obligation analogous to L1's PF-01 (a write *hit* at L2/L3 never forwards
downstream at all — FR-15 — so there is no L1-D-015-style skid register problem here either).
A single register holding the selected victim's way, tag/address, and full line is therefore
sufficient: it is written once when `TAG_CHECK` selects a dirty victim, read once by
`EVICT_WRITEBACK`, and never needs to hold more than one entry.

**Tradeoffs.** This means eviction write-back and the subsequent fill are strictly serial — the
full miss penalty is write-back latency *plus* fill latency, not overlapped. Accepted: overlapping
them would require the downstream link to accept a write and a read concurrently (two outstanding
transactions), which conflicts with the single-outstanding-transaction downstream contract already
established for L1<->L2 (`04_interfaces.md` §2) and would reopen exactly the kind of complexity
D-004 deferred. A future non-blocking phase (already out of v1 scope per D-004) would revisit this
together with MSHRs, not in isolation.

**Result.** `l2_cache_ctrl.sv`'s `TAG_CHECK`->`EVICT_WRITEBACK`->`ALLOC_FILL`->`UPDATE_TAG`
sequence uses one `victim_*` register set, mirroring the `miss_*` latch group already used for
the fill address/data in `l1_cache_ctrl.sv`. `01_requirements.md` OQ-2 marked resolved.

---

## D-019 — L2/L3 array elaboration: separate the reset-free arrays into their own always_ff

**2026-09-30 · Phase 2 planning**

**Problem.** D-017 fixed L1's Yosys elaboration slowness by single-indexing `data_array`'s
accesses (128 entries x 256 bits). L2's arrays are 4x larger by entry count (256 sets x 4 ways =
1024 entries) before even counting `tag_array`/`dirty_array` alongside `data_array`. Checked
directly before writing any L2 RTL, not assumed safe by extrapolation: a single-indexed,
D-017-style write at 1024 entries x 256 bits did not finish `proc` alone within 90 seconds —
D-017's fix was necessary but not sufficient at this scale, so an isolated reproduction was built
to find the actual bottleneck before committing to a design.

**Investigation.** Both `data_array` (single-indexed write, no reset) and `valid_array`
(reset-cleared via a for-loop) print Yosys's "Replacing memory X with list of registers" warning
when declared and written from within the same clocked process as a reset-cleared signal — even
though `data_array` itself carries no reset logic. `proc` alone, not `opt_clean` or `check`, is
where the time is spent once an array is flattened this way; the flattening itself, not any
downstream pass, is what scales badly with entry count.

**Options considered.**

1. *Accept the slow elaboration time* (tens of minutes) as a one-time Phase-2 cost.
2. *Separate the reset-free arrays into their own `always_ff @(posedge clk)` block* (no
   `or negedge rst_n)`, no reset branch at all), so nothing in that process's syntax disqualifies
   Yosys's automatic memory-inference pattern-match, keeping `data_array`/`tag_array`/
   `dirty_array` as compact `$mem` cells instead of N-way flattened registers. `valid_array` (the
   only array FR-06 actually requires to reach a defined value on reset) stays in its own
   `always_ff @(posedge clk or negedge rst_n)` block, small enough (1 bit x SETS x WAYS) that
   flattening it to registers is cheap regardless.

**Decision.** Option 2. Verified directly: the same 1024-entry x 256-bit array, moved to its own
reset-free `always_ff`, completes the full `proc`/`opt_clean`/`check -assert`/`stat` pipeline in
~0.5 seconds — no "Replacing memory" warning for that array at all, confirming it stayed a real
`$mem` cell. `valid_array`, kept in the separate reset-bearing block, still gets flattened (as
expected — 1024 x 1 bit is cheap to flatten) but no longer drags every other array's writes into
the same expensive path.

**Reason.** FR-06 already establishes that tag, data, and dirty-bit contents are don't-care until
a line is validated by a fill — nothing in the spec requires these arrays to reach any defined
value on reset, only that they never be trusted before their line's valid bit says so. Giving them
their own reset-free process is therefore not a compromise of anything FR-06 promises; it is
simply not paying for a guarantee (a defined reset value) the design never needed, in the one
place where paying for it was also expensive to elaborate.

**Tradeoffs.** Multiple `always_ff` blocks writing conceptually-related per-line state (tag, dirty,
data, valid, all committed together on a fill) is a slightly less consolidated read of the code
than one block doing everything — mitigated by keeping all of a single commit's writes on the
same clock edge (still synchronous and coherent) and naming the blocks clearly by what they own.
Whether this materially changes synthesized area or timing versus one combined process is
**NOT YET MEASURED** (Phase 7) — the fix here is scoped to elaboration/lint tractability, not a
synthesis optimization claim.

**Result.** `l2_cache_ctrl.sv` (and `l3_cache_ctrl.sv` when Phase 3 reuses it) splits `tag_array`/
`dirty_array`/`data_array` writes into one reset-free `always_ff @(posedge clk)`, and `valid_array`,
the FSM `state`, and the `miss_*` latches into a separate `always_ff @(posedge clk or negedge rst_n)`.
The victim register (`victim_way_latched`/`victim_tag_latched`/`victim_line_latched`, D-018) also
lives in the reset-free block. This is harmless: like the arrays, it is don't-care until written,
and `S_TAG_CHECK` always writes it before `S_EVICT_WRITEBACK` or a fill reads it.
This supersedes D-017's guidance for any array whose entry count materially exceeds L1's — D-017's
single-indexing fix still applies within each array access, but is no longer sufficient on its
own at L2/L3 scale without this separation too.

The memory-inference property is now a permanent, explicit check on the real module, not only
Task 3's informal inspection of Yosys's "Replacing memory" warning text. `scripts/lint.ys`'s
`l2_cache_ctrl` block asserts `select -assert-count 3 l2_cache_ctrl/m:*` (exactly `tag_array`,
`dirty_array` and `data_array` remain real `$mem` cells; `valid_array` is expected to flatten) and
`select -assert-count 1 l2_cache_ctrl/m:data_array`. `make lint` passes with both assertions (exit 0,
about 37 s on this machine, 2026-10-01). A deliberately wrong count (4) was confirmed to fail,
listing exactly those three memories.

---

## D-020 — Testbench forward-log monitors: no queue of a struct type on Icarus 12; use parallel queues

**2026-09-30 · Phase 2 (`tb_l2.sv` bring-up)**

**Problem.** `sim/tb_l2.sv`'s forward-log monitor (the mutation-testing-motivated pattern that
records every downstream write handshake so an eviction write-back is checked at the receiving
end, not by re-reading `l2_cache_ctrl.sv`'s own array) was first written the natural way: a
`fwd_entry_t` packed struct (`{addr, line}`) held in a queue, pushed with an assignment-pattern
literal (`fwd_log.push_back('{addr: dn_req_addr, line: dn_req_line})`). Compiling it hit three
distinct failures in sequence, not one: (1) the assignment-pattern literal as a direct task-call
argument — `Syntax error in task arguments`; (2) after moving the literal into a temporary of the
packed-struct type, `Sorry: Queue of type ... is not yet supported`; (3) switching the struct from
`packed` to plain (unpacked) to work around (2) instead hit `Sorry: Unpacked structs not
supported`. So the actual blocker is (2)/(3) — Icarus 12 supports a queue of a struct type in
neither form — and (1) was a symptom of trying to work around it in place rather than the root
cause.

**Options considered.**

1. *Keep the struct-queue design and find some third struct spelling that elaborates.* Ruled out
   directly: both spellings SystemVerilog allows for a struct type (`packed`, unpacked) were tried
   and both are explicitly unsupported by Icarus 12's queue elaboration, per the tool's own
   messages — there is no third form to try.
2. *Two parallel queues of plain packed vectors* (`fwd_addr_log[$]` of `[ADDR_W-1:0]`,
   `fwd_line_log[$]` of `[LINE_W-1:0]`), pushed and popped together by index/order rather than as
   one aggregate.

**Decision.** Option 2.

**Reason.** Confirmed directly with a minimal reproduction outside the testbench: a queue of a
plain packed vector (`logic [255:0] q[$]`) pushes, sizes, and pops correctly on Icarus 12, with no
warning of any kind — the limitation is specific to queues of an aggregate (struct) element type,
not to queues in general. Two parallel queues preserve the forward-log monitor's actual verification
property unchanged (one entry per accepted downstream write handshake, poppable in issue order,
checked at the receiving end) since both queues are only ever pushed together (one `always @(posedge
clk)` block, one `if`) and popped together (`check_fwd_one` pops both before comparing), so they
cannot desync into different lengths.

**Tradeoffs.** Two related queues instead of one is a smaller abstraction than the natural
`{addr, line}` pairing suggests the data has — a reader must know they are kept in lockstep by
convention, not by the type system. Mitigated by keeping every push and every pop of the two
queues textually adjacent (never one without the other) and commented as to why the split exists.

**Result.** `sim/tb_l2.sv`'s forward-log monitor uses `fwd_addr_log[$]`/`fwd_line_log[$]` in place
of a `fwd_entry_t` struct queue; `check_fwd_one`/`check_fwd_empty` read both. This is a testbench-
only finding (no RTL is affected) but is forward-relevant: Phase 3's `tb_l3.sv` is expected to
reuse the same forward-log-monitor pattern for its own eviction write-back checks (per the
mutation-testing discipline this project follows) and should use the two-parallel-queues form from
the start rather than rediscover this.

---

## D-021 — L2/L3 upstream writes are posted: accepted on `req_ready` alone, never answered with `resp_valid`

**2026-10-01 · Phase 2 (final whole-branch review fix wave)**

**Problem.** `l2_cache_ctrl.sv` as first built gated upstream write completion on
`resp_ready`/`resp_valid` exactly as it gated reads: a write hit was accepted only while
`resp_ready` was high (`req_ready`'s hit term), both a write hit and a write-allocate miss
completion raised `resp_valid`, and `S_UPDATE_TAG` waited for `resp_ready` before returning to
`S_IDLE`. The already-merged L1 (`rtl/l1/l1_cache_ctrl.sv`, D-015) forwards every write-through
write as a *posted* request: it presents the forward (directly, or from its 1-entry skid register),
treats it as done as soon as `dn_req_ready` is high, and never waits for or consumes a response to
it — its `dn_resp_ready` is asserted only while L1 itself is in `S_ALLOC_FILL`, which has nothing to
do with write forwarding. Against that neighbor the two failure modes are:

1. *A forwarded write that hits in L2 deadlocks.* L2 holds `req_ready` low waiting for a
   `resp_ready` that L1 never raises, so L1's skid register never drains and L1's own CPU-facing
   `req_ready` stays low for good. The Phase 2 final whole-branch review found this and confirmed it
   by simulating L1 -> L2 -> `l3_stub` with one forwarded write; the root cause was confirmed
   independently by reading the three expressions above, none of which distinguishes a read from a
   write.
2. *A forwarded write that misses in L2 silently corrupts a later, unrelated L1 fill.* The write is
   accepted (a miss never needed `resp_ready`), but its completion then parks in `S_UPDATE_TAG`
   presenting `resp_valid` with the merged line. The next time L1 misses on any address, it enters
   `S_ALLOC_FILL`, raises `dn_resp_ready`, and takes that stale write-miss "response" as its own
   fill data. Found while preparing this fix and reproduced in a scratch simulation (not checked in:
   L1 -> L2 -> `l3_stub`, with L2's copy of an L1-resident line invalidated to force an L2 write
   miss): an unrelated L1 read of `0x2224` returned `0xABCD1234`, the forwarded write's data,
   instead of `0x00002221`.

**Options considered.**

1. *Posted upstream writes at L2.* A write, hit or write-allocate miss, is accepted on `req_ready`
   alone and never produces `resp_valid`. Only a read hit still needs `resp_ready` to be accepted,
   because only a read hit hands back data in the same cycle it is accepted.
2. *Make L1 wait for a write response.* Change L1's skid register to hold until L2 returns a write
   acknowledgment, and assert `dn_resp_ready` for it. This reopens an already-merged, reviewed
   module and its D-015 contract. It also adds a round trip to every write-through forward, which is
   the coupling D-003 and D-015 exist to keep off L1's write path.
3. *A separate write-acknowledgment channel* (an AXI `B`-channel-style `wack_valid`/`wack_ready`
   pair). More signals at every level boundary, and no level has any use for the acknowledgment.

**Decision.** Option 1. It is exactly three expressions in `l2_cache_ctrl.sv`:
`req_ready`'s hit term becomes `(!req_valid || !is_hit || req_we || resp_ready)`, `resp_valid`
becomes `(state == S_UPDATE_TAG && !miss_is_write) || (<hit accepted> && !req_we)`, and
`S_UPDATE_TAG` exits on `miss_is_write || resp_ready`. Nothing else in the RTL changes:
`commit_write_hit` was already computed independently of `resp_ready`, so a write hit still commits
on its acceptance edge; the phantom-response guard (`resp_valid`'s hit term includes `req_ready`) is
unchanged and still protects reads; and the downstream write-back path (`dn_*`) is untouched, so
FR-15 (write hits never propagate downstream) still holds.

**Reason.** Posted writes are what the interface already describes. `04_interfaces.md` §2 defines
`resp_valid`/`resp_ready` on the inter-level links as the *fill-response* handshake, and no write on
those links ever had a response: L1's write-through forwards are posted (D-015), and L2's own
eviction write-backs to `l3_stub` are posted too — the stub absorbs a write-back with no response.
Before this fix, L2 was the one place that expected a response to a write. Option 1 brings L2's
upstream side in line with its own downstream side and with its real upstream neighbor, and it does
so without touching L1. Write ordering is still safe without an acknowledgment, because L2 is
blocking (D-004): after it accepts a write-allocate miss, `req_ready` stays low until the merged
line is committed, so no later request can overtake the write.

**Tradeoffs.** The upstream level never learns when a posted write-allocate miss has actually landed
in L2's array. No level needs to know this in v1 (blocking misses make ordering implicit, see above),
but a future non-blocking design would have to revisit it together with D-004. A read hit still
needs `resp_ready` in its acceptance cycle, so the "drive `resp_ready` independently of
`resp_valid`" rule of `04_interfaces.md` §1 still applies to reads at L2.

*Separate item, NOT YET ADDRESSED (Phase 3 planning).* The upstream port still has no full-line
write input (`req_line`), so this module cannot yet be reused completely unmodified as L3 to receive
L2's own write-back traffic. L1 -> L2 writes are word-granularity write-through (`req_wdata` +
`req_wstrb`), while L2 -> L3 writes are line-granularity write-backs (`dn_req_line`, see
`04_interfaces.md` §2's `req_line` row). FR-17 requires L2 and L3 to be one module, so Phase 3 has to
add a line-write path to the upstream port. That is out of Phase 2's scope (Phase 2's Definition of
Done explicitly excludes L3), so it is deliberately deferred here and not fixed.

**Result.** `rtl/l2/l2_cache_ctrl.sv` carries the three-expression change above. `sim/tb_l2.sv` now
treats every write as posted. `cpu_write_hit` drives `resp_ready` low (as L1 does), completes on
`req_ready` alone, and checks at the acceptance edge that the write was both accepted and a genuine
hit. The new `cpu_write_alloc` holds `resp_ready` low and waits for the miss to start
(`S_TAG_CHECK`) and fully finish (`S_IDLE`). A directed D-021 regression checks, with `resp_ready`
low throughout, that a write hit is accepted without `resp_valid`, that a write-allocate miss leaves
`S_UPDATE_TAG` after one cycle without `resp_valid`, and that both writes land in the array. A
whole-run monitor checks that no write, hit or miss, raises `resp_valid` anywhere in the test.
`make sim` passes (`sim/logs/tb_l2.log`). The same updated `tb_l2.sv` run against the pre-fix RTL
fails (the write-hit acceptance check and read-back fail, then the watchdog fires when the posted
write-allocate never leaves `S_UPDATE_TAG`), so the regression really detects the bug. Both failure
modes in **Problem** were reproduced on the pre-fix RTL and pass on the fixed RTL in scratch
L1 -> L2 -> `l3_stub` simulations. Those simulations are not checked in: L1/L2 integration testing
belongs to a later phase, and the checked-in evidence for this decision is `tb_l2`. After the rest
of the Phase 2 final-review fix wave, `tb_l2` runs 107 checks, all passing (`sim/logs/tb_l2.log`,
2026-10-01). In a scratch mutation run (also not checked in), reverting any one of the three
expressions was caught by the suite, and so was dropping only the `!req_we` from `resp_valid`'s hit
term.

---

## D-022 — One Makefile is the single test and check entry point: a registry, quiet verdicts, `check`

**2026-10-10 · Phase 3**

**Problem.** The Makefile built and ran every Tier-1 testbench, but: it printed every line of every
test, so a failure was easy to scroll past; there was no way to run one test; there was no single
"is everything fine" command; a testbench that printed nothing would have passed; and each new test
needed its own build rule plus an edit to two lists. Phase 3 adds eight more testbenches and several
parameter guards, and the project owner asked for a Makefile to test and check all of it.

**Options considered.**

1. *Keep one explicit build rule per test* (what Phases 1 and 2 did). Simple to read, but every new
   test is a rule, a list entry and an edit to the run loop.
2. *A registry*: one `$(call register,<name>,<sources>)` line per test, with one generic build rule
   and one generic run rule.
3. *Discover `sim/tb_*.sv` automatically.* No registration at all, but source lists differ per test
   and the package must come first, so the discovery would need a second source of truth anyway, and a
   deleted or renamed testbench would vanish from the run silently.

**Decision.** Option 2. Targets: `make check` (parameter guards, then every test, then lint, non-zero
if any fails), `make sim`, `make test-<name>` (one test; `V=1` shows its full output), `make list`,
`make elab`, `make lint`, `make clean`. A test passes only if `vvp` exits 0, prints no `FAIL`, and prints
at least one `PASS`. Each run still writes its full output to `sim/logs/<name>.log`, the tracked
evidence. `make clean` removes only the compiled binaries and `sim/elab_*`, never sources or logs.

**Reason.** Adding a test is one line, so the cost of testing a new module is never a reason to skip
it. Explicit registration keeps a missing file an error instead of a silent skip. The at-least-one-PASS
rule means a testbench that stops checking cannot go unnoticed.

**Tradeoffs.** The default output is one line per test, so the individual PASS lines are only in the
logs (or with `V=1`). `make check` takes about two minutes, almost all of it Yosys lint, and has no
shortcut yet; the individual targets are the shortcut. The `$(eval)` macro behind `register` is less
obvious than a plain rule.

**Result.** Verified on the Phase 2 tree before any Phase 3 code: `make sim` runs 5 testbenches and
229 checks, identical to the previous Makefile. Failure paths checked in a throwaway copy: one broken
expected value makes `make sim` print the failing line and exit non-zero; a registered testbench that
prints nothing fails with `0 passed, 0 failed, exit 0`; an unknown `test-<name>` is an error.
`make check` passes from a clean tree and leaves `git status` showing only the intended edits (the
regenerated tracked logs are byte-identical).

---

## D-023 — `plru_tree` builds the victim index in an `int`, so it works at 2 ways; toolchain limits found in Phase 3

**2026-10-10 · Phase 3**

**Problem.** `plru_tree.select_victim` assembled the way index by shifting a `$clog2(WAYS)`-bit vector
left each level, which needs the part-select `way[$clog2(WAYS)-2:0]`. At `WAYS = 2` there is one
level and that range is `[-1:0]`: out of order, a compile error. Both associativity parameters allow
2 ways (`PM-05`, `PM-08`: "power of 2, >= 2"), so the module could not be instantiated across its
own required range. The Phase 2 pull request review found this; `tb_plru` only ever built 4 ways, so
nothing in the repository could see it. The same module is used for L3 at 8 ways, which also had no
test.

**Options considered.**

1. *Special-case 2 ways with a generate block.* A second code path for the one value that breaks.
2. *Accumulate the index in an `int`* (`way = way*2 + bit`) and truncate once at the end. One code path.
3. *Raise the lower bound to 4 ways.* Violates `PM-05`/`PM-08`.

**Decision.** Option 2.

**Reason.** The bug was the shifted part-select, not 2 ways as such, so removing the part-select fixes
every associativity at once and keeps one implementation to verify.

**Tradeoffs.** The arithmetic is 32-bit `int`. The loop bounds are constants, so both tools fold it to
the same few gates; this was confirmed only by `make lint` passing, not by a gate-level comparison.

**Result.** New `sim/tb_plru_ways.sv` checks every single access and every ordered pair of accesses
from reset at 2 ways and at 8 ways (82 checks), against tables generated by
`scripts/gen_plru_tables.py`. The generator models the tree by recursing on way ranges, a different
formulation from the RTL's iterative bit walk, and first asserts results worked out by hand (2-way: way 0
then victim 1; the Phase 0 4-way example; 8-way: touching 0..7 in order leaves way 0, then way 0 again
moves it to way 4). A comparison script confirmed all 78 table entries in the testbench equal the
generator's output. Against the unfixed module the testbench fails to compile (`part select way[-1:0]`);
against a module with the pointing direction not inverted it fails 80 checks, with the walk direction
swapped 55. `tb_plru` (4 ways, 23 checks) and `tb_l2` (107) still pass.

*Toolchain limits found while building Phase 3 (each reproduced directly, none assumed):*

- **Yosys 0.33** cannot parse a size cast `int'(x)` (`syntax error, unexpected TOK_INT`), nor
  `return (a) && (b);` (`unexpected OP_LAND`). Write `name = expr;` and avoid casts.
- **Icarus 12** accepts a `$fatal` inside a generate block and silently does nothing. The same `$fatal`
  inside an `initial` block stops the run at time 0 with exit code 1. **Yosys 0.33** stops elaboration on
  an `initial`-block `$fatal` whose condition is true (`Can't resolve task name '$fatal'`), so parameter
  checks are written as `initial` blocks, which work in both tools (D-026).
- **Icarus 12** prints `sorry: constant selects in always_* processes are not currently supported` for a
  constant part-select of a loop variable inside `always_comb`. A function avoids it (Task 3).
- **Icarus 12** warns on a variable declaration with an initializer inside a block unless it has an
  explicit lifetime; declare, then assign.

---

## D-024 — The shared controller takes a write width, so L3 receives an L2 write-back as one posted half-line write

**2026-10-10 · Phase 3**

**Problem.** D-021 deferred this: the controller's upstream write port was word-sized
(`req_wdata[31:0]`, `req_wstrb[3:0]`), but L3 must receive L2's evicted 32 B line, and `FR-17` forbids a
second copy of the controller for L3. `04_interfaces.md` §2 listed a `req_line` signal for it, a port
the module never had. `FR-20` asks that an L2 write-back update only the addressed half of the L3 line
and set its dirty bit.

**Options considered.**

1. *Add a `req_line` port plus a mode select.* New ports on a module whose L2 instance would tie them
   off, and a second write path to verify.
2. *Have the adapter split the write-back into eight word writes.* No change to the controller, but one
   write-back becomes eight L3 transactions; if the line is absent the first allocates and the other
   seven hit.
3. *Parameterise the write width*: `WR_BYTES`, the size in bytes of one upstream write. L2 keeps the
   default (4, one word); L3 is elaborated with `WR_BYTES = L2_LINE_B` (32).

**Decision.** Option 3. The write slot inside a line is `req_addr[$clog2(WR_BYTES) +: $clog2(LINE_B/WR_BYTES)]`,
which at L3 is address bit 5: exactly the adapter's half select. Merge, hit write, miss latch and
write-allocate merge all use it. At least two slots per line are required (a write as wide as the line
is rejected by a guard, D-026).

**Reason.** One module, no new ports, no new state, and the L2 instance is unchanged at the default. It
matches `03_microarchitecture.md` §3, which describes L3's array as two independently write-enabled
32 B halves "the same byte-enable concept used for CPU-side writes, one granularity level up". One
write-back is one hit-or-miss decision at L3.

**Tradeoffs.** The upstream write bus is wider at L3 (256 data bits and 32 strobes against 32 and 4).
A write exactly as wide as the line cannot be expressed, which nothing here needs. This supersedes the
`req_line` row of `04_interfaces.md` §2 (updated in Task 9).

**Result.** The default width is unchanged: `tb_l2` still passes with its Phase 2 checks (108 with the
alignment check of D-025). The 32-byte case is exercised by `tb_l3` (37 checks): half-line write hits on the
upper and lower half, byte strobes at 32 B granularity, and write-allocate into the lower and the upper half,
plus an L2-sized write-back reaching memory with the right contents. On a throwaway copy ten mutants of the
shared controller were each caught by `tb_l3` (unaligned fill address, hit write ignoring the slot, dirty victim
never written back, write-back to the wrong address, strobes ignored, write-allocate dropping the merge,
write-allocate ignoring the slot, write-allocated line left clean, write-back without data, writes answered with
a response). The upper-half write-allocate check was added after reasoning that every write-allocate in the first
version of the test used the lower half; the "ignores the slot" mutant is caught only by it. `lint.ys` has an L3
block asserting zero latches and, at L3's 2 Mbit data array, exactly 3 inferred memories with `data_array` one of
them (about 35 s of the 72 s `make lint`).

---

## D-025 — Every request the controller sends downstream is line-aligned

**2026-10-10 · Phase 3**

**Problem.** L2 sent two address forms from one port: a write-back used `{tag, index, 0}` (aligned),
but a fill request carried the raw request address, offset bits and all. `FR-24` and
`03_microarchitecture.md` §4 say AXI addresses are line-aligned "by construction" and that the fill
engine therefore has no alignment logic. That is only true if the level above hands it aligned
addresses, and the reused controller at L3 would not have. No test saw it because `l3_stub` masks the
offset bits itself. The Phase 2 pull request review found it.

**Options considered.**

1. *Mask in the AXI engine.* Contradicts the specified engine and hides the inconsistency upstream.
2. *Mask in both adapter and engine.* Two places to keep right.
3. *Latch the miss address already aligned*, so the controller never produces an unaligned one.

**Decision.** Option 3: `miss_addr` is latched with its offset bits cleared.

**Reason.** It fixes the one place the address is created, adds no logic (the low flops disappear), and
makes "aligned by construction" true. Address bit 5, which the adapter uses as its half select, lies
above L2's 5-bit offset and survives. The word position inside the line is still kept separately
(`miss_slot`), and the response is the whole line, so nothing needs the low bits afterwards.

**Tradeoffs.** Requests *into* a level keep full addresses (`04_interfaces.md` §2: the downstream level
derives its own index and tag), so alignment is a property of what a level sends, not of what it accepts.

**Result.** `tb_l2` now watches every downstream handshake and fails on any address that is not 32 B
aligned (108 checks). A controller that latches the raw address fails exactly that check.

---

## D-026 — Parameter guards are `initial`-block `$fatal`s, and `make elab` proves each one fires

**2026-10-10 · Phase 3**

**Problem.** `NR-05` derives every field width from the parameters, and `02_architecture.md` §2 says
consistency is "checked as an elaboration-time assertion", but nothing was checking: a capacity that is
not a multiple of `LINE_B*WAYS`, or a non-power-of-two way count, would elaborate with wrong widths. `NR-06`
asks for `$fatal` in a generate block, which Icarus 12 silently ignores (D-023). A guard that has never
been seen to fire is indistinguishable from no guard.

**Options considered.**

1. *`$fatal` in a generate block*, as `NR-06` literally says. Honoured by Yosys, ignored by Icarus.
2. *`$fatal` in an `initial` block.* Stops Icarus at time 0 (exit code 1) and Yosys at elaboration.
3. *Simulation-only assertions.* Would not stop synthesis.

**Decision.** Option 2, plus `make elab`. `sim/param_guard_cases.sv` lists `good_*` parameter sets that
must be accepted and `bad_*` sets that must be rejected; `make elab` elaborates each under both tools,
requires them to agree, and requires a rejection to carry the guard's own message. Each bad case is built
so that exactly one guard can reject it.

**Reason.** It is the only form that stops both tools, and the one-guard-per-case rule makes a deleted
guard visible instead of being covered for by a neighbour.

**Tradeoffs.** Under Icarus the check runs at time 0 of any simulation, not at compile time. Two
degenerate sets (`WAYS = 1`, `WR_BYTES` equal to the line size) collapse to zero-width vectors that Icarus
refuses to compile before the guard can run, so they sit in a separate list where an Icarus compile error
also counts as a rejection; Yosys must still hit the guard itself. A "positive tag width" guard was
dropped: it cannot be reached with 32-bit parameters short of absurd sizes, so it could never be tested.

**Result.** The controller's guards: `LINE_B`, `WAYS`, `WR_BYTES` and the set count are powers of two;
`WAYS >= 2`; `CAPACITY_B` is a multiple of `LINE_B*WAYS`; at least two write slots per line. `make elab`
accepts 2 good sets and rejects 7 bad ones (5 by the guard's own message in both tools; the other 2 by
the guard's message in Yosys and by an earlier compile error in Icarus). On a throwaway copy, deleting each guard in turn made `make elab` report exactly the
cases it protects (power-of-two: 3, `WAYS >= 2`: 1, capacity multiple: 1, sets: 1, write slots: 1). Guards
for L3, the adapter and the fill engine are added with those units.

---

## D-027 — AXI4 fill engine: AW before W, wait for B, posted writes, sticky `mem_err`

**2026-10-10 · Phase 3**

**Problem.** `FR-22`..`FR-24` and `FR-26` call for an AXI4 master that turns each L3 line request into
exactly one fixed-length INCR burst, with a sticky error flag. The interface document fixes the signals but
not the ordering of the write channels, what happens to a write's completion, or what counts as an error.

**Options considered.**

1. *Drive AW and W together.* Saves a cycle or two per write-back, but a slave is allowed to wait for AW before
   accepting W, and some require it; presenting both at once is only safe against slaves that handle either order.
2. *AW first, then W, then wait for B.* Always legal for a slave.
3. *Answer a write to L3 with a response when B arrives.* Would break the posted-write rule (D-021).

**Decision.** Option 2, with writes posted. States: IDLE, AR, R, RESP, AW, W, B; `req_ready` only in IDLE, so
one transaction is in flight at a time (D-004). A read assembles the R beats into a line register in address
order and presents it until taken. A write sends the burst (WSTRB all ones, WLAST on the last beat), waits for
B, and only then returns to IDLE. `mem_err` is set by `rresp[1]`, by `bresp[1]` (SLVERR or DECERR), or by an
`RLAST` that disagrees with the beat count, and clears only on reset. Elaboration guards: the bus width divides
the line, a line takes 1..256 beats, a line fits one 4 KiB window.

**Reason.** L3 issues the fill read straight after a posted dirty write-back. Because the engine does not return
to IDLE until B arrives, the memory sees the write complete before it sees the read, with no extra ordering logic.
AW-then-W is the order every slave must accept.

**Tradeoffs.** The write address and data phases are not overlapped, which costs a cycle or two on a 16-beat burst.
There is no retry or recovery (`FR-26` does not require it), and a sticky flag cannot say which transaction failed.

**Result.** New `sim/axi_mem_model.sv`, a behavioural slave whose memory image is defined per 32-bit word, with stall
and error controls and checks of LEN, SIZE, burst type, 64 B alignment, WSTRB, WLAST and VALID/payload stability
against literals the testbench passes in. `sim/tb_axi4_fill_engine.sv` (29 checks) covers read order, a response held
until taken, a posted write with exact memory contents, a round trip, backpressure on every channel, SLVERR and DECERR
latching, and reset mid-burst. On a throwaway copy, ten engine mutants (length off by one, FIXED burst, read error
ignored, write error ignored, WLAST never, ready during B, wrong beat order, non-sticky `mem_err`, narrow WSTRB,
AWREADY not awaited) were each caught, and deleting each of the three guards flipped exactly its `bad_engine_*` case.
`make lint` is clean for the engine.

---

## D-028 — The adapter holds no state and has no clock

**2026-10-10 · Phase 3**

**Problem.** D-009 made the L2/L3 line-size adapter a standalone module (`FR-21`) and described it as a
"sequencer/router" with no tag, valid or dirty state. A request to L3 can take many cycles when L3 misses, so
the open question was whether the adapter must remember which 32 B half L2 asked for until the 64 B response
comes back.

**Options considered.**

1. *A small FSM with a latched half bit*, set when the request is accepted and used when the response arrives.
2. *Pure wiring*: read the half select from L2's live request address, `l2_req_addr[$clog2(L2_LINE_B)]`
   (address bit 5), and mux the response with it.

**Decision.** Option 2. Requests pass straight through (`l3_req_wdata` is L2's evicted line, `l3_req_wstrb` is
all ones, which at L3 selects the half by the same address bit, D-024), handshakes pass through unchanged, and
the response is the addressed half of L3's line.

**Reason.** `04_interfaces.md` §2 makes it a binding contract that a level holds its fill request, address
included, until the fill response has arrived; L1 does it and L2 does it. So the live address is stable for
exactly the lifetime of the request and a latch would only copy a value that cannot change. Write-backs are
posted and have no response. No clock, no reset and no state also leaves almost nothing to get wrong, and
`make lint` has no latch to find.

**Tradeoffs.** The adapter is only correct because the level above honours the hold contract. A future L2 that
dropped its request address early would flip the half mid-fill. The module header says so. The combinational
path is safe because every output of L2's downstream port is a function of its registered state, so the chain
has no loop through the adapter.

**Result.** `sim/tb_adapter.sv` (35 checks): both halves at eight addresses (including junk offset bits and the
top of the address space), all sixteen handshake combinations, the write-back data, address, write enable and
strobes, and a read staying a read. On a throwaway copy nine mutants (wrong half bit, halves swapped, strobes
zero, write enable low, address bit 5 dropped, L2 ready forced high, L3 response ready forced high, L2 response
valid forced low, write data from the wrong source) were each caught, and deleting the 2:1 ratio guard
(`NR-06`) flipped `bad_adapter_ratio`. The adapter lints clean.

---

## D-029 — Victim selection uses a free way before it asks the PLRU tree

**2026-10-10 · Phase 3**

**Problem.** The controller took its victim only from the PLRU tree and never looked at the valid bits. The
Phase 2 pull request review found, and a simulation reproduced, that hits can steer the tree at a live line
while an invalid way is still free: fill A, B, C into a 4-way set (ways 0, 2, 1), hit A, then hit B, and the tree
points at C's way; a fourth tag D evicts C and leaves way 3 invalid. Data stays correct, but capacity is
wasted and a dirty line can be written back for nothing. The same module is L3.

**Options considered.**

1. *Leave it.* Correct, but a visible inefficiency in a replacement policy that is a headline feature.
2. *Use the lowest invalid way if the set has one, otherwise the PLRU victim.*
3. *Make the tree aware of invalid ways* by masking its choice. More logic inside a module that is verified
   exhaustively as it stands.

**Decision.** Option 2: `victim_way = (all ways valid) ? plru_victim : lowest invalid way`. The tree is still updated
on every fill and every hit.

**Reason.** It is the usual rule, and it costs a priority encoder over the valid bits of one set, which are already
being read for the hit check. `S_TAG_CHECK` is unchanged: it already requires `valid && dirty` to write back, so
an invalid victim is never written back, which also covers a stale dirty bit left by a reset (D-019).

**Tradeoffs.** Fill order from an empty set changes from the PLRU order (ways 0, 2, 1, 3) to 0, 1, 2, 3. Tree
PLRU is mirror-symmetric once a set is full, so which *line* is evicted does not depend on which free way was
used; only expectations that name a way changed. The extra gates sit on the `S_TAG_CHECK` path; their timing
cost is **NOT YET MEASURED** (Phase 8).

**Result.** `tb_l2` (112 checks): the set 6 and set 137 scenarios were re-derived for the new fill order, not
weakened (set 6 now hits way 1 and expects the write-backs of way 2 then way 0; set 137 gained one clean
eviction so the partially written line, now in way 1, is the next victim); a new "set 9" scenario fills three
lines, hits two, adds a fourth and requires all four to still be resident with no downstream read, plus a direct
check of the valid bits that pins "lowest free way first". Run against the previous PLRU-only controller, the
updated `tb_l2` fails four checks (set 6 twice, set 137 once, set 9 once). On a throwaway copy four mutants of
the new logic were caught by `tb_l2` (highest free way, live request set instead of the latched one, validity
ignored, always the lowest way); the highest-free-way mutant is caught only by the internal valid-bit check
because it is invisible at the interface, and survives `tb_l3` alone for the same reason. `tb_l3` and the L1 tests
are unchanged and pass; `make lint` is clean.

---

*Phase 1 (L1 controllers) is complete; D-015 through D-017 were recorded during it. Phase 2 (L2
controller, standalone) begins with D-018/D-019 above, applying every Yosys-compatibility lesson
from Phase 1 (D-016, D-017) plus the two found here from the start, rather than rediscovering
them.*

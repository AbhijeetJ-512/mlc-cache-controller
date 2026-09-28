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
supports no classes, `randomize()`, covergroups, or concurrent SVA) already rules out a
UVM-based verification environment; cocotb is the practical route regardless of scope. A
multi-core coherency protocol adds an entire second axis of verification complexity on top of
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

*Next: user review of the written spec (`01_requirements.md` through `04_interfaces.md`,
this log), then `writing-plans` for the Phase 1 implementation plan.*

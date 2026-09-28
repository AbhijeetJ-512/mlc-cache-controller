# mlc_cache_controller

**A parameterized, single-core, 3-level (L1/L2/L3) cache hierarchy controller.** Split
direct-mapped write-through L1 instruction/data caches, unified set-associative write-back L2
and L3 with tree-PLRU replacement, a custom valid/ready CPU-side interface, and an AXI4
memory-side interface. Targets synthesis on **Sky130HD** standard cells via **Yosys**.

> **Project status: Phase 0 of 11 — Requirements & Architecture.** No RTL has been written yet.
> Every number in this repository either cites a checked-in tool report or is labelled
> **NOT YET MEASURED**. See [`docs/00_project_plan.md`](docs/00_project_plan.md) for the full
> phase plan and the Definition of Done for each phase.

---

## What makes this hierarchy's shape deliberate, not default

Every organizational choice below was made against at least one rejected alternative, with the
reasoning and the accepted tradeoff recorded in
[`docs/engineering_log.md`](docs/engineering_log.md):

1. **Each level makes a different, justifiable tradeoff — not the same one three times.** L1 is
   direct-mapped and write-through, which provably shortens both its critical path (no way-select
   mux) and its miss-handling FSM (no eviction state — write-through lines are never dirty). L2/L3
   are set-associative and write-back, trading a longer FSM and PLRU state for fewer conflict
   misses and less traffic to the next level, where capacity matters more than raw latency.
2. **L3's line is deliberately twice L2's width (64 B vs. 32 B)**, to amortize AXI4 burst and
   DRAM-row overhead where it matters most — closest to memory. That choice is not free: it
   requires a dedicated line-size adapter module, documented as real design work in
   `docs/03_microarchitecture.md` §3, not hand-waved.
3. **No coherency protocol and no inclusion policy (NINE) — by scope, not by omission.** This is
   a single-requester hierarchy; coherency and inclusion both exist primarily to bound multi-agent
   snoop traffic, a problem this design doesn't have. Paying either's complexity here would buy no
   functional benefit — see D-001/D-008 in the engineering log.
4. **Misses are blocking in v1, and that limitation is stated, not hidden.** Non-blocking misses
   (MSHRs, hit-under-miss) were explicitly scoped out to keep the verification matrix tractable
   for a first fully-closed version — see D-004. The external interface contract was kept generic
   enough to add non-blocking support later without renegotiating it.

## Documentation

| Doc | Contents |
|---|---|
| [`docs/00_project_plan.md`](docs/00_project_plan.md) | Repository structure, 11 phase definitions with explicit Definition of Done, risks, verified toolchain state |
| [`docs/01_requirements.md`](docs/01_requirements.md) | Full requirements specification — functional, address/sizing, performance, verification, synthesis, timing |
| [`docs/02_architecture.md`](docs/02_architecture.md) | System architecture: hierarchy diagram, per-level address partitioning (derived, not asserted), module list, data flow |
| [`docs/03_microarchitecture.md`](docs/03_microarchitecture.md) | Per-controller FSMs, the tree-PLRU algorithm with a worked example, the line-size adapter, the AXI4 fill engine |
| [`docs/04_interfaces.md`](docs/04_interfaces.md) | Signal-level CPU-side, inter-level, and AXI4 memory-side interface specification |
| [`docs/engineering_log.md`](docs/engineering_log.md) | Every architectural decision: options considered, decision, reason, and the tradeoff accepted — D-001 through D-012 |

## Toolchain (verified on this machine, per project memory)

| Tool | Status | Use |
|---|---|---|
| Icarus Verilog 12.0 | installed | Simulation (cocotb-based — see below) |
| Yosys 0.33 | installed | Synthesis, target Sky130HD |
| OpenSTA 2.7.0 | installed | Static timing analysis |
| Sky130HD liberty/LEF | present on disk | `sky130hd_tt.lib` under the local OpenROAD test assets |
| cocotb | **not yet installed** | Required from Phase 1 — `pip install cocotb` |

**Why cocotb, not UVM:** Icarus Verilog 12 supports no SystemVerilog classes, `randomize()`,
covergroups, or concurrent assertions, so a class-based UVM testbench cannot run on this
toolchain. Verification from Phase 1 onward is cocotb (Python-driven, plain synthesizable RTL as
the DUT) — see `docs/01_requirements.md` VR-01 and `docs/00_project_plan.md` §5.

## Reproducing the numbers in this README

There are none yet. Nothing has been built or measured (Phase 0). Every command that will
eventually produce a number is specified in the phase table in `docs/00_project_plan.md`, so
each claim will be checkable the moment it exists — per this project's `NOT YET MEASURED` policy.

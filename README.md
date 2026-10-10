# mlc_cache_controller

**A parameterized, single-core, 3-level (L1/L2/L3) cache hierarchy controller.** Split
direct-mapped write-through L1 instruction/data caches, unified set-associative write-back L2
and L3 with tree-PLRU replacement, a custom valid/ready CPU-side interface, and an AXI4
memory-side interface. Synthesis, STA, and place-and-route all target **Sky130HD** via
**Yosys + OpenSTA + OpenROAD**, in a single Makefile matching this portfolio's `Full-Adder` flow.

> **Project status: Phase 2 of 12 — L1 controllers (I$ and D$) and the L2 controller, built and
> Tier-1-verified.** The shared L1 core (`rtl/l1/l1_cache_ctrl.sv`) with its I$/D$ wrappers, the L2
> controller (`rtl/l2/l2_cache_ctrl.sv`) and the parameterized tree-PLRU module
> (`rtl/replace/plru_tree.sv`) pass their Tier-1 module-level Icarus tests (`make sim`: 229 checks
> across 5 testbenches, logs checked in under `sim/logs/`) and the Yosys elaboration check with
> zero inferred latches (`make lint`). L3, the line-size adapter, the AXI4 fill engine and the
> integrated `mlc_cache_top` are not written yet. Synthesis, timing, area and P&R figures are
> **NOT YET MEASURED**; the UVM tier is **NOT YET RUN (external simulator required)**.
> Every number in this repository either cites a checked-in tool report, is labelled
> **NOT YET MEASURED** (a locally-runnable figure that just hasn't been produced yet), or
> **NOT YET RUN (external simulator required)** (the UVM verification tier — see below). See
> [`docs/00_project_plan.md`](docs/00_project_plan.md) for the full phase plan and the Definition
> of Done for each phase.

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
5. **Verification is two-tiered because the toolchain honestly requires it, not by preference.**
   A full SystemVerilog UVM environment needs SystemVerilog classes; Icarus 12 (the only simulator
   on this machine) has none, and no UVM library or class-capable simulator is installed here
   either — verified directly by trying to compile this portfolio's own `APB_Design_and_Verification`
   project and getting `uvm_macros.svh not found`. Rather than either silently downgrading to a
   non-UVM approach or shipping a UVM testbench nobody here can run (the failure mode already on
   record for this portfolio's `axi_aes_engine`), this project splits verification **by test
   level**: standalone controllers are checked locally on Icarus; the integrated hierarchy is
   verified exclusively by the UVM environment, externally — see D-013.

## Documentation

| Doc | Contents |
|---|---|
| [`docs/00_project_plan.md`](docs/00_project_plan.md) | Repository structure, 13 phase definitions (0-12) with explicit Definition of Done, risks, verified toolchain state |
| [`docs/01_requirements.md`](docs/01_requirements.md) | Full requirements specification — functional, address/sizing, performance, verification, synthesis, timing |
| [`docs/02_architecture.md`](docs/02_architecture.md) | System architecture: hierarchy diagram, per-level address partitioning (derived, not asserted), module list, data flow |
| [`docs/03_microarchitecture.md`](docs/03_microarchitecture.md) | Per-controller FSMs, the tree-PLRU algorithm with a worked example, the line-size adapter, the AXI4 fill engine |
| [`docs/04_interfaces.md`](docs/04_interfaces.md) | Signal-level CPU-side, inter-level, and AXI4 memory-side interface specification |
| [`docs/engineering_log.md`](docs/engineering_log.md) | Every architectural decision: options considered, decision, reason, and the tradeoff accepted — D-001 through D-021 |

## Repository layout

Follows the target tree in [`docs/00_project_plan.md`](docs/00_project_plan.md) §1. Directories
for later phases are created when their phase starts, so the *planned* entries below do not exist
yet.

```
mlc_cache_controller/
├── rtl/
│   ├── common/     mlc_pkg.sv, reset_sync.sv
│   ├── l1/         l1_cache_ctrl.sv (shared core), l1_icache_ctrl.sv, l1_dcache_ctrl.sv
│   ├── l2/         l2_cache_ctrl.sv
│   ├── replace/    plru_tree.sv
│   └── l3/, adapter/, mem_if/, top/                       planned, Phases 3-4
├── sim/            Tier-1 module-level testbenches, behavioural stubs, checked-in logs (sim/logs/)
├── scripts/        lint.ys (Yosys elaboration check); synthesis/STA/P&R scripts arrive in Phases 7-9
├── docs/           requirements, architecture, microarchitecture, interfaces, engineering log,
│                   and per-phase implementation plans (docs/superpowers/plans/)
├── Makefile        sim, lint, clean (flow targets arrive with their phases)
└── tb_uvm/, assertions/, formal/, constraints/, config/,
    sky130hd/, build/, pnr_results/, results/               planned, Phases 5-10
```

## Quick start

Needs Icarus Verilog 12 and Yosys (see Toolchain below).

```bash
make sim    # all Tier-1 module-level tests; writes sim/logs/*.log
make lint   # Yosys elaboration check, zero latches/tristates (about 40 s)
make help   # list targets
```

## Verification: split by test level, not just by tool

- **Tier 1 — module-level smoke tests** (`sim/`): plain, class-free Verilog, directed, one
  testbench per **standalone** controller (L1-I, L1-D, L2, L3, the adapter, the PLRU tree). Runs
  on Icarus in this repository via `make sim`. Covers module-level correctness only — there is no
  Tier-1 test of the integrated design.
- **Tier 2 — UVM environment** (`tb_uvm/`): a full IEEE 1800.2 UVM environment (transaction,
  sequence, sequencer, driver, monitor, agent, scoreboard, env, test, config — matching this
  portfolio's `APB_Design_and_Verification` structure) whose DUT is the **fully integrated**
  `mlc_cache_top`, with constrained-random sequences and functional coverage for maximum
  coverage. This is the **only** functional verification the integrated hierarchy receives.
  **This tier requires an external, class-capable simulator** (VCS/Questa/Xcelium) that is not
  installed on this machine — attempting to compile `APB_Design_and_Verification` here fails
  immediately with `uvm_macros.svh not found`, and Icarus 12 has no SystemVerilog class support
  regardless. `tb_uvm/README.md` gives the exact external invocation. Its pass/fail result and
  coverage numbers — including for the integrated hierarchy overall — are labelled
  **NOT YET RUN (external simulator required)** until run externally and the log is checked in.

See D-013 in `docs/engineering_log.md` for the full reasoning, including the direct evidence.

## Toolchain (verified on this machine)

| Tool | Status | Use |
|---|---|---|
| Icarus Verilog 12.0 | installed | Tier-1 smoke-test simulator |
| Yosys 0.33 | installed | Synthesis, target Sky130HD |
| OpenSTA 2.7.0 | installed | Static timing analysis |
| OpenROAD v2.0-25346 | **installed, verified runnable** | Place and route, target Sky130HD |
| Sky130HD liberty/LEF | present on disk | Copied into `sky130hd/` |
| Class-capable SV simulator (VCS/Questa/Xcelium) + UVM library | **not installed** | Required only for `tb_uvm/`, supplied externally by the user |

## Reproducing the numbers in this README

There are no performance, area or timing numbers yet — nothing has been synthesized or measured.
The only checked-in results so far are the Tier-1 pass/fail logs from Phases 1-2: `make sim` regenerates
`sim/logs/*.log`, and `make lint` re-runs the Yosys elaboration check. Every command that will
eventually produce a number is specified in the phase table in `docs/00_project_plan.md`, so
each claim will be checkable the moment it exists — per this project's `NOT YET MEASURED` policy.

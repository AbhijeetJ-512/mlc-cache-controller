# mlc_cache_controller

**A parameterized, single-core, 3-level (L1/L2/L3) cache hierarchy controller.** Split
direct-mapped write-through L1 instruction/data caches, unified set-associative write-back L2
and L3 with tree-PLRU replacement, a custom valid/ready CPU-side interface, and an AXI4
memory-side interface. Synthesis, STA, and place-and-route all target **Sky130HD** via
**Yosys + OpenSTA + OpenROAD**, in a single Makefile matching this portfolio's `Full-Adder` flow.

> **Project status: Phase 8 of 12 (Phases 5 and 6, the UVM tier and the formal properties, are deferred at the project
> owner's request) — every unit is built and Tier-1-verified, the units are wired into one IP, each unit has been
> synthesized to Sky130HD, and the default configuration has been timed with OpenSTA.** `make check` runs the parameter guards, a
> structural check of the top, 13 Tier-1 testbenches (594 checks, logs checked in under `sim/logs/`), the Yosys elaboration check, an RTL
> coding-rule check and the self-tests of the synthesis and timing flows, all passing, in about three and a half minutes (187 to 220 s across
> runs). `make synth` and `make synth-sweep` map every unit at its default configuration and at 11 sweep points to Sky130HD with zero latches,
> tri-states, undriven or multiply-driven nets or unlisted warnings ([`build/reports/summary.md`](build/reports/summary.md)). **Two things were not
> synthesized: the default 256 KiB L3 (it ran out of memory under a 12,000,000 KiB cap, so its area is NOT MEASURED; L3 is measured up to 32 KiB)
> and the integrated top (it is wiring only).** `make synth-timing` and `make sta` give each unit's minimum clock period, critical path, logic
> depth, hold slack and a static power estimate ([`build/reports/timing_summary.md`](build/reports/timing_summary.md)); every period is an
> **upper bound on frequency** (ideal clock, no wires), analysed one unit at a time, so **no frequency of the integrated hierarchy is claimed**.
> The integrated top **elaborates cleanly but has not been simulated**: its functional behaviour will be verified only by the UVM tier.
> Place-and-route figures and any timing across units are **NOT YET MEASURED**; the UVM tier is **NOT YET RUN (external simulator required)**.
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
| [`docs/03_microarchitecture.md`](docs/03_microarchitecture.md) | Per-controller FSMs, the tree-PLRU algorithm with a worked example, the line-size adapter, the AXI4 fill engine, the L1 arbiter and the top-level ports |
| [`docs/04_interfaces.md`](docs/04_interfaces.md) | Signal-level CPU-side, inter-level, and AXI4 memory-side interface specification |
| [`docs/engineering_log.md`](docs/engineering_log.md) | Every architectural decision: options considered, decision, reason, and the tradeoff accepted — D-001 through D-039 |

## Repository layout

Follows the target tree in [`docs/00_project_plan.md`](docs/00_project_plan.md) §1. Directories
for later phases are created when their phase starts, so the *planned* entries below do not exist
yet.

```
mlc_cache_controller/
├── rtl/
│   ├── common/     mlc_pkg.sv, reset_sync.sv
│   ├── l1/         l1_cache_ctrl.sv (shared core), l1_icache_ctrl.sv, l1_dcache_ctrl.sv
│   ├── arbiter/    l1_l2_arbiter.sv (lets the two L1s share L2's one port)
│   ├── l2/         l2_cache_ctrl.sv (the shared write-back controller: L2 as is, L3 via l3_cache_ctrl)
│   ├── l3/         l3_cache_ctrl.sv (the same controller at L3's parameters)
│   ├── adapter/    l2_l3_width_adapter.sv
│   ├── mem_if/     axi4_fill_engine.sv
│   ├── replace/    plru_tree.sv
│   └── top/        mlc_cache_top.sv (structural only: instances and wires, checked by scripts/check_top.py)
├── sim/            Tier-1 module-level testbenches, behavioural stubs, an AXI4 memory model,
│                   parameter-guard cases, and checked-in logs (sim/logs/)
├── scripts/        lint.ys (Yosys elaboration check), check_top.py, gen_plru_tables.py; synth.tcl (the synthesis
│                   flow), synth_run.py (the table of synthesis points, the log check, the gate-level re-run),
│                   synth_summary.py, synth_stuckat.py, synth_selftest/, abc_speed.script/.constr (the timing-driven
│                   mapping); sta.tcl, sta_run.py, sta_summary.py, sta_selftest.py (static timing); P&R scripts arrive in Phase 9
├── constraints/    mlc.sdc: the clock and boundary constraints of one unit analysed on its own
├── sky130hd/       the Sky130HD typical-corner liberty the flow reads (origin and SHA-256 in its README)
├── build/reports/  checked-in evidence: one directory per synthesis point (and its timing), summary.md, timing_summary.md
├── docs/           requirements, architecture, microarchitecture, interfaces, engineering log,
│                   and per-phase implementation plans (docs/superpowers/plans/)
├── Makefile        check, sim, test-<name>, elab, top, lint, list, clean, and the synth-* targets
└── tb_uvm/, assertions/, formal/, config/,
    pnr_results/, results/                                  planned, Phases 5-10
```

## Testing and checking

Needs Icarus Verilog 12 and Yosys (see Toolchain below). Everything goes through the Makefile:

```bash
make check             # parameter guards + top check + every Tier-1 test + Yosys lint; non-zero exit on any failure
make sim               # every Tier-1 testbench, one verdict line each (about 3 s)
make test-tb_l3        # just one testbench; V=1 also prints its full output
make list              # the registered testbenches
make elab              # bad parameter sets are rejected, good ones accepted (about 30 s)
make top               # mlc_cache_top is structural only and elaborates under Icarus -Wall with no warnings (under 1 s)
make lint              # Yosys elaboration check, zero latches/tristates (about 170 s)
make rules             # rtl/ uses only always_comb and always_ff @(posedge clk ...): no incomplete sensitivity list, no gated clock
make synth-selftest    # each of the synthesis flow's checks stops the module built to break it (part of make check, about 10 s)
make clean             # remove build products; the tracked logs in sim/logs/ and build/reports/ stay
```

Synthesis is separate from `make check` because it takes tens of minutes (it needs 9.4 GiB of memory for its largest point):

```bash
make synth             # every unit at its default configuration (24 min of synthesis), then the gate-level re-runs
make synth-sweep       # the 11-point capacity / associativity sweep (56 min)
make synth-l3-default  # attempt the default 256 KiB L3; records an out-of-memory result (4 min)
make synth-abc-compare # the L1-D through ABC's full script, to compare with the fast one (9 min)
make synth-gatesim     # the four Tier-1 tests that use only ports, run on the synthesized netlists (needs make synth first)
make synth-stuckat     # tie every cell output of the arbiter and adapter netlists to 0 and 1 and run their tests (needs make synth first)
make synth-selftest-deep  # break each of the flow's checks in turn in a copy; the self-test must notice every time (2 min)
make synth-timing      # timing-driven mapping of the default configuration and four 8 KiB points (49 min of synthesis)
make sta               # OpenSTA on those netlists and four raw ones: minimum period, critical path, hold, power (75 min; needs make synth and make synth-timing)
make sta-sensitivity   # how the minimum period moves with the boundary delays, on four cheap points (about 10 min)
make sta-selftest      # the timing flow's known answers and refused cases (part of make check, about 5 s)
```

A test passes only if its simulation exits cleanly, prints no `FAIL` line, and prints at least one
`PASS`. Each run's full output goes to `sim/logs/<name>.log`. To add a testbench, add one
`$(call register,<name>,<sources>)` line to the Makefile's registry (D-022).

## Synthesis results (Sky130HD, Yosys 0.33)

Measured by `make synth` and `make synth-sweep`; all of it, with cell counts, flip-flop counts, wall time and peak memory, is in
[`build/reports/summary.md`](build/reports/summary.md). Area is Yosys's `stat -liberty` cell area of each unit mapped on its own
at the typical corner.

| Unit | Area (um^2) | Cells | Flip-flops |
|---|---|---|---|
| L1-I, 4 KiB direct-mapped | 1,455,566 | 162,596 | 35,491 |
| L1-D, 4 KiB direct-mapped | 1,496,114 | 166,059 | 35,596 |
| L2, 32 KiB 4-way | 15,047,108 | 2,249,289 | 284,763 |
| L3, **32 KiB** 8-way (the largest L3 that completes; **not** the default L3) | 14,710,293 | 2,189,987 | 274,710 |
| L2-L3 adapter | 3,323 | 800 | 0 |
| L1 to L2 arbiter | 1,026 | 108 | 3 |
| AXI4 fill engine | 36,102 | 5,511 | 554 |
| Reset synchroniser | 54 | 3 | 2 |
| **L3, 256 KiB 8-way (default)** | **NOT MEASURED: out of memory under a 12,000,000 KiB cap after 252 s** | | |

What the numbers say, and what they do not:

- **There are no memory macros in this flow, so every stored bit is a flip-flop plus multiplexing.** The flip-flop count is the
  number of stored bits plus 35 to 856 control flip-flops at every cache point, so the arrays are intact, and flip-flops are only
  37 to 49% of the area; the rest is the write-enable and read multiplexing around them. A design built on SRAM macros would look
  different, and no figure for one is claimed here.
- Area follows capacity: L2 is 3,829,883, 7,608,102 and 15,047,108 um^2 at 8, 16 and 32 KiB. Associativity costs little: L2 at 32 KiB
  is 14,997,923, 15,047,108 and 15,071,885 um^2 at 2, 4 and 8 ways.
- The flow's cost is part of the result. The default L2 takes just under ten minutes and 9 GiB; for L2 and for L3, peak memory doubles with each doubling of capacity (2.3, 4.5 and 9.0 GiB at 8, 16 and 32 KiB).
- Not synthesized: the default L3 (above) and the integrated top, which is wiring only. No whole-hierarchy area is claimed.
- Timing is in the next section; place and route is **NOT YET MEASURED** (Phase 9).
- The four unit testbenches that use only ports (`reset_sync`, L1-I, the adapter, the arbiter) also pass, with the same testbench files, on the synthesized
  netlists. The other four units (L1-D, L2, L3, the AXI4 engine) have testbenches that read internal state and have **no gate-level evidence**.

## Timing results (OpenSTA 2.7.0, Sky130HD typical corner)

Measured by `make synth-timing` and `make sta`; all of it, with the four classes of path, hold, power and the reset network, is in
[`build/reports/timing_summary.md`](build/reports/timing_summary.md). Each unit is mapped for delay (fan-out buffering and sizing), then analysed alone on one ideal
clock with a 0.35 ns input delay and a 0.15 ns output delay (`constraints/mlc.sdc`).

| Unit | Min period (ns) | Fmax bound (MHz) | Limiting path | Hold slack (ns) |
|---|---|---|---|---|
| Reset synchroniser | 0.638 | 1,567 | register to output | 0.331 |
| L1 to L2 arbiter | 1.859 | 538 | register to output, 4 cells | 0.517 |
| L2-L3 adapter | 1.446 | 692 | input to output, 3 cells | 0.553 |
| AXI4 fill engine | 2.495 | 401 | register to register, 7 cells | 0.481 |
| L1-I, 4 KiB | 4.171 | 240 | register to output, 16 cells | 0.431 |
| L1-D, 4 KiB | 5.997 | 167 | input to register, 25 cells | 0.427 |
| L2, 32 KiB 4-way | 9.168 | 109 | input to register, 34 cells | 0.416 |
| L3, **32 KiB** 8-way (not the default L3) | 8.366 | 120 | input to register, 32 cells | 0.418 |

- **Every figure is an upper bound on frequency**, not what a built chip would run at: the clock is ideal and there are no wires. Each unit is analysed
  alone, so a path that crosses units (an L1's request through the arbiter into L2) is not analysed and no frequency of the whole is claimed.
- **Without buffering the numbers mean nothing.** The unbuffered Phase 7 netlist of the L1-I needs 51.5 ns (two minimum-size gates drive fan-outs of 511 and 261); mapped for
  delay it needs 4.17 ns. The arbiter goes from 7.00 to 1.86 ns.
- **About half of the L2 and L3 limiting paths is the address being fanned out to the flip-flop arrays** (4.5 of 9.2 ns, 17 buffers in series; ABC builds a chain, not a tree), so the
  L2 and L3 numbers are pessimistic there and optimistic about wires. With every fan-out buffer free they would need 4.6 and 3.9 ns, a bound nobody reaches.
- **The prediction that the L3's 8-way compare is the longest hit path is contradicted** (`docs/03_microarchitecture.md` section 5, D-042): at 8 KiB the direct-mapped L1-D needs 5.76 ns, the
  4-way L2 8.52, the 4-way L3 7.05 and the 8-way L3 7.22. Associativity costs 0.17 ns (2.4%) from 4 to 8 ways at the L3, less than the difference between the L2 and L3 (line size and write path).
- The reset net (a fan-out of up to 1,796) is not buffered by this flow and is a false path in the figures above; its unbuffered period is recorded separately for P&R.
- Power in the reports is OpenSTA's static estimate at its default switching activity, not a design estimate (D-041).

## Verification: split by test level, not just by tool

- **Tier 1 — module-level smoke tests** (`sim/`): plain, class-free Verilog, directed, one
  testbench per **standalone** unit (L1-I, L1-D, L2, L3, the adapter, the AXI4 fill engine, the PLRU
  tree, the L1 arbiter). Runs on Icarus in this repository via `make sim`. Covers module-level
  correctness, plus three narrow **boundary-contract** tests (D-030, D-033) that join real modules at
  one boundary — L1 to L2, both L1 controllers to L2 through the arbiter, and L2 to adapter to L3 to
  the AXI4 fill engine — because both D-021 bugs lived on a boundary and no single-module test could
  see them. There is no Tier-1 test of the integrated hierarchy: `mlc_cache_top` gets an elaboration
  check only (`make top` and a block in `make lint`), which checks the wiring against structural rules
  (every port connected and named for its signal, one driver per signal, only wires, constants and instances in the top,
  no loops across units) and says nothing about behaviour.
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
| Yosys 0.33 | installed | Synthesis, target Sky130HD (`yosys -c` runs `scripts/synth.tcl`) |
| OpenSTA 2.7.0 | installed, used from Phase 8 | Static timing analysis (`sta`) |
| OpenROAD v2.0-25346 | **installed, verified runnable** | Place and route, target Sky130HD |
| Python 3.13 | installed | `make top` (`scripts/check_top.py`), the synthesis driver and summary, the PLRU table generator |
| Sky130HD liberty | **vendored** in `sky130hd/` | Synthesis; the LEF files are added with place and route (Phase 9) |
| Class-capable SV simulator (VCS/Questa/Xcelium) + UVM library | **not installed** | Required only for `tb_uvm/`, supplied externally by the user |

## Reproducing the numbers in this README

- **Test counts and the pass/fail verdicts:** `make check` (about three minutes); `make sim` regenerates `sim/logs/*.log`.
- **Synthesis figures:** `make synth` and `make synth-sweep` rewrite `build/reports/<point>/{stat,checks,run}.txt` and `summary.md`.
  `stat.txt` is Yosys's own report, `checks.txt` lists the assertions that passed, `run.txt` records the command's outcome, wall time and
  peak memory. Area and cell counts reproduce exactly; wall time and memory depend on the machine (the figures here are from a
  15 GiB machine that was also running other work).
- **The default L3's out-of-memory result:** `make synth-l3-default`. It depends on the machine and on the 12,000,000 KiB cap in
  `scripts/synth_run.py`.
- **Timing figures:** `make synth-timing` then `make sta` rewrite `build/reports/<point>/{timing,power,reset,sta}.txt` and `timing_summary.md`; the minimum
  periods were identical on every repeated run made (the mapping and OpenSTA are deterministic); wall time and memory depend on the machine.
- **Place and route, and the UVM tier:** nothing yet. Every command that will produce one of those numbers is specified
  in the phase table in `docs/00_project_plan.md`, so each claim will be checkable the moment it exists, per this project's
  `NOT YET MEASURED` policy.

# mlc_cache_controller

A parameterised, single-core cache hierarchy with three levels. The L1 instruction and data caches are direct-mapped and
write-through, L2 and L3 are set-associative and write-back with tree-PLRU replacement, the CPU side uses a custom valid/ready
interface, and the memory side is AXI4. Synthesis, STA and place and route all target **Sky130HD** through **Yosys, OpenSTA and
OpenROAD**, driven by one Makefile in the same style as this portfolio's `Full-Adder` flow.

**Where it stands.** The original project is at Phase 8 of 12. Phases 5 and 6, the UVM tier and the formal properties, were put off
at my request. Every unit is built and passes its Tier-1 tests, the units are wired into one IP, and each unit has been synthesised
to Sky130HD and timed with OpenSTA (the L3 at 32 KiB, not at its default 256 KiB). In the original project `make check` ran the
parameter guards, a structural check of the top, 13 Tier-1 testbenches (594 checks, logs checked in under `sim/logs/`), the Yosys
elaboration check, an RTL coding-rule check and the self-tests of the synthesis and timing flows, all passing, in about three and a
half minutes (187 to 220 s across runs). `make synth` and `make synth-sweep` map every unit at its default configuration and at 11
sweep points to Sky130HD with zero latches, tri-states, undriven or multiply-driven nets, or unlisted warnings
([`build/reports/summary.md`](build/reports/summary.md)).

**Two things weren't synthesised.** The default 256 KiB L3 ran out of memory under a 12,000,000 KiB cap, so its area is NOT
MEASURED (L3 is measured up to 32 KiB), and the integrated top is wiring only. `make synth-timing` and `make sta` give each unit's
minimum clock period, critical path, logic depth, hold slack and a static power estimate
([`build/reports/timing_summary.md`](build/reports/timing_summary.md)). Every period is an **upper bound on frequency** (ideal clock,
no wires) and comes from one unit analysed on its own, so **I don't claim a frequency for the integrated hierarchy**. Place-and-route
figures and any timing across units are NOT YET MEASURED, and the UVM tier is NOT YET RUN (it needs an external simulator).

**What the portfolio copy (2026-10-21) adds.** The original's status said the integrated top had only been elaborated, never
simulated. This copy adds:

1. **A system-level test of the integrated top** (`sim/tb_mlc_top.sv`, `make test-tb_mlc_top`). Both CPU ports are driven at the
   same time through `mlc_cache_top`, at its default sizes, against the AXI4 memory model, and every load and fetch is compared with
   a flat reference memory (summary in `results/system_test.txt`, log in `sim/logs/tb_mlc_top.log`). It checks data integrity. It
   isn't the UVM tier and it checks no performance property; the bound assertions and cover points of item 4 were added later and
   run on it too.
2. **An injected-bug campaign for that test** (`python3 scripts/mutate_top.py`, results in `results/mutants_top.txt`).
3. **Diagrams and a design document** in `docs/portfolio/` (sources: `docs/portfolio/diagrams/make_diagrams.py`,
   `scripts/doc_snippets.py`).
4. **Bound SVA checkers, cover points and a second injected-bug campaign** (revision 3): `verif/mlc_checkers.sv` and
   `verif/mlc_binds.sv`, run on the existing Tier-1 testbenches under Verilator 5.052 (`make sva`, `make sva-mutants`, results in
   `results/sva/`, and the section "Bound assertions" below). It changed two testbenches (`sim/tb_arbiter.sv`,
   `sim/tb_axi4_fill_engine.sv`) and the memory model (`sim/axi_mem_model.sv`) where a mutant showed a stimulus the tests never
   produced. `make sim` now runs 14 testbenches with 607 checks.

The original is in `Projects/mlc_cache_controller`, and the rest is unchanged. The functional UVM tier, formal properties and place
and route are still NOT RUN / NOT MEASURED. Every number here either cites a checked-in tool report or is labelled NOT YET MEASURED
(a figure I could produce here but haven't yet) or NOT YET RUN (external simulator required) for the UVM tier.
[`docs/00_project_plan.md`](docs/00_project_plan.md) has the full phase plan and each phase's definition of done.

---

## Why the hierarchy looks the way it does

I made each of these choices against at least one alternative, and the reasoning and the trade-off I accepted are in
[`docs/engineering_log.md`](docs/engineering_log.md).

1. **Each level makes its own trade-off.** L1 is direct-mapped and write-through, which shortens both its critical path (there's no
   way-select mux) and its miss-handling FSM (there's no eviction state, because write-through lines are never dirty). L2 and L3 are
   set-associative and write-back. They pay for a longer FSM and PLRU state with fewer conflict misses and less traffic to the next
   level, which is where capacity matters more than raw latency.
2. **L3's line is twice as wide as L2's (64 B against 32 B)**, to spread the AXI4 burst and DRAM-row overhead where it matters most,
   closest to memory. That costs a dedicated line-size adapter, which is real design work and is described in
   `docs/03_microarchitecture.md` §3.
3. **There's no coherency protocol and no inclusion policy (NINE).** This is a single-requester hierarchy, and coherency and
   inclusion mostly exist to limit snoop traffic between several agents, a problem this design doesn't have. Adding either would cost
   complexity for no functional gain (D-001 and D-008 in the engineering log).
4. **Misses block in this first version.** I left out non-blocking misses (MSHRs, hit-under-miss) to keep the verification matrix
   manageable for a first fully closed version (D-004). The external interface contract is generic enough that non-blocking support
   can be added later without changing it.
5. **Verification is split by test level because of the tools available.** A full SystemVerilog UVM environment needs SystemVerilog
   classes. Icarus 12, the only simulator the original project had, has none, and there was no UVM library or class-capable simulator
   either: compiling this portfolio's `APB_Design_and_Verification` project here failed with `uvm_macros.svh not found`. I didn't want
   to quietly drop UVM, or to ship a UVM testbench nobody here could run (which is what went wrong with this portfolio's
   `axi_aes_engine`), so the standalone controllers are checked locally on Icarus and the integrated hierarchy was left to the UVM
   environment, run externally (D-013). Since then I've got UVM running on a Verilator 5.052 built from source, in the `alu_uvm_env`
   project, but the UVM tier of this cache hasn't been written for it. The portfolio copy's system test covers data integrity of the
   integrated top in the meantime.

## Documentation

| Doc | Contents |
|---|---|
| [`docs/00_project_plan.md`](docs/00_project_plan.md) | Repository structure, 13 phase definitions (0-12) with explicit Definition of Done, risks, verified toolchain state |
| [`docs/01_requirements.md`](docs/01_requirements.md) | Full requirements specification — functional, address/sizing, performance, verification, synthesis, timing |
| [`docs/02_architecture.md`](docs/02_architecture.md) | System architecture: hierarchy diagram, per-level address partitioning (derived from the parameters), module list, data flow |
| [`docs/03_microarchitecture.md`](docs/03_microarchitecture.md) | Per-controller FSMs, the tree-PLRU algorithm with a worked example, the line-size adapter, the AXI4 fill engine, the L1 arbiter and the top-level ports |
| [`docs/04_interfaces.md`](docs/04_interfaces.md) | Signal-level CPU-side, inter-level, and AXI4 memory-side interface specification |
| [`docs/engineering_log.md`](docs/engineering_log.md) | Every architectural decision: options considered, decision, reason, and the tradeoff accepted — D-001 through D-039 |

## Repository layout

It follows the target tree in [`docs/00_project_plan.md`](docs/00_project_plan.md) §1. Directories for later phases are created when
their phase starts, so the entries marked as planned below don't exist yet.

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
├── verif/          the bound SVA checkers and their binds (portfolio addition, revision 3)
├── results/        system test, injected-bug campaigns and SVA results (portfolio additions)
└── tb_uvm/, assertions/, formal/, config/,
    pnr_results/                                            planned, Phases 5-10
```

## Testing and checking

You need Icarus Verilog 12 and Yosys (see Toolchain below). Everything goes through the Makefile:

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
make sva               # (portfolio addition) the testbenches under Verilator 5.052 with the bound checkers (53 s from a cold start with 7 jobs)
make sva-mutants       # (portfolio addition) the 106-mutant injected-bug campaign for those checkers (1126 s with `scripts/sva_mutants.py --jobs 7`; the target uses 4 jobs)
make clean             # remove build products; the tracked logs in sim/logs/ and build/reports/ stay
```

Synthesis isn't part of `make check` because it takes tens of minutes, and its largest point needs 9.4 GiB of memory:

```bash
make synth             # every unit at its default configuration (24 min of synthesis), then the gate-level re-runs
make synth-sweep       # the 11-point capacity / associativity sweep (56 min)
make synth-l3-default  # attempt the default 256 KiB L3; records an out-of-memory result (4 min)
make synth-abc-compare # the L1-D through ABC's full script, to compare with the fast one (9 min)
make synth-gatesim     # the four Tier-1 tests that use only ports, run on the synthesized netlists (needs make synth first)
make synth-stuckat     # tie every cell output of the arbiter and adapter netlists to 0 and 1 and run their tests (needs make synth first)
make synth-selftest-deep  # break each of the flow's checks in turn in a copy; the self-test must notice every time (2 min)
make synth-timing      # timing-driven mapping of the default configuration and four 8 KiB points (49 min of synthesis)
make sta               # OpenSTA on those netlists and four raw ones: minimum period, critical path, hold, power (94 min; needs make synth and make synth-timing)
make sta-sensitivity   # how the minimum period moves with the boundary delays, on four cheap points (12 min)
make sta-selftest-deep # break the timing flow in about sixty ways, one per copy; its self-test must notice each (3 min)
make sta-selftest      # the timing flow's known answers, the constants its SDC applies, each class of path and each refused case (part of make check, about 10 s)
```

A test passes only if its simulation exits cleanly, prints no `FAIL` line and prints at least one `PASS`. Each run's full output goes
to `sim/logs/<name>.log`. To add a testbench, add one `$(call register,<name>,<sources>)` line to the Makefile's registry (D-022).

## Synthesis results (Sky130HD, Yosys 0.33)

These come from `make synth` and `make synth-sweep`, and everything, including cell counts, flip-flop counts, wall time and peak
memory, is in [`build/reports/summary.md`](build/reports/summary.md). Area is Yosys's `stat -liberty` cell area of each unit mapped on
its own at the typical corner.

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

How to read these numbers:

- **There are no memory macros in this flow, so every stored bit is a flip-flop plus multiplexing.** The flip-flop count is the
  number of stored bits plus 35 to 856 control flip-flops at every cache point, which shows the arrays are intact, and flip-flops are
  only 37 to 49% of the area. The rest is the write-enable and read multiplexing around them. A design built on SRAM macros would look
  different, and I don't claim any figure for one.
- Area follows capacity: L2 is 3,829,883, 7,608,102 and 15,047,108 um^2 at 8, 16 and 32 KiB. Associativity costs little: L2 at 32 KiB
  is 14,997,923, 15,047,108 and 15,071,885 um^2 at 2, 4 and 8 ways.
- The cost of the flow itself is part of the result. The default L2 takes just under ten minutes and 9 GiB, and for both L2 and L3 the
  peak memory doubles with each doubling of capacity (2.3, 4.5 and 9.0 GiB at 8, 16 and 32 KiB).
- Not synthesised: the default L3 (above) and the integrated top, which is wiring only. I don't claim an area for the whole hierarchy.
- Timing is in the next section. Place and route is **NOT YET MEASURED** (Phase 9).
- The four unit testbenches that only use ports (`reset_sync`, L1-I, the adapter, the arbiter) also pass on the synthesised netlists,
  with the same testbench files and the same numbers of checks (4, 4, 41 and 45). The L1-I's has only 4 checks on its 162,596 cells,
  so that's thin evidence for it. The other four units (L1-D, L2, L3, the AXI4 engine) have testbenches that read internal state and
  have **no gate-level evidence**.

## Timing results (OpenSTA 2.7.0, Sky130HD typical corner)

These come from `make synth-timing` and `make sta`, and everything, including the classes of path, hold, power and the reset
network, is in [`build/reports/timing_summary.md`](build/reports/timing_summary.md). Each unit is mapped for delay (fan-out buffering
and sizing) and then analysed alone on one ideal clock, with a 0.35 ns input delay and a 0.15 ns output delay
(`constraints/mlc.sdc`).

| Unit | Min period (ns) | Fmax bound (MHz) | Limiting path | Hold slack (ns) |
|---|---|---|---|---|
| Reset synchroniser | 0.638 | 1,567 | register to output | 0.331 |
| L1 to L2 arbiter | 1.859 | 538 | register to output, 4 cells | 0.517 |
| L2-L3 adapter | 1.446 | 692 | input to output, 3 cells | 0.553 |
| AXI4 fill engine | 2.495 | 401 | register to register, 7 cells | 0.481 |
| L1-I, 4 KiB | 4.171 | 240 | register to output, 16 cells | 0.431 |
| L1-D, 4 KiB | 5.929 | 169 | input to register, 23 cells | 0.427 |
| L2, 32 KiB 4-way | 9.028 | 111 | input to register, 34 cells | 0.416 |
| L3, **32 KiB** 8-way (not the default L3) | 8.274 | 121 | input to register, 32 cells | 0.418 |

- **Every figure is an upper bound on frequency**, not what a built chip would run at, because the clock is ideal and there are no
  wires. Each unit is analysed alone, so a path that crosses units (an L1's request through the arbiter into L2) isn't analysed, and I
  don't claim a frequency for the whole.
- **Without buffering the numbers mean nothing.** The unbuffered Phase 7 netlist of the L1-I needs 51.5 ns, because two minimum-size
  gates drive fan-outs of 511 and 261; mapped for delay it needs 4.17 ns. The arbiter goes from 7.00 to 1.86 ns.
- **Fan-out buffers are about half of the L2 and L3 limiting paths**: 17 buffers take 4.5 of 9.0 ns in the L2 and 4.4 of 8.3 ns in the
  L3 (runs of 12, 3 and 2 buffers, and of 10, 3 and 4; the first run alone is 3.0 and 2.8 ns). The buffering is the mapping tool's,
  not a model of what place and route would build, so those two figures are pessimistic there and optimistic about wires. What a
  better tree would give is **NOT YET MEASURED**.
- **The prediction that the L3's 8-way compare is the longest hit path turned out wrong** (`docs/03_microarchitecture.md` section 5,
  D-042). I take the hit path as the worst path from a request input to a response output (`req2resp`). At 8 KiB it is 4.29 ns for the
  direct-mapped L1-D, 7.17 for the 4-way L2, 6.04 for the 4-way L3 and 6.32 for the 8-way L3. So the direct-mapped L1 is the fastest,
  as predicted, but the L2 is the slowest. Going from 4 to 8 ways costs the L3 0.28 ns (4.6%) on that path and 0.17 ns (2.4%) on the
  limiting path, with half the sets. The L2 and L3 also differ in line size and write granularity, and this phase didn't separate
  those from the effect of capacity.
- The reset net (a fan-out of up to 1,796) isn't buffered by this flow. Every path that starts at a reset port is a false path in the
  figures above, and the port has an ideal slew there; the net's unbuffered period is recorded separately for P&R.
- The power in the reports is OpenSTA's static estimate at its default switching activity, not a design estimate (D-041).

## Bound assertions, cover points and the injected-bug campaign (portfolio addition, rev 3)

This added a checking layer, not new RTL. `verif/mlc_checkers.sv` holds assertions (`a_*`), cover points (`c_*`) and procedural
scoreboards (`sb_*`), and `verif/mlc_binds.sv` binds them into the two L1 controllers, the L2 / L3 controller, the arbiter, the PLRU
tree, the AXI4 fill engine and the width adapter. The contracts they check come from `docs/04_interfaces.md` (PF-01, FR-05, the posted
writes of D-021, the line-aligned downstream addresses of D-025, the arbiter of D-033). Every conditional assertion gets an automatic
cover of its antecedent (`scripts/gen_vacuity.py`), so an assertion that only passed because its precondition never happened gets
reported. It needs Verilator 5.052 built from source (`VERILATOR_5052`), because the system 5.020 has no sequence delays. The results:

| Item | Result | Evidence |
|---|---|---|
| Checkers | **106** labelled assertions (103 concurrent, 3 procedural), **59** cover points | `results/sva/summary.txt` |
| Unmodified RTL | 12 testbenches pass, **no assertion fires** (`tb_l3` cannot be built by Verilator 5.052, an internal fault; `tb_reset_sync` has no module to bind to; L3 is the same RTL module as L2 and is covered through `tb_l2` and `tb_l2_l3_chain`) | `results/sva/runs.txt` |
| Vacuity | all **85** conditional assertions had their antecedent reached, **59 of 59** cover points hit | `results/sva/vacuity.txt`, `cover_bins.txt` |
| Injected bugs | **106 mutants** (23 from `scripts/mutate_top.py`, 31 aimed at interface contracts, 52 aimed at the assertions that nothing had made fire): **106 caught**, 96 by a testbench check, **10 only by an assertion**, 0 survived | `results/sva/mutants.txt` |
| Can each assertion fail? | **105 of 106** fired in at least one mutant run; `a_victim_range` cannot be violated by any edit (the victim index is a `$clog2(WAYS)`-bit value and `WAYS` must be a power of two) and is listed with that reason | `results/sva/mutants.txt`, `verif/sva_unviolable.txt` |

Besides catching bugs, the campaign found two stimulus gaps in the Tier-1 testbenches, and both are closed now. (1) A mutant that made
the arbiter tell a requester "accepted" while a read was outstanding survived, because the L2 model in `tb_arbiter` is never ready
then. The testbench now has a phase with an L2 that claims to be ready the whole time. (2) A mutant that made the AXI engine's RREADY
wait for RVALID couldn't be told apart from the correct design, because the memory model always answers the first beat at once. The
model now has a switch (`first_gap_en`), and `tb_axi4_fill_engine` reads a line whose first beat is four cycles late.

What this **doesn't** show: the assertions are only checked in simulation (no formal proof), the stimulus is the testbenches' own
(directed, apart from the system test's constrained-random load/store mix with one fixed seed, and no UVM-style functional coverage),
and the run uses the repository's own testbenches and parameters, so a bug that needs a stimulus none of them produces isn't covered.
Run times (measured with `--jobs 7` on 8 cores in the review re-run, `_evidence/rev3_review/timing.txt`; the make targets use the scripts' default of 4 jobs): the checker baseline 53 s from a cold start and 5 s once its simulator models are built, the campaign 1126 s (19 minutes).

## Verification by test level

- **Tier 1, module-level tests** (`sim/`): plain, class-free Verilog, directed, one testbench per **standalone** unit (L1-I, L1-D, L2,
  L3, the adapter, the AXI4 fill engine, the PLRU tree, the L1 arbiter). They run on Icarus in this repository through `make sim` and
  cover module-level correctness. On top of that there are three narrow **boundary-contract** tests (D-030, D-033) that join real
  modules at one boundary: L1 to L2, both L1 controllers to L2 through the arbiter, and L2 to adapter to L3 to the AXI4 fill engine. I
  added those because both D-021 bugs lived on a boundary, where no single-module test could see them. In the original project the
  integrated `mlc_cache_top` only got an elaboration check (`make top` and a block in `make lint`), which checks the wiring against
  structural rules (every port connected and named for its signal, one driver per signal, only wires, constants and instances in the
  top, no loops across units) and says nothing about behaviour. The portfolio copy's system test (`tb_mlc_top`) now exercises its
  behaviour for data integrity.
- **Tier 2, UVM environment** (`tb_uvm/`): a full IEEE 1800.2 UVM environment (transaction, sequence, sequencer, driver, monitor, agent,
  scoreboard, env, test, config, matching the structure of this portfolio's `APB_Design_and_Verification`) whose DUT is the **fully
  integrated** `mlc_cache_top`, with constrained-random sequences and functional coverage. It was planned as the only functional
  verification of the integrated hierarchy. **It needs an external, class-capable simulator** (VCS, Questa or Xcelium) that isn't
  installed here: compiling `APB_Design_and_Verification` here fails straight away with `uvm_macros.svh not found`, and Icarus 12 has no
  SystemVerilog class support anyway. `tb_uvm/README.md` gives the exact external command. Its pass/fail result and coverage numbers,
  including those for the integrated hierarchy as a whole, stay labelled **NOT YET RUN (external simulator required)** until it has
  been run externally and the log is checked in.

D-013 in `docs/engineering_log.md` has the full reasoning, including the direct evidence.

## Toolchain (verified on this machine)

| Tool | Status | Use |
|---|---|---|
| Icarus Verilog 12.0 | installed | Tier-1 smoke-test simulator |
| Yosys 0.33 | installed | Synthesis, target Sky130HD (`yosys -c` runs `scripts/synth.tcl`) |
| OpenSTA 2.7.0 | installed, used from Phase 8 | Static timing analysis (`sta`) |
| OpenROAD v2.0-25346 | **installed, verified runnable** | Place and route, target Sky130HD |
| Python 3.13 | installed | `make top` (`scripts/check_top.py`), the synthesis driver and summary, the PLRU table generator |
| Sky130HD liberty | **vendored** in `sky130hd/` | Synthesis; the LEF files are added with place and route (Phase 9) |
| Verilator 5.052, built from source | installed (portfolio addition) | `make sva` and `make sva-mutants`, the bound checkers |
| Class-capable SV simulator (VCS/Questa/Xcelium) + UVM library | **not installed** | Required only for `tb_uvm/`, supplied externally by the user |

## Reproducing the numbers in this README

- **Test counts and pass/fail verdicts:** `make check` (about three minutes); `make sim` regenerates `sim/logs/*.log`.
- **Synthesis figures:** `make synth` and `make synth-sweep` rewrite `build/reports/<point>/{stat,checks,run}.txt` and `summary.md`.
  `stat.txt` is Yosys's own report, `checks.txt` lists the assertions that passed, and `run.txt` records the command's outcome, wall
  time and peak memory. Area and cell counts reproduce exactly. Wall time and memory depend on the machine; the figures here are from a
  15 GiB machine that was also running other work.
- **The default L3's out-of-memory result:** `make synth-l3-default`. It depends on the machine and on the 12,000,000 KiB cap in
  `scripts/synth_run.py`.
- **Timing figures:** `make synth-timing` then `make sta` rewrite `build/reports/<point>/{timing,power,reset,sta}.txt` and
  `timing_summary.md`. The minimum periods were identical on every repeated run (the mapping and OpenSTA are deterministic), while wall
  time and memory depend on the machine.
- **Bound assertions and their campaign:** `make sva` and `make sva-mutants` rewrite `results/sva/`.
- **Place and route, and the UVM tier:** nothing yet. The command that will produce each of those numbers is specified in the phase
  table in `docs/00_project_plan.md`, so each claim can be checked as soon as it exists, following this project's `NOT YET MEASURED`
  policy.

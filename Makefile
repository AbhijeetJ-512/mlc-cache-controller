# Makefile - build, test and check entry points for mlc_cache_controller.
#
#   make               this help
#   make check         everything: parameter guards, every Tier-1 test, the top check, Yosys lint.
#                      Exits non-zero if anything fails.
#   make sim           every Tier-1 testbench (Icarus), one summary line each
#   make test-<name>   one testbench, e.g. `make test-tb_l3`   (V=1 prints its full output)
#   make list          list the testbenches
#   make elab          bad parameter sets must be rejected at elaboration, good ones accepted
#   make lint          Yosys elaboration check: hierarchy, zero latches and tristates, no synthesis
#   make top           the integrated top elaborates under Icarus with no warnings and is structural only
#   make synth-selftest  the synthesis flow's checks reject a latch, a tri-state, a multiply-driven net, a loop, a new warning
#   make synth         synthesise every unit at its default configuration (Yosys, Sky130HD); minutes to an hour
#   make synth-gatesim the Tier-1 testbenches that only use ports, run unchanged on the synthesised netlists (after make synth)
#   make synth-sweep   the capacity / associativity sweep; about an hour
#   make synth-l3-default   attempt the default 256 KiB L3; expected to run out of memory on a 15 GiB machine
#   make synth-abc-compare  L1-D through ABC's full script, to compare with the default fast script
#   make synth-summary rebuild build/reports/summary.md from the reports
#   make clean         remove build products (the tracked logs in sim/logs/ and build/reports/ are kept)
#
# Adding a testbench: add one `$(call register,<name>,<sources>)` line to the registry below,
# package first. Every file uses fully-qualified mlc_pkg:: names, which both Icarus 12 and
# Yosys 0.33 resolve only if the package has already been read (D-016).
#
# Later phases add: make sta, pnr, uvm, all, summary, view - each once its own scripts
# exist (docs/00_project_plan.md).

IVERILOG ?= iverilog
VVP      ?= vvp
YOSYS    ?= yosys
PYTHON   ?= python3
V        ?= 0
SYNTH    := $(PYTHON) scripts/synth_run.py

SIM_DIR := sim
LOG_DIR := sim/logs
PKG     := rtl/common/mlc_pkg.sv

# ---- test registry: one line per testbench, run in this order ---------------------------------
TESTS :=
define register_test
TESTS += $(1)
SRC_$(1) := $(2)
endef
register = $(eval $(call register_test,$(1),$(2)))

$(call register,tb_reset_sync,sim/tb_reset_sync.sv rtl/common/reset_sync.sv)
$(call register,tb_l1_dcache,$(PKG) sim/tb_l1_dcache.sv sim/l1_downstream_stub.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_dcache_ctrl.sv)
$(call register,tb_l1_icache,$(PKG) sim/tb_l1_icache.sv sim/l1_downstream_stub.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_icache_ctrl.sv)
$(call register,tb_plru,sim/tb_plru.sv rtl/replace/plru_tree.sv)
$(call register,tb_plru_ways,sim/tb_plru_ways.sv rtl/replace/plru_tree.sv)
$(call register,tb_l2,$(PKG) sim/tb_l2.sv sim/l3_stub.sv rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv)
$(call register,tb_adapter,$(PKG) sim/tb_adapter.sv rtl/adapter/l2_l3_width_adapter.sv)
$(call register,tb_axi4_fill_engine,$(PKG) sim/tb_axi4_fill_engine.sv sim/axi_mem_model.sv rtl/mem_if/axi4_fill_engine.sv)
$(call register,tb_l3,$(PKG) sim/tb_l3.sv sim/axi_mem_model.sv rtl/mem_if/axi4_fill_engine.sv rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv rtl/l3/l3_cache_ctrl.sv)
$(call register,tb_arbiter,$(PKG) sim/tb_arbiter.sv rtl/arbiter/l1_l2_arbiter.sv)
# Boundary-contract tests (D-030): real modules joined at one boundary. Not tests of the integrated hierarchy.
$(call register,tb_l1_l2,$(PKG) sim/tb_l1_l2.sv sim/l3_stub.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_dcache_ctrl.sv rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv)
$(call register,tb_l1_pair_l2,$(PKG) sim/tb_l1_pair_l2.sv sim/l3_stub.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_icache_ctrl.sv rtl/l1/l1_dcache_ctrl.sv rtl/arbiter/l1_l2_arbiter.sv rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv)
$(call register,tb_l2_l3_chain,$(PKG) sim/tb_l2_l3_chain.sv sim/axi_mem_model.sv rtl/mem_if/axi4_fill_engine.sv rtl/adapter/l2_l3_width_adapter.sv rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv rtl/l3/l3_cache_ctrl.sv)

# Everything mlc_cache_top instantiates, package first (D-016); used by `make top`.
TOP_SRC := $(PKG) rtl/common/reset_sync.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_icache_ctrl.sv rtl/l1/l1_dcache_ctrl.sv \
           rtl/arbiter/l1_l2_arbiter.sv rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv rtl/adapter/l2_l3_width_adapter.sv \
           rtl/l3/l3_cache_ctrl.sv rtl/mem_if/axi4_fill_engine.sv rtl/top/mlc_cache_top.sv

SIM_BINS     := $(addprefix $(SIM_DIR)/,$(TESTS))
TEST_TARGETS := $(addprefix test-,$(TESTS))

# ---- parameter-guard cases (sim/param_guard_cases.sv) -----------------------------------------
# good_* modules must be accepted by both tools, bad_* rejected by the guard itself. A bad case is
# written name:words, where the words (~ standing for a space) must appear in the $fatal message
# Icarus prints, so a case cannot be rejected by a different guard than the one it is for. Yosys's
# error does not name the guard, so under Yosys only the rejection itself can be checked. The task
# that adds a design unit appends its sources and cases below.
ELAB_SRC       := $(PKG) rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv sim/param_guard_cases.sv
ELAB_GOOD      := good_l2 good_l2_2way
ELAB_BAD       := bad_l2_ways_3:powers~of~two bad_l2_capacity:multiple~of bad_l2_line_not_pow2:powers~of~two \
                  bad_l2_wr_not_pow2:powers~of~two bad_l2_sets_not_pow2:a~power~of~two
ELAB_SRC       += rtl/mem_if/axi4_fill_engine.sv
ELAB_GOOD      += good_engine good_engine64
ELAB_BAD       += bad_engine_width:must~divide bad_engine_beats:1..256~beats bad_engine_line_4k:4~KB bad_engine_line_pow2:must~be~a~power~of~two
ELAB_SRC       += rtl/adapter/l2_l3_width_adapter.sv
ELAB_GOOD      += good_adapter
ELAB_BAD       += bad_adapter_ratio:l2_l3_width_adapter
ELAB_SRC       += rtl/l3/l3_cache_ctrl.sv
ELAB_GOOD      += good_l3
ELAB_BAD       += bad_l3_line_ratio:l3_cache_ctrl
# Degenerate sets whose width arithmetic collapses to zero-width vectors: Icarus refuses to compile
# them before the guard's initial block can run, so for these an Icarus compile error also counts as
# a rejection. Yosys must still hit the guard itself.
ELAB_BAD_EARLY := bad_l2_ways_1 bad_l2_wr_too_wide

.DEFAULT_GOAL := help
.SECONDEXPANSION:

.PHONY: help
help:
	@echo "make check        parameter guards + every Tier-1 test + Yosys lint (non-zero on any failure)"
	@echo "make sim          every Tier-1 testbench (Icarus), one summary line each"
	@echo "make test-<name>  one testbench, e.g. make test-tb_l3   (V=1 shows its full output)"
	@echo "make list         list the testbenches"
	@echo "make elab         bad parameter sets are rejected at elaboration, good ones accepted"
	@echo "make lint         Yosys elaboration check: hierarchy, zero latches/tristates (no synthesis)"
	@echo "make top          the integrated top elaborates cleanly and is structural only (no simulation)"
	@echo "make synth        Yosys + Sky130HD, every unit at its default configuration (reports in build/reports/)"
	@echo "make synth-sweep  the capacity / associativity sweep;  make synth-selftest  the flow's own checks can fail"
	@echo "make clean        remove build products (keeps the tracked logs in sim/logs/)"

.PHONY: list
list:
	@for t in $(TESTS); do echo $$t; done

# One compiled binary per testbench.
$(SIM_BINS): $(SIM_DIR)/%: $$(SRC_$$*)
	@$(IVERILOG) -g2012 -s $* -o $@ $^

# Run one testbench, keep its full output in sim/logs/<name>.log (tracked evidence), and print a
# one-line verdict. A run passes only if vvp exits 0, no FAIL, ERROR ($error), FATAL or AXI PROTO
# line was printed, and at least one check passed (so a testbench that silently does nothing cannot
# pass).
.PHONY: $(TEST_TARGETS)
$(TEST_TARGETS): test-%: $(SIM_DIR)/%
	@mkdir -p $(LOG_DIR)
	@$(VVP) $(SIM_DIR)/$* > $(LOG_DIR)/$*.log 2>&1; rc=$$?; \
	pass=$$(grep -c '^PASS' $(LOG_DIR)/$*.log); fail=$$(grep -c -E '^(FAIL|ERROR|FATAL|AXI PROTO)' $(LOG_DIR)/$*.log); \
	if [ "$(V)" = "1" ]; then cat $(LOG_DIR)/$*.log; fi; \
	if [ $$rc -eq 0 ] && [ $$fail -eq 0 ] && [ $$pass -gt 0 ]; then \
	  printf '  %-24s PASS  (%s checks)\n' $* $$pass; \
	else \
	  printf '  %-24s FAIL  (%s passed, %s failed, exit %s)\n' $* $$pass $$fail $$rc; \
	  grep -E '^(FAIL|ERROR|FATAL|AXI PROTO)' $(LOG_DIR)/$*.log | head -20 | sed 's/^/      /'; \
	  echo "      full log: $(LOG_DIR)/$*.log"; exit 1; \
	fi

.PHONY: sim test
sim:
	@echo "Tier-1 tests (Icarus):"; ok=0; bad=0; checks=0; \
	for t in $(TESTS); do \
	  if out=$$($(MAKE) --no-print-directory test-$$t 2>&1); then \
	    ok=$$((ok+1)); n=$$(echo "$$out" | sed -n 's/.*(\([0-9][0-9]*\) checks).*/\1/p' | head -1); checks=$$((checks+$${n:-0})); \
	  else bad=$$((bad+1)); fi; \
	  printf '%s\n' "$$out"; \
	done; \
	echo "sim: $$ok of $(words $(TESTS)) testbenches passed, $$bad failed ($$checks checks passed in total)"; \
	[ $$bad -eq 0 ]
test: sim

.PHONY: elab
elab:
	@echo "Parameter guards (Icarus and Yosys must agree; under Icarus a rejection must come from the named guard):"; bad=0; \
	for e in $(ELAB_GOOD) $(ELAB_BAD) $(ELAB_BAD_EARLY); do \
	  m=$${e%%:*}; why=; want=accept; \
	  case "$$e" in *:*) want=reject; why=$$(echo "$${e#*:}" | tr '~' ' ');; esac; \
	  case " $(ELAB_BAD_EARLY) " in *" $$m "*) want=reject;; esac; \
	  if ! $(IVERILOG) -g2012 -s $$m -o $(SIM_DIR)/elab_$$m $(ELAB_SRC) >/dev/null 2>&1; then got_i=compile-error; \
	  elif iout=$$($(VVP) $(SIM_DIR)/elab_$$m 2>&1); then got_i=accept; \
	  elif echo "$$iout" | grep -q "FATAL:.*$$why"; then got_i=reject; \
	  else got_i=other-failure; fi; \
	  case " $(ELAB_BAD_EARLY) " in *" $$m "*) if [ "$$got_i" = compile-error ]; then got_i=reject; fi;; esac; \
	  if yout=$$($(YOSYS) -q -p "read_verilog -sv $(ELAB_SRC); hierarchy -top $$m" 2>&1); then got_y=accept; \
	  elif echo "$$yout" | grep -q 'resolve task name'; then got_y=reject; \
	  else got_y=other-failure; fi; \
	  if [ "$$got_i" = "$$want" ] && [ "$$got_y" = "$$want" ]; then \
	    printf '  %-24s %s\n' $$m $$want; \
	  else \
	    printf '  %-24s FAIL: expected %s, Icarus %s, Yosys %s\n' $$m $$want $$got_i $$got_y; bad=$$((bad+1)); \
	  fi; \
	done; \
	echo "elab: $$bad failed"; [ $$bad -eq 0 ]

.PHONY: lint
lint:
	@$(YOSYS) -q scripts/lint.ys && echo "lint: clean (hierarchies elaborate, zero latches and tristates, L2 and L3 arrays inferred as memories)"

.PHONY: top
top:
	@$(PYTHON) scripts/check_top.py
	@out=$$($(IVERILOG) -g2012 -Wall -s mlc_cache_top -o /dev/null $(TOP_SRC) 2>&1); \
	if [ -n "$$out" ]; then echo "$$out"; echo "top: Icarus (-Wall) reports problems elaborating mlc_cache_top"; exit 1; fi; \
	echo "top: mlc_cache_top elaborates under Icarus -Wall with no warnings (widths and ports checked, nothing simulated)"

# ---- Phase 7: synthesis to Sky130HD (D-037). Not part of `check` except the self-test: the runs take minutes each. ----
.PHONY: synth synth-sweep synth-l3-default synth-abc-compare synth-selftest synth-summary synth-gatesim
synth:
	@rc=0; for p in $$($(SYNTH) --group default); do $(SYNTH) $$p || rc=1; done; \
	$(MAKE) --no-print-directory synth-gatesim || rc=1; \
	$(MAKE) --no-print-directory synth-summary >/dev/null; \
	if [ $$rc -eq 0 ]; then echo "synth: every default-configuration unit passed; see build/reports/summary.md"; else echo "synth: FAILED"; fi; exit $$rc

synth-sweep:
	@rc=0; for p in $$($(SYNTH) --group sweep); do $(SYNTH) $$p || rc=1; done; \
	$(MAKE) --no-print-directory synth-summary >/dev/null; \
	if [ $$rc -eq 0 ]; then echo "synth-sweep: every sweep point passed; see build/reports/summary.md"; else echo "synth-sweep: FAILED"; fi; exit $$rc

synth-l3-default:
	@$(SYNTH) l3_default; rc=$$?; $(MAKE) --no-print-directory synth-summary >/dev/null; exit $$rc

synth-abc-compare:
	@rc=0; for p in l1_dcache l1_dcache_abcdefault; do $(SYNTH) $$p || rc=1; done; \
	$(MAKE) --no-print-directory synth-summary >/dev/null; exit $$rc

synth-gatesim:
	@rc=0; for p in $$($(SYNTH) --gatesim-points); do $(SYNTH) --gatesim $$p || rc=1; done; exit $$rc

synth-selftest:
	@$(SYNTH) --selftest && echo "synth-selftest: the flow rejects a latch, a tri-state, a multiply-driven net, a loop and an unlisted warning, and accepts a clean module"

synth-summary:
	@$(PYTHON) scripts/synth_summary.py

.PHONY: check
check:
	@rc=0; \
	echo "== elab ==";  $(MAKE) --no-print-directory elab || rc=1; \
	echo "== top ==";   $(MAKE) --no-print-directory top  || rc=1; \
	echo "== sim ==";   $(MAKE) --no-print-directory sim  || rc=1; \
	echo "== lint ==";  $(MAKE) --no-print-directory lint || rc=1; \
	echo "== synth-selftest =="; $(MAKE) --no-print-directory synth-selftest || rc=1; \
	if [ $$rc -eq 0 ]; then echo "check: PASSED"; else echo "check: FAILED"; fi; exit $$rc

# sim/logs/*.log and build/reports/ are git-tracked evidence, overwritten by every run - `clean` must not delete
# them, or the working tree is left dirty after a clean. build/work/ (logs, scratch package copies) is not tracked.
.PHONY: clean
clean:
	@rm -f $(SIM_BINS) $(SIM_DIR)/elab_* $(SIM_DIR)/*.vcd
	@rm -rf build/work

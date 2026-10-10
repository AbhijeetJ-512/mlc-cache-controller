# Makefile - build, test and check entry points for mlc_cache_controller.
#
#   make               this help
#   make check         everything: parameter guards, every Tier-1 test, Yosys lint.
#                      Exits non-zero if anything fails.
#   make sim           every Tier-1 testbench (Icarus), one summary line each
#   make test-<name>   one testbench, e.g. `make test-tb_l3`   (V=1 prints its full output)
#   make list          list the testbenches
#   make elab          bad parameter sets must be rejected at elaboration, good ones accepted
#   make lint          Yosys elaboration check: hierarchy, zero latches and tristates, no synthesis
#   make clean         remove build products (the tracked logs in sim/logs/ are kept)
#
# Adding a testbench: add one `$(call register,<name>,<sources>)` line to the registry below,
# package first. Every file uses fully-qualified mlc_pkg:: names, which both Icarus 12 and
# Yosys 0.33 resolve only if the package has already been read (D-016).
#
# Later phases add: make synth, sta, pnr, uvm, all, summary, view - each once its own scripts
# exist (docs/00_project_plan.md).

IVERILOG ?= iverilog
VVP      ?= vvp
YOSYS    ?= yosys
V        ?= 0

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

SIM_BINS     := $(addprefix $(SIM_DIR)/,$(TESTS))
TEST_TARGETS := $(addprefix test-,$(TESTS))

# ---- parameter-guard cases (sim/param_guard_cases.sv) -----------------------------------------
# good_* modules must be accepted by both tools, bad_* rejected by the guard itself. The task that
# adds a design unit appends its sources and cases below.
ELAB_SRC       := $(PKG) rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv sim/param_guard_cases.sv
ELAB_GOOD      := good_l2 good_l2_2way
ELAB_BAD       := bad_l2_ways_3 bad_l2_capacity bad_l2_line_not_pow2 bad_l2_wr_not_pow2 bad_l2_sets_not_pow2
ELAB_SRC       += rtl/mem_if/axi4_fill_engine.sv
ELAB_GOOD      += good_engine good_engine64
ELAB_BAD       += bad_engine_width bad_engine_beats bad_engine_line_4k
ELAB_SRC       += rtl/adapter/l2_l3_width_adapter.sv
ELAB_GOOD      += good_adapter
ELAB_BAD       += bad_adapter_ratio
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
	@echo "make clean        remove build products (keeps the tracked logs in sim/logs/)"

.PHONY: list
list:
	@for t in $(TESTS); do echo $$t; done

# One compiled binary per testbench.
$(SIM_BINS): $(SIM_DIR)/%: $$(SRC_$$*)
	@$(IVERILOG) -g2012 -s $* -o $@ $^

# Run one testbench, keep its full output in sim/logs/<name>.log (tracked evidence), and print a
# one-line verdict. A run passes only if vvp exits 0, no FAIL line was printed, and at least one
# check passed (so a testbench that silently does nothing cannot pass).
.PHONY: $(TEST_TARGETS)
$(TEST_TARGETS): test-%: $(SIM_DIR)/%
	@mkdir -p $(LOG_DIR)
	@$(VVP) $(SIM_DIR)/$* > $(LOG_DIR)/$*.log 2>&1; rc=$$?; \
	pass=$$(grep -c '^PASS' $(LOG_DIR)/$*.log); fail=$$(grep -c '^FAIL' $(LOG_DIR)/$*.log); \
	if [ "$(V)" = "1" ]; then cat $(LOG_DIR)/$*.log; fi; \
	if [ $$rc -eq 0 ] && [ $$fail -eq 0 ] && [ $$pass -gt 0 ]; then \
	  printf '  %-24s PASS  (%s checks)\n' $* $$pass; \
	else \
	  printf '  %-24s FAIL  (%s passed, %s failed, exit %s)\n' $* $$pass $$fail $$rc; \
	  grep -E '^(FAIL|AXI PROTO|FATAL)' $(LOG_DIR)/$*.log | head -20 | sed 's/^/      /'; \
	  echo "      full log: $(LOG_DIR)/$*.log"; exit 1; \
	fi

.PHONY: sim test
sim:
	@echo "Tier-1 tests (Icarus):"; ok=0; bad=0; \
	for t in $(TESTS); do \
	  if $(MAKE) --no-print-directory test-$$t; then ok=$$((ok+1)); else bad=$$((bad+1)); fi; \
	done; \
	checks=$$(cat $(addprefix $(LOG_DIR)/,$(addsuffix .log,$(TESTS))) 2>/dev/null | grep -c '^PASS'); \
	echo "sim: $$ok of $(words $(TESTS)) testbenches passed, $$bad failed ($$checks checks passed in total)"; \
	[ $$bad -eq 0 ]
test: sim

.PHONY: elab
elab:
	@echo "Parameter guards (Icarus and Yosys must agree; a rejection must come from the guard itself):"; bad=0; \
	for m in $(ELAB_GOOD) $(ELAB_BAD) $(ELAB_BAD_EARLY); do \
	  want=accept; case " $(ELAB_BAD) $(ELAB_BAD_EARLY) " in *" $$m "*) want=reject;; esac; \
	  if ! $(IVERILOG) -g2012 -s $$m -o $(SIM_DIR)/elab_$$m $(ELAB_SRC) >/dev/null 2>&1; then got_i=compile-error; \
	  elif iout=$$($(VVP) $(SIM_DIR)/elab_$$m 2>&1); then got_i=accept; \
	  elif echo "$$iout" | grep -q 'FATAL:.*must'; then got_i=reject; \
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
	@$(YOSYS) -q scripts/lint.ys && echo "lint: clean (hierarchies elaborate, zero latches and tristates, cache arrays inferred as memories)"

.PHONY: check
check:
	@rc=0; \
	echo "== elab ==";  $(MAKE) --no-print-directory elab || rc=1; \
	echo "== sim ==";   $(MAKE) --no-print-directory sim  || rc=1; \
	echo "== lint ==";  $(MAKE) --no-print-directory lint || rc=1; \
	if [ $$rc -eq 0 ]; then echo "check: PASSED"; else echo "check: FAILED"; fi; exit $$rc

# sim/logs/*.log are git-tracked test evidence, overwritten by every run - `clean` must not delete
# them, or the working tree is left dirty after a clean.
.PHONY: clean
clean:
	@rm -f $(SIM_BINS) $(SIM_DIR)/elab_* $(SIM_DIR)/*.vcd

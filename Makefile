# Makefile - mlc_cache_controller build/verification entry points.
# Phase 1 provides: make sim (Tier-1 module-level smoke tests, Icarus).
# Later phases add: make lint, make synth, make sta, make pnr, make uvm,
# make all, make summary, make view - each only once its own scripts exist,
# per docs/00_project_plan.md's phase-by-phase Definition of Done.

IVERILOG ?= iverilog
VVP      ?= vvp

SIM_DIR := sim

TESTS := tb_reset_sync tb_l1_dcache tb_l1_icache

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "make sim   - run all Tier-1 module-level smoke tests (Icarus)"
	@echo "make clean - remove simulation build artefacts"

.PHONY: sim
sim: $(addprefix $(SIM_DIR)/,$(TESTS))
	@mkdir -p $(SIM_DIR)/logs && \
	bash -c 'set -o pipefail; \
	for t in $(TESTS); do \
		echo "=== $$t ==="; \
		$(VVP) $(SIM_DIR)/$$t | tee $(SIM_DIR)/logs/$$t.log || exit 1; \
	done'

$(SIM_DIR)/tb_reset_sync: sim/tb_reset_sync.sv rtl/common/reset_sync.sv
	$(IVERILOG) -g2012 -o $@ $^

# rtl/common/mlc_pkg.sv is listed first: Icarus Verilog 12 requires a package to be compiled
# before any file that does `import mlc_pkg::*;` at compilation-unit scope (see Task 2 report,
# Ruling 3) - listing it first here means $^ expands with the package ahead of its importers.
$(SIM_DIR)/tb_l1_dcache: rtl/common/mlc_pkg.sv sim/tb_l1_dcache.sv sim/l1_downstream_stub.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_dcache_ctrl.sv
	$(IVERILOG) -g2012 -o $@ $^

$(SIM_DIR)/tb_l1_icache: rtl/common/mlc_pkg.sv sim/tb_l1_icache.sv sim/l1_downstream_stub.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_icache_ctrl.sv
	$(IVERILOG) -g2012 -o $@ $^

.PHONY: clean
clean:
	@rm -f $(addprefix $(SIM_DIR)/,$(TESTS))
	@rm -f $(SIM_DIR)/*.vcd
	@rm -f $(SIM_DIR)/logs/*.log

# Makefile - mlc_cache_controller build/verification entry points.
# Phase 1 provides: make sim (Tier-1 module-level smoke tests, Icarus).
# Later phases add: make lint, make synth, make sta, make pnr, make uvm,
# make all, make summary, make view - each only once its own scripts exist,
# per docs/00_project_plan.md's phase-by-phase Definition of Done.

IVERILOG ?= iverilog
VVP      ?= vvp

SIM_DIR := sim

TESTS := tb_reset_sync

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "make sim   - run all Tier-1 module-level smoke tests (Icarus)"
	@echo "make clean - remove simulation build artefacts"

.PHONY: sim
sim: $(addprefix $(SIM_DIR)/,$(TESTS))
	@for t in $(TESTS); do \
		echo "=== $$t ==="; \
		$(VVP) $(SIM_DIR)/$$t || exit 1; \
	done

$(SIM_DIR)/tb_reset_sync: sim/tb_reset_sync.sv rtl/common/reset_sync.sv
	$(IVERILOG) -g2012 -o $@ $^

.PHONY: clean
clean:
	@rm -f $(addprefix $(SIM_DIR)/,$(TESTS))
	@rm -f $(SIM_DIR)/*.vcd

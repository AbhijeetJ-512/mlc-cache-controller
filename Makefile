# Makefile - mlc_cache_controller build/verification entry points.
# Phases 1-2 provide: make sim (Tier-1 module-level smoke tests, Icarus),
# make lint (Yosys elaboration check: hierarchy + zero-latch/tristate).
# Later phases add: make synth, make sta, make pnr, make uvm,
# make all, make summary, make view - each only once its own scripts exist,
# per docs/00_project_plan.md's phase-by-phase Definition of Done.

IVERILOG ?= iverilog
VVP      ?= vvp

SIM_DIR := sim

TESTS := tb_reset_sync tb_l1_dcache tb_l1_icache tb_plru tb_l2

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "make sim   - run all Tier-1 module-level smoke tests (Icarus)"
	@echo "make lint  - Yosys elaboration check: hierarchy + zero-latch/tristate (no synthesis)"
	@echo "make clean - remove simulation build artefacts (compiled binaries, VCDs; keeps tracked logs)"

.PHONY: lint
lint:
	yosys -q scripts/lint.ys

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

# rtl/common/mlc_pkg.sv is listed first: every other file uses fully-qualified mlc_pkg::<name>
# references (no `import` - Yosys 0.33 cannot parse it), and both Icarus 12 and Yosys 0.33 only
# resolve those if the package has already been read - see D-016 in docs/engineering_log.md.
$(SIM_DIR)/tb_l1_dcache: rtl/common/mlc_pkg.sv sim/tb_l1_dcache.sv sim/l1_downstream_stub.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_dcache_ctrl.sv
	$(IVERILOG) -g2012 -o $@ $^

$(SIM_DIR)/tb_l1_icache: rtl/common/mlc_pkg.sv sim/tb_l1_icache.sv sim/l1_downstream_stub.sv rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_icache_ctrl.sv
	$(IVERILOG) -g2012 -o $@ $^

$(SIM_DIR)/tb_plru: sim/tb_plru.sv rtl/replace/plru_tree.sv
	$(IVERILOG) -g2012 -o $@ $^

$(SIM_DIR)/tb_l2: rtl/common/mlc_pkg.sv sim/tb_l2.sv sim/l3_stub.sv rtl/replace/plru_tree.sv rtl/l2/l2_cache_ctrl.sv
	$(IVERILOG) -g2012 -o $@ $^

# sim/logs/*.log are git-tracked VR-04 evidence, overwritten by every `make sim` - `clean` must not
# delete them, or the working tree is left dirty after a clean.
.PHONY: clean
clean:
	@rm -f $(addprefix $(SIM_DIR)/,$(TESTS))
	@rm -f $(SIM_DIR)/*.vcd

#!/usr/bin/env bash
# run_replay.sh - check the explorer page's cycle model against the real RTL.
#
# For each recorded scenario in docs/validate/vec/*.vec this
#   1. compiles the real mlc_cache_top and sim/axi_mem_model.sv with Icarus Verilog (docs/validate/replay_tb.sv is the testbench),
#   2. drives the CPU-port inputs and the memory stall pattern recorded from the model into them,
#   3. compares 32 outputs and unit states per cycle with what the model predicted (docs/validate/compare.py).
# A last step corrupts one expected value and checks that the comparison notices. Run it from anywhere:  docs/validate/run_replay.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; V="$ROOT/docs/validate"; T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$ROOT"
iverilog -g2012 -s replay_tb -o "$T/replay.vvp" rtl/common/mlc_pkg.sv "$V/replay_tb.sv" sim/axi_mem_model.sv rtl/common/reset_sync.sv \
  rtl/l1/l1_cache_ctrl.sv rtl/l1/l1_icache_ctrl.sv rtl/l1/l1_dcache_ctrl.sv rtl/arbiter/l1_l2_arbiter.sv rtl/replace/plru_tree.sv \
  rtl/l2/l2_cache_ctrl.sv rtl/l3/l3_cache_ctrl.sv rtl/adapter/l2_l3_width_adapter.sv rtl/mem_if/axi4_fill_engine.sv rtl/top/mlc_cache_top.sv
fail=0; scen=0; cycles=0; values=0
for vec in "$V"/vec/*.vec; do
  name="$(basename "$vec" .vec)"; n=$(( $(wc -l < "$vec") - 1 ))
  vvp "$T/replay.vvp" +vec="$vec" +out="$T/$name.out" +n=$n > "$T/$name.log"
  if python3 "$V/compare.py" "$vec" "$T/$name.out" > "$T/$name.cmp"; then
    printf '  %-10s PASS  %s\n' "$name" "$(tail -1 "$T/$name.cmp")"
  else
    printf '  %-10s FAIL\n' "$name"; head -12 "$T/$name.cmp" | sed 's/^/      /'; fail=1
  fi
  scen=$((scen+1)); cycles=$((cycles+n)); values=$((values+n*32))
done
# the comparison must be able to fail: change one expected FSM state in a copy and run it again
python3 - "$V/vec/evl3.vec" "$T/bad.vec" <<'PY'
import sys
L = open(sys.argv[1]).read().splitlines(); f = L[100].split(); f[12 + 24] = format((int(f[12 + 24], 16) + 1) % 3, 'x'); L[100] = " ".join(f)
open(sys.argv[2], "w").write("\n".join(L) + "\n")
PY
if python3 "$V/compare.py" "$T/bad.vec" "$T/evl3.out" > /dev/null; then echo "  self-test  FAIL (a corrupted expectation was not detected)"; fail=1; else echo "  self-test  PASS (a corrupted expectation is detected)"; fi
# ... and change a CPU input: the real RTL must then diverge from the model's expectation (the data port is idle for 40 cycles in this copy)
python3 - "$V/vec/evl2.vec" "$T/alt.vec" <<'PY'
import sys
L = open(sys.argv[1]).read().splitlines()
for i in range(40, 80):
    f = L[i].split(); f[3] = '0'; L[i] = " ".join(f)
open(sys.argv[2], "w").write("\n".join(L) + "\n")
PY
vvp "$T/replay.vvp" +vec="$T/alt.vec" +out="$T/alt.out" +n=$(( $(wc -l < "$V/vec/evl2.vec") - 1 )) > /dev/null
if python3 "$V/compare.py" "$T/alt.vec" "$T/alt.out" > /dev/null; then echo "  self-test  FAIL (a changed CPU input was not detected)"; fail=1; else echo "  self-test  PASS (a changed CPU input is detected)"; fi
echo "$scen scenarios, $cycles cycles, $values values compared"
[ "$fail" -eq 0 ] && echo "replay: ALL MATCH" || { echo "replay: MISMATCH"; exit 1; }

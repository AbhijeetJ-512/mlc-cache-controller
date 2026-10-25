#!/usr/bin/env python3
"""mutate_top.py - injected-bug campaign for the system-level test (sim/tb_mlc_top.sv).

Each mutant is one source edit of the RTL, applied to a copy; the copy is compiled with Icarus and run through the full
system test. A mutant is KILLED if the test prints a FAIL / AXI PROTO line, times out or its watchdog fires; it SURVIVED if the
test still passes. Survivors are annotated: some are not data-visible by construction (replacement-policy quality, fairness,
performance), which is exactly what a data-integrity test cannot see.

usage: mutate_top.py [--jobs N] [--only M01,M05]   -> results/mutants_top.txt
"""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = ["rtl/common/mlc_pkg.sv", "rtl/common/reset_sync.sv", "rtl/l1/l1_cache_ctrl.sv", "rtl/l1/l1_icache_ctrl.sv",
       "rtl/l1/l1_dcache_ctrl.sv", "rtl/arbiter/l1_l2_arbiter.sv", "rtl/replace/plru_tree.sv", "rtl/l2/l2_cache_ctrl.sv",
       "rtl/l3/l3_cache_ctrl.sv", "rtl/adapter/l2_l3_width_adapter.sv", "rtl/mem_if/axi4_fill_engine.sv", "rtl/top/mlc_cache_top.sv"]
TB = ["sim/axi_mem_model.sv", "sim/tb_mlc_top.sv"]

L1, L2, AD, AR, EN = ("rtl/l1/l1_cache_ctrl.sv", "rtl/l2/l2_cache_ctrl.sv", "rtl/adapter/l2_l3_width_adapter.sv",
                      "rtl/arbiter/l1_l2_arbiter.sv", "rtl/mem_if/axi4_fill_engine.sv")
# id, file, old text (must occur exactly once), new text, description, expectation
MUTANTS = [
    ("M01", L1, "                data_array[req_index] <= hit_write_line_merged;", "                // data_array[req_index] <= hit_write_line_merged;", "L1: a store hit does not update the L1 data array", "killed"),
    ("M02", L1, "dn_req_addr = req_addr; dn_req_we = 1'b1;\n      dn_req_wdata = req_wdata; dn_req_wstrb = req_wstrb;", "dn_req_addr = req_addr; dn_req_we = 1'b1;\n      dn_req_wdata = req_wdata; dn_req_wstrb = '1;", "L1: the write-through forward of a store hit ignores the byte strobes", "killed"),
    ("M03", L1, "            if (miss_is_write) begin\n              wr_fwd_pending <= 1'b1;", "            if (1'b0) begin\n              wr_fwd_pending <= 1'b1;", "L1: a store miss is not forwarded to L2", "killed"),
    ("M04", L1, "    if (miss_is_write) begin\n      fill_line_merged[", "    if (1'b0) begin\n      fill_line_merged[", "L1: a store miss does not merge the store into the filled line", "killed"),
    ("M05", L1, "    else                       resp_rdata = req_line_rd[req_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W];", "    else                       resp_rdata = req_line_rd[(req_word_sel ^ 1)*mlc_pkg::DATA_W +: mlc_pkg::DATA_W];", "L1: a hit returns the neighbouring word", "killed"),
    ("M06", L2, "      dirty_array[req_index][hit_way] <= 1'b1;", "      dirty_array[req_index][hit_way] <= 1'b0;", "L2/L3: a store hit does not set the dirty bit", "killed"),
    ("M07", L2, "      dirty_array[miss_index][victim_way_latched] <= miss_is_write;", "      dirty_array[miss_index][victim_way_latched] <= 1'b0;", "L2/L3: a write-allocated line is not marked dirty", "killed"),
    ("M08", L2, "      dn_req_addr  = {victim_tag_latched, miss_index, {OFFSET_W{1'b0}}};", "      dn_req_addr  = {miss_tag, miss_index, {OFFSET_W{1'b0}}};", "L2/L3: a write-back goes to the address of the incoming line", "killed"),
    ("M09", L2, "      victim_line_latched <= data_array[miss_index][victim_way];", "      victim_line_latched <= data_array[miss_index][0];", "L2/L3: a write-back sends way 0's data instead of the victim's", "killed"),
    ("M10", L2, "      if (wstrb[b]) merge_wstrb[b*8 +: 8] = new_data[b*8 +: 8];", "      if (1'b1) merge_wstrb[b*8 +: 8] = new_data[b*8 +: 8];", "L2/L3: the byte-strobe merge ignores the strobes", "killed"),
    ("M11", L2, "    if (miss_is_write) begin\n      fill_line_merged[miss_slot", "    if (1'b0) begin\n      fill_line_merged[miss_slot", "L2/L3: a write-allocate miss drops the store", "killed"),
    ("M12", L2, "  assign commit_write_hit = hit_accept && req_we;", "  assign commit_write_hit = hit_accept && req_we && 1'b0;", "L2/L3: a store hit is not written", "killed"),
    ("M13", L2, "          if (dn_req_ready) state <= S_ALLOC_FILL;", "          state <= S_ALLOC_FILL;", "L2/L3: the eviction does not wait for the write-back to be accepted", "survives: equivalent in this integration (the downstream is always ready when L2 evicts: one requester, blocking misses); tb_l2 with a stalling stub kills it"),
    ("M14", L2, "      if (commit_fill) valid_array[miss_index][victim_way_latched] <= 1'b1;", "      if (1'b0) valid_array[miss_index][victim_way_latched] <= 1'b1;", "L2/L3: a filled line is never marked valid", "killed"),
    ("M15", L2, "  assign victim_way = (&set_valid) ? plru_victim : lowest_set(~set_valid);", "  assign victim_way = lowest_set(~set_valid);", "L2/L3: the PLRU tree is ignored, a full set always evicts way 0", "survives: replacement quality is not data-visible"),
    ("M16", AD, "  assign half = l2_req_addr[HALF_BIT];", "  assign half = ~l2_req_addr[HALF_BIT];", "adapter: the half-line select is inverted", "killed"),
    ("M17", AD, "  assign l3_req_wstrb  = '1;", "  assign l3_req_wstrb  = '0;", "adapter: write-backs to L3 carry no strobes", "killed"),
    ("M18", AR, "  assign resp_to = busy ? owner : sel;", "  assign resp_to = busy ? ~owner : sel;", "arbiter: a miss response goes to the other requester", "killed"),
    ("M19", AR, "    if (up0_req_valid && up1_req_valid) sel = ~last;", "    if (up0_req_valid && up1_req_valid) sel = 1'b0;", "arbiter: round-robin removed, L1-I wins every tie", "survives: fairness is not data-visible"),
    ("M20", EN, "  assign wstrb   = '1;", "  assign wstrb   = '0;", "AXI engine: write beats carry no strobes", "killed"),
    ("M21", EN, "  assign awaddr  = addr_q;", "  assign awaddr  = addr_q ^ 32'h40;", "AXI engine: write bursts go to the neighbouring line", "killed"),
    ("M22", EN, "  assign arlen   = AXLEN;", "  assign arlen   = AXLEN - 8'd1;", "AXI engine: read bursts are one beat short", "killed"),
    ("M23", EN, "  assign wlast   = wvalid && last_beat;", "  assign wlast   = wvalid && (beat_q == BEATS - 2);", "AXI engine: WLAST on the second-to-last beat", "killed"),
]


def run_one(m, work):
    mid, rel, old, new, desc, expect = m
    d = os.path.join(work, mid)
    os.makedirs(d, exist_ok=True)
    srcs = []
    for f in RTL + TB:
        dst = os.path.join(d, os.path.basename(f) if f not in RTL else f.replace("/", "_"))
        shutil.copy(os.path.join(ROOT, f), dst)
        if f == rel:
            t = open(dst).read()
            if t.count(old) != 1:
                return (mid, desc, expect, "INVALID", "edit text found %d times" % t.count(old))
            open(dst, "w").write(t.replace(old, new))
        srcs.append(dst)
    exe = os.path.join(d, "sim.vvp")
    r = subprocess.run(["iverilog", "-g2012", "-s", "tb_mlc_top", "-o", exe] + srcs, capture_output=True, text=True)
    if r.returncode != 0:
        return (mid, desc, expect, "INVALID", "does not compile: " + r.stderr.strip().splitlines()[0][:80])
    try:
        r = subprocess.run(["vvp", exe], capture_output=True, text=True, timeout=400)
        out = r.stdout
    except subprocess.TimeoutExpired:
        return (mid, desc, expect, "KILLED", "wall-clock timeout")
    if "tb_mlc_top: ALL CHECKS PASSED" in out and not re.search(r"^(FAIL|AXI PROTO)", out, re.M):
        return (mid, desc, expect, "SURVIVED", "")
    why = [l for l in out.splitlines() if re.match(r"^(FAIL|AXI PROTO)", l)]
    return (mid, desc, expect, "KILLED", (why[0][:110] if why else "no pass line"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    sel = [m for m in MUTANTS if not a.only or m[0] in a.only.split(",")]
    work = tempfile.mkdtemp(prefix="mutate_top_", dir=os.path.join(ROOT, "build"))
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda m: run_one(m, work), sel))
    shutil.rmtree(work, ignore_errors=True)
    killed = sum(1 for r in res if r[3] == "KILLED")
    surv = [r for r in res if r[3] == "SURVIVED"]
    inv = [r for r in res if r[3] == "INVALID"]
    lines = ["mutants run: %d, killed %d, survived %d, invalid %d (each through the full system test sim/tb_mlc_top.sv)" % (len(res), killed, len(surv), len(inv)),
             "a survivor is expected where the edit changes only replacement quality or fairness: the test checks data integrity, not performance.", ""]
    problems = []
    for mid, desc, expect, st, why in res:
        ok = (st == "KILLED" and expect == "killed") or (st == "SURVIVED" and expect.startswith("survives"))
        if not ok:
            problems.append(mid)
        lines.append("%-4s %-9s %-70s %s%s" % (mid, st, desc, ("[expected: %s] " % expect), why))
    lines.insert(2, "PROBLEMS: " + (", ".join(problems) if problems else "none (every outcome matched its expectation)"))
    out = "\n".join(lines) + "\n"
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    open(os.path.join(ROOT, "results", "mutants_top.txt"), "w").write(out)
    print(out)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

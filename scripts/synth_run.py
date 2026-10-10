#!/usr/bin/env python3
"""Run scripts/synth.tcl for one named synthesis point and record what happened (Phase 7, D-037).

    synth_run.py POINT            synthesise one point, write build/reports/POINT/{stat,checks,run}.txt
    synth_run.py --list           print the points and the group each belongs to
    synth_run.py --group NAME     print the points of one group, one per line (the Makefile loops over these)
    synth_run.py --selftest       prove the flow's checks can fail (D-037): bad modules must be rejected, good ones accepted
    synth_run.py --gatesim POINT  run the unit's Tier-1 testbench, unchanged, on its synthesised netlist (D-039)
    synth_run.py --gatesim-points print the points that have such a testbench

A point is a top module, the source files it needs, optional overrides of the top's parameters (Yosys chparam) and
optional overrides of mlc_pkg localparams (for L1, whose sizes are package constants and not module parameters), plus the
ABC mode. The table below is the single definition of the default configuration and of the capacity/associativity sweep.

The run fails (exit 1) when Yosys fails, or when its log holds a warning that is not on the whitelist below. A point
with `oom=True` (the default L3) records an out-of-memory failure in run.txt and exits 0, because that outcome is a measured
result for that point and not an error in the flow; any other failure of such a point still exits 1.
"""
import hashlib
import os
import re
import resource
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "sky130hd" / "sky130hd_tt.lib"
SCRIPT = ROOT / "scripts" / "synth.tcl"
REPORTS = ROOT / "build" / "reports"
WORK = ROOT / "build" / "work"
SELFTEST_DIR = ROOT / "scripts" / "synth_selftest"

# One address space limit for every run (KiB). A run that needs more stops with an out-of-memory error instead of pushing the
# machine into swap. The development machine has 15 GiB of RAM; the largest point that completes peaks at about 9.5 GiB.
MEM_CAP_KIB = 12_000_000

PKG = "rtl/common/mlc_pkg.sv"
SRC = {
    "reset_sync": [PKG, "rtl/common/reset_sync.sv"],
    "l1": [PKG, "rtl/common/reset_sync.sv", "rtl/l1/l1_cache_ctrl.sv"],
    "l2": [PKG, "rtl/replace/plru_tree.sv", "rtl/l2/l2_cache_ctrl.sv"],
    "l3": [PKG, "rtl/replace/plru_tree.sv", "rtl/l2/l2_cache_ctrl.sv", "rtl/l3/l3_cache_ctrl.sv"],
    "adapter": [PKG, "rtl/adapter/l2_l3_width_adapter.sv"],
    "arbiter": [PKG, "rtl/arbiter/l1_l2_arbiter.sv"],
    "engine": [PKG, "rtl/mem_if/axi4_fill_engine.sv"],
}


# Points whose Tier-1 testbench uses only the unit's ports, so it runs unchanged on the synthesised netlist. The other
# units' testbenches read internal state (dut.state, dut.dirty_array, ...), which a netlist does not have.
NETLISTS = ROOT / "build" / "netlists"
GATESIM = {
    "reset_sync": ("tb_reset_sync", ["sim/tb_reset_sync.sv"]),
    "l1_icache": ("tb_l1_icache", [PKG, "sim/tb_l1_icache.sv", "sim/l1_downstream_stub.sv"]),
    "adapter": ("tb_adapter", [PKG, "sim/tb_adapter.sv"]),
    "arbiter": ("tb_arbiter", [PKG, "sim/tb_arbiter.sv"]),
}


def point(top, src, params="", pkg=None, abc="fast", groups=(), oom=False):
    files = list(SRC[src])
    if src == "l1":
        files.append("rtl/l1/l1_icache_ctrl.sv" if top == "l1_icache_ctrl" else "rtl/l1/l1_dcache_ctrl.sv")
    return dict(top=top, srcs=files, params=params, pkg=pkg or {}, abc=abc, groups=tuple(groups), oom=oom)


# Default configuration: every unit at its default size, except L3, which is the largest L3 that fits in memory (D-038).
DEFAULT = "default"
SWEEP = "sweep"
POINTS = {
    "reset_sync": point("reset_sync", "reset_sync", groups=[DEFAULT]),
    "l1_icache": point("l1_icache_ctrl", "l1", groups=[DEFAULT]),
    "l1_dcache": point("l1_dcache_ctrl", "l1", groups=[DEFAULT]),
    "l2_default": point("l2_cache_ctrl", "l2", groups=[DEFAULT]),
    "adapter": point("l2_l3_width_adapter", "adapter", groups=[DEFAULT]),
    "arbiter": point("l1_l2_arbiter", "arbiter", groups=[DEFAULT]),
    "axi4_engine": point("axi4_fill_engine", "engine", groups=[DEFAULT]),
    "l3_32k_w8": point("l3_cache_ctrl", "l3", "CAPACITY_B=32768 WAYS=8", groups=[DEFAULT]),
    # Capacity / associativity sweep (SR-08). L1 is direct-mapped: capacity only.
    "l1_dcache_2k": point("l1_dcache_ctrl", "l1", pkg={"L1_CAPACITY_B": 2048}, groups=[SWEEP]),
    "l1_dcache_8k": point("l1_dcache_ctrl", "l1", pkg={"L1_CAPACITY_B": 8192}, groups=[SWEEP]),
    "l2_8k_w4": point("l2_cache_ctrl", "l2", "CAPACITY_B=8192 WAYS=4", groups=[SWEEP]),
    "l2_16k_w4": point("l2_cache_ctrl", "l2", "CAPACITY_B=16384 WAYS=4", groups=[SWEEP]),
    "l2_32k_w2": point("l2_cache_ctrl", "l2", "CAPACITY_B=32768 WAYS=2", groups=[SWEEP]),
    "l2_32k_w8": point("l2_cache_ctrl", "l2", "CAPACITY_B=32768 WAYS=8", groups=[SWEEP]),
    "l3_8k_w4": point("l3_cache_ctrl", "l3", "CAPACITY_B=8192 WAYS=4", groups=[SWEEP]),
    "l3_8k_w8": point("l3_cache_ctrl", "l3", "CAPACITY_B=8192 WAYS=8", groups=[SWEEP]),
    "l3_16k_w4": point("l3_cache_ctrl", "l3", "CAPACITY_B=16384 WAYS=4", groups=[SWEEP]),
    "l3_16k_w8": point("l3_cache_ctrl", "l3", "CAPACITY_B=16384 WAYS=8", groups=[SWEEP]),
    "l3_32k_w4": point("l3_cache_ctrl", "l3", "CAPACITY_B=32768 WAYS=4", groups=[SWEEP]),
    # The default L3 (256 KiB, 8-way): attempted, expected to run out of memory on a 15 GiB machine.
    "l3_default": point("l3_cache_ctrl", "l3", groups=["l3-default"], oom=True),
    # The same L1-D as `l1_dcache` through ABC's full script, to measure what `abc -fast` costs in area (D-037).
    "l1_dcache_abcdefault": point("l1_dcache_ctrl", "l1", abc="default", groups=["abc-compare"]),
}

# Warnings the flow is known to print and that do not bear on SR-03. Anything else in the log fails the run.
WARNING_OK = [
    # Yosys' liberty reader cannot parse the scan and enable flip-flop functions, so it never maps to those cells.
    re.compile(r"^Warning: Found unsupported expression '[^']*' in pin attribute of cell 'sky130_fd_sc_hd__\w+' - skipping\.$"),
    # Register arrays become one flip-flop per bit (no memory macro exists in this flow).
    re.compile(r"^Warning: Replacing memory \\\w+ with list of registers\. See \S+:\d+$"),
    # ABC notes that the library has full and half adders it does not use as single gates.
    re.compile(r'^ABC: Warning: Detected \d+ multi-output gates \(for example, "sky130_fd_sc_hd__\w+"\)\.$'),
    # ABC's full script ends with a sequential clean-up step, and Yosys hands ABC only the combinational logic.
    re.compile(r'^ABC: Warning: The network is combinational \(run "fraig" or "fraig_sweep"\)\.$'),
    # Yosys' own count of the warnings above.
    re.compile(r"^Warnings: \d+ unique messages, \d+ total$"),
]


def unexpected_warnings(log_text):
    bad = []
    for line in log_text.splitlines():
        if re.search(r"warning|error", line, re.IGNORECASE) and not any(p.match(line) for p in WARNING_OK):
            bad.append(line)
    return bad


def package_copy(name, overrides):
    """Copy of mlc_pkg.sv with the given localparams changed. Fails unless each name is found exactly once."""
    text = (ROOT / PKG).read_text()
    for key, value in overrides.items():
        pat = re.compile(r"(localparam\s+int\s+%s\s*=\s*)\d+(\s*;)" % re.escape(key))
        text, n = pat.subn(lambda m: "%s%d%s" % (m.group(1), value, m.group(2)), text)
        if n != 1:
            raise SystemExit("synth_run: %s: expected one 'localparam int %s' in %s, found %d" % (name, key, PKG, n))
    out = WORK / name / "mlc_pkg.sv"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    return out


def run_yosys(name, spec, out_dir, work_dir, srcs, cap_kib):
    """Run synth.tcl once. Returns (returncode, wall_seconds, peak_rss_kib, log_text)."""
    env = dict(os.environ)
    env.update(
        SYNTH_TOP=spec["top"],
        SYNTH_SRCS=" ".join(str(s) for s in srcs),
        SYNTH_PARAMS=spec["params"],
        SYNTH_LIB=str(LIB),
        SYNTH_OUT=str(out_dir),
        SYNTH_ABC=spec["abc"],
    )
    if name in GATESIM:
        NETLISTS.mkdir(parents=True, exist_ok=True)
        env["SYNTH_NETLIST"] = str(NETLISTS / (name + ".v"))
    log = work_dir / "synth.log"
    err = work_dir / "synth.err"

    def limit():
        resource.setrlimit(resource.RLIMIT_AS, (cap_kib * 1024, cap_kib * 1024))

    t0 = time.monotonic()
    with open(err, "w") as ferr:
        proc = subprocess.run(["yosys", "-q", "-l", str(log), "-c", str(SCRIPT)], cwd=ROOT, env=env,
                              stdout=subprocess.DEVNULL, stderr=ferr, preexec_fn=limit)
    wall = time.monotonic() - t0
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss  # KiB on Linux
    text = log.read_text() if log.exists() else ""
    return proc.returncode, wall, peak, text + "\n" + err.read_text()


def classify(rc, text, peak_kib, cap_kib):
    """(status, reason) of one yosys run: ok, out-of-memory or failed."""
    if rc != 0:
        # Under `yosys -c` a failed allocation is reported as an uncaught exception from the Tcl command, not as bad_alloc,
        # so that message only counts as out-of-memory when the run had also grown to within 10% of the cap.
        at_cap = peak_kib >= 0.9 * cap_kib
        if "bad_alloc" in text or "Cannot allocate memory" in text or (
                "uncaught exception during Yosys command invoked from TCL" in text and at_cap):
            return "out-of-memory", "address-space cap %d KiB reached" % cap_kib
        return "failed", "yosys exit status %d" % rc
    bad = unexpected_warnings(text)
    if bad:
        return "failed", "unexpected log lines: " + " | ".join(bad[:3])
    return "ok", ""


def run_point(name, cap_kib=MEM_CAP_KIB):
    spec = POINTS[name]
    out_dir = REPORTS / name
    work_dir = WORK / name
    for d in (out_dir, work_dir):
        d.mkdir(parents=True, exist_ok=True)
    for stale in ("stat.txt", "checks.txt", "run.txt"):
        (out_dir / stale).unlink(missing_ok=True)
    srcs = [ROOT / s for s in spec["srcs"]]
    if spec["pkg"]:
        srcs[srcs.index(ROOT / PKG)] = package_copy(name, spec["pkg"])
    rc, wall, peak, text = run_yosys(name, spec, out_dir, work_dir, srcs, cap_kib)

    status, reason = classify(rc, text, peak, cap_kib)

    version = subprocess.run(["yosys", "-V"], capture_output=True, text=True).stdout.strip()
    lib_hash = hashlib.sha256(LIB.read_bytes()).hexdigest()
    lines = [
        ("point", name), ("top", spec["top"]), ("params", spec["params"] or "(defaults)"),
        ("package_overrides", ", ".join("%s=%d" % kv for kv in spec["pkg"].items()) or "(none)"),
        ("abc", spec["abc"]), ("status", status), ("reason", reason or "-"),
        ("wall_seconds", "%.0f" % wall), ("peak_rss_kib", str(peak)), ("mem_cap_kib", str(cap_kib)),
        ("yosys", version), ("liberty_sha256", lib_hash),
    ]
    (out_dir / "run.txt").write_text("".join("%s: %s\n" % kv for kv in lines))
    print("%-22s %-14s %5.0f s  peak %5.2f GiB  %s" % (name, status, wall, peak / 1048576, reason))
    if status == "ok":
        return 0
    if status == "out-of-memory" and spec["oom"]:
        return 0  # the outcome is the result
    return 1


# --- gate-level re-run of a Tier-1 testbench --------------------------------------------------------------------------------

def gatesim(name):
    """Run the unit's own testbench on build/netlists/<name>.v. Cell models come from the liberty itself (Yosys turns each
    cell's function into Verilog), so this checks that mapping preserved the RTL's behaviour, not that the library is right."""
    tb, tb_srcs = GATESIM[name]
    spec = POINTS[name]
    net = NETLISTS / (name + ".v")
    if not net.exists():
        raise SystemExit("synth_run: %s does not exist; run `make synth` first" % net)
    newer = [f for f in spec["srcs"] if (ROOT / f).stat().st_mtime > net.stat().st_mtime]
    if newer:
        raise SystemExit("synth_run: %s is older than %s; run `make synth` again" % (net, ", ".join(newer)))
    work = WORK / name
    work.mkdir(parents=True, exist_ok=True)
    models = NETLISTS / (name + "_gl.v")
    subprocess.run(["yosys", "-q", "-p", "read_liberty -ignore_miss_func -ignore_miss_dir %s; read_verilog %s; hierarchy -top %s; "
                    "write_verilog -noattr %s" % (LIB, net, spec["top"], models)], check=True, cwd=ROOT)
    exe = work / "gl_sim"
    subprocess.run(["iverilog", "-g2012", "-s", tb, "-o", str(exe)] + [str(ROOT / f) for f in tb_srcs] + [str(models)],
                   check=True, cwd=ROOT)
    try:
        res = subprocess.run(["vvp", str(exe)], capture_output=True, text=True, cwd=ROOT, timeout=3600)
    except subprocess.TimeoutExpired as e:
        res = subprocess.CompletedProcess(e.cmd, 1, (e.stdout or b"").decode(errors="replace"), "timeout after 3600 s")
    (work / "gatesim.log").write_text(res.stdout + res.stderr)
    passed = len(re.findall(r"^PASS", res.stdout, re.MULTILINE))
    failed = len(re.findall(r"^(FAIL|ERROR|FATAL)", res.stdout, re.MULTILINE))
    rtl_log = ROOT / "sim" / "logs" / (tb + ".log")
    rtl_passed = len(re.findall(r"^PASS", rtl_log.read_text(), re.MULTILINE)) if rtl_log.exists() else None
    ok = res.returncode == 0 and failed == 0 and passed > 0 and passed == rtl_passed
    cells = len(re.findall(r"^\s*sky130_fd_sc_hd__\w+\s", net.read_text(), re.MULTILINE))
    line = "gatesim %s: %s, %s on the synthesised netlist (%d cells); the RTL run of the same testbench has %s checks" % (
        name, "PASS" if ok else "FAIL", "%d checks" % passed, cells, rtl_passed)
    (REPORTS / name / "gatesim.txt").write_text(line + "\n")
    print(line)
    return 0 if ok else 1


# --- self test -----------------------------------------------------------------------------------------------------------

SELFTEST = [
    # (module, source, must be accepted?, text that must appear in the log when it is rejected)
    ("st_good", "good.sv", True, ""),
    ("st_array", "array_ok.sv", True, ""),
    ("st_latch", "latch_bad.sv", False, "Assertion failed"),
    ("st_tristate", "tristate_bad.sv", False, "Assertion failed"),
    ("st_multidriver", "multidriver_bad.sv", False, "problems"),
    ("st_loop", "loop_bad.sv", False, "problems"),
    ("st_warn", "warn_bad.sv", False, "unexpected log lines"),
]


def pattern_selftest():
    """The assertions on the mapped netlist can only be reached by a fault that the earlier checks already catch, so the bad
    modules above cannot exercise them. Check instead that every cell-name pattern they use names real library cells (a
    misspelt pattern would select nothing and pass for ever), and that `t:$*` does match generic cells."""
    patterns = sorted(set(re.findall(r"t:(sky130_fd_sc_hd__\w+_)\*", SCRIPT.read_text())))
    lib_text = LIB.read_text()
    missing = [p for p in patterns if not re.search(r'cell \("%s\d+"\)' % re.escape(p), lib_text)]
    generic = "read_verilog -sv %s; hierarchy -top st_good; synth -top st_good; select -assert-min 1 t:$*" % (
        SELFTEST_DIR / "good.sv")
    r = subprocess.run(["yosys", "-q", "-p", generic], capture_output=True, text=True)
    ok = not missing and r.returncode == 0 and len(patterns) >= 10
    print("selftest %-15s %d library-cell patterns%s, generic-cell pattern  %s" % (
        "patterns", len(patterns), " (missing: %s)" % ", ".join(missing) if missing else "", "ok" if ok else "WRONG"))
    return 0 if ok else 1


def classify_selftest():
    tcl_exc = "ERROR: uncaught exception during Yosys command invoked from TCL"
    cases = [
        ("clean run", classify(0, "", 1000, 12_000_000)[0], "ok"),
        ("exception at the cap", classify(1, tcl_exc, 11_972_044, 12_000_000)[0], "out-of-memory"),
        ("bad_alloc", classify(134, "std::bad_alloc", 50, 12_000_000)[0], "out-of-memory"),
        ("exception far below the cap", classify(1, tcl_exc, 2_000_000, 12_000_000)[0], "failed"),
        ("other error at the cap", classify(1, "ERROR: Assertion failed", 11_972_044, 12_000_000)[0], "failed"),
        ("unlisted warning", classify(0, "Warning: something new", 1000, 12_000_000)[0], "failed"),
    ]
    bad = [name for name, got, want in cases if got != want]
    print("selftest %-15s %d cases  %s" % ("classification", len(cases), "ok" if not bad else "WRONG: " + ", ".join(bad)))
    return 1 if bad else 0


def selftest():
    failures = pattern_selftest() + classify_selftest()
    for top, src, accept, needle in SELFTEST:
        name = "selftest_" + top
        POINTS[name] = dict(top=top, srcs=[str(SELFTEST_DIR / src)], params="", pkg={}, abc="fast", groups=(), oom=False)
        out_dir, work_dir = WORK / "selftest" / top / "out", WORK / "selftest" / top
        for d in (out_dir, work_dir):
            d.mkdir(parents=True, exist_ok=True)
        rc, _, _, text = run_yosys(name, POINTS[name], out_dir, work_dir, [SELFTEST_DIR / src], MEM_CAP_KIB)
        bad = unexpected_warnings(text) if rc == 0 else []
        accepted = rc == 0 and not bad
        if bad:
            text += "\nunexpected log lines: " + " | ".join(bad)
        ok = accepted if accept else (not accepted and needle in text)
        print("selftest %-15s %-9s %s" % (top, "accepted" if accepted else "rejected", "ok" if ok else "WRONG"))
        failures += not ok
    return 1 if failures else 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--list":
        for n, s in POINTS.items():
            print("%-22s %-12s %s %s" % (n, "/".join(s["groups"]), s["top"], s["params"]))
        return 0
    if len(argv) == 3 and argv[1] == "--group":
        names = [n for n, s in POINTS.items() if argv[2] in s["groups"]]
        if not names:
            raise SystemExit("synth_run: no group %s" % argv[2])
        print("\n".join(names))
        return 0
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) == 3 and argv[1] == "--gatesim" and argv[2] in GATESIM:
        return gatesim(argv[2])
    if len(argv) == 2 and argv[1] == "--gatesim-points":
        print("\n".join(GATESIM))
        return 0
    if len(argv) == 2 and argv[1] in POINTS:
        return run_point(argv[1])
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

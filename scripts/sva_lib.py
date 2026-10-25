#!/usr/bin/env python3
"""sva_lib.py - run the existing Tier-1 / boundary / system testbenches under Verilator 5.052 with the bound checkers (verif/) and read the results.

The testbenches are the repository's own (sim/tb_*.sv, written for Icarus); Verilator 5.052 builds twelve of the thirteen unchanged (tb_l3 hits an
internal fault of the simulator, see docs). State is zero-initialised (no --x-initial unique): the testbenches count events from time zero, and a random power-up state before reset produces spurious
forwards that Icarus's X values hide (tb_l1_dcache then reports an extra forward). A run passes when the testbench's own verdict is clean (exit 0, at least one PASS line, no FAIL / ERROR /
FATAL / AXI PROTO line: the same rule as the Makefile's test-% target) AND no checker assertion fired.

Used by sva_run.py (baseline run) and sva_mutants.py (injected-bug campaign).
"""
import collections
import concurrent.futures as cf
import os
import re
import signal
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VLT = os.environ.get("VERILATOR_5052", os.path.normpath(os.path.join(ROOT, "..", "..", "_toolchain", "verilator-5.052")))
PKG = "rtl/common/mlc_pkg.sv"


def registry():
    """[(name, [sources])] from the `$(call register,<name>,<sources>)` lines of the Makefile (the single list of testbenches)"""
    out = []
    for name, src in re.findall(r"^\$\(call register,(\w+),(.*)\)\s*$", open(os.path.join(ROOT, "Makefile")).read(), re.M):
        out.append((name, src.replace("$(PKG)", PKG).split()))
    return out


# tb_l3 cannot be built by Verilator 5.052 (internal fault); tb_reset_sync instantiates nothing a checker is bound to
EXCLUDED = {"tb_l3": "Verilator 5.052 internal fault while building it", "tb_reset_sync": "contains no module a checker is bound to"}


def env():
    e = dict(os.environ)
    e["VERILATOR_ROOT"] = VLT
    return e


def run_one(name, srcs, outdir, rtl_dir=None, checkers=None, timeout=1200, reuse=False):
    """build + run one testbench; returns a dict (never raises). A run that does not finish within `timeout` seconds is killed (with its process
    group) and recorded as a timeout. reuse: take the result of a finished run from its log (resuming an interrupted campaign)."""
    build = os.path.join(outdir, name)
    os.makedirs(outdir, exist_ok=True)
    chk = checkers or os.path.join(ROOT, "verif", "mlc_checkers.sv")
    files = []
    for s in srcs:
        if rtl_dir and s.startswith("rtl/"):
            files.append(os.path.join(rtl_dir, s[len("rtl/"):]))   # rtl_dir is a copy of rtl/ itself
        else:
            files.append(os.path.join(ROOT, s))
    cmd = [VLT + "/bin/verilator", "--binary", "--timing", "--assert", "--coverage", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-WIDTH",
           "-Wno-TIMESCALEMOD", "-Wno-DECLFILENAME", "--top-module", name, "--Mdir", build] + files + \
          [chk, os.path.join(ROOT, "verif", "mlc_binds.sv")]
    log = os.path.join(outdir, name + ".log")
    exe = os.path.join(build, "V" + name)
    res = dict(tag=name, log=log, fired={}, covdat=os.path.join(build, "coverage.dat"))
    if reuse and os.path.exists(exe) and os.path.exists(log):
        return parse_run(res, open(log, errors="replace").read(), None)
    b = subprocess.run(cmd, capture_output=True, text=True, env=env(), cwd=ROOT)
    if not os.path.exists(exe):
        open(log, "w").write((b.stdout + b.stderr)[-4000:])
        res.update(ok=False, built=False, pass_=0, fail=0, rc=None)
        return res
    p = subprocess.Popen([exe, "+verilator+error+limit+100000", "+verilator+coverage+file+" + res["covdat"]],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=build, start_new_session=True)
    try:
        text, _ = p.communicate(timeout=timeout)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        text, _ = p.communicate()
        text, rc = (text or "") + "\nTIMEOUT", -9
    open(log, "w").write(text + "\n[exit status %d]\n" % rc)
    return parse_run(res, text, rc)


def parse_run(res, text, rc):
    """fill in a run's result from its log text; rc None = read it back from the `[exit status N]` trailer run_one wrote (none: the run did not finish)"""
    if rc is None:
        m = re.search(r"^\[exit status (-?\d+)\]$", text, re.M)
        rc = int(m.group(1)) if m else 1
    pass_ = len(re.findall(r"^PASS", text, re.M))
    # a testbench-side failure: its own FAIL/ERROR/FATAL/AXI PROTO line, or one of its own `assert`s (scope = the testbench, no checker label)
    fail = len(re.findall(r"^(FAIL|ERROR|FATAL|AXI PROTO)", text, re.M)) + len(re.findall(r"Assertion failed in \w+\s*$", text, re.M))
    fired = collections.Counter(re.findall(r"Assertion failed in \S*?\.((?:a|sb)_\w+)", text))
    timeout = (rc == -9)
    # the run was stopped by the checkers themselves: they fired, the testbench reported nothing, and the simulator hit its error limit
    aborted = rc != 0 and not timeout and bool(fired) and fail == 0
    res.update(built=True, rc=rc, pass_=pass_, fail=fail, fired=dict(fired), timeout=timeout, aborted_by_checker=aborted)
    # "the tests caught it" means a testbench check failed, or the run ended without the testbench's own verdict for a reason that is not a checker
    res["tests_failed"] = fail > 0 or timeout or ((rc != 0 or pass_ == 0) and not aborted)
    res["ok"] = rc == 0 and pass_ > 0 and fail == 0 and not fired
    return res


def run_matrix(tbs, outdir, jobs=4, **kw):
    with cf.ThreadPoolExecutor(jobs) as ex:
        return list(ex.map(lambda t: run_one(t[0], t[1], outdir, **kw), tbs))


REC = re.compile(r"^C '(.*)' (\d+)$")


def read_cov(path):
    out = {}
    if not os.path.exists(path):
        return out
    for raw in open(path, "rb").read().decode("latin-1").splitlines():
        m = REC.match(raw)
        if not m:
            continue
        f = {}
        for part in m.group(1).split("\x01")[1:]:
            k, _, v = part.partition("\x02")
            f[k] = v
        page = f.get("page", "")
        if page.startswith("v_user/"):
            mod = page.split("/", 1)[1].split("__")[0]
            key = (mod, f["o"], f["h"])
            out[key] = out.get(key, 0) + int(m.group(2))
    return out


def merge_cov(results):
    tot = collections.defaultdict(int)
    for r in results:
        for k, v in read_cov(r["covdat"]).items():
            tot[k] += v
    return tot


def by_label(tot):
    agg, inst = collections.defaultdict(int), collections.defaultdict(set)
    for (mod, lab, h), v in tot.items():
        agg[(mod, lab)] += v
        inst[(mod, lab)].add(h)
    return agg, inst


def assertion_labels(path):
    labs = []
    for line in open(path).read().splitlines():
        m = re.match(r"^\s*((?:a|sb)_\w+):\s*assert\b", line)
        if m:
            labs.append(m.group(1))
    return labs


if __name__ == "__main__":
    sys.exit("use sva_run.py or sva_mutants.py")

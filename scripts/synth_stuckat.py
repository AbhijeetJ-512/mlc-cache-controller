#!/usr/bin/env python3
"""Stuck-at campaign on a synthesised netlist (Phase 7, D-039).

    synth_stuckat.py POINT                 tie each cell output of build/netlists/POINT.v to 0 and to 1, one fault at a time,
                                           and run the unit's own Tier-1 testbench on every faulty netlist
    synth_stuckat.py POINT --tb-rev REV    the same with the testbench file(s) as they were at git revision REV, to show
                                           what an earlier version of the test could not see
    synth_stuckat.py --points              the points this is run for (the ones with a gate-level testbench and no storage)

A fault is (cell instance, output pin, stuck value). The pin is disconnected from the cell and its net is tied to the value. A
fault that gives a tie cell the constant it already drives changes nothing; it is counted as no-op and not simulated, because no
test can detect it. Every other fault is simulated and is detected when the testbench fails, hangs, or passes a different
number of checks than on the fault-free netlist. The result is written to build/reports/POINT/stuckat.txt (stuckat_before.txt
with --tb-rev). Run `make synth` first: it writes the netlist.

This is not run on the L1 netlist: those testbenches use a few of the 128 sets, so most faults in the storage cells would
survive by construction, which is a memory-test question and not a functional one.
"""
import os
import re
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_run  # noqa: E402

ROOT, WORK, REPORTS, NETLISTS = synth_run.ROOT, synth_run.WORK, synth_run.REPORTS, synth_run.NETLISTS
POINTS = ["arbiter", "adapter"]
TIMEOUT_S = 120


def split_top(models_text, top):
    """(text before the top module, the top module, text after it)."""
    start = models_text.index("module %s(" % top)
    end = models_text.index("endmodule", start) + len("endmodule")
    return models_text[:start], models_text[start:end], models_text[end:]


def faults_of(top_text, cells):
    """Every (instance match, output pin, connected net, value) of the top module."""
    inst = re.compile(r"\n  (sky130_fd_sc_hd__\w+) (\S+) \((.*?)\n  \);", re.S)
    out = []
    for m in inst.finditer(top_text):
        cell = m.group(1)
        pins = dict(re.findall(r"\.(\w+)\(([^)]*)\)", m.group(3)))
        outs = [p for p, d in cells[cell][1] if d == "output" and p in pins]
        for pin in outs:
            for value in (0, 1):
                out.append((m, cell, pin, pins[pin].strip(), value))
    return out


def is_noop(cell, pin, value):
    """A tie cell's outputs are constants: HI is always 1 and LO is always 0."""
    return cell.startswith("sky130_fd_sc_hd__conb_") and ((pin == "HI" and value == 1) or (pin == "LO" and value == 0))


def mutate(top_text, m, pin, net, value):
    """The top module with output `pin` of instance `m` disconnected and its net tied to `value`."""
    inst = m.group(0)
    new_inst = re.sub(r"\.%s\([^)]*\)" % re.escape(pin), ".%s()" % pin, inst, count=1)
    return top_text[: m.start()] + new_inst + "\n  assign %s = 1'b%d;" % (net, value) + top_text[m.end():]


def testbench_files(point, rev):
    """The testbench sources for the point, from the working tree or from git revision `rev`."""
    tb, srcs = synth_run.GATESIM[point]
    if rev is None:
        return tb, [str(ROOT / f) for f in srcs]
    d = WORK / point / "stuckat_tb"
    d.mkdir(parents=True, exist_ok=True)
    files = []
    for f in srcs:
        if f.startswith("sim/tb_"):
            text = subprocess.run(["git", "show", "%s:%s" % (rev, f)], capture_output=True, text=True, cwd=ROOT, check=True).stdout
            path = d / Path(f).name
            path.write_text(text)
            files.append(str(path))
        else:
            files.append(str(ROOT / f))
    return tb, files


def run_sim(tag, tb, tb_files, models_path, workdir):
    exe = workdir / (tag + ".vvp")
    c = subprocess.run(["iverilog", "-g2012", "-s", tb, "-o", str(exe)] + tb_files + [str(models_path)], capture_output=True, text=True)
    if c.returncode != 0:
        raise SystemExit("synth_stuckat: %s does not compile: %s" % (tag, c.stderr[:300]))
    try:
        v = subprocess.run(["vvp", str(exe)], capture_output=True, text=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        exe.unlink(missing_ok=True)
        return None  # a hang is a detection
    exe.unlink(missing_ok=True)
    passed = len(re.findall(r"^PASS", v.stdout, re.M))
    failed = len(re.findall(r"^(FAIL|ERROR|FATAL)", v.stdout, re.M))
    return v.returncode, passed, failed


def main(argv):
    if argv[1:] == ["--points"]:
        print("\n".join(POINTS))
        return 0
    rev = None
    if len(argv) == 4 and argv[2] == "--tb-rev":
        rev = argv[3]
    elif len(argv) != 2:
        raise SystemExit(__doc__)
    point = argv[1]
    if point not in POINTS:
        raise SystemExit("synth_stuckat: %s is not one of %s" % (point, POINTS))
    net = NETLISTS / (point + ".v")
    if not net.exists():
        raise SystemExit("synth_stuckat: %s does not exist; run `make synth` first" % net)
    top = synth_run.POINTS[point]["top"]
    models = synth_run.make_models(point)
    cells = synth_run.liberty_cells()
    head, top_text, tail = split_top(models.read_text(), top)
    tb, tb_files = testbench_files(point, rev)
    work = WORK / point / "stuckat"
    work.mkdir(parents=True, exist_ok=True)

    base = run_sim("base", tb, tb_files, models, work)
    if base is None or base[0] != 0 or base[2] != 0 or base[1] == 0:
        raise SystemExit("synth_stuckat: the fault-free netlist does not pass the testbench: %s" % (base,))
    expect = base[1]

    faults = faults_of(top_text, cells)
    todo = [f for f in faults if not is_noop(f[1], f[2], f[4])]
    noop = len(faults) - len(todo)

    def one(i):
        m, cell, pin, netname, value = todo[i]
        path = work / ("m%d.v" % i)
        path.write_text(head + mutate(top_text, m, pin, netname, value) + tail)
        r = run_sim("m%d" % i, tb, tb_files, path, work)
        path.unlink(missing_ok=True)
        survived = r is not None and r[0] == 0 and r[2] == 0 and r[1] == expect
        return survived

    with ThreadPoolExecutor(max_workers=max(2, (os.cpu_count() or 4) // 2)) as ex:
        results = list(ex.map(one, range(len(todo))))
    survivors = [todo[i] for i, s in enumerate(results) if s]
    detected = len(todo) - len(survivors)

    by_kind = Counter("%s.%s stuck-at-%d" % (c.replace("sky130_fd_sc_hd__", ""), pin, v) for _, c, pin, _, v in survivors)
    name = "stuckat_before.txt" if rev else "stuckat.txt"
    lines = [
        "point: %s" % point, "testbench: %s%s" % (tb, " as at git revision %s" % rev if rev else " (working tree)"),
        "checks on the fault-free netlist: %d" % expect, "cells: %d" % len(set(id(f[0]) for f in faults)),
        "faults (output pin x stuck value): %d" % len(faults), "no-op faults, not simulated (a tie cell tied to its own constant): %d" % noop,
        "faults that change the circuit and were simulated: %d" % len(todo), "detected: %d" % detected, "survived: %d" % len(survivors),
    ]
    lines += ["survivors by kind: %d x %s" % (n, k) for k, n in sorted(by_kind.items())]
    # What each surviving fault sits on, by the name of the net it ties: port bits such as l2_req_addr[7] say which path it is.
    by_net = Counter(re.sub(r"\[\d+\]", "", n.strip()) for _, _, _, n, _ in survivors)
    lines += ["survivors by net: %d x %s" % (c, n) for n, c in sorted(by_net.items())]
    (REPORTS / point / name).write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0 if not survivors or rev else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

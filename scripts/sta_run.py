#!/usr/bin/env python3
"""Static timing analysis of one synthesised netlist with OpenSTA, and a record of what it found (Phase 8, D-041).

    sta_run.py POINT        analyse build/netlists/POINT.v (written by `make synth` / `make synth-timing`); write
                            build/reports/POINT/{timing,power,sta}.txt
    sta_run.py --list       print the points and the group each belongs to
    sta_run.py --group G    print the points of group G, one per line (the Makefile loops over these)
    sta_run.py --sensitivity POINT   how the minimum period moves with the input and output delays (0/0, 0.35/0.15, 1.0/0.5 ns)
    sta_run.py --selftest   check the flow against known answers and prove its checks can fail

How a point is analysed. The unit is analysed alone, on one ideal clock, with the input and output delays of constraints/mlc.sdc,
and no wire parasitics. The netlist is fixed, so every path delay is independent of the clock period and every slack is the period
minus a constant: STA is run once at a base period, and the smallest period each class of path needs is then base period minus
that class's worst setup slack. That figure is verified, not assumed: STA is run again 2% above it (every setup slack must be
non-negative) and 2% below it (some setup slack must be negative), which is the constraint sweep of TR-02.

The run fails when OpenSTA fails, when it prints any warning or error (check_setup warns about a missing clock, an unconstrained
endpoint, a combinational loop), or when the 2% bracket does not hold.
"""
import math
import os
import re
import resource
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_run  # noqa: E402  (the table of synthesis points is the table of netlists)

ROOT = synth_run.ROOT
LIB = synth_run.LIB
REPORTS = synth_run.REPORTS
NETLISTS = synth_run.NETLISTS
WORK = synth_run.WORK
SCRIPT = ROOT / "scripts" / "sta.tcl"
SDC = ROOT / "constraints" / "mlc.sdc"
BASE_PERIOD_NS = 10.0
BRACKET = 0.02
CLASSES = ["reg2reg", "in2reg", "reg2out", "in2out"]
RESET_CLASSES = ["reset_async", "reset_data", "reset2out"]

# Points analysed: the netlists of `make synth-timing` (timing-driven mapping), and the four default-flow netlists that
# `make synth` also writes, as the "raw" comparison (no buffering: the point of D-041).
RAW = ["reset_sync", "arbiter", "adapter", "l1_icache"]
POINTS = {name: dict(netlist=name, top=synth_run.POINTS[name]["top"], groups=("raw",)) for name in RAW}
for name in synth_run.SPEED_POINTS:
    POINTS[name] = dict(netlist=name, top=synth_run.POINTS[name]["top"], groups=synth_run.POINTS[name]["groups"])


def run_sta(netlist, top, period, out_dir, work_dir, sdc=SDC, extra_env=None, lib=LIB):
    """One OpenSTA run. Returns (returncode, text of stdout and stderr, peak KiB, seconds)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.update(STA_NETLIST=str(netlist), STA_TOP=top, STA_LIB=str(lib), STA_SDC=str(sdc), STA_PERIOD_NS="%.6g" % period,
               STA_OUT=str(out_dir))
    env.update(extra_env or {})
    t0 = time.monotonic()
    p = subprocess.run(["sta", "-no_splash", "-exit", str(SCRIPT)], cwd=ROOT, env=env, capture_output=True, text=True)
    return p.returncode, p.stdout + "\n" + p.stderr, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss, time.monotonic() - t0


def log_problems(text):
    """Every OpenSTA message that is a warning or an error. None are expected, so none are whitelisted."""
    return [l for l in text.splitlines() if re.search(r"warning|error", l, re.IGNORECASE)]


SLACK = re.compile(r"^\s+(-?\d+\.\d+)\s+slack \((MET|VIOLATED)\)", re.M)


def sections(text):
    """{ "class kind": text } from the '=== class kind ===' headings that sta.tcl writes."""
    parts = re.split(r"^=== (.*) ===$", text, flags=re.M)
    return {parts[i]: parts[i + 1] for i in range(1, len(parts) - 1, 2)}


def worst_path(section_text):
    """(slack, block) of the path with the smallest slack in a section, or None if it has none."""
    blocks = re.split(r"(?=^Startpoint:)", section_text, flags=re.M)
    found = []
    for b in blocks:
        m = SLACK.search(b)
        if m and b.startswith("Startpoint:"):
            found.append((float(m.group(1)), b))
    return min(found, key=lambda t: t[0]) if found else None


def logic_depth(block):
    """Combinational cells on the data path: output pins of cells that are not flip-flops or latches."""
    data = block.split("data arrival time")[0]
    cells = re.findall(r"\s\S+/(?:X|Y|Z|HI|LO|SUM|COUT)\s+\((sky130_fd_sc_hd__\w+)\)", data)
    return len([c for c in cells if not re.search(r"__(df|dl|sdf|edf)", c)])


CELL_LINE = re.compile(r"^\s+\d+\s+[\d.]+\s+[\d.]+\s+([\d.]+)\s+[\d.]+\s+[\^v]\s+\S+/\w+\s+\(sky130_fd_sc_hd__(\w+?)_\d+\)", re.M)


def composition(block):
    """Where the time of a path goes: (buffers, multiplexers, other logic, flip-flop clock-to-output) in ns, and the number of buffers.
    Buffers are buf and clkbuf cells (fan-out trees), multiplexers are mux2 and mux4 cells."""
    data = block.split("data arrival time")[0]
    buf = mux = other = clkq = 0.0
    nbuf = 0
    for m in CELL_LINE.finditer(data):
        delay, kind = float(m.group(1)), m.group(2)
        if re.match(r"(df|dl|sdf|edf)", kind):
            clkq += delay
        elif kind in ("buf", "clkbuf"):
            buf += delay
            nbuf += 1
        elif kind in ("mux2", "mux4", "mux2i"):
            mux += delay
        else:
            other += delay
    return buf, mux, other, clkq, nbuf


def endpoints(block):
    s = re.search(r"^Startpoint: (\S+)", block, re.M)
    e = re.search(r"^Endpoint: (\S+)", block, re.M)
    return (s.group(1) if s else "-", e.group(1) if e else "-")


def analyse(timing_text, period, classes=CLASSES):
    """The numbers of one STA run: per class the smallest period it needs, depth and endpoints, hold slack, overall setup slack."""
    sec = sections(timing_text)
    info = {}
    for cls in classes:
        w = worst_path(sec.get(cls + " max", ""))
        h = worst_path(sec.get(cls + " min", ""))
        if w:
            info[cls] = dict(slack=w[0], need=period - w[0], depth=logic_depth(w[1]), start=endpoints(w[1])[0], end=endpoints(w[1])[1],
                             hold=(h[0] if h else None), comp=composition(w[1]))
    # the overall report has one path per group (clk and asynchronous); take the worst of them
    all_max = [float(m.group(1)) for m in SLACK.finditer(sec.get("overall max", ""))]
    all_min = [float(m.group(1)) for m in SLACK.finditer(sec.get("overall min", ""))]
    return info, (min(all_max) if all_max else None), (min(all_min) if all_min else None)


def bracket_check(net, top, tmin, work_dir, sdc=SDC):
    """STA 2% above `tmin` must show no setup violation and 2% below it at least one. Returns (ok, text, why it failed)."""
    verdicts, why = [], "-"
    for factor, want_ok in ((1 + BRACKET, True), (1 - BRACKET, False)):
        period = tmin * factor
        sub = work_dir / ("p%.0f" % (period * 1000))
        rc, text, _, _ = run_sta(net, top, period, sub, work_dir, sdc=sdc, extra_env={"STA_BRIEF": "1"})
        if rc != 0 or log_problems(text):
            return False, "; ".join(verdicts), "bracket run at %.3f ns failed" % period
        _, setup, _ = analyse((sub / "timing.txt").read_text(), period)
        ok = setup is not None and ((setup >= 0) if want_ok else (setup < 0))
        verdicts.append("%.3f ns: worst setup slack %.3f %s" % (period, setup, "(as required)" if ok else "(WRONG)"))
        if not ok:
            why = "bracket does not hold at %.3f ns" % period
    return why == "-", "; ".join(verdicts), why


def run_point(name):
    spec = POINTS[name]
    net = NETLISTS / (spec["netlist"] + ".v")
    if not net.exists():
        raise SystemExit("sta_run: %s does not exist; run `make synth-timing` (or `make synth` for the raw points) first" % net)
    stale = [f for f in (ROOT / "scripts" / "synth.tcl", ROOT / "scripts" / "abc_speed.script") if f.stat().st_mtime > net.stat().st_mtime]
    if stale and spec["netlist"] in synth_run.SPEED_POINTS:
        raise SystemExit("sta_run: %s is older than %s; run `make synth-timing` again" % (net, stale[0].name))
    out_dir = REPORTS / name
    work_dir = WORK / name / "sta"
    for f in ("timing.txt", "power.txt", "sta.txt"):
        (out_dir / f).unlink(missing_ok=True)
    lines, status, reason = [], "ok", "-"

    rc, text, peak, wall = run_sta(net, spec["top"], BASE_PERIOD_NS, out_dir, work_dir)
    problems = log_problems(text)
    if rc != 0 or problems:
        status, reason = "failed", ("sta exit status %d" % rc) if rc else "sta printed: " + " | ".join(problems[:3])
        info, worst_setup, worst_hold = {}, None, None
    else:
        info, worst_setup, worst_hold = analyse((out_dir / "timing.txt").read_text(), BASE_PERIOD_NS)

    # The reset network on its own, unbuffered (the main analysis treats paths from the reset ports as false paths: constraints/mlc.sdc)
    reset = {}
    if status == "ok":
        rc3, text3, _, _ = run_sta(net, spec["top"], BASE_PERIOD_NS, work_dir / "reset", work_dir,
                                   extra_env={"STA_RESET_ONLY": "1", "STA_RESET_FALSE_PATH": "0"})
        if rc3 != 0 or log_problems(text3):
            status, reason = "failed", "reset-only run failed"
        else:
            rtext = (work_dir / "reset" / "timing.txt").read_text()
            (out_dir / "reset.txt").write_text(rtext)
            reset, _, _ = analyse(rtext, BASE_PERIOD_NS, RESET_CLASSES)
            for cls, i in reset.items():
                blk = worst_path(sections(rtext).get(cls + " max", ""))
                m = re.search(r"^\s*(\d+)\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+[\^v]\s+\S+\s+\(in\)", blk[1], re.M) if blk else None
                i["fanout"] = int(m.group(1)) if m else None

    tmin = None
    bracket = "-"
    if status == "ok":
        if worst_setup is None or not info:
            status, reason = "failed", "no setup paths were reported"
        else:
            tmin = BASE_PERIOD_NS - worst_setup
            ok, bracket, failed_at = bracket_check(net, spec["top"], tmin, work_dir)
            if not ok:
                status, reason = "failed", failed_at

    power = "-"
    pw = out_dir / "power.txt"
    if pw.exists():
        m = re.search(r"^Total\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", pw.read_text(), re.M)
        power = m.group(4) if m else "-"

    lines += [("point", name), ("top", spec["top"]), ("netlist", "build/netlists/%s.v" % spec["netlist"]),
              ("status", status), ("reason", reason), ("base_period_ns", "%.3f" % BASE_PERIOD_NS),
              ("input_delay_ns", "0.35"), ("output_delay_ns", "0.15")]
    if tmin is not None:
        lines += [("min_period_ns", "%.3f" % tmin), ("fmax_mhz", "%.1f" % (1000.0 / tmin)),
                  ("worst_setup_slack_at_base_ns", "%.3f" % worst_setup),
                  ("worst_hold_slack_ns", "%.3f" % worst_hold if worst_hold is not None else "-"), ("bracket", bracket)]
        for cls in CLASSES:
            if cls in info:
                i = info[cls]
                lines += [("%s_min_period_ns" % cls, "%.3f" % i["need"]), ("%s_depth" % cls, str(i["depth"])),
                          ("%s_path" % cls, "%s -> %s" % (i["start"], i["end"])),
                          ("%s_hold_slack_ns" % cls, "%.3f" % i["hold"] if i["hold"] is not None else "-")]
    if reset:
        worst_reset = max(reset.values(), key=lambda i: i["need"])
        lines += [("reset_unbuffered_min_period_ns", "%.3f" % worst_reset["need"]), ("reset_net_fanout", str(worst_reset.get("fanout")))]
        for cls in RESET_CLASSES:
            if cls in reset:
                lines += [("%s_min_period_ns" % cls, "%.3f" % reset[cls]["need"]), ("%s_path" % cls, "%s -> %s" % (reset[cls]["start"], reset[cls]["end"]))]
    else:
        lines += [("reset_unbuffered_min_period_ns", "-"), ("reset_net_fanout", "-")]
    lines += [("total_power_w", power), ("wall_seconds", "%.0f" % wall), ("peak_rss_kib", str(peak)),
              ("sta", subprocess.run(["sta", "-version"], capture_output=True, text=True).stdout.strip() or "OpenSTA")]
    (out_dir).mkdir(parents=True, exist_ok=True)
    (out_dir / "sta.txt").write_text("".join("%s: %s\n" % kv for kv in lines))
    print("%-22s %-7s %s" % (name, status, ("min period %.3f ns (%.0f MHz)" % (tmin, 1000.0 / tmin)) if tmin else reason))
    return 0 if status == "ok" else 1


SENSITIVITY = [(0.0, 0.0), (0.35, 0.15), (1.0, 0.5)]


def sensitivity(name):
    """The minimum period at three settings of the boundary delays, so that the effect of the one assumption in constraints/mlc.sdc
    is a measured figure (written to build/reports/POINT/sensitivity.txt)."""
    spec = POINTS[name]
    net = NETLISTS / (spec["netlist"] + ".v")
    if not net.exists():
        raise SystemExit("sta_run: %s does not exist" % net)
    work_dir = WORK / name / "sta_sens"
    lines = []
    for din, dout in SENSITIVITY:
        rc, text, _, _ = run_sta(net, spec["top"], BASE_PERIOD_NS, work_dir / ("d%g_%g" % (din, dout)), work_dir,
                                 extra_env={"STA_IN_DELAY_NS": str(din), "STA_OUT_DELAY_NS": str(dout)})
        if rc != 0 or log_problems(text):
            raise SystemExit("sta_run: sensitivity run %g/%g failed" % (din, dout))
        info, setup, hold = analyse((work_dir / ("d%g_%g" % (din, dout)) / "timing.txt").read_text(), BASE_PERIOD_NS)
        need = {c: info[c]["need"] for c in CLASSES if c in info}
        lines.append("input %.2f ns, output %.2f ns: min period %.3f ns, worst hold slack %s, per class %s" % (
            din, dout, BASE_PERIOD_NS - setup, ("%.3f" % hold) if hold is not None else "-",
            ", ".join("%s %.3f" % (c, v) for c, v in need.items())))
    (REPORTS / name / "sensitivity.txt").write_text("\n".join(lines) + "\n")
    print("\n".join("%-22s %s" % (name, l) for l in lines))
    return 0


def main(argv):
    if argv[1:] == ["--list"]:
        for n, s in POINTS.items():
            print("%-22s %-8s %s" % (n, "/".join(s["groups"]), s["top"]))
        return 0
    if len(argv) == 3 and argv[1] == "--group":
        names = [n for n, s in POINTS.items() if argv[2] in s["groups"]]
        if not names:
            raise SystemExit("sta_run: no group %s" % argv[2])
        print("\n".join(names))
        return 0
    if len(argv) == 3 and argv[1] == "--sensitivity" and argv[2] in POINTS:
        return sensitivity(argv[2])
    if argv[1:] == ["--selftest"]:
        import sta_selftest
        return sta_selftest.main()
    if len(argv) == 2 and argv[1] in POINTS:
        return run_point(argv[1])
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

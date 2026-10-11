#!/usr/bin/env python3
"""Turn build/reports/<point>/{sta,stat}.txt into build/reports/timing_summary.md (Phase 8, D-041).

Every figure is read from a checked-in report. A point with no sta.txt is listed as NOT YET MEASURED.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sta_run  # noqa: E402
import synth_summary  # noqa: E402

REPORTS = sta_run.REPORTS
CLASSES = sta_run.CLASSES
SUBCLASSES = sta_run.SUBCLASSES
TITLES = [("raw", "Raw netlists of the default flow (`abc -fast`: no buffering, no sizing)"),
          ("timing", "Default configuration, timing-driven mapping"),
          ("timing-compare", "Comparison at 8 KiB (the prediction of 03_microarchitecture.md section 5)")]


def read(path):
    kv = {}
    for line in path.read_text().splitlines():
        k, _, v = line.partition(": ")
        kv[k] = v
    return kv


def row(name):
    spec = sta_run.POINTS[name]
    f = REPORTS / name / "sta.txt"
    if not f.exists():
        return "| %s | %s | NOT YET MEASURED |%s" % (name, spec["top"], " |" * 14)
    kv = read(f)
    if kv["status"] != "ok":
        return "| %s | %s | %s (%s) |%s" % (name, spec["top"], kv["status"], kv["reason"], " |" * 14)
    stat = REPORTS / name / "stat.txt"
    cells = area = ""
    if stat.exists():
        a, c, _, _ = synth_summary.read_stat(stat)
        cells, area = "{:,}".format(c), "{:,.0f}".format(a)
    need = {c: float(kv[c + "_min_period_ns"]) for c in CLASSES if c + "_min_period_ns" in kv}
    worst = max(need, key=need.get)
    cols = [name, spec["top"], "ok", cells, area, kv["min_period_ns"], kv["fmax_mhz"], worst, kv["%s_depth" % worst]]
    cols += [("%.3f" % need[c]) if c in need else "-" for c in CLASSES]
    cols += [kv[c + "_min_period_ns"] if c + "_min_period_ns" in kv else "-" for c in SUBCLASSES]
    reset = ("%s (fan-out %s)" % (kv["reset_unbuffered_min_period_ns"], kv["reset_net_fanout"])) if kv.get("reset_net_fanout", "-") != "-" else "-"
    cols += [reset, kv["worst_hold_slack_ns"], "%.3f" % (float(kv["total_power_w"]) * 1000) if kv["total_power_w"] != "-" else "-"]
    return "| " + " | ".join(cols) + " |"


def fmt_runs(runs):
    return ", ".join("%d (%.2f)" % (n, t) for n, t in runs) if runs else "-"


def timing_points():
    """The timing-driven points that have a successful sta.txt and a timing.txt, as (name, spec, sta.txt as a dict, timing.txt text)."""
    for name, spec in sta_run.POINTS.items():
        f = REPORTS / name / "sta.txt"
        t = REPORTS / name / "timing.txt"
        if "timing" not in spec["groups"] and "timing-compare" not in spec["groups"] or not f.exists() or not t.exists():
            continue
        kv = read(f)
        if kv["status"] == "ok":
            yield name, spec, kv, t.read_text()


def class_paths_table():
    """Per timing-driven point, the start and end point and the depth of the worst path of each class."""
    rows = ["## The worst path of each class", "",
            "Start point -> end point (combinational cells on the path, buffers included). A path from an input to an output is only a",
            "combinational path through the unit: it is not necessarily a cache hit, and its end point says what it is (a downstream request",
            "output, a ready signal, ...). req2resp is the part of it that matters for the hit: the worst path from a request input (`req_*`)",
            "to a response output (`resp_*`), which exists for the four cache controllers. Flip-flop names in the netlists are anonymous",
            "(`_447803_`).", "",
            "| point | " + " | ".join(CLASSES + SUBCLASSES) + " |", "|---|" + "---|" * len(CLASSES + SUBCLASSES)]
    for name, spec, kv, _ in timing_points():
        cells = [("%s -> %s (%s)" % (kv[c + "_path"].split(" -> ")[0], kv[c + "_path"].split(" -> ")[1], kv[c + "_depth"])) if c + "_path" in kv else "-"
                 for c in CLASSES + SUBCLASSES]
        rows.append("| %s | %s |" % (name, " | ".join(cells)))
    return rows + [""]


def composition_table():
    """Per point: the limiting class's worst path split into buffers, multiplexers, other logic and flip-flop clock-to-output."""
    rows = ["## Where the limiting path's time goes", "",
            "The worst path of the limiting class of each timing-driven point, from its `timing.txt`: time in fan-out buffers (`buf` and",
            "`clkbuf` cells), in multiplexers, in other logic, and in the launching flip-flop's clock-to-output (zero for an input path).",
            "The rest of the period is the input delay, the capture flip-flop's setup time and slack. 'buffer runs' lists the runs of",
            "consecutive buffers along the path in path order: (number of buffers, their summed delay in ns). The table says how many",
            "buffers a path contains and how much time they take; it does not say what a run fans out to. The depth counts every",
            "combinational cell on the path, buffers included.", "",
            "| point | limiting class | start -> end | min period (ns) | depth | buffer cells | buffers (ns) | buffer runs: cells (ns) | multiplexers (ns) | other logic (ns) | clock-to-output (ns) |",
            "|---|---|---|---|---|---|---|---|---|---|---|"]
    for name, spec, kv, ttext in timing_points():
        need = {c: float(kv[c + "_min_period_ns"]) for c in CLASSES if c + "_min_period_ns" in kv}
        worst = max(need, key=need.get)
        info, _, _ = sta_run.analyse(ttext, sta_run.BASE_PERIOD_NS)
        buf, mux, other, clkq, nbuf = info[worst]["comp"]
        rows.append("| %s | %s | %s | %s | %s | %d | %.2f | %s | %.2f | %.2f | %.2f |" % (
            name, worst, kv[worst + "_path"].replace(" -> ", " -> "), kv["min_period_ns"], kv[worst + "_depth"], nbuf, buf,
            fmt_runs(info[worst]["runs"]), mux, other, clkq))
    return rows + [""]


def main():
    out = ["# Static timing results (OpenSTA %s, Sky130HD typical corner)" % "2.7.0", "",
           "Generated by `scripts/sta_summary.py` from the `sta.txt` and `stat.txt` of each point. Each unit is analysed alone on one ideal",
           "clock, with an input delay of 0.35 ns, an output delay of 0.15 ns, an `inv_2` driving every input and 0.033442 pF on every",
           "output (`constraints/mlc.sdc`), and no wire parasitics. 'min period' is the smallest clock period at which no setup check",
           "fails: the base period minus the worst setup slack, confirmed by running STA 2% above it (no violation) and 2% below it",
           "(a violation). Paths that start at a reset port are false paths in this figure and are reported in their own column (the",
           "unbuffered period they would need, and the fan-out of the reset net that P&R must buffer; the main figure also gives those",
           "ports an ideal slew, because a false path removes a check and not the slew it would pass on). The four class columns give the",
           "period each class of path needs on its own: register to register, input to register, register to output, and input to output",
           "(a purely combinational path from an input port to an output port; the worst one is not necessarily a cache hit, see the",
           "table of worst paths). req2resp is the part of in2out from the request inputs to the response outputs of a cache controller:",
           "its combinational hit path (PF-01); it is never the limiting class. 'depth' is the number of combinational cells on the worst path of the limiting class, buffers",
           "included. Hold slack is the worst over all hold checks. Power is OpenSTA's static estimate at its default switching",
           "activity, not a simulation-driven figure (PW-01).", ""]
    head = ("| point | module | status | cells | area (um^2) | min period (ns) | Fmax (MHz) | limiting class | depth | reg2reg | in2reg | reg2out | in2out | req2resp "
            "| reset net, unbuffered (ns) | worst hold slack (ns) | power (mW) |")
    sep = "|" + "---|" * 17
    for group, title in TITLES:
        names = [n for n, s in sta_run.POINTS.items() if group in s["groups"]]
        out += ["## " + title, "", head, sep] + [row(n) for n in names] + [""]
    out += class_paths_table() + composition_table()
    text = "\n".join(out)
    (REPORTS / "timing_summary.md").write_text(text)
    print(text)


if __name__ == "__main__":
    main()

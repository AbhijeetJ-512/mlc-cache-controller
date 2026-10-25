#!/usr/bin/env python3
"""doc_snippets.py - extract the figures the design document quotes from the checked-in tool reports into results/*.md.
Nothing is typed by hand: each table is a column selection of a table in build/reports/summary.md or build/reports/timing_summary.md."""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def tables(path):
    """{section title: (header cells, rows)}"""
    out, title, rows = {}, None, []
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith("## "):
            if title and rows:
                out[title] = rows
            title, rows = line[3:].strip(), []
        elif line.startswith("|") and title:
            rows.append([c.strip() for c in line.strip("|").split("|")])
    if title and rows:
        out[title] = rows
    return out


def pick(rows, cols):
    head = rows[0]
    idx = [head.index(c) for c in cols]
    body = [r for r in rows[2:]]
    lines = ["| " + " | ".join(cols) + " |", "|" + "|".join(["---"] * len(cols)) + "|"]
    lines += ["| " + " | ".join(r[i] for i in idx) + " |" for r in body]
    return "\n".join(lines)


syn = tables(os.path.join(ROOT, "build/reports/summary.md"))
sta = tables(os.path.join(ROOT, "build/reports/timing_summary.md"))
os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
open(os.path.join(ROOT, "results/unit_area.md"), "w").write(
    "Synthesis, default configuration (Yosys 0.33, Sky130HD typical corner, `abc -fast`; from `build/reports/summary.md`):\n\n"
    + pick(syn["Default configuration"], ["point", "parameters", "area (um^2)", "cells", "flip-flops", "flip-flop area"]) + "\n")
open(os.path.join(ROOT, "results/unit_timing.md"), "w").write(
    "Static timing, timing-driven mapping, one unit at a time (OpenSTA 2.7.0; from `build/reports/timing_summary.md`):\n\n"
    + pick(sta["Default configuration, timing-driven mapping"],
           ["point", "cells", "area (um^2)", "min period (ns)", "Fmax (MHz)", "limiting class", "depth", "worst hold slack (ns)"]) + "\n\n"
    + "Same flow at 8 KiB (the comparison the microarchitecture document predicted):\n\n"
    + pick(sta["Comparison at 8 KiB (the prediction of 03_microarchitecture.md section 5)"],
           ["point", "cells", "area (um^2)", "min period (ns)", "Fmax (MHz)", "limiting class", "depth", "in2reg", "req2resp"]) + "\n")
print("results/unit_area.md, results/unit_timing.md written")

# system-level test: the summary lines of its checked-in log
log = os.path.join(ROOT, "sim/logs/tb_mlc_top.log")
if os.path.exists(log):
    keep = [l.rstrip() for l in open(log) if re.match(r"^(PASS|INFO|FAIL|tb_mlc_top)", l)]
    open(os.path.join(ROOT, "results/system_test.txt"), "w").write("\n".join(keep) + "\n")
    print("results/system_test.txt written")

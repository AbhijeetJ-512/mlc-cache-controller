#!/usr/bin/env python3
"""Coding rules for rtl/ that close two gaps Yosys leaves open (D-040).

Yosys 0.33 does not warn about an incomplete sensitivity list (SR-03), and the synthesis flow cannot tell a clock gated by
ordinary gates from any other logic (SR-06). Both come from the same few constructs, so the RTL is held to this:

  * combinational logic is `always_comb` (its sensitivity list is derived, so it cannot be incomplete);
  * sequential logic is `always_ff @(posedge clk)` or `always_ff @(posedge clk or negedge <rst_n | async_rst_n>)`, so every
    flip-flop is clocked by the port `clk` and nothing else;
  * no `always_latch` and no plain `always`.

    check_rtl_rules.py             check every .sv file under rtl/
    check_rtl_rules.py --selftest  prove the check rejects each kind of violation
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWED_FF = re.compile(r"always_ff\s*@\s*\(\s*posedge\s+clk(\s+or\s+negedge\s+(rst_n|async_rst_n))?\s*\)")


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def violations(text):
    """[(line number, text)] of every always construct that breaks the rules."""
    text = strip_comments(text)
    bad = []
    for m in re.finditer(r"\balways\w*\b", text):
        line = text.count("\n", 0, m.start()) + 1
        word = m.group(0)
        if word == "always_comb":
            continue
        if word == "always_ff" and ALLOWED_FF.match(text, m.start()):
            continue
        bad.append((line, text[m.start(): m.start() + 60].split("\n")[0]))
    return bad


def selftest():
    good = "always_comb begin y = a; end\nalways_ff @(posedge clk) q <= d;\nalways_ff @(posedge clk or negedge rst_n) q <= d;\n// always @(*) in a comment\n"
    cases = [
        ("clean file", good, False),
        ("plain always @(*)", "always @(*) y = a & b;", True),
        ("plain always @(a)", "always @(a) y = a & b;", True),
        ("always_latch", "always_latch if (en) q = d;", True),
        ("flip-flop on a derived clock", "always_ff @(posedge gclk) q <= d;", True),
        ("flip-flop on the falling edge", "always_ff @(negedge clk) q <= d;", True),
        ("flip-flop with another async signal", "always_ff @(posedge clk or negedge other) q <= d;", True),
    ]
    wrong = [n for n, text, want_bad in cases if bool(violations(text)) != want_bad]
    print("check_rtl_rules selftest: %d cases, %s" % (len(cases), "ok" if not wrong else "WRONG: " + ", ".join(wrong)))
    return 1 if wrong else 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    files = sorted((ROOT / "rtl").rglob("*.sv"))
    total = 0
    for f in files:
        for line, text in violations(f.read_text()):
            print("%s:%d: %s" % (f.relative_to(ROOT), line, text))
            total += 1
    ff = sum(len(re.findall(r"\balways_ff\b", strip_comments(f.read_text()))) for f in files)
    print("rtl rules: %d files, %d always_ff blocks, %d violations" % (len(files), ff, total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

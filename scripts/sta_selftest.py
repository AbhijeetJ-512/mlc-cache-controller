#!/usr/bin/env python3
"""Self-test of the static timing flow (Phase 8, D-041): known answers, and cases that must fail.

  1. a port-to-port feed-through with input delay 1, output delay 2 and period 10 has a setup slack of exactly 7.0 ns
     (the meaning of the SDC commands, units and path groups);
  2. an inverter's delay from OpenSTA equals the one computed here from the liberty tables by bilinear interpolation, for both
     transitions (the liberty is read, in the right units, at the right corner);
  3. the report parser: a canned report with two path groups and a flip-flop in the path gives the right worst slack and logic depth;
  4. through scripts/sta.tcl and constraints/mlc.sdc: a clean netlist is accepted; a netlist with a combinational loop, an SDC
     with no output delay (unconstrained endpoints) and an SDC with no clock are each refused because OpenSTA warns.
"""
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sta_run  # noqa: E402

ROOT, LIB, WORK = sta_run.ROOT, sta_run.LIB, sta_run.WORK
DIR = WORK / "sta_selftest"


def sta_script(netlist, top, commands):
    """Run OpenSTA on a netlist with the given commands after link_design; returns stdout."""
    DIR.mkdir(parents=True, exist_ok=True)
    tcl = DIR / "case.tcl"
    tcl.write_text("read_liberty %s\nread_verilog %s\nlink_design %s\n%s\nexit\n" % (LIB, netlist, top, commands))
    p = subprocess.run(["sta", "-no_splash", "-exit", str(tcl)], capture_output=True, text=True, cwd=ROOT)
    return p.stdout + p.stderr


def arrival(text):
    m = re.search(r"(-?\d+\.\d+)\s+data arrival time", text)
    return float(m.group(1)) if m else None


def feedthrough():
    net = DIR / "ft.v"
    DIR.mkdir(parents=True, exist_ok=True)
    net.write_text("module ft (input a, output y);\n  assign y = a;\nendmodule\n")
    out = sta_script(net, "ft", "create_clock -name clk -period 10\nset_input_delay 1 -clock clk [get_ports a]\n"
                                "set_output_delay 2 -clock clk [get_ports y]\nreport_checks -path_delay max -digits 4")
    m = re.search(r"(-?\d+\.\d+)\s+slack \(MET\)", out)
    got = float(m.group(1)) if m else None
    ok = got is not None and abs(got - 7.0) < 1e-6
    print("sta_selftest %-14s slack %s, expected 7.0000  %s" % ("feedthrough", got, "ok" if ok else "WRONG"))
    return 0 if ok else 1


def liberty_table(cell, kind):
    """(index_1, index_2, values) of the `kind` (cell_rise / cell_fall) table of the first timing arc of the cell's output."""
    text = LIB.read_text()
    start = text.index('cell ("%s")' % cell)
    block = text[start: text.index('\n    cell ("', start + 10)]
    m = re.search(r'%s \("[^"]*"\) \{\s*index_1\s*\("([^"]*)"\);\s*index_2\s*\("([^"]*)"\);\s*values\s*\((.*?)\);\s*\}' % kind, block, re.S)
    floats = lambda s: [float(x) for x in s.replace("\\", " ").replace(",", " ").split()]
    return floats(m.group(1)), floats(m.group(2)), floats(m.group(3).replace('"', " "))


def interpolate(i1, i2, values, x, y):
    n2 = len(i2)

    def bracket(axis, v):
        for k in range(len(axis) - 1):
            if axis[k] <= v <= axis[k + 1]:
                return k
        raise ValueError("%g outside the table" % v)

    a, b = bracket(i1, x), bracket(i2, y)
    tx = (x - i1[a]) / (i1[a + 1] - i1[a])
    ty = (y - i2[b]) / (i2[b + 1] - i2[b])
    v = lambda r, c: values[r * n2 + c]
    return (v(a, b) * (1 - tx) * (1 - ty) + v(a + 1, b) * tx * (1 - ty) + v(a, b + 1) * (1 - tx) * ty + v(a + 1, b + 1) * tx * ty)


def inverter_arc():
    net = DIR / "inv.v"
    net.write_text("module inv (input a, output y);\n  sky130_fd_sc_hd__inv_1 u (.A(a), .Y(y));\nendmodule\n")
    slew, load = 0.05, 0.01
    cmds = ("create_clock -name clk -period 10\nset_input_delay 0 -clock clk [get_ports a]\nset_output_delay 0 -clock clk [get_ports y]\n"
            "set_input_transition %g [get_ports a]\nset_load %g [get_ports y]\n" % (slew, load))
    got = {}
    for kind, rf in (("cell_rise", "rise"), ("cell_fall", "fall")):
        # the path whose output rises (cell_rise) or falls (cell_fall)
        out = sta_script(net, "inv", cmds + "report_checks -path_delay max -digits 5 -%s_to [get_ports y]" % rf)
        got[kind] = arrival(out)
    bad = []
    for kind in ("cell_rise", "cell_fall"):
        i1, i2, vals = liberty_table("sky130_fd_sc_hd__inv_1", kind)
        want = interpolate(i1, i2, vals, slew, load)
        if got[kind] is None or abs(got[kind] - want) > 5e-4:
            bad.append("%s: OpenSTA %s, liberty %.5f" % (kind, got[kind], want))
        else:
            print("sta_selftest %-14s %s OpenSTA %.5f ns, liberty tables %.5f ns  ok" % ("inverter arc", kind, got[kind], want))
    if bad:
        print("sta_selftest %-14s WRONG: %s" % ("inverter arc", "; ".join(bad)))
    return 1 if bad else 0


CANNED = """
=== reg2reg max ===
Startpoint: r1 (rising edge-triggered flip-flop clocked by clk)
Endpoint: r2 (rising edge-triggered flip-flop clocked by clk)
Path Group: clk
Path Type: max

Fanout      Cap     Slew    Delay     Time   Description
---------------------------------------------------------------------------------
     7    0.013    0.136    0.352    0.352 ^ r1/Q (sky130_fd_sc_hd__dfxtp_1)
     1    0.002    0.072    0.443    0.795 v u1/X (sky130_fd_sc_hd__or3b_2)
     1    0.002    0.072    0.100    0.895 ^ u2/Y (sky130_fd_sc_hd__nand2_1)
                   0.044    0.000    0.895 v r2/D (sky130_fd_sc_hd__dfxtp_1)
                                     0.895   data arrival time
                                     9.879   data required time
                                     8.984   slack (MET)

Startpoint: r3 (rising edge-triggered flip-flop clocked by clk)
Endpoint: r4 (rising edge-triggered flip-flop clocked by clk)
Path Group: clk
Path Type: max
     7    0.013    0.136    0.352    0.352 ^ r3/Q (sky130_fd_sc_hd__dfxtp_1)
     1    0.002    0.072    5.800    6.152 v u9/Y (sky130_fd_sc_hd__nand2_1)
                                     6.152   data arrival time
                                     9.652   data required time
                                     3.500   slack (MET)

=== reg2reg min ===
Startpoint: r1 (rising edge-triggered flip-flop clocked by clk)
Endpoint: r2 (rising edge-triggered flip-flop clocked by clk)
Path Group: clk
Path Type: min
                                     0.400   data arrival time
                                     0.250   slack (MET)

=== in2reg max ===
Startpoint: a (input port clocked by clk)
Endpoint: r2 (rising edge-triggered flip-flop clocked by clk)
Path Group: clk
Path Type: max
     1    0.002    0.072    0.443    0.795 v u1/X (sky130_fd_sc_hd__or3b_2)
     1    0.002    0.072    0.100    0.895 ^ u2/Y (sky130_fd_sc_hd__nand2_1)
                                     0.895   data arrival time
                                    -1.250   slack (VIOLATED)
"""


def parser():
    info, setup, hold = sta_run.analyse(CANNED, 10.0)
    r, i = info.get("reg2reg", {}), info.get("in2reg", {})
    # reg2reg has two paths: the worst slack (3.5) belongs to the second, which has one combinational cell; the flip-flops on the path
    # are not counted. in2reg has one path with two combinational cells and a negative slack, so it needs 11.25 ns.
    ok = (r.get("slack") == 3.5 and abs(r.get("need", 0) - 6.5) < 1e-9 and r.get("depth") == 1 and r.get("hold") == 0.25
          and r.get("start") == "r3" and r.get("end") == "r4"
          and i.get("slack") == -1.25 and abs(i.get("need", 0) - 11.25) < 1e-9 and i.get("depth") == 2 and i.get("hold") is None)
    print("sta_selftest %-14s reg2reg slack %s depth %s, in2reg slack %s depth %s  %s" % (
        "parser", r.get("slack"), r.get("depth"), i.get("slack"), i.get("depth"), "ok" if ok else "WRONG"))
    return 0 if ok else 1


def refused():
    """Cases that sta.tcl must refuse (OpenSTA warns), and one that it must accept."""
    DIR.mkdir(parents=True, exist_ok=True)
    clean = DIR / "clean.v"
    clean.write_text("module clean (input clk, input a, output q);\n  wire n;\n  sky130_fd_sc_hd__inv_1 g (.A(a), .Y(n));\n"
                     "  sky130_fd_sc_hd__dfxtp_1 f (.CLK(clk), .D(n), .Q(q));\nendmodule\n")
    loop = DIR / "loop.v"
    loop.write_text("module loopy (input clk, input a, output q);\n  wire n1, n2;\n"
                    "  sky130_fd_sc_hd__nand2_1 g1 (.A(a), .B(n2), .Y(n1));\n  sky130_fd_sc_hd__nand2_1 g2 (.A(a), .B(n1), .Y(n2));\n"
                    "  sky130_fd_sc_hd__dfxtp_1 f (.CLK(clk), .D(n1), .Q(q));\nendmodule\n")
    no_out = DIR / "no_out.sdc"
    no_out.write_text("create_clock -name clk -period $::env(STA_PERIOD_NS) [get_ports clk]\n"
                      "set_input_delay 0.35 -clock clk [get_ports a]\n")
    no_clk = DIR / "no_clk.sdc"
    no_clk.write_text("set_input_delay 0.35 -clock clk [get_ports a]\nset_output_delay 0.15 -clock clk [get_ports q]\n")
    cases = [("clean", clean, "clean", sta_run.SDC, True), ("combinational loop", loop, "loopy", sta_run.SDC, False),
             ("unconstrained output", clean, "clean", no_out, False), ("no clock", clean, "clean", no_clk, False)]
    failures = 0
    for name, net, top, sdc, accept in cases:
        out_dir = DIR / ("out_" + name.replace(" ", "_"))
        rc, text, _, _ = sta_run.run_sta(net, top, 10.0, out_dir, DIR, sdc=sdc)
        problems = sta_run.log_problems(text)
        accepted = rc == 0 and not problems
        ok = accepted == accept
        print("sta_selftest %-14s %-9s %s %s" % (name, "accepted" if accepted else "refused", "ok" if ok else "WRONG",
                                                 ("(" + problems[0].strip()[:70] + ")") if problems else ""))
        failures += not ok
    return failures


def bracket():
    """The 2% bracket accepts the true minimum period and refuses a wrong one (too large: nothing fails below it)."""
    net = DIR / "clean.v"
    out_dir = DIR / "out_bracket"
    rc, text, _, _ = sta_run.run_sta(net, "clean", 10.0, out_dir, DIR)
    _, setup, _ = sta_run.analyse((out_dir / "timing.txt").read_text(), 10.0)
    tmin = 10.0 - setup
    good, _, _ = sta_run.bracket_check(net, "clean", tmin, DIR)
    bad_high, _, _ = sta_run.bracket_check(net, "clean", tmin * 2, DIR)
    bad_low, _, _ = sta_run.bracket_check(net, "clean", tmin * 0.5, DIR)
    ok = good and not bad_high and not bad_low
    print("sta_selftest %-14s true minimum %.3f ns accepted: %s; twice it refused: %s; half of it refused: %s  %s" % (
        "bracket", tmin, good, not bad_high, not bad_low, "ok" if ok else "WRONG"))
    return 0 if ok else 1


def reset_ports():
    """A path that starts at rst_n is absent from the main analysis (false path) and present in the reset-only one."""
    net = DIR / "withreset.v"
    net.write_text("module withreset (input clk, input rst_n, input a, output q);\n"
                   "  sky130_fd_sc_hd__dfrtp_1 f (.CLK(clk), .D(a), .RESET_B(rst_n), .Q(q));\nendmodule\n")
    main_dir, reset_dir = DIR / "out_reset_main", DIR / "out_reset_only"
    rc1, t1, _, _ = sta_run.run_sta(net, "withreset", 10.0, main_dir, DIR)
    rc2, t2, _, _ = sta_run.run_sta(net, "withreset", 10.0, reset_dir, DIR, extra_env={"STA_RESET_ONLY": "1", "STA_RESET_FALSE_PATH": "0"})
    main_txt = (main_dir / "timing.txt").read_text()
    reset_txt = (reset_dir / "timing.txt").read_text()
    ok = (rc1 == 0 and rc2 == 0 and not sta_run.log_problems(t1) and not sta_run.log_problems(t2)
          and "Startpoint: rst_n" not in main_txt and "Startpoint: rst_n" in reset_txt and "recovery check" in reset_txt)
    print("sta_selftest %-14s main analysis has rst_n paths: %s; reset-only analysis has them: %s  %s" % (
        "reset ports", "Startpoint: rst_n" in main_txt, "Startpoint: rst_n" in reset_txt, "ok" if ok else "WRONG"))
    # a module like reset_sync, whose output port is called rst_n and whose input is async_rst_n: the output is not a start point
    rs = DIR / "rsync.v"
    rs.write_text("module rsync (input clk, input async_rst_n, output rst_n);\n  wire q1;\n"
                  "  sky130_fd_sc_hd__dfrtp_1 f1 (.CLK(clk), .D(1'b1), .RESET_B(async_rst_n), .Q(q1));\n"
                  "  sky130_fd_sc_hd__dfrtp_1 f2 (.CLK(clk), .D(q1), .RESET_B(async_rst_n), .Q(rst_n));\nendmodule\n")
    rc3, t3, _, _ = sta_run.run_sta(rs, "rsync", 10.0, DIR / "out_rsync", DIR)
    rc4, t4, _, _ = sta_run.run_sta(rs, "rsync", 10.0, DIR / "out_rsync_reset", DIR, extra_env={"STA_RESET_ONLY": "1", "STA_RESET_FALSE_PATH": "0"})
    ok2 = rc3 == 0 and rc4 == 0 and not sta_run.log_problems(t3) and not sta_run.log_problems(t4)
    print("sta_selftest %-14s an output port named rst_n is not taken as a reset start point  %s" % ("reset output", "ok" if ok2 else "WRONG: " + str(sta_run.log_problems(t3 + t4)[:1])))
    return 0 if ok and ok2 else 1


def main():
    failures = feedthrough() + inverter_arc() + parser() + refused() + bracket() + reset_ports()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

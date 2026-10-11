#!/usr/bin/env python3
"""Self-test of the static timing flow (Phase 8, D-041): known answers, and cases that must fail.

  1. a port-to-port feed-through with input delay 1, output delay 2 and period 10 has a setup slack of exactly 7.0 ns
     (the meaning of the SDC commands and of the path groups);
  2. an inverter's delay from OpenSTA equals the one computed here from the liberty tables by bilinear interpolation, for both
     transitions (the liberty is read, in the right units, at the right corner);
  3. the constraints the project's own SDC applies, read back with `write_sdc`: 0.35 ns in, 0.15 ns out, an inv_2 on every data input,
     0.033442 pF on every output, a false path from the reset ports, an ideal slew on them in the main analysis, the unbuffered drive in
     the reset-only analysis; the same constants in abc_speed.constr; and the effect of those delays and the drive in an OpenSTA report;
  4. the classes of path of scripts/sta.tcl (the four disjoint ones and req2resp, the request-to-response part of in2out), on a
     netlist in which each class has one path with known start, end and depth;
  5. the reset classes, on a netlist in which the reset port also feeds logic and an output, and on a module whose reset input is
     called async_rst_n and whose output port is called rst_n;
  6. a reset net with many loads leaves a data path unchanged in the main analysis (finding F1 of the review: a false path does not
     remove the slew) and changes it in an analysis where the port is driven by a cell (the control that shows the test can fail);
  7. the report parser on canned reports: two path groups, a flip-flop in a path, the split of a path's time into buffers, multiplexers,
     other logic and clock-to-output, the reset net's fan-out, the agreement of the classes with the overall report;
  8. a clean netlist is accepted; a netlist with a combinational loop, an SDC with no output delay and an SDC with no clock are each
     refused because OpenSTA warns;
  9. the 2% bracket accepts the true minimum period and refuses half and twice of it;
 10. a netlist older than one of its inputs is called stale, and sta_run refuses it;
 11. sta_run.measure, the function behind every report, accepts the classes netlist with a consistent minimum period and a bracket that
     holds, and fails on the netlist with a loop.
"""
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sta_run  # noqa: E402
import synth_run  # noqa: E402

ROOT, LIB, WORK = sta_run.ROOT, sta_run.LIB, sta_run.WORK
DIR = WORK / "sta_selftest"
CELL = "sky130_fd_sc_hd__"


def verdict(name, ok, detail):
    print("sta_selftest %-14s %s  %s" % (name, detail, "ok" if ok else "WRONG"))
    return 0 if ok else 1


def sta_script(netlist, top, commands, sdc=False, env=None):
    """Run OpenSTA on a netlist with the given commands after link_design (and, with sdc, after the project's SDC); returns stdout."""
    DIR.mkdir(parents=True, exist_ok=True)
    tcl = DIR / "case.tcl"
    tcl.write_text("read_liberty %s\nread_verilog %s\nlink_design %s\n%s%s\nexit\n" % (
        LIB, netlist, top, ("source %s\n" % sta_run.SDC) if sdc else "", commands))
    environment = dict(os.environ, STA_PERIOD_NS="10")
    environment.update(env or {})
    p = subprocess.run(["sta", "-no_splash", "-exit", str(tcl)], capture_output=True, text=True, cwd=ROOT, env=environment)
    return p.stdout + p.stderr


def arrival(text):
    m = re.search(r"(-?\d+\.\d+)\s+data arrival time", text)
    return float(m.group(1)) if m else None


def write_net(name, text):
    DIR.mkdir(parents=True, exist_ok=True)
    f = DIR / name
    f.write_text(text)
    return f


# --- 1 ------------------------------------------------------------------------------------------------------------------------

def feedthrough():
    net = write_net("ft.v", "module ft (input a, output y);\n  assign y = a;\nendmodule\n")
    out = sta_script(net, "ft", "create_clock -name clk -period 10\nset_input_delay 1 -clock clk [get_ports a]\n"
                                "set_output_delay 2 -clock clk [get_ports y]\nreport_checks -path_delay max -digits 4")
    m = re.search(r"(-?\d+\.\d+)\s+slack \(MET\)", out)
    got = float(m.group(1)) if m else None
    return verdict("feedthrough", got is not None and abs(got - 7.0) < 1e-6, "slack %s, expected 7.0000" % got)


# --- 2 ------------------------------------------------------------------------------------------------------------------------

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
    net = write_net("inv.v", "module inv (input a, output y);\n  %sinv_1 u (.A(a), .Y(y));\nendmodule\n" % CELL)
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
        i1, i2, vals = liberty_table(CELL + "inv_1", kind)
        want = interpolate(i1, i2, vals, slew, load)
        if got[kind] is None or abs(got[kind] - want) > 5e-4:
            bad.append("%s: OpenSTA %s, liberty %.5f" % (kind, got[kind], want))
        else:
            print("sta_selftest %-14s %s OpenSTA %.5f ns, liberty tables %.5f ns  ok" % ("inverter arc", kind, got[kind], want))
    if bad:
        print("sta_selftest %-14s WRONG: %s" % ("inverter arc", "; ".join(bad)))
    return 1 if bad else 0


# --- 3 ------------------------------------------------------------------------------------------------------------------------

PORT = r"\[get_ports \{(\w+)\}\]"


def parse_sdc(text):
    """The commands of a `write_sdc` file that matter here, as a dict of port -> value."""
    text = text.replace("\\\n", " ")
    got = dict(period=None, in_delay={}, out_delay={}, load={}, drive={}, transition={}, false_from=[])
    for line in text.splitlines():
        line = " ".join(line.split())
        m = re.match(r"create_clock -name clk -period (\S+)", line)
        if m:
            got["period"] = float(m.group(1))
        m = re.match(r"set_input_delay (\S+) .*" + PORT, line)
        if m:
            got["in_delay"][m.group(2)] = float(m.group(1))
        m = re.match(r"set_output_delay (\S+) .*" + PORT, line)
        if m:
            got["out_delay"][m.group(2)] = float(m.group(1))
        m = re.match(r"set_load -pin_load (\S+) " + PORT, line)
        if m:
            got["load"][m.group(2)] = float(m.group(1))
        m = re.match(r"set_driving_cell -lib_cell (\S+) .*" + PORT, line)
        if m:
            got["drive"][m.group(2)] = m.group(1)
        m = re.match(r"set_input_transition (\S+) " + PORT, line)
        if m:
            got["transition"][m.group(2)] = float(m.group(1))
        m = re.match(r"set_false_path -from " + PORT, line)
        if m:
            got["false_from"].append(m.group(1))
    return got


def sdc_constants():
    """What constraints/mlc.sdc applies, read back with write_sdc, in the main analysis and in the reset-only one."""
    net = write_net("cst.v", "module cst (input clk, input rst_n, input a, output q, output y);\n  wire n;\n"
                             "  %snand2_1 g (.A(a), .B(rst_n), .Y(n));\n  %sdfrtp_1 f (.CLK(clk), .D(n), .RESET_B(rst_n), .Q(q));\n"
                             "  %sinv_1 i (.A(q), .Y(y));\nendmodule\n" % (CELL, CELL, CELL))
    failures = 0
    cases = (("main", {}, dict(drive={"a"}, transition={"rst_n"}, false_from=["rst_n"])),
             ("reset-only", {"STA_RESET_FALSE_PATH": "0"}, dict(drive={"a", "rst_n"}, transition=set(), false_from=[])))
    for name, env, want in cases:
        sdc_file = DIR / ("written_%s.sdc" % name.replace("-", "_"))
        sta_script(net, "cst", "write_sdc -digits 6 -no_timestamp %s" % sdc_file, sdc=True, env=env)
        got = parse_sdc(sdc_file.read_text()) if sdc_file.exists() else parse_sdc("")
        problems = []
        if got["period"] != 10.0:
            problems.append("clock period %s" % got["period"])
        if got["in_delay"] != {"a": sta_run.IN_DELAY_NS, "rst_n": sta_run.IN_DELAY_NS}:
            problems.append("input delays %s" % got["in_delay"])
        if got["out_delay"] != {"q": sta_run.OUT_DELAY_NS, "y": sta_run.OUT_DELAY_NS}:
            problems.append("output delays %s" % got["out_delay"])
        if got["load"] != {"q": sta_run.LOAD_PF, "y": sta_run.LOAD_PF}:
            problems.append("loads %s" % got["load"])
        if got["drive"] != {p: CELL + "inv_2" for p in want["drive"]} or sta_run.DRIVE_CELL != CELL + "inv_2":
            problems.append("driving cells %s" % got["drive"])
        if set(got["transition"]) != want["transition"] or any(v != 0.0 for v in got["transition"].values()):
            problems.append("input transitions %s" % got["transition"])
        if got["false_from"] != want["false_from"]:
            problems.append("false paths from %s" % got["false_from"])
        failures += verdict("sdc " + name, not problems, "write_sdc: %s" % ("; ".join(problems) if problems else
                            "10 ns clock, 0.35/0.15 ns, inv_2 on %s, 0.033442 pF, false path from %s, ideal slew on %s" % (
                                sorted(want["drive"]), want["false_from"] or "nothing", sorted(want["transition"]) or "nothing")))
    # the timing-driven mapping assumes the same boundary
    constr = (ROOT / "scripts" / "abc_speed.constr").read_text()
    m_drive = re.search(r"^set_driving_cell (\S+)", constr, re.M)
    m_load = re.search(r"^set_load (\S+)", constr, re.M)
    ok = bool(m_drive and m_load) and m_drive.group(1) == sta_run.DRIVE_CELL and float(m_load.group(1)) == sta_run.LOAD_PF
    failures += verdict("abc constr", ok, "abc_speed.constr drives with %s and loads %s pF" % (m_drive and m_drive.group(1), m_load and m_load.group(1)))
    # the effect in a report (units and the driving cell): a feed-through under the project's own SDC
    ft = write_net("ftp.v", "module ftp (input a, output y);\n  assign y = a;\nendmodule\n")
    out = sta_script(ft, "ftp", "report_checks -path_delay max -digits 4", sdc=True)
    m_in = re.search(r"(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(?:[\^v]\s+)?input external delay", out)
    m_out = re.search(r"(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(?:[\^v]\s+)?output external delay", out)
    m_port = re.search(r"(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+[\^v]\s+a \(in\)", out)
    ok = (bool(m_in and m_out and m_port) and abs(float(m_in.group(1)) - 0.35) < 1e-9 and abs(float(m_out.group(1)) + 0.15) < 1e-9
          and 0.005 < float(m_port.group(1)) < 0.2)
    failures += verdict("sdc report", ok, "feed-through under mlc.sdc: input delay %s, output delay %s, delay of the input's driving cell %s" % (
        m_in and m_in.group(1), m_out and m_out.group(1), m_port and m_port.group(1)))
    return failures


# --- 4 ------------------------------------------------------------------------------------------------------------------------

def inverters(prefix, src, n, dst):
    """A chain of n inverters from net src to net dst, as netlist text."""
    nets = [src] + ["%s_n%d" % (prefix, k) for k in range(1, n)] + [dst]
    wires = "".join("  wire %s;\n" % w for w in nets[1:-1])
    gates = "".join("  %sinv_1 %s%d (.A(%s), .Y(%s));\n" % (CELL, prefix, k + 1, nets[k], nets[k + 1]) for k in range(n))
    return wires + gates


def classes():
    """The four classes of path of sta.tcl on a netlist whose every class has a known start point, end point and depth."""
    text = ("module cls (input clk, input a, input b, input c, input req_a, output q_r2o, output y_io, output resp_y, output dn_y, output resp_z);\n"
            "  wire r1q, r1d, r2d, r3d, r4q, r4d;\n"
            "  %sdfxtp_1 r1 (.CLK(clk), .D(c), .Q(r1q));\n" % CELL
            + inverters("gr", "r1q", 4, "r2d")                        # reg2reg: r1 -> 4 inverters -> r2
            + "  %sdfxtp_1 r2 (.CLK(clk), .D(r2d), .Q());\n" % CELL
            + inverters("ga", "a", 3, "r3d")                          # in2reg: a -> 3 inverters -> r3
            + "  %sdfxtp_1 r3 (.CLK(clk), .D(r3d), .Q());\n" % CELL
            + "  %sdfxtp_1 r4 (.CLK(clk), .D(c), .Q(r4q));\n" % CELL
            + inverters("go", "r4q", 2, "q_r2o")                      # reg2out: r4 -> 2 inverters -> q_r2o
            + inverters("gy", "b", 3, "y_io")
            + inverters("gd", "req_a", 4, "dn_y")                     # in2out: req_a -> 4 inverters -> dn_y, the worst input-to-output path
            + inverters("gq", "req_a", 1, "resp_y")                   # req2resp: req_a -> 1 inverter -> resp_y
            + inverters("gz", "b", 2, "resp_z")                       # b is not a request input: this path to a response output is not in req2resp
            + "endmodule\n")
    net = write_net("cls.v", text)
    out_dir = DIR / "out_classes"
    rc, log, _, _ = sta_run.run_sta(net, "cls", 10.0, out_dir, DIR)
    info, setup, _ = sta_run.analyse((out_dir / "timing.txt").read_text(), 10.0)
    want = {"reg2reg": ("r1", "r2", 4), "in2reg": ("a", "r3", 3), "reg2out": ("r4", "q_r2o", 2), "in2out": ("req_a", "dn_y", 4),
            "req2resp": ("req_a", "resp_y", 1)}
    bad = []
    for cls, (start, end, depth) in want.items():
        i = info.get(cls)
        if not i or (i["start"], i["end"], i["depth"]) != (start, end, depth):
            bad.append("%s: %s" % (cls, (i["start"], i["end"], i["depth"]) if i else "no path"))
    if rc != 0 or sta_run.log_problems(log):
        bad.append("sta printed %s" % sta_run.log_problems(log)[:1])
    mismatch = sta_run.class_consistency(info, 10.0 - setup) if setup is not None and info else "no result"
    if mismatch:
        bad.append(mismatch)
    return verdict("classes", not bad, "reg2reg r1->r2 depth 4, in2reg a->r3 depth 3, reg2out r4->q_r2o depth 2, in2out req_a->dn_y depth 4, "
                   "req2resp req_a->resp_y depth 1 (not b->resp_z, not req_a->dn_y)%s" % (("; WRONG: " + "; ".join(bad)) if bad else ""))


def end_to_end():
    """sta_run.measure, the function behind every report, on the classes netlist (accepted: its figures are internally consistent and
    its 2% bracket holds) and on a netlist with a combinational loop (refused)."""
    net, loop = DIR / "cls.v", DIR / "loop.v"
    if not net.exists() or not loop.exists():
        raise SystemExit("sta_selftest: end_to_end needs the netlists written by classes() and refused()")
    m = sta_run.measure(net, "cls", DIR / "out_measure", DIR / "work_measure")
    need = max(i["need"] for i in m["info"].values()) if m["info"] else None
    ok = (m["status"] == "ok" and m["tmin"] is not None and need is not None and abs(m["tmin"] - need) < 1e-3 and 0.5 < m["tmin"] < 5.0
          and "worst setup slack" in m["bracket"] and "WRONG" not in m["bracket"])
    bad = sta_run.measure(loop, "loopy", DIR / "out_measure_loop", DIR / "work_measure")
    refused_ok = bad["status"] == "failed" and bad["tmin"] is None and "sta printed" in bad["reason"]
    # fault injection: class results that disagree with the overall report by 1 ns must be refused
    real = sta_run.analyse

    def skewed(text, period, classes=sta_run.CLASSES):
        info, setup, hold = real(text, period, classes)
        for i in info.values():
            i["need"] += 1.0
        return info, setup, hold

    sta_run.analyse = skewed
    try:
        skew = sta_run.measure(net, "cls", DIR / "out_measure_skew", DIR / "work_measure")
    finally:
        sta_run.analyse = real
    skew_ok = skew["status"] == "failed" and "worst class needs" in skew["reason"]
    return verdict("end to end", ok and refused_ok and skew_ok, "measure(): classes netlist status %s, minimum period %s ns equals its worst class, "
                   "bracket %s; loop netlist %s; classes 1 ns off the overall report %s" % (
                       m["status"], "%.3f" % m["tmin"] if m["tmin"] is not None else None, "holds" if ok else "does not hold", bad["status"],
                       skew["status"]))


# --- 5 ------------------------------------------------------------------------------------------------------------------------

def rstmix_netlist(extra):
    loads = "".join("  %sdfrtp_1 e%d (.CLK(clk), .D(1'b0), .RESET_B(rst_n), .Q());\n" % (CELL, k) for k in range(extra))
    return ("module rstmix (input clk, input rst_n, input a, output q_f, output q_g, output ro);\n  wire nd;\n"
            "  %sdfrtp_1 f (.CLK(clk), .D(a), .RESET_B(rst_n), .Q(q_f));\n"
            "  %snand2_1 gn (.A(a), .B(rst_n), .Y(nd));\n"
            "  %sdfxtp_1 g (.CLK(clk), .D(nd), .Q(q_g));\n"
            "  %snand2_1 gro (.A(rst_n), .B(q_f), .Y(ro));\n" % (CELL, CELL, CELL, CELL) + loads + "endmodule\n")


def reset_ports():
    """Paths that start at a reset port: absent from the main analysis, present and told apart in the reset-only one. The output ro
    also depends on a flip-flop, otherwise its only path would be a false path and OpenSTA would call the endpoint unconstrained.
    With 300 more flip-flops on the reset net its slew is large enough that the recovery check is worse than the data path from
    rst_n, the case in which a reset_data class that included the asynchronous pins would report the recovery check (finding F8)."""
    net = write_net("rstmix.v", rstmix_netlist(300))
    main_dir, reset_dir = DIR / "out_reset_main", DIR / "out_reset_only"
    rc1, t1, _, _ = sta_run.run_sta(net, "rstmix", 10.0, main_dir, DIR)
    rc2, t2, _, _ = sta_run.run_sta(net, "rstmix", 10.0, reset_dir, DIR, extra_env={"STA_RESET_ONLY": "1", "STA_RESET_FALSE_PATH": "0"})
    main_txt = (main_dir / "timing.txt").read_text()
    reset_txt = (reset_dir / "timing.txt").read_text()
    reset = sta_run.analyse_reset(reset_txt)
    flops = {"f"} | {"e%d" % k for k in range(300)}
    want = {"reset_async": ("rst_n", flops, 0), "reset_data": ("rst_n", {"g"}, 1), "reset2out": ("rst_n", {"ro"}, 1)}
    bad = []
    for cls, (start, ends, depth) in want.items():
        i = reset.get(cls)
        if not i or (i["start"], i["end"] in ends, i["depth"], i["fanout"]) != (start, True, depth, 303):
            bad.append("%s: %s" % (cls, (i["start"], i["end"], i["depth"], i["fanout"]) if i else "no path"))
    if not bad and not reset["reset_async"]["slack"] < reset["reset_data"]["slack"]:
        bad.append("the recovery check is not worse than the data path, so the test cannot tell the classes apart")
    if rc1 or rc2 or sta_run.log_problems(t1) or sta_run.log_problems(t2):
        bad.append("sta printed %s" % (sta_run.log_problems(t1 + t2)[:1]))
    if "Startpoint: rst_n" in main_txt:
        bad.append("the main analysis has a path from rst_n")
    if "recovery check" not in reset_txt:
        bad.append("the reset-only analysis has no recovery check")
    failures = verdict("reset ports", not bad, "none from rst_n in the main analysis; reset-only: async rst_n->a reset pin, data rst_n->g (1 cell), "
                       "output rst_n->ro (1 cell), fan-out 303, recovery worse than the data path%s" % (("; WRONG: " + "; ".join(bad)) if bad else ""))
    # a module like reset_sync: its reset INPUT is async_rst_n and its OUTPUT port is called rst_n, which is not a start point
    rs = write_net("rsync.v", "module rsync (input clk, input async_rst_n, output rst_n);\n  wire q1;\n"
                              "  %sdfrtp_1 f1 (.CLK(clk), .D(1'b1), .RESET_B(async_rst_n), .Q(q1));\n"
                              "  %sdfrtp_1 f2 (.CLK(clk), .D(q1), .RESET_B(async_rst_n), .Q(rst_n));\nendmodule\n" % (CELL, CELL))
    rc3, t3, _, _ = sta_run.run_sta(rs, "rsync", 10.0, DIR / "out_rsync", DIR)
    rc4, t4, _, _ = sta_run.run_sta(rs, "rsync", 10.0, DIR / "out_rsync_reset", DIR, extra_env={"STA_RESET_ONLY": "1", "STA_RESET_FALSE_PATH": "0"})
    m_txt = (DIR / "out_rsync" / "timing.txt").read_text()
    r_txt = (DIR / "out_rsync_reset" / "timing.txt").read_text()
    ok = (rc3 == 0 and rc4 == 0 and not sta_run.log_problems(t3 + t4) and "Startpoint: async_rst_n" not in m_txt
          and "Startpoint: async_rst_n" in r_txt and "Startpoint: rst_n" not in m_txt + r_txt)
    failures += verdict("reset input", ok, "async_rst_n is a reset start point (false path in the main analysis, a path in the reset-only one); "
                        "the output port rst_n is not")
    return failures


# --- 6 ------------------------------------------------------------------------------------------------------------------------

def slew_netlist(extra):
    loads = "".join("  %sdfrtp_1 e%d (.CLK(clk), .D(1'b0), .RESET_B(rst_n), .Q());\n" % (CELL, k) for k in range(extra))
    return ("module slw (input clk, input rst_n, input a, output q);\n  wire n, m;\n"
            "  %snand2_1 g (.A(a), .B(rst_n), .Y(n));\n  %sinv_1 h (.A(n), .Y(m));\n"
            "  %sdfrtp_1 f (.CLK(clk), .D(m), .RESET_B(rst_n), .Q(q));\n" % (CELL, CELL, CELL) + loads + "endmodule\n")


def slew_isolation():
    """The arrival of a data path through a gate that also takes rst_n must not depend on how many loads rst_n has."""
    few = write_net("slw_few.v", slew_netlist(0))
    many = write_net("slw_many.v", slew_netlist(300))
    cmd = "report_checks -path_delay max -from [get_ports a] -through [get_pins g/Y] -to [get_pins f/D] -digits 5"
    got = {}
    for label, env in (("main", {}), ("driven", {"STA_RESET_FALSE_PATH": "0"})):
        got[label] = (arrival(sta_script(few, "slw", cmd, sdc=True, env=env)), arrival(sta_script(many, "slw", cmd, sdc=True, env=env)))
    same = all(v is not None for v in got["main"]) and abs(got["main"][0] - got["main"][1]) < 1e-9
    differs = all(v is not None for v in got["driven"]) and abs(got["driven"][0] - got["driven"][1]) > 1e-3
    return verdict("slew isolation", same and differs,
                   "arrival at f/D with 1 and 301 loads on rst_n: main analysis %s and %s ns (must be equal), reset port driven by a cell %s and %s ns "
                   "(must differ)" % (got["main"] + got["driven"]))


# --- 7 ------------------------------------------------------------------------------------------------------------------------

CANNED = """
=== overall max ===
Startpoint: r1 (rising edge-triggered flip-flop clocked by clk)
Endpoint: r2 (rising edge-triggered flip-flop clocked by clk)
Path Group: clk
Path Type: max
                                     5.250   slack (MET)

Startpoint: rst_n (input port clocked by clk)
Endpoint: f (recovery check against rising-edge clock clk)
Path Group: asynchronous
Path Type: max
                                     2.125   slack (MET)

=== overall min ===
Startpoint: r1 (rising edge-triggered flip-flop clocked by clk)
Endpoint: r2 (rising edge-triggered flip-flop clocked by clk)
Path Group: clk
Path Type: min
                                     0.500   slack (MET)

Startpoint: rst_n (input port clocked by clk)
Endpoint: f (removal check against rising-edge clock clk)
Path Group: asynchronous
Path Type: min
                                     0.200   slack (MET)

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

# a path with every kind of cell: a flip-flop, two fan-out buffers, three multiplexers, two other gates
COMPOSITION = """Startpoint: r1 (rising edge-triggered flip-flop clocked by clk)
Endpoint: r9 (rising edge-triggered flip-flop clocked by clk)
Path Group: clk
Path Type: max

Fanout      Cap     Slew    Delay     Time   Description
---------------------------------------------------------------------------------
    10    0.020    0.200    0.350    0.350 ^ r1/Q (sky130_fd_sc_hd__dfxtp_1)
    10    0.020    0.200    0.200    0.550 ^ b1/X (sky130_fd_sc_hd__buf_4)
    10    0.020    0.200    0.300    0.850 ^ b2/X (sky130_fd_sc_hd__clkbuf_2)
     1    0.010    0.100    0.500    1.350 v m1/X (sky130_fd_sc_hd__mux4_1)
     1    0.010    0.100    0.400    1.750 ^ m2/X (sky130_fd_sc_hd__mux2_1)
     1    0.010    0.100    0.250    2.000 v m3/Y (sky130_fd_sc_hd__mux2i_1)
     1    0.010    0.100    0.100    2.100 ^ u1/Y (sky130_fd_sc_hd__nand2_1)
     1    0.010    0.100    0.120    2.220 v u2/X (sky130_fd_sc_hd__o21a_1)
                   0.044    0.000    2.220 v r9/D (sky130_fd_sc_hd__dfxtp_1)
                                     2.220   data arrival time
"""

# buffers in three runs, separated by gates: 2 (0.2 ns), 1 (0.2 ns), 3 (0.3 ns)
RUNS = """Startpoint: a (input port clocked by clk)
Endpoint: r9 (rising edge-triggered flip-flop clocked by clk)
Path Group: clk
Path Type: max

Fanout      Cap     Slew    Delay     Time   Description
---------------------------------------------------------------------------------
    10    0.020    0.200    0.100    0.100 ^ b1/X (sky130_fd_sc_hd__buf_4)
    10    0.020    0.200    0.100    0.200 ^ b2/X (sky130_fd_sc_hd__buf_2)
     1    0.010    0.100    0.100    0.300 v u1/Y (sky130_fd_sc_hd__nand2_1)
    10    0.020    0.200    0.200    0.500 ^ b3/X (sky130_fd_sc_hd__clkbuf_4)
     1    0.010    0.100    0.300    0.800 v m1/X (sky130_fd_sc_hd__mux4_1)
    10    0.020    0.200    0.100    0.900 ^ b4/X (sky130_fd_sc_hd__buf_1)
    10    0.020    0.200    0.100    1.000 ^ b5/X (sky130_fd_sc_hd__buf_1)
    10    0.020    0.200    0.100    1.100 ^ b6/X (sky130_fd_sc_hd__buf_1)
                   0.044    0.000    1.100 v r9/D (sky130_fd_sc_hd__dfxtp_1)
                                     1.100   data arrival time
"""

RESET_BLOCK = """Startpoint: rst_n (input port clocked by clk)
Endpoint: f (recovery check against rising-edge clock clk)
Path Group: asynchronous
Path Type: max

Fanout      Cap     Slew    Delay     Time   Description
---------------------------------------------------------------------------------
  1796    0.512    3.410    0.000    0.350 ^ rst_n (in)
"""


def parser():
    """The report parser on canned reports."""
    failures = 0
    info, setup, hold = sta_run.analyse(CANNED, 10.0)
    r, i = info.get("reg2reg", {}), info.get("in2reg", {})
    # reg2reg has two paths: the worst slack (3.5) belongs to the second, which has one combinational cell; the flip-flops on the path
    # are not counted. in2reg has one path with two combinational cells and a negative slack, so it needs 11.25 ns.
    ok = (r.get("slack") == 3.5 and abs(r.get("need", 0) - 6.5) < 1e-9 and r.get("depth") == 1 and r.get("hold") == 0.25
          and r.get("start") == "r3" and r.get("end") == "r4"
          and i.get("slack") == -1.25 and abs(i.get("need", 0) - 11.25) < 1e-9 and i.get("depth") == 2 and i.get("hold") is None)
    failures += verdict("parser", ok, "reg2reg slack %s depth %s, in2reg slack %s depth %s" % (r.get("slack"), r.get("depth"), i.get("slack"), i.get("depth")))
    # two path groups in the overall reports: the worst setup and the worst hold slack are the smaller of each pair, not the clk group's
    failures += verdict("overall", setup == 2.125 and hold == 0.2, "worst of two path groups: setup %s (expected 2.125), hold %s (expected 0.2)" % (setup, hold))
    # the split of a path's time
    buf, mux, other, clkq, nbuf = sta_run.composition(COMPOSITION)
    got = (round(buf, 6), round(mux, 6), round(other, 6), round(clkq, 6), nbuf, sta_run.logic_depth(COMPOSITION))
    want = (0.5, 1.15, 0.22, 0.35, 2, 7)
    failures += verdict("composition", got == want, "buffers %.2f, multiplexers %.2f, other %.2f, clock-to-output %.2f ns, %d buffers, depth %d "
                        "(expected %s)" % (got + (want,)))
    # runs of consecutive buffers
    runs = [(n, round(t, 6)) for n, t in sta_run.buffer_runs(RUNS)]
    flop_first = [(n, round(t, 6)) for n, t in sta_run.buffer_runs(COMPOSITION)]
    failures += verdict("buffer runs", runs == [(2, 0.2), (1, 0.2), (3, 0.3)] and flop_first == [(2, 0.5)],
                        "runs %s (expected 2 buffers 0.2 ns, 1 buffer 0.2 ns, 3 buffers 0.3 ns); after a flip-flop %s" % (runs, flop_first))
    # the reset net's fan-out
    fo = sta_run.reset_fanout(RESET_BLOCK)
    failures += verdict("reset fan-out", fo == 1796 and sta_run.reset_fanout(COMPOSITION) is None, "fan-out of the reset port %s (expected 1796); a path from a flip-flop has none" % fo)
    # the classes against the overall report
    agree = sta_run.class_consistency(info, 11.25) is None
    disagree = sta_run.class_consistency(info, 7.0) is not None
    failures += verdict("consistency", agree and disagree, "classes whose worst need is 11.25 ns: agree with an overall 11.25 ns: %s; disagree with 7.0 ns: %s" % (agree, disagree))
    return failures


# --- 8 ------------------------------------------------------------------------------------------------------------------------

def refused():
    """Cases that sta.tcl must refuse (OpenSTA warns), and one that it must accept."""
    clean = write_net("clean.v", "module clean (input clk, input a, output q);\n  wire n;\n  %sinv_1 g (.A(a), .Y(n));\n"
                                 "  %sdfxtp_1 f (.CLK(clk), .D(n), .Q(q));\nendmodule\n" % (CELL, CELL))
    loop = write_net("loop.v", "module loopy (input clk, input a, output q);\n  wire n1, n2;\n"
                               "  %snand2_1 g1 (.A(a), .B(n2), .Y(n1));\n  %snand2_1 g2 (.A(a), .B(n1), .Y(n2));\n"
                               "  %sdfxtp_1 f (.CLK(clk), .D(n1), .Q(q));\nendmodule\n" % (CELL, CELL, CELL))
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


# --- 9 ------------------------------------------------------------------------------------------------------------------------

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
    return verdict("bracket", ok, "true minimum %.3f ns accepted: %s; twice it refused: %s; half of it refused: %s" % (
        tmin, good, not bad_high, not bad_low))


# --- 10 -----------------------------------------------------------------------------------------------------------------------

def staleness():
    """A netlist older than one of the files it is made from is stale; the timing-driven points depend on more files than the raw ones."""
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        net, old, new = d / "n.v", d / "old", d / "new"
        for f in (net, old, new):
            f.write_text("x")
        os.utime(old, (1000, 1000))
        os.utime(net, (2000, 2000))
        os.utime(new, (3000, 3000))
        got = sta_run.stale_inputs(net, [old, new, d / "missing"])
    ok = got == [new]
    raw, speed = set(sta_run.netlist_inputs("arbiter")), set(sta_run.netlist_inputs("arbiter_speed"))
    extra = {synth_run.ABC_SCRIPT, synth_run.ABC_CONSTR, synth_run.DONT_USE_LIB}
    ok2 = extra <= speed and not (extra & raw) and ROOT / "scripts" / "synth.tcl" in raw and LIB in raw
    # the refusal itself: an ancient netlist is refused, a netlist from the future is not
    with tempfile.TemporaryDirectory() as d:
        net = Path(d) / "n.v"
        net.write_text("x")
        results = []
        for stamp in (1000, time.time() + 1e6):
            os.utime(net, (stamp, stamp))
            try:
                sta_run.require_fresh("arbiter_speed", net)
                results.append("accepted")
            except SystemExit:
                results.append("refused")
    ok3 = results == ["refused", "accepted"]
    return verdict("staleness", ok and ok2 and ok3, "a file newer than the netlist is reported (%s), a missing one is not; the timing-driven points also "
                   "depend on the ABC script, its constraints and the dont_use liberty (%s); an old netlist is %s, a new one %s" % (ok, ok2, results[0], results[1]))


def main():
    failures = (feedthrough() + inverter_arc() + sdc_constants() + classes() + reset_ports() + slew_isolation() + parser() + refused()
                + end_to_end() + bracket() + staleness())
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

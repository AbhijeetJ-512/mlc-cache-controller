#!/usr/bin/env python3
"""Mutation experiment on the static timing flow's self-test (Phase 8, D-043): `make sta-selftest-deep`.

Each variant is a copy of scripts/, constraints/ and the liberty with ONE edit that breaks the flow (a changed constant, a dropped
command, a wrong set of ports, a skipped check). `sta_run.py --selftest` is run in the copy; it must fail. A variant that passes is
"not noticed". Three variants are expected to pass and say why:

  limits_violators_back   only makes timing.txt larger, the numbers are the same
  depth_counts_flops      equivalent: the depth regex only matches output pins named X, Y, Z, HI, LO, SUM, COUT and a flip-flop's is Q
  base_period_5           equivalent: every slack is the period minus a constant, so the minimum period does not depend on the base period

The run fails if any other variant is not noticed, if the unmodified copy fails, or if a variant's edit no longer matches the code (so a
renamed constant cannot silently turn a variant into a no-op). The result is written to build/reports/sta_selftest_deep.txt.
"""
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "build" / "work" / "sta_mutation"
REPORT = ROOT / "build" / "reports" / "sta_selftest_deep.txt"
COPY = ["scripts", "constraints", "sky130hd"]
SDC, TCL, RUN, CONSTR = "constraints/mlc.sdc", "scripts/sta.tcl", "scripts/sta_run.py", "scripts/abc_speed.constr"
FALSE_PATH = "    set_false_path -from $reset_ports\n"
EXPECTED_MISSED = {
    "limits_violators_back": "only makes timing.txt larger",
    "depth_counts_flops": "equivalent: the depth regex never matches a flip-flop's Q pin",
    "base_period_5": "equivalent: the minimum period does not depend on the base period",
}

# (name, file, old, new): `old` must occur exactly once in `file`
V = [
    ("baseline", None, None, None),
    ("no_output_delay", SDC, "set_output_delay $out_delay -clock clk [all_outputs]\n", ""),
    ("no_input_delay", SDC, "set_input_delay  $in_delay  -clock clk $data_inputs\n", ""),
    ("input_delay_0.5", SDC, "STA_IN_DELAY_NS 0.35", "STA_IN_DELAY_NS 0.5"),
    ("input_delay_350_units", SDC, "STA_IN_DELAY_NS 0.35", "STA_IN_DELAY_NS 350"),
    ("output_delay_0", SDC, "STA_OUT_DELAY_NS 0.15", "STA_OUT_DELAY_NS 0"),
    ("cmd_units_ps", SDC, "set period    [expr", "set_cmd_units -time ps\nset period    [expr"),
    ("no_driving_cell", SDC, "if {[llength $driven] > 0} { set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 $driven }\n", ""),
    ("driving_cell_inv_4", SDC, "sky130_fd_sc_hd__inv_2 $driven", "sky130_fd_sc_hd__inv_4 $driven"),
    ("no_load", SDC, "set_load 0.033442 [all_outputs]\n", ""),
    ("load_0.04", SDC, "set_load 0.033442 [all_outputs]", "set_load 0.04 [all_outputs]"),
    ("no_reset_false_path", SDC, FALSE_PATH, ""),
    ("false_path_to_async_pins", SDC, FALSE_PATH, "    set_false_path -to [all_registers -async_pins]\n"),
    ("false_path_all_inputs", SDC, FALSE_PATH, "    set_false_path -from [all_inputs]\n"),
    ("clock_virtual", SDC, "    create_clock -name clk -period $period $clk_port\n", "    create_clock -name clk -period $period\n"),
    ("reset_ports_only_rst_n", SDC, "in {rst_n async_rst_n}", "in {rst_n}"),
    ("no_ideal_slew_on_reset", SDC, "    set_input_transition 0 $reset_ports\n", ""),
    ("reset_driven_in_main", SDC, "if {!$reset_false || [get_name $p] ni $reset_names}", "if {1}"),
    ("reset_undriven_in_reset_only", SDC, "if {!$reset_false || [get_name $p] ni $reset_names}", "if {[get_name $p] ni $reset_names}"),
    ("no_check_setup", TCL, "check_setup -verbose\n", ""),
    ("overall_max_is_min", TCL, "section \"overall max\"\nreport_checks -path_delay max", "section \"overall max\"\nreport_checks -path_delay min"),
    ("brief_writes_nothing", TCL, "section \"overall max\"\n",
     "if {[info exists ::env(STA_BRIEF)]} { sta::redirect_file_end; exit }\nsection \"overall max\"\n"),
    ("classes_dropped", TCL, "    path_class \"reg2reg\" $regs_clk $regs_data\n    path_class \"in2reg\" [all_inputs] $regs_data\n"
     "    path_class \"reg2out\" $regs_clk [all_outputs]\n", ""),
    ("in2reg_wrong_sets", TCL, "path_class \"in2reg\" [all_inputs] $regs_data", "path_class \"in2reg\" $regs_clk [all_outputs]"),
    ("req2resp_dropped", TCL, "    path_class \"req2resp\" $req_in $resp_out\n", ""),
    ("req2resp_all_inputs", TCL, "set req_in   [ports_named [all_inputs] \"req_*\"]", "set req_in   [all_inputs]"),
    ("req2resp_all_outputs", TCL, "set resp_out [ports_named [all_outputs] \"resp_*\"]", "set resp_out [all_outputs]"),
    ("in2out_dropped", TCL, "path_class \"in2out\" [all_inputs] [all_outputs]\n", ""),
    ("reset_async_dropped", TCL, "        path_class \"reset_async\" $reset_ports [all_registers -async_pins] asynchronous\n", ""),
    ("reset_data_in_async_group", TCL, "[all_registers -data_pins] clk\n        path_class \"reset2out\"",
     "[all_registers -data_pins] asynchronous\n        path_class \"reset2out\""),
    ("reset2out_wrong_set", TCL, "path_class \"reset2out\" $reset_ports [all_outputs] clk",
     "path_class \"reset2out\" $reset_ports [all_registers -data_pins] clk"),
    ("path_group_ignored", TCL, "        if {$group ne \"\"} { lappend cmd -path_group $group }\n", ""),
    ("limits_violators_back", TCL, "report_check_types -max_slew -max_capacitance -max_fanout\n",
     "report_check_types -max_slew -max_capacitance -max_fanout -violators\n"),
    ("bracket_always_ok", RUN, "    return why == \"-\", \"; \".join(verdicts), why", "    return True, \"; \".join(verdicts), why"),
    ("bracket_factor_0", RUN, "BRACKET = 0.02", "BRACKET = 0.0"),
    ("bracket_factor_0.6", RUN, "BRACKET = 0.02", "BRACKET = 0.6"),
    ("worst_path_best", RUN, "return min(found, key=lambda t: t[0]) if found else None", "return max(found, key=lambda t: t[0]) if found else None"),
    ("overall_best_not_worst", RUN, "return info, (min(all_max) if all_max else None)", "return info, (max(all_max) if all_max else None)"),
    ("hold_overall_best", RUN, "(min(all_min) if all_min else None)", "(max(all_min) if all_min else None)"),
    ("need_plus_slack", RUN, "need=period - w[0]", "need=period + w[0]"),
    ("tmin_plus_slack", RUN, "    r[\"tmin\"] = tmin = BASE_PERIOD_NS - r[\"worst_setup\"]", "    r[\"tmin\"] = tmin = BASE_PERIOD_NS + r[\"worst_setup\"]"),
    ("measure_ignores_problems", RUN, "    if rc != 0 or problems:\n        r[\"status\"]", "    if False:\n        r[\"status\"]"),
    ("measure_skips_consistency", RUN, "    mismatch = class_consistency(r[\"info\"], tmin)\n    if mismatch:", "    mismatch = None\n    if mismatch:"),
    ("measure_skips_bracket", RUN, "    ok, r[\"bracket\"], failed_at = bracket_check(net, top, tmin, work_dir)\n    if not ok:",
     "    ok, r[\"bracket\"], failed_at = True, \"-\", \"-\"\n    if not ok:"),
    ("require_fresh_off", RUN, "    stale = stale_inputs(net, netlist_inputs(name))\n    if stale:", "    stale = []\n    if stale:"),
    ("log_problems_never", RUN, "return [l for l in text.splitlines() if re.search(r\"warning|error\", l, re.IGNORECASE)]", "return []"),
    ("log_problems_errors_only", RUN, "re.search(r\"warning|error\", l, re.IGNORECASE)", "re.search(r\"error\", l, re.IGNORECASE)"),
    ("composition_buf_as_other", RUN, "elif kind in (\"buf\", \"clkbuf\"):", "elif kind in (\"nonexistent\",):"),
    ("composition_mux_as_other", RUN, "elif kind in (\"mux2\", \"mux4\", \"mux2i\"):", "elif kind in (\"nonexistent\",):"),
    ("buffer_runs_merged", RUN, "        elif n:\n            runs.append((n, t))\n            n, t = 0, 0.0\n    if n:",
     "        elif False:\n            runs.append((n, t))\n            n, t = 0, 0.0\n    if n:"),
    ("depth_counts_flops", RUN, "return len([c for c in cells if not re.search(r\"__(df|dl|sdf|edf)\", c)])", "return len(cells)"),
    ("reset_fanout_none", RUN, "    return int(m.group(1)) if m else None\n\n\ndef stale_inputs", "    return None\n\n\ndef stale_inputs"),
    ("reset_fanout_not_set", RUN, "i[\"fanout\"] = reset_fanout(blk[1]) if blk else None", "i[\"fanout\"] = None"),
    ("class_consistency_off", RUN, "    if abs(need - tmin) > tol:", "    if False:"),
    ("class_consistency_best", RUN, "    need = max(i[\"need\"] for i in info.values())\n    if abs", "    need = min(i[\"need\"] for i in info.values())\n    if abs"),
    ("base_period_5", RUN, "BASE_PERIOD_NS = 10.0", "BASE_PERIOD_NS = 5.0"),
    ("stale_inputs_never", RUN, "    return [f for f in inputs if f.exists() and f.stat().st_mtime > t]", "    return []"),
    ("stale_inputs_no_abc_constr", RUN, "files += [synth_run.ABC_SCRIPT, synth_run.ABC_CONSTR, synth_run.DONT_USE_LIB]",
     "files += [synth_run.ABC_SCRIPT, synth_run.DONT_USE_LIB]"),
    ("stale_inputs_no_dontuse", RUN, "files += [synth_run.ABC_SCRIPT, synth_run.ABC_CONSTR, synth_run.DONT_USE_LIB]",
     "files += [synth_run.ABC_SCRIPT, synth_run.ABC_CONSTR]"),
    ("in_delay_constant_changed", RUN, "IN_DELAY_NS = 0.35", "IN_DELAY_NS = 0.36"),
    ("abc_constr_load_changed", CONSTR, "set_load 0.033442", "set_load 0.03"),
    ("abc_constr_drive_changed", CONSTR, "set_driving_cell sky130_fd_sc_hd__inv_2", "set_driving_cell sky130_fd_sc_hd__inv_4"),
]


def one(variant):
    name, f, old, new = variant
    d = WORK / name
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    for part in COPY:
        shutil.copytree(ROOT / part, d / part, ignore=shutil.ignore_patterns("synth_selftest", "__pycache__"))
    if f:
        p = d / f
        text = p.read_text()
        if text.count(old) != 1:
            shutil.rmtree(d)
            return name, "BAD VARIANT", -1, ["the edit matches %d places in %s" % (text.count(old), f)]
        p.write_text(text.replace(old, new))
    r = subprocess.run([sys.executable, "scripts/sta_run.py", "--selftest"], cwd=d, capture_output=True, text=True)
    wrong = [l for l in r.stdout.splitlines() if "WRONG" in l]
    why = [w[:110] for w in wrong[:2]] + ([r.stderr.strip().splitlines()[-1][:110]] if r.returncode and not wrong and r.stderr.strip() else [])
    shutil.rmtree(d)
    return name, ("noticed" if r.returncode != 0 else "not noticed"), r.returncode, why


def main():
    with ThreadPoolExecutor(4) as ex:
        results = list(ex.map(one, V))
    shutil.rmtree(WORK, ignore_errors=True)
    lines = []
    for name, verdict, rc, why in results:
        lines.append("%-30s %-12s %s" % (name, verdict, (" | ".join(why)) if verdict == "noticed" else EXPECTED_MISSED.get(name, "")))
    base = next(r for r in results if r[0] == "baseline")
    variants = [r for r in results if r[0] != "baseline"]
    noticed = [r for r in variants if r[1] == "noticed"]
    missed = [r for r in variants if r[1] == "not noticed"]
    unexpected = [r[0] for r in missed if r[0] not in EXPECTED_MISSED]
    bad = [r[0] for r in variants if r[1] == "BAD VARIANT"]
    ok = base[1] == "not noticed" and not unexpected and not bad
    lines.append("")
    lines.append("variants %d, noticed %d, not noticed %d (expected: %s)" % (len(variants), len(noticed), len(missed), ", ".join(sorted(r[0] for r in missed))))
    lines.append("baseline (no edit) passes the self-test: %s" % (base[1] == "not noticed"))
    if unexpected:
        lines.append("UNEXPECTED, not noticed: " + ", ".join(unexpected))
    if bad:
        lines.append("VARIANTS THAT NO LONGER MATCH THE CODE: " + ", ".join(bad))
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

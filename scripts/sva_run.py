#!/usr/bin/env python3
"""sva_run.py - run every buildable testbench under Verilator 5.052 with the bound checkers and gate on the result.

    sva_run.py [--jobs N] [--out results/sva]

Writes results/sva/{runs.txt, cover_bins.txt, vacuity.txt, summary.txt}. Exit 1 if a testbench fails or a checker fires on the unmodified RTL,
a hand-written cover bin was never hit (and has no reason in verif/sva_exclusions.txt), the antecedent of a conditional assertion was never met
(the assertion passed vacuously), or an exclusion is stale. Exit 2 if a run cannot be built or produces no coverage data.
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sva_lib as L  # noqa: E402

ROOT = L.ROOT
CHK = os.path.join(ROOT, "verif", "mlc_checkers.sv")
EXCL = os.path.join(ROOT, "verif", "sva_exclusions.txt")


def read_exclusions():
    ex = {}
    if os.path.exists(EXCL):
        for n, line in enumerate(open(EXCL), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            lab, _, why = line.partition(" ")
            if not why.strip():
                sys.exit("%s:%d: an exclusion needs a reason" % (EXCL, n))
            ex[lab] = why.strip()
    return ex


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "sva"))
    a = ap.parse_args()
    work = os.path.join(ROOT, "build", "sva")
    os.makedirs(work, exist_ok=True)
    os.makedirs(a.out, exist_ok=True)
    vac = os.path.join(work, "mlc_checkers_vac.sv")
    msg = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "gen_vacuity.py"), CHK, vac], capture_output=True, text=True).stdout.strip()
    tbs = [t for t in L.registry() if t[0] not in L.EXCLUDED]
    res = L.run_matrix(tbs, os.path.join(work, "runs"), jobs=a.jobs, checkers=vac)

    lines = ["# one line per testbench: its own verdict, then any checker assertion that fired", ""]
    bad = False
    for r in res:
        if not r["built"]:
            lines.append("%-22s BUILD ERROR (see %s)" % (r["tag"], os.path.relpath(r["log"], ROOT)))
            bad = True
            continue
        lines.append("%-22s %-6s PASS lines %d, FAIL lines %d, exit %s   checkers fired: %s" % (
            r["tag"], "ok" if r["ok"] else "FAILED", r["pass_"], r["fail"], r["rc"], ", ".join("%s x%d" % kv for kv in sorted(r["fired"].items())) or "none"))
        bad |= not r["ok"]
    for name, why in sorted(L.EXCLUDED.items()):
        lines.append("%-22s not run: %s" % (name, why))
    open(os.path.join(a.out, "runs.txt"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    if any(not r["built"] for r in res):
        return 2
    tot = L.merge_cov(res)
    if not tot:
        print("sva_run: no cover data in any run")
        return 2
    agg, inst = L.by_label(tot)
    excl = read_exclusions()
    asserts = L.assertion_labels(CHK)
    conditional = sorted({k[1][len("c_ante_"):] for k in agg if k[1].startswith("c_ante_")})
    hand = sorted((m, lab) for (m, lab) in agg if lab.startswith("c_") and not lab.startswith("c_ante_"))
    problems = []
    with open(os.path.join(a.out, "cover_bins.txt"), "w") as out:
        out.write("# hits over every run and instance   checker module   label   (instances that carry the bin)\n")
        for m, lab in hand:
            h = agg[(m, lab)]
            out.write("%10d  %-16s %-18s (%d instance%s)\n" % (h, m, lab, len(inst[(m, lab)]), "s" if len(inst[(m, lab)]) != 1 else ""))
            if h == 0 and lab not in excl:
                problems.append("ZERO-HIT COVER %s.%s" % (m, lab))
    with open(os.path.join(a.out, "vacuity.txt"), "w") as out:
        out.write("# antecedent hits per conditional assertion (0 = the assertion passed vacuously in every run)\n")
        for name in conditional:
            ms = [m for (m, lab) in agg if lab == "c_ante_" + name]
            h = sum(agg[(m, "c_ante_" + name)] for m in ms)
            out.write("%10d  %-16s a_%s\n" % (h, ms[0] if ms else "?", name))
            if h == 0 and ("a_" + name) not in excl:
                problems.append("VACUOUS ASSERTION a_%s (antecedent never met)" % name)
    for lab, why in sorted(excl.items()):
        if any(h > 0 for (m, l), h in agg.items() if l == lab or l == "c_ante_" + lab[2:]):
            problems.append("STALE EXCLUSION %s (%s) was hit; remove the exclusion" % (lab, why))
    n_hand_hit = sum(1 for k in hand if agg[k] > 0)
    n_ante_hit = sum(1 for n in conditional if any(agg[(m, "c_ante_" + n)] > 0 for (m, l) in agg if l == "c_ante_" + n))
    with open(os.path.join(a.out, "summary.txt"), "w") as out:
        out.write("mlc_cache_controller: bound checkers under Verilator 5.052 on the repository's own testbenches (%d runs, unmodified RTL)\n" % len(res))
        out.write("runs                      : %d testbenches, all passed and no checker fired: %s\n" % (len(res), "yes" if not bad else "NO"))
        out.write("assertions defined        : %d labelled (%d concurrent, %d procedural checks)\n" % (
            len(asserts), sum(1 for x in asserts if x.startswith("a_")), sum(1 for x in asserts if x.startswith("sb_"))))
        out.write("conditional assertions    : %d, antecedent reached in at least one run: %d\n" % (len(conditional), n_ante_hit))
        out.write("cover bins                : %d, hit: %d, zero: %d (excluded with a reason: %d)\n" % (
            len(hand), n_hand_hit, len(hand) - n_hand_hit, sum(1 for k in hand if agg[k] == 0 and k[1] in excl)))
        out.write("note                      : %s\n" % msg)
        out.write("problems                  : %s\n" % ("none" if not problems and not bad else "; ".join(problems) or "a run failed"))
    print(open(os.path.join(a.out, "summary.txt")).read())
    for p in problems:
        print("PROBLEM", p)
    return 1 if (problems or bad) else 0


if __name__ == "__main__":
    sys.exit(main())

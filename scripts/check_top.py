#!/usr/bin/env python3
"""Mechanical check that rtl/top/mlc_cache_top.sv is structural only (D-034).

The top is meant to be reviewable by inspection: it instantiates units and wires them, nothing
else. This script turns that into a check that fails the build:

  * no always / initial / generate / for / function / task, no ternary, no `.*` connections;
  * every assign is `name = name_or_constant;` (no operators);
  * every instance connects every port of its module, by name, to a plain signal, and connects no
    port that the module does not have;
  * every internal signal has exactly one driver (an instance output) and at least one reader;
    every top-level input is read, every top-level output is driven exactly once;
  * every signal connects exactly the instances the architecture says it joins (the BOUNDARIES
    table below, written once from 02_architecture.md section 1), so a signal wired to the wrong
    unit is caught even when its width happens to fit;
  * every port is wired to a signal named for it (`.req_valid(l2_req_valid)`, `.dn_resp_line(l2_resp_line)`:
    the names agree once the boundary prefixes are stripped), so two same-width signals swapped
    between the same pair of units, or the clock and the reset crossed on one unit, are caught.

Widths are not checked here: Icarus (-Wall) and Yosys (hierarchy -check) do that, see the Makefile.
Usage: check_top.py [top.sv] [rtl-dir...]   (defaults: rtl/top/mlc_cache_top.sv, rtl)
"""
import re
import sys
from pathlib import Path

TOP = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("rtl/top/mlc_cache_top.sv")
RTL_DIRS = [Path(p) for p in sys.argv[2:]] or [Path("rtl")]

errors = []

# Which instances each signal may connect: the module graph of the hierarchy, as a list of
# (signal-name regex, set of instance names). Every declared signal must match one row.
ALL = {"u_reset", "u_l1i", "u_l1d", "u_arb", "u_l2", "u_adapter", "u_l3", "u_axi"}
BOUNDARIES = [
    (r"clk", ALL - {"u_adapter"}),                       # the clock reaches every clocked unit; the adapter has none
    (r"rst_n", {"u_reset"}),
    (r"rst_n_sync", ALL - {"u_adapter"}),                 # driven by the synchroniser, read by every stateful unit
    (r"i_(req|resp)_\w+", {"u_l1i"}),                    # CPU fetch port
    (r"d_(req|resp)_\w+", {"u_l1d"}),                    # CPU load/store port
    (r"i_dn_\w+", {"u_l1i", "u_arb"}),                   # L1-I <-> arbiter
    (r"d_dn_\w+", {"u_l1d", "u_arb"}),                   # L1-D <-> arbiter
    (r"l2_resp_line", {"u_l2", "u_l1i", "u_l1d"}),       # L2's response line fans out to both L1 controllers
    (r"l2_(req_\w+|resp_valid|resp_ready)", {"u_arb", "u_l2"}),   # arbiter <-> L2
    (r"l2_dn_\w+", {"u_l2", "u_adapter"}),               # L2 <-> adapter
    (r"l3_(req|resp)_\w+", {"u_adapter", "u_l3"}),       # adapter <-> L3
    (r"l3_dn_\w+", {"u_l3", "u_axi"}),                   # L3 <-> AXI4 fill engine
    (r"m_axi_a[wr](lock|cache|prot|qos|region)", set()),  # sideband constants: assigns, no instance
    (r"m_axi_\w+|mem_err", {"u_axi"}),                   # the AXI4 master port
]


def err(msg):
    errors.append(msg)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def balanced(text, start):
    """Index just past the parenthesis group that opens at text[start] == '('."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError("unbalanced parentheses")


def module_ports(text):
    """{module name: {port name: 'input'|'output'}} for every module in text."""
    mods = {}
    for m in re.finditer(r"\bmodule\s+(\w+)\s*", text):
        i = m.end()
        if text[i:i + 1] == "#":                      # skip the parameter list
            i = balanced(text, text.index("(", i))
        j = text.index("(", i)
        header = text[j:balanced(text, j)]
        ports = {}
        for d in re.finditer(r"\b(input|output|inout)\b\s+(?:logic|wire|reg)?\s*(?:\[[^\]]*\])?\s*(\w+)", header):
            ports[d.group(2)] = d.group(1)
        mods[m.group(1)] = ports
    return mods


all_mods = {}
for d in RTL_DIRS:
    for f in sorted(d.rglob("*.sv")):
        all_mods.update(module_ports(strip_comments(f.read_text())))

src = strip_comments(TOP.read_text())

# ---- nothing but structure ----
for pat, what in [
    (r"\balways(_ff|_comb|_latch)?\b", "always block"),
    (r"\binitial\b", "initial block"),
    (r"\bgenerate\b|\bgenvar\b", "generate"),
    (r"\bfor\s*\(", "for loop"),
    (r"\bfunction\b|\btask\b", "function/task"),
    (r"\?", "ternary operator"),
    (r"\.\*", "implicit .* port connection"),
]:
    for m in re.finditer(pat, src):
        err(f"{TOP}: {what} is not allowed in the top")

top_mod = re.search(r"\bmodule\s+(\w+)", src).group(1)
top_ports = module_ports(src)[top_mod]

# ---- assigns: name = name_or_constant ----
CONST = r"(?:\d+)?'[bBhHdDoO][0-9a-fA-F_xXzZ]+"
drivers = {}   # signal -> number of drivers
readers = {}   # signal -> number of readers


def bump(table, name):
    table[name] = table.get(name, 0) + 1


for m in re.finditer(r"\bassign\s+([^;]*);", src):
    a = re.fullmatch(r"\s*(\w+)\s*=\s*(\w+|" + CONST + r")\s*", m.group(1))
    if not a:
        err(f"{TOP}: assign is not a plain wire or constant: assign {m.group(1).strip()}")
        continue
    bump(drivers, a.group(1))
    if re.fullmatch(r"[A-Za-z_]\w*", a.group(2)):
        bump(readers, a.group(2))          # a parameter name is not a declared signal and is ignored below

# ---- instances ----
declared = set(top_ports)
for m in re.finditer(r"^\s*(?:logic|wire)\b\s*(?:\[[^\]]*\])?\s*([^;]+);", src, flags=re.M):
    for name in m.group(1).split(","):
        declared.add(name.strip())

inst_re = re.compile(r"^\s*(\w+)\s+(?:#\s*\(.*?\)\s*)?(\w+)\s*\(", flags=re.M | re.S)
touches = {}   # signal -> set of instance names it is connected to

# A port and the signal wired to it must agree on the name once the boundary prefixes are removed.
# The few ports whose job is not their name are listed in EXACT.
PORT_PREFIXES = ("dn_", "up0_", "up1_", "l2_", "l3_")
SIG_PREFIXES = ("i_dn_", "d_dn_", "l2_dn_", "l3_dn_", "l2_", "l3_", "i_", "d_", "m_axi_")
EXACT = {"clk": "clk", "rst_n": "rst_n_sync", "async_rst_n": "rst_n"}


def strip_prefix(name, prefixes):
    for pre in prefixes:
        if name.startswith(pre):
            return name[len(pre):]
    return name


def names_agree(port, sig):
    if port in EXACT:
        return sig == EXACT[port]
    return strip_prefix(port, PORT_PREFIXES) == strip_prefix(sig, SIG_PREFIXES)

n_inst = 0
for m in inst_re.finditer(src):
    mod, inst = m.group(1), m.group(2)
    if mod == top_mod:
        continue
    if mod not in all_mods:
        err(f"{inst}: instance of {mod}, which is not a module defined under {', '.join(map(str, RTL_DIRS))}")
        continue
    n_inst += 1
    start = m.end() - 1
    body = src[start:balanced(src, start)]
    conns = re.findall(r"\.(\w+)\s*\(\s*([^()]*?)\s*\)", body)
    names = [c[0] for c in conns]
    for dup in {n for n in names if names.count(n) > 1}:
        err(f"{inst} ({mod}): port .{dup} connected more than once")
    ports = all_mods[mod]
    for p in sorted(set(ports) - set(names)):
        err(f"{inst} ({mod}): port .{p} is not connected")
    for p in sorted(set(names) - set(ports)):
        err(f"{inst} ({mod}): .{p} is not a port of {mod}")
    for p, expr in conns:
        if p not in ports:
            continue
        if not re.fullmatch(r"[A-Za-z_]\w*", expr):
            err(f"{inst} ({mod}): .{p}({expr}) is not a plain signal")
            continue
        if expr not in declared:
            err(f"{inst} ({mod}): .{p}({expr}) names an undeclared signal")
        bump(drivers if ports[p] == "output" else readers, expr)
        touches.setdefault(expr, set()).add(inst)
        if not names_agree(p, expr):
            err(f"{inst} ({mod}): .{p}({expr}) wires a port to a signal that is not named for it")

if n_inst == 0:
    err(f"{TOP}: found no instances; the checker could not parse the file")

# ---- one driver per signal, every signal read, every port used ----
for sig in sorted(declared):
    d, r = drivers.get(sig, 0), readers.get(sig, 0)
    if sig in top_ports:
        if top_ports[sig] == "input":
            if d:
                err(f"top input {sig} is driven inside the top")
            if not r:
                err(f"top input {sig} is not read by anything")
        else:
            if d != 1:
                err(f"top output {sig} has {d} drivers, want exactly 1")
    else:
        if d != 1:
            err(f"signal {sig} has {d} drivers, want exactly 1")
        if not r:
            err(f"signal {sig} is driven but never read")

for sig in sorted(declared):
    rule = next((want for pat, want in BOUNDARIES if re.fullmatch(pat, sig)), "none")
    if rule == "none":
        err(f"signal {sig} matches no row of the BOUNDARIES table; add it (which units does it join?)")
    elif rule is not None and touches.get(sig, set()) != rule:
        err(f"signal {sig} joins {sorted(touches.get(sig, set()))}, the architecture says {sorted(rule)}")

if errors:
    print(f"check_top: {len(errors)} problem(s) in {TOP}")
    for e in errors:
        print("  " + e)
    sys.exit(1)
print(f"check_top: clean ({n_inst} instances, {len(declared)} signals, structural only)")

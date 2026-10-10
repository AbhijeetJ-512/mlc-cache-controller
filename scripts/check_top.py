#!/usr/bin/env python3
"""Mechanical check that rtl/top/mlc_cache_top.sv is structural only (D-034).

The top is meant to be reviewable by inspection: it instantiates units and wires them, nothing
else. This script turns that into a check that fails the build. It reads the top as a list of
statements and accepts only these:

  * `logic` / `wire` declarations, `localparam` / `parameter` constants;
  * `assign <AXI4 sideband output> = <constant or the matching top parameter>;` (nothing else may
    be assigned, so there is no way to put an expression, a gate or a signal on an output);
  * an instance of a module defined under rtl/, with no parameter override, connecting every port
    of that module by name to a plain signal, and no port the module does not have.

Anything else is an error: always / initial / generate / loops / functions / ternaries / `.*` /
gate primitives / defparam / a statement the script does not know. On top of that:

  * every internal signal has exactly one driver (an instance output) and at least one reader;
    every top-level input is read, every top-level output is driven exactly once;
  * every signal connects exactly the instances the architecture says it joins (the BOUNDARIES
    table below, written once from 02_architecture.md section 1), so a signal wired to the wrong
    unit is caught even when its width happens to fit;
  * every port is wired to a signal named for it (`.req_valid(l2_req_valid)`, `.dn_resp_line(l2_resp_line)`:
    the names agree once the boundary prefixes are stripped; the arbiter's `up0_` ports take `i_dn_`
    signals and its `up1_` ports `d_dn_` signals; `clk` and `rst_n` are pinned), so two same-width
    signals swapped between the same pair of units, the two L1 controllers crossed at the arbiter, or
    the clock and the reset crossed on one unit, are caught.

What it cannot see: a swap that keeps both the names and the topology consistent, a top whose units
are individually wrong, and anything about behaviour. Widths are not checked here: Icarus (-Wall)
and Yosys (hierarchy -check) do that, see the Makefile.
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

# A port and the signal wired to it must agree on the name once the boundary prefixes are removed.
# The few ports whose job is not their name are listed in EXACT; the arbiter's two requester sides
# are tied to their L1 controller in SIDES.
PORT_PREFIXES = ("dn_", "up0_", "up1_", "l2_", "l3_")
SIG_PREFIXES = ("i_dn_", "d_dn_", "l2_dn_", "l3_dn_", "l2_", "l3_", "i_", "d_", "m_axi_")
EXACT = {"clk": "clk", "rst_n": "rst_n_sync", "async_rst_n": "rst_n"}
SIDES = {"up0_": "i_dn_", "up1_": "d_dn_"}

SIDEBAND = re.compile(r"m_axi_a[wr](lock|cache|prot|qos|region)")
CONST = re.compile(r"(?:\d+)?'[bBhHdDoO][0-9a-fA-F_]+")      # no x or z


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


def strip_prefix(name, prefixes):
    for pre in prefixes:
        if name.startswith(pre):
            return name[len(pre):]
    return name


def names_agree(port, sig):
    if port in EXACT:
        return sig == EXACT[port]
    for side, want in SIDES.items():
        if port.startswith(side):
            return sig.startswith(want) and port[len(side):] == sig[len(want):]
    return strip_prefix(port, PORT_PREFIXES) == strip_prefix(sig, SIG_PREFIXES)


all_mods = {}
for d in RTL_DIRS:
    for f in sorted(d.rglob("*.sv")):
        all_mods.update(module_ports(strip_comments(f.read_text())))

src = strip_comments(TOP.read_text())

# ---- constructs that have no place in a structural top, wherever they appear ----
for pat, what in [
    (r"\balways(_ff|_comb|_latch)?\b", "always block"),
    (r"\binitial\b", "initial block"),
    (r"\bgenerate\b|\bgenvar\b", "generate"),
    (r"\bfor\s*\(", "for loop"),
    (r"\bfunction\b|\btask\b", "function/task"),
    (r"\bdefparam\b", "defparam"),
    (r"\?", "ternary operator"),
    (r"\.\*", "implicit .* port connection"),
]:
    for _ in re.finditer(pat, src):
        err(f"{TOP}: {what} is not allowed in the top")

# ---- the module header: name, parameters, ports ----
mm = re.search(r"\bmodule\s+(\w+)\s*", src)
top_mod = mm.group(1)
i = mm.end()
params = set()
if src[i:i + 1] == "#":
    j = src.index("(", i)
    k = balanced(src, j)
    for p in re.finditer(r"\bparameter\b[^,)]*?\b(\w+)\s*=", src[j:k]):
        params.add(p.group(1))
    i = k
j = src.index("(", i)
header_end = src.index(";", balanced(src, j))
top_ports = module_ports(src)[top_mod]

drivers = {}   # signal -> number of drivers
readers = {}   # signal -> number of readers
touches = {}   # signal -> set of instance names it is connected to
declared = set(top_ports)
n_inst = 0


def bump(table, name):
    table[name] = table.get(name, 0) + 1


inst_re = re.compile(r"(\w+)\s+(#\s*\(.*?\)\s*)?(\w+)\s*\(", flags=re.S)

# ---- the body, one statement at a time ----
for stmt in (s.strip() for s in src[header_end + 1:].split(";")):
    if not stmt or stmt == "endmodule":
        continue
    word = stmt.split(None, 1)[0]

    if word in ("logic", "wire"):
        body = re.sub(r"^(logic|wire)\b\s*(\[[^\]]*\])?", "", stmt)
        for name in body.split(","):
            declared.add(name.strip())

    elif word in ("localparam", "parameter"):
        pass                                            # constants for widths and defaults

    elif word == "assign":
        a = re.fullmatch(r"assign\s+(\w+)\s*=\s*(\w+|\d*'[bBhHdDoO]\S+)", stmt)
        if not a:
            err(f"{TOP}: assign is not `name = constant_or_parameter`: {stmt}")
            continue
        lhs, rhs = a.groups()
        m = SIDEBAND.fullmatch(lhs)
        if not m or top_ports.get(lhs) != "output":
            err(f"{TOP}: only the AXI4 sideband outputs may be assigned in the top, not {lhs}")
            continue
        bump(drivers, lhs)
        if CONST.fullmatch(rhs):
            continue
        want = "AXI_" + m.group(1).upper()
        if rhs not in params:
            err(f"{TOP}: assign {lhs} = {rhs}: the right side must be a constant or a top parameter, never a signal")
        elif rhs != want:
            err(f"{TOP}: assign {lhs} = {rhs}: the parameter for {lhs} is {want}")

    else:
        m = inst_re.match(stmt)
        if not m:
            err(f"{TOP}: statement is not allowed in a structural top: {stmt[:70]}")
            continue
        mod, override, inst = m.groups()
        if mod not in all_mods or mod == top_mod:
            err(f"{inst}: instance of {mod}, which is not a module defined under {', '.join(map(str, RTL_DIRS))}")
            continue
        if override:
            err(f"{inst} ({mod}): parameter override on an instance; units keep the package defaults")
        n_inst += 1
        start = m.end() - 1
        end = balanced(stmt, start)
        body = stmt[start:end]
        if stmt[end:].strip():
            err(f"{inst} ({mod}): text after the port list")
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
            if not names_agree(p, expr):
                err(f"{inst} ({mod}): .{p}({expr}) wires a port to a signal that is not named for it")
            bump(drivers if ports[p] == "output" else readers, expr)
            touches.setdefault(expr, set()).add(inst)

if n_inst == 0:
    err(f"{TOP}: found no instances; the checker could not parse the file")

# ---- names used in connections must be declared ----
for sig in sorted(touches):
    if sig not in declared:
        err(f"signal {sig} is connected but not declared")

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

# ---- every signal joins the units the architecture says it joins ----
for sig in sorted(declared):
    rule = next((want for pat, want in BOUNDARIES if re.fullmatch(pat, sig)), "none")
    if rule == "none":
        err(f"signal {sig} matches no row of the BOUNDARIES table; add it (which units does it join?)")
    elif touches.get(sig, set()) != rule:
        err(f"signal {sig} joins {sorted(touches.get(sig, set()))}, the architecture says {sorted(rule)}")

if errors:
    print(f"check_top: {len(errors)} problem(s) in {TOP}")
    for e in errors:
        print("  " + e)
    sys.exit(1)
print(f"check_top: clean ({n_inst} instances, {len(declared)} signals, structural only)")

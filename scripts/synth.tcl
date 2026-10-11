# synth.tcl - Yosys 0.33 synthesis of one module to Sky130HD (Phase 7: SR-01..SR-07, D-037).
#
# This is the single synthesis script (SR-07). It is a Tcl script because the module, its parameter overrides and the
# output directory change from run to run and a plain .ys script cannot take arguments. Run it as
#
#     yosys -c scripts/synth.tcl
#
# with these environment variables set (scripts/synth_run.py sets them; `make synth` calls that):
#
#   SYNTH_TOP        module to synthesise
#   SYNTH_SRCS       space-separated source files, read in this order (the package first)
#   SYNTH_PARAMS     optional, "NAME=VALUE ..." overrides of the top module's own parameters (Yosys chparam)
#   SYNTH_LIB        liberty file, sky130hd/sky130hd_tt.lib
#   SYNTH_OUT        directory that receives stat.txt and checks.txt
#   SYNTH_ABC        "fast" (the default flow, D-037) or "default" (ABC's full area-oriented script, much slower)
#   SYNTH_NETLIST    optional, path to write the mapped netlist to
#   SYNTH_PREMAPPED  optional, "1": SYNTH_SRCS is already a mapped netlist; skip synthesis and run only the checks on a
#                    mapped netlist (the self-test uses this to prove those checks can fail)
#
# Each check below prints "running check: <name>" before it runs and "check passed: <name>" after. A failing check ends the
# run with a Yosys error, so the last "running check" line without a "check passed" after it names the check that stopped the
# run (scripts/synth_run.py reads that, and the self-test requires the intended check to be the one). Passed checks are also
# written to $SYNTH_OUT/checks.txt as evidence.
#
# What is and is not checked (D-037):
#   checked   tri-states written as a mux with z; latches; undriven and multiply-driven nets; combinational loops (all before
#             and after synthesis); black boxes in the RTL; a library cell instantiated in the RTL (the liberty is read only
#             after the RTL, so hierarchy -check rejects it); a mapped netlist with any cell that is not a library cell,
#             or a tri-state, latch or clock-gate library cell.
#   logged    any other Yosys warning is left to scripts/synth_run.py, which fails the run unless it is on its whitelist.
#             That is what catches a constant z and a port resized by a connection.
#   NOT       assignment truncation inside a module, incomplete sensitivity lists (Yosys 0.33 does not warn on either), and
#             clock gating built from ordinary gates. The last two are closed for this RTL by `make rules`
#             (scripts/check_rtl_rules.py: only always_comb and always_ff @(posedge clk ...)), not by this script.

proc need_env {name} {
    if {![info exists ::env($name)] || $::env($name) eq ""} {
        puts "synth.tcl: environment variable $name is not set"
        exit 1
    }
    return $::env($name)
}

proc opt_env {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default
}

set top       [need_env SYNTH_TOP]
set srcs      [need_env SYNTH_SRCS]
set lib       [need_env SYNTH_LIB]
set out       [need_env SYNTH_OUT]
set params    [opt_env SYNTH_PARAMS ""]
set abcmode   [opt_env SYNTH_ABC fast]
set netlist   [opt_env SYNTH_NETLIST ""]
set premapped [opt_env SYNTH_PREMAPPED 0]

if {$abcmode ne "fast" && $abcmode ne "default"} {
    puts "synth.tcl: SYNTH_ABC must be fast or default, not $abcmode"
    exit 1
}

file mkdir $out
set checks [open $out/checks.txt w]

# Run one Yosys command as a named check.
proc must {name cmd} {
    global checks
    puts "synth.tcl: running check: $name"
    yosys $cmd
    puts $checks $name
    flush $checks
    puts "synth.tcl: check passed: $name"
}

# The checks on a mapped netlist; also all that SYNTH_PREMAPPED runs.
proc mapped_checks {} {
    must "check -assert on the mapped netlist (SR-03, SR-06)" {check -assert}
    must "every cell is a Sky130HD library cell (SR-05)" {select -assert-none t:* t:sky130_fd_sc_hd__* %d}
    must "no tri-state cell in the mapped netlist (SR-02)" {select -assert-none t:$tribuf t:$_TBUF_ t:sky130_fd_sc_hd__ebufn_* t:sky130_fd_sc_hd__einvn_* t:sky130_fd_sc_hd__einvp_*}
    must "no latch or clock-gate cell in the mapped netlist (SR-02, SR-06)" {select -assert-none t:sky130_fd_sc_hd__dlxtp_* t:sky130_fd_sc_hd__dlxtn_* t:sky130_fd_sc_hd__dlxbp_* t:sky130_fd_sc_hd__dlxbn_* t:sky130_fd_sc_hd__dlrtp_* t:sky130_fd_sc_hd__dlrtn_* t:sky130_fd_sc_hd__dlrbp_* t:sky130_fd_sc_hd__dlrbn_* t:sky130_fd_sc_hd__lpflow_inputisolatch_* t:sky130_fd_sc_hd__dlclkp_* t:sky130_fd_sc_hd__sdlclkp_*}
}

if {$premapped} {
    yosys read_liberty -lib $lib
    foreach f $srcs { yosys read_verilog -sv $f }
    yosys hierarchy -check -top $top
    mapped_checks
    close $checks
    exit 0
}

foreach f $srcs {
    yosys read_verilog -sv $f
}

set h "hierarchy -check -top $top"
foreach p $params {
    set kv [split $p =]
    append h " -chparam [lindex $kv 0] [lindex $kv 1]"
}
yosys $h

# The liberty is read after the RTL, and as a cell library (-lib). After the RTL so that a library cell instantiated in
# the RTL is an unknown module and hierarchy -check refuses it (SR-05, no vendor primitives); as a library so Yosys knows
# each cell's port directions (without that `check` reports every mapped cell output as undriven).
must "no black box in the RTL (SR-05)" {select -assert-none =A:blackbox}
yosys read_liberty -lib $lib

# Tri-states are recognised from the RTL (a mux with a z input), and undriven nets must be looked for before `synth`: its
# opt passes replace an undriven net by x, after which `check` no longer sees it.
yosys proc
yosys tribuf
must "no tri-state driver in the RTL (SR-02)" {select -assert-none t:$tribuf}
must "no undriven or multiply-driven net and no combinational loop in the RTL (SR-03, SR-06)" {check -assert}

yosys synth -top $top -flatten -noabc
must "no undriven or multiply-driven net and no combinational loop after generic synthesis (SR-03, SR-06)" {check -assert}
must "no latch after generic synthesis (SR-02)" {select -assert-none t:$dlatch t:$adlatch t:$dlatchsr t:$_DLATCH_* t:$_DLATCHSR_* t:$_SR_*}

yosys dfflibmap -liberty $lib
if {$abcmode eq "fast"} {
    yosys abc -fast -liberty $lib
} else {
    yosys abc -liberty $lib
}
yosys opt_clean -purge

# Constant outputs and inputs become tie cells, as in the Full-Adder flow.
yosys hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
yosys opt_clean -purge

mapped_checks

yosys tee -o $out/stat.txt stat -liberty $lib
if {$netlist ne ""} {
    yosys write_verilog -noattr $netlist
}
close $checks

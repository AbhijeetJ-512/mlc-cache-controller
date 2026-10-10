# synth.tcl - Yosys 0.33 synthesis of one module to Sky130HD (Phase 7: SR-01..SR-07, D-037).
#
# This is the single synthesis script (SR-07). It is a Tcl script because the module, its parameter overrides and the
# output directory change from run to run and a plain .ys script cannot take arguments. Run it as
#
#     yosys -c scripts/synth.tcl
#
# with these environment variables set (scripts/synth_run.py sets them; `make synth` calls that):
#
#   SYNTH_TOP      module to synthesise
#   SYNTH_SRCS     space-separated source files, read in this order (the package first)
#   SYNTH_PARAMS   optional, "NAME=VALUE ..." overrides of the top module's own parameters (Yosys chparam)
#   SYNTH_LIB      liberty file, sky130hd/sky130hd_tt.lib
#   SYNTH_OUT      directory that receives stat.txt and checks.txt
#   SYNTH_ABC      "fast" (the default flow, D-037) or "default" (ABC's full area-oriented script, much slower)
#   SYNTH_NETLIST  optional, path to write the mapped netlist to
#
# Every `select -assert-none` and `check -assert` below stops the run with an error when it fails, so a run that gets to
# the end has no latch, no tri-state, no undriven or multiply-driven net, no combinational loop, and no cell that is
# not a library cell. Each check that passed is also written to $SYNTH_OUT/checks.txt as evidence.

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

set top     [need_env SYNTH_TOP]
set srcs    [need_env SYNTH_SRCS]
set lib     [need_env SYNTH_LIB]
set out     [need_env SYNTH_OUT]
set params  [opt_env SYNTH_PARAMS ""]
set abcmode [opt_env SYNTH_ABC fast]
set netlist [opt_env SYNTH_NETLIST ""]

if {$abcmode ne "fast" && $abcmode ne "default"} {
    puts "synth.tcl: SYNTH_ABC must be fast or default, not $abcmode"
    exit 1
}

file mkdir $out
set checks [open $out/checks.txt w]
proc passed {msg} {
    global checks
    puts $checks $msg
    flush $checks
    puts "synth.tcl: check passed: $msg"
}

# The liberty is read as a cell library (-lib) so Yosys knows each cell's port directions; without it `check` reports every
# mapped cell output as undriven.
yosys read_liberty -lib $lib
foreach f $srcs {
    yosys read_verilog -sv $f
}

set h "hierarchy -check -top $top"
foreach p $params {
    set kv [split $p =]
    append h " -chparam [lindex $kv 0] [lindex $kv 1]"
}
yosys $h

# Tri-states are recognised from the RTL (a mux with a z input), so look for them before anything lowers them.
yosys proc
yosys tribuf
yosys {select -assert-none t:$tribuf}
passed "no tri-state driver in the RTL (SR-02)"

yosys synth -top $top -flatten -noabc
yosys check -assert
passed "check -assert after generic synthesis: no undriven or multiply-driven net, no combinational loop (SR-03, SR-06)"
yosys {select -assert-none t:$dlatch t:$adlatch t:$dlatchsr t:$_DLATCH_* t:$_DLATCHSR_* t:$_SR_*}
passed "no latch after generic synthesis (SR-02)"

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

yosys check -assert
passed "check -assert on the mapped netlist (SR-03, SR-06)"
yosys {select -assert-none t:$*}
passed "every cell is a Sky130HD library cell (SR-05)"
yosys {select -assert-none t:$tribuf t:$_TBUF_ t:sky130_fd_sc_hd__ebufn_* t:sky130_fd_sc_hd__einvn_* t:sky130_fd_sc_hd__einvp_*}
passed "no tri-state cell in the mapped netlist (SR-02)"
yosys {select -assert-none t:sky130_fd_sc_hd__dlxtp_* t:sky130_fd_sc_hd__dlxtn_* t:sky130_fd_sc_hd__dlxbp_* t:sky130_fd_sc_hd__dlxbn_* t:sky130_fd_sc_hd__dlrtp_* t:sky130_fd_sc_hd__dlrtn_* t:sky130_fd_sc_hd__dlrbp_* t:sky130_fd_sc_hd__dlrbn_* t:sky130_fd_sc_hd__dlclkp_* t:sky130_fd_sc_hd__sdlclkp_*}
passed "no latch or clock-gate cell in the mapped netlist (SR-02, SR-06)"

yosys tee -o $out/stat.txt stat -liberty $lib
if {$netlist ne ""} {
    yosys write_verilog -noattr $netlist
}
close $checks

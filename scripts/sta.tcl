# sta.tcl - OpenSTA static timing analysis of one synthesised netlist (Phase 8, TR-01..TR-04, D-041).
#
#   sta -no_splash -exit scripts/sta.tcl
#
# Environment (scripts/sta_run.py sets it):
#   STA_NETLIST  mapped netlist      STA_TOP  its top module      STA_LIB  liberty (sky130hd/sky130hd_tt.lib)
#   STA_PERIOD_NS, STA_IN_DELAY_NS, STA_OUT_DELAY_NS   see constraints/mlc.sdc
#   STA_OUT      directory for timing.txt and power.txt
#   STA_BRIEF=1       only the overall worst setup and hold paths (the verification runs of the Fmax bracket)
#   STA_RESET_ONLY=1  analyse only the paths that start at a reset port, with the false path of constraints/mlc.sdc left off
#                     (set by sta_run.py together with STA_RESET_FALSE_PATH=0): the unbuffered reset network, reported separately
#
# timing.txt holds, for each class of path, the worst setup path and the worst hold path: register to register, input to
# register, register to output and input to output (the combinational input-to-output path), each headed by a line "=== class ===".
# A fifth, req2resp, is a part of in2out: the paths from the request inputs (req_*) to the response outputs (resp_*) of a cache
# controller, the combinational hit path of PF-01 and the one the prediction of 03_microarchitecture.md section 5 is about. It exists
# only for a unit that has both kinds of port.
# check_setup is run first; any warning it prints (no clock, an unconstrained endpoint, a loop) fails the run in sta_run.py.

foreach v {STA_NETLIST STA_TOP STA_LIB STA_PERIOD_NS STA_OUT} {
    if {![info exists ::env($v)]} { puts "sta.tcl: environment variable $v is not set"; exit 1 }
}
file mkdir $::env(STA_OUT)

read_liberty $::env(STA_LIB)
read_verilog $::env(STA_NETLIST)
link_design $::env(STA_TOP)
source $::env(STA_SDC)

check_setup -verbose

proc section {title} { sta::report_line "\n=== $title ===" }

# One class of path: the worst setup and the worst hold path from the set `from` to the set `to`, optionally in one path group.
# OpenSTA puts the recovery and removal checks at asynchronous pins in the group "asynchronous" and every other check in the group of
# its clock ("clk"); a set of data pins from `all_registers -data_pins` includes the asynchronous pins, so the reset classes are
# told apart by path group and not by endpoint set.
proc path_class {name from to {group ""}} {
    foreach kind {max min} {
        section "$name $kind"
        set cmd [list report_checks -path_delay $kind -from $from -to $to -group_path_count 1 -format full_clock_expanded \
                     -fields {slew cap fanout} -digits 3]
        if {$group ne ""} { lappend cmd -path_group $group }
        if {[catch {eval $cmd} err]} {
            sta::report_line "no $kind paths: $err"
        }
    }
}

# the ports of a set whose names match a glob pattern (req_addr[3] matches req_*)
proc ports_named {ports pattern} {
    set found {}
    foreach p $ports {
        if {[string match $pattern [get_name $p]]} { lappend found $p }
    }
    return $found
}

# report_checks writes to stdout; redirect every class into the file
set regs_clk  [all_registers -clock_pins]
set regs_data [all_registers -data_pins]
sta::redirect_file_begin $::env(STA_OUT)/timing.txt
if {[info exists ::env(STA_RESET_ONLY)] && $::env(STA_RESET_ONLY) eq "1"} {
    set reset_ports [reset_input_ports]
    if {[llength $reset_ports] > 0} {
        # recovery and removal at the reset pins; rst_n through logic to a flip-flop's D; rst_n to an output
        path_class "reset_async" $reset_ports [all_registers -async_pins] asynchronous
        path_class "reset_data" $reset_ports [all_registers -data_pins] clk
        path_class "reset2out" $reset_ports [all_outputs] clk
    }
    sta::redirect_file_end
    exit
}
section "overall max"
report_checks -path_delay max -group_path_count 1 -format full_clock_expanded -fields {slew cap fanout} -digits 3
section "overall min"
report_checks -path_delay min -group_path_count 1 -digits 3
# STA_BRIEF=1 (the verification runs of the Fmax bracket) stops here: only the overall worst slack is needed, and the per-class
# reports with every register pin as a -from or -to set cost 30 to 45 s each on a 900,000-cell netlist.
if {[info exists ::env(STA_BRIEF)] && $::env(STA_BRIEF) eq "1"} {
    sta::redirect_file_end
    exit
}
if {[llength $regs_clk] > 0} {
    path_class "reg2reg" $regs_clk $regs_data
    path_class "in2reg" [all_inputs] $regs_data
    path_class "reg2out" $regs_clk [all_outputs]
}
path_class "in2out" [all_inputs] [all_outputs]
set req_in   [ports_named [all_inputs] "req_*"]
set resp_out [ports_named [all_outputs] "resp_*"]
if {[llength $req_in] > 0 && [llength $resp_out] > 0} {
    path_class "req2resp" $req_in $resp_out
}
section "limits"
report_check_types -max_slew -max_capacitance -max_fanout
report_wns
report_tns
sta::redirect_file_end

sta::redirect_file_begin $::env(STA_OUT)/power.txt
report_power
sta::redirect_file_end
exit

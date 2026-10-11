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
# register, register to output and input to output (the combinational hit path of PF-01), each headed by a line "=== class ===".
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

proc path_class {name from to} {
    foreach kind {max min} {
        section "$name $kind"
        if {[catch {
            report_checks -path_delay $kind -from $from -to $to -group_path_count 1 -format full_clock_expanded \
                -fields {slew cap fanout} -digits 3
        } err]} {
            sta::report_line "no $kind paths: $err"
        }
    }
}

# report_checks writes to stdout; redirect every class into the file
set regs_clk  [all_registers -clock_pins]
set regs_data [all_registers -data_pins]
sta::redirect_file_begin $::env(STA_OUT)/timing.txt
if {[info exists ::env(STA_RESET_ONLY)] && $::env(STA_RESET_ONLY) eq "1"} {
    set reset_ports [reset_input_ports]
    if {[llength $reset_ports] > 0} {
        path_class "reset_async" $reset_ports [all_registers -async_pins]
        path_class "reset_data" $reset_ports [all_registers -data_pins]
        path_class "reset2out" $reset_ports [all_outputs]
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
section "limits"
report_check_types -max_slew -max_capacitance -max_fanout -violators
report_wns
report_tns
sta::redirect_file_end

sta::redirect_file_begin $::env(STA_OUT)/power.txt
report_power
sta::redirect_file_end
exit

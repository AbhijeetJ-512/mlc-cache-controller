# mlc.sdc - timing constraints for ONE unit analysed on its own (Phase 8, D-041). Read by scripts/sta.tcl.
#
# Parameters, from the environment (scripts/sta_run.py sets them):
#   STA_PERIOD_NS     clock period in ns
#   STA_IN_DELAY_NS   delay of every data input after the clock edge, min and max (default 0.35)
#   STA_OUT_DELAY_NS  delay required of every output before the next edge (default 0.15)
#
# What the numbers stand for. A unit has no real neighbours here, so its boundary is modelled as if it were driven by and
# captured by a flip-flop of the same library on the same ideal clock: 0.35 ns is the order of a dfxtp_1 clock-to-Q at a small
# load and 0.15 ns of its setup time (both read from the checked-in reports, e.g. 0.352 and 0.121 to 0.190 ns). The minimum input
# delay equals the maximum, so a hold check on an input is a check against a neighbour that is not faster than that (hold is met even at
# zero input delay on the four points of `make sta-sensitivity`, worst +0.081 ns, so this does not decide hold). Inputs
# are driven by an inv_2 and outputs load 0.033442 pF: the same assumptions the timing-driven mapping used (abc_speed.constr).
# They are assumptions about the boundary, not measurements, and they are small beside the multi-nanosecond paths found.
# The clock is ideal: no skew, no uncertainty, no wire parasitics (there is no placement yet; Phase 9).
#
# The reset ports. rst_n (and async_rst_n in reset_sync) drive every flip-flop's asynchronous reset pin directly, so the input net
# has a fan-out of up to about 1,800 and nothing in this flow buffers it: ABC buffers only the logic it maps, and the reset pins
# are not part of that logic. P&R builds the reset tree (Phase 9), and in the integrated design the port is the output of
# reset_sync's flip-flop. So in the main analysis every path that starts at a reset port is a false path (STA_RESET_FALSE_PATH=1,
# the default), and the reset network is analysed on its own with STA_RESET_ONLY=1 (see scripts/sta.tcl), its unbuffered delay and
# fan-out recorded as a separate figure. This removes the recovery, removal and rst_n-to-output checks from the minimum period;
# the real tree adds an estimated few buffer levels, which are not in the figure.

proc env_or {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $default
}

set period    [expr {double($::env(STA_PERIOD_NS))}]
set in_delay  [expr {double([env_or STA_IN_DELAY_NS 0.35])}]
set out_delay [expr {double([env_or STA_OUT_DELAY_NS 0.15])}]

set clk_port [get_ports -quiet clk]
if {[llength $clk_port] > 0} {
    create_clock -name clk -period $period $clk_port
    set data_inputs [lsearch -inline -all -not -exact [all_inputs] $clk_port]
} else {
    # a unit with no clock port (the L2-L3 adapter is pure wiring and logic) is constrained against a virtual clock of the same name
    create_clock -name clk -period $period
    set data_inputs [all_inputs]
}
set_input_delay  $in_delay  -clock clk $data_inputs
set_output_delay $out_delay -clock clk [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 $data_inputs
set_load 0.033442 [all_outputs]

# the reset INPUT ports (reset_sync has rst_n as an output, which is not a start point)
proc reset_input_ports {} {
    set found {}
    foreach p [all_inputs] {
        if {[get_name $p] in {rst_n async_rst_n}} { lappend found $p }
    }
    return $found
}
set reset_ports [reset_input_ports]
if {[llength $reset_ports] > 0 && [env_or STA_RESET_FALSE_PATH 1] eq "1"} {
    set_false_path -from $reset_ports
}

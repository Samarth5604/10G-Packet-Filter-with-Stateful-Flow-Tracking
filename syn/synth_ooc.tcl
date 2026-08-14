# Out-of-context synthesis and implementation for one block.
#
# Non-project mode: takes -part directly, has no concept of a board, and
# produces the same reports on any 2024.1 install. Reports are the checked-in
# artifact; the run itself is disposable.
#
#   vivado -mode batch -source syn/synth_ooc.tcl \
#          -tclargs <part> <top> <rtl_dir> <reports_dir>
#
# Constraints are read from syn/<top>.xdc if present. They must be read BEFORE
# synth_design: create_clock needs an elaborated design, and a constraint
# applied after synthesis would not have influenced it.

if {$argc < 4} {
    puts "usage: synth_ooc.tcl <part> <top> <rtl_dir> <reports_dir>"
    exit 1
}

set part    [lindex $argv 0]
set top     [lindex $argv 1]
set rtl_dir [lindex $argv 2]
set rpt_dir [lindex $argv 3]
set xdc     "syn/${top}.xdc"
# Parameterised blocks share one constraints file: cam_d12_w104 and cam_d32_w104
# differ only in depth, and the clock and I/O budget are identical.
if {![file exists $xdc] && [string match "cam_d*" $top]} {
    set xdc "syn/cam.xdc"
}

file mkdir $rpt_dir

set sources [glob -nocomplain -directory $rtl_dir *.v *.sv]
if {[llength $sources] == 0} {
    puts "ERROR: no sources in $rtl_dir"
    exit 1
}
foreach f $sources {
    puts "reading $f"
    read_verilog -sv $f
}

if {[file exists $xdc]} {
    puts "reading constraints $xdc"
    read_xdc $xdc
} else {
    puts "WARNING: $xdc not found -- synthesising unconstrained, timing meaningless"
}

synth_design -top $top -part $part -mode out_of_context
report_utilization -file $rpt_dir/${top}_utilization_synth.rpt

# HD.CLK_SRC: without it, out-of-context mode cannot estimate clock delay or
# skew and analyses the path as if the clock were ideal. It cannot go in the
# XDC -- that file is a restricted Tcl subset with no control flow, and the
# buffer site name varies by family (BUFGCTRL on 7-series, BUFGCE on
# UltraScale+), so hardcoding one is a critical warning and a silently
# unapplied constraint. Look it up here instead, with the design open.
set _clk_port [get_ports -quiet clock]
if {[llength $_clk_port] == 0} {
    puts "WARNING: no port named 'clock'; skipping HD.CLK_SRC"
} else {
    set _bufg [lindex [lsort [get_sites -quiet -filter {SITE_TYPE =~ BUFGCE*}]] 0]
    if {$_bufg eq ""} {
        set _bufg [lindex [lsort [get_sites -quiet -filter {SITE_TYPE =~ BUFGCTRL*}]] 0]
    }
    if {$_bufg eq ""} {
        puts "WARNING: no global buffer site found; clock skew will not be modelled"
    } else {
        set_property HD.CLK_SRC $_bufg $_clk_port
        puts "HD.CLK_SRC = $_bufg"
    }
}

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file $rpt_dir/${top}_timing.rpt -warn_on_violation
report_utilization    -file $rpt_dir/${top}_utilization.rpt
catch { report_ram_utilization -file $rpt_dir/${top}_ram.rpt }

# Two numbers, because they mean different things in out-of-context mode.
#
# reg-to-reg is the block's own logic depth: fully routed, accurate, and
# unchanged when the block is instantiated in a larger design. It is only
# meaningful if the block's outputs are REGISTERED -- otherwise the combinational
# result sits on the port paths and reg-to-reg covers nothing but the pipeline
# registers, reporting huge slack that means nothing.
#
# overall includes port paths, which have no HD.PARTPIN_LOCS and so are not
# routed. Those are governed by the budgeted input/output delays and should be
# read as a budget check, not a measurement.
#
# If reg-to-reg slack is close to the full clock period, suspect unregistered
# outputs before believing the frequency.

proc worst_slack {paths} {
    if {[llength $paths] == 0} { return "n/a" }
    return [get_property SLACK [lindex $paths 0]]
}

set r2r [get_timing_paths -quiet -delay_type max -max_paths 1 \
             -from [all_registers] -to [all_registers]]
set all [get_timing_paths -quiet -delay_type max -max_paths 1]
# Hold is gated on INTERNAL paths only. Across an out-of-context boundary,
# Vivado launches from an ideal external clock but captures on a flop that sees
# BUFG insertion delay (~2.6 ns here), so port paths carry a fixed positive skew
# that flatters setup and penalises hold by the same amount. The router cannot
# compensate: port nets have no HD.PARTPIN_LOCS, so no detour is available.
# In the assembled design both flops are internal and share the clock tree, so
# that skew does not exist. Port hold is reported below as information, never
# as a pass/fail criterion -- and raising set_input_delay -min until it passes
# would be tuning the constraint to fit the answer.
set hld [get_timing_paths -quiet -delay_type min -max_paths 1 \
             -from [all_registers] -to [all_registers]]
set hld_io [get_timing_paths -quiet -delay_type min -max_paths 1]

set wns_r2r [worst_slack $r2r]
set wns_all [worst_slack $all]
set whs     [worst_slack $hld]
set whs_io  [worst_slack $hld_io]

if {[llength $r2r] > 0} {
    report_timing -of_objects $r2r -file $rpt_dir/${top}_critical_path.rpt
}

puts "==================================================================="
puts " $top on $part"
puts "   period          : 6.400 ns (156.25 MHz)"
puts "   WNS reg-to-reg  : $wns_r2r ns"
puts "   WNS overall     : $wns_all ns  (includes budgeted port paths)"
puts "   WHS hold (r2r)  : $whs ns"
puts "   WHS hold (all)  : $whs_io ns  (port paths: OOC artifact, not gated)"
if {$wns_r2r ne "n/a"} {
    puts [format "   max frequency   : %.1f MHz" [expr {1000.0 / (6.400 - $wns_r2r)}]]
} else {
    puts "   NOTE: no register-to-register paths. Every path is port-to-register,"
    puts "         so this slack reflects the I/O budget and clock insertion delay"
    puts "         rather than the logic. Synthesise the registered-input variant"
    puts "         (make rtl; make synth TOP=${top}_ooc) to measure logic depth."
}
puts "==================================================================="

# Gate on BOTH setup and hold. Checking setup alone reported a clean pass on a
# design Vivado had already flagged with a timing CRITICAL WARNING.
set failed 0
if {$wns_all ne "n/a" && $wns_all < 0} { puts "SETUP FAILED"; set failed 1 }
if {$whs     ne "n/a" && $whs     < 0} { puts "HOLD FAILED (internal)"; set failed 1 }
if {$whs eq "n/a"} {
    puts "NOTE: no internal paths to hold-check. This block is combinational"
    puts "      between ports; characterise ${top}_ooc instead."
}
if {$failed} { exit 1 }
# Out-of-context synthesis and implementation for one block.
#
# Non-project mode: takes -part directly, has no concept of a board, and
# produces the same reports on any 2024.1 install. Reports are the checked-in
# artifact; the run is disposable.
#
#   vivado -mode batch -source syn/synth_ooc.tcl -tclargs <part> <top> <rtl_dir> <reports_dir>

if {$argc < 4} {
    puts "usage: synth_ooc.tcl <part> <top> <rtl_dir> <reports_dir>"
    exit 1
}

set part     [lindex $argv 0]
set top      [lindex $argv 1]
set rtl_dir  [lindex $argv 2]
set rpt_dir  [lindex $argv 3]

file mkdir $rpt_dir

foreach f [glob -nocomplain -directory $rtl_dir *.v *.sv] {
    read_verilog -sv $f
}

# 156.25 MHz = 6.4 ns. The datapath clock for 10G at 64-bit.
create_clock -period 6.400 -name clk [get_ports clk]

synth_design -top $top -part $part -mode out_of_context
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file $rpt_dir/${top}_timing.rpt -warn_on_violation
report_utilization    -file $rpt_dir/${top}_utilization.rpt
report_ram_utilization -file $rpt_dir/${top}_ram.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "=== $top : WNS = $wns ns on $part ==="
if {$wns < 0} {
    puts "TIMING FAILED"
    exit 1
}

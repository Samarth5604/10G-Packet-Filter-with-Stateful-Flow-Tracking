# Timing constraints for out-of-context synthesis of header_parser.
#
# Read BEFORE synth_design so the constraint is in force during synthesis.
# Applying it afterwards would leave synthesis unconstrained and make the
# post-route numbers describe a netlist that was never optimised for 156.25 MHz.
#
# 6.400 ns = 156.25 MHz, the 64-bit datapath clock for 10G line rate.
# The port is named `clock`: that is what Hardcaml emits.

create_clock -period 6.400 -name clock [get_ports clock]

# HD.CLK_SRC is NOT set here. XDC is a restricted Tcl subset -- no if, no catch,
# no procs -- and the buffer site name is family-specific (BUFGCTRL on 7-series,
# BUFGCE on UltraScale+), so it must be looked up rather than hardcoded. That
# lookup lives in syn/synth_ooc.tcl, which is full Tcl and runs with the design
# open, which set_property HD.CLK_SRC requires in any case.

# OOC: no board, no I/O buffers, so input and output delays are budgeted as a
# fraction of the period rather than derived from real off-chip timing. 40% in
# and 40% out leaves 20% for this block, which is deliberately pessimistic --
# it flags a marginal path here rather than hiding it until integration.
set_input_delay  -clock clock 2.560 [get_ports {in_data[*] in_valid in_last clear}]
set_output_delay -clock clock 2.560 [get_ports {hdr_valid hdr_parsed hdr_err[*] hdr_key[*]}]

# NOT set: HD.PARTPIN_LOCS. Without pin locations the router cannot route port
# nets, so port-path timing is approximate and Vivado warns once per port. That
# is inherent to out-of-context analysis and is not worth silencing: this block
# is never a top level in the real design, where these ports become internal
# nets. The input/output delays above are the budget that stands in for them.
#
# The number that characterises this block is register-to-register WNS, which
# synth_ooc.tcl reports separately for exactly this reason.

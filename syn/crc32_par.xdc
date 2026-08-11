# Timing constraints for out-of-context synthesis of crc32_par.
#
# Same 6.400 ns period as the parser: this block sits in the same datapath and
# must sustain one beat per cycle at 156.25 MHz.
#
# The critical path here is a 52-input XOR reduction (64-bit width, worst-case
# output bit), which should map to three LUT6 levels. If it does not close, the
# fix is a pipeline stage between the XOR tree and the byte-count mux, not a
# different polynomial.

create_clock -period 6.400 -name clock [get_ports clock]

# HD.CLK_SRC is set in syn/synth_ooc.tcl, not here -- XDC is a restricted Tcl
# subset with no control flow, and the buffer site name is family-specific.

set_input_delay  -clock clock 2.560 [get_ports {crc_in[*] data[*] keep[*] en clear}]
set_output_delay -clock clock 2.560 [get_ports {crc_out[*]}]

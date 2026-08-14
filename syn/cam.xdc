# Timing constraints for out-of-context synthesis of a CAM instance.
#
# Same 6.400 ns period as the rest of the datapath: both CAM instances sit on
# the per-packet path and must sustain one search per cycle.
#
# The block registers its outputs, so register-to-register timing measures the
# comparator array and the match reduction -- which is the number the depth
# sweep is trying to compare. Inputs are unregistered here, so overall WNS is
# dominated by the port budget and should be read as a budget check only.

create_clock -period 6.400 -name clock [get_ports clock]

# HD.CLK_SRC is set in syn/synth_ooc.tcl, not here -- XDC has no control flow
# and the buffer site name is family-specific.

set_input_delay  -clock clock 2.560 [get_ports {search_key[*] wr_key[*] wr_idx[*] wr_en wr_valid clear}]
set_output_delay -clock clock 2.560 [get_ports {match_found match_idx[*] free_idx[*] full}]

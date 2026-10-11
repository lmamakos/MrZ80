project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
update_timing_netlist
set core "emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM"
set t80 [get_registers "$core|T80s:cpu1|*"]
foreach_in_collection op [get_available_operating_conditions] {
  set_operating_conditions $op
  update_timing_netlist
  report_timing -setup -npaths 5000 -less_than_slack 0 -detail summary -file "tmp/cen_allfail_$op.txt"
  report_timing -setup -npaths 10 -from $t80 -to $t80 -detail summary -file "tmp/cen_s_tt_$op.txt"
  report_timing -setup -npaths 10 -to $t80 -detail summary -file "tmp/cen_s_xt_$op.txt"
  report_timing -setup -npaths 10 -from $t80 -detail summary -file "tmp/cen_s_tx_$op.txt"
  report_timing -hold -npaths 10 -to $t80 -detail summary -file "tmp/cen_h_xt_$op.txt"
  report_timing -hold -npaths 10 -from $t80 -detail summary -file "tmp/cen_h_tx_$op.txt"
  report_timing -setup -npaths 3 -to $t80 -detail full_path -file "tmp/cen_sfull_xt_$op.txt"
}
delete_timing_netlist
project_close

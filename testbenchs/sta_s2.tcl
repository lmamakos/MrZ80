project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
update_timing_netlist
set core "emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM"
set t80 [get_registers "$core|T80s:cpu1|*"]
foreach_in_collection op [get_available_operating_conditions] {
  set_operating_conditions $op
  update_timing_netlist
  report_timing -setup -npaths 5000 -less_than_slack 0 -detail summary -file "tmp/s2_allfail_$op.txt"
  report_timing -hold -npaths 100 -less_than_slack 0 -detail summary -file "tmp/s2_holdfail_$op.txt"
  report_timing -setup -npaths 5 -to $t80 -detail summary -file "tmp/s2_s_xt_$op.txt"
  report_timing -setup -npaths 5 -to [get_registers "$core|sdram_*"] -detail summary -file "tmp/s2_s_fsm_$op.txt"
  report_timing -setup -npaths 5 -from $t80 -detail summary -file "tmp/s2_s_tx_$op.txt"
}
delete_timing_netlist
project_close

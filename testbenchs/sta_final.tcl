project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection op [get_available_operating_conditions] {
  set_operating_conditions $op
  update_timing_netlist
  set n [get_operating_conditions_info $op -display_name]
  report_timing -setup -npaths 400 -less_than_slack 0 -detail summary -file "tmp/final_setup_$op.txt"
  report_timing -hold -npaths 100 -less_than_slack 0 -detail summary -file "tmp/final_hold_$op.txt"
}
delete_timing_netlist
project_close

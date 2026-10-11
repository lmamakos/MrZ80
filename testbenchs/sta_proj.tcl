project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
update_timing_netlist
report_sdc -ignored -file tmp/proj_ignored.txt
create_timing_summary -setup -file tmp/proj_setup.txt
create_timing_summary -hold -file tmp/proj_hold.txt
report_clock_transfers -setup -file tmp/proj_xfers.txt
set s [get_clocks {*general[0]*}]
set r [get_clocks {*general[2]*}]
set c [get_clocks cpuClk]
foreach {a b n} [list $s $s ss $r $r rr $s $r sr $r $s rs $s $c sc $c $s cs $c $c cc] {
  report_timing -setup -from_clock $a -to_clock $b -npaths 25 -detail summary -file tmp/proj_setup_$n.txt
  report_timing -hold  -from_clock $a -to_clock $b -npaths 25 -detail summary -file tmp/proj_hold_$n.txt
}
delete_timing_netlist
project_close

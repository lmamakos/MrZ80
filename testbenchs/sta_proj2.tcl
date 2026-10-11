project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
update_timing_netlist
set s [get_clocks {*general[0]*}]
set r [get_clocks {*general[2]*}]
set c [get_clocks cpuClk]
report_timing -hold  -from_clock $s -to_clock $c -npaths 5000 -less_than_slack 0 -detail summary -file tmp/p2_hold_sc.txt
report_timing -setup -from_clock $c -to_clock $s -npaths 20000 -less_than_slack 0 -detail summary -file tmp/p2_setup_cs.txt
report_timing -setup -from_clock $c -to_clock $r -npaths 2000 -less_than_slack 0 -detail summary -file tmp/p2_setup_cr.txt
report_timing -setup -from_clock $s -to_clock $r -npaths 2000 -less_than_slack 0 -detail summary -file tmp/p2_setup_sr.txt
report_timing -setup -from_clock $c -to_clock $s -npaths 50 -detail summary -to [get_registers {*was_map_io_to_direct* *sdram_state* *sdram_we_reg* *sdram_rd_reg* *sdram_wait_n* *direct_access_pointer* *mmu_frame*}] -file tmp/p2_setup_cs_fsm.txt
delete_timing_netlist
project_close

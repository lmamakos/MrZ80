project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
update_timing_netlist
set c0 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set c2 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
report_timing -setup -from_clock $c0 -to_clock $c0 -npaths 15 -detail summary -file tmp/sta_sys_sys.txt
report_timing -setup -from_clock $c0 -to_clock $c0 -npaths 3 -detail full_path -file tmp/sta_sys_sys_full.txt
report_timing -setup -from_clock $c0 -to_clock $c2 -npaths 30 -detail summary -file tmp/sta_sys_ram.txt
report_timing -setup -from_clock $c2 -to_clock $c0 -npaths 10 -detail summary -file tmp/sta_ram_sys.txt
report_timing -setup -from_clock $c2 -to_clock $c2 -npaths 15 -detail summary -file tmp/sta_ram_ram.txt
report_timing -setup -from_clock $c0 -to_clock $c2 -npaths 2 -detail full_path -file tmp/sta_sys_ram_full.txt
report_clocks -file tmp/sta_clocks.txt
delete_timing_netlist
project_close

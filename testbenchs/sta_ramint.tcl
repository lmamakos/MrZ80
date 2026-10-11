project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
update_timing_netlist
set cr [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
report_timing -setup -from_clock $cr -to_clock $cr -npaths 10 -detail summary -file tmp/ramint_setup.txt
report_timing -hold -from_clock $cr -to_clock $cr -npaths 5 -detail summary -file tmp/ramint_hold.txt

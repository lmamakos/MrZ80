# Diagnostic only: define the derived cpuClock as a generated clock in this
# timing session (no project files are modified) and report the
# clk_sys <-> cpuClock transfers that are currently unanalysed.
project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
set c0pin [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name cpuClk -source $c0pin -edges {1 7 11} \
    [get_registers {emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM|cpuClock}]
update_timing_netlist
set c0 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set cc [get_clocks cpuClk]
report_clocks -file tmp/cc_clocks.txt
report_timing -hold  -from_clock $c0 -to_clock $cc -npaths 40 -detail summary -file tmp/cc_hold_sys_to_cpu.txt
report_timing -hold  -from_clock $c0 -to_clock $cc -npaths 40 -detail summary -from [get_registers {*sdram_wait_n*}] -file tmp/cc_hold_waitn.txt
report_timing -hold  -from_clock $c0 -to_clock $cc -npaths 3 -detail full_path -from [get_registers {*sdram_wait_n*}] -file tmp/cc_hold_waitn_full.txt
report_timing -setup -from_clock $c0 -to_clock $cc -npaths 20 -detail summary -file tmp/cc_setup_sys_to_cpu.txt
report_timing -setup -from_clock $cc -to_clock $c0 -npaths 20 -detail summary -file tmp/cc_setup_cpu_to_sys.txt
report_timing -hold  -from_clock $cc -to_clock $c0 -npaths 20 -detail summary -file tmp/cc_hold_cpu_to_sys.txt
report_timing -setup -from_clock $cc -to_clock $cc -npaths 10 -detail summary -file tmp/cc_setup_cpu_cpu.txt
report_timing -hold  -from_clock $cc -to_clock $cc -npaths 10 -detail summary -file tmp/cc_hold_cpu_cpu.txt
create_timing_summary -hold  -file tmp/cc_summary_hold.txt
create_timing_summary -setup -file tmp/cc_summary_setup.txt
delete_timing_netlist
project_close

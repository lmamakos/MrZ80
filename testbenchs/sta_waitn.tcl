project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
set c0pin [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name cpuClk -source $c0pin -edges {1 7 11} [get_registers {emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM|cpuClock}]
update_timing_netlist
set c0 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set cc [get_clocks cpuClk]
foreach src {sdram_wait_n sdramReadData*} {
  set f [open "tmp/waitn_$src.txt" w]
  foreach_in_collection p [get_timing_paths -setup -from_clock $c0 -to_clock $cc -from [get_registers "*MicrocomputerZ80CPM|$src"] -npaths 5000 -pairs_only] {
    set arr [get_path_info $p -arrival_time]
    set dst [get_node_info -name [get_path_info $p -to]]
    set req [get_path_info $p -required_time]
    set slk [get_path_info $p -slack]
    set lat [get_path_info $p -latch_time]
    set ck [get_path_info $p -clock_skew]
    puts $f [format "%8.3f %8.3f %8.3f %8.3f %s" $arr $req $slk $ck $dst]
  }
  close $f
}
delete_timing_netlist
project_close

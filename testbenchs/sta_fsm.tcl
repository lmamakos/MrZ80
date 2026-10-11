project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
set c0pin [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name cpuClk -source $c0pin -edges {1 7 11} [get_registers {emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM|cpuClock}]
update_timing_netlist
set c0 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set cc [get_clocks cpuClk]
set f [open "tmp/fsm_endpoints.txt" w]
foreach pat {*sdram_state* *sdram_rd_reg* *sdram_we_reg* *sdram_wait_n* *sdram_gap_cnt* *mmu1|was_map_io_to_direct* *mmu1|direct_access_pointer* *mmu1|mmu_frame* *fpLatch* *bram* *ram1*porta_we_reg* *ram1*porta_datain_reg* *ram1*porta_address_reg* *iorq* *io2|* *sd1|* *io1|*} {
  set ps [get_timing_paths -setup -from_clock $cc -to_clock $c0 -to [get_registers $pat] -npaths 1]
  foreach_in_collection p $ps {
    puts $f [format "%8.3f  %-28s %s -> %s" [get_path_info $p -slack] $pat [get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
  }
}
close $f
delete_timing_netlist
project_close

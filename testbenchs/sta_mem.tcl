project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
update_timing_netlist
set core "emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM"
set t80 [get_registers "$core|T80s:cpu1|*"]
set mem [get_registers [list "$core|InternalRam64K:ram1|*" "$core|Z80_CPM_BASIC_ROM:rom1|*"]]
foreach_in_collection op [get_available_operating_conditions] {
  set_operating_conditions $op
  update_timing_netlist
  report_timing -setup -npaths 3 -from $t80 -to $mem -detail summary -file "tmp/cen_mem_$op.txt"
}
delete_timing_netlist
project_close

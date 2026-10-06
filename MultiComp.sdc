# ============================================================================
# MultiComp.sdc - project-level timing constraints (MultiComp core).
#
# sys/sys_top.sdc (maintained externally, never edit) defines the board/PLL
# clocks and puts every output of the core PLL (emu|pll) in ONE clock group,
# so Quartus analyses the clk_sys <-> clk_ram crossing as if it were
# synchronous. This file adds what the core itself needs. It is read after sys_top.sdc (it is
# listed after sys/sys.qip in MultiComp.qsf), so the PLL clocks exist.
#
# See SDRAM-review-handoff.md sections 5 and 8 (step 5) for the analysis
# behind each constraint.
# ============================================================================

# ---- clocks ----------------------------------------------------------------
# clk_sys = PLL outclk_0 (50.000 MHz), clk_ram = PLL outclk_2 (96.667 MHz,
# SDRAM_CLK_100 in MultiComp.sv).
set clk_sys     [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set clk_ram     [get_clocks {*|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]

set core "emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM"

derive_clock_uncertainty

# ---- T80 clock enable (REQUIREMENTS.md item 4.1) ----------------------------
# The T80 is clocked by clk_sys and advances only on clk_sys edges at which
# the register cpu_cen is high: one edge in five (10 MHz). Every T80
# register (T80.vhd, T80_Reg.vhd and T80s.vhd's strobe/DI_Reg process) is
# gated by that enable, so all CPU paths are ordinary clk_sys paths with
# normal, skew-free setup and hold checks. (Before item 4.1 the T80 ran on
# a fabric-derived cpuClock register; the generated clock, the
# clk_sys -> cpuClk hold relaxations and the accepted peripheral-read hold
# violations that went with it are gone.)
set t80_regs [get_registers "$core|T80s:cpu1|*"]

# T80 -> T80: launched and captured only on cpu_cen edges, which are 5
# clk_sys periods apart, so 5 periods of setup are available; the hold
# check stays on the launch edge. This covers the paths that leave the
# core and come back through the address decode, MMU read-back and the
# cpuDataIn mux. Paths from other clk_sys registers into the T80
# (peripheral data, sdramReadData, sdram_wait_n, block-RAM q, n_RomActive)
# are NOT relaxed: they can change on any clk_sys edge, including the one
# just before a cpu_cen edge, so they get the normal one-period check.
set_multicycle_path -setup -end 5 -from $t80_regs -to $t80_regs
set_multicycle_path -hold  -end 4 -from $t80_regs -to $t80_regs

# Quasi-static configuration inputs: only change during download/reset
# while the CPU is held in reset.
set_false_path -from [get_registers {emu:emu|bin_loaded}] -to $t80_regs
set_false_path -from [get_registers {emu:emu|hps_io:hps_io|status[13]}] -to $t80_regs

# ---- T80 -> block RAM / boot ROM (setup) ------------------------------------
# Their input registers sample the T80 address/data/strobes on every clk_sys
# edge, but the T80 only uses the result at a later cpu_cen edge:
#   reads  - the address is driven at the start of a T-state and the data
#            captured at least one full T-state (5 clk_sys periods) later,
#            so only the clk_sys samples from 4 periods after the launch
#            edge onwards matter;
#   writes - the address is stable from T1; WR_n/DO change together at a
#            cpu_cen edge and WR_n stays low for at least a full T-state,
#            so writes at the first clk_sys edges may store unsettled data
#            but the final write(s) of the window store the settled value;
#            when WR_n rises the address and data are unchanged until the
#            next T-state, and wren (n_memWR OR chip-select) is held low
#            by n_memWR whatever the address does.
# Allow 4 clk_sys periods for these paths; the hold check stays on the
# launch edge (-hold -end 3).
set mem_regs [get_registers [list \
    "$core|InternalRam64K:ram1|*" \
    "$core|Z80_CPM_BASIC_ROM:rom1|*" ]]
set_multicycle_path -setup -end 4 -from $t80_regs -to $mem_regs
set_multicycle_path -hold  -end 3 -from $t80_regs -to $mem_regs

# Front-panel LED capture chain: snapshots cpuAddress/cpuDataIn every clk
# purely for display on the LED string. A wrong sample is never used by the
# CPU and is overwritten on the next clk.
set_false_path -from $t80_regs -to [get_registers "$core|Transparent_Capture_Chain:*|captured_bits[*]"]

# ---- clk_sys <-> clk_ram CDC (MultiComp.sv SDRAM adapter) -----------
# Request level (sdram_we_mux | sdram_rd_mux) -> 2-FF synchroniser req_sync.
# Address/data/direction (ram_addr, ram_din, ram_rnw) are captured only on
# the synchronised rising edge of that level, >= 2 clk_ram cycles after the
# clk_sys side asserted it, and the clk_sys side holds them stable for the
# whole transaction. (The address comes combinationally from the T80
# address bus through the MMU.)
# Completion: ram_done toggle -> 2-FF done_sync; ram_byte is written on the
# same clk_ram edge as the toggle and is not sampled by clk_sys
# (sdramReadData) until >= 2 clk_sys cycles later.
set_false_path -to [get_registers {emu:emu|req_sync[0]}]
set_false_path -to [get_registers {emu:emu|ram_addr[*] emu:emu|ram_din[*] emu:emu|ram_rnw}]
set_false_path -from $clk_ram -to [get_registers {emu:emu|done_sync[0]}]
set_false_path -from [get_registers {emu:emu|ram_byte[*]}] -to $clk_sys

# SDRAM controller init (sdram_init_reset = RESET | status[0] | buttons[1] |
# reset_from_mount) is an unsynchronised level into clk_ram. Each source is
# held for many thousands of clk_ram cycles (reset_from_mount: 65536 clk_sys
# cycles), so a one-cycle skew between controller registers on assertion or
# release is harmless: the controller restarts its full init sequence.
set_false_path -from [get_registers {emu:emu|reset_from_mount}] -to $clk_ram

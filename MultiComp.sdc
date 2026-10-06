# ============================================================================
# MultiComp.sdc - project-level timing constraints (MultiComp core).
#
# sys/sys_top.sdc (maintained externally, never edit) defines the board/PLL
# clocks and puts every output of the core PLL (emu|pll) in ONE clock group,
# so Quartus analyses the clk_sys <-> clk_ram crossing as if it were
# synchronous, and the derived CPU clock is not defined at all. This file
# adds what the core itself needs. It is read after sys_top.sdc (it is
# listed after sys/sys.qip in MultiComp.qsf), so the PLL clocks exist.
#
# See SDRAM-review-handoff.md sections 5 and 8 (step 5) for the analysis
# behind each constraint.
# ============================================================================

# ---- clocks ----------------------------------------------------------------
# clk_sys = PLL outclk_0 (50.000 MHz), clk_ram = PLL outclk_2 (96.667 MHz,
# SDRAM_CLK_100 in MultiComp.sv).
set clk_sys_pin [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set clk_sys     [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set clk_ram     [get_clocks {*|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]

set core "emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM"

# cpuClock: the T80's clock, a REGISTER in MicrocomputerZ80CPM.vhd that
# divides clk_sys by 5 (high 3 / low 2 clk_sys periods). It rises on the
# clk_sys edge at which (old) cpuClkCount = 2. Source edges counted on
# clk_sys (edge 1 = rising at 0 ns, edge 2 = falling at 10 ns, ...):
# rise at edge 1 (0 ns), fall at edge 7 (60 ns), next rise at edge 11
# (100 ns). Without this every path into/out of the T80 is unanalysed.
create_generated_clock -name cpuClk -source $clk_sys_pin -edges {1 7 11} \
    [get_registers "$core|cpuClock"]
set cpu_clk [get_clocks cpuClk]

derive_clock_uncertainty

# ---- clk_sys -> cpuClk (hold) ----------------------------------------------
# cpuClk is a register output on a global, so it arrives several ns after
# the clk_sys edge it is derived from. A clk_sys register that changes ON
# the clk_sys edge where cpuClk rises can therefore race the T80 capture
# (fast-corner hold violations of ~-4 ns): individual T80 flops may see the
# old or the new value. The registers below provably never change on that
# edge, so the default same-edge hold check is pessimistic for them and is
# moved one clk_sys period later (-hold -start 1). Setup is unchanged
# (launch one clk_sys period before the cpuClk rising edge).
#
#  sdram_wait_n           asserted 1-2 clk_sys edges after a T80 edge; the
#                         S_DONE release is suppressed on the cpuClk rising
#                         edge (cpuClkCount guard, review step 3a).
#  sdramReadData          only loaded in S_REQ, while sdram_wait_n is low,
#                         so the T80 is not loading DI_Reg/IR then.
#  MMU mmu_frame,         written / post-incremented / updated on the first
#  direct_access_pointer, clk_sys edge after a T80 strobe change (the
#  was_map_io_to_direct   strobes are cpuClk-launched); repeat writes while
#                         WR_n stays low write the same value.
#  fpLatch (port 0xFF)    same as the MMU registers (written by OUT only).
#  block RAM / boot ROM   address is registered every clk_sys edge; on the
#  internal registers     cpuClk edge it re-registers the unchanged (old)
#                         T80 address, so q does not change on that edge.
set wait_safe [get_registers [list \
    "$core|sdram_wait_n" \
    "$core|sdramReadData[*]" \
    "$core|MMU:mmu1|mmu_frame[*][*]" \
    "$core|MMU:mmu1|direct_access_pointer[*]" \
    "$core|MMU:mmu1|was_map_io_to_direct" \
    "$core|fpLatch[*]" \
    "$core|InternalRam64K:ram1|*" \
    "$core|Z80_CPM_BASIC_ROM:rom1|*" ]]
set_multicycle_path -hold -start 1 -from $wait_safe -to $cpu_clk

# NOT relaxed (real, accepted for now): peripheral read registers
# (sd_controller dout/status flags, FrontPanel_Subsystem dout, ...)
# can change on any clk_sys edge, including the cpuClk rising edge, so an
# IN from such a port can capture a bit-wise mixture of old and new values.
# The fitter pads these paths to meet hold. The proper fix is clocking the
# T80 from clk_sys with a clock enable (REQUIREMENTS.md, review step 3b).

# Quasi-static configuration inputs: only change during download/reset
# while the CPU is held in reset.
set_false_path -from [get_registers {emu:emu|bin_loaded}] -to $cpu_clk
set_false_path -from [get_registers {emu:emu|hps_io:hps_io|status[13]}] -to $cpu_clk

# ---- cpuClk -> clk_sys (setup) ---------------------------------------------
# Block RAM / boot ROM: their input registers sample the T80 address/data/
# strobes on every clk_sys edge, but the T80 only uses the result at a later
# cpuClk edge:
#   reads  - address is driven at the start of T1 and data captured at the
#            end of T2 (>= 2 cpuClk periods later), so only the LAST
#            clk_sys sample before that edge matters;
#   writes - address is stable from T1; WR_n/DO change together at the
#            start of T2 and WR_n stays low until the end of T2, so writes
#            at the first clk_sys edges may store unsettled data but the
#            final write(s) of the window store the settled value.
# Allow 4 clk_sys periods (the full cpuClk period) for these paths; the hold
# check stays on the launch edge (-hold -end 3).
set mem_regs [get_registers [list \
    "$core|InternalRam64K:ram1|*" \
    "$core|Z80_CPM_BASIC_ROM:rom1|*" ]]
set_multicycle_path -setup -end 4 -from $cpu_clk -to $mem_regs
set_multicycle_path -hold  -end 3 -from $cpu_clk -to $mem_regs

# Front-panel LED capture chain: snapshots cpuAddress/cpuDataIn every clk
# purely for display on the LED string. A wrong sample is never used by the
# CPU and is overwritten on the next clk.
set_false_path -from $cpu_clk -to [get_registers "$core|Transparent_Capture_Chain:*|captured_bits[*]"]

# ---- clk_sys/cpuClk <-> clk_ram CDC (MultiComp.sv SDRAM adapter) -----------
# Request level (sdram_we_mux | sdram_rd_mux) -> 2-FF synchroniser req_sync.
# Address/data/direction (ram_addr, ram_din, ram_rnw) are captured only on
# the synchronised rising edge of that level, >= 2 clk_ram cycles after the
# clk_sys side asserted it, and the clk_sys side holds them stable for the
# whole transaction. (The address comes combinationally from the T80
# address bus through the MMU, hence launched by cpuClk as well as clk_sys.)
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

# sim/Makefile -- simulation & consistency targets (D-28 / D-29).
#
# Convention: heavy per-bench runs stay in the existing sim/run_*.sh
# scripts (GHDL, project-root-relative); this Makefile is the thin
# discovery surface. New SSP benches land here as sim/run_ssp_*.sh
# (integration, GHDL -- real T80/MMU/SDRAM, D-33 VHDL side) and
# sim/ssp/ (Verilator, RV side + BFM) with targets below.

ROOT := $(CURDIR)/..

.PHONY: regmap regmap-check sync fw smoke-qemu dict-qemu lint-ssp seam-check ssp-map p1a p1a-vcd dict-rtl smoke-p1a dl-path vdu terminal mrom-install tramp tramp-p1a uart-fifo integ-park mem-client integ-mux integ-core interval-timer itimer-z80 universal-chain cycle-golden engine-golden fw-rom fw-rom-check
regmap:
	python3 $(ROOT)/tools/ssp_regmap.py

# R-45: generated outputs must match ssp/regs/ssp_regs.csv (drift fails)
regmap-check:
	python3 $(ROOT)/tools/ssp_regmap.py --check

sync:
	$(ROOT)/sim/check_sync.sh

# top-level wiring of the SSP seam in MrZ80.sv (invisible to every bench)
seam-check:
	python3 $(ROOT)/sim/check_seam.py

# R43: one SSP memory map -- MROM size and dictionary window agree across the
# RTL (ssp_top, MrZ80.sv), the firmware (.s equates, linker maps) and the
# build scripts
ssp-map:
	python3 $(ROOT)/sim/check_ssp_map.py

# Mecrisp SSP firmware (needs $MECRISP, see ssp/fw/Makefile)
fw:
	$(MAKE) -C $(ROOT)/ssp/fw all

# RV-side FW REPL smoke on qemu (D-28 companion; no RTL required)
smoke-qemu:
	$(ROOT)/sim/ssp/smoke_qemu.sh

# D-35 build-pipeline rehearsal on qemu: compiletoflash dictionary build,
# QMP pmemsave capture, kernel+dict merge, cold-boot residency proof
dict-qemu:
	$(ROOT)/sim/ssp/dictbuild_qemu.sh

# (The P0 bake-off stub-SoC lanes -- stub, stub-gracilis, smoke-stub,
# smoke-gracilis, dict-stub, dict-gracilis, bench-* -- were retired in R43:
# the p1a lane below runs the real ssp_top with the selected core.)

# ---- P1a "first light" (gracilis + bridge + uart + BFM, D-28 lane 1) -------
# Lint gate (R25/P1): -Wall over the whole Verilator lane; waivers are
# deliberate (phased-reg scaffold + vendor core + inert pins).
lint-ssp:
	cd $(ROOT) && verilator --lint-only -Wall \
	  -Wno-VARHIDDEN -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
	  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Issp/rtl --top-module ssp_top \
	  ssp/rtl/ssp_top.v ssp/rtl/ssp_bridge.v ssp/rtl/ssp_uart.v \
	  sim/ssp/ssp_sdp_ram.v Components/RISCV/femtorv32_gracilis.v
	@echo lint-ssp: OK

p1a:
	cd $(ROOT) && verilator --cc --exe --build \
	  -CFLAGS "-std=c++17" \
	  -Issp/rtl \
	  --top-module ssp_p1a_top -o ssp_p1a \
	  sim/ssp/tb_p1a_main.cpp sim/ssp/p1a_sim_top.v sim/ssp/z80_bfm.v \
	  ssp/rtl/ssp_top.v ssp/rtl/ssp_bridge.v ssp/rtl/ssp_uart.v \
	  sim/ssp/ssp_sdp_ram.v Components/RISCV/femtorv32_gracilis.v \
	  -Mdir sim/ssp/obj_p1a

# trace-instrumented twin for problem triage (+VCD -> sim/ssp/p1a.vcd)
p1a-vcd:
	cd $(ROOT) && verilator --cc --exe --build --trace \
	  -CFLAGS "-std=c++17" \
	  -Issp/rtl \
	  --top-module ssp_p1a_top -o ssp_p1a_dbg \
	  sim/ssp/tb_p1a_main.cpp sim/ssp/p1a_sim_top.v sim/ssp/z80_bfm.v \
	  ssp/rtl/ssp_top.v ssp/rtl/ssp_bridge.v ssp/rtl/ssp_uart.v \
	  sim/ssp/ssp_sdp_ram.v Components/RISCV/femtorv32_gracilis.v \
	  -Mdir sim/ssp/obj_p1adbg

# "G aaaa" (D-02/D-39): reset vent + reset-vector JP injector.
#   tramp      : ssp_tramp.vhd vs the REAL T80s (GHDL, sim/tb_tramp.vhd)
#   tramp-p1a  : bridge <-> FW <-> BFM handshake from the Mecrisp REPL
tramp:
	$(ROOT)/sim/run_tramp.sh

tramp-p1a: p1a
	$(ROOT)/sim/ssp/p1a_tramp.sh

# R-40: every SSP park lands on an instruction boundary (GHDL, real T80s)
integ-park:
	$(ROOT)/sim/run_integ_park.sh

# M3 (R40): parked physical memory client unit bench (GHDL)
mem-client:
	$(ROOT)/sim/run_mem_client.sh

# R-42 (SDRAM/BRAM/MMU half): engine through the real CPM fabric (GHDL)
integ-core:
	$(ROOT)/sim/run_integ_core.sh

# IntervalTimer ($D0-$D3, REQUIREMENTS.md item 7): unit bench, then INT through the
# real fabric into a Z80 program in interrupt modes 0 and 1 (GHDL, ~1 min)
interval-timer:
	$(ROOT)/sim/run_interval_timer.sh

itimer-z80:
	$(ROOT)/sim/run_itimer_z80.sh

# Front-panel Universal_Capture_Chain: STRETCH_MASK must pick the intended bits (GHDL, seconds)
universal-chain:
	$(ROOT)/sim/run_universal_chain.sh

# R-42: z80_bus_mux + real T80s + engine model (GHDL)
integ-mux:
	$(ROOT)/sim/run_integ_mux.sh

# R-42: SSP engine waveform == real T80 waveform.  cycle-golden captures the
# T80's data cycles (GHDL) and checks the committed sim/ssp/golden_cycles.txt;
# engine-golden replays the same cycle types through the real bridge engine.
cycle-golden:
	$(ROOT)/sim/run_cycle_golden.sh

engine-golden: p1a
	$(ROOT)/sim/ssp/p1a_engine_golden.sh

# ssp_uart RX FIFO unit bench (iverilog, depth 8 and 128; D-41)
uart-fifo:
	$(ROOT)/sim/ssp/run_uart_fifo.sh

# P1a dictionary build (monitor.fs into the p1a model; separate artifact
# name space -- P0 goldens untouched)
# The firmware artifacts are built from ssp/fw (make -C ssp/fw [image|rom|install]);
# these are kept as aliases.  Unlike before they rebuild only when monitor.fs, its
# includes, the register constants or the kernel changed.
dict-rtl:
	$(MAKE) -C $(ROOT)/ssp/fw image

smoke-p1a: p1a
	$(ROOT)/sim/ssp/p1a_smoke.sh

# R44: SSP console on its own video terminal (OSD entry, routing, keyboard)
vdu: p1a
	$(ROOT)/sim/ssp/p1a_vdu.sh

# R44: the video terminal itself + the SSP's instance (ssp_vdu) + the 6850
# master reset of both ACIA-style devices (GHDL, real terminal RTL)
terminal:
	$(ROOT)/sim/run_terminal.sh

# R43 (R-29): OSD ROM mount -- clear sweep, byte lanes, RV-only hold, monitor
# restart on the mounted image, guest never reset
dl-path: p1a
	$(ROOT)/sim/ssp/p1a_dlpath.sh

# Factory ROM (D-38): rebuild the monitor dictionary and regenerate the MIF
# the MROM instance loads.  Recommit ssp/fw/forth_rom.mif when it changes.
fw-rom:
	$(MAKE) -C $(ROOT)/ssp/fw rom

mrom-install:
	$(MAKE) -C $(ROOT)/ssp/fw install

fw-rom-check:
	$(MAKE) -C $(ROOT)/ssp/fw rom-check

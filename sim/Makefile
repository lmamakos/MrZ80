# sim/Makefile -- simulation & consistency targets (D-28 / D-29).
#
# Convention: heavy per-bench runs stay in the existing sim/run_*.sh
# scripts (GHDL, project-root-relative); this Makefile is the thin
# discovery surface. New SSP benches land here as sim/run_ssp_*.sh
# (integration, GHDL -- real T80/MMU/SDRAM, D-33 VHDL side) and
# sim/ssp/ (Verilator, RV side + BFM) with targets below.

ROOT := $(CURDIR)/..

.PHONY: regmap regmap-check sync fw smoke-qemu dict-qemu stub stub-gracilis smoke-stub smoke-gracilis dict-stub dict-gracilis bench-stub bench-stub-fab bench-gracilis lint-ssp p1a dict-p1a smoke-p1a tramp tramp-p1a uart-fifo integ-park integ-mux integ-core cycle-golden engine-golden fw-rom fw-rom-check
regmap:
	python3 $(ROOT)/tools/ssp_regmap.py

# R-45: generated outputs must match ssp/regs/ssp_regs.csv (drift fails)
regmap-check:
	python3 $(ROOT)/tools/ssp_regmap.py --check

sync:
	$(ROOT)/sim/check_sync.sh

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

# ---- Verilator stub SoC (RV side, hardware-true addresses; OQ-20 lane) -----
# picorv32 + ROM(hex)/DTCM + minimal ssp_bridge w/ console UART (D-33 RV side)
stub:
	cd $(ROOT) && verilator --cc --exe --build \
	  -CFLAGS "-std=c++17 -DSTUB_INC=Vssp_stub_top.h -DSTUB_CLASS=Vssp_stub_top" \
	  --top-module ssp_stub_top -o ssp_stub \
	  sim/ssp/tb_stub_main.cpp sim/ssp/ssp_stub_top.v \
	  Components/RISCV/picorv32.v -Mdir sim/ssp/obj_dir

# gracilis twin (FemtoRV32, D-34 ADDR_WIDTH=30) -- bake-off entrant B
stub-gracilis:
	cd $(ROOT) && verilator --cc --exe --build \
	  -CFLAGS "-std=c++17 -DSTUB_INC=Vssp_stub_gracilis.h -DSTUB_CLASS=Vssp_stub_gracilis" \
	  --top-module ssp_stub_gracilis -o ssp_gracilis \
	  sim/ssp/tb_stub_main.cpp sim/ssp/ssp_stub_gracilis.v \
	  Components/RISCV/femtorv32_gracilis.v -Mdir sim/ssp/obj_grac

# REPL smoke on the stub SoC (picorv32 twin of smoke-qemu; ID read-back
# $2000_0000 -> 4D525A03 proves the bridge decode against ssp_regs.csv)
smoke-stub: stub
	$(ROOT)/sim/ssp/smoke_stub.sh

smoke-gracilis: stub-gracilis
	TAG=gracilis MODEL=sim/ssp/obj_grac/ssp_gracilis \
	$(ROOT)/sim/ssp/smoke_stub.sh

# D-35 authoritative dictionary build at hardware addresses: harness-side
# rom[] capture -> merged OSD MROM artifact + cold-boot residency proof
dict-stub: stub
	$(ROOT)/sim/ssp/dictbuild_stub.sh

dict-gracilis: stub-gracilis
	TAG=gracilis MODEL=sim/ssp/obj_grac/ssp_gracilis \
	$(ROOT)/sim/ssp/dictbuild_stub.sh

# Cycle-level performance benchmarks (OQ-20 evidence, R22): EMIT-marker
# bracketed workloads over the console, TXTRACE cycle stamps -> CPI.
# bench-stub-fab models the D-36 launch+1 IP fabric (silicon-predictive
# pairing vs the natively-launch+1 gracilis stub).
bench-stub: stub
	$(ROOT)/sim/ssp/bench_stub.sh

bench-stub-fab: stub
	TAG=picorv32-fab EXTRA="+FABWAIT" $(ROOT)/sim/ssp/bench_stub.sh

bench-gracilis: stub-gracilis
	TAG=gracilis MODEL=sim/ssp/obj_grac/ssp_gracilis \
	$(ROOT)/sim/ssp/bench_stub.sh

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

# R-42 (SDRAM/BRAM/MMU half): engine through the real CPM fabric (GHDL)
integ-core:
	$(ROOT)/sim/run_integ_core.sh

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
dict-p1a: p1a
	$(ROOT)/sim/ssp/p1a_dictbuild.sh

smoke-p1a: p1a
	$(ROOT)/sim/ssp/p1a_smoke.sh

# Factory ROM (D-38): rebuild the monitor dictionary and regenerate the MIF
# the MROM instance loads.  Recommit ssp/fw/forth_rom.mif when it changes.
fw-rom: dict-p1a
	python3 $(ROOT)/tools/bin2mif.py $(ROOT)/ssp/fw/build/mecrisp-ssp-p1a-app.bin $(ROOT)/ssp/fw/forth_rom.mif 16384
	python3 $(ROOT)/tools/bin2mif.py --check $(ROOT)/ssp/fw/build/mecrisp-ssp-p1a-app.bin $(ROOT)/ssp/fw/forth_rom.mif 16384

# Drift check only (needs a prior dict-p1a build)
fw-rom-check:
	python3 $(ROOT)/tools/bin2mif.py --check $(ROOT)/ssp/fw/build/mecrisp-ssp-p1a-app.bin $(ROOT)/ssp/fw/forth_rom.mif 16384

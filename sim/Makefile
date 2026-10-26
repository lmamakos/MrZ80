# sim/Makefile -- simulation & consistency targets (D-28 / D-29).
#
# Convention: heavy per-bench runs stay in the existing sim/run_*.sh
# scripts (GHDL, project-root-relative); this Makefile is the thin
# discovery surface. New SSP benches land here as sim/run_ssp_*.sh
# (integration, GHDL -- real T80/MMU/SDRAM, D-33 VHDL side) and
# sim/ssp/ (Verilator, RV side + BFM) with targets below.

ROOT := $(CURDIR)/..

.PHONY: regmap regmap-check sync fw smoke-qemu dict-qemu stub stub-gracilis smoke-stub smoke-gracilis dict-stub dict-gracilis
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

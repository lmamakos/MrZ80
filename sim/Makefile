# sim/Makefile -- simulation & consistency targets (D-28 / D-29).
#
# Convention: heavy per-bench runs stay in the existing sim/run_*.sh
# scripts (GHDL, project-root-relative); this Makefile is the thin
# discovery surface. New SSP benches land here as sim/run_ssp_*.sh
# (integration, GHDL -- real T80/MMU/SDRAM, D-33 VHDL side) and
# sim/ssp/ (Verilator, RV side + BFM) with targets below.

ROOT := $(CURDIR)/..

.PHONY: regmap regmap-check sync
regmap:
	python3 $(ROOT)/tools/ssp_regmap.py

# R-45: generated outputs must match ssp/regs/ssp_regs.csv (drift fails)
regmap-check:
	python3 $(ROOT)/tools/ssp_regmap.py --check

sync:
	$(ROOT)/sim/check_sync.sh

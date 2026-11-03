# MrZ80 helper Makefile.
#
#   make fpga      full Quartus compile of the core -> output_files/MrZ80.rbf
#                  (Quartus 17.0 in Docker on tycho, via tools/build.sh)
#   make forth     CamelFORTH for the Z-80: the kernel binaries
#                  (camel80.bin, camelf.bin, camel80cpm.com) and the
#                  forth/blocks/forth.blk block file    [needs um80/ul80]
#   make profile   regenerate the front-panel profile files (profile.fpp,
#                  example_profiles.fpp) from their .yaml sources
#   make ssp       the SSP (RISC-V) Forth images: build/mrz80-ssp.mrz, which
#                  the OSD mounts as "SSP Monitor ROM", plus the factory ROM
#                  forth_rom.mif                     [needs riscv64-elf + MECRISP]
#   make install   copy the freshly built core image to the MiSTer SD card,
#                  stamped with the current date, e.g.
#                  /media/fat/_Computer/MrZ80_20261024.rbf
#
# Each target just dispatches to the Makefile that owns that artifact
# (forth/, Components/FRONTPANEL/tools/, ssp/fw/); those stay the source of
# truth for how each piece is built. `build` is the long-standing alias for
# `fpga`.

MRBF    := $(CURDIR)/output_files/MrZ80.rbf
MISTER  := mister
DESTDIR := /media/fat/_Computer

.PHONY: build fpga forth profile ssp install

build:
	./tools/build.sh

# Full FPGA bitstream: analysis, synthesis and place & route.
fpga: build

# CamelFORTH kernels and the bootable block file.
forth:
	$(MAKE) -C forth

# Front-panel profile files, from the .yaml of the same name.
profile:
	$(MAKE) -C Components/FRONTPANEL/tools

# SSP firmware: OSD-loadable .MRZ image and the committed factory ROM .mif.
# Recommit ssp/fw/forth_rom.mif whenever this changes.
ssp:
	$(MAKE) -C ssp/fw

install:
	@test -f "$(MRBF)" || { echo "No built image at $(MRBF) - build it first (tools/build.sh)." >&2; exit 1; }
	scp "$(MRBF)" "$(MISTER):$(DESTDIR)/MrZ80_$$(date +%Y%m%d).rbf"

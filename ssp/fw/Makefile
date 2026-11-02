# Mecrisp-Quintus for the MrZ80 SSP -- minimal RV32IMC, RAM dictionary,
# no flash / no MappedSPIFlash (D-32, R17).
#
# The one place to build the SSP firmware artifacts:
#
#   make            kernel + monitor image + factory ROM (all of the below)
#   make image      build/mrz80-ssp.mrz -- the 128 KiB image the OSD mounts
#                   ("SSP Monitor ROM"): kernel + the compiled monitor dictionary
#   make rom        forth_rom.mif -- the same image as the committed factory ROM
#                   (baked into the bitstream, D-38); needs a Quartus rebuild to ship
#   make check      ~2 s qemu compile check of apps/monitor.fs, nothing built
#   make install    scp the image to the MiSTer (MISTER_DEST=host:path)
#   make rom-check  fail if forth_rom.mif differs from the current image
#   make ssp|qemu   just the kernel (silicon map / qemu smoke variant)
#
# `image` and `rom` rebuild only when their inputs change: apps/monitor.fs, the
# files it @includes, ssp-regs.fs, the kernel sources and the build scripts.  The
# image is built by tools/ssp_image.py (qemu compile check, then the dictionary
# build on the Verilator model, sim/ssp/dictbuild.sh).  See doc/OVERVIEW.md s.6.
#
# The Mecrisp-Quintus common core is NOT vendored: it is referenced in place
# from its own repository (owner decision R17). MECRISP must point at a
# Mecrisp-Quintus distribution root containing common/*.s. Verified against
# upstream commit 16a34f0 (Mecrisp-Quintus 1.1.2a).

MECRISP ?= $(HOME)/mecrisp-quintus/mecrisp-quintus-source
CROSS   ?= riscv64-unknown-elf-
OBJROOT ?= build

SRCS := mecrisp-quintus-ssp.s terminal.s flash.s

AS     := $(CROSS)as
LD     := $(CROSS)ld
OBJCOPY:= $(CROSS)objcopy
# march string per SSP_DESIGN 5.8 (the .s re-asserts .option rvc itself; the
# toolchain still has to accept compressed encodings for relaxation-free use).
AFLAGS := --warn -march=rv32imc_zicsr_zifencei -mabi=ilp32
# ../common/*.s (upstream include style) resolves through this -I:
# $(MECRISP)/common/../common/x.s == $(MECRISP)/common/x.s ; bare
# "terminal.s"/"flash.s" still find OURS first (cwd beats -I).
IFLAGS := -I$(MECRISP)/common

.PHONY: all ssp qemu run-qemu clean check-tools image rom check install rom-check

# ssp_image.py writes its output even when its final check fails (exit 3): a
# target left behind by a failed recipe must not look up to date next time
.DELETE_ON_ERROR:

all: image rom

ssp: $(OBJROOT)/mecrisp-ssp.hex

qemu: $(OBJROOT)/mecrisp-ssp-qemu.elf

# ---- silicon / stub-SoC image: rom@0, dtcm@0x1000_0000 ----------------------
$(OBJROOT)/mecrisp-ssp.hex: $(SRCS) memmap-ssp | $(OBJROOT)
	$(AS) $(AFLAGS) $(IFLAGS) mecrisp-quintus-ssp.s -o $(OBJROOT)/ssp.o
	$(LD) -m elf32lriscv -nostdlib -T memmap-ssp -Map $(OBJROOT)/mecrisp-ssp.map \
	      -o $(OBJROOT)/mecrisp-ssp.elf $(OBJROOT)/ssp.o
	$(OBJCOPY) -O binary --gap-fill 0x00 $(OBJROOT)/mecrisp-ssp.elf \
	           $(OBJROOT)/mecrisp-ssp.bin
	python3 ../../tools/bin2hex.py $(OBJROOT)/mecrisp-ssp.bin $@ 0x20000

# ---- qemu virt smoke variant: everything in DRAM, ns16550 console -----------
QEMU_DEFS := --defsym QEMU_NS16550=1 \
             --defsym RamAnfang=0x80020000 --defsym RamEnde=0x80030000 \
             --defsym FlashAnfang=0x80000000 --defsym FlashEnde=0x80020000 \
             --defsym FlashDictionaryAnfang=0x80005000 \
             --defsym FlashDictionaryEnde=0x80020000

$(OBJROOT)/mecrisp-ssp-qemu.elf: $(SRCS) memmap-qemu | $(OBJROOT)
	$(AS) $(AFLAGS) $(IFLAGS) $(QEMU_DEFS) mecrisp-quintus-ssp.s \
	      -o $(OBJROOT)/ssp-qemu.o
	$(LD) -m elf32lriscv -nostdlib -T memmap-qemu -Map $(OBJROOT)/mecrisp-ssp-qemu.map \
	      -o $@ $(OBJROOT)/ssp-qemu.o

run-qemu: $(OBJROOT)/mecrisp-ssp-qemu.elf
	timeout 30 qemu-system-riscv32 -M virt -cpu rv32 -m 8 -bios none \
	  -kernel $(OBJROOT)/mecrisp-ssp-qemu.elf -serial mon:stdio -display none \
	  -no-reboot

# ---- monitor image + factory ROM --------------------------------------------
TOOLS    := ../../tools
IMAGE    := $(OBJROOT)/mrz80-ssp.mrz
ROM_MIF  := forth_rom.mif
ROM_WORDS := 32768     # 128 KiB MROM
MISTER_DEST ?= mister:/media/fat/games/MrZ80/mrz80-ssp.mrz

# everything the image's bytes depend on: the monitor, the repo files it
# \ @include's, the register constants, the kernel (our sources + upstream's
# common/*.s), the link map and the scripts that drive the build
APP_INCLUDES := $(shell sed -n 's|^\\ @include[[:space:]]*|../../|p' apps/monitor.fs)
IMAGE_DEPS   := apps/monitor.fs $(APP_INCLUDES) ssp-regs.fs $(SRCS) memmap-ssp \
                $(wildcard $(MECRISP)/common/*.s) \
                ../../sim/ssp/dictbuild.sh $(TOOLS)/ssp_image.py $(TOOLS)/ssp_appsrc.py \
                $(TOOLS)/bin2hex.py $(TOOLS)/hex2bin.py

image: $(IMAGE)

# ssp_image.py also leaves build/mecrisp-ssp-app.{bin,hex} and build/dict.{bin,hex}
# (the simulator lanes read the .hex)
$(IMAGE): $(IMAGE_DEPS) | $(OBJROOT)
	python3 $(TOOLS)/ssp_image.py -o $@

rom: $(ROM_MIF)

$(ROM_MIF): $(IMAGE) $(TOOLS)/bin2mif.py
	python3 $(TOOLS)/bin2mif.py $(IMAGE) $@ $(ROM_WORDS)
	python3 $(TOOLS)/bin2mif.py --check $(IMAGE) $@ $(ROM_WORDS)

rom-check: $(IMAGE)
	python3 $(TOOLS)/bin2mif.py --check $(IMAGE) $(ROM_MIF) $(ROM_WORDS)

check:
	python3 $(TOOLS)/ssp_image.py --check

install: $(IMAGE)
	scp $(IMAGE) $(MISTER_DEST)

$(OBJROOT):
	mkdir -p $(OBJROOT)

check-tools:
	@$(AS) --version | head -1
	@test -d $(MECRISP)/common || { \
	  echo "MECRISP=$(MECRISP) has no common/*.s -- set MECRISP to a"; \
	  echo "Mecrisp-Quintus distribution root (see doc/SSP_STATUS.md)"; \
	  exit 1; }

clean:
	rm -rf $(OBJROOT)

# Mecrisp-Quintus for the MrZ80 SSP -- minimal RV32IMC, RAM dictionary,
# no flash / no MappedSPIFlash (D-32, R17).
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

.PHONY: all ssp qemu run-qemu clean check-tools

all: ssp

ssp: $(OBJROOT)/mecrisp-ssp.hex

qemu: $(OBJROOT)/mecrisp-ssp-qemu.elf

# ---- silicon / stub-SoC image: rom@0, dtcm@0x1000_0000 ----------------------
$(OBJROOT)/mecrisp-ssp.hex: $(SRCS) memmap-ssp | $(OBJROOT)
	$(AS) $(AFLAGS) $(IFLAGS) mecrisp-quintus-ssp.s -o $(OBJROOT)/ssp.o
	$(LD) -m elf32lriscv -nostdlib -T memmap-ssp -Map $(OBJROOT)/mecrisp-ssp.map \
	      -o $(OBJROOT)/mecrisp-ssp.elf $(OBJROOT)/ssp.o
	$(OBJCOPY) -O binary --gap-fill 0x00 $(OBJROOT)/mecrisp-ssp.elf \
	           $(OBJROOT)/mecrisp-ssp.bin
	python3 ../../tools/bin2hex.py $(OBJROOT)/mecrisp-ssp.bin $@ 0x10000

# ---- qemu virt smoke variant: everything in DRAM, ns16550 console -----------
QEMU_DEFS := --defsym QEMU_NS16550=1 \
             --defsym RamAnfang=0x80010000 --defsym RamEnde=0x80020000 \
             --defsym FlashAnfang=0x80000000 --defsym FlashEnde=0x80010000 \
             --defsym FlashDictionaryAnfang=0x8000FF00 \
             --defsym FlashDictionaryEnde=0x80010000

$(OBJROOT)/mecrisp-ssp-qemu.elf: $(SRCS) memmap-qemu | $(OBJROOT)
	$(AS) $(AFLAGS) $(IFLAGS) $(QEMU_DEFS) mecrisp-quintus-ssp.s \
	      -o $(OBJROOT)/ssp-qemu.o
	$(LD) -m elf32lriscv -nostdlib -T memmap-qemu -Map $(OBJROOT)/mecrisp-ssp-qemu.map \
	      -o $@ $(OBJROOT)/ssp-qemu.o

run-qemu: $(OBJROOT)/mecrisp-ssp-qemu.elf
	timeout 30 qemu-system-riscv32 -M virt -cpu rv32 -m 8 -bios none \
	  -kernel $(OBJROOT)/mecrisp-ssp-qemu.elf -serial mon:stdio -display none \
	  -no-reboot

$(OBJROOT):
	mkdir -p $(OBJROOT)

check-tools:
	@$(AS) --version | head -1
	@test -d $(MECRISP)/common || { \
	  echo "MECRISP=$(MECRISP) has no common/*.s -- set MECRISP to a"; \
	  echo "Mecrisp-Quintus distribution root (see doc/SSP_HANDOFF.md)"; \
	  exit 1; }

clean:
	rm -rf $(OBJROOT)

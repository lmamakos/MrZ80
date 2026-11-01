#
#    Mecrisp-Quintus target: MrZ80 SSP (System Support Processor)
#
#    Minimal RV32IMC configuration -- no flash memory device and no
#    MappedSPIFlash anywhere (D-32, owner ruling R17):
#      * kernel executes from MROM (128 KiB, R43; factory image in the core,
#        replaceable by an OSD mount)
#      * new words compile into DTCM (dictionary pointer starts in RAM)
#      * the "flash dictionary" is the MROM window above the kernel
#        (FlashDictionaryAnfang..FlashDictionaryEnde): plain stores, so
#        `compiletoflash` works there on silicon as in sim (D-35, R43).  The
#        build pipeline fills it with the monitor; words compiled into it on
#        the board survive "Reset SSP" and are lost at core reload
#
#    Build: see Makefile in this directory. The Mecrisp-Quintus common core
#    is referenced in place (not vendored): MECRISP must point at a
#    Mecrisp-Quintus source distribution root (one containing common/).
#

# -----------------------------------------------------------------------------
# Switches for capabilities of this target
# -----------------------------------------------------------------------------

# Absolute addresses everywhere: never let the linker relax them.
.option norelax
.option rvc
.equ compressed_isa, 1

# Our ROM image is zero-filled (objcopy --gap-fill 0x00, MROM init from hex),
# so "erased" reads as all-zero -- NOT SPI-flash 0xFF.
.equ erasedflashcontainszero, 1

# Line ends: upstream's `crlf` switch makes `cr` and the kernel messages (the
# `writeln` macro, common/forth-core.s) emit CR as well as LF, so the operator's
# terminal need not translate a bare LF.  Same setting as the thejas32 port.
.equ crlf, 1

# softwaremultiply deliberately NOT set: both bake-off cores (picorv32
# ENABLE_MUL, gracilis) implement the M extension in hardware.

# -----------------------------------------------------------------------------
# Memory map for code ROM and data RAM (see SSP_DESIGN.md 5.2)
# -----------------------------------------------------------------------------

# Defaults = real SSP silicon map. -D overrides exist for the qemu-system
# virt smoke variant only (see Makefile: target `qemu`).

.ifndef RamAnfang
.equ RamAnfang,             0x10000000 # DTCM base -- stacks, variables
.equ RamEnde,               0x10010000 # 64 KiB DTCM
.equ FlashAnfang,           0x00000000 # MROM base (RV read-only, D-10)
.equ FlashEnde,             0x00020000 # 128 KiB MROM (R43)
# Application-dictionary window (D-35): contiguous above the kernel (~16 KiB,
# ends near 0x3FA0; R43 moved the window from 0x4400 to 0x5000 to leave the
# kernel room to grow).  `compiletoflash` builds the app dictionary here and
# the build pipeline captures it into the shipped MROM image; the EndOfCore
# entry links here and the boot scan sees erased (zero) bytes above it.
# FlashDictionaryAnfang must equal ssp_top's DICT_BASE (`make -C sim ssp-map`).
.equ FlashDictionaryAnfang, 0x00005000
.equ FlashDictionaryEnde,   0x00020000
.endif

# -----------------------------------------------------------------------------
# Core start
# -----------------------------------------------------------------------------

.text
  j Reset

# -----------------------------------------------------------------------------
# Include the Forth core of Mecrisp-Quintus
# -----------------------------------------------------------------------------

.include "../common/forth-core.s"

# -----------------------------------------------------------------------------
Reset: # Forth begins here
# -----------------------------------------------------------------------------

  .include "../common/catchflashpointers.s"

  call uart_init

  welcome " RV32IMC SSP core (MrZ80) -- 128 KiB ROM, dictionary window above the kernel"

  # Ready to fly !
  .include "../common/boot.s"

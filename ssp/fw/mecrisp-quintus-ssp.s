#
#    Mecrisp-Quintus target: MrZ80 SSP (System Support Processor)
#
#    Minimal RV32IMC configuration -- RAM dictionary only, NO flash memory
#    and no MappedSPIFlash device anywhere (D-32, owner ruling R17):
#      * kernel executes from MROM (OSD-loaded image, RV-read-only, D-10)
#      * new words compile into DTCM (dictionary pointer starts in RAM)
#      * the "flash dictionary" region is a 1 KiB erased pad at the top of
#        the ROM image -- reserved for future MPKG precompiled packs (D-21),
#        empty in P0
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
.equ FlashEnde,             0x00010000 # 64 KiB MROM
# Application-dictionary window (D-35): contiguous above the kernel (~16 KiB
# at 0x3F70; margin to 0x4400 mirrors the ulx3s convention). In sim this
# window is writable and `compiletoflash` builds the app dictionary here;
# the build pipeline captures it into the shipped MROM image. Empty until
# then: the EndOfCore entry links here and the boot scan sees erased bytes.
.equ FlashDictionaryAnfang, 0x00004400
.equ FlashDictionaryEnde,   0x00010000
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

  welcome " RV32IMC SSP core (MrZ80) -- RAM dictionary, no flash"

  # Ready to fly !
  .include "../common/boot.s"

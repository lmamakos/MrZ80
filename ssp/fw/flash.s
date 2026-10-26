#
#    MrZ80 SSP flash primitives -- there is NO flash memory device in this
#    system (D-32 rev R17/R18: no SPI flash, no MappedSPIFlash).
#
#    "Flash" here means the MROM window [FlashDictionaryAnfang..FlashEnde)
#    that sits contiguously above the kernel in the OSD-loaded image (D-35).
#    flash!/hflash! are plain stores:
#      * in sim (qemu DRAM, Verilator stub rom[] array) the window is
#        writable, so `compiletoflash` builds the application dictionary
#        contiguously with the kernel -- the build pipeline captures that
#        window into the shipped MROM hex;
#      * on silicon MROM ignores RV writes, so the same words are inert and
#        `compiletoflash` there is harmless (dictionary lost at reset).
#    The dictionary build is therefore a build-system/stub procedure; the
#    operator-visible persistence path stays source packs (D-21, OSD MPKG).
#
#    The initflash hook is deliberately absent: boot.s skips its call (.ifdef),
#    there is no controller to bring up.
#

# -----------------------------------------------------------------------------
  Definition Flag_visible, "flash!" # ( x 32-addr -- )  plain store, see header
# -----------------------------------------------------------------------------
flashstore:
  lw x15, 0(x9)  # value
  sw x15, 0(x8)
  lw x8, 4(x9)   # consume both stack items
  addi x9, x9, 8
  ret

# -----------------------------------------------------------------------------
  Definition Flag_visible, "hflash!" # ( x 16-addr -- )  plain store
# -----------------------------------------------------------------------------
hflashstore:
  lw x15, 0(x9)
  sh x15, 0(x8)
  lw x8, 4(x9)
  addi x9, x9, 8
  ret

# -----------------------------------------------------------------------------
  Definition Flag_visible, "flushflash" # ( -- )  no-op: nothing to flush
# -----------------------------------------------------------------------------
flushflash:
  ret

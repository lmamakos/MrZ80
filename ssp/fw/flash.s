#
#    MrZ80 SSP flash primitives -- there is NO flash memory device in this
#    system (D-32 rev R17/R18: no SPI flash, no MappedSPIFlash).
#
#    "Flash" here means the MROM window [FlashDictionaryAnfang..FlashEnde)
#    that sits contiguously above the kernel in the OSD-loaded image (D-35).
#    flash!/hflash! are plain stores, and the window is writable everywhere
#    (ssp_top accepts RV writes at DICT_BASE and up; qemu has DRAM there):
#      * the build pipeline (sim/ssp/p1a_dictbuild.sh) runs `compiletoflash`
#        on the p1a model and captures the window into the shipped MROM image;
#      * on the board the same words extend the dictionary in place.  Those
#        words survive an RV reset ("Reset SSP": the boot scan finds them)
#        and are lost when the core is reloaded or a new image is mounted
#        from the OSD (R43).  Writes below the window never land.
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

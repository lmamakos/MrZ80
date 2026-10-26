#
#    MrZ80 SSP: flash primitives stub -- there is no flash memory device in
#    this system (D-32, owner ruling R17: no SPI flash, no MappedSPIFlash).
#
#    The kernel boots straight into the RAM dictionary (catchflashpointers
#    sets dictionarypointer := RamDictionaryAnfang); persistence is the OSD
#    MROM image plus MPKG packs re-EVAL'd at boot (D-21).
#
#    flash! / hflash! accept and discard their arguments: writes to the MROM
#    window are bus no-ops on silicon, and this stub keeps them harmless in
#    RAM-mapped positions. They stay visible so a stray user program finds
#    *something* answering rather than an unknown-word error mid-edit.
#    The initflash hook is deliberately absent: boot.s skips its call (.ifdef).
#

# -----------------------------------------------------------------------------
  Definition Flag_visible, "flash!" # ( x 32-addr -- )  not available: discarded
# -----------------------------------------------------------------------------
flashstore:
  popda x15 # value
  popda x15 # address
  ret

# -----------------------------------------------------------------------------
  Definition Flag_visible, "hflash!" # ( x 16-addr -- )  not available: discarded
# -----------------------------------------------------------------------------
hflashstore:
  popda x15
  popda x15
  ret

# -----------------------------------------------------------------------------
  Definition Flag_visible, "flushflash" # ( -- )  no-op: no flash to flush
# -----------------------------------------------------------------------------
flushflash:
  ret

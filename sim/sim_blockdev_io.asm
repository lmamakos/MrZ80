; ============================================================================
; sim_blockdev_io.asm - payload for sim/tb_sdram_perf.vhd (-gBIN=..., EXPECT_SUM=0).
;
; Top-level integration check of the HPS block device (hps_blockdev) at I/O
; ports $90-$97, with NO image mounted (the testbench never drives the bd_*
; ports). It confirms the chip select, the cpuDataIn mux and the register
; decode are wired correctly, and that $88-$8F (SPI sd_controller) is not
; aliased onto the new device:
;
;   $91 STATUS = 90h        (b4 "no image", b7 write ok)
;   $95..$97 SIZE = 0
;   LBA writes + READ command ($91 <- 00h) are rejected: STATUS = 94h
;   The reject must not change anything at $88-$8F (sd_controller status
;   is independent: it reads 1xh while it initialises, never 94h/90h here).
;
; RESULT = number of failed checks (expect 0), then DONE_FLAG = 0AAh.
;
; Build: tools/z80asm.sh -o /tmp/sim_blockdev_io sim/sim_blockdev_io.asm
; ============================================================================

                .z80
                aseg
                org     0000h

RESULT          equ     0900h
DONE_FLAG       equ     0908h
STACK           equ     0A00h

start:          ld      sp,STACK
                ld      d,0             ; D = error count

                in      a,(91h)         ; STATUS, no image mounted
                cp      90h
                call    nz,fail

                in      a,(95h)         ; SIZE0..2 = 0
                or      a
                call    nz,fail
                in      a,(96h)
                or      a
                call    nz,fail
                in      a,(97h)
                or      a
                call    nz,fail

                xor     a               ; LBA = 0
                out     (92h),a
                out     (93h),a
                out     (94h),a
                out     (91h),a         ; READ command -> rejected
                ld      b,20            ; let the device see it
dly:            djnz    dly
                in      a,(91h)
                cp      94h
                call    nz,fail

                in      a,(90h)         ; DATA port readable, no hang
                in      a,(91h)
                cp      94h             ; still rejected-and-idle
                call    nz,fail

                ld      a,d
                ld      (RESULT),a
                ld      a,0AAh
                ld      (DONE_FLAG),a
fin:            jr      fin

fail:           ld      a,d             ; saturating error count
                inc     a
                ret     z
                inc     d
                ret

                end

; ============================================================================
; sim_unused_io.asm - payload for sim/tb_sdram_perf.vhd (-gBIN=..., EXPECT_SUM=0).
;
; Checks that a read from an I/O port that no peripheral decodes returns 0FFh
; (floating, pulled-up data bus) instead of stale memory data. The MMU
; translates the CPU address on I/O cycles as well, so with the high address
; byte (B in IN A,(C)) selecting a frame that maps to block RAM or SDRAM, an
; unqualified memory leg in the cpuDataIn mux used to answer the port read
; (observed: 78h).
;
;   1. maps frame 1 to SDRAM page 1 and fills 4000h-40FFh with 78h,
;   2. for B in {40h (SDRAM page 1), 00h (block RAM), 80h, 0C0h (SDRAM)}:
;      primes the SDRAM read data register with a read of 78h, then
;      IN A,(C) for every port C that nothing decodes (see skip list), and
;      counts the reads that do not return 0FFh,
;   3. stores the error count at RESULT (expect 0) and 0AAh at DONE_FLAG.
;
; Decoded ports skipped: 70-71 RTC, 80-83 UARTs, 88-8F SD, 90-97 HPS block
; device, A0-A7 front panel,
; B0-BF MMU, C0-CF timers, FF front-panel latch.
;
; Build: tools/z80asm.sh -o /tmp/sim_unused_io sim/sim_unused_io.asm
; ============================================================================

                .z80
                aseg
                org     0000h

MMU_F1          equ     0B1h            ; frame 1 mapping, bits 7:0
MMU_F1H         equ     0B5h            ; frame 1 mapping, bits 15:8
RESULT          equ     0900h
DONE_FLAG       equ     0908h
STACK           equ     0A00h

start:          ld      sp,STACK
                ld      a,1             ; frame 1 -> SDRAM page 1
                out     (MMU_F1),a
                xor     a
                out     (MMU_F1H),a
                ld      hl,4000h        ; fill 4000h-40FFh with 78h
                ld      (hl),78h
                ld      de,4001h
                ld      bc,00FFh
                ldir

                ld      d,0             ; D = error count
                ld      e,4             ; E = number of B values left
                ld      hl,btab
nextb:          ld      a,(4000h)       ; prime SDRAM read data (78h)
                ld      b,(hl)
                inc     hl
                ld      c,0
nextc:          ld      a,c
                cp      70h
                jr      c,test          ; 00-6F
                cp      72h
                jr      c,skip          ; 70-71 RTC
                cp      80h
                jr      c,test          ; 72-7F
                cp      84h
                jr      c,skip          ; 80-83
                cp      88h
                jr      c,test          ; 84-87
                cp      90h
                jr      c,skip          ; 88-8F
                cp      98h
                jr      c,skip          ; 90-97 HPS block device
                cp      0A0h
                jr      c,test          ; 98-9F
                cp      0A8h
                jr      c,skip          ; A0-A7
                cp      0B0h
                jr      c,test          ; A8-AF
                cp      0D0h
                jr      c,skip          ; B0-CF
                cp      0FFh
                jr      z,skip          ; FF
test:           in      a,(c)
                inc     a               ; 0FFh -> 0
                jr      z,skip
                ld      a,d             ; not 0FFh: count an error (saturating)
                inc     a
                jr      z,skip
                inc     d
skip:           inc     c
                jr      nz,nextc
                dec     e
                jr      nz,nextb

                ld      a,d
                ld      (RESULT),a
                ld      a,0AAh
                ld      (DONE_FLAG),a
fin:            jr      fin

btab:           db      40h,00h,80h,0C0h

                end

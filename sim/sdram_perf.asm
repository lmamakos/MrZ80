; ============================================================================
; sdram_perf.asm - payload for sim/tb_sdram_perf.vhd.
;
; Measures (in simulation) how many wait T-states SDRAM accesses cost, for
; opcode fetches, memory reads and memory writes, and checks the data.
;
;   1. maps logical frame 1 (4000h-7FFFh) to SDRAM physical page 1,
;   2. copies WORK (below) into SDRAM at 4000h with LDIR (SDRAM writes),
;   3. CALLs it: it runs entirely from SDRAM (opcode fetches from SDRAM),
;      filling an N-byte buffer at 5000h, then making PASSES passes of
;      buf2[i] = buf[i] + pass and copying buf2 back to buf (SDRAM reads and
;      writes), and returns the 8-bit sum of buf in A,
;   4. stores the sum at RESULT and 0AAh at DONE_FLAG (block RAM, watched
;      by the testbench).
;
; Expected sum: after the passes buf[i] = i*3 + 7 + (1+2+...+PASSES), so
; with N = 64, PASSES = 4 the sum mod 256 is
; 3*2016 + 7*64 + 64*10 = 7136 = E0h (mod 256).
;
; Build: tools/z80asm.sh -o sim/sdram_perf sim/sdram_perf.asm
; ============================================================================

                .z80
                aseg
                org     0000h

MMU_F1          equ     0B1h            ; frame 1 mapping, bits 7:0
MMU_F1H         equ     0B5h            ; frame 1 mapping, bits 15:8
RESULT          equ     0900h
DONE_FLAG       equ     0908h
STACK           equ     0A00h
PASSES          equ     4
N               equ     64              ; buffer length (1..256)

start:          ld      sp,STACK
                ld      a,1             ; frame 1 -> SDRAM page 1
                out     (MMU_F1),a
                xor     a
                out     (MMU_F1H),a
                ld      hl,work
                ld      de,4000h
                ld      bc,worklen
                ldir
                call    4000h
                ld      (RESULT),a
                ld      a,0AAh
                ld      (DONE_FLAG),a
fin:            jr      fin

; ---- position-independent routine, copied to and run from 4000h --------
work:           ld      hl,5000h        ; buf[i] = i*3 + 7
                ld      b,N
                ld      a,7
w1:             ld      (hl),a
                add     a,3
                inc     hl
                djnz    w1
                ld      c,1             ; pass number 1..PASSES
w2:             ld      hl,5000h
                ld      de,5100h
                ld      b,N
w3:             ld      a,(hl)          ; buf2[i] = buf[i] + pass
                add     a,c
                ld      (de),a
                inc     hl
                inc     de
                djnz    w3
                push    bc
                ld      hl,5100h        ; buf = buf2
                ld      de,5000h
                ld      bc,N
                ldir
                pop     bc
                inc     c
                ld      a,c
                cp      PASSES+1
                jr      nz,w2
                ld      hl,5000h        ; return the sum of buf in A
                ld      b,N
                xor     a
w4:             add     a,(hl)
                inc     hl
                djnz    w4
                ret
worklen         equ     $-work

                end

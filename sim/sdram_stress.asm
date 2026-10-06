; ============================================================================
; sdram_stress.asm - correctness payload for sim/tb_sdram_perf.vhd
; (-gBIN=sim/sdram_stress.bin -gEXPECT_SUM=0; sim/run_perf.sh runs it).
;
; Exercises the SDRAM FSM's speculative reads and posted writes in the
; awkward orderings, running entirely from SDRAM with the stack in SDRAM:
;   1. write then immediately read back the same address (256 bytes)
;   2. PUSH/PUSH/PUSH/POP/POP/POP (back-to-back writes, then reads)
;   3. recursive CALL/RET, 12 deep, then check SP
;   4. EX (SP),HL (read, read, write, write to the same addresses)
;   5. RLD (read then write of the same byte)
;   6. LDIR 256 bytes SDRAM -> SDRAM, then compare
;   7. OTIR 16 bytes to the MMU direct-access port (+12) into SDRAM, read
;      them back through normal memory reads, then INIR them back through
;      the port and compare
; Each failed check increments ERRS; RESULT = ERRS, expected 0.
;
; Build: tools/z80asm.sh -o sim/sdram_stress sim/sdram_stress.asm
; ============================================================================

                .z80
                aseg
                org     0000h

MMU_F1          equ     0B1h            ; frame 1 mapping, bits 7:0
MMU_F1H         equ     0B5h            ; frame 1 mapping, bits 15:8
PTR0            equ     0B8h            ; direct-access pointer bytes
PTR1            equ     0B9h
PTR2            equ     0BAh
PTR3            equ     0BBh
DDATA           equ     0BCh            ; direct-access data port
RESULT          equ     0900h
DONE_FLAG       equ     0908h
ERRS            equ     0910h
OLDSP           equ     0912h
STACK           equ     0A00h
WORK            equ     4000h           ; routine runs here (SDRAM page 1)

start:          ld      sp,STACK
                xor     a
                ld      (ERRS),a
                ld      a,1             ; frame 1 -> SDRAM page 1
                out     (MMU_F1),a
                xor     a
                out     (MMU_F1H),a
                ld      hl,image
                ld      de,WORK
                ld      bc,imglen
                ldir
                call    WORK
                ld      a,(ERRS)
                ld      (RESULT),a
                ld      a,0AAh
                ld      (DONE_FLAG),a
fin:            jr      fin

; The image is assembled at its load address in the .BIN but runs at WORK.
; um80 accepts .PHASE/.DEPHASE but IGNORES them, so every absolute
; reference from the image to itself is written label+IM (IM = WORK -
; image) to point into the copy at WORK; relative jumps need nothing.
IM              equ     WORK-image
image:
test:           ld      (OLDSP),sp
                ld      sp,7F00h        ; stack in SDRAM

; 1. write, then read back the same address at once
                ld      hl,5000h
                ld      b,0
t1:             ld      a,b
                xor     5Ah
                ld      (hl),a
                ld      c,(hl)
                cp      c
                call    nz,fail+IM
                inc     hl
                djnz    t1

; 2. back-to-back pushes and pops
                ld      b,16
t2:             push    bc
                ld      bc,1234h
                ld      de,5678h
                ld      hl,9ABCh
                push    bc
                push    de
                push    hl
                pop     bc
                pop     de
                pop     hl
                ld      a,b
                cp      9Ah
                call    nz,fail+IM
                ld      a,c
                cp      0BCh
                call    nz,fail+IM
                ld      a,d
                cp      56h
                call    nz,fail+IM
                ld      a,e
                cp      78h
                call    nz,fail+IM
                ld      a,h
                cp      12h
                call    nz,fail+IM
                ld      a,l
                cp      34h
                call    nz,fail+IM
                pop     bc
                djnz    t2

; 3. recursion, then SP must be back at 7F00h
                ld      a,12
                call    rec+IM
                ld      hl,0
                add     hl,sp
                ld      a,h
                cp      7Fh
                call    nz,fail+IM
                ld      a,l
                or      a
                call    nz,fail+IM

; 4. EX (SP),HL
                ld      hl,1111h
                push    hl
                ld      hl,2222h
                ex      (sp),hl
                pop     de
                ld      a,h
                cp      11h
                call    nz,fail+IM
                ld      a,l
                cp      11h
                call    nz,fail+IM
                ld      a,d
                cp      22h
                call    nz,fail+IM
                ld      a,e
                cp      22h
                call    nz,fail+IM

; 5. RLD
                ld      hl,5100h
                ld      (hl),34h
                ld      a,12h
                rld
                cp      13h
                call    nz,fail+IM
                ld      a,(hl)
                cp      42h
                call    nz,fail+IM

; 6. LDIR 5000h -> 5200h, then compare
                ld      hl,5000h
                ld      de,5200h
                ld      bc,256
                ldir
                ld      hl,5000h
                ld      de,5200h
                ld      b,0
t6:             ld      a,(de)
                cp      (hl)
                call    nz,fail+IM
                inc     hl
                inc     de
                djnz    t6

; 7. OTIR to the direct-access port (phys 6000h = logical 6000h in frame 1),
;    read back normally, then INIR back through the port
                call    ptr6000+IM
                ld      hl,5000h
                ld      bc,16*256+DDATA
                otir
                ld      hl,5000h
                ld      de,6000h
                ld      b,16
t7:             ld      a,(de)
                cp      (hl)
                call    nz,fail+IM
                inc     hl
                inc     de
                djnz    t7
                call    ptr6000+IM
                ld      hl,5300h
                ld      bc,16*256+DDATA
                inir
                ld      hl,5000h
                ld      de,5300h
                ld      b,16
t8:             ld      a,(de)
                cp      (hl)
                call    nz,fail+IM
                inc     hl
                inc     de
                djnz    t8

                ld      sp,(OLDSP)
                ret

ptr6000:        xor     a
                out     (PTR0),a
                out     (PTR2),a
                out     (PTR3),a
                ld      a,60h
                out     (PTR1),a
                ret

rec:            dec     a
                call    nz,rec+IM
                ret

fail:           push    af
                ld      a,(ERRS)
                inc     a
                ld      (ERRS),a
                pop     af
                ret
imglen          equ     $-image

                end

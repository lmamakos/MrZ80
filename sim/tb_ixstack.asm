; tb_ixstack.asm - test payload for sim/tb_ixstack.vhd
;
; Exercises the custom PUSHIX/POPIX instructions (ED C5/D5/E5, ED C1/D1/E1)
; on a bare T80s core.  Each test stores its observed register/memory
; values into the RESULTS area at 8000h; the VHDL testbench compares that
; area against its table of expected values after the CPU HALTs.
;
; Assemble: pasmo --bin sim/tb_ixstack.asm sim/tb_ixstack.bin
; (sim/run_ixstack.sh does this automatically.)

; ---- custom instruction encodings (assembler knows nothing of them) ----
PUSHIX_BC MACRO
        db 0EDh,0C5h
        ENDM
PUSHIX_DE MACRO
        db 0EDh,0D5h
        ENDM
PUSHIX_HL MACRO
        db 0EDh,0E5h
        ENDM
POPIX_BC MACRO
        db 0EDh,0C1h
        ENDM
POPIX_DE MACRO
        db 0EDh,0D1h
        ENDM
POPIX_HL MACRO
        db 0EDh,0E1h
        ENDM
FNEXT   MACRO
        db 0EDh,092h
        ENDM

RSLT    equ 8000h       ; results area (see tb_ixstack.vhd for layout)
RSTK    equ 0E000h      ; initial IX ("return stack" top)

        org 0
        di
        ld sp,0F000h
        ld iy,7777h
        ld ix,RSTK

; ---- T1: PUSHIX DE, check memory image and IX ----------------------------
        ld de,1234h
        PUSHIX_DE
        ld (RSLT+00h),ix         ; expect DFFE
        ld a,(RSTK-1)
        ld (RSLT+02h),a          ; expect 12 (high byte at IX-1)
        ld a,(RSTK-2)
        ld (RSLT+03h),a          ; expect 34 (low byte at IX-2)

; ---- T2: push BC and HL, then pop in a different order -------------------
        ld bc,5678h
        PUSHIX_BC
        ld hl,9ABCh
        PUSHIX_HL
        ld (RSLT+04h),ix         ; expect DFFA
        POPIX_BC                ; BC <- 9ABC
        POPIX_HL                ; HL <- 5678
        POPIX_DE                ; DE <- 1234
        ld (RSLT+06h),bc         ; expect 9ABC
        ld (RSLT+08h),hl         ; expect 5678
        ld (RSLT+0Ah),de         ; expect 1234
        ld (RSLT+0Ch),ix         ; expect E000

; ---- T3: flags untouched (all-ones and all-zeros F) ----------------------
        ld bc,0FFFFh
        push bc
        pop af                  ; A=FF F=FF
        PUSHIX_BC
        POPIX_DE
        push af
        pop hl
        ld (RSLT+0Eh),hl         ; expect FFFF
        ld bc,0
        push bc
        pop af                  ; A=00 F=00
        PUSHIX_BC
        POPIX_DE
        push af
        pop hl
        ld (RSLT+10h),hl         ; expect 0000

; ---- T4: back-to-back PUSHIX/POPIX (register copy through the stack) -----
        ld de,0CAFEh
        ld bc,0
        PUSHIX_DE
        POPIX_BC
        ld (RSLT+12h),bc         ; expect CAFE
        ld (RSLT+14h),ix         ; expect E000

; ---- T5: EXX bank - pushes/pops act on the current bank ------------------
        ld de,1111h             ; main DE
        exx
        ld de,0A55Ah            ; alternate DE
        PUSHIX_DE               ; push alternate DE
        ld hl,0
        POPIX_HL                ; alternate HL <- A55A
        ld (RSLT+16h),hl         ; expect A55A
        ld a,(RSTK-1)
        ld (RSLT+38h),a          ; expect A5 (written via IX, not IY)
        ld a,(RSTK-2)
        ld (RSLT+39h),a          ; expect 5A
        ld (RSLT+18h),ix         ; expect E000
        exx
        ld (RSLT+1Ah),de         ; expect 1111 (main bank untouched)

; ---- T6: POPIX DE immediately followed by F_NEXT (the EXIT path) ---------
        ld hl,thread
        PUSHIX_HL               ; "return address" = thread
        ld de,0
        POPIX_DE                ; DE <- thread
        FNEXT                   ; PC <- (thread) = t6ok, DE <- thread+2
        jp fail
thread: dw t6ok
        dw 0
t6ok:   ld hl,thread+2
        or a
        sbc hl,de
        ld (RSLT+1Ch),hl         ; expect 0000 (DE = thread+2)
        ld (RSLT+1Eh),ix         ; expect E000

; ---- T7: IX wrap-around at 0000h -----------------------------------------
        ld ix,0
        ld bc,0BEEFh
        PUSHIX_BC
        ld (RSLT+20h),ix         ; expect FFFE
        ld a,(0FFFFh)
        ld (RSLT+22h),a          ; expect BE
        ld a,(0FFFEh)
        ld (RSLT+23h),a          ; expect EF
        POPIX_HL
        ld (RSLT+24h),hl         ; expect BEEF
        ld (RSLT+26h),ix         ; expect 0000

; ---- T8: regression - stock IX ops, PUSH/POP, IY, SP still fine ----------
        ld ix,RSTK
        ld de,4321h
        PUSHIX_DE
        ld l,(ix+0)
        ld h,(ix+1)             ; (IX+d) path still works after PUSHIX
        ld (RSLT+28h),hl         ; expect 4321
        inc ix
        inc ix                  ; stock INC IX (DD 23)
        dec ix
        dec ix
        ld (ix+0),56h           ; overwrite low byte via (IX+d)
        POPIX_BC
        ld (RSLT+2Ah),bc         ; expect 4356
        ld bc,0F00Dh
        push bc
        pop de                  ; stock PUSH/POP still fine
        ld (RSLT+2Ch),de         ; expect F00D
        ld (RSLT+2Eh),iy         ; expect 7777
        ld (RSLT+30h),sp         ; expect F000

; ---- T9: unimplemented AF slots (ED F5 / ED F1) are still 2-byte NOPs ----
        ld ix,RSTK
        ld hl,6789h
        db 0EDh,0F5h
        db 0EDh,0F1h
        ld (RSLT+32h),ix         ; expect E000
        ld (RSLT+34h),hl         ; expect 6789

; ---- T10: HL via EX DE,HL round-trip, push HL / pop DE -------------------
        ld hl,2468h
        PUSHIX_HL
        POPIX_DE
        ex de,hl
        ld (RSLT+36h),hl         ; expect 2468

        ld a,0A5h
        ld (RSLT+3Fh),a          ; completion marker
        jp timing

fail:   ld a,0EEh
        ld (RSLT+3Fh),a
        halt

; ---- timing probe at a fixed address: testbench measures M1-to-M1 -------
        org 0200h
timing: ld ix,RSTK              ; 0200 (4 bytes)
        PUSHIX_DE               ; 0204
        POPIX_DE                ; 0206
        PUSHIX_HL               ; 0208
        POPIX_BC                ; 020A
        nop                     ; 020C
        halt                    ; 020D

; tb_integ_core.asm -- guest program for sim/tb_integ_core.vhd (R-42, SDRAM/BRAM/MMU half).
;
; Runs from block RAM while the SSP engine model repeatedly parks it and does its
; own memory/I-O cycles through the real fabric.  The program keeps a running sum
; (120 steps, A += B with B counting 120..1), writes each value to SDRAM (through
; MMU frame 3 -> SDRAM page 0, logical C100h+k) and to block RAM (3000h+k), reads
; both back and counts mismatches at 0900h.  Result: final sum at 0902h, done flag
; AAh at 0903h.  Any cycle the engine corrupts, drops or doubles shows up as a
; mismatch, a wrong sum, or a wrong memory image.
;
; Assemble: tools/z80asm.sh -o <base> sim/tb_integ_core.asm  (sim/run_integ_core.sh)

        .Z80
        ASEG

        ORG 0000h
        LD SP,0A00h
        XOR A
        LD (0900h),A               ; mismatch count = 0
        OUT (0B3h),A               ; frame 3 low byte  = 0 (clears the register)
        OUT (0B7h),A               ; frame 3 high byte = 0 -> SDRAM page 0
        LD HL,0C100h               ; SDRAM through frame 3
        LD DE,3000h                ; block RAM
        LD B,120
        XOR A
LOOP:   ADD A,B
        LD (HL),A                  ; SDRAM write
        LD (DE),A                  ; block RAM write
        LD C,A
        LD A,(HL)                  ; SDRAM read back
        CP C
        JR NZ,BAD
        LD A,(DE)                  ; block RAM read back
        CP C
        JR NZ,BAD
        JR OK
BAD:    LD A,(0900h)
        INC A
        LD (0900h),A
OK:     LD A,C
        INC HL
        INC DE
        OUT (0AAh),A
        DJNZ LOOP
        LD (0902h),A
        LD A,0AAh
        LD (0903h),A               ; done
        HALT
        END

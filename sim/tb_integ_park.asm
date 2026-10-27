; tb_integ_park.asm -- directed instruction mix for sim/tb_integ_park.vhd (R-40).
;
; Every class of instruction whose boundary the T80 FREEZE gate (D-25) has to
; get right: DD/FD-indexed, CB, DDCB/FDCB-indexed bit ops, ED (incl. the
; custom PUSHIX/POPIX), block LDIR/LDDR/CPIR/INIR/OTIR, DJNZ, CALL/RET, RST,
; EX (SP), EXX, I/O, 16-bit ALU, an EI shadow, IM2 interrupts, then HALT.
; Results are not checked here: the bench compares the architectural state at
; every park against an unparked reference run of this same image.
;
; Interrupt triggers are keyed on the PC of an instruction start (labels the
; runner reads from the symbol file): TRGEI = the NOP right after a DI (INT
; raised while disabled, so it is pending across EI: the EI shadow), TRGBLK =
; the LDIR (INT between iterations), TRGDDC = a DDCB instruction.  IM2: I=90h,
; vector table at 9000h -> ISR at 0200h; the bench's device supplies vector
; byte 00h and drops INT on the acknowledge.  INITOK: every register is defined
; from here on (the T80 register file is not reset), so the bench compares from
; the start at INITOK.
;
; Assemble: tools/z80asm.sh -o <base> sim/tb_integ_park.asm  (sim/run_integ_park.sh)

        .Z80
        ASEG

        ORG 0000h
        JP START

        ORG 0008h                  ; RST 08h
        LD A,(8070h)
        INC A
        LD (8070h),A
        RET

        ORG 0038h
        RET

        ORG 0200h                  ; IM2 service routine
ISR:    PUSH AF
        LD A,(8040h)
        INC A
        LD (8040h),A
        POP AF
        EI
        RETI

        ORG 0100h
START:  LD SP,0FF00h
        LD BC,0                    ; the T80 register file is not reset: define every
        LD DE,0                    ; register before the bench starts comparing
        LD HL,0                    ; state (INITOK)
        LD IX,0
        LD IY,0
        EXX
        LD BC,0
        LD DE,0
        LD HL,0
        EXX
        XOR A
        EX AF,AF'
        XOR A
        EX AF,AF'
        LD A,90h
        LD I,A
        IM 2
INITOK: CALL EISEC
        CALL IXSEC
        CALL CBSEC
        CALL BLKSEC
        CALL ALUSEC
        CALL IOSEC
        CALL STKSEC
        CALL ISRTAIL
ENDHLT: HALT
        JR ENDHLT

; ---- EI shadow: INT raised at TRGEI while interrupts are disabled -------------
        ORG 0300h
EISEC:  DI
TRGEI:  NOP
        EI
        INC A                      ; shadow: no interrupt before this completes
        NOP                        ; ... the interrupt is taken here
        NOP
        RET

; ---- DD/FD indexed, DDCB/FDCB, custom PUSHIX/POPIX -----------------------------
        ORG 0320h
IXSEC:  LD IX,8200h
        LD IY,8300h
        LD (IX+5),12h
        LD A,(IX+5)
        ADD A,(IY+3)
        LD (IY-2),A
        INC (IX+5)
        DEC (IY-2)
        BIT 3,(IX+5)
TRGDDC: DB 0DDh,0CBh,06h,0FEh       ; SET 7,(IX+6)  (SET is an M80 directive)
        RES 0,(IY+1)
        RLC (IX+7)
        SRL (IY+2)
        LD B,(IX+6)
        LD (IX+8),B
        LD (IY+9),0A5h
        ADD IX,BC
        INC IX
        DEC IY
        PUSH IX
        POP IY
        EX (SP),IX
        EX (SP),IX
        LD HL,8200h
        LD DE,8210h
        DB 0EDh,0C5h               ; PUSHIX BC
        DB 0EDh,0D5h               ; PUSHIX DE
        DB 0EDh,0C1h               ; POPIX  BC
        DB 0EDh,0D1h               ; POPIX  DE
        DB 0DDh,2Eh,3Ch            ; LD IXL,3Ch  (undocumented, T80 implements it)
        DB 0DDh,7Dh                ; LD A,IXL
        RET

; ---- CB-prefixed, ED-prefixed single instructions ---------------------------------
        ORG 0360h
CBSEC:  LD HL,8400h
        LD (HL),81h
        LD A,5Ah
        BIT 5,A
        DB 0CBh,0D0h               ; SET 2,B
        RES 3,C
        RR C
        RL D
        SLA (HL)
        SRA (HL)
        SRL A
        RLC E
        BIT 7,(HL)
        DB 0CBh,0C6h               ; SET 0,(HL)
        LD BC,1234h
        LD (8410h),BC
        LD DE,(8410h)
        LD (8412h),SP
        LD SP,(8412h)
        NEG
        RLD
        RRD
        IM 1
        IM 2
        LD A,I
        LD I,A
        LD A,R
        RET

; ---- block instructions --------------------------------------------------------------
        ORG 0400h
BLKSEC: LD HL,8500h
        LD B,20
FILL:   LD (HL),B
        INC HL
        DJNZ FILL
        LD HL,8500h
        LD DE,8600h
        LD BC,20
TRGBLK: LDIR
        LD HL,8613h
        LD DE,8713h
        LD BC,10
        LDDR
        LD HL,8600h
        LD BC,20
        LD A,5
        CPIR
        LD HL,8613h
        LD BC,10
        LD A,9
        CPDR
        LD HL,8800h
        LD BC,1
        LDIR
        RET

; ---- ALU, 16-bit, rotates, DAA, EXX/EX AF, RST, CALL nesting, DJNZ ------------------------
        ORG 0460h
ALUSEC: LD A,99h
        ADD A,27h
        DAA
        LD HL,1234h
        LD DE,0FEDh
        ADD HL,DE
        ADC HL,DE
        SBC HL,DE
        PUSH HL
        EXX
        LD BC,1111h
        LD DE,2222h
        LD HL,3333h
        EXX
        EX AF,AF'
        LD A,0AAh
        EX AF,AF'
        POP HL
        PUSH BC
        EX (SP),HL
        POP DE
        RLCA
        RRCA
        RLA
        RRA
        CPL
        SCF
        CCF
        LD A,0Fh
        LD HL,8900h
        LD (HL),0A5h
        INC (HL)
        DEC (HL)
        ADD A,(HL)
        CP (HL)
        XOR A
        OR 0Fh
        AND 3Ch
        RST 08h
        CALL SUB1
        LD B,5
DJL:    DJNZ DJL
        LD B,4
L2:     INC C
        DEC B
        JR NZ,L2
        RET
SUB1:   CALL SUB2
        INC A
        RET
SUB2:   PUSH AF
        LD A,(8070h)
        POP AF
        RET

; ---- I/O: IN/OUT, IN r,(C), INIR/OTIR ------------------------------------------------------
        ORG 0500h
IOSEC:  LD HL,8A00h
        LD B,8
        LD C,10h
        INIR
        LD HL,8A00h
        LD B,8
        LD C,20h
        OTIR
        IN A,(33h)
        OUT (34h),A
        LD C,40h
        IN B,(C)
        OUT (C),B
        INI
        OUTI
        IND
        OUTD
        RET

; ---- stack-heavy: CALL/PUSH/POP/RET chains, RETN-less ----------------------------------------
        ORG 0540h
STKSEC: LD BC,0102h
        LD DE,0304h
        LD HL,0506h
        PUSH BC
        PUSH DE
        PUSH HL
        POP BC
        POP DE
        POP HL
        CALL S3
        LD HL,STKEND
        PUSH HL
        RET                        ; RET to a pushed address
STKEND: NOP
        RET
S3:     CALL S4
        RET
S4:     LD A,3
        RET

; ---- a last trip through the ISR with EI active before HALT ---------------------------------------
        ORG 0580h
ISRTAIL: EI
        LD B,6
TL:     NOP
        DJNZ TL
        RET

        ORG 9000h                  ; IM2 vector table
        DW 0200h

        END

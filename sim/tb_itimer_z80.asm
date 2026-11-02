; tb_itimer_z80.asm -- Z-80 program for sim/tb_itimer_z80.vhd: the IntervalTimer
; ($D0-$D3) raising INT through the real MicrocomputerZ80CPM fabric.
;
; Results (watched by the bench through the block-RAM write bus):
;   0900h FAIL  0 = all steps passed, else the code of the first failing check
;   0901h DONE  0AAh when the program has finished
;   0902h GOT   the value that failed
;   0903h WANT  the value expected
; Check codes: 1 IM 0 INTA took RST 38h, 2 IM 1 periodic count, 3 status seen in
; the ISR, 4 pending-while-DI count, 5 status after the ISR, 6 nothing pending
; after ACK, 7 one-shot count, 8 one-shot ISR status, 9 one-shot final status,
; 10 IE=0 raised no INT, 11 IE=0 status.
;
; Assemble: tools/z80asm.sh -o <base> sim/tb_itimer_z80.asm  (sim/run_itimer_z80.sh)

        .Z80
        ASEG

FAIL    EQU 0900h
DONE    EQU 0901h
GOT     EQU 0902h
WANT    EQU 0903h
ISRCNT  EQU 0910h
LASTST  EQU 0911h

IVLLO   EQU 0D0h
IVLHI   EQU 0D1h
CTRL    EQU 0D2h               ; write CONTROL, read STATUS
CMD     EQU 0D3h

        ORG 0000h
        JP START

        ORG 0038h               ; interrupt mode 1 (and mode 0 reading FFh = RST 38h)
ISR:    PUSH AF
        IN A,(CTRL)
        LD (LASTST),A
        AND 08h                 ; INTREQ: this timer is the source
        JR Z,ISRX
        LD A,(ISRCNT)
        INC A
        LD (ISRCNT),A
        LD A,02h                ; ACK
        OUT (CMD),A
ISRX:   POP AF
        EI
        RETI

; check A == B, else record code C and finish
CHK:    CP B
        RET Z
        LD (GOT),A
        LD A,B
        LD (WANT),A
        LD A,C
        LD (FAIL),A
FINISH: DI
        LD A,0AAh
        LD (DONE),A
        HALT
        JR $

; stop the timer and clear every pending indication
QUIET:  XOR A
        OUT (CTRL),A
        LD A,06h
        OUT (CMD),A
        RET

; set the interval to A ms
SETIVL: OUT (IVLLO),A
        XOR A
        OUT (IVLHI),A
        RET

; wait (bounded) until STATUS bit B (mask in D) is set
WAITST: LD BC,0
WS1:    IN A,(CTRL)
        AND D
        RET NZ
        DEC BC
        LD A,B
        OR C
        JR NZ,WS1
        RET

START:  DI
        LD SP,0A00h
        XOR A
        LD (FAIL),A
        LD (DONE),A
        LD (ISRCNT),A
        LD (LASTST),A
        CALL QUIET

; 1. interrupt mode 0 (reset default): the INTA bus read is FFh = RST 38h
        LD A,1
        CALL SETIVL
        LD A,07h                ; RUN IE AUTO
        OUT (CTRL),A
        EI
        HALT
        DI
        CALL QUIET
        LD A,(ISRCNT)
        LD B,1
        LD C,1
        CALL CHK

; 2/3. interrupt mode 1, periodic: five interrupts, woken from HALT each time
        IM 1
        XOR A
        LD (ISRCNT),A
        LD A,07h
        OUT (CTRL),A
        EI
P1:     HALT
        LD A,(ISRCNT)
        CP 5
        JR C,P1
        DI
        CALL QUIET
        LD A,(ISRCNT)
        LD B,5
        LD C,2
        CALL CHK
        LD A,(LASTST)           ; EXPIRED RUNNING INTREQ IE AUTO
        LD B,3Dh
        LD C,3
        CALL CHK

; 4/5/6. expiries pile up while interrupts are disabled: EXPIRED and OVERFLOW;
; stopping the timer keeps them; EI takes exactly one interrupt, whose ACK
; releases INT, so a second EI takes none
        XOR A
        LD (ISRCNT),A
        LD A,07h
        OUT (CTRL),A
        LD D,02h                ; OVERFLOW
        CALL WAITST
        IN A,(CTRL)
        AND 0Bh                 ; EXPIRED OVERFLOW INTREQ
        LD B,0Bh
        LD C,4
        CALL CHK
        LD A,(ISRCNT)           ; DI: nothing taken
        LD B,0
        LD C,4
        CALL CHK
        LD A,02h                ; stop, keep IE
        OUT (CTRL),A
        LD A,04h                ; CLROVF only
        OUT (CMD),A
        EI
        NOP
        NOP
        NOP
        DI
        LD A,(ISRCNT)
        LD B,1
        LD C,4
        CALL CHK
        IN A,(CTRL)             ; ACKed in the ISR, stopped
        LD B,10h                ; IE only
        LD C,5
        CALL CHK
        EI
        NOP
        NOP
        NOP
        NOP
        DI
        LD A,(ISRCNT)
        LD B,1
        LD C,6
        CALL CHK

; 7/8/9. one-shot, 2 ms
        CALL QUIET
        XOR A
        LD (ISRCNT),A
        LD A,2
        CALL SETIVL
        LD A,03h                ; RUN IE (AUTO = 0)
        OUT (CTRL),A
        EI
        HALT
        DI
        LD A,(ISRCNT)
        LD B,1
        LD C,7
        CALL CHK
        LD A,(LASTST)           ; EXPIRED INTREQ IE, no RUNNING
        LD B,19h
        LD C,8
        CALL CHK
        IN A,(CTRL)
        LD B,10h
        LD C,9
        CALL CHK

; 10/11. IE = 0: the expiry is visible in STATUS but INT stays inactive
        CALL QUIET
        XOR A
        LD (ISRCNT),A
        LD A,1
        CALL SETIVL
        LD A,05h                ; RUN AUTO, IE = 0
        OUT (CTRL),A
        EI
        LD D,01h                ; EXPIRED
        CALL WAITST
        NOP
        NOP
        DI
        LD A,(ISRCNT)
        LD B,0
        LD C,10
        CALL CHK
        IN A,(CTRL)
        AND 09h                 ; EXPIRED set, INTREQ clear
        LD B,01h
        LD C,11
        CALL CHK
        CALL QUIET
        JP FINISH
        END

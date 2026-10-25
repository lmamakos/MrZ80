; ============================================================================
; fptest.asm - front-panel register pattern test
; ----------------------------------------------------------------------------
; PURPOSE
;   Check that every CPU register exposed on the front-panel capture chain
;   actually reaches the LEDs.  Each register is loaded with a distinctive
;   pattern and held long enough to see (~2 s); the pattern alternates
;   AA / 55 four times per register, so a dead, shorted or mis-mapped LED
;   group stands out, and the byte order of a 16-bit pair can be read
;   straight off the panel.
;
; WHAT IS TESTED
;   Each pass sweeps the panel twice per alternation - once with every
;   register showing AA, once with every register showing 55 - four times
;   over, so each of the 16 registers is presented 8 times at ~2 s each
;   (about 2 1/4 minutes per pass) and every register alternates AA/55 four
;   times per pass.  The sweep order is B, C, D, E, H, L, IX, IY, then B', C', D',
;   E', H', L' and IX, IY again.  A/AF are deliberately excluded - keeping
;   the accumulator live would leave no register for the console and timer
;   traffic that has to run during the hold (every IN/OUT names A), and the
;   flags are not a useful pattern target.  IX/IY are bank-independent in
;   this core, so their second appearance is a cross-check that EXX left
;   them alone (doc/t80_reg_debug_vector.md).  After the last register the
;   whole pass repeats, forever, until reset.
;
; CONSOLE / PANEL READING
;   One console line per presentation, printed as the pattern is applied:
;
;       Testing B  = AA ........
;
;   Each dot is one quarter-second of hold (eight per line), so the console
;   leads the panel by the hold time - which is the point: the line tells you
;   what the LEDs should be showing while you watch them.  With the identity
;   profile (no .fpp loaded) LED n = chain bit n, so
;   (../../SIGNAL-CAPTURES.md):
;
;       B 64..71    C 72..79    D 96..103   E 104..111
;       H 128..135  L 136..143  IX 160..175               IY 176..191
;       B' 80..87   C' 88..95   D' 112..119  E' 120..127
;       H' 144..151 L' 152..159
;
; HOLDING A PATTERN WITHOUT DISTURBING IT
;   The difficulty here is that the hold has to run while the register under
;   test still holds the pattern, and the hold itself needs the accumulator
;   (BenchTimer IN/OUT) plus console output.  Two rules make that work:
;
;   1. Announce first, apply second.  The "Testing X = AA" line is printed
;      *before* the register is loaded, so the printing that uses A and HL
;      happens while nothing is highlighted.  Only the hold runs afterwards,
;      and the hold was written to need A plus RAM scratch only - no HL -
;      which is precisely what makes H and L testable.
;
;   2. Alternate-bank presentations park their pattern in the SHADOW bank and
;      undo the swap before the hold: EXX, load, EXX.  The chain reports the
;      inactive bank at the primed LED positions (doc/t80_reg_debug_vector.md
;      section 1.3), so the pattern shows up at the B'-L' LEDs while every
;      main register - A and HL included - is free scratch for the hold.
;
;   Loop counters live in RAM for the same reason: nothing may be required to
;   survive a hold except the register being highlighted.
;
; MAKING THE PRIMED GROUP STAND OUT
;   B and B' sit at different LED positions but would otherwise show the same
;   thing (the bank not under test still holds the value from the previous
;   group).  So before each group the OTHER bank is pre-loaded with the
;   complement: the shadow bank gets ~pattern ahead of the main-group
;   presentations, and the main bank gets ~pattern ahead of the primed ones.
;   The highlighted group then reads AA against a 55 background.
;
; TIMING
;   BenchTimer (I/O 0C0h-0CFh): OUT to a channel port latches that channel's
;   free-running 32-bit counter, IN reads the latch back.  Waiting for the ms
;   counter's low byte to read zero is therefore a quarter-second (256 ms)
;   tick; each call ends on the same boundary, so back-to-back holds are a
;   steady ~2 s and the delay is independent of instruction timing, wait
;   states and CPU clock.
;
; HARDWARE / BUILD
;   Run from block RAM: OSD "Boot Load Target = Block RAM", boot image
;   fptest.bin.  Console output goes to BOTH the video terminal (ACIA
;   80h/81h) and the serial console (ACIA 82h/83h, 115200 8N1).  Needs a
;   core whose capture chain carries the T80 REG vector (chain bits
;   32..223) - see ../../SIGNAL-CAPTURES.md.
;
; BUILD:  make -C testing fptest.bin    (um80 + ul80 + objcopy)
; ============================================================================

	.z80
                org     0000h

CONSTAT         equ     080h            ; video terminal status/control
CONDATA         equ     081h            ; video terminal data
SERSTAT         equ     082h          ; serial ACIA status/control
SERDATA         equ     083h        ; serial ACIA data
TDRE            equ     002h       ; transmitter data register empty

TMS0            equ     0C0h            ; BenchTimer channel 0, 1 ms/tick
STACK           equ     3F00h

PAT1            equ     0AAh          ; the two alternating patterns
PAT2            equ     055h
NPAT            equ     4             ; AA/55 alternations per register
NQ              equ     8             ; quarter-second ticks per hold (~2 s)

; ============================================================================
; Presentation macros.  Announce first (free to use any register), then apply
; the pattern, then hold it.  Arguments are labels only: the bank-swap
; instruction is fixed per macro because it contains a comma.
;
;   TEST   main-bank register - pattern left live in the register
;   TESTX  alternate BC/DE/HL - EXX around the load, pattern rests in shadow
; ============================================================================
TEST            MACRO   name,stf
                call    msgpre
                ld      hl,name
                call    puts
                ld      a,(pattern)
                call    puthex
                call    stf
                call    hold
                ENDM

TESTX           MACRO   name,stf
                call    msgpre
                ld      hl,name
                call    puts
                ld      a,(pattern)
                call    puthex
                exx
                call    stf
                exx
                call    hold
                ENDM

; ============================================================================
; Entry
; ============================================================================
start:
                di
                ld      sp,STACK

                ld      a,003h                  ; serial ACIA master reset
                out     (SERSTAT),a
                ld      a,015h                  ; 8N1, /16
                out     (SERSTAT),a
;               The video terminal needs no control-register write here: the
;               proven pattern in the other diagnostics initialises SERSTAT
;               only and writes data to both consoles.

                ld      hl,msg_banner
                call    puts

; ============================================================================
; Main loop: pass 1, 2, 3 ... forever, until reset
; ============================================================================
main:
                ld      hl,msg_pass           ; "--- pass NN" (1, 2, 3 ...)
                call    puts
                ld      a,(pass)
                call    puthex
                call    crlf
                ld      a,(pass)              ; bump for the next pass, 255 -> 1
                inc     a
                jr      nz,pass_ok
                ld      a,1
pass_ok:
                ld      (pass),a

; ---- main register set ------------------------------------------------------
                ld      a,NPAT                ; AA/55 alternation countdown
                ld      (np),a
ploop1:
                ld      a,PAT1
                ld      (pattern),a
                ld      (pattern+1),a
                exx                           ; shadow bank = complement, so the
                call    setbankc              ; main-group LEDs stand out
                exx
                TEST    msgB,   setB
                TEST    msgC,   setC
                TEST    msgD,   setD
                TEST    msgE,   setE
                TEST    msgH,   setH
                TEST    msgL,   setL
                TEST    msgIX,  setIX
                TEST    msgIY,  setIY

                ld      a,PAT2
                ld      (pattern),a
                ld      (pattern+1),a
                exx
                call    setbankc
                exx
                TEST    msgB,   setB
                TEST    msgC,   setC
                TEST    msgD,   setD
                TEST    msgE,   setE
                TEST    msgH,   setH
                TEST    msgL,   setL
                TEST    msgIX,  setIX
                TEST    msgIY,  setIY

                ld      a,(np)                ; next alternation, loop while > 0
                dec     a
                ld      (np),a
                jr      nz,ploop1

; ---- alternate register set -------------------------------------------------
; Each presentation swaps to the alternate bank, loads, and swaps back, so the
; pattern rests in the shadow bank (where the chain reports it at the primed
; LED positions) and the main registers are free scratch for the hold.  IX/IY
; are unaffected by EXX and are re-presented as a cross-check.
                ld      a,NPAT
                ld      (np),a
ploop2:
                ld      a,PAT1
                ld      (pattern),a
                ld      (pattern+1),a
                call    setbankc              ; main bank = complement, so the
                TESTX   msgBS,  setB
                TESTX   msgCS,  setC
                TESTX   msgDS,  setD
                TESTX   msgES,  setE
                TESTX   msgHS,  setH
                TESTX   msgLS,  setL
                TEST    msgIX,  setIX
                TEST    msgIY,  setIY

                ld      a,PAT2
                ld      (pattern),a
                ld      (pattern+1),a
                call    setbankc
                TESTX   msgBS,  setB
                TESTX   msgCS,  setC
                TESTX   msgDS,  setD
                TESTX   msgES,  setE
                TESTX   msgHS,  setH
                TESTX   msgLS,  setL
                TEST    msgIX,  setIX
                TEST    msgIY,  setIY

                ld      a,(np)
                dec     a
                ld      (np),a
                jr      nz,ploop2

                jp      main

; ============================================================================
; hold - keep the highlighted register on the panel for NQ quarter-seconds,
; printing one progress dot per tick.  Needs only the accumulator and RAM
; scratch: no HL, no other register, so the pattern under test survives.
; ============================================================================
hold:
                ld      a,NQ
                ld      (units),a
hold_loop:
                call    qtr_wait
                ld      a,'.'
                call    putc
                ld      a,(units)
                dec     a
                ld      (units),a
                jr      nz,hold_loop
                ret

; ============================================================================
; qtr_wait - block until the BenchTimer ms low byte wraps to zero: ~256 ms,
; returning on the boundary so successive calls are evenly spaced.
; Clobbers A only.
; ============================================================================
qtr_wait:
                out     (TMS0),a
qw_sync:
                in      a,(TMS0)
                or      a
                jr      nz,qw_run               ; mid-period: wait for the wrap
                out     (TMS0),a              ; caught the boundary: re-latch
                jr      qw_sync
qw_run:
                out     (TMS0),a
                in      a,(TMS0)
                or      a
                jr      nz,qw_run
                ret

; ---- bank pre-load: complement of the pattern into B/C/D/E/H/L of the
; current bank, i.e. the bank that is NOT under test.  Gives the highlighted
; group something to stand out against.  A is scratch here by design: the
; register under test is never written by this routine.
setbankc:
                ld      a,(pattern)
                cpl
                ld      b,a
                ld      c,a
                ld      d,a
                ld      e,a
                ld      h,a
                ld      l,a
                ret

; ---- register loaders: pattern -> exactly one register, nothing else -------
; um80 gives no LD r,(nn) for r other than A, so every loader goes through
; the accumulator - safe here because A is never the register under test.
setB:
                ld      a,(pattern)
                ld      b,a
                ret

setC:
                ld      a,(pattern)
                ld      c,a
                ret

setD:
                ld      a,(pattern)
                ld      d,a
                ret

setE:
                ld      a,(pattern)
                ld      e,a
                ret

setH:
                ld      a,(pattern)
                ld      h,a
                ret

setL:
                ld      a,(pattern)
                ld      l,a
                ret

setIX:
                ld      ix,(pattern)              ; DD 2A - 16-bit load from
                ret                               ; memory, no other register used

setIY:
                ld      iy,(pattern)              ; FD 2A
                ret

; ============================================================================
; Console - output to BOTH the video terminal and the serial port
; ============================================================================
putc:
                push    af
pc_w1:
                in      a,(CONSTAT)
                and     TDRE
                jr      z,pc_w1
                pop     af
                out     (CONDATA),a
                push    af
pc_w2:
                in      a,(SERSTAT)
                and     TDRE
                jr      z,pc_w2
                pop     af
                out     (SERDATA),a
                ret

puts:
                ld      a,(hl)
                or      a
                ret     z
                call    putc
                inc     hl
                jr      puts

crlf:
                ld      a,0Dh
                call    putc
                ld      a,0Ah
                jp      putc

msgpre:
                ld      hl,msg_testing
                jp      puts

; puthex - print A as two hex digits.  Clobbers A only (af saved).
puthex:
                push    af
                rrca
                rrca
                rrca
                rrca
                call    puthexnib
                pop     af
                call    puthexnib
                ret

puthexnib:
                and     00Fh
                add     a,090h
                daa
                adc     a,040h
                daa
                call    putc
                ret

; ============================================================================
; Messages
; ============================================================================
msg_banner:     db      0Dh,0Ah
                db      'Front-panel register pattern test',0Dh,0Ah
                db      'Each register is held ~2 s; pattern AA/55 x4.',0Dh,0Ah
                db      'Watch the LED group for the named register.',0Dh,0Ah
                db      'Chain map: SIGNAL-CAPTURES.md',0Dh,0Ah,0
msg_pass:       db      '--- pass ',0
msg_testing:    db      'Testing ',0
msgB:           db      'B ',0
msgBS:          db      'B',27h,' ',0              ; B'
msgC:           db      'C ',0
msgCS:          db      'C',27h,' ',0              ; C'
msgD:           db      'D ',0
msgDS:          db      'D',27h,' ',0              ; D'
msgE:           db      'E ',0
msgES:          db      'E',27h,' ',0              ; E'
msgH:           db      'H ',0
msgHS:          db      'H',27h,' ',0              ; H'
msgL:           db      'L ',0
msgLS:          db      'L',27h,' ',0              ; L'
msgIX:          db      'IX ',0
msgIY:          db      'IY ',0

; ============================================================================
; Scratch (initialised: the whole image, data included, is loaded to RAM)
; ============================================================================
pattern:        dw      0               ; value presented to the reg under test
units:          db      0             ; quarter-second dot countdown
np:             db      0           ; AA/55 alternation countdown
pass:           db      1         ; pass counter, 1..254

                end     start

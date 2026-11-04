; ============================================================================
; psgtest.asm  -  dual YM2149 PSG test (I/O ports 50h/51h and 68h/60h)
; ----------------------------------------------------------------------------
; Plays the five-note "Close Encounters of the Third Kind" motif
; (G4 A4 F4 F3 C4) on each PSG and reports what it finds:
;
;   1. Probe both devices the way RomWBW ay.asm does: select R2, write 55h,
;      read it back (device 1 via its DATA port 51h, as AYMODE_COLECO does;
;      device 2 via its SELECT port 68h, the "EB" card convention vibetune
;      uses).  A missing device reads FFh.
;   2. Read the left/right mixer gains (MrZ80 extension registers 80h-86h and
;      90h-96h, reached through the device-1 SELECT port) and report which
;      OSD "PSG Stereo" setting is in effect: Mono, ABC or ACB.
;   3. Play the motif on device 1 channel A, then on device 2 channel C.
;      Under OSD ABC the first pass is heard mostly in the LEFT ear and the
;      second mostly in the RIGHT (A and the device-2 C channel F are panned
;      opposite ways); under ACB the device-2 pass is centred; under Mono
;      both are centred.
;   4. Leave both chips silent (all volumes 0, tone/noise disabled).
;
; Tone period = 1789772 / (16 * f); the PSG clock is the MSX 1.7897725 MHz.
;   G4 392.00 Hz -> 285   A4 440.00 Hz -> 254   F4 349.23 Hz -> 320
;   F3 174.61 Hz -> 641   C4 261.63 Hz -> 428
; Timing uses the BenchTimer millisecond channel (C0h-C3h).
;
; Run from block RAM (Boot Load Target = Block RAM) or SDRAM.
; CONSOLES (both 6850-compatible ACIA): video terminal 0x80/0x81, serial
; console 0x82/0x83; output goes to BOTH.
; BUILD: make -C testing psgtest.bin   (or tools/z80asm.sh testing/psgtest.asm)
; ============================================================================

                .z80
                org     0000h
                jp      start

CONSTAT         equ     080h            ; video terminal status/control
CONDATA         equ     081h            ; video terminal data
SERSTAT         equ     082h            ; serial ACIA status/control
SERDATA         equ     083h            ; serial ACIA data
TDRE            equ     002h

TMS0            equ     0C0h            ; BenchTimer channel 0, 1 ms/tick

PSG1SEL         equ     050h            ; device 1 SELECT (and read)
PSG1DAT         equ     051h            ; device 1 DATA   (and read)
PSG2SEL         equ     068h            ; device 2 SELECT (and read)
PSG2DAT         equ     060h            ; device 2 DATA   (and read)

R_MIXER         equ     7               ; AY R7: noise/tone enables (0 = on)
R_AVOL          equ     8               ; AY R8..R10: channel A..C volume
MIX_L           equ     080h            ; left mixer, regs 0-9 at 80h-89h
MIX_R           equ     090h            ; right mixer, regs 0-9 at 90h-99h

NOTEVOL         equ     13              ; fixed volume (0-15)
GAPMS           equ     60              ; silence between notes, ms

STACK           equ     3F00h

; ============================================================================
start:
                di
                ld      sp,STACK
                ld      a,003h                  ; ACIA master reset
                out     (SERSTAT),a
                ld      a,015h                  ; 8N1, /16
                out     (SERSTAT),a

                ld      hl,msg_banner
                call    puts

; ---- 1. probe ---------------------------------------------------------------
                ld      hl,msg_probe1
                call    puts
                ld      a,2
                out     (PSG1SEL),a
                ld      a,55h
                out     (PSG1DAT),a
                in      a,(PSG1DAT)
                ld      (dev1),a
                call    report_probe

                ld      hl,msg_probe2
                call    puts
                ld      a,2
                out     (PSG2SEL),a
                ld      a,55h
                out     (PSG2DAT),a
                in      a,(PSG2SEL)             ; EB convention: read via SELECT
                ld      (dev2),a
                call    report_probe

                ld      a,(dev1)
                cp      55h
                jp      nz,nodev1               ; nothing to play on

; ---- 2. mixer / OSD stereo setting ------------------------------------------
                ld      hl,msg_mixl
                call    puts
                ld      b,MIX_L
                call    show_mixer
                ld      hl,msg_mixr
                call    puts
                ld      b,MIX_R
                call    show_mixer

                ld      hl,msg_osd
                call    puts
                ld      a,MIX_L+1               ; left gain of channel B ...
                call    rd1
                ld      c,a
                ld      a,MIX_L+2               ; ... and of channel C
                call    rd1
                ld      b,a                     ; B = L.C, C = L.B
                ld      a,c
                cp      b
                ld      hl,msg_mono             ; L.B == L.C: Mono
                jr      z,osd_done
                ld      hl,msg_abc              ; L.B > L.C: B centre, C right
                jr      nc,osd_done
                ld      hl,msg_acb              ; L.B < L.C: C centre, B right
osd_done:
                call    puts

; ---- 3. the motif -------------------------------------------------------------
                ld      hl,msg_play1
                call    puts
                ld      a,PSG1SEL
                ld      (selport),a
                ld      a,PSG1DAT
                ld      (datport),a
                xor     a                       ; channel A
                call    play_motif

                ld      a,(dev2)
                cp      55h
                jr      nz,skip2
                ld      hl,msg_play2
                call    puts
                ld      a,PSG2SEL
                ld      (selport),a
                ld      a,PSG2DAT
                ld      (datport),a
                ld      a,2                     ; channel C (mixer channel F)
                call    play_motif
                jr      done
skip2:
                ld      hl,msg_skip2
                call    puts
done:
                ld      hl,msg_done
                call    puts
                halt

nodev1:
                ld      hl,msg_nodev
                call    puts
                halt

; ----------------------------------------------------------------------------
; report_probe: A = value read back; prints "present" (55h) or "absent".
report_probe:
                push    af
                call    puthex
                pop     af
                cp      55h
                ld      hl,msg_present
                jr      z,rp_out
                ld      hl,msg_absent
rp_out:         jp      puts

; show_mixer: B = 80h (left) or 90h (right).  Prints gains A..F, master vol.
show_mixer:
                ld      c,7                     ; registers 0..6
sm_loop:
                ld      a,b
                call    rd1
                call    puthex
                ld      a,' '
                call    putc
                inc     b
                dec     c
                jr      nz,sm_loop
                jp      crlf

; rd1: A = device-1 SELECT value; returns the register in A.
rd1:
                out     (PSG1SEL),a
                in      a,(PSG1DAT)
                ret

; wrpsg: D = register, E = value, on the device in (selport)/(datport).
wrpsg:
                push    bc
                ld      a,(selport)
                ld      c,a
                out     (c),d
                ld      a,(datport)
                ld      c,a
                out     (c),e
                pop     bc
                ret

; ----------------------------------------------------------------------------
; play_motif: A = channel (0 = A, 1 = B, 2 = C) on the current device.
; Enables only that channel's tone, plays the five notes, then silences
; the chip.
play_motif:
                ld      (chan),a
                ld      b,a                     ; R7: tone enable bit = 0 for chan
                ld      a,0FEh
                inc     b
pm_bit:         dec     b
                jr      z,pm_bit_done
                rlca
                jr      pm_bit
pm_bit_done:
                and     03Fh                    ; noise off, I/O ports as inputs
                or      038h
                ld      e,a
                ld      d,R_MIXER
                call    wrpsg

                ld      hl,motif
pm_note:
                ld      e,(hl)                  ; period low (0 = end of list)
                inc     hl
                ld      d,(hl)                  ; period high
                inc     hl
                ld      a,e
                or      d
                jr      z,pm_end
                push    hl
                ld      a,(chan)                ; tone period regs = 2*chan, 2*chan+1
                add     a,a
                ld      b,d                     ; save high byte
                ld      d,a
                call    wrpsg                   ; fine tune
                inc     d
                ld      e,b
                call    wrpsg                   ; coarse tune
                pop     hl
                ld      c,(hl)                  ; duration, ms
                inc     hl
                ld      b,(hl)
                inc     hl
                push    hl
                push    bc
                call    vol_on
                pop     hl                      ; HL = duration
                call    delay_ms
                call    vol_off
                ld      hl,GAPMS
                call    delay_ms
                pop     hl
                jr      pm_note
pm_end:
                ; silence: all three volumes 0, tones and noise disabled
                ld      d,R_AVOL
                ld      e,0
                call    wrpsg
                inc     d
                call    wrpsg
                inc     d
                call    wrpsg
                ld      d,R_MIXER
                ld      e,03Fh
                call    wrpsg
                ld      hl,400
                jp      delay_ms

vol_on:
                ld      e,NOTEVOL
                jr      vol_set
vol_off:
                ld      e,0
vol_set:
                ld      a,(chan)
                add     a,R_AVOL
                ld      d,a
                jp      wrpsg

; ----------------------------------------------------------------------------
; delay_ms: wait HL milliseconds (1..65535) on BenchTimer channel 0.
; Uses only the low 16 bits of the counter; the subtraction is wrap-safe.
delay_ms:
                push    hl
                call    ms_now
                ld      (t0),hl
                pop     de                      ; DE = duration
dm_loop:
                call    ms_now
                push    de
                ld      de,(t0)
                or      a
                sbc     hl,de                   ; HL = elapsed
                pop     de
                or      a
                sbc     hl,de                   ; elapsed - duration
                jr      c,dm_loop
                ret

ms_now:                                         ; HL = ms counter, low 16 bits
                out     (TMS0),a                ; latch channel 0
                in      a,(TMS0)
                ld      l,a
                in      a,(TMS0+1)
                ld      h,a
                ret

; ---- console (output to BOTH the video terminal and the serial port) -------
puthex:
                push    af
                rrca
                rrca
                rrca
                rrca
                call    hexnib
                pop     af
hexnib:
                and     0Fh
                add     a,'0'
                cp      '9'+1
                jr      c,hn_out
                add     a,7
hn_out:         jp      putc

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

; ---- data ------------------------------------------------------------------
; The motif: period (16-bit), duration in ms (16-bit); period 0 ends it.
motif:
                dw      285, 450                ; G4
                dw      254, 450                ; A4
                dw      320, 450                ; F4
                dw      641, 450                ; F3 (an octave below)
                dw      428, 1400               ; C4, held
                dw      0

msg_banner:     db      0Dh,0Ah,'Dual YM2149 PSG test (ports 50h/51h, 68h/60h)',0Dh,0Ah,0
msg_probe1:     db      'Device 1 ($50/$51) R2 <- 55h, read $51: ',0
msg_probe2:     db      'Device 2 ($68/$60) R2 <- 55h, read $68: ',0
msg_present:    db      '  present',0Dh,0Ah,0
msg_absent:     db      '  absent',0Dh,0Ah,0
msg_mixl:       db      'Left  mixer gain A B C D E F, master: ',0
msg_mixr:       db      'Right mixer gain A B C D E F, master: ',0
msg_osd:        db      'OSD PSG Stereo: ',0
msg_mono:       db      'Mono (all channels centred)',0Dh,0Ah,0
msg_abc:        db      'ABC (A left, B centre, C right)',0Dh,0Ah,0
msg_acb:        db      'ACB (A left, C centre, B right)',0Dh,0Ah,0
msg_play1:      db      'Playing on device 1, channel A ...',0Dh,0Ah,0
msg_play2:      db      'Playing on device 2, channel C ...',0Dh,0Ah,0
msg_skip2:      db      'Device 2 absent: skipped.',0Dh,0Ah,0
msg_nodev:      db      'Device 1 absent: nothing to play.',0Dh,0Ah,0
msg_done:       db      'Done; both PSGs silent.',0Dh,0Ah,0

selport:        db      0
datport:        db      0
chan:           db      0
dev1:           db      0
dev2:           db      0
t0:             dw      0

                end     start

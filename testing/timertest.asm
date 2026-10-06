; ============================================================================
; timertest.asm  -  BenchTimer peripheral test (I/O ports 0C0h-0CFh)
; ----------------------------------------------------------------------------
; BenchTimer: four 32-bit snapshot channels over free-running counters.
;   ch0  0C0h-0C3h  1 ms/tick     ch2  0C8h-0CBh  1 us/tick
;   ch1  0C4h-0C7h  1 ms/tick     ch3  0CCh-0CFh  1 us/tick
; OUT (any value) to any port of a channel latches that channel; IN reads the
; latched value, byte 0 (bits 7:0) at the channel's first port, little-endian.
;
; Tests:
;   1. Snapshot and print all four channels (time since FPGA configuration;
;      the counters are NOT cleared by a CPU reset, so re-running the program
;      after pressing reset must show larger values).
;   2. Re-read ch0 without re-latching: must be identical (reads have no
;      side effects).
;   3. us counter strictly increasing over 4096 back-to-back snapshots.
;   4. Calibration, 3 rounds: align to a ms tick (ch1), snapshot us (ch3),
;      wait until 1000 ms have elapsed (ch1), snapshot us (ch3) again.
;      Expect 1000000 us +/- 200 (PASS/FAIL).
;   5. Snapshot ch0 at program start and end: prints total run time.
;
; Run from block RAM (Boot Load Target = Block RAM) or SDRAM.
; SERIAL CONSOLE (6850-compatible ACIA)  0x82 status/control, 0x83 data
; BUILD: make -C testing timertest.bin   (or tools/z80asm.sh)
; ============================================================================

	.z80
                org     0000h

SERSTAT         equ     082h
SERDATA         equ     083h
TDRE            equ     002h

TMS0            equ     0C0h            ; channel 0, ms
TMS1            equ     0C4h            ; channel 1, ms
TUS0            equ     0C8h            ; channel 2, us
TUS1            equ     0CCh            ; channel 3, us

STACK           equ     3F00h
NMONO           equ     4096            ; monotonic-test samples
TOL             equ     200             ; calibration tolerance (us)

; ============================================================================
start:
                di
                ld      sp,STACK
                ld      c,TMS0                  ; run-time start stamp
                ld      hl,tstart
                call    snap32

                ld      a,003h                  ; ACIA master reset
                out     (SERSTAT),a
                ld      a,015h                  ; 8N1, /16
                out     (SERSTAT),a

                ld      hl,msg_banner
                call    puts

; ---- 1. all four channels --------------------------------------------------
                ld      c,TMS0
                ld      hl,v0
                call    snap32
                ld      c,TMS1
                ld      hl,v1
                call    snap32
                ld      c,TUS0
                ld      hl,v2
                call    snap32
                ld      c,TUS1
                ld      hl,v3
                call    snap32

                ld      hl,msg_ch0
                call    puts
                ld      hl,v0
                call    putdec32
                ld      hl,msg_ch1
                call    puts
                ld      hl,v1
                call    putdec32
                ld      hl,msg_ch2
                call    puts
                ld      hl,v2
                call    putdec32
                ld      hl,msg_ch3
                call    puts
                ld      hl,v3
                call    putdec32
                call    crlf

; ---- 2. re-read without latching -------------------------------------------
                ld      hl,msg_reread
                call    puts
                ld      c,TMS0
                ld      hl,v4
                call    read32
                ld      hl,v0
                ld      de,v4
                call    sub32
                call    reszero
                call    passfail
                call    crlf

; ---- 3. us counter strictly increasing -------------------------------------
                ld      hl,msg_mono
                call    puts
                ld      hl,0
                ld      (nfail),hl
                ld      hl,NMONO
                ld      (cnt),hl
                ld      c,TUS0
                ld      hl,prev
                call    snap32
mono_loop:
                ld      c,TUS0
                ld      hl,cur
                call    snap32
                ld      hl,cur
                ld      de,prev
                call    sub32                   ; res = cur - prev
                ld      a,(res+3)
                bit     7,a
                jr      nz,mono_bad             ; went backwards
                call    reszero
                jr      nz,mono_ok              ; strictly increased
mono_bad:
                ld      hl,(nfail)
                inc     hl
                ld      (nfail),hl
mono_ok:
                ld      hl,cur
                ld      de,prev
                ld      bc,4
                ldir
                ld      hl,(cnt)
                dec     hl
                ld      (cnt),hl
                ld      a,h
                or      l
                jr      nz,mono_loop
                ld      hl,msg_fails
                call    puts
                ld      hl,(nfail)
                ld      (num),hl
                ld      hl,0
                ld      (num+2),hl
                ld      hl,num
                call    putdec32
                ld      a,' '
                call    putc
                ld      hl,(nfail)
                ld      a,h
                or      l
                call    passfail
                call    crlf

; ---- 4. calibration: 1000 ms vs us counter ---------------------------------
                ld      a,3
                ld      (round),a
cal_loop:
                ld      hl,msg_cal
                call    puts
                ; align to a ms tick
                ld      c,TMS1
                ld      hl,mstart
                call    snap32
cal_edge:
                ld      c,TMS1
                ld      hl,cur
                call    snap32
                ld      hl,cur
                ld      de,mstart
                call    sub32
                call    reszero
                jr      z,cal_edge
                ld      c,TUS1                  ; us at the tick
                ld      hl,usa
                call    snap32
                ld      hl,cur                  ; mstart = tick value
                ld      de,mstart
                ld      bc,4
                ldir
                ld      hl,mstart               ; target = mstart + 1000
                ld      de,k1000
                call    add32
                ld      hl,res
                ld      de,target
                ld      bc,4
                ldir
cal_wait:
                ld      c,TMS1
                ld      hl,cur
                call    snap32
                ld      hl,cur
                ld      de,target
                call    sub32                   ; res = cur - target
                ld      a,(res+3)
                bit     7,a
                jr      nz,cal_wait             ; cur < target
                ld      c,TUS1
                ld      hl,usb
                call    snap32

                ld      hl,cur                  ; print elapsed ms
                ld      de,mstart
                call    sub32
                ld      hl,res
                call    putdec32
                ld      hl,msg_mseq
                call    puts
                ld      hl,usb                  ; elapsed us
                ld      de,usa
                call    sub32
                ld      hl,res
                ld      de,v4                   ; keep a copy
                ld      bc,4
                ldir
                ld      hl,v4
                call    putdec32
                ld      hl,msg_us
                call    puts
                ; |elapsed_us - 1000000| <= TOL  <=>  (d - 1000000 + TOL) < 2*TOL
                ld      hl,v4
                ld      de,klow
                call    sub32                   ; res = d - (1000000 - TOL)
                ld      a,(res+3)
                ld      b,a
                ld      a,(res+2)
                or      b
                jr      nz,cal_fail
                ld      hl,(res)
                ld      de,2*TOL+1
                or      a
                sbc     hl,de
                jr      nc,cal_fail
                xor     a                       ; Z = pass
                jr      cal_rep
cal_fail:
                or      1                       ; NZ = fail
cal_rep:
                call    passfail
                call    crlf
                ld      hl,round
                dec     (hl)
                jp      nz,cal_loop

; ---- 5. total run time -----------------------------------------------------
                ld      c,TMS0
                ld      hl,tend
                call    snap32
                ld      hl,msg_total
                call    puts
                ld      hl,tend
                ld      de,tstart
                call    sub32
                ld      hl,res
                call    putdec32
                ld      hl,msg_done
                call    puts
halt_loop:
                jr      halt_loop

; ============================================================================
; snap32: latch channel whose first port is C, then read it into (HL).
; read32: read the 4 latched bytes of channel C into (HL) (no latch).
; Clobbers A, B, C, HL.
snap32:
                out     (c),a
read32:
                ld      b,4
r32_loop:
                in      a,(c)
                ld      (hl),a
                inc     hl
                inc     c
                djnz    r32_loop
                ret

; sub32: res = (HL) - (DE), 32-bit little-endian. Clobbers A, B, DE, HL, IX.
sub32:
                ld      ix,res
                ld      b,4
                or      a
s32_loop:
                ld      a,(hl)
                ex      de,hl
                sbc     a,(hl)
                ex      de,hl
                ld      (ix+0),a
                inc     hl
                inc     de
                inc     ix
                djnz    s32_loop
                ret

; add32: res = (HL) + (DE). Clobbers A, B, DE, HL, IX.
add32:
                ld      ix,res
                ld      b,4
                or      a
a32_loop:
                ld      a,(hl)
                ex      de,hl
                adc     a,(hl)
                ex      de,hl
                ld      (ix+0),a
                inc     hl
                inc     de
                inc     ix
                djnz    a32_loop
                ret

; reszero: Z set if res == 0. Clobbers A, HL.
reszero:
                ld      hl,res
                ld      a,(hl)
                inc     hl
                or      (hl)
                inc     hl
                or      (hl)
                inc     hl
                or      (hl)
                ret

; passfail: print "PASS" if Z, else "FAIL".
passfail:
                ld      hl,msg_pass
                jr      z,pf_out
                ld      hl,msg_fail
pf_out:
                jp      puts

; putdec32: print the 32-bit unsigned value at (HL) in decimal.
putdec32:
                ld      de,num
                ld      bc,4
                ldir
                ld      c,0                     ; digit count
pd_loop:
                call    div10
                add     a,'0'
                push    af
                inc     c
                ld      hl,num
                ld      a,(hl)
                inc     hl
                or      (hl)
                inc     hl
                or      (hl)
                inc     hl
                or      (hl)
                jr      nz,pd_loop
pd_out:
                pop     af
                call    putc
                dec     c
                jr      nz,pd_out
                ret

; div10: num /= 10, A = remainder. Clobbers B, HL.
div10:
                xor     a
                ld      b,32
d10_loop:
                ld      hl,num
                sla     (hl)
                inc     hl
                rl      (hl)
                inc     hl
                rl      (hl)
                inc     hl
                rl      (hl)
                rla
                cp      10
                jr      c,d10_next
                sub     10
                ld      hl,num
                inc     (hl)
d10_next:
                djnz    d10_loop
                ret

; ---- serial ----------------------------------------------------------------
putc:
                push    af
pc_wait:
                in      a,(SERSTAT)
                and     TDRE
                jr      z,pc_wait
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
msg_banner:     db      0Dh,0Ah,'BenchTimer test (ports C0h-CFh)',0Dh,0Ah,0
msg_ch0:        db      'ch0(ms)=',0
msg_ch1:        db      ' ch1(ms)=',0
msg_ch2:        db      ' ch2(us)=',0
msg_ch3:        db      ' ch3(us)=',0
msg_reread:     db      'Re-read without latch: ',0
msg_mono:       db      'us strictly increasing, 4096 samples: ',0
msg_fails:      db      'failures=',0
msg_cal:        db      'Calibrate: ',0
msg_mseq:       db      ' ms = ',0
msg_us:         db      ' us  ',0
msg_total:      db      'Total run time: ',0
msg_done:       db      ' ms. Done.',0Dh,0Ah,0
msg_pass:       db      'PASS',0
msg_fail:       db      'FAIL',0

k1000:          dw      1000,0
; 1000000 - TOL = 999800 = 000F4178h (the assembler evaluates 16-bit
; expressions, so the 32-bit constant is written out; update if TOL changes)
klow:           dw      4178h,000Fh

tstart:         ds      4
tend:           ds      4
v0:             ds      4
v1:             ds      4
v2:             ds      4
v3:             ds      4
v4:             ds      4
prev:           ds      4
cur:            ds      4
mstart:         ds      4
target:         ds      4
usa:            ds      4
usb:            ds      4
res:            ds      4
num:            ds      4
cnt:            ds      2
nfail:          ds      2
round:          ds      1

                end

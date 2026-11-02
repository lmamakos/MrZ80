; ============================================================================
; timertest.asm  -  BenchTimer (I/O ports 0C0h-0CFh) and IntervalTimer
;                   (I/O ports 0D0h-0D3h) peripheral test
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
;   6. IntervalTimer (ports 0D0h-0D3h, see HARDWARE.md), timed against the
;      BenchTimer microsecond counter (ch3), expected value +/- TOL us:
;        a. register read-back and the all-zero status after a stop;
;        b. periodic 10 ms, polled: ten periods = 100000 us;
;        c. one-shot 20 ms = 20000 us; it stays stopped and does not overflow;
;        d. 16-bit interval $0101 = 257 ms = 257000 us;
;        e. RESET command restarts the interval: 20 ms after RESET;
;        f. RUN=0 stops it: no expiry;
;        g. EXPIRED + OVERFLOW from a 1 ms timer left unacknowledged, CLROVF
;           and ACK clear them independently;
;        h. interrupts: interrupt mode 0 (the reset default; the acknowledge
;           read must give RST 38h), mode 1 periodic (10 interrupts =
;           100000 us, ISR sees status 3Dh, no spurious source), IE=0 holds
;           INT off and setting IE interrupts at once, wake from HALT.
;      The ISR at 0038h polls the status for INTREQ and ACKs, as RomWBW would.
;      Section 6h needs interrupts to work; if they do not, the HALT test is
;      skipped (it would hang) and the failures are reported.
;
; Run from block RAM (Boot Load Target = Block RAM) or SDRAM.
; CONSOLES (both 6850-compatible ACIA): video terminal 0x80/0x81, serial
; console 0x82/0x83; output goes to BOTH
; BUILD: make -C testing timertest.bin   (or tools/z80asm.sh)
; ============================================================================

	.z80
                org     0000h
                jp      start

CONSTAT         equ     080h            ; video terminal status/control
CONDATA         equ     081h            ; video terminal data
SERSTAT         equ     082h            ; serial ACIA status/control
SERDATA         equ     083h            ; serial ACIA data
TDRE            equ     002h

TMS0            equ     0C0h            ; channel 0, ms
TMS1            equ     0C4h            ; channel 1, ms
TUS0            equ     0C8h            ; channel 2, us
TUS1            equ     0CCh            ; channel 3, us

STACK           equ     3F00h
NMONO           equ     4096            ; monotonic-test samples
TOL             equ     200             ; calibration tolerance (us)

; IntervalTimer
ITIVLLO         equ     0D0h            ; INTERVAL low  (W/R)
ITIVLHI         equ     0D1h            ; INTERVAL high (W/R)
ITCTRL          equ     0D2h            ; W: CONTROL   R: STATUS
ITCMD           equ     0D3h            ; W: COMMAND   R: STATUS
ITC_RUN         equ     01h
ITC_IE          equ     02h
ITC_AUTO        equ     04h
ITK_RST         equ     01h
ITK_ACK         equ     02h
ITK_OVF         equ     04h             ; CLROVF
ITS_EXP         equ     01h
ITS_OVF         equ     02h
ITS_RUN         equ     04h
ITS_REQ         equ     08h

; ---- interrupt mode 1 handler (mode 0 reads FFh = RST 38h from the bus) ----
                org     0038h
isr:
                push    af
                in      a,(ITCTRL)              ; STATUS
                ld      (laststat),a
                and     ITS_REQ                 ; is this timer the source?
                jr      z,isr_other
                ld      a,(isrcnt)
                inc     a
                ld      (isrcnt),a
                ld      a,ITK_ACK
                out     (ITCMD),a
                jr      isr_x
isr_other:
                ld      a,(spurious)
                inc     a
                ld      (spurious),a
isr_x:
                pop     af
                ei
                reti

; ============================================================================
start:
                di
                im      0                       ; reset default, set explicitly
                ld      sp,STACK
                xor     a
                ld      (nbad),a
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

; ---- 6. IntervalTimer -------------------------------------------------------
                ld      hl,msg_it
                call    puts
                call    itquiet

                call    t_reg
                call    t_per
                call    t_one
                call    t_16
                call    t_rst
                call    t_stop
                call    t_ovf
                ld      a,(nbad)
                ld      (nbad0),a
                call    t_im0
                call    t_im1
                call    t_ie
                call    t_halt
                ld      hl,msg_it_sum
                call    puts
                ld      a,(nbad)
                or      a
                jr      nz,sum_bad
                ld      hl,msg_allpass
                call    puts
                jr      sum_x
sum_bad:        call    puthex
                ld      hl,msg_nfail
                call    puts
sum_x:          call    crlf

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

; ---- IntervalTimer tests (called from section 6; a timed-out wait ends the
; test through to_fail, which returns to the caller) -----------------------
t_reg:
; 6a. register read-back; status and command ports read the same, all zero
                ld      hl,msg_it_reg
                call    puts
                ld      hl,1234h
                call    itsetms
                in      a,(ITIVLLO)
                cp      34h
                jr      nz,rg_bad
                in      a,(ITIVLHI)
                cp      12h
                jr      nz,rg_bad
                in      a,(ITCTRL)
                or      a
                jr      nz,rg_bad
                in      a,(ITCMD)
                or      a
                jr      nz,rg_bad
                xor     a
                jr      rg_rep
rg_bad:         or      1
rg_rep:         call    check

                ret

t_per:
; 6b. periodic 10 ms, polled: ten periods
                ld      hl,msg_it_per
                call    puts
                ld      hl,10
                call    itsetms
                ld      a,ITC_RUN+ITC_AUTO
                out     (ITCTRL),a
                call    itwaitack               ; first expiry: reference
                jp      z,to_fail
                ld      hl,usa
                call    usstamp
                ld      a,10
                ld      (itn),a
per_l:
                call    itwaitack
                jp      z,to_fail
                ld      hl,usb
                call    usstamp
                ld      hl,itn
                dec     (hl)
                jr      nz,per_l
                ld      hl,klo_100ms
                call    elapsed_check
                call    itquiet

                ret

t_one:
; 6c. one-shot 20 ms
                ld      hl,msg_it_one
                call    puts
                ld      hl,20
                call    itsetms
                ld      hl,usa
                call    usstamp
                ld      a,ITC_RUN
                out     (ITCTRL),a
                ld      a,ITS_EXP
                ld      hl,100
                call    waitst
                jp      z,to_fail
                ld      hl,usb
                call    usstamp
                in      a,(ITCTRL)
                and     ITS_EXP+ITS_OVF+ITS_RUN ; expired, not running, no overflow
                ld      (itst),a
                ld      hl,klo_20ms
                call    elapsed_check
                ld      hl,msg_it_one2
                call    puts
                ld      a,ITS_OVF               ; no second expiry in 40 ms
                ld      hl,40
                call    waitst
                jr      nz,one_bad              ; overflow appeared
                in      a,(ITCTRL)
                and     ITS_EXP+ITS_OVF+ITS_RUN
                cp      ITS_EXP
                jr      nz,one_bad
                ld      a,(itst)
                cp      ITS_EXP
                jr      nz,one_bad
                xor     a
                jr      one_rep
one_bad:        or      1
one_rep:        call    check
                call    itquiet

                ret

t_16:
; 6d. 16-bit interval: $0101 = 257 ms, one-shot
                ld      hl,msg_it_16
                call    puts
                ld      hl,0101h
                call    itsetms
                ld      hl,usa
                call    usstamp
                ld      a,ITC_RUN
                out     (ITCTRL),a
                ld      a,ITS_EXP
                ld      hl,500
                call    waitst
                jp      z,to_fail
                ld      hl,usb
                call    usstamp
                ld      hl,klo_257ms
                call    elapsed_check
                call    itquiet

                ret

t_rst:
; 6e. RESET restarts the interval: 20 ms after RESET, not 10 ms
                ld      hl,msg_it_rst
                call    puts
                ld      hl,20
                call    itsetms
                ld      a,ITC_RUN
                out     (ITCTRL),a
                ld      hl,10
                call    delayms
                ld      hl,usa
                call    usstamp
                ld      a,ITK_RST
                out     (ITCMD),a
                ld      a,ITS_EXP
                ld      hl,100
                call    waitst
                jp      z,to_fail
                ld      hl,usb
                call    usstamp
                ld      hl,klo_20ms
                call    elapsed_check
                call    itquiet

                ret

t_stop:
; 6f. RUN=0 stops the count: no expiry after 2 ms start + 20 ms
                ld      hl,msg_it_stop
                call    puts
                ld      hl,5
                call    itsetms
                ld      a,ITC_RUN+ITC_AUTO
                out     (ITCTRL),a
                ld      hl,2
                call    delayms
                xor     a                       ; RUN = 0
                out     (ITCTRL),a
                ld      hl,20
                call    delayms
                in      a,(ITCTRL)
                and     ITS_EXP+ITS_RUN
                call    check
                call    itquiet

                ret

t_ovf:
; 6g. EXPIRED + OVERFLOW from a 1 ms timer nobody acknowledges
                ld      hl,msg_it_ovf
                call    puts
                ld      hl,1
                call    itsetms
                ld      a,ITC_RUN+ITC_AUTO
                out     (ITCTRL),a
                ld      hl,5
                call    delayms
                xor     a                       ; stop; EXPIRED/OVERFLOW stay
                out     (ITCTRL),a
                in      a,(ITCTRL)
                and     ITS_EXP+ITS_OVF
                cp      ITS_EXP+ITS_OVF
                jr      nz,ov_bad
                ld      a,ITK_OVF               ; CLROVF alone
                out     (ITCMD),a
                in      a,(ITCTRL)
                and     ITS_EXP+ITS_OVF
                cp      ITS_EXP
                jr      nz,ov_bad
                ld      a,ITK_ACK               ; ACK clears the rest
                out     (ITCMD),a
                in      a,(ITCTRL)
                and     ITS_EXP+ITS_OVF+ITS_REQ
                jr      nz,ov_bad
                xor     a
                jr      ov_rep
ov_bad:         or      1
ov_rep:         call    check
                call    itquiet

                ret

t_im0:
; 6h. interrupts
                xor     a
                ld      (isrcnt),a
                ld      (spurious),a
; interrupt mode 0 (current mode): one interrupt after 10 ms
                ld      hl,msg_it_im0
                call    puts
                ld      hl,10
                call    itsetms
                ld      hl,usa
                call    usstamp
                ld      a,ITC_RUN+ITC_AUTO+ITC_IE
                out     (ITCTRL),a
                ei
                ld      a,1
                ld      hl,100
                call    waitisr
                di
                jp      z,to_fail
                ld      hl,usb
                call    usstamp
                call    itquiet
                ld      hl,klo_10ms
                call    elapsed_check
                ret

t_im1:
; interrupt mode 1, periodic: ten interrupts = 100 ms
                im      1
                xor     a
                ld      (isrcnt),a
                ld      hl,msg_it_im1
                call    puts
                ld      hl,usa
                call    usstamp
                ld      a,ITC_RUN+ITC_AUTO+ITC_IE
                out     (ITCTRL),a
                ei
                ld      a,10
                ld      hl,300
                call    waitisr
                di
                jp      z,to_fail
                ld      hl,usb
                call    usstamp
                call    itquiet
                ld      hl,klo_100ms
                call    elapsed_check
                ld      hl,msg_it_isr
                call    puts
                ld      a,(laststat)
                call    puthex
                ld      hl,msg_spur
                call    puts
                ld      a,(spurious)
                call    puthex
                ld      a,' '
                call    putc
                ld      a,(laststat)
                cp      3Dh                     ; EXPIRED RUNNING INTREQ IE AUTO
                jr      nz,isr_bad
                ld      a,(spurious)
                or      a
                jr      nz,isr_bad
                xor     a
                jr      isr_rep
isr_bad:        or      1
isr_rep:        call    check
                ret

t_ie:
; IE = 0 holds INT off; setting IE interrupts at once (level)
                ld      hl,msg_it_ie
                call    puts
                xor     a
                ld      (isrcnt),a
                ld      hl,1
                call    itsetms
                ld      a,ITC_RUN+ITC_AUTO      ; IE = 0
                out     (ITCTRL),a
                ei
                ld      hl,5
                call    delayms
                di
                ld      a,(isrcnt)
                or      a
                jr      nz,ie_bad               ; interrupted with IE = 0
                in      a,(ITCTRL)
                and     ITS_EXP+ITS_REQ
                cp      ITS_EXP                 ; expired, INTREQ clear
                jr      nz,ie_bad
                ld      a,ITC_RUN+ITC_AUTO+ITC_IE
                out     (ITCTRL),a
                ei
                ld      a,1
                ld      hl,5
                call    waitisr
                di
                jr      z,ie_bad
                xor     a
                jr      ie_rep
ie_bad:         or      1
ie_rep:         call    check
                call    itquiet
                ret

t_halt:
; wake from HALT (skipped if interrupts have already failed: it would hang)
                ld      hl,msg_it_halt
                call    puts
                ld      a,(nbad)
                ld      hl,nbad0
                cp      (hl)
                jr      nz,halt_skip
                xor     a
                ld      (isrcnt),a
                ld      hl,10
                call    itsetms
                ld      hl,usa
                call    usstamp
                ld      a,ITC_RUN+ITC_IE        ; one-shot
                out     (ITCTRL),a
                ei
                halt
                di
                ld      hl,usb
                call    usstamp
                call    itquiet
                ld      hl,klo_10ms
                call    elapsed_check
                jr      halt_done
halt_skip:      ld      hl,msg_skip
                call    puts
                call    crlf
halt_done:
                ret

; ---- IntervalTimer helpers -------------------------------------------------
; itquiet: stop the timer (IE, AUTO cleared) and clear EXPIRED and OVERFLOW.
itquiet:
                xor     a
                out     (ITCTRL),a
                ld      a,ITK_ACK+ITK_OVF
                out     (ITCMD),a
                ret

; itsetms: INTERVAL = HL milliseconds.
itsetms:
                ld      a,l
                out     (ITIVLLO),a
                ld      a,h
                out     (ITIVLHI),a
                ret

; ms16: HL = low 16 bits of the BenchTimer ms counter (channel 1, latched).
ms16:
                out     (TMS1),a
                in      a,(TMS1)
                ld      l,a
                in      a,(TMS1+1)
                ld      h,a
                ret

; waitst: wait up to HL ms for (STATUS and A) /= 0. NZ = found, Z = timed out.
; Polls with interrupts as the caller left them. Clobbers A, DE, HL.
waitst:
                ld      (wmask),a
                ld      (wlimit),hl
                call    ms16
                ld      (wstart),hl
ws_l:
                in      a,(ITCTRL)
                ld      hl,wmask
                and     (hl)
                ret     nz
                call    ms16
                ld      de,(wstart)
                or      a
                sbc     hl,de                   ; elapsed ms
                ld      de,(wlimit)
                or      a
                sbc     hl,de
                jr      c,ws_l                  ; elapsed < limit
                xor     a                       ; Z
                ret

; delayms: wait HL ms (a waitst on a status bit that never sets).
delayms:
                ld      a,80h
                jr      waitst

; itwaitack: wait up to 100 ms for EXPIRED, then ACK it. NZ = found.
itwaitack:
                ld      a,ITS_EXP
                ld      hl,100
                call    waitst
                ret     z
                ld      a,ITK_ACK
                out     (ITCMD),a
                or      1                       ; NZ
                ret

; waitisr: wait up to HL ms for isrcnt >= A (interrupts enabled by the caller).
; NZ = reached, Z = timed out. Clobbers A, B, DE, HL.
waitisr:
                ld      (wcount),a
                ld      (wlimit),hl
                call    ms16
                ld      (wstart),hl
wi_l:
                ld      a,(wcount)
                ld      b,a
                ld      a,(isrcnt)
                cp      b
                jr      c,wi_not
                or      1                       ; NZ
                ret
wi_not:
                call    ms16
                ld      de,(wstart)
                or      a
                sbc     hl,de
                ld      de,(wlimit)
                or      a
                sbc     hl,de
                jr      c,wi_l
                xor     a                       ; Z
                ret

; usstamp: latch BenchTimer channel 3 (us) into (HL).
usstamp:
                ld      c,TUS1
                jp      snap32

; elapsed_check: print usb - usa in us and check it lies in [lo, lo + 2*TOL],
; (HL) = 32-bit lo. Prints the verdict line.
elapsed_check:
                push    hl
                ld      hl,usb
                ld      de,usa
                call    sub32                   ; res = usb - usa
                ld      hl,res
                call    putdec32
                ld      hl,msg_us
                call    puts
                pop     de                      ; DE = lo
                ld      hl,res
                call    sub32                   ; res = elapsed - lo (in place)
                ld      a,(res+3)
                ld      b,a
                ld      a,(res+2)
                or      b
                jr      nz,ec_bad
                ld      hl,(res)
                ld      de,2*TOL+1
                or      a
                sbc     hl,de
                jr      nc,ec_bad
                xor     a
                jr      check
ec_bad:         or      1
                ; falls through

; check: Z = PASS, else FAIL (counted in nbad); ends the line.
check:
                jr      z,ck_pass
                ld      hl,nbad
                inc     (hl)
                ld      hl,msg_fail
                jr      ck_out
ck_pass:        ld      hl,msg_pass
ck_out:         call    puts
                jp      crlf

; to_fail: a wait timed out. Count a failure, leave the timer quiet and return
; to the caller of the test (the test was entered with call; the stack is clean).
to_fail:
                ld      hl,msg_to
                call    puts
                or      1
                call    check
                jp      itquiet

; puthex: print A as two hex digits.
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

; ---- console (output to BOTH the video terminal and the serial port) -------
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
msg_it:         db      0Dh,0Ah,'IntervalTimer test (ports D0h-D3h)',0Dh,0Ah,0
msg_it_reg:     db      'Registers, status clear: ',0
msg_it_per:     db      'Periodic 10 ms x 10, polled: ',0
msg_it_one:     db      'One-shot 20 ms: ',0
msg_it_one2:    db      'One-shot stays stopped, no overflow: ',0
msg_it_16:      db      '16-bit interval 257 ms: ',0
msg_it_rst:     db      'RESET restarts: 20 ms after RESET: ',0
msg_it_stop:    db      'RUN=0 stops, no expiry: ',0
msg_it_ovf:     db      'EXPIRED+OVERFLOW, CLROVF, ACK: ',0
msg_it_im0:     db      'IM 0, 1 interrupt at 10 ms: ',0
msg_it_im1:     db      'IM 1, 10 interrupts at 10 ms: ',0
msg_it_isr:     db      'ISR status=',0
msg_spur:       db      ' spurious=',0
msg_it_ie:      db      'IE=0 holds INT off, IE=1 interrupts: ',0
msg_it_halt:    db      'IM 1, wake from HALT at 10 ms: ',0
msg_skip:       db      'SKIPPED (interrupts failed)',0
msg_it_sum:     db      'IntervalTimer: ',0
msg_allpass:    db      'all PASS',0
msg_nfail:      db      ' FAILED',0
msg_to:         db      'TIMEOUT ',0
msg_pass:       db      'PASS',0
msg_fail:       db      'FAIL',0

; IntervalTimer lower bounds (expected - TOL, us), 32-bit little-endian
klo_10ms:       dw      02648h,0000h            ;   9800
klo_20ms:       dw      04D58h,0000h            ;  19800
klo_100ms:      dw      085D8h,0001h            ;  99800
klo_257ms:      dw      0EB20h,0003h            ; 256800

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
nbad:           ds      1
nbad0:          ds      1
isrcnt:         ds      1
spurious:       ds      1
laststat:       ds      1
itn:            ds      1
itst:           ds      1
wmask:          ds      1
wcount:         ds      1
wlimit:         ds      2
wstart:         ds      2

                end

; ============================================================================
; sdramstress.asm - SDRAM correctness soak + speed comparison (hardware)
; ----------------------------------------------------------------------------
; PURPOSE
;   Hardware version of sim/sdram_stress.asm. Since REQUIREMENTS.md item 4.1
;   the SDRAM client FSM starts opcode fetches / memory reads speculatively
;   in T1 and posts writes (the CPU does not wait for them). This program
;   hammers exactly the access orderings that logic has to get right, with
;   the code, the stack and the data all in SDRAM, and keeps doing so until
;   a key is pressed, so rare faults (refresh collisions, clock-phase
;   drift between clk_sys and clk_ram) get a chance to show up.
;
;   Each pass runs the same test image twice, at the same logical address
;   (frame 1, 4000h-7FFFh):
;     - once with frame 1 mapped to BLOCK RAM page 8193 (reference run),
;     - once with frame 1 mapped to SDRAM page TESTPAGE,
;   REPS times each, timed with the benchmark timer's microsecond channel,
;   and prints one line per pass:
;     pass N  blk T us  sdram T us  errors: blk E  sdram E
;   The SDRAM time should be within about 1% of the block-RAM time; any
;   error is a fault (an error in the block-RAM run means a bug in the test
;   itself). The first failure is reported with its test number, run type
;   and the value compared.
;
; TESTS (in the image; all data in frame 1, stack at 7F00h in frame 1)
;   1  write each pattern byte, read it back at once (256 bytes)
;   2  PUSH x3 / POP x3 bursts (back-to-back writes, then reads), 16 times
;   3  recursive CALL/RET 64 deep, then SP must be back at 7F00h
;   4  EX (SP),HL (read, read, write, write of the same two bytes)
;   5  RLD/RRD with pattern bytes (read then write of the same byte), and
;      RLD with known values
;   6  LDIR 256 bytes 5000h -> 5200h, compare with the pattern
;   7  OTIR 64 bytes to the MMU direct-access port (+12) at logical 6000h,
;      read them back with normal reads, INIR them back to 5300h, compare
;   0  (not in the image) the per-pass copy of the image into frame 1 is
;      read back and verified before it is run
;
;   Data patterns change every pass (PATBUF, built in block RAM): pass mod
;   4 = 0: i XOR pass, 1: AAh/55h alternating, 2: walking one, 3: walking
;   zero (each rotated by the pass number).
;
; USAGE
;   Load the .BIN via the OSD with Boot Load Target = Block RAM. Output on
;   the serial console (io2, 6850 ACIA at 82h/83h). Press any key to stop
;   after the current pass and print the totals.
;
; BUILD
;   make -C testing sdramstress.bin   (or tools/z80asm.sh testing/sdramstress.asm)
;
; SIMULATION
;   Assembled with -D SIM (sim/run_perf.sh does this) it runs in
;   sim/tb_sdram_perf.vhd: REPS = 1, no serial output, and after one pass
;   (block-RAM run + SDRAM run, pattern mode 0) it writes the low byte of
;   the total error count to 0900h and AAh to 0908h, which the testbench
;   checks (expected 00h); 0901h-0905h = block-RAM errors, SDRAM errors,
;   first failing test, its run (0 blk / 1 SDRAM), its A value.
; ============================================================================

                .z80
                aseg
                org     0000h

; ---- configuration ---------------------------------------------------------
TESTPAGE        equ     4               ; SDRAM physical 16 KB page under test
                                        ; (physical 010000h, as sdramexec)
BLKPAGE_LO      equ     01h             ; block RAM page 8193 = 2001h
BLKPAGE_HI      equ     20h             ;   (block RAM 4000h-7FFFh, unused)
                IFDEF   SIM
REPS            equ     1               ; GHDL run (see SIMULATION below)
                ELSE
REPS            equ     40              ; image runs per timed measurement
                ENDIF
WORK            equ     4000h           ; image runs here (frame 1)
RECDEPTH        equ     64              ; test 3 recursion depth
NPORT           equ     64              ; test 7 bytes through port +12

; ---- ports -------------------------------------------------------------------
SERSTAT         equ     082h
SERDATA         equ     083h
TDRE            equ     002h
RDRF            equ     001h
MAP1LO          equ     0B1h            ; frame-1 mapping, bits 7:0
MAP1HI          equ     0B5h            ; frame-1 mapping, bits 13:8
PTR0            equ     0B8h            ; direct-access pointer, LSB
PTR1            equ     0B9h
PTR2            equ     0BAh
PTR3            equ     0BBh            ; MSB
DDATA           equ     0BCh            ; direct-access data port
TUS             equ     0C8h            ; benchmark timer channel 2 (us)

; ---- block RAM scratch (frame 0; fixed addresses shared with the image) -----
STACK           equ     0F00h           ; main program stack (grows down)
CURT            equ     0F00h           ; current test number (set by image)
ERRPTR          equ     0F02h           ; -> 32-bit error counter of this run
OLDSP           equ     0F04h           ; main SP saved by the image
PTRVAL          equ     0F06h           ; 4 bytes: phys address of logical 6000h
FIRST           equ     0F0Ah           ; 0 until the first failure is reported
FTEST           equ     0F0Bh           ; first failure: test number
FVAL            equ     0F0Ch           ; first failure: value in A
FRUN            equ     0F0Dh           ; first failure: 0 = blk, 1 = sdram
RUNTYPE         equ     0F0Eh           ; 0 = blk, 1 = sdram
PASSN           equ     0F10h           ; 32-bit pass counter
ERRB            equ     0F14h           ; 32-bit error total, block-RAM runs
ERRS            equ     0F18h           ; 32-bit error total, SDRAM runs
TSTART          equ     0F1Ch           ; 4 bytes
TEND            equ     0F20h           ; 4 bytes
RES             equ     0F24h           ; 4 bytes (sub32 result)
NUM             equ     0F28h           ; 4 bytes (putdec32 scratch)
PATBUF          equ     1000h           ; 256-byte pattern, page aligned

; ============================================================================
start:
                di
                ld      sp,STACK
                ld      a,003h                  ; ACIA master reset
                out     (SERSTAT),a
                ld      a,015h                  ; 8N1, /16
                out     (SERSTAT),a

                ld      hl,PASSN                ; clear counters/flags
                ld      b,ERRS+4-PASSN
cl_loop:        ld      (hl),0
                inc     hl
                djnz    cl_loop
                xor     a
                ld      (FIRST),a

                ld      hl,msg_banner
                call    puts

; ---- core check: does a write through the direct-access port reach block
; RAM? (Cores before the bram_wren fix silently dropped such writes, which
; makes test 7 fail in every block-RAM run.) Writes 5Ah then A5h through
; port +12 to physical 08003F00h (block RAM, logical 3F00h in frame 0) and
; reads them back with normal reads.
                ld      hl,msg_core
                call    puts
                ld      b,2
                ld      e,5Ah
cc_loop:        xor     a
                out     (PTR0),a
                out     (PTR2),a
                ld      a,3Fh
                out     (PTR1),a
                ld      a,08h
                out     (PTR3),a
                ld      a,e
                out     (DDATA),a
                ld      a,(3F00h)
                cp      e
                jr      nz,cc_bad
                ld      e,0A5h
                djnz    cc_loop
                ld      hl,msg_ok2
                jr      cc_out
cc_bad:         ld      hl,msg_ccbad
cc_out:         call    puts

; ---- one pass ---------------------------------------------------------------
pass:
                call    mkpat

                ; reference run: frame 1 -> block RAM page 8193
                xor     a
                ld      (RUNTYPE),a
                ld      hl,ERRB
                ld      (ERRPTR),hl
                ld      a,BLKPAGE_LO
                out     (MAP1LO),a
                ld      a,BLKPAGE_HI
                out     (MAP1HI),a
                ld      hl,ptr_blk
                call    timedrun
                ld      hl,msg_pass
                call    puts
                ld      hl,PASSN
                call    putdec32
                ld      hl,msg_blk
                call    puts
                ld      hl,RES
                call    putdec32

                ; run under test: frame 1 -> SDRAM page TESTPAGE
                ld      a,1
                ld      (RUNTYPE),a
                ld      hl,ERRS
                ld      (ERRPTR),hl
                ld      a,TESTPAGE
                out     (MAP1LO),a
                xor     a
                out     (MAP1HI),a
                ld      hl,ptr_sd
                call    timedrun
                ld      hl,msg_sd
                call    puts
                ld      hl,RES
                call    putdec32

                ld      hl,msg_errs
                call    puts
                ld      hl,ERRB
                call    putdec32
                ld      hl,msg_errs2
                call    puts
                ld      hl,ERRS
                call    putdec32
                call    crlf

                ld      a,(FIRST)               ; first failure, reported once
                cp      1
                call    z,firstrep

                ld      hl,PASSN
                call    inc32

                IFDEF   SIM
                ld      a,(PASSN)               ; one pass, then report
                cp      1
                jp      nz,pass
                ld      a,(ERRB)
                ld      hl,ERRS
                or      (hl)
                ld      (0900h),a
                ld      a,(ERRB)                ; details, printed by the
                ld      (0901h),a               ; testbench
                ld      a,(ERRS)
                ld      (0902h),a
                ld      a,(FTEST)
                ld      (0903h),a
                ld      a,(FRUN)
                ld      (0904h),a
                ld      a,(FVAL)
                ld      (0905h),a
                ld      a,0AAh
                ld      (0908h),a
sim_end:        jr      sim_end
                ENDIF

                in      a,(SERSTAT)             ; key pressed -> stop
                and     RDRF
                jp      z,pass
                in      a,(SERDATA)             ; discard the key

                ld      hl,msg_stop
                call    puts
                ld      hl,PASSN
                call    putdec32
                ld      hl,msg_stop2
                call    puts
                ld      hl,ERRS                 ; verdict on the SDRAM runs
                call    iszero32
                ld      hl,msg_ok
                jr      nz,v_bad
                ld      hl,ERRB
                call    iszero32
                ld      hl,msg_ok
                jr      z,v_out
                ld      hl,msg_tbug
                jr      v_out
v_bad:          ld      hl,msg_bad
v_out:          call    puts
halt_loop:      halt
                jr      halt_loop

; firstrep: print the first failure and mark it reported (FIRST = 2).
firstrep:
                ld      a,2
                ld      (FIRST),a
                ld      hl,msg_first
                call    puts
                ld      a,(FTEST)
                call    puthex
                ld      hl,msg_frun
                call    puts
                ld      hl,msg_rblk
                ld      a,(FRUN)
                or      a
                jr      z,fr_1
                ld      hl,msg_rsd
fr_1:           call    puts
                ld      hl,msg_fval
                call    puts
                ld      a,(FVAL)
                call    puthex
                jp      crlf

; timedrun: HL -> 4-byte direct-access pointer value for this run. Copies
; the image into frame 1, verifies the copy (test 0), then runs it REPS
; times; RES = elapsed microseconds.
timedrun:
                ld      de,PTRVAL
                ld      bc,4
                ldir
                ld      hl,image
                ld      de,WORK
                ld      bc,imglen
                ldir
                xor     a                       ; test 0: verify the copy
                ld      (CURT),a
                ld      hl,image
                ld      de,WORK
                ld      bc,imglen
tr_ver:         ld      a,(de)
                cp      (hl)
                call    nz,fail
                inc     hl
                inc     de
                dec     bc
                ld      a,b
                or      c
                jr      nz,tr_ver
                ld      hl,TSTART
                ld      c,TUS
                call    snap32
                ld      b,REPS
tr_run:         push    bc
                call    WORK
                pop     bc
                djnz    tr_run
                ld      hl,TEND
                ld      c,TUS
                call    snap32
                ld      hl,TEND
                ld      de,TSTART
                jp      sub32

; mkpat: fill PATBUF[0..255] for this pass (see header). Clobbers all.
mkpat:
                ld      a,(PASSN)
                ld      e,a                     ; E = pass number (low byte)
                and     3
                ld      d,a                     ; D = pattern mode
                ld      hl,PATBUF
mp_l:           ld      a,d
                or      a
                jr      z,mp_xor
                dec     a
                jr      z,mp_alt
                call    mp_bit                  ; modes 2/3: walking one/zero
                bit     0,d
                jr      z,mp_put
                cpl
                jr      mp_put
mp_xor:         ld      a,l                     ; mode 0: i XOR pass
                xor     e
                jr      mp_put
mp_alt:         ld      a,0AAh                  ; mode 1: AAh/55h
                bit     0,l
                jr      z,mp_put
                cpl
mp_put:         ld      (hl),a
                inc     l
                jr      nz,mp_l
                ret
; mp_bit: A = 1 << ((L + E) mod 8). Clobbers B.
mp_bit:         ld      a,l
                add     a,e
                and     7
                ld      b,a
                inc     b
                ld      a,80h
mpb_l:          rlca
                djnz    mpb_l
                ret

; fail: count an error for the current run; remember the first one.
; Preserves all registers (the flags are not needed by the callers).
fail:
                push    af
                push    hl
                ld      hl,(ERRPTR)
                call    inc32
                ld      hl,FIRST
                ld      a,(hl)
                or      a
                jr      nz,f_out
                ld      (hl),1
                ld      a,(CURT)
                ld      (FTEST),a
                ld      a,(RUNTYPE)
                ld      (FRUN),a
                pop     hl
                pop     af
                ld      (FVAL),a
                ret
f_out:          pop     hl
                pop     af
                ret

; direct-access pointer values for logical 6000h in each run
ptr_blk:        defb    00h,60h,00h,08h         ; block RAM 08006000h
ptr_sd:         defb    00h,20h,01h,00h         ; SDRAM TESTPAGE*4000h+2000h

; ============================================================================
; Test image: copied to WORK (frame 1) and run from there. Absolute
; references to itself are assembled for WORK; it reaches block RAM only
; through the fixed scratch addresses and the fail routine (frame 0).
; ============================================================================
; The image is assembled at its load address in the .BIN but runs at WORK.
; um80 accepts .PHASE/.DEPHASE but IGNORES them, so every absolute
; reference from the image to itself is written label+IM (IM = WORK -
; image) to point into the copy at WORK; relative jumps need nothing.
IM              equ     WORK-image
image:
test:           ld      (OLDSP),sp
                ld      sp,7F00h

; 1. write each pattern byte, read it back at once
                ld      a,1
                ld      (CURT),a
                ld      hl,5000h
                ld      de,PATBUF
                ld      b,0
t1:             ld      a,(de)
                ld      (hl),a
                ld      c,(hl)
                cp      c
                call    nz,fail
                inc     hl
                inc     e
                djnz    t1

; 2. back-to-back pushes and pops
                ld      a,2
                ld      (CURT),a
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
                call    nz,fail
                ld      a,c
                cp      0BCh
                call    nz,fail
                ld      a,d
                cp      56h
                call    nz,fail
                ld      a,e
                cp      78h
                call    nz,fail
                ld      a,h
                cp      12h
                call    nz,fail
                ld      a,l
                cp      34h
                call    nz,fail
                pop     bc
                djnz    t2

; 3. recursion, then SP must be back at 7F00h
                ld      a,3
                ld      (CURT),a
                ld      a,RECDEPTH
                call    rec+IM
                ld      hl,0
                add     hl,sp
                ld      a,h
                cp      7Fh
                call    nz,fail
                ld      a,l
                or      a
                call    nz,fail

; 4. EX (SP),HL
                ld      a,4
                ld      (CURT),a
                ld      hl,(PATBUF)
                push    hl
                ld      hl,(PATBUF+2)
                ex      (sp),hl
                pop     de
                ld      bc,(PATBUF)
                ld      a,h
                cp      b
                call    nz,fail
                ld      a,l
                cp      c
                call    nz,fail
                ld      bc,(PATBUF+2)
                ld      a,d
                cp      b
                call    nz,fail
                ld      a,e
                cp      c
                call    nz,fail

; 5. RLD/RRD round trip with pattern bytes, and RLD with known values
                ld      a,5
                ld      (CURT),a
                ld      hl,5100h
                ld      de,PATBUF
                ld      b,0
t5:             ld      a,(de)
                ld      (hl),a
                inc     e
                ld      a,(de)
                ld      c,a                     ; C = original A
                rld
                rrd
                cp      c
                call    nz,fail
                dec     e
                ld      a,(de)
                cp      (hl)
                call    nz,fail
                inc     e
                djnz    t5
                ld      (hl),34h
                ld      a,12h
                rld
                cp      13h
                call    nz,fail
                ld      a,(hl)
                cp      42h
                call    nz,fail

; 6. LDIR 5000h -> 5200h, compare with the pattern
                ld      a,6
                ld      (CURT),a
                ld      hl,5000h
                ld      de,5200h
                ld      bc,256
                ldir
                ld      hl,PATBUF
                ld      de,5200h
                ld      b,0
t6:             ld      a,(de)
                cp      (hl)
                call    nz,fail
                inc     l
                inc     de
                djnz    t6

; 7. OTIR through the direct-access port to logical 6000h, read back
;    normally, INIR back to 5300h, compare
                ld      a,7
                ld      (CURT),a
                call    ptrset+IM
                ld      hl,5000h
                ld      bc,NPORT*256+DDATA
                otir
                ld      hl,PATBUF
                ld      de,6000h
                ld      b,NPORT
t7:             ld      a,(de)
                cp      (hl)
                call    nz,fail
                inc     l
                inc     de
                djnz    t7
                call    ptrset+IM
                ld      hl,5300h
                ld      bc,NPORT*256+DDATA
                inir
                ld      hl,PATBUF
                ld      de,5300h
                ld      b,NPORT
t8:             ld      a,(de)
                cp      (hl)
                call    nz,fail
                inc     l
                inc     de
                djnz    t8

                ld      sp,(OLDSP)
                ret

ptrset:         ld      hl,PTRVAL
                ld      a,(hl)
                out     (PTR0),a
                inc     hl
                ld      a,(hl)
                out     (PTR1),a
                inc     hl
                ld      a,(hl)
                out     (PTR2),a
                inc     hl
                ld      a,(hl)
                out     (PTR3),a
                ret

rec:            dec     a
                call    nz,rec+IM
                ret
imglen          equ     $-image

; ============================================================================
; 32-bit helpers (little-endian)
; ============================================================================
; snap32: latch timer channel whose first port is C, read it into (HL).
snap32:
                out     (c),a
                ld      b,4
s32r:           in      a,(c)
                ld      (hl),a
                inc     hl
                inc     c
                djnz    s32r
                ret

; sub32: RES = (HL) - (DE)
sub32:
                ld      ix,RES
                ld      b,4
                or      a
sb_l:           ld      a,(hl)
                ex      de,hl
                sbc     a,(hl)
                ex      de,hl
                ld      (ix+0),a
                inc     hl
                inc     de
                inc     ix
                djnz    sb_l
                ret

; inc32: (HL) += 1. Preserves HL.
inc32:
                push    hl
                inc     (hl)
                jr      nz,i32_x
                inc     hl
                inc     (hl)
                jr      nz,i32_x
                inc     hl
                inc     (hl)
                jr      nz,i32_x
                inc     hl
                inc     (hl)
i32_x:          pop     hl
                ret

; iszero32: Z set if (HL) == 0
iszero32:
                ld      a,(hl)
                inc     hl
                or      (hl)
                inc     hl
                or      (hl)
                inc     hl
                or      (hl)
                ret

; putdec32: print the 32-bit unsigned value at (HL) in decimal.
putdec32:
                ld      de,NUM
                ld      bc,4
                ldir
                ld      c,0
pd_loop:        call    div10
                add     a,'0'
                push    af
                inc     c
                ld      hl,NUM
                call    iszero32
                jr      nz,pd_loop
pd_out:         pop     af
                call    putc
                dec     c
                jr      nz,pd_out
                ret

; div10: NUM /= 10, A = remainder. Clobbers B, HL.
div10:
                xor     a
                ld      b,32
d10_l:          ld      hl,NUM
                sla     (hl)
                inc     hl
                rl      (hl)
                inc     hl
                rl      (hl)
                inc     hl
                rl      (hl)
                rla
                cp      10
                jr      c,d10_n
                sub     10
                ld      hl,NUM
                inc     (hl)
d10_n:          djnz    d10_l
                ret

; ============================================================================
; serial
; ============================================================================
putc:
                IFDEF   SIM
                ret                             ; no serial output in GHDL
                ENDIF
                push    af
pc_wait:        in      a,(SERSTAT)
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

puthex:
                push    af
                rrca
                rrca
                rrca
                rrca
                call    phn
                pop     af
phn:            and     0Fh
                add     a,090h
                daa
                adc     a,040h
                daa
                jp      putc

; ============================================================================
; messages
; ============================================================================
msg_banner:     defb    0Dh,0Ah
                defm    'MultiComp SDRAM stress test (speculative reads, posted writes)'
                defb    0Dh,0Ah
                defm    'Code, stack and data in frame 1: block RAM page 8193 vs SDRAM page 4.'
                defb    0Dh,0Ah
                defm    'Times are us for 40 runs of the test image. Any key stops.'
                defb    0Dh,0Ah,0
msg_pass:       defm    'pass '
                defb    0
msg_blk:        defm    '  blk '
                defb    0
msg_sd:         defm    ' us  sdram '
                defb    0
msg_errs:       defm    ' us  errors: blk '
                defb    0
msg_errs2:      defm    ' sdram '
                defb    0
msg_first:      defm    '*** FIRST FAILURE: test '
                defb    0
msg_frun:       defm    ', '
                defb    0
msg_rblk:       defm    'block RAM run'
                defb    0
msg_rsd:        defm    'SDRAM run'
                defb    0
msg_fval:       defm    ', A='
                defb    0
msg_stop:       defb    0Dh,0Ah
                defm    'Stopped after '
                defb    0
msg_stop2:      defm    ' passes. '
                defb    0
msg_ok:         defm    'RESULT: PASS (no errors)'
                defb    0Dh,0Ah,0
msg_bad:        defm    'RESULT: FAIL (SDRAM errors)'
                defb    0Dh,0Ah,0
msg_tbug:       defm    'RESULT: errors in the block-RAM reference run (test bug?)'
                defb    0Dh,0Ah,0
msg_core:       defm    'Core check, port +12 write to block RAM: '
                defb    0
msg_ok2:        defm    'OK'
                defb    0Dh,0Ah,0
msg_ccbad:      defm    'BROKEN - core predates the bram_wren fix;'
                defb    0Dh,0Ah
                defm    '  expect test 7 errors in every block-RAM run.'
                defb    0Dh,0Ah,0

                end

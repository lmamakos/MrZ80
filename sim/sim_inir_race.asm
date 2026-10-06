; ============================================================================
; sim_inir_race.asm - ModelSim/GHDL testbench payload.
;
; Sweeps a variable-length NOP preamble (D = 0..ITER_COUNT-1) before each of
; ITER_COUNT outer iterations, each of which:
;   1. resets the direct-access pointer to physical address 0,
;   2. executes exactly one INIR reading NBYTES from the direct-access data
;      port (0xBC) into a scratch buffer,
;   3. verifies buf[i] == i (the testbench's fake SDRAM model returns
;      (byte address) mod 256 for any read, so the first NBYTES bytes
;      starting at address 0 are simply 0,1,2,...NBYTES-1),
;   4. on the FIRST mismatch, records which delay value (D), which byte
;      offset, and what got/expected values caused it,
;   5. always increments a running 16-bit mismatch counter (so a
;      non-first-only, aggregate view is available too, mirroring
;      testing/backtoback.asm's mmcnt_* infrastructure).
;
; The testbench (sim/tb_inir_race.vhd) monitors writes to the fixed
; addresses below in real time (via a VHDL external-name probe on the
; block RAM's write bus) rather than needing any serial/UART decoding.
;
; This is deliberately NOT using golden_fetch/report_fail/etc. from
; testing/backtoback.asm -- it's a minimal, purpose-built reproduction of
; the isolated Phase A2/A3 scenario (direct-access port INIR read,
; immediately following pointer-register writes, into a block-RAM
; destination), with a swept delay preamble standing in for "whatever
; variable-timing code happened to run before entering the INIR loop" on
; real hardware.
;
; BUILD: pasmo --bin sim/sim_inir_race.asm sim/sim_inir_race.bin
; ============================================================================

                org     0000h
 .z80

DDATA           equ     0BCh
PTR0            equ     0B8h
PTR1            equ     0B9h
PTR2            equ     0BAh
PTR3            equ     0BBh

ITER_COUNT      equ     200             ; number of outer (delay-swept) iterations
NBYTES          equ     8               ; bytes read per INIR

; ---- fixed result addresses (monitored live by the testbench) ------------
MISCNT_LO       equ     0900h           ; running mismatch count, low byte
MISCNT_HI       equ     0901h           ; running mismatch count, high byte
FAIL_RECORDED   equ     0902h           ; 0 until first mismatch recorded, then 1
FAIL_DELAY      equ     0903h           ; D value (preamble length) at first mismatch
FAIL_OFFSET     equ     0904h           ; byte offset within the INIR burst
FAIL_EXP        equ     0905h           ; expected byte at first mismatch
FAIL_GOT        equ     0906h           ; got byte at first mismatch
ITERS_DONE      equ     0907h           ; outer-loop iterations completed so far
DONE_FLAG       equ     0908h           ; 0 until test completes, then 0AAh
TMP_EXP         equ     0909h           ; scratch: expected byte of current mismatch
TMP_GOT         equ     090Ah           ; scratch: got byte of current mismatch

BUF             equ     1000h           ; INIR destination scratch buffer
STACK           equ     0A00h

; ============================================================================
start:
                di
                ld      sp,STACK

                xor     a
                ld      (MISCNT_LO),a
                ld      (MISCNT_HI),a
                ld      (FAIL_RECORDED),a
                ld      (ITERS_DONE),a
                ld      (DONE_FLAG),a

                ld      d,0                     ; D = swept preamble delay length
outer_loop:
                 ; ---- variable-length NOP preamble ----
                ld      a,d
                or      a
                jr      z,skip_delay
                ld      c,a
delay_loop:
                nop
                dec     c
                jr      nz,delay_loop
skip_delay:

                 ; ---- reset direct-access pointer to physical address 0 ----
                xor     a
                out     (PTR0),a
                out     (PTR1),a
                out     (PTR2),a
                out     (PTR3),a

                 ; ---- one INIR burst: NBYTES from the direct-access port ----
                ld      hl,BUF
                ld      c,DDATA
                ld      b,NBYTES
                inir

                 ; ---- verify buf[i] == i for i in 0..NBYTES-1 ----
                ld      hl,BUF
                ld      b,NBYTES
                xor     a                       ; A = expected byte (== offset)
verify_loop:
                cp      (hl)
                jr      z,verify_ok
                 ; mismatch: got=(hl), expected=A, offset=(NBYTES-B).
                 ; NOTE: stash expected/got to scratch memory BEFORE any
                 ; conditional branch, and keep every push/pop pair fully
                 ; balanced before branching -- this is the same class of
                 ; stack-imbalance bug found and fixed in
                 ; testing/backtoback.asm's report_fail (a push left
                 ; unpopped across a conditional jump).
                push    af                      ; save expected(A)/flags
                push    hl                      ; save HL (points at buf[i])
                 ; bump 16-bit mismatch counter
                ld      hl,MISCNT_LO
                inc     (hl)
                jr      nz,cnt_done
                inc     hl
                inc     (hl)
cnt_done:
                pop     hl                      ; restore HL
                pop     af                      ; restore expected(A); flags don't matter now
                ld      (TMP_EXP),a
                ld      a,(hl)
                ld      (TMP_GOT),a
                ld      a,(FAIL_RECORDED)
                or      a
                jr      nz,mismatch_done        ; already recorded one; nothing pushed, safe to jump
                ld      a,1
                ld      (FAIL_RECORDED),a
                ld      a,d
                ld      (FAIL_DELAY),a
                ld      a,NBYTES
                sub     b
                ld      (FAIL_OFFSET),a         ; offset = NBYTES - remaining B
                ld      a,(TMP_EXP)
                ld      (FAIL_EXP),a
                ld      a,(TMP_GOT)
                ld      (FAIL_GOT),a
mismatch_done:
                 ; both paths above clobbered A; restore it to the current
                 ; expected byte before falling into verify_ok's `inc a`.
                ld      a,(TMP_EXP)
verify_ok:
                inc     hl
                inc     a
                djnz    verify_loop

                 ; ---- advance outer loop ----
                ld      hl,ITERS_DONE
                inc     (hl)
                inc     d
                ld      a,d
                cp      ITER_COUNT
                jr      nz,outer_loop

                 ; ---- done ----
                ld      a,0AAh
                ld      (DONE_FLAG),a
halt_loop:
                halt
                jr      halt_loop

                end

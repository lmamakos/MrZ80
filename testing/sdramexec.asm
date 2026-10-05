; ============================================================================
; sdramexec.asm  -  SDRAM *execution* test for the MultiComp Z-80 CP/M core
; ----------------------------------------------------------------------------
; PURPOSE
;   Block-RAM boot works; SDRAM boot fails; yet the SDRAM *memory* tests
;   (sdramtest.asm) pass. The difference the memory tests do NOT cover is
;   INSTRUCTION FETCH (M1 opcode reads) from SDRAM: sdramtest only ever does
;   data LD (HL),A / LD A,(HL) into a paged window while the code keeps
;   running from block RAM. A boot image, by contrast, must FETCH AND EXECUTE
;   instructions out of SDRAM.
;
;   This program isolates exactly that. It runs from block RAM (loaded via the
;   OSD with "Boot Load Target = Block RAM", the known-good path), then:
;
;     1. Maps SDRAM physical page 4 (physical 0x010000) into frame 1
;        (logical 0x4000..0x7FFF) via the MMU mapping register.
;     2. Copies a small self-contained subroutine into 0x4000 using ordinary
;        CPU writes (the proven data path).
;     3. Reads the copy back and verifies it byte-for-byte (data-path sanity:
;        confirms the bytes actually landed in SDRAM before we try to run it).
;     4. CALLs 0x4000 to EXECUTE the routine straight out of SDRAM. The
;        routine computes a known result (and walks a few instructions /
;        branches / a loop) so a correct return value proves real instruction
;        fetch from SDRAM, not just a lucky single byte.
;     5. Repeats the execute step several times to catch non-deterministic /
;        intermittent fetch failures (the hallmark of the boot bug).
;
;   Each stage prints PASS/FAIL over the serial console. If the copy+verify
;   passes but the EXECUTE step fails (or is flaky), the fault is specifically
;   in the SDRAM instruction-fetch / wait-state path -- the same path a boot
;   image depends on and the prime suspect for the boot failure.
;
; MMU MAPPING
;   Frame 1 = logical 0x4000..0x7FFF (addr(15:14)="01"). To map physical 16 KB
;   page N into frame 1:
;       OUT (0xB1), N_low      ; low byte  (clears reg first, sets page 7:0)
;       OUT (0xB5), N_high     ; high byte (page bits 13:8)
;   Frame 1 is used (not frame 3) so that the test's own stack/scratch in
;   frame 0 and code in frames 0..2 are untouched; only 0x4000.. is remapped.
;
; SERIAL CONSOLE (6850-compatible ACIA, "io2")
;       0x82 = status(read)/control(write); bit1 (0x02) = TX ready (TDRE)
;       0x83 = data
;
; BUILD
;   pasmo --bin testing/sdramexec.asm testing/sdramexec.bin
;   (load the flat .BIN via OSD with Boot Load Target = Block RAM)
; ============================================================================

	.z80
                org     0000h

; ---- configuration ---------------------------------------------------------
TESTPAGE        equ     4               ; SDRAM physical 16 KB page to use
                                        ; (page 4 = physical 0x010000, first
                                        ;  SDRAM page above the block-RAM page)
EXEC_BASE       equ     4000h           ; frame-1 window (logical), where the
                                        ; copied routine runs from in SDRAM
EXEC_RUNS       equ     16              ; how many times to re-run the routine
                                        ; (catches intermittent fetch faults)

; Expected result the SDRAM routine returns in A. The routine sums a short
; table and adds a constant; EXPECT must match what srctn computes.
EXPECT          equ     0C3h

; ---- serial / MMU ports ----------------------------------------------------
SERSTAT         equ     082h
SERDATA         equ     083h
TDRE            equ     002h

MAP1LO          equ     0B1h            ; frame-1 map reg low byte (page 7:0)
MAP1HI          equ     0B5h            ; frame-1 map reg high byte (page 13:8)

STACK           equ     0A00h

; ============================================================================
start:
                di
                ld      sp,STACK

                ; --- init ACIA: master reset then 8N1, /16 clock ---
                ld      a,003h
                out     (SERSTAT),a
                ld      a,015h
                out     (SERSTAT),a

                ld      hl,msg_banner
                call    puts

                ; --- initialise the sum table the SDRAM routine reads ---
                ; (scratch RAM is not part of the .BIN image, so fill it now)
                ld      hl,srctn_tab
                ld      (hl),011h
                inc     hl
                ld      (hl),022h
                inc     hl
                ld      (hl),033h
                inc     hl
                ld      (hl),044h
                inc     hl
                ld      (hl),055h

                ; =====================================================
                ; Step 1: map SDRAM page TESTPAGE into frame 1 (0x4000)
                ; =====================================================
                ld      hl,msg_map
                call    puts
                ld      a,TESTPAGE
                out     (MAP1LO),a              ; low byte (clears reg first)
                xor     a
                out     (MAP1HI),a              ; high byte = 0 (page < 256)
                call    okln

                ; =====================================================
                ; Step 2: copy the routine into the SDRAM window
                ; =====================================================
                ld      hl,msg_copy
                call    puts
                ld      hl,srctn_start          ; source (in block RAM)
                ld      de,EXEC_BASE            ; dest (SDRAM via frame 1)
                ld      bc,srctn_len
                ldir
                call    okln

                ; =====================================================
                ; Step 3: read the copy back and verify it (data path)
                ; =====================================================
                ld      hl,msg_verify
                call    puts
                ld      hl,srctn_start
                ld      de,EXEC_BASE
                ld      bc,srctn_len
cv_loop:
                ld      a,(de)                  ; byte from SDRAM
                cp      (hl)                    ; compare to block-RAM source
                jr      nz,cv_fail
                inc     hl
                inc     de
                dec     bc
                ld      a,b
                or      c
                jr      nz,cv_loop
                call    okln
                jr      do_exec
cv_fail:
                ; report first mismatch: DE=SDRAM addr, (HL)=exp, (DE)=got
                push    de
                ld      hl,msg_cvfail
                call    puts
                pop     hl                      ; HL = failing SDRAM addr
                call    puthex16
                call    crlf
                ld      hl,msg_abort
                call    puts
                jr      halt_loop

                ; =====================================================
                ; Step 4/5: EXECUTE from SDRAM, EXEC_RUNS times
                ; =====================================================
do_exec:
                ld      hl,msg_exec
                call    puts

                ld      b,EXEC_RUNS             ; run count
                xor     a
                ld      (execerr),a             ; clear error flag
ex_loop:
                push    bc
                call    EXEC_BASE               ; <-- fetch+execute from SDRAM
                ; A = routine result; compare to EXPECT
                cp      EXPECT
                jr      z,ex_ok
                ; mismatch on this run: print "got=GG " and flag error
                push    af
                ld      hl,msg_got
                call    puts
                pop     af
                call    puthex
                ld      a,' '
                call    putc
                ld      a,1
                ld      (execerr),a
                jr      ex_next
ex_ok:
                ld      a,'.'                   ; progress dot per good run
                call    putc
ex_next:
                pop     bc
                djnz    ex_loop
                call    crlf

                ; ---- final verdict ----
                ld      a,(execerr)
                or      a
                jr      nz,exec_bad
                ld      hl,msg_execok
                call    puts
                jr      halt_loop
exec_bad:
                ld      hl,msg_execbad
                call    puts
halt_loop:
                halt
                jr      halt_loop

; ============================================================================
; srctn - the test subroutine that gets copied into SDRAM and EXECUTED from
;         there.
;
;   POSITION INDEPENDENCE
;     The Z-80 has no PC-relative CALL, so the simplest way to make this
;     routine run correctly from the SDRAM window (without two-address-org
;     trickery) is to give it NO absolute self-references. The only data it
;     needs -- the 5-byte sum table -- lives at a FIXED block-RAM address
;     (srctn_tab, in scratch) that is identical whether the routine runs from
;     block RAM or SDRAM. The code body therefore contains only register ops,
;     an immediate-loaded pointer to that fixed table, a DJNZ loop, and a RET,
;     all of which are inherently relocatable.
;
;   It returns a known value in A:
;       A = (sum of bytes at srctn_tab) + 0xC4
;   sum(11+22+33+44+55) = 0xFF; 0xFF + 0xC4 = 0x1C3 -> A = 0xC3 = EXPECT.
;
;   srctn_start/srctn_len (its location/length in block RAM) are used by the
;   LDIR copy into SDRAM.
; ============================================================================
srctn_start:
srctn:
                ld      hl,srctn_tab            ; FIXED block-RAM table addr
                ld      b,5
                xor     a                       ; A = running sum = 0
sr_sum:
                add     a,(hl)                  ; (reads table from block RAM)
                inc     hl
                djnz    sr_sum                  ; loop branch (fetched from SDRAM)
                ; A = 0xFF (sum of table)
                add     a,0C4h                  ; + constant -> 0x1C3 -> A=0xC3
                ret
srctn_end:
srctn_len       equ     srctn_end - srctn_start

; ============================================================================
; Serial output helpers
; ============================================================================
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
                call    putc
                ret

; okln - print " OK" + CRLF
okln:
                ld      hl,msg_ok
                call    puts
                ret

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

puthex16:
                ld      a,h
                call    puthex
                ld      a,l
                call    puthex
                ret

; ============================================================================
; Messages
; ============================================================================
msg_banner:     defb    0Dh,0Ah
                defm    "MultiComp SDRAM EXECUTE test"
                defb    0Dh,0Ah
                defm    "(runs a routine fetched from SDRAM page 4 @0x4000)"
                defb    0Dh,0Ah,0
msg_map:        defm    "map page4 -> frame1 (0x4000) ..."
                defb    0
msg_copy:       defm    "copy routine to SDRAM ..."
                defb    0
msg_verify:     defm    "verify copy (data path) ..."
                defb    0
msg_cvfail:     defb    0Dh,0Ah
                defm    "  COPY VERIFY FAIL @"
                defb    0
msg_exec:       defb    0Dh,0Ah
                defm    "EXECUTE from SDRAM: "
                defb    0
msg_got:        defm    "got="
                defb    0
msg_ok:         defm    " OK"
                defb    0Dh,0Ah,0
msg_abort:      defm    "ABORTED (data path bad; fix that first)"
                defb    0Dh,0Ah,0
msg_execok:     defm    "RESULT: SDRAM EXECUTION PASSED"
                defb    0Dh,0Ah,0
msg_execbad:    defm    "RESULT: SDRAM EXECUTION FAILED (fetch path)"
                defb    0Dh,0Ah,0

; ============================================================================
; RAM scratch (block RAM)
; ============================================================================
                org     0700h
execerr:        defs    1               ; nonzero if any execute run mismatched
srctn_tab:      defs    5               ; 5-byte sum table, filled at runtime
                                        ; (lives in block RAM at a FIXED addr so
                                        ;  the SDRAM-resident routine can reach
                                        ;  it with the same absolute pointer)

                end

; ============================================================================
; sdramret.asm  -  SDRAM refresh / data-retention test (device 0)
; ----------------------------------------------------------------------------
; PURPOSE
;   Detects the refresh-starvation defect described in SDRAM-review-handoff.md
;   section 7.1: with the original sdram2.sv, if the CPU touches SDRAM
;   device 0 at least once between consecutive refreshes (~8 us apart), every
;   AUTO_REFRESH goes to device 1 and device 0 is NEVER refreshed. Only rows
;   that the program itself happens to activate keep their contents.
;
;   Run from block RAM (Boot Load Target = Block RAM). Each round:
;     1. FILL   SDRAM pages FIRSTPG..FIRSTPG+NPG-1 (device 0, 256 KB) with an
;               address-derived pattern (polarity alternates per round).
;     2. HAMMER read one SDRAM byte (page HAMPG, outside the test region) in
;               a tight loop for D "blocks" of 65536 reads (~0.3 s/block).
;               One access every ~4 us keeps device 0 "busy" between every
;               pair of refreshes -- the starvation trigger -- while never
;               activating (and so never self-refreshing) the test rows.
;     3. VERIFY the test region; print the error count and the first few
;               failures (page, offset, expected, got, and a re-read).
;   D increases per round: 0, 4, 32, 256, 1024 blocks (~0 s, 1 s, 9 s,
;   70 s, 280 s). A '.' is printed every 16 blocks while hammering.
;
;   Expected: with refresh starvation, errors appear (and grow) once D
;   exceeds the cells' room-temperature retention time (typically seconds).
;   With working refresh: errors=0000 in every round.
;
; SERIAL CONSOLE (6850-compatible ACIA)  0x82 status/control, 0x83 data
; BUILD: make -C testing sdramret.bin   (or tools/z80asm.sh)
; ============================================================================

	.z80
                org     0000h

SERSTAT         equ     082h
SERDATA         equ     083h
TDRE            equ     002h

MAP1LO          equ     0B1h            ; frame-1 map reg low byte
MAP1HI          equ     0B5h            ; frame-1 map reg high byte
MAP2LO          equ     0B2h            ; frame-2 map reg low byte
MAP2HI          equ     0B6h            ; frame-2 map reg high byte

FIRSTPG         equ     8               ; first SDRAM 16 KB page under test
NPG             equ     16              ; pages under test (256 KB, device 0)
HAMPG           equ     2               ; page hammered (not under test)
WIN1            equ     4000h           ; frame 1: test pages
WIN2            equ     8000h           ; frame 2: hammer page
MAXSHOW         equ     6               ; failures printed per round

STACK           equ     3F00h           ; frame 0 = block RAM

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

                ld      a,HAMPG                 ; frame 2 -> hammer page
                out     (MAP2LO),a
                xor     a
                out     (MAP2HI),a

                xor     a
                ld      (round),a
round_loop:
                ; ---- D = rounds[round] (16-bit), done when table ends ----
                ld      a,(round)
                add     a,a
                ld      e,a
                ld      d,0
                ld      hl,rounds
                add     hl,de
                ld      e,(hl)
                inc     hl
                ld      d,(hl)
                ld      a,d
                and     e
                inc     a                       ; 0FFFFh terminator?
                jp      z,all_done
                ld      (dblocks),de

                ; ---- mask alternates 00 / FF ----
                ld      a,(round)
                rrca
                sbc     a,a                     ; A = 00 (even) / FF (odd)
                ld      (mask),a

                call    crlf
                ld      hl,msg_d
                call    puts
                ld      hl,(dblocks)
                call    puthex16
                ld      hl,msg_mask
                call    puts
                ld      a,(mask)
                call    puthex

                ld      hl,msg_fill
                call    puts
                call    fill
                ld      hl,msg_ham
                call    puts
                call    hammer
                ld      hl,msg_ver
                call    puts
                ld      hl,0
                ld      (errcnt),hl
                call    verify
                ld      hl,msg_err
                call    puts
                ld      hl,(errcnt)
                call    puthex16

                ld      hl,round
                inc     (hl)
                jp      round_loop

all_done:
                call    crlf
                ld      hl,msg_done
                call    puts
halt_loop:
                halt
                jr      halt_loop

; ----------------------------------------------------------------------------
; mappg: map page (curpg) into frame 1; D = curpg xor mask (pattern seed)
; ----------------------------------------------------------------------------
mappg:
                ld      a,(curpg)
                out     (MAP1LO),a              ; low byte (clears high)
                ld      d,a
                xor     a
                out     (MAP1HI),a
                ld      a,(mask)
                xor     d
                ld      d,a
                ret

; ----------------------------------------------------------------------------
; fill: pattern byte at offset HL of page p = L xor H xor p xor mask
; ----------------------------------------------------------------------------
fill:
                ld      a,FIRSTPG
                ld      (curpg),a
fl_page:
                call    mappg
                ld      hl,WIN1
fl_loop:
                ld      a,l
                xor     h
                xor     d
                ld      (hl),a
                inc     hl
                ld      a,h
                cp      high (WIN1+4000h)
                jr      nz,fl_loop
                ld      a,(curpg)
                inc     a
                ld      (curpg),a
                cp      FIRSTPG+NPG
                jr      nz,fl_page
                ret

; ----------------------------------------------------------------------------
; verify: compare the region against the pattern, count/print mismatches
; ----------------------------------------------------------------------------
verify:
                ld      a,FIRSTPG
                ld      (curpg),a
vf_page:
                call    mappg
                ld      hl,WIN1
vf_loop:
                ld      a,l
                xor     h
                xor     d
                cp      (hl)
                call    nz,vfail
                inc     hl
                ld      a,h
                cp      high (WIN1+4000h)
                jr      nz,vf_loop
                ld      a,(curpg)
                inc     a
                ld      (curpg),a
                cp      FIRSTPG+NPG
                jr      nz,vf_page
                ret

; vfail: A = expected byte, HL = failing logical address. Preserves all.
vfail:
                push    af
                push    bc
                push    de
                push    hl
                ld      c,a                     ; C = expected
                ld      b,(hl)                  ; B = got
                ld      de,(errcnt)
                inc     de
                ld      a,d
                or      e
                jr      nz,vf_nosat
                dec     de                      ; saturate at FFFF
vf_nosat:
                ld      (errcnt),de
                ld      a,d
                or      a
                jr      nz,vf_ret
                ld      a,e
                cp      MAXSHOW+1
                jr      nc,vf_ret
                push    hl
                ld      hl,msg_vf
                call    puts
                ld      a,(curpg)
                call    puthex
                ld      a,':'
                call    putc
                pop     hl
                push    hl
                ld      a,h
                sub     high WIN1               ; offset within page
                call    puthex
                ld      a,l
                call    puthex
                ld      hl,msg_exp
                call    puts
                ld      a,c
                call    puthex
                ld      hl,msg_got
                call    puts
                ld      a,b
                call    puthex
                ld      hl,msg_re
                call    puts
                pop     hl
                ld      a,(hl)                  ; re-read: stored vs read error
                call    puthex
vf_ret:
                pop     hl
                pop     de
                pop     bc
                pop     af
                ret

; ----------------------------------------------------------------------------
; hammer: (dblocks) x 65536 reads of WIN2; '.' every 16 blocks
; ----------------------------------------------------------------------------
hammer:
                ld      de,(dblocks)
                ld      a,d
                or      e
                ret     z
hm_block:
                ld      bc,0
hm_loop:
                ld      a,(WIN2)                ; device-0 access, ~every 4 us
                dec     bc
                ld      a,b
                or      c
                jr      nz,hm_loop
                ld      a,e
                and     0Fh
                jr      nz,hm_nodot
                ld      a,'.'
                call    putc
hm_nodot:
                dec     de
                ld      a,d
                or      e
                jr      nz,hm_block
                ret

; ============================================================================
; Serial output helpers (preserve BC, DE, HL)
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
                jp      putc

puthex:
                push    af
                rrca
                rrca
                rrca
                rrca
                call    puthexnib
                pop     af
puthexnib:
                and     00Fh
                add     a,090h
                daa
                adc     a,040h
                daa
                jp      putc

puthex16:
                ld      a,h
                call    puthex
                ld      a,l
                jp      puthex

; ============================================================================
rounds:         defw    0, 4, 32, 256, 1024, 0FFFFh

msg_banner:     defb    0Dh,0Ah
                defm    "MultiComp SDRAM retention test: dev0 pages 08-17, hammer page 02"
                defb    0
msg_d:          defm    "D="
                defb    0
msg_mask:       defm    " mask="
                defb    0
msg_fill:       defm    " fill"
                defb    0
msg_ham:        defm    " hammer"
                defb    0
msg_ver:        defm    " verify"
                defb    0
msg_err:        defm    " errors="
                defb    0
msg_vf:         defb    0Dh,0Ah
                defm    "  fail "
                defb    0
msg_exp:        defm    " exp="
                defb    0
msg_got:        defm    " got="
                defb    0
msg_re:         defm    " re="
                defb    0
msg_done:       defm    "DONE"
                defb    0Dh,0Ah,0

round:          defb    0
mask:           defb    0
curpg:          defb    0
dblocks:        defw    0
errcnt:         defw    0

                end

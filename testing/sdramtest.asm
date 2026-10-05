; ============================================================================
; sdramtest.asm  -  SDRAM memory test for the MultiComp Z-80 CP/M FPGA core
; ----------------------------------------------------------------------------
; PURPOSE
;   Hardware testing showed that a .BIN boot image runs reliably when loaded
;   into the on-chip BLOCK RAM (OSD "Boot Load Target = Block RAM"), but does
;   NOT run when loaded into SDRAM. The block-RAM result proves the OSD
;   download / boot / CPU machinery is sound, so the fault is in the SDRAM
;   data path. This program is a standalone diagnostic: assemble it to a flat
;   .BIN, load it via the OSD into BLOCK RAM (the known-good path), and it
;   exercises the SDRAM two ways and reports results over the serial console.
;
;   PHASE 1 - direct-access port:
;     Touches a small SDRAM region through the MMU direct-access data port
;     (0xBC). This is the simplest possible SDRAM access and confirms the raw
;     read/write path. (This phase already PASSES on hardware.)
;
;   PHASE 2 - MMU-paged sweep (the realistic path software actually uses):
;     Maps each 16 KB physical SDRAM page, in turn, into the unused top 16 KB
;     of the Z-80's logical space (frame 3, logical 0xC000..0xFFFF) using the
;     MMU mapping registers, then tests that page with NORMAL CPU memory
;     accesses (LD (HL),A / LD A,(HL)) - exactly how CP/M / RomWBW reaches
;     paged memory. It sweeps every 16 KB SDRAM page above the block-RAM
;     overlap (physical pages PAGE_FIRST..PAGE_LAST), printing a running
;     per-page progress line and a running error tally.
;
; WHY TWO PATHS
;   The CPU only ever sees 64 KB of logical space; the low 64 KB of *physical*
;   memory is on-chip block RAM, NOT SDRAM. SDRAM lives at physical
;   0x010000..0x7FFFFFF (physical pages 4..8191 of 16 KB each). Phase 1 reaches
;   it via the direct-access port; Phase 2 reaches it via the normal MMU page
;   map. If Phase 1 passes but Phase 2 fails, the fault is specifically in the
;   paged-access path (frame map -> sdram_addr translation / read mux), not the
;   raw controller.
;
; MMU MAPPING (Phase 2)
;   Frame 3 = logical 0xC000..0xFFFF (addr(15:14)="11"). To map physical 16 KB
;   page N (13-bit page number) into frame 3:
;       OUT (0xB3), N_low      ; low byte - CLEARS the whole reg first, then
;                              ;            sets page bits 7:0
;       OUT (0xB7), N_high     ; high byte - sets page bits 12:8 (only 5 bits
;                              ;            exist since physical_page_bits=13)
;   Page N covers physical N*16384. SDRAM begins at page 4 (0x010000); the last
;   page is 8191 (top of the 27-bit / 128 MB space).
;
; DIRECT-ACCESS PORT (Phase 1)
;       0xB8..0xBB = 27-bit physical pointer, little-endian (lo byte first)
;       0xBC       = data port; IN/OUT performs a physical mem cycle at the
;                    pointer, then the pointer POST-INCREMENTS by 1.
;   The CPU is automatically wait-stated until each access completes.
;
; SERIAL CONSOLE (6850-compatible ACIA, "io2")
;       0x82 = status (read) / control (write); bit1 (0x02) = TX ready (TDRE)
;       0x83 = data (read = RX, write = TX)
;
; PHASE 1 REGION
;   Exhaustively tests a SMALL region: the first TEST_PAGES 256-byte pages
;   starting at the SDB0..SDB3 physical base (default 0x010000 = first SDRAM
;   byte above block RAM). Region size = TEST_PAGES * 256. Default 64 KB.
;
; TESTS (comprehensive pattern set, used by both phases)
;   1. Stuck-data fills: 0x00, 0xFF, 0xAA, 0x55 - stuck-at / shorted data bits.
;   2. Address-in-data: byte = (addr_lo XOR addr_mid) - address aliasing /
;      address-line faults.
;   3. Walking-ones: 01,02,04,...,80 repeating - data-bit shorts / swapped
;      lanes.
;
;   On the FIRST mismatch of a test the failing address, expected and actual
;   bytes are printed, then the test continues. Phase 1 prints a low-24-bit
;   PHYSICAL address; Phase 2 prints the LOGICAL window address (0xC000..) of
;   the failing byte plus the physical page being tested (shown in the
;   per-page progress line).
;
; BUILD
;   pasmo --bin testing/sdramtest.asm testing/sdramtest.bin
;   (load the resulting flat .BIN via OSD with Boot Load Target = Block RAM)
; ============================================================================

		.z80
                org     0000h

; ---- configuration ---------------------------------------------------------
; First SDRAM physical address to test (must be >= 0x010000 to be SDRAM, not
; block RAM). 27-bit value, little-endian bytes B0(lsb) B1 B2 B3.
SDB0            equ     000h            ; bits  7:0
SDB1            equ     000h            ; bits 15:8
SDB2            equ     001h            ; bits 23:16   -> base = 0x010000
SDB3            equ     000h            ; bits 31:24 (only 26:24 used)

TEST_PAGES      equ     256             ; number of 256-byte pages to test
                                        ; (256 => 64 KB region)

; ---- Phase 2 (MMU-paged sweep) configuration -------------------------------
; Inclusive range of 16 KB PHYSICAL page numbers to sweep. SDRAM starts at
; page 4 (physical 0x010000, first page above the 64 KB block-RAM overlap);
; the last page in the 128 MB / 27-bit space is 8191.
PAGE_FIRST      equ     4               ; first SDRAM 16 KB page (0x010000)
PAGE_LAST       equ     8191            ; last 16 KB page (top of 128 MB)

; Frame-3 logical window the pages are mapped into (top 16 KB of CPU space).
WIN_BASE        equ     0C000h          ; logical 0xC000..0xFFFF (16 KB)
WIN_SIZE        equ     4000h           ; 16384 bytes

; ---- serial / MMU ports ----------------------------------------------------
SERSTAT         equ     082h            ; ACIA status(read)/control(write)
SERDATA         equ     083h            ; ACIA data
TDRE            equ     002h            ; status bit1 = transmit ready

PTR0            equ     0B8h            ; direct-access pointer byte 7:0
PTR1            equ     0B9h            ; direct-access pointer byte 15:8
PTR2            equ     0BAh            ; direct-access pointer byte 23:16
PTR3            equ     0BBh            ; direct-access pointer byte 31:24
DDATA           equ     0BCh            ; direct-access data (auto-increment)

MAP3LO          equ     0B3h            ; frame-3 map reg low byte (page 7:0)
MAP3HI          equ     0B7h            ; frame-3 map reg high byte (page 12:8)

; ---- scratch / stack -------------------------------------------------------
; We run from block RAM, so RAM scratch is fine. Code + messages occupy only
; the first ~0x340 bytes; place the stack and scratch just above that so the
; emitted .BIN stays small.
STACK           equ     0A00h           ; stack grows down from here (above scratch)

; ============================================================================
start:
                di
                ld      sp,STACK

                ; --- init ACIA: master reset then 8N1, /16 clock ---
                ld      a,003h
                out     (SERSTAT),a     ; master reset
                ld      a,015h
                out     (SERSTAT),a     ; RTS low, 8N1, /16, no IRQ

                ld      hl,msg_banner
                call    puts

                xor     a
                ld      (failcount),a   ; Phase 1 failed-test count = 0

                ; =========================================================
                ; PHASE 1 - direct-access port (small region)
                ; =========================================================
                ld      hl,msg_p1
                call    puts

                ; ---------------------------------------------------------
                ; Test 1a..1d : stuck-data constant fills
                ; ---------------------------------------------------------
                ld      hl,msg_t1
                call    puts

                ld      a,000h
                call    fill_test
                ld      a,0FFh
                call    fill_test
                ld      a,0AAh
                call    fill_test
                ld      a,055h
                call    fill_test

                ; ---------------------------------------------------------
                ; Test 2 : address-in-data
                ; ---------------------------------------------------------
                ld      hl,msg_t2
                call    puts
                call    addr_test

                ; ---------------------------------------------------------
                ; Test 3 : walking-ones data pattern
                ; ---------------------------------------------------------
                ld      hl,msg_t3
                call    puts
                call    walk_test

                ; =========================================================
                ; PHASE 2 - MMU-paged sweep across all 16 KB SDRAM pages
                ; =========================================================
                call    paged_sweep

                ; ---------------------------------------------------------
                ; Final summary
                ; ---------------------------------------------------------
                ld      hl,msg_done
                call    puts

                ; Phase 1 result
                ld      hl,msg_p1res
                call    puts
                ld      a,(failcount)
                call    puthex
                call    crlf

                ; Phase 2 result (16-bit byte-error count)
                ld      hl,msg_p2res
                call    puts
                ld      hl,(perrcount)
                call    puthex16
                call    crlf

                ; Overall
                ld      a,(failcount)
                ld      b,a
                ld      hl,(perrcount)
                ld      a,h
                or      l
                or      b
                jr      nz,sum_fail
                ld      hl,msg_allok
                call    puts
                jr      halt_loop
sum_fail:
                ld      hl,msg_anyfail
                call    puts
halt_loop:
                halt
                jr      halt_loop

; ============================================================================
; fill_test - write constant in A to the whole region, then read back & verify
;   A = pattern byte
;   Prints "  fill XX " then OK / FAIL
; ============================================================================
fill_test:
                ld      (pattern),a

                ld      hl,msg_fill
                call    puts
                ld      a,(pattern)
                call    puthex
                ld      a,' '
                call    putc

                ; --- write phase ---
                call    set_ptr_base
                ; outer loop over pages, inner 256 bytes (b=0 => 256 via DJNZ)
                ld      d,TEST_PAGES
fw_page:
                ld      b,0                     ; 256 iterations (b=0 -> 256)
fw_byte:
                ld      a,(pattern)
                out     (DDATA),a               ; write + auto-increment ptr
                djnz    fw_byte
                dec     d
                jr      nz,fw_page

                ; --- read/verify phase ---
                call    set_ptr_base
                call    copy_ptr_to_work        ; shadow addr for fail reporting
                xor     a
                ld      (errflag),a
                ld      d,TEST_PAGES
fr_page:
                ld      b,0
fr_byte:
                in      a,(DDATA)               ; read + auto-increment ptr
                ld      e,a                     ; e = got
                ld      a,(pattern)
                cp      e
                jr      z,fr_next
                ; mismatch - report only the first one
                ld      a,(errflag)
                or      a
                jr      nz,fr_next              ; already reported one
                ld      a,1
                ld      (errflag),a
                ld      a,(pattern)             ; expected
                ld      c,e                     ; got (in c)
                call    report_fail_here
fr_next:
                call    inc_work
                djnz    fr_byte
                dec     d
                jr      nz,fr_page

                call    test_result
                ret

; ============================================================================
; addr_test - write addr-derived byte (lo XOR mid), read back & verify
; ============================================================================
addr_test:
                ; write phase - regenerate value from running pointer copy
                call    set_ptr_base
                call    copy_ptr_to_work        ; work = base phys addr (24-bit lo)
                ld      d,TEST_PAGES
aw_page:
                ld      b,0
aw_byte:
                call    val_for_work            ; A = value for current work addr
                out     (DDATA),a               ; write + hw ptr auto-increment
                call    inc_work                ; keep our shadow addr in step
                djnz    aw_byte
                dec     d
                jr      nz,aw_page

                ; read/verify phase
                call    set_ptr_base
                call    copy_ptr_to_work
                xor     a
                ld      (errflag),a
                ld      d,TEST_PAGES
ar_page:
                ld      b,0
ar_byte:
                in      a,(DDATA)               ; got
                ld      e,a
                call    val_for_work            ; A = expected
                cp      e
                jr      z,ar_next
                ld      a,(errflag)
                or      a
                jr      nz,ar_next
                ld      a,1
                ld      (errflag),a
                call    val_for_work            ; expected in A
                ld      c,e                     ; got in C
                call    report_fail_here
ar_next:
                call    inc_work
                djnz    ar_byte
                dec     d
                jr      nz,ar_page

                call    test_result
                ret

; ============================================================================
; walk_test - walking ones (01,02,04,08,10,20,40,80 repeating), verify
; ============================================================================
walk_test:
                ; write phase
                call    set_ptr_base
                ld      a,001h
                ld      (walkval),a
                ld      d,TEST_PAGES
ww_page:
                ld      b,0
ww_byte:
                ld      a,(walkval)
                out     (DDATA),a
                call    next_walk
                djnz    ww_byte
                dec     d
                jr      nz,ww_page

                ; read/verify phase
                call    set_ptr_base
                call    copy_ptr_to_work
                ld      a,001h
                ld      (walkval),a
                xor     a
                ld      (errflag),a
                ld      d,TEST_PAGES
wr_page:
                ld      b,0
wr_byte:
                in      a,(DDATA)
                ld      e,a                     ; got
                ld      a,(walkval)             ; expected
                cp      e
                jr      z,wr_next
                ld      a,(errflag)
                or      a
                jr      nz,wr_next
                ld      a,1
                ld      (errflag),a
                ld      a,(walkval)             ; expected
                ld      c,e                     ; got
                call    report_fail_here
wr_next:
                call    inc_work
                call    next_walk
                djnz    wr_byte
                dec     d
                jr      nz,wr_page

                call    test_result
                ret

; next_walk: rotate walkval left, 01->02->...->80->01
next_walk:
                ld      a,(walkval)
                rlca
                ld      (walkval),a
                ret

; ============================================================================
; val_for_work - compute the address-derived data byte for the shadow address
;   in (work0/work1/work2):  A = work0 XOR work1
; ============================================================================
val_for_work:
                ld      a,(work0)
                ld      hl,work1
                xor     (hl)
                ret

; ============================================================================
; Shadow physical-address counter (3 bytes is enough for our small region:
; base + up to 64 KB stays within 24 bits). work0=lsb.
; ============================================================================
copy_ptr_to_work:
                ld      a,SDB0
                ld      (work0),a
                ld      a,SDB1
                ld      (work1),a
                ld      a,SDB2
                ld      (work2),a
                ret

inc_work:
                ld      hl,work0
                inc     (hl)
                ret     nz
                inc     hl
                inc     (hl)
                ret     nz
                inc     hl
                inc     (hl)
                ret

; ============================================================================
; set_ptr_base - load the direct-access pointer with SDRAM_BASE (lo first)
; ============================================================================
set_ptr_base:
                ld      a,SDB0
                out     (PTR0),a
                ld      a,SDB1
                out     (PTR1),a
                ld      a,SDB2
                out     (PTR2),a
                ld      a,SDB3
                out     (PTR3),a
                ret

; ============================================================================
; test_result - print OK/FAIL based on errflag; bump failcount on fail
; ============================================================================
test_result:
                ld      a,(errflag)
                or      a
                jr      nz,tr_fail
                ld      hl,msg_ok
                call    puts
                ret
tr_fail:
                ld      hl,msg_fail
                call    puts
                ld      a,(failcount)
                inc     a
                ld      (failcount),a
                ret

; ============================================================================
; report_fail_here - print failing physical address + expected/got
;   A = expected byte, C = got byte
;   The failing physical address is taken from the shadow counter
;   (work2:work1:work0), which every read loop keeps in step with the HW
;   pointer (incremented AFTER the compare, so it still points at the
;   failing byte here).
;   Prints:  MISMATCH @XXXXXX exp=EE got=GG
; ============================================================================
report_fail_here:
                push    af                      ; save expected
                push    bc                      ; save got (in C)
                ld      hl,msg_mis              ; "  MISMATCH @"
                call    puts
                ld      a,(work2)               ; phys addr high
                call    puthex
                ld      a,(work1)
                call    puthex
                ld      a,(work0)               ; phys addr low
                call    puthex
                ld      hl,msg_exp              ; " exp="
                call    puts
                pop     bc
                pop     af                      ; expected
                push    bc
                call    puthex                  ; expected
                ld      hl,msg_got              ; " got="
                call    puts
                pop     bc
                ld      a,c
                call    puthex                  ; got
                call    crlf
                ret

; ============================================================================
; PHASE 2 - MMU-paged sweep
; ----------------------------------------------------------------------------
; For each physical 16 KB page N in [PAGE_FIRST..PAGE_LAST]:
;   - map N into frame 3 (logical 0xC000..0xFFFF)
;   - print a running progress line:  "page NNNN  errs=EEEE\r"  (CR only, so
;     the line is overwritten in place on a serial terminal)
;   - run the comprehensive pattern set on the 16 KB window using normal CPU
;     LD (HL) accesses
;   - add any byte errors to perrcount (16-bit running total)
; On completion a newline is emitted so the final progress line is kept.
;
; perrcount = total mismatched BYTES across the whole sweep (16-bit, saturates
; implicitly by wrap - but a healthy part shows 0000).
; ============================================================================
paged_sweep:
                ld      hl,msg_p2
                call    puts

                ; zero the running byte-error counter
                ld      hl,0
                ld      (perrcount),hl

                ; current physical page number (16-bit; only low 13 bits used)
                ld      hl,PAGE_FIRST
                ld      (curpage),hl

ps_loop:
                ; ---- map curpage into frame 3 ----
                ld      hl,(curpage)
                ld      a,l
                out     (MAP3LO),a              ; low byte (clears reg first)
                ld      a,h
                out     (MAP3HI),a              ; high byte (page bits 12:8)

                ; ---- progress line (CR, no LF, so it overwrites) ----
                call    print_progress

                ; ---- run the pattern set on the 16 KB window ----
                call    page_patterns           ; adds byte errors to perrcount

                ; ---- next page / done? ----
                ld      hl,(curpage)
                ld      de,PAGE_LAST
                ; if curpage == PAGE_LAST -> done after this iteration
                ld      a,h
                cp      d
                jr      nz,ps_more
                ld      a,l
                cp      e
                jr      z,ps_done
ps_more:
                ld      hl,(curpage)
                inc     hl
                ld      (curpage),hl
                jr      ps_loop
ps_done:
                ; print final progress line state then a newline to keep it
                call    print_progress
                call    crlf
                ret

; ----------------------------------------------------------------------------
; print_progress - "page NNNN  errs=EEEE\r"
; ----------------------------------------------------------------------------
print_progress:
                ld      hl,msg_page
                call    puts
                ld      hl,(curpage)
                call    puthex16
                ld      hl,msg_errs
                call    puts
                ld      hl,(perrcount)
                call    puthex16
                ld      a,0Dh                   ; CR only (overwrite line)
                call    putc
                ret

; ----------------------------------------------------------------------------
; page_patterns - comprehensive pattern set on the frame-3 window
;   (logical WIN_BASE..WIN_BASE+WIN_SIZE-1). Each mismatched byte increments
;   perrcount. On the first mismatch of THIS page it also prints a detail line
;   (preceded by CRLF so it doesn't get clobbered by the progress CR).
;   ppfirst = 0 at entry; set to 1 once a detail line has been printed.
; ----------------------------------------------------------------------------
page_patterns:
                xor     a
                ld      (ppfirst),a

                ; --- constant fills 00, FF, AA, 55 ---
                ld      a,000h
                call    pp_fill
                ld      a,0FFh
                call    pp_fill
                ld      a,0AAh
                call    pp_fill
                ld      a,055h
                call    pp_fill

                ; --- address-in-data (value = lowbyte XOR highbyte of the
                ;     logical window address) ---
                call    pp_addr

                ; --- walking ones ---
                call    pp_walk
                ret

; pp_fill - fill window with byte in A, verify
;   A = pattern
pp_fill:
                ld      (pattern),a
                ; write
                ld      hl,WIN_BASE
                ld      bc,WIN_SIZE
pf_w:
                ld      a,(pattern)
                ld      (hl),a
                inc     hl
                dec     bc
                ld      a,b
                or      c
                jr      nz,pf_w
                ; verify
                ld      hl,WIN_BASE
                ld      bc,WIN_SIZE
pf_r:
                ld      a,(pattern)
                cp      (hl)
                jr      z,pf_ok
                ; mismatch: expected=(pattern), got=(hl)
                push    bc
                ld      a,(hl)
                ld      c,a                     ; got
                ld      a,(pattern)             ; expected
                call    page_fail               ; HL=addr, A=exp, C=got
                pop     bc
pf_ok:
                inc     hl
                dec     bc
                ld      a,b
                or      c
                jr      nz,pf_r
                ret

; pp_addr - write/verify a value derived from BOTH the logical window address
;   (L XOR H) and the physical page number low byte. Mixing in the page byte
;   makes the expected value differ from page to page, so this also catches
;   page-to-page ALIASING (a page wrongly mapped to another page's storage
;   would read back the other page's value). DE holds the page-derived XOR
;   constant for the whole pass.
pp_addr:
                ld      a,(curpage)             ; page low byte
                ld      d,a                     ; D = per-page constant
                ; write
                ld      hl,WIN_BASE
                ld      bc,WIN_SIZE
pa_w:
                ld      a,l
                xor     h
                xor     d
                ld      (hl),a
                inc     hl
                dec     bc
                ld      a,b
                or      c
                jr      nz,pa_w
                ; verify
                ld      a,(curpage)
                ld      d,a
                ld      hl,WIN_BASE
                ld      bc,WIN_SIZE
pa_r:
                ld      a,l
                xor     h                       ; expected
                xor     d
                cp      (hl)
                jr      z,pa_ok
                push    bc
                push    af                      ; save expected
                ld      a,(hl)
                ld      c,a                     ; got
                pop     af                      ; expected
                call    page_fail
                pop     bc
pa_ok:
                inc     hl
                dec     bc
                ld      a,b
                or      c
                jr      nz,pa_r
                ret

; pp_walk - walking ones 01,02,...,80 repeating
pp_walk:
                ; write
                ld      a,001h
                ld      (walkval),a
                ld      hl,WIN_BASE
                ld      bc,WIN_SIZE
pw_w:
                ld      a,(walkval)
                ld      (hl),a
                rlca
                ld      (walkval),a
                inc     hl
                dec     bc
                ld      a,b
                or      c
                jr      nz,pw_w
                ; verify
                ld      a,001h
                ld      (walkval),a
                ld      hl,WIN_BASE
                ld      bc,WIN_SIZE
pw_r:
                ld      a,(walkval)             ; expected
                cp      (hl)
                jr      z,pw_ok
                push    bc
                ld      a,(hl)
                ld      c,a                     ; got
                ld      a,(walkval)             ; expected
                call    page_fail
                pop     bc
pw_ok:
                ld      a,(walkval)
                rlca
                ld      (walkval),a
                inc     hl
                dec     bc
                ld      a,b
                or      c
                jr      nz,pw_r
                ret

; ----------------------------------------------------------------------------
; page_fail - record + (first of page) report a paged mismatch
;   HL = logical address, A = expected, C = got
;   Increments perrcount (16-bit). On the FIRST failure of the current page it
;   prints "\r\n  PAGE pppp @LLLL exp=EE got=GG"; later failures on the same
;   page are counted but not printed (avoids a flood while still tallying).
;   Caller's HL/DE/BC/AF are preserved. Uses scratch vars to avoid stack
;   gymnastics: pf_addr (logical addr), pf_exp (expected), pf_got (got).
; ----------------------------------------------------------------------------
page_fail:
                ld      (pf_addr),hl            ; logical address
                ld      (pf_exp),a              ; expected
                ld      a,c
                ld      (pf_got),a              ; got
                push    hl
                push    de                      ; preserve caller's DE (pp_addr)
                push    bc
                push    af

                ; bump 16-bit running error counter
                ld      hl,(perrcount)
                inc     hl
                ld      (perrcount),hl

                ; only print one detail line per page
                ld      a,(ppfirst)
                or      a
                jr      nz,pgf_done
                ld      a,1
                ld      (ppfirst),a

                ld      hl,msg_pgfail           ; "\r\n  PAGE "
                call    puts
                ld      hl,(curpage)
                call    puthex16
                ld      hl,msg_at               ; " @"
                call    puts
                ld      hl,(pf_addr)
                call    puthex16                ; logical address
                ld      hl,msg_exp              ; " exp="
                call    puts
                ld      a,(pf_exp)
                call    puthex
                ld      hl,msg_got              ; " got="
                call    puts
                ld      a,(pf_got)
                call    puthex
pgf_done:
                pop     af
                pop     bc
                pop     de
                pop     hl
                ret

; ============================================================================
; Serial output helpers
; ============================================================================
; putc - send char in A
putc:
                push    af
pc_wait:
                in      a,(SERSTAT)
                and     TDRE
                jr      z,pc_wait
                pop     af
                out     (SERDATA),a
                ret

; puts - send NUL-terminated string at HL
puts:
                ld      a,(hl)
                or      a
                ret     z
                call    putc
                inc     hl
                jr      puts

; crlf
crlf:
                ld      a,0Dh
                call    putc
                ld      a,0Ah
                call    putc
                ret

; puthex - print A as two hex digits
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

; puthex16 - print HL as four hex digits (high byte first)
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
                defm    "MultiComp SDRAM memory test"
                defb    0Dh,0Ah
                defm    "region: small exhaustive (see SDB*/TEST_PAGES)"
                defb    0Dh,0Ah,0
msg_t1:         defb    0Dh,0Ah
                defm    "T1 stuck-data fills"
                defb    0Dh,0Ah,0
msg_t2:         defb    0Dh,0Ah
                defm    "T2 address-in-data"
                defb    0Dh,0Ah,0
msg_t3:         defb    0Dh,0Ah
                defm    "T3 walking-ones"
                defb    0Dh,0Ah,0
msg_fill:       defm    "  fill "
                defb    0
msg_ok:         defm    " OK"
                defb    0Dh,0Ah,0
msg_fail:       defm    " FAIL"
                defb    0Dh,0Ah,0
msg_mis:        defm    "  MISMATCH @"
                defb    0
msg_exp:        defm    " exp="
                defb    0
msg_got:        defm    " got="
                defb    0
msg_p1:         defb    0Dh,0Ah
                defm    "PHASE 1: direct-access port (small region)"
                defb    0Dh,0Ah,0
msg_p2:         defb    0Dh,0Ah
                defm    "PHASE 2: MMU-paged sweep of all 16K SDRAM pages"
                defb    0Dh,0Ah,0
msg_page:       defm    "page "
                defb    0
msg_errs:       defm    "  errs="
                defb    0
msg_pgfail:     defb    0Dh,0Ah
                defm    "  PAGE "
                defb    0
msg_at:         defm    " @"
                defb    0
msg_done:       defb    0Dh,0Ah
                defm    "---- test complete ----"
                defb    0Dh,0Ah,0
msg_p1res:      defm    "PHASE 1 failed tests = "
                defb    0
msg_p2res:      defm    "PHASE 2 byte errors  = "
                defb    0
msg_allok:      defm    "RESULT: ALL TESTS PASSED"
                defb    0Dh,0Ah,0
msg_anyfail:    defm    "RESULT: FAILURES DETECTED (see counts above)"
                defb    0Dh,0Ah,0

; ============================================================================
; RAM scratch (lives in block RAM; initialised at run time, not in the image)
; ============================================================================
                org     0700h
pattern:        defs    1
errflag:        defs    1
failcount:      defs    1       ; Phase 1 failed-test count (8-bit)
walkval:        defs    1
work0:          defs    1
work1:          defs    1
work2:          defs    1
; Phase 2 state
curpage:        defs    2       ; current physical 16K page number (16-bit)
perrcount:      defs    2       ; Phase 2 running byte-error count (16-bit)
ppfirst:        defs    1       ; 1 once a detail line printed for this page
pf_addr:        defs    2       ; failing logical address
pf_exp:         defs    1       ; expected byte
pf_got:         defs    1       ; got byte

                end

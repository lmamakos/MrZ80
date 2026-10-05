; ============================================================================
; backtoback.asm -  SDRAM *sustained / back-to-back* access test
; ----------------------------------------------------------------------------
; PURPOSE
;   The SDRAM array and the discrete (single-touch) read/write paths are
;   proven: sdramtest.asm passes.  But two sustained-access patterns FAIL on
;   real hardware:
;      (a) executing code out of SDRAM (M1 opcode fetch, back-to-back reads;
;          see sdramexec.asm - intermittent 0xC3->0xC4 off-by-one); and
;      (b) reading SDRAM back-to-back through the MMU direct-access port using
;          INIR (the reported symptom: "corrupted data").
;   Both are the same class of bug - TIGHTLY SPACED SDRAM accesses with no
;   intervening block-RAM cycles to give the request-level CDC (the 2-FF
;   level+edge synchroniser in MultiComp.sv) a "low" gap to re-arm.  This
;   test isolates and localizes the fault with four phases that each stress a
;   different sustained path and report the FIRST bad byte.
;
;   It runs from BLOCK RAM (load the .BIN via OSD with "Boot Load Target =
;   Block RAM", the known-good path), so all of its own code/scratch live in
;   block RAM and only the SDRAM region under test is in SDRAM.
;
; MMU / memory layout (physical_page_bits = 14, 256 MB / 16 KB pages)
;   Frame 0  logical 0x0000-0x3FFF = block RAM page 8192 (physical 0x8000000)
;             -> where THIS test's code + scratch + buffers live.
;   Frame 1  logical 0x4000-0x7FFF = SDRAM page TESTPAGE (physical
;             TESTPAGE*0x4000 = 0x010000 for TESTPAGE=4) -> the region
;             under test.   (Mapped at the start of the test.)
;   Direct-access pointer: 0xB8..0xBB (27-bit, little-endian) + data port
;   0xBC (read or write; pointer POST-increments after each access).
;
; PHASES  (REGION = 1024 bytes of ramp)
;   PHASE 0 (setup)  Build a golden ramp in a block-RAM buffer (GOLD), and
;                     fill the SDRAM region with the SAME ramp via the
;                     direct-access port (the proven write path).
;   PHASE A  direct-access SUSTAINED READ of the SDRAM region back-to-back
;            (IN (DDATA) in a tight loop, no intervening memory accesses).
;            -> tests the I/O-port SDRAM read path.
;   PHASE A2 direct-access SUSTAINED READ of the SDRAM region using INIR (a
;            Z-80 block-input instruction: IN (HL),(C); HL++; B--).
;            NOTE: on the T80 core, INIR's "repeat" is implemented by
;            rolling PC back 2 and re-fetching the ED-prefixed opcode from
;            program memory every iteration (T80.vhd, matching real Z-80
;            silicon so interrupts can be sampled mid-block) -- so when this
;            test runs from block RAM (as it does), INIR is NOT actually a
;            tighter/gap-free burst of SDRAM accesses than Phase A's
;            software loop at the SDRAM-CDC level; both see intervening
;            non-SDRAM (block-RAM) bus cycles between port reads. The real
;            structural difference from Phase A is that INIR's first read
;            follows set_ptr_base much SOONER (only 3 short instructions,
;            vs. Phase A's full CALL/RET to zero_idx first) -- useful for
;            probing whether the elapsed time since the last MMU
;            pointer-register write affects the reliability of the first
;            SDRAM access afterward.
;            -> tests the I/O-port SDRAM read path via a distinct
;               opcode/microcode path from Phase A's plain `in`, with a much
;               shorter settle time after set_ptr_base.
;   PHASE A3 DIAGNOSTIC: identical to Phase A2 (INIR), except a
;            `call zero_idx` is inserted before the first INIR so its
;            pre-read timing gap after set_ptr_base exactly matches Phase
;            A's.  If A3 passes while A2 fails, the fault is a settle-time/
;            async race tied to elapsed time since the last MMU
;            pointer-register write, not the INIR opcode itself.  If A3
;            ALSO fails the same way, the fault is specific to INIR's own
;            bus-cycle timing.  See phase_a3 for details.
;            RESULT (observed): A2 and A3 both fail identically (exactly 1
;            mismatch each, always offset 0000) -> settle-time theory
;            REFUTED; the fault is deterministic and tied to something
;            about INIR's own access, not merely elapsed time.
;   PHASE A4 DIAGNOSTIC: isolates whether A2/A3's fault is INIR's
;            block-repeat microcode (decrement B, write to (HL), PC-rollback
;            re-fetch) or simply the underlying BC-ADDRESSED "IN r,(C)" bus
;            cycle.  Structurally identical to Phase A (same timing gap)
;            but reads via a single plain `in a,(c)` instead of Phase A's
;            immediate-addressed `in a,(DDATA)`.  See phase_a4 for details.
;   PHASE B  LDIR  SDRAM (0x4000) -> block-RAM buffer (WORK), then verify the
;            buffer against the golden ramp.
;            -> tests the *native* (non-I/O) read path from SDRAM, exactly
;               what executing from SDRAM relies on for M1 fetch.
;   PHASE C  CPIR  sustained, READ-ONLY search for a de-duplicated sentinel
;            byte (0xFF) placed at the very last offset of the SDRAM region.
;            NOTE: CPI/CPIR compares the accumulator (A) against (HL) only --
;            it does NOT compare two memory regions and never reads DE (an
;            earlier version of this phase incorrectly tried a DE-vs-HL
;            "block compare" with `cpir`, which is not what the instruction
;            does; see the comment on phase_c below for the corrected design).
;            -> exercises CPIR's own microcode/timing (distinct from LDIR's
;               in the T80 core) against the SDRAM read path, read-only.
;   PHASE D  LDIR  golden (block RAM) -> SDRAM (0x4000) sustained WRITE, then
;            LDIR SDRAM -> buffer + verify.
;            -> tests sustained SDRAM WRITE (tWR / write-recovery).
;
; On the first mismatch of a phase the test prints:
;     "  FAIL @NNNN exp=XX got=YY"
;   where NNNN is the region-relative byte offset (0..1023) taken from a
;   per-phase 16-bit index, and then CONTINUES, so one run reveals every
;   phase that fails.  Phase C has its own single-shot report (see phase_c).
;
; INTERPRETING THE RESULT
;   - Phase A and/or A2 fail, B/D pass -> fault is the direct-access
;                                       (I/O-port) SDRAM read path
;                                       specifically.  If only ONE of A/A2
;                                       fails, the fault is specific to that
;                                       opcode's access pattern/timing
;                                       (`in` vs `inir`), not the I/O-port
;                                       path in general.  Use Phase A3 (INIR,
;                                       timing-matched to Phase A) to tell
;                                       apart "opcode-specific" from
;                                       "settle-time-after-set_ptr_base"
;                                       causes: A2 fails but A3 passes ->
;                                       settle-time/async race; A2 AND A3
;                                       both fail the same way -> something
;                                       about INIR's own bus cycle.
;   - Phase B or C fails            -> fault is the *native* SDRAM read path
;                                       (M1-fetch / execute, and CPIR's own
;                                       block-search microcode); matches the
;                                       stale-read-race / S_GAP hypothesis.
;   - Phase D fails                 -> sustained SDRAM *write* is the fault
;                                       (write-recovery / tWR, or the LDIR /
;                                       direct-access write path).
;   - Multiple phases fail          -> the shared request-level CDC
;                                       (level+edge synchroniser in
;                                       MultiComp.sv) is the common root cause;
;                                       see the analysis in HISTORY.md.
;
; SERIAL CONSOLE (6850-compatible ACIA, "io2")
;         0x82 = status (read) / control (write); bit1 (0x02) = TX ready (TDRE)
;         0x83 = data (read = RX, write = TX)
;
; BUILD
;   with Makefile
;     (load the flat .BIN via OSD with Boot Load Target = Block RAM)
; ============================================================================

                org     0000h
 .z80
; ---- configuration ---------------------------------------------------------
REGION          equ     1024            ; bytes in the SDRAM region under test
                                          ; (1024 = 0x0400; a 16-bit count)
REGION_HIGH     equ     4              ; high byte of REGION (stop test at hi==4)

TESTPAGE        equ     4              ; SDRAM physical 16 KB page for the
                                         ; region under test.  Page 4 = physical
                                         ; 0x00010000 (first SDRAM page that is
                                         ; comfortably above the relocated
                                         ; block-RAM page 8192 / 0x8000000).
                                          ; Physical base = TESTPAGE * 0x4000.

; Direct-access pointer bytes (27-bit, little-endian) for physical 0x00010000:
;   bits  7:0   = 0x00
;   bits 15:8   = 0x00
;   bits 23:16 = 0x01    (0x10000 sets bit 16)
;   bits 31:24 = 0x00
SDB0            equ     000h           ; bits   7:0
SDB1            equ     000h           ; bits  15:8
SDB2            equ     001h           ; bits  23:16 -> 0x00010000
SDB3            equ     000h           ; bits  31:24

; Logical windows
SDRAM_WIN       equ     4000h          ; frame 1 base (SDRAM region under test)
GOLD_BASE       equ     2000h          ; frame 0 / block RAM golden buffer
WORK_BASE       equ     2400h          ; frame 0 / block RAM LDIR destination

; Phase C (CPIR sentinel search): region-relative offset of the last byte.
LASTOFF         equ     REGION-1       ; = 1023 (0x3FF) for REGION=1024

; ---- serial / MMU ports ----------------------------------------------------
SERSTAT         equ     082h           ; ACIA status(read)/control(write)
SERDATA         equ     083h           ; ACIA data
TDRE            equ     002h           ; status bit1 = transmit ready

MAP1LO          equ     0B1h           ; frame-1 map reg low byte  (page 7:0)
MAP1HI          equ     0B5h           ; frame-1 map reg high byte (page 15:8)

PTR0            equ     0B8h           ; direct-access ptr bits   7:0
PTR1            equ     0B9h           ; direct-access ptr bits 15:8
PTR2            equ     0BAh           ; direct-access ptr bits 23:16
PTR3            equ     0BBh           ; direct-access ptr bits 31:24
DDATA           equ     0BCh           ; direct-access data (auto-increment)

; ---- scratch / stack -------------------------------------------------------
; Code + message strings occupy only the low ~0x0800 of block RAM; scratch sits
; just above it, well below the GOLD/WORK buffers at 0x2000.
SCRATCH         equ     0900h          ; small vars + per-phase indices
STACK           equ     0A00h          ; stack grows down from here

; ============================================================================
start:
                di
                ld      sp,STACK

                  ; --- init ACIA: master reset then 8N1, /16 clock ---
                ld      a,003h
                out      (SERSTAT),a
                ld      a,015h
                out      (SERSTAT),a

                ld      hl,msg_banner
                call    puts

                  ; ---------------------------------------------------------
                  ; PHASE 0 - SETUP
                ld      hl,pa0_hdr
                call    puts

                  ; 0a. map the SDRAM region (TESTPAGE) into frame 1 (0x4000)
                ld      a,TESTPAGE
                out      (MAP1LO),a                ; low byte (clears reg first)
                xor     a
                out      (MAP1HI),a                ; high byte = 0 (page < 256)

                  ; 0b. build the golden ramp in block RAM [GOLD_BASE..]:
                 ;     GOLD[i] = i (0,1,2,...,255,0,1,...; wraps every 256).
                 ; NOTE: this used to test the REGION countdown for zero with
                 ; the classic `ld a,b / or c` idiom, but that idiom
                 ; OVERWRITES A -- which is also the incrementing ramp value
                 ; -- so after the first byte the buffer stopped being a
                 ; real ramp at all (it degenerated into the OR of the
                 ; remaining-count bytes).  Since REGION is an exact multiple
                 ; of 256 (REGION_HIGH pages of 256 bytes), restructure as a
                 ; page loop (D = page count) around an inner DJNZ (B counts
                 ; 256..1), leaving A free to wrap 0..255 on its own via
                 ; natural 8-bit overflow.
                ld      hl,GOLD_BASE
                xor     a                           ; A = ramp value 0
                ld      d,REGION_HIGH               ; D = number of 256-byte pages
gld_page:
                ld      b,0                         ; inner count = 256
gld_loop:
                ld      (hl),a
                inc     hl
                inc     a                          ; wraps 0..255
                djnz    gld_loop
                dec     d
                jr      nz,gld_page

                  ; 0c. fill the SDRAM region [SDRAM_WIN..] with the SAME ramp
                 ;     via the proven direct-access write path.  Same page/
                 ;     DJNZ restructuring as gld_loop above, for the same
                 ;     reason (A must not be clobbered by the loop count).
                call    set_ptr_base             ; pointer = SDB0..SDB3 (0x010000)
                xor     a                           ; ramp value 0
                ld      d,REGION_HIGH               ; D = number of 256-byte pages
fl_page:
                ld      b,0                         ; inner count = 256
fl_loop:
                out      (DDATA),a                ; write byte, ptr post-increments
                inc     a                          ; ramps 0..255, wraps
                djnz    fl_loop
                dec     d
                jr      nz,fl_page

                ld      hl,msg_okp
                call    puts

                  ; ---------------------------------------------------------
                  ; PHASE A - direct-access SUSTAINED READ (I/O-port path)
                ld      hl,pa_hdr
                call    puts
                call    phase_a

                  ; ---------------------------------------------------------
                  ; PHASE A2 - direct-access SUSTAINED READ via INIR
                ld      hl,pa2_hdr
                call    puts
                call    phase_a2

                  ; ---------------------------------------------------------
                  ; PHASE A3 - diagnostic: same as A2 (INIR), but with the
                  ; same pre-read timing gap as Phase A (see phase_a3 below).
                ld      hl,pa3_hdr
                call    puts
                call    phase_a3

                  ; ---------------------------------------------------------
                  ; PHASE A4 - diagnostic: same as Phase A, but reads via
                  ; plain BC-addressed `in a,(c)` instead of Phase A's
                  ; immediate-addressed `in a,(DDATA)` (see phase_a4 below).
                ld      hl,pa4_hdr
                call    puts
                call    phase_a4

                  ; ---------------------------------------------------------
                  ; PHASE B - LDIR SDRAM -> block RAM (native read path)
                ld      hl,pb_hdr
                call    puts
                call    phase_b

                  ; ---------------------------------------------------------
                  ; PHASE C - CPIR golden vs SDRAM (read-only sustained)
                ld      hl,pc_hdr
                call    puts
                call    phase_c

                  ; ---------------------------------------------------------
                  ; PHASE D - LDIR block RAM -> SDRAM (sustained) + verify
                ld      hl,pd_hdr
                call    puts
                call    phase_d

                  ; ---------------------------------------------------------
                  ; VERDICT
                ld      hl,verdict_hdr
                call    puts
                ld      a,(perrflag)               ; any phase failed?
                or      a
                jr      nz,verdict_fail
                ld      hl,msg_allok
                call    puts
                jr      halt_loop
verdict_fail:
                ld      hl,msg_anyfail
                call    puts
halt_loop:
                halt
                jr      halt_loop

; ============================================================================
; set_ptr_base - load the direct-access pointer with the SDRAM region base
;                  (SDB0..SDB3 little-endian), i.e. physical 0x00010000.
; ============================================================================
set_ptr_base:
                ld      a,SDB0
                out      (PTR0),a
                ld      a,SDB1
                out      (PTR1),a
                ld      a,SDB2
                out      (PTR2),a
                ld      a,SDB3
                out      (PTR3),a
                ret

; ============================================================================
; golden_fetch - load the golden byte for a 16-bit region index held in
;                 (idx_lo : idx_hi).  Result in A.  Uses (a_idx) as scratch
;                 (a single scratch pair is enough for one outstanding fetch).
;   golden_at uses the *same* scratch pair, so all phases that need a golden
;    lookup first stage their index into (a_idx0 : a_idx1).
; ============================================================================
golden_fetch:
                 ; NOTE: this used to load B from a_idx0 (the index LOW byte)
                 ; and C from a_idx1 (the index HIGH byte) before `add
                 ; hl,bc` -- but Z-80 BC is (B*256+C), so that computed the
                 ; offset as (low*256+high) instead of (high*256+low): a
                 ; byte-swapped index.  For any index whose low byte wasn't
                 ; 0 this read the wrong GOLD_BASE offset (and for low
                 ; byte >= 4 it overran the 1024-byte GOLD_BASE buffer
                 ; entirely, reading garbage out of the adjacent WORK_BASE
                 ; buffer instead).  Fixed: B = high byte, C = low byte.
                ld      a,(a_idx1)
                ld      b,a
                ld      a,(a_idx0)
                ld      c,a
                ld      hl,GOLD_BASE
                add     hl,bc
                ld      a,(hl)
                ret

; ============================================================================
; PHASE A - sustained read of the SDRAM region via the direct-access port.
;   Read REGION (1024) bytes back-to-back with a tight IN (DDATA) loop and
;   compare each against the golden ramp.  A 16-bit index (pa_idx) walks the
;   region.  On the first mismatch: set flags, stage the index, report the
;   failing offset / expected / got, then CONTINUE (so remaining mismatches are
;   still counted but not re-printed).
; ============================================================================
phase_a:
                call    set_ptr_base              ; pointer = SDRAM region base
                call    zero_idx                   ; pa_idx = 0
                call    mmcnt_zero                 ; total-mismatch counter = 0
                xor     a
                ld      (pa_first),a              ; "already reported a fail?"
pa_loop:
                 ; read one byte from SDRAM via the direct-access port
                in      a,(DDATA)                ; A = got; ptr post-increments
                push    af                       ; save got (AF)

                ; stage current index into the golden_fetch scratch pair
                ld      a,(pa_idx_lo)
                ld      (a_idx0),a
                ld      a,(pa_idx_hi)
                ld      (a_idx1),a
                call    golden_fetch             ; A = expected = (index) = index
                pop     bc                        ; got -> B (B = saved A of got); C = flags
                cp      b                          ; expected(A) vs got(B)
                jr      z,pa_ok
                call    mmcnt_inc                ; count every mismatch, not just the first
                 ; mismatch on this byte: preserve expected(A)/got(B) across
                 ; the "already reported?" bookkeeping below, which would
                 ; otherwise clobber A before report_fail can use it.
                push    af
                ld      a,(pa_first)
                or      a
                jr      nz,pa_already           ; already reported one
                ld      a,1
                ld      (pa_first),a
                ld      (perrflag),a             ; flag overall failure
                pop     af                       ; restore expected(A); B still got
                call    report_fail             ; (index = pa_idx, exp in A, got in B)
                jr      pa_ok
pa_already:
                pop     af
pa_ok:
                   ; advance 16-bit index (pa_idx) by 1
                ld      hl,pa_idx_lo
                inc      (hl)                 ; increment low byte
                jr      nz,pa_loop            ; low byte nonzero: keep looping
                inc     hl                    ; low byte wrapped: point hl at high byte
                inc      (hl)                 ; increment high byte
                ld      a,(pa_idx_hi)
                cp      REGION_HIGH           ; stop when index has reached REGION
                jr      nz,pa_loop
                call    print_mmcnt
                ret

; ============================================================================
; PHASE A2 - direct-access SUSTAINED READ via INIR (a Z-80 block-input
;   instruction) rather than a software IN(DDATA)/compare loop.  INIR does,
;   entirely inside ONE opcode: IN (HL),(C); HL++; B--; repeat until B==0.
;
;   IMPORTANT CORRECTION: on the T80 core, INIR's repeat is implemented by
;   rolling PC back 2 and re-fetching the ED-prefixed opcode from program
;   memory on every iteration (T80.vhd, matching real Z-80 silicon so that
;   interrupts can be sampled mid-block); it is NOT a hardware loop with
;   zero intervening bus cycles.  Since this test runs from block RAM,
;   those refetches are block-RAM cycles, so INIR does NOT give a
;   structurally tighter/gap-free burst of SDRAM accesses than Phase A's
;   software loop at the SDRAM-CDC level.  The real difference from Phase A
;   is that INIR's FIRST port read follows set_ptr_base much SOONER (only 3
;   short instructions below, vs. Phase A's full CALL/RET to zero_idx
;   first) -- this phase is useful for probing whether the elapsed time
;   since the last MMU pointer-register write affects the reliability of
;   the very next SDRAM access, and for exercising a distinct
;   opcode/microcode path from Phase A's plain `in`.
;
;   B is only 8 bits (B=0 means a count of 256), so REGION (1024) bytes
;   requires REGION/256 = 4 back-to-back INIR calls of 256 bytes each. The
;   direct-access pointer auto-increments across all 4 calls, so it is only
;   reset once, before the first INIR.  The destination is WORK_BASE (block
;   RAM); it is then verified against the golden ramp exactly as Phase B
;   does.
; ============================================================================
phase_a2:
                call    set_ptr_base              ; pointer = SDRAM region base
                ld      hl,WORK_BASE               ; dest (block RAM)
                ld      c,DDATA                    ; INIR reads from port (C)
                ld      b,0                        ; count = 256 (block 1 of 4)
                inir
                ld      b,0                        ; count = 256 (block 2 of 4)
                inir
                ld      b,0                        ; count = 256 (block 3 of 4)
                inir
                ld      b,0                        ; count = 256 (block 4 of 4)
                inir
                 ; verify WORK_BASE against golden (same pattern as phase B)
                call    zero_idx                  ; a_idx -> 0
                call    mmcnt_zero                 ; total-mismatch counter = 0
                xor     a
                ld      (pa2_first),a
pa2_loop:
                 ; got = WORK_BASE[index].  B must be the index HIGH byte and
                 ; C the LOW byte for `add hl,bc` (BC=B*256+C) to compute the
                 ; right offset -- see the note in golden_fetch about the
                 ; identical swapped-byte-order bug.
                ld      a,(a_idx1)
                ld      b,a
                ld      a,(a_idx0)
                ld      c,a
                ld      hl,WORK_BASE
                add     hl,bc
                ld      a,(hl)                  ; A = got
                push    af
                call    golden_fetch          ; A = expected (reuses a_idx0/1)
                pop     bc                       ; got -> B; C = flags
                cp      b                       ; expected(A) vs got(B)
                jr      z,pa2_ok
                call    mmcnt_inc                ; count every mismatch, not just the first
                 ; preserve expected(A)/got(B) across the bookkeeping below
                push    af
                ld      a,(pa2_first)
                or      a
                jr      nz,pa2_already
                ld      a,1
                ld      (pa2_first),a
                ld      (perrflag),a
                pop     af                       ; restore expected(A); B still got
                call    report_fail
                jr      pa2_ok
pa2_already:
                pop     af
pa2_ok:
                   ; advance 16-bit index (a_idx) by 1
                ld      hl,a_idx0
                inc      (hl)                  ; increment low byte
                jr      nz,pa2_loop            ; low byte nonzero: keep looping
                inc     hl                     ; low byte wrapped: point hl at a_idx1
                inc      (hl)                  ; increment high byte
                ld      a,(a_idx1)
                cp      REGION_HIGH            ; stop when index has reached REGION
                jr      nz,pa2_loop
                call    print_mmcnt
                ret

; ============================================================================
; PHASE A3 - DIAGNOSTIC: identical to Phase A2 (sustained INIR read), except
;   a `call zero_idx` is inserted between set_ptr_base and the first INIR --
;   the exact same subroutine call Phase A performs before its first
;   `in a,(DDATA)` -- so Phase A3's first SDRAM read follows the last MMU
;   pointer-register write (in set_ptr_base) after the SAME elapsed time
;   (T-states) as Phase A's does.  Phase A2's first INIR read, by contrast,
;   follows set_ptr_base after only 3 short instructions -- a much shorter
;   gap.
;
;   PURPOSE: isolate whether Phase A2's intermittent first-byte failure
;   (@0000, non-deterministic wrong value) is caused by:
;     (a) how SOON the first real SDRAM access follows the pointer-register
;         setup (a settle-time / async wait-line race), or
;     (b) something specific to the INIR opcode's own bus-cycle timing.
;   If Phase A3 passes reliably (timing matched to Phase A, but still using
;   INIR), that points to (a).  If Phase A3 still shows the same
;   intermittent @0000 failure despite the matched timing, that points to
;   (b) -- something about INIR's bus cycle itself, distinct from mere
;   elapsed time since the last MMU access.
; ============================================================================
phase_a3:
                call    set_ptr_base              ; pointer = SDRAM region base
                call    zero_idx                  ; <-- the only change vs phase_a2:
                                                    ;     matches Phase A's pre-read
                                                    ;     timing gap exactly.
                ld      hl,WORK_BASE               ; dest (block RAM)
                ld      c,DDATA                    ; INIR reads from port (C)
                ld      b,0                        ; count = 256 (block 1 of 4)
                inir
                ld      b,0                        ; count = 256 (block 2 of 4)
                inir
                ld      b,0                        ; count = 256 (block 3 of 4)
                inir
                ld      b,0                        ; count = 256 (block 4 of 4)
                inir
                 ; verify WORK_BASE against golden (same pattern as phase A2)
                call    zero_idx                  ; a_idx -> 0
                call    mmcnt_zero                 ; total-mismatch counter = 0
                xor     a
                ld      (pa3_first),a
pa3_loop:
                 ; got = WORK_BASE[index] (B=index HIGH byte, C=LOW byte --
                 ; see the golden_fetch note on the swapped-byte-order bug)
                ld      a,(a_idx1)
                ld      b,a
                ld      a,(a_idx0)
                ld      c,a
                ld      hl,WORK_BASE
                add     hl,bc
                ld      a,(hl)                  ; A = got
                push    af
                call    golden_fetch          ; A = expected (reuses a_idx0/1)
                pop     bc                       ; got -> B; C = flags
                cp      b                       ; expected(A) vs got(B)
                jr      z,pa3_ok
                call    mmcnt_inc                ; count every mismatch, not just the first
                 ; preserve expected(A)/got(B) across the bookkeeping below
                push    af
                ld      a,(pa3_first)
                or      a
                jr      nz,pa3_already
                ld      a,1
                ld      (pa3_first),a
                ld      (perrflag),a
                pop     af                       ; restore expected(A); B still got
                call    report_fail
                jr      pa3_ok
pa3_already:
                pop     af
pa3_ok:
                   ; advance 16-bit index (a_idx) by 1
                ld      hl,a_idx0
                inc      (hl)                  ; increment low byte
                jr      nz,pa3_loop            ; low byte nonzero: keep looping
                inc     hl                     ; low byte wrapped: point hl at a_idx1
                inc      (hl)                  ; increment high byte
                ld      a,(a_idx1)
                cp      REGION_HIGH            ; stop when index has reached REGION
                jr      nz,pa3_loop
                call    print_mmcnt
                ret

; ============================================================================
; PHASE A4 - DIAGNOSTIC: isolates whether the Phase A2/A3 first-byte failure
;   is caused by INIR's block-repeat microcode (decrement B, memory write to
;   (HL), PC-rollback re-fetch) or simply by the BC-ADDRESSED I/O bus cycle
;   itself ("IN r,(C)"), as opposed to Phase A's immediate-addressed
;   "IN A,(n)" form.  Phase A2/A3 mismatch count was exactly 1 in both
;   cases (always the very first byte, never bytes 256/512/768, i.e. not a
;   per-INIR-call pattern) -- this points at something about the FIRST
;   BC-addressed read of port 0xBC following set_ptr_base, not at INI/INIR's
;   block mechanism specifically.
;
;   This phase is structurally IDENTICAL to Phase A (same call set_ptr_base
;   / call zero_idx timing gap, same per-iteration staging/compare
;   overhead) except the read is done with a single plain `in a,(c)`
;   instruction (BC-addressed) instead of Phase A's `in a,(DDATA)`
;   (immediate-addressed) -- with NONE of INI/INIR's extra microcode.  C is
;   reloaded every iteration since golden_fetch/report_fail use BC as
;   scratch internally.
;
;   - If Phase A4 ALSO fails on the very first byte -> confirms the fault is
;     the BC-addressed ("IN r,(C)"-style) I/O bus cycle itself, not
;     anything specific to INI/INIR's block-repeat mechanism.
;   - If Phase A4 PASSES -> the fault requires INI/INIR's fuller microcode
;     (decrement-B, the write-to-(HL) that follows, and/or the PC-rollback
;     re-fetch), and is not explained by BC-addressing alone.
; ============================================================================
phase_a4:
                call    set_ptr_base              ; pointer = SDRAM region base
                call    zero_idx                   ; a_idx = 0 (also zeroes pa_idx,
                                                    ;  unused here, harmless)
                call    mmcnt_zero                 ; total-mismatch counter = 0
                xor     a
                ld      (pa4_idx_lo),a
                ld      (pa4_idx_hi),a
                ld      (pa4_first),a             ; "already reported a fail?"
pa4_loop:
                 ; read one byte from SDRAM via the direct-access port using
                 ; the BC-addressed "IN r,(C)" bus cycle (same addressing
                 ; mode INI/INIR use for their port read), as a single plain
                 ; instruction with none of INI/INIR's block-repeat
                 ; microcode.
                ld      c,DDATA                  ; reloaded every iteration --
                                                    ;  golden_fetch/report_fail
                                                    ;  clobber C as scratch
                in      a,(c)                     ; A = got; ptr post-increments
                push    af                        ; save got (AF)

                ld      a,(pa4_idx_lo)
                ld      (a_idx0),a
                ld      a,(pa4_idx_hi)
                ld      (a_idx1),a
                call    golden_fetch              ; A = expected
                pop     bc                         ; got -> B (B = saved A of got); C = flags
                cp      b                          ; expected(A) vs got(B)
                jr      z,pa4_ok
                call    mmcnt_inc                 ; count every mismatch, not just the first
                 ; preserve expected(A)/got(B) across the bookkeeping below
                push    af
                ld      a,(pa4_first)
                or      a
                jr      nz,pa4_already
                ld      a,1
                ld      (pa4_first),a
                ld      (perrflag),a
                pop     af                        ; restore expected(A); B still got
                call    report_fail
                jr      pa4_ok
pa4_already:
                pop     af
pa4_ok:
                   ; advance 16-bit index (pa4_idx) by 1
                ld      hl,pa4_idx_lo
                inc      (hl)                  ; increment low byte
                jr      nz,pa4_loop            ; low byte nonzero: keep looping
                inc     hl                     ; low byte wrapped: point hl at high byte
                inc      (hl)                  ; increment high byte
                ld      a,(pa4_idx_hi)
                cp      REGION_HIGH            ; stop when index has reached REGION
                jr      nz,pa4_loop
                call    print_mmcnt
                ret

; ============================================================================
; PHASE B - LDIR SDRAM (SDRAM_WIN) -> block-RAM buffer (WORK_BASE), then
;   verify the buffer byte-by-byte against the golden ramp.
; ============================================================================
phase_b:
                ld      hl,SDRAM_WIN            ; source (SDRAM, frame 1)
                ld      de,WORK_BASE            ; dest (block RAM)
                ld      bc,REGION
                ldir
                 ; verify WORK_BASE against golden
                call    zero_idx               ; pb_idx -> 0 (uses the same
                                              ;  index scratch pair as (a))
                call    mmcnt_zero              ; total-mismatch counter = 0
                ; NOTE: zero_idx zeroes (a_idx0)/(a_idx1) AND (pa_idx); phase B
                 ; uses (pb_idx) which we alias to (a_idx*) via pb_idx0/1.
                 ; To keep a single index pair, phase B uses (a_idx0/1) too.
                xor     a
                ld      (pb_first),a
pb_loop:
                 ; got = WORK_BASE[index] (B=index HIGH byte, C=LOW byte --
                 ; see the golden_fetch note on the swapped-byte-order bug)
                ld      a,(a_idx1)
                ld      b,a
                ld      a,(a_idx0)
                ld      c,a
                ld      hl,WORK_BASE
                add     hl,bc
                ld      a,(hl)                  ; A = got
                push    af
                call    golden_fetch          ; A = expected (reuses a_idx0/1)
                pop     bc                       ; got -> B (B = saved A of got); C = flags
                cp      b                       ; expected(A) vs got(B)
                jr      z,pb_ok
                call    mmcnt_inc                ; count every mismatch, not just the first
                 ; preserve expected(A)/got(B) across the bookkeeping below
                push    af
                ld      a,(pb_first)
                or      a
                jr      nz,pb_already
                ld      a,1
                ld      (pb_first),a
                ld      (perrflag),a
                pop     af                       ; restore expected(A); B still got
                call    report_fail
                jr      pb_ok
pb_already:
                pop     af
pb_ok:
                   ; advance 16-bit index (a_idx) by 1
                ld      hl,a_idx0
                inc      (hl)                  ; increment low byte
                jr      nz,pb_loop             ; low byte nonzero: keep looping
                inc     hl                     ; low byte wrapped: point hl at a_idx1
                inc      (hl)                  ; increment high byte
                ld      a,(a_idx1)
                cp      REGION_HIGH            ; stop when index has reached REGION
                jr      nz,pb_loop
                call    print_mmcnt
                ret

; ============================================================================
; PHASE C - CPIR: sustained, READ-ONLY search for a de-duplicated sentinel
;   byte in the SDRAM region.
;
;   IMPORTANT / BUG FIXED HERE: CPI/CPIR does *not* compare two memory
;   regions.  Per the Z-80 instruction set, CPI/CPIR compares the
;   accumulator (A) against (HL) ONLY -- it never reads DE, and DE is not
;   advanced by the instruction.  An earlier version of this phase did
;   `ld de,GOLD_BASE` / `ld hl,SDRAM_WIN` / `cpir`, expecting a DE-vs-HL
;   block compare; that is not what CPIR does (DE was simply ignored, and A
;   was left holding whatever it was set to by the preceding code, not a
;   per-byte "expected" value), so that version never validated anything.
;
;   CORRECTED DESIGN: use CPIR for what it actually does -- a sustained,
;   single-value search -- in a way that still exercises a full back-to-back
;   read of the SDRAM region and is worth running in its own right, because
;   CPIR's microcode/timing in the T80 core differs from LDIR's (see
;   Components/Z80/T80_MCode.vhd), so it stresses the SDRAM read path with a
;   distinct instruction, not just a repeat of Phase B's LDIR.
;
;   The golden ramp (GOLD[i] = i mod 256) naturally places the byte value
;   0xFF at every 256-byte boundary (offsets 255, 511, 767, 1023 for
;   REGION=1024), and Phase 0 wrote that same ramp into the SDRAM region.
;   Before searching, the first three occurrences in the SDRAM copy are
;   overwritten with 0xFE via the (proven, single-touch, non-sustained)
;   direct-access port, leaving offset LASTOFF (1023) as the ONLY 0xFF left
;   in the whole region. A plain `cpir` searching for 0xFF must then scan
;   every one of the REGION bytes, back-to-back -- there are no software
;   instructions between reads; they all happen inside the one CPIR opcode
;   -- before it can find the match at the very end.
;
;   Expected result, per Z-80 CPI/CPIR semantics (each iteration: compare A
;   to (HL), HL++, BC--, Z set iff A==(HL); CPIR repeats while BC!=0 and
;   Z=0):
;     - Z=1 and BC=0  -> the sentinel was found on the LAST iteration (the
;                         real, de-duplicated 0xFF at offset LASTOFF). PASS:
;                         the whole region was read back-to-back with no
;                         early false match and no missed match.
;     - Z=1 and BC!=0 -> the sentinel was found EARLY (some other offset
;                         read back as 0xFF) -> a corrupted/stale read
;                         produced a false match.  FAIL.
;     - Z=0 (BC=0)     -> the sentinel was never found (the true last byte
;                         itself did not read back as 0xFF) -> FAIL.
; ============================================================================
phase_c:
                call    pc_dedup_sentinel      ; leave exactly one 0xFF, @LASTOFF

                ld      hl,SDRAM_WIN            ; SDRAM region (frame 1)
                ld      bc,REGION
                ld      a,0FFh                  ; sentinel byte to search for
                cpir                            ; sustained, read-only scan

                jr      z,pc_found              ; Z=1 -> a match was found
                 ; Z=0: BC reached 0 without ever finding 0xFF -> not found
                ld      a,1
                ld      (perrflag),a
                ld      hl,msg_cnotfound
                call    puts
                ret

pc_found:
                ld      a,b
                or      c
                jr      z,pc_pass               ; BC==0 -> matched on the LAST
                                                 ; iteration, exactly as expected
                 ; found EARLY: offset = LASTOFF - BC
                ld      a,1
                ld      (perrflag),a
                ld      hl,msg_cearly
                call    puts
                ld      hl,LASTOFF
                or      a                        ; clear carry for sbc hl,bc
                sbc     hl,bc
                ld      a,h
                call    puthex
                ld      a,l
                call    puthex
                call    crlf
                ret

pc_pass:
                ld      hl,msg_cpass
                call    puts
                ret

; ----------------------------------------------------------------------------
; pc_dedup_sentinel - overwrite the SDRAM copies of the ramp's redundant
;   0xFF occurrences (offsets 255, 511, 767) with 0xFE via the direct-access
;   port, leaving offset LASTOFF (1023) as the only 0xFF in the region.
;   These are isolated, single-touch direct-access writes (the proven path
;   already exercised in Phase 0), not sustained, so this setup step does
;   not itself depend on the sustained-access behaviour under test.
; ----------------------------------------------------------------------------
pc_dedup_sentinel:
                ld      hl,255
                call    pc_poke_fe
                ld      hl,511
                call    pc_poke_fe
                ld      hl,767
                call    pc_poke_fe
                ret

; pc_poke_fe - write 0xFE at SDRAM region offset HL (0..1023) via the
;   direct-access port.  Pointer = SDRAM region base (SDB0..SDB3, physical
;   0x00010000) + HL; since HL < 1024 and the base's low 16 bits are 0, this
;   never carries into PTR2/PTR3.
pc_poke_fe:
                push    hl
                ld      a,l
                out      (PTR0),a
                ld      a,h
                out      (PTR1),a
                ld      a,SDB2
                out      (PTR2),a
                ld      a,SDB3
                out      (PTR3),a
                ld      a,0FEh
                out      (DDATA),a
                pop     hl
                ret

; ============================================================================
; PHASE D - sustained SDRAM WRITE: LDIR golden (block RAM) -> SDRAM (frame 1),
;   then verify by LDIR SDRAM -> block-RAM buffer (WORK_BASE) and compare vs
;   golden.  Exercises the sustained write path (tWR / write-recovery) and the
;   subsequent read.
; ============================================================================
phase_d:
                 ; sustained write: golden -> SDRAM
                ld      hl,GOLD_BASE            ; src (block RAM)
                ld      de,SDRAM_WIN            ; dst (SDRAM, frame 1)
                ld      bc,REGION
                ldir
                 ; read back: SDRAM -> WORK_BASE
                ld      hl,SDRAM_WIN
                ld      de,WORK_BASE
                ld      bc,REGION
                ldir
                 ; verify WORK_BASE vs golden (uses a_idx, like phase B)
                call    zero_idx
                call    mmcnt_zero              ; total-mismatch counter = 0
                xor     a
                ld      (pd_first),a
pd_loop:
                 ; got = WORK_BASE[index] (B=index HIGH byte, C=LOW byte --
                 ; see the golden_fetch note on the swapped-byte-order bug)
                ld      a,(a_idx1)
                ld      b,a
                ld      a,(a_idx0)
                ld      c,a
                ld      hl,WORK_BASE
                add     hl,bc
                ld      a,(hl)                  ; got
                push    af
                call    golden_fetch          ; A = expected
                pop     bc                       ; got -> B (B = saved A of got); C = flags
                cp      b                       ; expected(A) vs got(B)
                jr      z,pd_ok
                call    mmcnt_inc                ; count every mismatch, not just the first
                 ; preserve expected(A)/got(B) across the bookkeeping below
                push    af
                ld      a,(pd_first)
                or      a
                jr      nz,pd_already
                ld      a,1
                ld      (pd_first),a
                ld      (perrflag),a
                pop     af                       ; restore expected(A); B still got
                call    report_fail
                jr      pd_ok
pd_already:
                pop     af
pd_ok:
                ld      hl,a_idx0
                inc      (hl)                   ; increment low byte
                jr      nz,pd_loop              ; low byte nonzero: keep looping
                inc     hl                      ; low byte wrapped: point hl at a_idx1
                inc      (hl)                   ; increment high byte
                ld      a,(a_idx1)
                cp      REGION_HIGH             ; stop when index has reached REGION
                jr      nz,pd_loop
                call    print_mmcnt
                ret

; ============================================================================
; zero_idx - set the shared 16-bit index (a_idx0 : a_idx1) to 0.
;   Also zeroes (pa_idx) so phase A starts cleanly (pa_idx is separate).
; ============================================================================
zero_idx:
                xor     a
                ld      (a_idx0),a
                ld      (a_idx1),a
                ld      (pa_idx_lo),a
                ld      (pa_idx_hi),a
                ret

; ============================================================================
; mmcnt_zero / mmcnt_inc / print_mmcnt - shared 16-bit mismatch COUNTER.
;   Each verify-style phase (A, A2, A3, B, D) zeroes this at phase entry,
;   increments it on EVERY mismatch (not just the first -- report_fail only
;   ever prints the FIRST mismatch's details, which hides whether a phase
;   has exactly one bad byte or many), and prints the total at phase exit.
;   This lets us tell an isolated one-off from a pervasive/patterned
;   failure (e.g. "first byte of every INIR call": offsets 0/256/512/768)
;   without flooding the console with up to 1024 FAIL lines.
; ============================================================================
mmcnt_zero:
                xor     a
                ld      (mmcnt_lo),a
                ld      (mmcnt_hi),a
                ret

mmcnt_inc:
                ld      hl,mmcnt_lo
                inc     (hl)
                ret     nz
                inc     hl
                inc     (hl)
                ret

print_mmcnt:
                push    af
                push    hl
                ld      hl,msg_mmcnt
                call    puts
                ld      a,(mmcnt_hi)
                call    puthex
                ld      a,(mmcnt_lo)
                call    puthex
                call    crlf
                pop     hl
                pop     af
                ret

; ============================================================================
; report_fail - print "  FAIL @NNNN exp=XX got=YY\r\n"
;   NNNN = the 16-bit region index held in (a_idx0 : a_idx1).
;   A    = expected byte,  B = got byte  (caller convention).
;   Prints the index, then expected (A), then got (B).
;
;   NOTE: this used to juggle the expected/got bytes through push/pop AF/BC
;   pairs interleaved with the puts calls; a stack-bookkeeping mistake there
;   made it pop the *same* value back twice, so the printed "exp=" and
;   "got=" fields were silently SWAPPED.  Stashing both bytes to scratch
;   bytes up front avoids any stack-ordering dependency.
; ============================================================================
report_fail:
                ld      (rf_exp),a             ; stash expected (A)
                ld      a,b
                ld      (rf_got),a             ; stash got (B)
                ld      hl,msg_failpre         ; "  FAIL @"
                call    puts
                 ; print 16-bit index (a_idx1 : a_idx0)
                ld      a,(a_idx1)
                call    puthex
                ld      a,(a_idx0)
                call    puthex
                ld      hl,msg_exp             ; " exp="
                call    puts
                ld      a,(rf_exp)
                call    puthex
                ld      hl,msg_got             ; " got="
                call    puts
                ld      a,(rf_got)
                call    puthex
                call    crlf
                ret

; ============================================================================
; Serial output helpers (identical to sdramtest.asm / sdramexec.asm)
; ============================================================================
putc:
                push    af
pc_wait:
                in      a,(SERSTAT)
                and     TDRE
                jr      z,pc_wait
                pop     af
                out      (SERDATA),a
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
msg_banner:     defb    0Dh,0Ah
                defm     "MultiComp SDRAM back-to-back (sustained) test"
                defb     0Dh,0Ah
                defm     "region "
                defb     000h                 ; REGION low nibble (1024 -> 00)
                defb     0Dh
                defm     " bytes @ SDRAM page "
                defb     TESTPAGE
                defb     0Dh,0Ah,0

pa0_hdr:        defb     0Dh,0Ah
                defm     "PHASE 0: build golden ramp + fill SDRAM (direct-access)"
                defb     0Dh,0Ah,0

pa_hdr:         defb     0Dh,0Ah
                defm     "PHASE A: direct-access SUSTAINED READ"
                defb     0Dh,0Ah,0

pa2_hdr:        defb     0Dh,0Ah
                defm     "PHASE A2: direct-access SUSTAINED READ (INIR)"
                defb     0Dh,0Ah,0

pa3_hdr:        defb     0Dh,0Ah
                defm     "PHASE A3: INIR read, timing-matched to Phase A (diag)"
                defb     0Dh,0Ah,0

pa4_hdr:        defb     0Dh,0Ah
                defm     "PHASE A4: plain IN r,(C) read, BC-addressed (diag)"
                defb     0Dh,0Ah,0

pb_hdr:         defb     0Dh,0Ah
                defm     "PHASE B: LDIR SDRAM->BRAM (native read path)"
                defb     0Dh,0Ah,0

pc_hdr:         defb     0Dh,0Ah
                defm     "PHASE C: CPIR sentinel search (read-only sustained)"
                defb     0Dh,0Ah,0

pd_hdr:         defb     0Dh,0Ah
                defm     "PHASE D: LDIR BRAM->SDRAM (sustained) + verify"
                defb     0Dh,0Ah,0

verdict_hdr:    defb     0Dh,0Ah
                defm     "==== VERDICT ===="
                defb     0Dh,0Ah,0

msg_failpre:    defm     "  FAIL @"
                defb     0
msg_exp:        defm     " exp="
                defb     0
msg_got:        defm     " got="
                defb     0

msg_mmcnt:      defm     "  mismatches: "
                defb     0

; Phase C (CPIR sentinel search) result messages.
msg_cpass:      defm     "  sentinel found @03FF (region fully scanned) OK"
                defb     0Dh,0Ah,0
msg_cearly:     defm     "  FAIL sentinel found EARLY @"
                defb     0
msg_cnotfound:  defm     "  FAIL sentinel NOT FOUND (expected last byte @03FF)"
                defb     0Dh,0Ah,0

msg_okp:        defm     "PHASE 0 OK"
                defb     0Dh,0Ah,0

msg_allok:      defm     "RESULT: ALL SUSTAINED TESTS PASSED"
                defb     0Dh,0Ah,0
msg_anyfail:    defm     "RESULT: FAILURES DETECTED (see phases above)"
                defb     0Dh,0Ah,0

; ============================================================================
; RAM scratch (block RAM, frame 0)  --  placed at SCRATCH
; ============================================================================
                org      SCRATCH

a_idx0:         defs     1               ; shared 16-bit index low
a_idx1:         defs     1               ; shared 16-bit index high
pa_idx_lo:      defs     1               ; phase A 16-bit index low
pa_idx_hi:      defs     1               ; phase A 16-bit index high
pa_first:       defs     1               ; 1 once phase A reported a fail
pa2_first:      defs     1               ; 1 once phase A2 reported a fail
pa3_first:      defs     1               ; 1 once phase A3 reported a fail
pa4_idx_lo:     defs     1               ; phase A4 16-bit index low
pa4_idx_hi:     defs     1               ; phase A4 16-bit index high
pa4_first:      defs     1               ; 1 once phase A4 reported a fail
pb_first:       defs     1               ; 1 once phase B reported a fail
pd_first:       defs     1               ; 1 once phase D reported a fail
perrflag:       defs     1               ; overall "any phase failed"
                                          ; (phase C is single-shot; no "first"
                                          ;  flag needed -- see phase_c)
rf_exp:         defs     1               ; report_fail scratch: expected byte
rf_got:         defs     1               ; report_fail scratch: got byte
mmcnt_lo:       defs     1               ; shared 16-bit mismatch count, low
mmcnt_hi:       defs     1               ; shared 16-bit mismatch count, high

; Golden ramp + LDIR buffers (frame 0 / block RAM), each 1024 bytes.
;   GOLD_BASE = 0x2000, WORK_BASE = 0x2400 (defined as EQUs above). Code +
;   scratch + messages end well below 0x2000, so these are disjoint.

                end

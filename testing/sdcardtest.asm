; ============================================================================
; sdcardtest.asm - end-to-end test of the SPI SD card controller
;                  (sd_controller, I/O ports 88h-8Fh)
; ----------------------------------------------------------------------------
; PURPOSE
;   Validates the whole chain Z-80 -> sd_controller -> SPI -> a physical SD
;   or SDHC card in the SD socket.  It is the counterpart of blockdevtest.asm
;   (the HPS image block device at 90h-97h) and is laid out the same way, but
;   it allows for the differences of the SPI controller:
;
;     - There are NO size registers.  The card capacity cannot be read, so it
;       is a build-time constant (CARD_MB, see below).
;     - Reading or writing past the end of the card is NOT rejected: the
;       controller waits forever for a data token and stays hung until the
;       core is reset.  So the out-of-range test of blockdevtest is omitted
;       and CARD_MB must not be larger than the real card.
;     - STATUS b4 is "init busy": the FPGA initialises the card after reset
;       and b4 stays set until that is done (forever if there is no card).
;     - STATUS b3:b2 are always 0 (no read-only / rejected flags), so there
;       is no error reporting at all: a card problem shows up as a timeout.
;     - The read/write-ready bits are per BYTE.  The 512 bytes of a block
;       are normally moved with a status poll before each byte.  Writes are
;       ALWAYS polled here (the controller drops a byte written while b7 is
;       clear, which really can happen with OTIR during the first bytes).
;
;   Phase 1 - READ tests (non-destructive, always run):
;     T1  wait for card init to finish (STATUS b4 clear), STATUS reads idle
;         (80h).  If b4 stays set the program reports "no card", shows the
;         controller's diagnostic registers (where the init is stuck, the
;         live MISO level, the framework's card-detect) and stops.
;     T2  states the capacity in use (from CARD_MB) and shows the controller's
;         diagnostic registers +5..+7 (FSM state, SDHC flag, init restarts,
;         card detect; FPGA builds before the diagnostics read 0 there)
;     T3  read block 0, one byte at a time, polling STATUS before each byte;
;         hex dump and MBR signature (55AAh) report
;     T4  read block 0 again with INIR (back-to-back, no status poll).  This
;         is informational: the Z-80 at 10 MHz is slower than the 25 MHz SPI
;         clock so it normally works.  If it does NOT match, the program
;         notes that and uses polled reads only for the rest of the run.
;     T5  read the LAST block of CARD_MB (both ways if INIR is usable)
;     T6  read blocks 1,2,4,8,... (each power of two below the capacity),
;         both ways if INIR is usable (exercises every LBA bit)
;     T7  block 0 read again after all of the above: must be unchanged
;   If everything passes the program asks whether to go on.
;
;   Phase 2 - WRITE tests (destructive, asks first):
;     the NSECT (100) sectors at the top of CARD_MB are
;       1. backed up to physical RAM at 400000h (read back and verified),
;       2. written with a per-sector pattern, then read back in the OPPOSITE
;          order and compared (catches cross-sector aliasing); done twice,
;          the second time with all bits inverted (and the read-back using
;          INIR if T4 showed that works),
;       3. restored from the backup and verified.
;     So the card ends up unchanged even though it was written to.  If the
;     program is interrupted (reset, power) in the middle, those NSECT
;     sectors are left holding the test pattern - the prompt shows the LBA
;     range so you can make sure nothing important lives there.
;
; USAGE
;   Load the .BIN with the OSD "Boot Rom Image" entry (SDRAM target) with an
;   SD card in the socket (the card is initialised by the FPGA at reset, so
;   insert it BEFORE resetting/loading).  Output goes to BOTH the video
;   terminal (ports 80h/81h) and the serial console (82h/83h); answer the
;   prompt from either keyboard.
;
; CARD CAPACITY (IMPORTANT)
;   CARD_MB below is the card size in MiB (max 8191: the 24-bit block number
;   reaches 8 GB).  The default is deliberately small (128 MiB) so the test
;   is safe on any card.  Set it to the real size to test the whole card, or
;   leave it small to confine the test to the start of the card.  If it is
;   larger than the card the controller hangs; the program then reports a
;   command timeout and the core must be reset.  Override it at build time:
;       tools/z80asm.sh -D CARD_MB=7680 testing/sdcardtest.asm
;   Note a card holding a RomWBW image or DOS partitions has live data in
;   the area tested; the write test backs it up and restores it, but see the
;   caution above.
;
; BUILD
;   make -C testing sdcardtest.bin   (or tools/z80asm.sh testing/sdcardtest.asm)
; ============================================================================

                .z80
                aseg
                org     0000h

; ---- configuration ---------------------------------------------------------
                IFNDEF  CARD_MB
CARD_MB         equ     128             ; card size in MiB (<= the real card!)
                ENDIF
                IF      CARD_MB GT 8191
                CARD_MB_MUST_BE_AT_MOST_8191
                ENDIF
; blocks = CARD_MB * 2048, split to fit in 16-bit assembler arithmetic
SIZE_LO         equ     (CARD_MB AND 31) * 2048 ; blocks bits 15:0
SIZE_HI         equ     CARD_MB / 32            ; blocks bits 23:16

NSECT           equ     100             ; sectors in the write test
WAITOUTER       equ     24              ; ~ 8 s per wait at 10 MHz
INITOUTER       equ     60              ; ~ 20 s for the card to initialise
BKP_HI          equ     040h            ; backup area physical 00400000h
                                        ; (+ sector index * 512)

; ---- ports -------------------------------------------------------------------
CON_STAT        equ     080h            ; video terminal (6850-like)
CON_DATA        equ     081h
SER_STAT        equ     082h            ; serial console (6850 ACIA)
SER_DATA        equ     083h
TDRE            equ     002h
RDRF            equ     001h

SD_DATA         equ     088h            ; sd_controller
SD_STAT         equ     089h            ;   read: status   write: command
SD_LBA0         equ     08Ah
SD_LBA1         equ     08Bh
SD_LBA2         equ     08Ch
SD_DG5          equ     08Dh            ; diagnostics (read only): FSM state
SD_DG6          equ     08Eh            ;   next step (identifies the command)
SD_DG7          equ     08Fh            ;   pins / card detect / init retries

MMU_PTR0        equ     0B8h            ; MMU direct-access pointer
MMU_PTR1        equ     0B9h
MMU_PTR2        equ     0BAh
MMU_PTR3        equ     0BBh
MMU_DAT         equ     0BCh            ; direct-access data port

; ---- sd_* error codes (V_ERRC) ---------------------------------------------
E_BUSY          equ     1               ; device not idle at start
E_CMDTMO        equ     3               ; no data ready after the command
E_BYTETMO       equ     4               ; byte-ready timeout in poll mode
E_END           equ     5               ; not idle after block

; ---- memory (all in frame 0, below 4000h) ----------------------------------
BUFA            equ     2000h
BUFB            equ     2200h
BUFC            equ     2400h
STACK           equ     3F00h

V_BASE          equ     3000h           ; 4  base LBA of the write test
V_SIZE          equ     3004h           ; 4  capacity, blocks
V_LBA           equ     3008h           ; 4  current LBA (bits 31:24 = 0)
V_NUM           equ     300Ch           ; 4  putdec32 scratch
V_TMP           equ     3010h           ; 4  scratch
V_DEST          equ     3014h           ; 2  sd_read/sd_write buffer pointer
V_FAILS         equ     3016h           ; 2  failure count
V_MOFF          equ     3018h           ; 2  cmp512: offset of first difference
V_SUM           equ     301Ah           ; 2  cksum512 result
V_FAST          equ     301Ch           ; 1  0 = poll per byte, 1 = INIR (reads)
V_ERRC          equ     301Dh           ; 1  last sd_* error code
V_IDX           equ     301Eh           ; 1  sector index in the write test
V_PASSN         equ     301Fh           ; 1  write-test pattern (0 / 1)
V_MEXP          equ     3020h           ; 1  cmp512: expected byte
V_MACT          equ     3021h           ; 1  cmp512: actual byte
V_PRT           equ     3022h           ; 1  detailed mismatch lines printed
V_FASTOK        equ     3023h           ; 1  1 = T4 showed INIR reads work
V_SUM0          equ     3026h           ; 2  checksum of block 0 (T3)
V_FMARK         equ     3028h           ; 2  failure count mark (pr_result)

; ============================================================================
start:
                di
                ld      sp,STACK
                ld      a,003h                  ; serial ACIA master reset
                out     (SER_STAT),a
                ld      a,015h                  ; 8N1, /16
                out     (SER_STAT),a

                ld      hl,V_BASE               ; clear variables
                ld      bc,0100h
                ld      (hl),0
                ld      de,V_BASE+1
                dec     bc
                ldir

                ld      hl,msg_banner
                call    puts

; ---- T1: card initialisation and status -------------------------------------------
                ld      hl,msg_t1
                call    puts
                in      a,(SD_STAT)
                call    puthex
                in      a,(SD_STAT)
                and     010h
                jr      z,t1_ready
                ld      hl,msg_initw            ; init busy: give it time
                call    puts
                ld      d,INITOUTER
t1_o:           ld      bc,0
t1_i:           in      a,(SD_STAT)
                and     010h
                jr      z,t1_done
                dec     bc
                ld      a,b
                or      c
                jr      nz,t1_i
                dec     d
                jr      nz,t1_o
                ld      hl,msg_nocard           ; init never finished
                call    puts
                in      a,(SD_STAT)
                call    puthex
                call    crlf
                call    pr_diag                 ; where is it stuck?
                call    pr_fail
                jp      p1_done                 ; no point going on
t1_done:        ld      hl,msg_inited
                call    puts
                in      a,(SD_STAT)
                call    puthex
t1_ready:       in      a,(SD_STAT)
                cp      080h                    ; idle, nothing else set
                jr      nz,t1_bad
                call    pr_ok
                jr      t2
t1_bad:         call    pr_fail
                jp      p1_done

; ---- T2: capacity (assumed) and FPGA diagnostics ---------------------------------
t2:             ld      hl,msg_t2
                call    puts
                ld      hl,SIZE_LO              ; V_SIZE from CARD_MB
                ld      (V_SIZE),hl
                ld      a,SIZE_HI
                ld      (V_SIZE+2),a
                xor     a
                ld      (V_SIZE+3),a
                ld      hl,V_SIZE
                call    putdec32
                ld      hl,msg_blocks
                call    puts
                ld      hl,CARD_MB
                call    putdec_hl
                ld      hl,msg_mib
                call    puts
                call    pr_ok
                call    pr_diag                 ; FPGA diagnostics (SDHC, retries)

; ---- T3: read block 0, polled ----------------------------------------------------
t3:             ld      hl,msg_t3
                call    puts
                xor     a
                ld      (V_FAST),a
                call    lba_zero
                ld      hl,BUFA
                call    sd_read
                jr      nc,t3_ok
                call    pr_sderr
                jp      p1_done
t3_ok:          ld      hl,BUFA
                call    cksum512
                ld      hl,(V_SUM)
                ld      (V_SUM0),hl
                ld      hl,msg_sum
                call    puts
                ld      hl,(V_SUM)
                call    puthex16
                call    crlf
                ld      hl,BUFA                 ; dump first 32 bytes
                ld      b,32
                call    dump
                ld      hl,msg_mbr
                call    puts
                ld      a,(BUFA+510)
                call    puthex
                ld      a,(BUFA+511)
                call    puthex
                call    crlf
                call    pr_ok

; ---- T4: block 0 again with INIR (informational) ----------------------------------
                ld      hl,msg_t4
                call    puts
                ld      a,1
                ld      (V_FAST),a
                call    lba_zero
                ld      hl,BUFB
                call    sd_read
                jr      nc,t4_ok
                ld      a,(V_ERRC)              ; INIR outran the controller?
                cp      E_END                   ; (block left part-read)
                jr      nz,t4_err
                call    sd_drain                ; finish the block polled
                jr      c,t4_err
                jr      t4_diff
t4_err:         call    pr_sderr
                jp      p1_done
t4_ok:          call    cmp_ab
                jr      nz,t4_diff
                ld      a,1
                ld      (V_FASTOK),a
                call    pr_ok
                jr      t5
t4_diff:        ld      hl,msg_nofast           ; not a failure: stay polled
                call    puts

; ---- T5: last block, both ways ----------------------------------------------------
t5:             ld      hl,msg_t5
                call    puts
                ld      de,1
                call    lba_top                 ; V_LBA = size - 1
                call    read_both               ; NC = ok & identical
                jr      nc,t5_ok
                jp      p1_done
t5_ok:          call    print_lba_sum
                call    pr_ok

; ---- T6: blocks 1,2,4,8,... ----------------------------------------------------------
                ld      hl,msg_t6
                call    puts
                call    crlf
                call    lba_zero
                ld      a,1
                ld      (V_LBA),a
t6_loop:        call    lba_lt_size             ; carry if V_LBA < size
                jr      nc,t6_done
                call    read_both
                jr      nc,t6_ok
                jp      p1_done
t6_ok:          ld      hl,msg_indent
                call    puts
                call    print_lba_sum
                call    crlf
                ld      hl,(V_LBA)              ; next power of two
                add     hl,hl
                ld      (V_LBA),hl
                ld      a,(V_LBA+2)
                rla
                ld      (V_LBA+2),a
                ld      hl,(V_LBA)              ; shifted out of 24 bits?
                or      h
                or      l
                jr      nz,t6_loop
t6_done:        ld      hl,msg_t6e
                call    puts
                call    pr_ok

; ---- T7: block 0 unchanged after all of the above -------------------------------------
                ld      hl,msg_t7
                call    puts
                xor     a
                ld      (V_FAST),a
                call    lba_zero
                ld      hl,BUFB
                call    sd_read
                jr      c,t7_bad2
                ld      hl,BUFB
                call    cksum512
                ld      hl,(V_SUM)
                ld      de,(V_SUM0)
                or      a
                sbc     hl,de
                jr      nz,t7_bad3
                call    pr_ok
                jr      p1_done
t7_bad2:        call    pr_sderr
                jr      p1_done
t7_bad3:        ld      hl,msg_recbad
                call    puts
                call    pr_fail

; ---- end of phase 1 ----------------------------------------------------------------------
p1_done:        call    crlf
                ld      hl,(V_FAILS)
                ld      a,h
                or      l
                jr      z,p1_pass
                ld      hl,msg_p1bad
                call    puts
                ld      hl,(V_FAILS)
                call    putdec_hl
                call    crlf
                jp      finish
p1_pass:        ld      hl,msg_p1ok
                call    puts

; ---- prompt --------------------------------------------------------------------------------
                ld      de,NSECT
                call    lba_top
                ld      hl,V_LBA                ; V_BASE = size - NSECT
                ld      de,V_BASE
                ld      bc,4
                ldir
                ld      hl,msg_ask1
                call    puts
                ld      hl,V_BASE
                call    putdec32
                ld      hl,msg_ask2
                call    puts
                ld      hl,V_SIZE
                call    putdec32                ; (size, one past the last)
                ld      hl,msg_ask3
                call    puts
                call    getkey
                push    af
                call    putc
                call    crlf
                pop     af
                or      020h                    ; lower case
                cp      'y'
                jr      z,p2_go
                ld      hl,msg_nowr
                call    puts
                jp      finish

; ---- phase 2: write tests ------------------------------------------------------------------
p2_go:          ld      hl,msg_bk
                call    puts
                xor     a
                ld      (V_IDX),a
bk_loop:        call    set_lba_idx
                xor     a
                ld      (V_FAST),a
                ld      hl,BUFC
                call    sd_read
                jr      nc,bk_rd_ok
                call    pr_sderr
                jp      wr_nowrite              ; nothing written yet
bk_rd_ok:       call    set_ptr_idx
                ld      hl,BUFC
                call    out512_ptr              ; BUFC -> backup RAM
                call    set_ptr_idx
                ld      hl,BUFB
                call    in512_ptr               ; read it back
                call    cmp_cb
                jr      z,bk_same
                ld      hl,msg_bkbad
                call    puts
                call    pr_mismatch
                jp      wr_nowrite
bk_same:        ld      a,(V_IDX)
                inc     a
                ld      (V_IDX),a
                cp      NSECT
                jr      nz,bk_loop
                call    pr_ok

                xor     a
                ld      (V_PASSN),a
pass_loop:      call    mark_fails
                ld      hl,msg_wp
                call    puts
                ld      a,(V_PASSN)
                add     a,'1'
                call    putc
                ld      a,(V_PASSN)
                or      a
                ld      hl,msg_pat0
                jr      z,pl_msg
                ld      hl,msg_pat1
pl_msg:         call    puts
                xor     a
                ld      (V_IDX),a
wp_loop:        call    set_lba_idx             ; write ascending (polled)
                ld      hl,BUFA
                call    fill_pattern
                ld      hl,BUFA
                call    sd_write
                jr      nc,wp_ok
                call    pr_sderr
                jp      restore                 ; give up writing, restore
wp_ok:          ld      a,(V_IDX)
                inc     a
                ld      (V_IDX),a
                cp      NSECT
                jr      nz,wp_loop
                ld      hl,msg_vp
                call    puts
                ld      a,NSECT
                ld      (V_IDX),a
vp_loop:        ld      a,(V_IDX)               ; verify descending
                dec     a
                ld      (V_IDX),a
                call    set_lba_idx
                ld      a,(V_PASSN)             ; pass 2: INIR if T4 allowed
                ld      b,a
                ld      a,(V_FASTOK)
                and     b
                ld      (V_FAST),a
                ld      hl,BUFB
                call    sd_read
                jr      nc,vp_rd_ok
                call    pr_sderr
                jp      restore
vp_rd_ok:       ld      hl,BUFA
                call    fill_pattern
                call    cmp_ab
                jr      z,vp_same
                call    pr_mismatch_n
vp_same:        ld      a,(V_IDX)
                or      a
                jr      nz,vp_loop
                call    pr_result
                ld      a,(V_PASSN)
                inc     a
                ld      (V_PASSN),a
                cp      2
                jr      nz,pass_loop

; ---- restore the original contents -----------------------------------------------------
restore:        call    mark_fails
                ld      hl,msg_rs
                call    puts
                xor     a
                ld      (V_IDX),a
rs_loop:        call    set_lba_idx
                call    set_ptr_idx
                ld      hl,BUFC
                call    in512_ptr               ; original sector from backup
                ld      hl,BUFC
                call    sd_write
                jr      nc,rs_wr_ok
                call    pr_sderr
                jr      rs_next                 ; keep restoring the others
rs_wr_ok:       xor     a
                ld      (V_FAST),a
                ld      hl,BUFB
                call    sd_read
                jr      nc,rs_rd_ok
                call    pr_sderr
                jr      rs_next
rs_rd_ok:       call    cmp_cb
                jr      z,rs_next
                call    pr_mismatch_n
rs_next:        ld      a,(V_IDX)
                inc     a
                ld      (V_IDX),a
                cp      NSECT
                jr      nz,rs_loop
                call    pr_result
                jr      p2_done

wr_nowrite:     ld      hl,msg_nowrite          ; backup failed: nothing written
                call    puts

p2_done:        call    crlf
                ld      hl,(V_FAILS)
                ld      a,h
                or      l
                jr      nz,p2_bad
                ld      hl,msg_p2ok
                call    puts
                jr      finish
p2_bad:         ld      hl,msg_p2bad
                call    puts
                ld      hl,(V_FAILS)
                call    putdec_hl
                call    crlf

; ---- the end ---------------------------------------------------------------------------------
finish:         ld      hl,msg_end
                call    puts
fin_halt:       halt
                jr      fin_halt

; ============================================================================
; SD controller primitives
; ============================================================================

; wait_idle: wait for STATUS = 8xh (b6,b5,b4 clear). NC when idle, C = timeout.
wait_idle:
                ld      d,WAITOUTER
wi_o:           ld      bc,0
wi_i:           in      a,(SD_STAT)
                and     0F0h
                cp      080h
                ret     z                       ; (NC: cp of equal values)
                dec     bc
                ld      a,b
                or      c
                jr      nz,wi_i
                dec     d
                jr      nz,wi_o
                scf
                ret

; set_lba: write V_LBA (bits 23:0) to LBA0..2
set_lba:
                ld      a,(V_LBA)
                out     (SD_LBA0),a
                ld      a,(V_LBA+1)
                out     (SD_LBA1),a
                ld      a,(V_LBA+2)
                out     (SD_LBA2),a
                ret

; sd_read: read block V_LBA into the buffer at HL (V_FAST selects the mode).
; NC = ok, C = error with the code in V_ERRC.
sd_read:
                ld      (V_DEST),hl
                call    wait_idle
                ld      a,E_BUSY
                jr      c,sdr_fail
                call    set_lba
                xor     a
                out     (SD_STAT),a             ; command 00h = read block
                ld      d,WAITOUTER
sdr_o:          ld      bc,0
sdr_i:          in      a,(SD_STAT)
                and     0E0h
                cp      0E0h                    ; read byte available
                jr      z,sdr_data
                dec     bc
                ld      a,b
                or      c
                jr      nz,sdr_i
                dec     d
                jr      nz,sdr_o
                ld      a,E_CMDTMO
                jr      sdr_fail
sdr_data:       ld      hl,(V_DEST)
                ld      a,(V_FAST)
                or      a
                jr      nz,sdr_fast
                ld      de,512                  ; poll STATUS before each byte
sdr_pb:         ld      bc,0
sdr_pw:         in      a,(SD_STAT)
                and     0E0h
                cp      0E0h
                jr      z,sdr_pg
                dec     bc
                ld      a,b
                or      c
                jr      nz,sdr_pw
                ld      a,E_BYTETMO
                jr      sdr_fail
sdr_pg:         in      a,(SD_DATA)
                ld      (hl),a
                inc     hl
                dec     de
                ld      a,d
                or      e
                jr      nz,sdr_pb
                jr      sdr_end
sdr_fast:       ld      c,SD_DATA               ; no status checks at all
                ld      b,0
                inir
                inir
sdr_end:        call    wait_idle               ; back to idle (CRC read)...
                ld      a,E_END
                jr      c,sdr_fail
                in      a,(SD_STAT)
                cp      080h                    ; ...and nothing else set
                ld      a,E_END
                jr      nz,sdr_fail
                or      a                       ; NC
                ret
sdr_fail:       ld      (V_ERRC),a
                scf
                ret

; sd_write: write the buffer at HL to block V_LBA, polling STATUS before every
; byte (never block mode: a byte written while b7 is clear is lost).
; NC = ok, C = error with the code in V_ERRC. Returns after the card has
; finished programming the block (STATUS back to 80h).
sd_write:
                ld      (V_DEST),hl
                call    wait_idle
                ld      a,E_BUSY
                jr      c,sdw_fail
                call    set_lba
                ld      a,1
                out     (SD_STAT),a             ; command 01h = write block
                ld      d,WAITOUTER
sdw_o:          ld      bc,0
sdw_i:          in      a,(SD_STAT)
                and     0E0h
                cp      0A0h                    ; write byte accepted
                jr      z,sdw_data
                dec     bc
                ld      a,b
                or      c
                jr      nz,sdw_i
                dec     d
                jr      nz,sdw_o
                ld      a,E_CMDTMO
                jr      sdw_fail
sdw_data:       ld      hl,(V_DEST)
                ld      de,512
sdw_pb:         ld      bc,0
sdw_pw:         in      a,(SD_STAT)
                and     0E0h
                cp      0A0h
                jr      z,sdw_pg
                dec     bc
                ld      a,b
                or      c
                jr      nz,sdw_pw
                ld      a,E_BYTETMO
                jr      sdw_fail
sdw_pg:         ld      a,(hl)
                out     (SD_DATA),a
                inc     hl
                dec     de
                ld      a,d
                or      e
                jr      nz,sdw_pb
                call    wait_idle               ; card programming complete
                ld      a,E_END
                jr      c,sdw_fail
                in      a,(SD_STAT)
                cp      080h
                ld      a,E_END
                jr      nz,sdw_fail
                or      a
                ret
sdw_fail:       ld      (V_ERRC),a
                scf
                ret

; sd_drain: after a block-mode read that ended early, read and discard bytes
; with status polling until the controller is idle again.
; NC = idle again, C = gave up (controller wedged).
sd_drain:
                ld      de,1200                 ; more than a block + CRC
sdd_l:          ld      bc,0
sdd_w:          in      a,(SD_STAT)
                cp      080h
                ret     z                       ; idle (NC)
                and     040h                    ; byte available?
                jr      nz,sdd_g
                dec     bc
                ld      a,b
                or      c
                jr      nz,sdd_w
                scf                             ; nothing more is coming
                ret
sdd_g:          in      a,(SD_DATA)
                dec     de
                ld      a,d
                or      e
                jr      nz,sdd_l
                scf
                ret

; read_both: read V_LBA polled into BUFA, and (if T4 showed INIR works) with
; INIR into BUFB and compare.
; NC = ok and identical (V_SUM = checksum), C = failure (already reported).
read_both:
                xor     a
                ld      (V_FAST),a
                ld      hl,BUFA
                call    sd_read
                jr      c,rb_err
                ld      a,(V_FASTOK)
                or      a
                jr      z,rb_sum
                ld      a,1
                ld      (V_FAST),a
                ld      hl,BUFB
                call    sd_read
                jr      c,rb_err
                call    cmp_ab
                jr      nz,rb_mis
rb_sum:         ld      hl,BUFA
                call    cksum512
                or      a                       ; NC
                ret
rb_err:         call    pr_sderr
                scf
                ret
rb_mis:         call    pr_mismatch
                scf
                ret

; ============================================================================
; LBA / address helpers
; ============================================================================
lba_zero:       ld      hl,0
                ld      (V_LBA),hl
                ld      (V_LBA+2),hl
                ret

; lba_top: V_LBA = V_SIZE - DE
lba_top:
                ld      hl,(V_SIZE)
                or      a
                sbc     hl,de
                ld      (V_LBA),hl
                ld      a,(V_SIZE+2)
                sbc     a,0
                ld      (V_LBA+2),a
                xor     a
                ld      (V_LBA+3),a
                ret

; lba_lt_size: carry set if V_LBA < V_SIZE (24 bit)
lba_lt_size:
                ld      hl,(V_LBA)
                ld      de,(V_SIZE)
                or      a
                sbc     hl,de
                ld      a,(V_LBA+2)
                ld      hl,V_SIZE+2
                sbc     a,(hl)
                ret

; set_lba_idx: V_LBA = V_BASE + V_IDX
set_lba_idx:
                ld      a,(V_IDX)
                ld      e,a
                ld      d,0
                ld      hl,(V_BASE)
                add     hl,de
                ld      (V_LBA),hl
                ld      a,(V_BASE+2)
                adc     a,0
                ld      (V_LBA+2),a
                xor     a
                ld      (V_LBA+3),a
                ret

; set_ptr_idx: MMU direct-access pointer = 00400000h + V_IDX * 512
set_ptr_idx:
                ld      a,(V_IDX)
                add     a,a
                ld      b,a
                xor     a
                out     (MMU_PTR0),a
                ld      a,b
                out     (MMU_PTR1),a
                ld      a,BKP_HI
                out     (MMU_PTR2),a
                xor     a
                out     (MMU_PTR3),a
                ret

out512_ptr:     ld      c,MMU_DAT               ; 512 bytes (HL) -> physical RAM
                ld      b,0
                otir
                otir
                ret

in512_ptr:      ld      c,MMU_DAT               ; physical RAM -> 512 bytes (HL)
                ld      b,0
                inir
                inir
                ret

; ============================================================================
; data helpers
; ============================================================================

; fill_pattern: fill the 512 bytes at HL with the pattern for sector V_LBA
; and pass V_PASSN: a ramp whose start depends on the LBA, with the second
; 256 bytes offset by 5Bh (so address bit 8 matters); inverted on pass 1.
fill_pattern:
                ld      a,(V_LBA)
                ld      b,a
                add     a,a
                add     a,a
                add     a,a
                sub     b                       ; LBA0 * 7
                ld      b,a
                ld      a,(V_LBA+1)
                rlca
                rlca
                rlca
                add     a,b
                add     a,011h
                ld      c,a                     ; C = first byte
                ld      e,0                     ; E = invert mask
                ld      a,(V_PASSN)
                or      a
                jr      z,fp_m
                dec     e                       ; 0FFh
fp_m:           ld      b,0                     ; 256
fp_1:           ld      a,c
                xor     e
                ld      (hl),a
                inc     hl
                inc     c
                djnz    fp_1
                ld      a,c                     ; C is back at the first byte
                add     a,05Bh
                ld      c,a
                ld      b,0
fp_2:           ld      a,c
                xor     e
                ld      (hl),a
                inc     hl
                inc     c
                djnz    fp_2
                ret

; cmp512: compare the 512 bytes at HL (reference) and DE. Z = identical.
; On a difference NZ and V_MOFF / V_MEXP / V_MACT describe the first one.
cmp_ab:         ld      hl,BUFA
                ld      de,BUFB
                jr      cmp512
cmp_cb:         ld      hl,BUFC
                ld      de,BUFB
cmp512:
                ld      bc,512
cm_l:           ld      a,(de)
                cp      (hl)
                jr      nz,cm_diff
                inc     hl
                inc     de
                dec     bc
                ld      a,b
                or      c
                jr      nz,cm_l
                xor     a                       ; Z
                ret
cm_diff:        ld      (V_MACT),a
                ld      a,(hl)
                ld      (V_MEXP),a
                ld      hl,512
                or      a
                sbc     hl,bc
                ld      (V_MOFF),hl
                ld      a,1
                or      a                       ; NZ
                ret

; cksum512: V_SUM = position-dependent 16-bit checksum of the 512 bytes at HL:
; s = rotate-left-1(s) + byte (16 bit, wrapping), starting at 0. Same on the host:
;   python3 -c 'import sys;s=0
;   for b in sys.stdin.buffer.read(512): s=((((s<<1)|(s>>15))&65535)+b)&65535
;   print("%04X"%s)' < block.bin
cksum512:
                ex      de,hl                   ; DE = data pointer
                ld      hl,0                    ; HL = s
                ld      bc,512
ck_l:           add     hl,hl                   ; rotate left 1 (bit 15 -> bit 0)
                jr      nc,ck_n
                inc     l
ck_n:           ld      a,(de)
                add     a,l
                ld      l,a
                jr      nc,ck_nc
                inc     h
ck_nc:          inc     de
                dec     bc
                ld      a,b
                or      c
                jr      nz,ck_l
                ld      (V_SUM),hl
                ret

; dump: print B bytes at HL as hex, 16 per line
dump:
                ld      c,16
dp_l:           ld      a,(hl)
                call    puthex
                ld      a,' '
                call    putc
                inc     hl
                dec     c
                jr      nz,dp_n
                call    crlf
                ld      c,16
dp_n:           djnz    dp_l
                ret

; print_lba_sum: " LBA <n>  sum xxxx" (uses V_SUM)
print_lba_sum:
                ld      hl,msg_lba
                call    puts
                ld      hl,V_LBA
                call    putdec32
                ld      hl,msg_sum
                call    puts
                ld      hl,(V_SUM)
                jp      puthex16

; ============================================================================
; result reporting
; ============================================================================

; pr_diag: show the controller's diagnostic registers (8Dh-8Fh)
;   8Dh = FSM state number, 8Eh = next step (10h/03h = waiting for the response
;   to CMD0, 10h/04h = CMD8, 10h/05h = CMD55, 10h/06h = ACMD41, ...)
;   8Fh: b7 MISO (live), b6 CS, b5 SCLK, b4 SDHC, b3 card detect from the
;   MiSTer framework (1 = no card seen), b2:0 init restarts since reset
pr_diag:
                in      a,(SD_DG5)
                ld      b,a
                in      a,(SD_DG6)
                ld      c,a
                in      a,(SD_DG7)
                ld      d,a
                or      b
                or      c
                jr      nz,pdg_have
                ld      hl,msg_dgnone           ; reads 0: older FPGA build
                jp      puts
pdg_have:       ld      hl,msg_dg1
                call    puts
                ld      a,b
                call    puthex
                ld      hl,msg_dg2
                call    puts
                ld      a,c
                call    puthex
                ld      hl,msg_dg3
                call    puts
                ld      a,d
                call    puthex
                ld      a,'h'
                call    putc
                call    crlf
                ld      hl,msg_dg4              ; "  MISO="
                call    puts
                ld      a,080h
                call    pdg_bit
                ld      hl,msg_dg5              ; " CS="
                call    puts
                ld      a,040h
                call    pdg_bit
                ld      hl,msg_dg6              ; " SCLK="
                call    puts
                ld      a,020h
                call    pdg_bit
                ld      hl,msg_dg7              ; " SDHC="
                call    puts
                ld      a,010h
                call    pdg_bit
                ld      hl,msg_dg8              ; " CD="
                call    puts
                ld      a,008h
                call    pdg_bit
                ld      hl,msg_dg9              ; " init restarts="
                call    puts
                ld      a,d
                and     007h
                add     a,'0'
                call    putc
                call    crlf
                in      a,(SD_STAT)             ; hint only if init is stuck
                and     010h
                ret     z
                bit     3,d                     ; card detect high?
                ret     z
                ld      hl,msg_dgcd
                jp      puts

; pdg_bit: print '1' or '0' for the bits of D selected by the mask in A
pdg_bit:
                and     d
                ld      a,'0'
                jr      z,pdg_b0
                inc     a
pdg_b0:         jp      putc
pr_ok:          ld      hl,msg_okc
                jp      puts

pr_fail:        ld      hl,msg_failc
                call    puts
                jr      inc_fails

; pr_sderr: report an sd_read / sd_write error
pr_sderr:       ld      hl,msg_sderr
                call    puts
                ld      a,(V_ERRC)
                call    puthex
                ld      hl,msg_stat
                call    puts
                in      a,(SD_STAT)
                call    puthex
                ld      hl,msg_lbaeq
                call    puts
                ld      hl,V_LBA
                call    putdec32
                call    crlf
                ld      a,(V_ERRC)              ; "controller hung" hint
                cp      E_BUSY
                jr      z,pse_hint
                cp      E_CMDTMO
                jr      nz,inc_fails
pse_hint:       ld      hl,msg_hung
                call    puts
                jr      inc_fails

; pr_mismatch: first-difference details after a failed cmp512
pr_mismatch:    ld      hl,msg_failc2
                call    puts
                call    mm_detail
                jr      inc_fails

; pr_mismatch_n: same, but as a numbered line inside the write test; only
; the first few are printed in full
pr_mismatch_n:  ld      a,(V_PRT)
                cp      8
                jr      nc,inc_fails
                inc     a
                ld      (V_PRT),a
                ld      hl,msg_mm
                call    puts
                call    mm_detail
                jr      inc_fails

mm_detail:      ld      hl,msg_off
                call    puts
                ld      hl,(V_MOFF)
                call    puthex16
                ld      hl,msg_exp
                call    puts
                ld      a,(V_MEXP)
                call    puthex
                ld      hl,msg_act
                call    puts
                ld      a,(V_MACT)
                call    puthex
                ld      hl,msg_lbaeq
                call    puts
                ld      hl,V_LBA
                call    putdec32
                call    crlf
                ret

; mark_fails / pr_result: print OK only if no failure was counted since
; the mark was taken
mark_fails:     ld      hl,(V_FAILS)
                ld      (V_FMARK),hl
                ret

pr_result:      ld      hl,(V_FAILS)
                ld      de,(V_FMARK)
                or      a
                sbc     hl,de
                jr      z,pr_ok
                ld      hl,msg_failc
                jp      puts

inc_fails:      ld      hl,(V_FAILS)
                inc     hl
                ld      (V_FAILS),hl
                ret

; ============================================================================
; console: output to the video terminal AND the serial port, input from either
; ============================================================================
putc:
                push    af
pc_w1:          in      a,(CON_STAT)
                and     TDRE
                jr      z,pc_w1
                pop     af
                out     (CON_DATA),a
                push    af
pc_w2:          in      a,(SER_STAT)
                and     TDRE
                jr      z,pc_w2
                pop     af
                out     (SER_DATA),a
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

puthex:         push    af
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

puthex16:       ld      a,h
                call    puthex
                ld      a,l
                jp      puthex

; putdec_hl: print HL as an unsigned decimal number
putdec_hl:
                ld      (V_TMP),hl
                xor     a
                ld      (V_TMP+2),a
                ld      (V_TMP+3),a
                ld      hl,V_TMP
                ; fall through

; putdec32: print the 32-bit unsigned value at (HL) in decimal
putdec32:
                ld      de,V_NUM
                ld      bc,4
                ldir
                ld      c,0
pd_loop:        call    div10
                add     a,'0'
                push    af
                inc     c
                ld      hl,V_NUM
                call    iszero32
                jr      nz,pd_loop
pd_out:         pop     af
                call    putc
                dec     c
                jr      nz,pd_out
                ret

iszero32:       ld      a,(hl)
                inc     hl
                or      (hl)
                inc     hl
                or      (hl)
                inc     hl
                or      (hl)
                ret

; div10: V_NUM /= 10, A = remainder. Clobbers B, HL.
div10:
                xor     a
                ld      b,32
d10_l:          ld      hl,V_NUM
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
                ld      hl,V_NUM
                inc     (hl)
d10_n:          djnz    d10_l
                ret

; getkey: wait for a character from either console; returns it in A
getkey:
gk_flush:       in      a,(SER_STAT)            ; discard pending input
                and     RDRF
                jr      z,gk_f2
                in      a,(SER_DATA)
                jr      gk_flush
gk_f2:          in      a,(CON_STAT)
                and     RDRF
                jr      z,gk_wait
                in      a,(CON_DATA)
                jr      gk_flush
gk_wait:        in      a,(SER_STAT)
                and     RDRF
                jr      z,gk_w2
                in      a,(SER_DATA)
                ret
gk_w2:          in      a,(CON_STAT)
                and     RDRF
                jr      z,gk_wait
                in      a,(CON_DATA)
                ret

; ============================================================================
; messages
; ============================================================================
msg_banner:     defb    0Dh,0Ah
                defm    'SPI SD card controller end-to-end test (ports 88h-8Fh)'
                defb    0Dh,0Ah
                defm    'Phase 1: read tests (non-destructive)'
                defb    0Dh,0Ah,0
msg_t1:         defm    'T1 status register = '
                defb    0
msg_initw:      defm    '  card initialising, waiting...'
                defb    0Dh,0Ah,0
msg_inited:     defm    'T1 card initialised, status = '
                defb    0
msg_nocard:     defm    'T1 NO CARD: init never finished, status = '
                defb    0
msg_t2:         defm    'T2 assumed capacity (CARD_MB, not detectable) = '
                defb    0
msg_blocks:     defm    ' blocks ('
                defb    0
msg_mib:        defm    ' MiB)'
                defb    0
msg_dgnone:     defm    '  (no diagnostic registers: older FPGA build)'
                defb    0Dh,0Ah,0
msg_dg1:        defm    '  FPGA diagnostics: state '
                defb    0
msg_dg2:        defm    'h next step '
                defb    0
msg_dg3:        defm    'h pins '
                defb    0
msg_dg4:        defm    '  MISO='
                defb    0
msg_dg5:        defm    ' CS='
                defb    0
msg_dg6:        defm    ' SCLK='
                defb    0
msg_dg7:        defm    ' SDHC='
                defb    0
msg_dg8:        defm    ' CD='
                defb    0
msg_dg9:        defm    ' init restarts='
                defb    0
msg_dgcd:       defm    '  CD=1: the MiSTer framework sees NO card in the secondary SD socket'
                defb    0Dh,0Ah
                defm    '  (it then forces MISO high and tri-states the SPI pins)'
                defb    0Dh,0Ah,0
msg_t3:         defm    'T3 read LBA 0, polled per byte'
                defb    0Dh,0Ah,0
msg_sum:        defm    '  sum '
                defb    0
msg_mbr:        defm    '  MBR signature bytes (55AA expected for a partitioned card): '
                defb    0
msg_t4:         defm    'T4 read LBA 0 again, INIR back-to-back, same data?'
                defb    0
msg_nofast:     defm    '  INFO: INIR differs, so reads are polled only from here'
                defb    0Dh,0Ah,0
msg_t5:         defm    'T5 last block (polled, plus INIR if T4 passed)'
                defb    0
msg_t6:         defm    'T6 blocks 2^n (polled, plus INIR if T4 passed)'
                defb    0
msg_t6e:        defm    'T6 done'
                defb    0
msg_indent:     defm    '   '
                defb    0
msg_lba:        defm    ' LBA '
                defb    0
msg_t7:         defm    'T7 LBA 0 unchanged after all of the above'
                defb    0
msg_recbad:     defm    '  data differs from the first read of block 0'
                defb    0
msg_okc:        defm    '  ... OK'
                defb    0Dh,0Ah,0
msg_failc:      defm    '  ... FAIL'
                defb    0Dh,0Ah,0
msg_failc2:     defm    '  ... FAIL:'
                defb    0
msg_sderr:      defm    '  *** FAIL: device error '
                defb    0
msg_stat:       defm    ' status '
                defb    0
msg_lbaeq:      defm    ' LBA '
                defb    0
msg_hung:       defm    '  (the controller waits forever if the card does not answer, e.g.'
                defb    0Dh,0Ah
                defm    '   LBA beyond the real card size: lower CARD_MB; reset the core to recover)'
                defb    0Dh,0Ah,0
msg_mm:         defm    '  *** MISMATCH'
                defb    0
msg_off:        defm    ' at offset '
                defb    0
msg_exp:        defm    ' expected '
                defb    0
msg_act:        defm    ' got '
                defb    0
msg_p1ok:       defm    'READ TESTS PASSED'
                defb    0Dh,0Ah,0
msg_p1bad:      defm    'READ TESTS FAILED, failures: '
                defb    0
msg_ask1:       defm    'Phase 2: WRITE tests on the sectors at the top of CARD_MB,'
                defb    0Dh,0Ah
                defm    'LBA '
                defb    0
msg_ask2:       defm    ' up to '
                defb    0
msg_ask3:       defm    ' (exclusive).'
                defb    0Dh,0Ah
                defm    'The original contents are backed up to RAM and restored afterwards.'
                defb    0Dh,0Ah
                defm    'Do NOT reset or power off during the test.'
                defb    0Dh,0Ah
                defm    'Proceed with the write tests? (y/N) '
                defb    0
msg_nowr:       defm    'Write tests skipped.'
                defb    0Dh,0Ah,0
msg_bk:         defm    'W1 backing up the sectors to RAM'
                defb    0
msg_bkbad:      defm    '  backup verify failed:'
                defb    0
msg_wp:         defm    'W2 pattern '
                defb    0
msg_pat0:       defm    ' write ascending (polled)'
                defb    0Dh,0Ah,0
msg_pat1:       defm    ' (inverted) write ascending (polled)'
                defb    0Dh,0Ah,0
msg_vp:         defm    '   read back descending and compare'
                defb    0Dh,0Ah,0
msg_rs:         defm    'W3 restoring the original sectors and verifying'
                defb    0Dh,0Ah,0
msg_nowrite:    defm    'Backup failed: nothing was written to the card.'
                defb    0Dh,0Ah,0
msg_p2ok:       defm    'WRITE TESTS PASSED (original contents restored)'
                defb    0Dh,0Ah,0
msg_p2bad:      defm    'WRITE TESTS FAILED, failures: '
                defb    0
msg_end:        defm    'Done. Reset the core to run again.'
                defb    0Dh,0Ah,0

                end

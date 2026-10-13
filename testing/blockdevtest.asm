; ============================================================================
; blockdevtest.asm - end-to-end test of the HPS image-backed block device
;                    (hps_blockdev, I/O ports 90h-97h)
; ----------------------------------------------------------------------------
; PURPOSE
;   Validates the whole chain Z-80 -> hps_blockdev -> hps_io -> Linux image
;   file, in two phases.
;
;   Phase 1 - READ tests (non-destructive, always run):
;     T1  STATUS reads "idle" (80h/88h) once an image is mounted (waits if
;         none is mounted yet: STATUS b4 set = 90h)
;     T2  SIZE registers (95h-97h) are non-zero and stable; prints the size
;     T3  read block 0, one byte at a time, polling STATUS before each byte
;         (the way a driver written for sd_controller would); hex dump
;     T4  read block 0 again with INIR (block transfer) - must be identical
;     T5  read the LAST block (size-1) both ways - must be identical
;     T6  read blocks 1,2,4,8,... (each power of two below the size), each
;         both ways - must be identical (exercises every LBA bit)
;     T7  out-of-range LBA (size and FFFFFFh) must be REJECTED (STATUS b2),
;         and the next good read must clear the error
;   If everything passes the program asks whether to go on.
;
;   Phase 2 - WRITE tests (destructive, asks first; skipped for a read-only
;   image or one smaller than NSECT blocks):
;     the NSECT (100) sectors at the top of the device are
;       1. backed up to physical RAM at 400000h (read back and verified),
;       2. written with a per-sector pattern, then read back in the OPPOSITE
;          order and compared (catches cross-sector aliasing); done twice,
;          the second time with all bits inverted, alternating poll mode
;          and block mode for the writes/reads,
;       3. restored from the backup and verified.
;     So the image ends up unchanged even though it was written to.
;
; USAGE
;   Load the .BIN with the OSD "Boot Rom Image" entry (SDRAM target) and
;   mount a disk image with the "SD card image" entry (S,IMG). Output goes
;   to BOTH the video terminal (ports 80h/81h) and the serial console
;   (82h/83h); answer the prompt from either keyboard.
;
; BUILD
;   make -C testing blockdevtest.bin   (or tools/z80asm.sh testing/blockdevtest.asm)
;
; SIMULATION
;   Assembled with -D SIM (sim/run_blockdev_prog.sh does this): NSECT = 2,
;   no waiting on the console (characters are written straight to port 83h,
;   where the testbench captures them), the prompt answers 'y' by itself,
;   and the final PASS/FAIL result is also stored at 3FF0h (0 = pass, else
;   the number of failures, saturating) with 0AAh at 3FF8h.
; ============================================================================

                .z80
                aseg
                org     0000h

; ---- configuration ---------------------------------------------------------
                IFDEF   SIM
NSECT           equ     2               ; sectors in the write test (GHDL)
WAITOUTER       equ     2               ; timeout = WAITOUTER * 65536 polls
                ELSE
NSECT           equ     100             ; sectors in the write test
WAITOUTER       equ     24              ; ~ 15 s per wait at 10 MHz
                ENDIF
                IFDEF   SIM
RESULT          equ     3FF0h           ; testbench result (0 = pass)
DONE_FLAG       equ     3FF8h           ; 0AAh when finished
                ENDIF
BKP_HI          equ     040h            ; backup area physical 00400000h
                                        ; (+ sector index * 512)

; ---- ports -------------------------------------------------------------------
CON_STAT        equ     080h            ; video terminal (6850-like)
CON_DATA        equ     081h
SER_STAT        equ     082h            ; serial console (6850 ACIA)
SER_DATA        equ     083h
TDRE            equ     002h
RDRF            equ     001h

BD_DATA         equ     090h            ; hps_blockdev
BD_STAT         equ     091h            ;   read: status   write: command
BD_LBA0         equ     092h
BD_LBA1         equ     093h
BD_LBA2         equ     094h
BD_SZ0          equ     095h
BD_SZ1          equ     096h
BD_SZ2          equ     097h

MMU_PTR0        equ     0B8h            ; MMU direct-access pointer
MMU_PTR1        equ     0B9h
MMU_PTR2        equ     0BAh
MMU_PTR3        equ     0BBh
MMU_DAT         equ     0BCh            ; direct-access data port

; ---- bd_* error codes (V_ERRC) ---------------------------------------------
E_BUSY          equ     1               ; device not idle at start
E_REJ           equ     2               ; command rejected (STATUS b2)
E_CMDTMO        equ     3               ; no completion / no data ready
E_BYTETMO       equ     4               ; byte-ready timeout in poll mode
E_END           equ     5               ; not idle / error flag after block

; ---- memory (all in frame 0, below 4000h) ----------------------------------
BUFA            equ     2000h
BUFB            equ     2200h
BUFC            equ     2400h
STACK           equ     3F00h

V_BASE          equ     3000h           ; 4  base LBA of the write test
V_SIZE          equ     3004h           ; 4  image size, blocks
V_LBA           equ     3008h           ; 4  current LBA (bits 31:24 = 0)
V_NUM           equ     300Ch           ; 4  putdec32 scratch
V_TMP           equ     3010h           ; 4  scratch
V_DEST          equ     3014h           ; 2  bd_read/bd_write buffer pointer
V_FAILS         equ     3016h           ; 2  failure count
V_MOFF          equ     3018h           ; 2  cmp512: offset of first difference
V_SUM           equ     301Ah           ; 2  cksum512 result
V_FAST          equ     301Ch           ; 1  0 = poll per byte, 1 = INIR/OTIR
V_ERRC          equ     301Dh           ; 1  last bd_* error code
V_IDX           equ     301Eh           ; 1  sector index in the write test
V_PASSN         equ     301Fh           ; 1  write-test pattern (0 / 1)
V_MEXP          equ     3020h           ; 1  cmp512: expected byte
V_MACT          equ     3021h           ; 1  cmp512: actual byte
V_PRT           equ     3022h           ; 1  detailed mismatch lines printed
V_RO            equ     3023h           ; 1  image is read-only
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

; ---- T1: status ---------------------------------------------------------------
                ld      hl,msg_t1
                call    puts
                in      a,(BD_STAT)
                call    puthex
                in      a,(BD_STAT)
                and     010h
                jr      z,t1_mounted
                ld      hl,msg_nomount          ; no image yet: wait for one
                call    puts
t1_wait:        in      a,(BD_STAT)
                and     010h
                jr      nz,t1_wait
                ld      hl,msg_nowmnt
                call    puts
                in      a,(BD_STAT)
                call    puthex
t1_mounted:     in      a,(BD_STAT)
                ld      b,a
                and     008h                    ; b3 = read-only image
                ld      (V_RO),a
                ld      a,b
                and     0F7h                    ; ignore b3
                cp      080h
                jr      nz,t1_bad
                ld      a,(V_RO)
                or      a
                jr      z,t1_rw
                ld      hl,msg_ro
                call    puts
t1_rw:          call    pr_ok
                jr      t2
t1_bad:         call    pr_fail
                jp      p1_done                 ; no point going on

; ---- T2: size -----------------------------------------------------------------
t2:             ld      hl,msg_t2
                call    puts
                call    read_size               ; V_SIZE
                ld      hl,V_SIZE
                call    putdec32
                ld      hl,msg_blocks
                call    puts
                ld      hl,(V_SIZE+1)           ; bits 23:8 -> MiB = /2048
                srl     h
                rr      l
                srl     h
                rr      l
                srl     h
                rr      l
                call    putdec_hl
                ld      hl,msg_mib
                call    puts
                ld      hl,V_SIZE               ; saturated at FFFFFFh?
                ld      a,(hl)
                inc     hl
                and     (hl)
                inc     hl
                and     (hl)
                cp      0FFh
                jr      nz,t2_nsat
                ld      hl,msg_sat
                call    puts
t2_nsat:        ld      hl,(V_SIZE)             ; zero?
                ld      a,(V_SIZE+2)
                or      h
                or      l
                jr      nz,t2_nz
                call    pr_fail
                jp      p1_done
t2_nz:          ld      hl,V_SIZE               ; stable? read again, compare
                ld      de,V_TMP
                ld      bc,4
                ldir
                call    read_size
                ld      hl,V_SIZE
                ld      de,V_TMP
                ld      b,4
t2_cmp:         ld      a,(de)
                cp      (hl)
                jr      nz,t2_bad
                inc     hl
                inc     de
                djnz    t2_cmp
                call    pr_ok
                jr      t3
t2_bad:         call    pr_fail
                jp      p1_done

; ---- T3: read block 0, polled ----------------------------------------------------
t3:             ld      hl,msg_t3
                call    puts
                xor     a
                ld      (V_FAST),a
                call    lba_zero
                ld      hl,BUFA
                call    bd_read
                jr      nc,t3_ok
                call    pr_bderr
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
                call    pr_ok

; ---- T4: block 0 again with INIR; must be identical ----------------------------
                ld      hl,msg_t4
                call    puts
                ld      a,1
                ld      (V_FAST),a
                call    lba_zero
                ld      hl,BUFB
                call    bd_read
                jr      nc,t4_ok
                call    pr_bderr
                jp      p1_done
t4_ok:          call    cmp_ab
                jr      z,t4_same
                call    pr_mismatch
                jp      p1_done
t4_same:        call    pr_ok

; ---- T5: last block, both ways ----------------------------------------------------
                ld      hl,msg_t5
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

; ---- T7: out-of-range LBA rejected ----------------------------------------------------
                ld      hl,msg_t7
                call    puts
                ld      hl,(V_SIZE)             ; LBA = size
                ld      (V_LBA),hl
                ld      a,(V_SIZE+2)
                ld      (V_LBA+2),a
                call    expect_reject
                jr      nz,t7_bad
                ld      hl,0FFFFh               ; LBA = FFFFFFh
                ld      (V_LBA),hl
                ld      a,0FFh
                ld      (V_LBA+2),a
                call    expect_reject
                jr      nz,t7_bad
                ld      a,1                     ; then a good read must work
                ld      (V_FAST),a
                call    lba_zero
                ld      hl,BUFB
                call    bd_read                 ; (also checks the error flag
                jr      c,t7_bad2               ;  was cleared: E_END otherwise)
                ld      hl,BUFB                 ; must be block 0 again
                call    cksum512
                ld      hl,(V_SUM)
                ld      de,(V_SUM0)
                or      a
                sbc     hl,de
                jr      nz,t7_bad3
                call    pr_ok
                jr      p1_done
t7_bad:         ld      hl,msg_notrej
                call    puts
                call    pr_fail
                jr      p1_done
t7_bad2:        call    pr_bderr
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

                ld      a,(V_RO)                ; write phase possible?
                or      a
                jr      z,p2_ro_ok
                ld      hl,msg_skipro
                call    puts
                jp      finish
p2_ro_ok:       ld      a,(V_SIZE+2)            ; size >= NSECT ?
                or      a
                jr      nz,p2_big
                ld      hl,(V_SIZE)
                ld      de,NSECT
                or      a
                sbc     hl,de
                jr      nc,p2_big
                ld      hl,msg_small
                call    puts
                jp      finish
p2_big:

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
                ld      a,1
                ld      (V_FAST),a
                ld      hl,BUFC
                call    bd_read
                jr      nc,bk_rd_ok
                call    pr_bderr
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
wp_loop:        call    set_lba_idx             ; write ascending
                ld      hl,BUFA
                call    fill_pattern
                ld      a,(V_PASSN)             ; pass 1: poll, pass 2: block
                ld      (V_FAST),a
                ld      hl,BUFA
                call    bd_write
                jr      nc,wp_ok
                call    pr_bderr
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
                ld      a,(V_PASSN)             ; opposite mode to the write
                xor     1
                ld      (V_FAST),a
                ld      hl,BUFB
                call    bd_read
                jr      nc,vp_rd_ok
                call    pr_bderr
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
                ld      a,1
                ld      (V_FAST),a
                ld      hl,BUFC
                call    bd_write
                jr      nc,rs_wr_ok
                call    pr_bderr
                jr      rs_next                 ; keep restoring the others
rs_wr_ok:       xor     a
                ld      (V_FAST),a
                ld      hl,BUFB
                call    bd_read
                jr      nc,rs_rd_ok
                call    pr_bderr
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
                IFDEF   SIM
                ld      hl,(V_FAILS)            ; result for the testbench
                ld      a,l
                or      a
                jr      nz,fin_r
                ld      a,h
                or      a
                jr      z,fin_r
                ld      a,0FFh
fin_r:          ld      (RESULT),a
                ld      a,0AAh
                ld      (DONE_FLAG),a
                ENDIF
fin_halt:       halt
                jr      fin_halt

; ============================================================================
; block device primitives
; ============================================================================

; read_size: V_SIZE (4 bytes) = SIZE0..2 registers
read_size:
                in      a,(BD_SZ0)
                ld      (V_SIZE),a
                in      a,(BD_SZ1)
                ld      (V_SIZE+1),a
                in      a,(BD_SZ2)
                ld      (V_SIZE+2),a
                xor     a
                ld      (V_SIZE+3),a
                ret

; wait_idle: wait for STATUS = 8xh (b6,b5,b4 clear). NC when idle, C = timeout.
wait_idle:
                ld      d,WAITOUTER
wi_o:           ld      bc,0
wi_i:           in      a,(BD_STAT)
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
                out     (BD_LBA0),a
                ld      a,(V_LBA+1)
                out     (BD_LBA1),a
                ld      a,(V_LBA+2)
                out     (BD_LBA2),a
                ret

; bd_read: read block V_LBA into the buffer at HL (V_FAST selects the mode).
; NC = ok, C = error with the code in V_ERRC.
bd_read:
                ld      (V_DEST),hl
                call    wait_idle
                ld      a,E_BUSY
                jr      c,bdr_fail
                call    set_lba
                xor     a
                out     (BD_STAT),a             ; command 00h = read block
                ld      d,WAITOUTER
bdr_o:          ld      bc,0
bdr_i:          in      a,(BD_STAT)
                ld      e,a
                and     0E0h
                cp      0E0h                    ; read byte available
                jr      z,bdr_data
                ld      a,e
                and     0F4h
                cp      084h                    ; idle + error flag: rejected
                jr      z,bdr_rej
                dec     bc
                ld      a,b
                or      c
                jr      nz,bdr_i
                dec     d
                jr      nz,bdr_o
                ld      a,E_CMDTMO
                jr      bdr_fail
bdr_rej:        ld      a,E_REJ
                jr      bdr_fail
bdr_data:       ld      hl,(V_DEST)
                ld      a,(V_FAST)
                or      a
                jr      nz,bdr_fast
                ld      de,512                  ; poll STATUS before each byte
bdr_pb:         ld      bc,0
bdr_pw:         in      a,(BD_STAT)
                and     0E0h
                cp      0E0h
                jr      z,bdr_pg
                dec     bc
                ld      a,b
                or      c
                jr      nz,bdr_pw
                ld      a,E_BYTETMO
                jr      bdr_fail
bdr_pg:         in      a,(BD_DATA)
                ld      (hl),a
                inc     hl
                dec     de
                ld      a,d
                or      e
                jr      nz,bdr_pb
                jr      bdr_end
bdr_fast:       ld      c,BD_DATA
                ld      b,0
                inir
                inir
bdr_end:        call    wait_idle               ; back to idle...
                ld      a,E_END
                jr      c,bdr_fail
                in      a,(BD_STAT)
                and     0F4h                    ; ...with no error flag
                cp      080h
                ld      a,E_END
                jr      nz,bdr_fail
                or      a                       ; NC
                ret
bdr_fail:       ld      (V_ERRC),a
                scf
                ret

; bd_write: write the buffer at HL to block V_LBA (V_FAST selects the mode).
; NC = ok, C = error with the code in V_ERRC. Returns after the HPS has
; finished writing the block to the image.
bd_write:
                ld      (V_DEST),hl
                call    wait_idle
                ld      a,E_BUSY
                jr      c,bdw_fail
                call    set_lba
                ld      a,1
                out     (BD_STAT),a             ; command 01h = write block
                ld      d,WAITOUTER
bdw_o:          ld      bc,0
bdw_i:          in      a,(BD_STAT)
                ld      e,a
                and     0E0h
                cp      0A0h                    ; write byte accepted
                jr      z,bdw_data
                ld      a,e
                and     0F4h
                cp      084h
                jr      z,bdw_rej
                dec     bc
                ld      a,b
                or      c
                jr      nz,bdw_i
                dec     d
                jr      nz,bdw_o
                ld      a,E_CMDTMO
                jr      bdw_fail
bdw_rej:        ld      a,E_REJ
                jr      bdw_fail
bdw_data:       ld      hl,(V_DEST)
                ld      a,(V_FAST)
                or      a
                jr      nz,bdw_fast
                ld      de,512
bdw_pb:         ld      bc,0
bdw_pw:         in      a,(BD_STAT)
                and     0E0h
                cp      0A0h
                jr      z,bdw_pg
                dec     bc
                ld      a,b
                or      c
                jr      nz,bdw_pw
                ld      a,E_BYTETMO
                jr      bdw_fail
bdw_pg:         ld      a,(hl)
                out     (BD_DATA),a
                inc     hl
                dec     de
                ld      a,d
                or      e
                jr      nz,bdw_pb
                jr      bdw_end
bdw_fast:       ld      c,BD_DATA
                ld      b,0
                otir
                otir
bdw_end:        call    wait_idle               ; HPS write complete
                ld      a,E_END
                jr      c,bdw_fail
                in      a,(BD_STAT)
                and     0F4h
                cp      080h
                ld      a,E_END
                jr      nz,bdw_fail
                or      a
                ret
bdw_fail:       ld      (V_ERRC),a
                scf
                ret

; expect_reject: read V_LBA, which must be REJECTED. Z = rejected as expected.
expect_reject:
                xor     a
                ld      (V_FAST),a
                ld      hl,BUFC
                call    bd_read
                jr      c,er_err
                ld      a,1                     ; the read worked: NZ
                or      a
                ret
er_err:         ld      a,(V_ERRC)
                cp      E_REJ                   ; Z = rejected
                ret

; read_both: read V_LBA polled into BUFA then block mode into BUFB; compare.
; NC = ok and identical (V_SUM = checksum), C = failure (already reported).
read_both:
                xor     a
                ld      (V_FAST),a
                ld      hl,BUFA
                call    bd_read
                jr      c,rb_err
                ld      a,1
                ld      (V_FAST),a
                ld      hl,BUFB
                call    bd_read
                jr      c,rb_err
                call    cmp_ab
                jr      nz,rb_mis
                ld      hl,BUFA
                call    cksum512
                or      a                       ; NC
                ret
rb_err:         call    pr_bderr
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
ck_nc:                inc     de
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
pr_ok:          ld      hl,msg_okc
                jp      puts

pr_fail:        ld      hl,msg_failc
                call    puts
                jr      inc_fails

; pr_bderr: report a bd_read / bd_write error
pr_bderr:       ld      hl,msg_bderr
                call    puts
                ld      a,(V_ERRC)
                call    puthex
                ld      hl,msg_stat
                call    puts
                in      a,(BD_STAT)
                call    puthex
                ld      hl,msg_lbaeq
                call    puts
                ld      hl,V_LBA
                call    putdec32
                call    crlf
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
                IFDEF   SIM
                out     (SER_DATA),a            ; the testbench captures this
                ret
                ELSE
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
                ENDIF

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
                IFDEF   SIM
                ld      a,'y'
                ret
                ELSE
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
                ENDIF

; ============================================================================
; messages
; ============================================================================
msg_banner:     defb    0Dh,0Ah
                defm    'HPS block device end-to-end test (ports 90h-97h)'
                defb    0Dh,0Ah
                defm    'Phase 1: read tests (non-destructive)'
                defb    0Dh,0Ah,0
msg_t1:         defm    'T1 status register = '
                defb    0
msg_nomount:    defm    '  NO IMAGE MOUNTED. Mount one with the OSD (SD card image). Waiting...'
                defb    0Dh,0Ah,0
msg_nowmnt:     defm    'T1 image mounted, status = '
                defb    0
msg_ro:         defm    '  (image is read-only)'
                defb    0
msg_t2:         defm    'T2 image size = '
                defb    0
msg_blocks:     defm    ' blocks ('
                defb    0
msg_mib:        defm    ' MiB)'
                defb    0
msg_sat:        defm    ' (size register saturated at FFFFFFh)'
                defb    0
msg_t3:         defm    'T3 read LBA 0, polled per byte'
                defb    0Dh,0Ah,0
msg_sum:        defm    '  sum '
                defb    0
msg_t4:         defm    'T4 read LBA 0 again, INIR block mode, same data?'
                defb    0
msg_t5:         defm    'T5 last block, polled vs INIR'
                defb    0
msg_t6:         defm    'T6 blocks 2^n, polled vs INIR'
                defb    0
msg_t6e:        defm    'T6 done'
                defb    0
msg_indent:     defm    '   '
                defb    0
msg_lba:        defm    ' LBA '
                defb    0
msg_t7:         defm    'T7 out-of-range LBA rejected, then recovery'
                defb    0
msg_notrej:     defm    '  not rejected'
                defb    0
msg_recbad:     defm    '  data after recovery differs from block 0'
                defb    0
msg_okc:        defm    '  ... OK'
                defb    0Dh,0Ah,0
msg_failc:      defm    '  ... FAIL'
                defb    0Dh,0Ah,0
msg_failc2:     defm    '  ... FAIL:'
                defb    0
msg_bderr:      defm    '  *** FAIL: device error '
                defb    0
msg_stat:       defm    ' status '
                defb    0
msg_lbaeq:      defm    ' LBA '
                defb    0
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
msg_skipro:     defm    'Image is read-only: write tests skipped.'
                defb    0Dh,0Ah,0
msg_small:      defm    'Image has fewer than the sectors needed: write tests skipped.'
                defb    0Dh,0Ah,0
msg_ask1:       defm    'Phase 2: WRITE tests on the sectors at the top of the device,'
                defb    0Dh,0Ah
                defm    'LBA '
                defb    0
msg_ask2:       defm    ' up to '
                defb    0
msg_ask3:       defm    ' (exclusive).'
                defb    0Dh,0Ah
                defm    'The original contents are backed up to RAM and restored afterwards.'
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
msg_pat0:       defm    ' write ascending'
                defb    0Dh,0Ah,0
msg_pat1:       defm    ' (inverted) write ascending'
                defb    0Dh,0Ah,0
msg_vp:         defm    '   read back descending and compare'
                defb    0Dh,0Ah,0
msg_rs:         defm    'W3 restoring the original sectors and verifying'
                defb    0Dh,0Ah,0
msg_nowrite:    defm    'Backup failed: nothing was written to the device.'
                defb    0Dh,0Ah,0
msg_p2ok:       defm    'WRITE TESTS PASSED (original contents restored)'
                defb    0Dh,0Ah,0
msg_p2bad:      defm    'WRITE TESTS FAILED, failures: '
                defb    0
msg_end:        defm    'Done. Reset the core to run again.'
                defb    0Dh,0Ah,0

                end

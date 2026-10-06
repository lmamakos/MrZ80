; ============================================================================
; sdramsum.asm  -  checksum / dump SDRAM page 0 (verify an OSD-loaded image)
; ----------------------------------------------------------------------------
; PURPOSE
;   A .BIN loaded with "Boot Load Target = SDRAM" lands at SDRAM physical
;   0x000000 (page 0) and boots from there. If such an image fails to run we
;   need to know whether the image itself arrived intact (download path) or
;   whether it is being mis-executed (fetch / wait-state path).
;
;   SDRAM is NOT re-initialised by a later OSD download, so:
;     1. Load the suspect image (e.g. camel80.bin) with Boot Load Target =
;        SDRAM.  Let it fail.
;     2. Switch Boot Load Target = Block RAM and load THIS program.
;     3. It maps SDRAM page 0 into frame 1 (logical 0x4000) and prints a
;        16-bit additive checksum of every 256-byte block of the 16 KB page,
;        re-reads everything a second time and reports blocks that differ
;        between the two reads, then hex-dumps the first 64 bytes.
;     4. On the host run   testing/binsums.py <image.bin>   and compare the
;        two tables. (The last, partial block of the image will differ --
;        SDRAM holds whatever followed the image there. A crashed image may
;        also have scribbled on its own data/stack area.)
;
; SERIAL CONSOLE (6850-compatible ACIA)  0x82 status/control, 0x83 data
; BUILD: make -C testing sdramsum.bin
; ============================================================================

	.z80
                org     0000h

SERSTAT         equ     082h
SERDATA         equ     083h
TDRE            equ     002h

MAP1LO          equ     0B1h            ; frame-1 map reg low byte (page 7:0)
MAP1HI          equ     0B5h            ; frame-1 map reg high byte (page 13:8)

SDPAGE          equ     0               ; SDRAM physical 16 KB page to inspect
WIN             equ     4000h           ; frame-1 window (logical)
NBLK            equ     64              ; 64 x 256 bytes = the whole 16 KB page
PERLINE         equ     8               ; checksums printed per line

SUMTAB          equ     3000h           ; NBLK x 2 bytes, block RAM (frame 0)
STACK           equ     3F00h

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

                ; ---- map SDRAM page SDPAGE into frame 1 ----
                ld      a,SDPAGE and 0FFh
                out     (MAP1LO),a              ; low byte (clears reg first)
                ld      a,SDPAGE shr 8
                out     (MAP1HI),a

                ; ---- pass 1: per-block checksums into SUMTAB ----
                ld      hl,WIN
                ld      de,SUMTAB
                ld      c,NBLK
p1_loop:
                push    bc
                call    blksum                  ; BC = sum, HL += 256
                ld      a,c
                ld      (de),a
                inc     de
                ld      a,b
                ld      (de),a
                inc     de
                pop     bc
                dec     c
                jr      nz,p1_loop

                ; ---- print the table: "kk: ssss ssss ..." ----
                ld      hl,SUMTAB
                ld      e,0                     ; E = block index
pr_loop:
                ld      a,e
                and     PERLINE-1
                jr      nz,pr_noline
                call    crlf
                ld      a,e
                call    puthex
                ld      a,':'
                call    putc
pr_noline:
                ld      a,' '
                call    putc
                ld      c,(hl)
                inc     hl
                ld      a,(hl)
                inc     hl
                call    puthex                  ; high byte
                ld      a,c
                call    puthex                  ; low byte
                inc     e
                ld      a,e
                cp      NBLK
                jr      nz,pr_loop
                call    crlf

                ; ---- pass 2: re-read, compare against pass 1 ----
                ld      hl,msg_reread
                call    puts
                xor     a
                ld      (nbad),a
                ld      hl,WIN
                ld      de,SUMTAB
                ld      c,NBLK
p2_loop:
                push    bc
                call    blksum                  ; BC = sum, HL += 256
                ld      a,(de)
                cp      c
                jr      nz,p2_bad
                inc     de
                ld      a,(de)
                cp      b
                jr      nz,p2_bad1
                inc     de
                jr      p2_next
p2_bad:
                inc     de
p2_bad1:
                inc     de
                ld      a,(nbad)
                inc     a
                ld      (nbad),a
                pop     bc
                push    bc
                ld      a,NBLK
                sub     c                       ; A = block index
                push    hl
                push    af
                ld      a,' '
                call    putc
                pop     af
                call    puthex
                pop     hl
p2_next:
                pop     bc
                dec     c
                jr      nz,p2_loop
                ld      a,(nbad)
                or      a
                jr      nz,p2_some
                ld      hl,msg_none
                call    puts
                jr      p2_done
p2_some:
                ld      hl,msg_count
                call    puts
                ld      a,(nbad)
                call    puthex
p2_done:
                call    crlf

                ; ---- hex dump of the first 64 bytes ----
                ld      hl,msg_dump
                call    puts
                ld      hl,WIN
                ld      c,4                     ; 4 lines x 16 bytes
dump_line:
                call    crlf
                push    hl
                ld      a,h
                sub     WIN shr 8               ; show image offset, not 4000h
                ld      h,a
                call    puthex16
                pop     hl
                ld      a,':'
                call    putc
                ld      b,16
dump_byte:
                ld      a,' '
                call    putc
                ld      a,(hl)
                call    puthex
                inc     hl
                djnz    dump_byte
                dec     c
                jr      nz,dump_line
                call    crlf
                ld      hl,msg_done
                call    puts
halt_loop:
                halt
                jr      halt_loop

; ----------------------------------------------------------------------------
; blksum: BC = 16-bit additive sum of the 256 bytes at HL; HL += 256.
;         Preserves DE.
; ----------------------------------------------------------------------------
blksum:
                push    de
                ld      de,0
                ld      b,0                     ; 256 iterations
bs_loop:
                ld      a,(hl)
                add     a,e
                ld      e,a
                jr      nc,bs_nc
                inc     d
bs_nc:
                inc     hl
                djnz    bs_loop
                ld      b,d
                ld      c,e
                pop     de
                ret

; ============================================================================
; Serial output helpers (all preserve BC, DE, HL)
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
msg_banner:     defb    0Dh,0Ah
                defm    "MultiComp SDRAM page-0 checksum (256-byte blocks, 16-bit sums)"
                defb    0
msg_reread:     defm    "re-read differs:"
                defb    0
msg_none:       defm    " none"
                defb    0
msg_count:      defm    "  count="
                defb    0
msg_dump:       defm    "first 64 bytes:"
                defb    0
msg_done:       defm    "DONE"
                defb    0Dh,0Ah,0

nbad:           defb    0

                end

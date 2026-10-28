\ MrZ80 SSP monitor -- P1a command loop (D-39, R30)
\
\ Fed to the REPL AFTER `compiletoflash` (D-35 pipeline), with the SSP_*
\ register constants it uses (generated ssp/fw/ssp-regs.fs, filtered by
\ sim/ssp/p1a_dictbuild.sh) loaded first.  `init` runs `mon` at boot.
\
\ Design (recorded R30): a dedicated ODT-style command loop (prompt `.`,
\ uppercase responses, SSP_DESIGN 10.1) rather than Forth words that parse
\ their own arguments.  It owns the console only while STATUS.FW_CONSOLE_OK
\ is set (the Z80 owns the SNAC link at power, R25), so it WAITS for the
\ operator's escape and prints its banner then, not at boot (R26).
\
\   E [aaaa [n]]  examine n bytes (default $80) from aaaa; no aaaa = continue
\                 after the last examine/deposit.  Hex + ASCII, 16 per line.
\   D [aaaa]      deposit.  Shows  aaaa: xx   a hex value replaces the byte,
\                 a bare CR leaves it unchanged, either way advance; `.` ends.
\   G aaaa        Z80 restarts at aaaa (reset vent + reset-vector JP, D-02)
\   G             continue: resume the parked Z80, console back to it
\   R             registers (parked snapshot)
\   F             leave to the Forth REPL (`mon` re-enters)
\   ? / H         help
\ Numbers are hex, 1..8 digits, any case.  Memory is the Z80's LOGICAL
\ space through the D-30 sequencer, so E/D/R need the Z80 parked.

\ ---- bits composed into CTRL values (ssp-regs.fs masks) ----------------------
SSP_CTRL_ESC_BREAK_EN SSP_CTRL_CONSOLE_OWN or SSP_CTRL_Z_BUSRQ_N or
  constant m-c-park                       \ $122: parked, console ours
m-c-park SSP_CTRL_Z_RST_N or SSP_CTRL_TRAMP_EN or
  constant m-c-arm                        \ $133: arm + reset vent while parked
SSP_CTRL_ESC_BREAK_EN SSP_CTRL_TRAMP_EN or
  constant m-c-go                         \ $030: release reset, hold, console
SSP_CTRL_ESC_BREAK_EN
  constant m-c-cont                       \ $020: plain continue (never injects)

\ ---- state -------------------------------------------------------------------
128 buffer: m-line
16  buffer: m-row
0 variable m-len
0 variable m-pos
0 variable m-next                           \ default address for E / D
0 variable m-state                          \ 0 stay, 1 Z80 resumed, 2 to Forth
0 variable m-a
0 variable m-n
0 variable m-k
0 variable m-bad                           \ argument error flag

\ ---- output ------------------------------------------------------------------
: m-h1 ( u -- )  $F and dup 10 < if 48 else 55 then + emit ;
: m-h2 ( u -- )  dup 4 rshift m-h1 m-h1 ;
: m-h4 ( u -- )  dup 8 rshift m-h2 m-h2 ;
: m-ascii ( b -- )  dup 32 < over 126 > or if drop 46 then emit ;
: m-q ( -- )  ." ?" cr ;

\ Wait for the last character to leave the UART before the console is handed
\ to the Z80 (1-deep TX holding register + the shifter: ~100 us at 115200).
: m-drain ( -- )
  SSP_TICK_US @
  begin SSP_TICK_US @ over - 200 u>= until
  drop ;

\ ---- Z80 memory through the D-30 sequencer (Z80 must be parked) ----------
: m-wait ( -- )  begin SSP_STATUS @ SSP_STATUS_SEQ_BUSY and 0= until ;
: gc@ ( addr -- b )
  SSP_MEM_ADDR !
  SSP_MEM_CTL_START SSP_MEM_CTL_RNW or SSP_MEM_CTL !
  m-wait SSP_MEM_DATA @ $FF and ;
: gc! ( b addr -- )
  SSP_MEM_ADDR !  SSP_MEM_DATA !
  SSP_MEM_CTL_START SSP_MEM_CTL !
  m-wait ;

\ The park is granted at the next instruction boundary: allow it a moment.
: m-parked? ( -- f )
  200000
  begin
    SSP_STATUS @ SSP_STATUS_BUSACK and if drop true exit then
    1- dup 0=
  until
  drop false ;
: m-need-park ( -- f )
  m-parked? dup 0= if ." NOT PARKED" cr then ;

\ ---- line input and parsing ---------------------------------------------------
: m-line-in ( -- )  m-line 120 accept m-len !  0 m-pos ! ;
: m-getc ( -- c )  m-pos @ m-len @ u< if m-pos @ m-line + c@ else 0 then ;
: m-adv ( -- )  1 m-pos +! ;
: m-spaces ( -- )  begin m-getc 32 = while m-adv repeat ;
: m-digit ( c -- n )                      \ -1 if not a hex digit
  dup 48 >= over 58 < and if 48 - exit then
  dup 65 >= over 71 < and if 55 - exit then
  dup 97 >= over 103 < and if 87 - exit then
  drop -1 ;
: m-num ( -- u true | false )
  m-spaces  0 0
  begin m-getc m-digit dup 0< 0= while
    >r swap 4 lshift r> or swap 1+ m-adv
  repeat
  drop
  m-getc dup 0= swap 32 = or 0= if 2drop false exit then  \ junk after digits
  0= if drop false else true then ;

\ Optional numeric argument: the number if one is next on the line, else the
\ default.  A malformed one leaves the default AND its junk on the line, which
\ m-end then flags (so `G zz` is an error, never a plain continue).
: m-arg ( dflt -- u )
  m-spaces m-getc 0= if exit then
  m-num if nip then ;
: m-end ( -- )  m-spaces m-getc if 1 m-bad ! then ;     \ junk / extra tokens

\ ---- E : examine ---------------------------------------------------------------
: m-rd-row ( addr k -- )
  0 do dup i + $FFFF and gc@ m-row i + c! loop drop ;
: m-pr-row ( k -- )
  >r
  r@ 0 do m-row i + c@ m-h2 space loop
  16 r@ ?do 3 spaces loop
  space
  r> 0 do m-row i + c@ m-ascii loop ;
: m-examine ( -- )
  0 m-bad !
  m-next @ m-arg $FFFF and m-a !
  $80 m-arg $FFFF and m-n !  m-end
  m-bad @ if m-q exit then
  m-need-park 0= if exit then
  begin m-n @ while
    m-n @ 16 min m-k !
    m-a @ m-h4 ." : "
    m-a @ m-k @ m-rd-row
    m-k @ m-pr-row cr
    m-k @ m-a +!  m-a @ $FFFF and m-a !
    m-k @ negate m-n +!
  repeat
  m-a @ m-next ! ;

\ ---- D : deposit ----------------------------------------------------------------
\ one prompt; true when the session is over
: m-dep1 ( -- f )
  m-a @ m-h4 ." : " m-a @ gc@ m-h2 space
  m-line-in cr m-spaces
  m-getc 0= if 1 m-a +! false exit then           \ bare CR: leave, advance
  m-getc 46 = if true exit then                   \ .  ends
  m-num 0= if m-q false exit then
  dup $FF u> if drop m-q false exit then
  m-a @ gc!  1 m-a +! false ;
: m-deposit ( -- )
  0 m-bad !
  m-next @ m-arg $FFFF and m-a !  m-end
  m-bad @ if m-q exit then
  m-need-park 0= if exit then
  begin m-dep1  m-a @ $FFFF and m-a !  until
  m-a @ m-next ! ;

\ ---- R : registers ----------------------------------------------------------------
: m-w ( addr shift -- )  swap @ swap rshift m-h4 space ;
: m-regs ( -- )
  m-need-park 0= if exit then
  SSP_STATUS @ SSP_STATUS_AT_BOUNDARY and 0= if ." *MID-INSN* " then
  SSP_STATUS @ SSP_STATUS_ALT and if ." *EXX* " then
  cr
  ." PC=" SSP_SNAP_REG2 0 m-w
  ." SP=" SSP_SNAP_REG1 16 m-w
  ." AF=" SSP_SNAP_REG0 @ dup $FF and m-h2 8 rshift m-h2 space
  ." BC=" SSP_SNAP_REG2 16 m-w
  ." DE=" SSP_SNAP_REG3 0 m-w
  ." HL=" SSP_SNAP_REG3 16 m-w cr
  ." IX=" SSP_SNAP_REG4 0 m-w
  ." IY=" SSP_SNAP_REG6 0 m-w
  ." AF'=" SSP_SNAP_REG0 @ 16 rshift dup $FF and m-h2 8 rshift m-h2 space
  ." BC'=" SSP_SNAP_REG4 16 m-w
  ." DE'=" SSP_SNAP_REG5 0 m-w
  ." HL'=" SSP_SNAP_REG5 16 m-w cr
  ." I=" SSP_SNAP_REG1 @ m-h2 space
  ." R=" SSP_SNAP_REG1 @ 8 rshift m-h2 space
  ." IM=" SSP_SNAP_REG6 @ 16 rshift 3 and m-h1 space
  ." IFF=" SSP_SNAP_REG6 @ 18 rshift 3 and m-h1 cr ;

\ ---- G : go ---------------------------------------------------------------------
\ Print and drain BEFORE the CTRL writes: once console_own drops the monitor's
\ TX is no longer on the pin (R25/R26).  Register recipe: SSP_HANDOFF 2/Step 1.
: m-go ( -- )
  m-spaces m-getc 0= if                         \ G : continue
    m-need-park 0= if exit then
    ." GO" cr m-drain
    m-c-cont SSP_CTRL !
    1 m-state ! exit
  then
  0 m-bad !
  0 m-arg $FFFF and m-a !  m-end                \ G aaaa
  m-bad @ if m-q exit then
  m-need-park 0= if exit then
  ." GO " m-a @ m-h4 cr m-drain
  m-a @ SSP_TRAMP_ADDR !
  m-c-arm SSP_CTRL !
  m-c-go  SSP_CTRL !
  1 m-state ! ;

\ ---- command loop -----------------------------------------------------------------
: m-help ( -- )
  ." E [AAAA [N]]  EXAMINE" cr
  ." D [AAAA]      DEPOSIT: HEX=SET  CR=SKIP  .=END" cr
  ." G [AAAA]      GO (NO ADDRESS = CONTINUE)" cr
  ." R             REGISTERS" cr
  ." F             FORTH" cr ;
: m-cmd ( -- )
  m-spaces m-getc dup 0= if drop exit then
  m-adv 32 or
  dup 101 = if drop m-examine exit then       \ e
  dup 100 = if drop m-deposit exit then       \ d
  dup 103 = if drop m-go exit then            \ g
  dup 114 = if drop m-regs exit then          \ r
  dup 102 = if drop 2 m-state ! exit then     \ f
  dup 63 = over 104 = or if drop m-help exit then   \ ? h
  drop m-q ;
: m-banner ( -- )  cr ." MRZ80 SSP MONITOR  ? = HELP" cr ;
: m-console? ( -- f )  SSP_STATUS @ SSP_STATUS_FW_CONSOLE_OK and ;

: mon ( -- )
  begin
    begin m-console? until                    \ the operator's escape
    m-banner
    0 m-state !
    begin ." ." m-line-in cr m-cmd m-state @ until
    m-state @ 2 = if ." FORTH" cr exit then
    begin m-console? 0= until                 \ Z80 has the console again
  again ;

: init ( -- )  0 m-next !  mon ;

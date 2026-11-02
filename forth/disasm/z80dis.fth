\ z80dis.fth -- portable Z-80 disassembler core (SINGLE SOURCE OF TRUTH)
\
\ This one file is loaded, unchanged, by both Forth environments:
\   * CamelFORTH (16-bit cells, block-loaded): forth/disasm/mkblocks.py packs
\     it, wrapped by camel-port.fth, into blocks/3x-disasm.fth.
\   * Mecrisp-Quintus on the SSP (32-bit cells, text-fed): sim/ssp/
\     dictbuild.sh splices it into ssp/fw/apps/monitor.fs at the
\     "\ @include forth/disasm/z80dis.fth" line.
\ Everything that differs between the two lives in a PORT, never here.
\ See forth/disasm/README.md for the full porting contract and the tests.
\
\ RULES for editing this file (the lint in mkblocks.py enforces most):
\   * Lines <= 64 columns.  Each `\ ====` marker starts a new Camel block
\     (<= 15 lines of text under it).  Markers/comments cost Mecrisp nothing.
\   * A parsing word and its argument stay on ONE line: ." strings, ( ),
\     and never end a line with a word that parses ahead.
\   * UPPERCASE names (Camel is case-sensitive; Mecrisp is not).
\   * Decimal literals only.  No BASE, <# #>, .R, WITHIN, ?OF, RECURSE.
\   * No CELL-SIZE assumptions: mask to 8/16 bits explicitly.
\   * Every name starts DZ-.  Core words never print an address or a
\     newline; the port's wrapper does (see DZ-OP).
\
\ PORT CONTRACT -- the port must define, BEFORE this file loads:
\   DZ@   ( addr -- b )  read one Z-80 memory byte (it may return junk
\                        and flag the failure itself; the core only
\                        uses the low 8 bits)
\   variables DZ-PC DZ-IX DZ-DV DZ-HD  (the core's private state)
\ and the standard output words EMIT SPACE and ."  The ENTRY POINT is
\   DZ-OP ( addr -- next )  decode the instruction at addr and print its
\   mnemonic text only; next = address of the following instruction.
\ Address arithmetic is NOT masked here: the port's DZ@ wraps the address
\ for its own address space (16 bits logical).  Printed addresses and
\ branch targets show the low 16 bits only.

\ ==== disasm: bit fields, fetch and hex output
: DZ-GET ( -- b ) DZ-PC @ DZ@ 255 AND  1 DZ-PC +! ;
: DZ-WORD ( -- w ) DZ-GET DZ-GET 8 LSHIFT OR ;
: DZ-BITS ( byte shift mask -- v ) >R RSHIFT R> AND ;
: DZ-FX ( b -- x ) 6 3 DZ-BITS ;
: DZ-FY ( b -- y ) 3 7 DZ-BITS ;
: DZ-FZ ( b -- z ) 0 7 DZ-BITS ;
: DZ-FP ( b -- p ) 4 3 DZ-BITS ;
: DZ-FQ ( b -- q ) 3 1 DZ-BITS ;
: DZ-H1 ( u -- ) 15 AND DUP 10 < IF 48 ELSE 55 THEN + EMIT ;
: DZ-H2 ( u -- ) DUP 4 RSHIFT DZ-H1 DZ-H1 ;
: DZ-H4 ( u -- ) DUP 8 RSHIFT DZ-H2 DZ-H2 ;
: DZ-DIG ( n -- ) 48 + EMIT ;

\ ==== disasm: operands and displacements
: DZ-N8 ( -- ) DZ-GET DZ-H2 ." h" ;
: DZ-N16 ( -- ) DZ-WORD DZ-H4 ." h" ;
: DZ-GETD ( -- d )
  DZ-HD @ 0= IF
    DZ-GET DUP 128 AND IF 256 - THEN
    DZ-DV !  -1 DZ-HD !
  THEN
  DZ-DV @ ;
: DZ-DISP ( -- )
  DZ-GETD
  DUP 0< IF ." -" NEGATE DZ-H2 ELSE ." +" DZ-H2 THEN ." h" ;
: DZ-IXN ( -- ) DZ-IX @ 1 = IF ." IX" ELSE ." IY" THEN ;
: DZ-REL ( -- )  \ JR/DJNZ operand: the branch target address
  DZ-GET DUP 128 AND IF 256 - THEN DZ-PC @ + DZ-H4 ." h" ;

\ ==== disasm: register names
: DZ-REG ( n -- )
  CASE
    0 OF ." B" ENDOF    1 OF ." C" ENDOF
    2 OF ." D" ENDOF    3 OF ." E" ENDOF
    4 OF DZ-IX @ IF DZ-IXN ." H" ELSE ." H" THEN ENDOF
    5 OF DZ-IX @ IF DZ-IXN ." L" ELSE ." L" THEN ENDOF
    6 OF DZ-IX @ IF
           ." (" DZ-IXN DZ-DISP ." )"
         ELSE
           ." (HL)"
         THEN ENDOF
    7 OF ." A" ENDOF
  ENDCASE ;
: DZ-REG0 ( n -- )  \ like DZ-REG but H/L are never IXH/IXL
  DZ-IX @ >R  0 DZ-IX !  DZ-REG  R> DZ-IX ! ;

\ ==== disasm: register pairs and condition codes
: DZ-RP ( n -- )
  CASE
    0 OF ." BC" ENDOF 1 OF ." DE" ENDOF
    2 OF DZ-IX @ IF DZ-IXN ELSE ." HL" THEN ENDOF
    3 OF ." SP" ENDOF
  ENDCASE ;
: DZ-RP2 ( n -- )  \ PUSH/POP pairs: AF instead of SP
  DUP 3 = IF DROP ." AF" ELSE DZ-RP THEN ;
: DZ-CC ( n -- )
  CASE
    0 OF ." NZ" ENDOF 1 OF ." Z" ENDOF
    2 OF ." NC" ENDOF 3 OF ." C" ENDOF
    4 OF ." PO" ENDOF 5 OF ." PE" ENDOF
    6 OF ." P" ENDOF  7 OF ." M" ENDOF
  ENDCASE ;

\ ==== disasm: ALU and rotate/shift mnemonics
: DZ-ALU ( n -- )
  CASE
    0 OF ." ADD A, " ENDOF 1 OF ." ADC A, " ENDOF
    2 OF ." SUB "    ENDOF 3 OF ." SBC A, " ENDOF
    4 OF ." AND "    ENDOF 5 OF ." XOR "    ENDOF
    6 OF ." OR "     ENDOF 7 OF ." CP "     ENDOF
  ENDCASE ;
: DZ-ROT ( n -- )
  CASE
    0 OF ." RLC " ENDOF 1 OF ." RRC " ENDOF
    2 OF ." RL "  ENDOF 3 OF ." RR "  ENDOF
    4 OF ." SLA " ENDOF 5 OF ." SRA " ENDOF
    6 OF ." SLL " ENDOF 7 OF ." SRL " ENDOF
  ENDCASE ;

\ ==== disasm: custom CPU instructions, ED page
\ F_NEXT ED 92; PUSHIX BC/DE/HL ED C5/D5/E5; POPIX ED C1/D1/E1.
\ See HARDWARE.md "Custom CPU instructions".
: DZ-CUSTOM ( b -- flag )  \ custom ED b: print it, return true
  DUP 146 = IF DROP ." F_NEXT" -1 EXIT THEN
  DUP 4 RSHIFT DUP 11 > SWAP 15 < AND
  OVER 15 AND DUP 1 = SWAP 5 = OR AND IF
    DUP 15 AND 5 = IF ." PUSHIX " ELSE ." POPIX " THEN
    4 RSHIFT 12 - DZ-RP -1 EXIT
  THEN DROP 0 ;

\ ==== disasm: CB prefix decoder, rotates and BIT/RES/SET
: DZ-DCB ( -- )
  DZ-IX @ IF DZ-GETD DROP THEN
  DZ-GET >R
  R@ DZ-FX CASE
    0 OF R@ DZ-FY DZ-ROT ENDOF
    1 OF ." BIT " R@ DZ-FY DZ-DIG ." , " ENDOF
    2 OF ." RES " R@ DZ-FY DZ-DIG ." , " ENDOF
    3 OF ." SET " R@ DZ-FY DZ-DIG ." , " ENDOF
  ENDCASE
  DZ-IX @ IF
    6 DZ-REG
    R@ DZ-FZ 6 <> IF ." , " R@ DZ-FZ DZ-REG0 THEN
  ELSE R@ DZ-FZ DZ-REG THEN
  R> DROP ;

\ ==== disasm: ED prefix decoder, part 1 of 3
: DZ-DED ( -- )
  0 DZ-IX !  DZ-GET >R
  R@ DZ-CUSTOM IF R> DROP EXIT THEN
  R@ DZ-FX CASE
    1 OF
      R@ DZ-FZ CASE
        0 OF ." IN " R@ DZ-FY 6 = IF ." F, (C)"
               ELSE R@ DZ-FY DZ-REG ." , (C)" THEN ENDOF
        1 OF ." OUT (C), " R@ DZ-FY 6 = IF ." 0"
               ELSE R@ DZ-FY DZ-REG THEN ENDOF
        2 OF R@ DZ-FQ IF ." ADC " 2 DZ-RP ." , "
               ELSE ." SBC " 2 DZ-RP ." , " THEN
             R@ DZ-FP DZ-RP ENDOF

\ ==== disasm: ED prefix decoder, part 2 of 3
        3 OF R@ DZ-FQ IF ." LD " R@ DZ-FP DZ-RP
               ." , (" DZ-N16 ." )"
             ELSE ." LD (" DZ-N16 ." ), " R@ DZ-FP DZ-RP
             THEN ENDOF
        4 OF ." NEG" ENDOF
        5 OF R@ DZ-FY 1 AND IF ." RETI" ELSE ." RETN" THEN
             ENDOF
        6 OF ." IM " R@ DZ-FY 3 AND 1- 0 MAX DZ-DIG ENDOF
        7 OF R@ DZ-FY CASE
               0 OF ." LD I, A" ENDOF 1 OF ." LD R, A" ENDOF
               2 OF ." LD A, I" ENDOF 3 OF ." LD A, R" ENDOF
               4 OF ." RRD"     ENDOF 5 OF ." RLD"     ENDOF
               6 OF ." NOP"     ENDOF 7 OF ." NOP"     ENDOF
             ENDCASE ENDOF
      ENDCASE ENDOF

\ ==== disasm: ED prefix decoder, part 3 of 3
    2 OF R@ DZ-FZ 4 < R@ DZ-FY 3 > AND IF
        R@ DZ-FY 4 - 4 * R@ DZ-FZ + CASE
          0 OF ." LDI"  ENDOF  1 OF ." CPI"  ENDOF
          2 OF ." INI"  ENDOF  3 OF ." OUTI" ENDOF
          4 OF ." LDD"  ENDOF  5 OF ." CPD"  ENDOF
          6 OF ." IND"  ENDOF  7 OF ." OUTD" ENDOF
          8 OF ." LDIR" ENDOF  9 OF ." CPIR" ENDOF
         10 OF ." INIR" ENDOF 11 OF ." OTIR" ENDOF
         12 OF ." LDDR" ENDOF 13 OF ." CPDR" ENDOF
         14 OF ." INDR" ENDOF 15 OF ." OTDR" ENDOF
        ENDCASE
      ELSE ." NOP" THEN
    ENDOF
    ." NOP"
  ENDCASE  R> DROP ;

\ ==== disasm: main decoder x=0, part 1 of 3
: DZ-D0 ( b -- )
  >R
  R@ DZ-FZ CASE
    0 OF R@ DZ-FY CASE
           0 OF ." NOP" ENDOF
           1 OF ." EX AF, AF'" ENDOF
           2 OF ." DJNZ " DZ-REL ENDOF
           3 OF ." JR " DZ-REL ENDOF
           ." JR " R@ DZ-FY 4 - DZ-CC ." , " DZ-REL
         ENDCASE ENDOF
    1 OF R@ DZ-FQ IF ." ADD " 2 DZ-RP ." , " R@ DZ-FP DZ-RP
           ELSE ." LD " R@ DZ-FP DZ-RP ." , " DZ-N16 THEN ENDOF

\ ==== disasm: main decoder x=0, part 2 of 3
    2 OF R@ DZ-FQ IF
           R@ DZ-FP CASE
             0 OF ." LD A, (BC)" ENDOF 1 OF ." LD A, (DE)" ENDOF
             2 OF ." LD " 2 DZ-RP ." , (" DZ-N16 ." )" ENDOF
             3 OF ." LD A, (" DZ-N16 ." )" ENDOF
           ENDCASE
         ELSE
           R@ DZ-FP CASE
             0 OF ." LD (BC), A" ENDOF 1 OF ." LD (DE), A" ENDOF
             2 OF ." LD (" DZ-N16 ." ), " 2 DZ-RP ENDOF
             3 OF ." LD (" DZ-N16 ." ), A" ENDOF
           ENDCASE
         THEN ENDOF

\ ==== disasm: main decoder x=0, part 3 of 3
    3 OF R@ DZ-FQ IF ." DEC " ELSE ." INC " THEN
         R@ DZ-FP DZ-RP ENDOF
    4 OF ." INC " R@ DZ-FY DZ-REG ENDOF
    5 OF ." DEC " R@ DZ-FY DZ-REG ENDOF
    6 OF ." LD " R@ DZ-FY DZ-REG ." , " DZ-N8 ENDOF
    7 OF R@ DZ-FY CASE
           0 OF ." RLCA" ENDOF 1 OF ." RRCA" ENDOF
           2 OF ." RLA"  ENDOF 3 OF ." RRA"  ENDOF
           4 OF ." DAA"  ENDOF 5 OF ." CPL"  ENDOF
           6 OF ." SCF"  ENDOF 7 OF ." CCF"  ENDOF
         ENDCASE ENDOF
  ENDCASE  R> DROP ;

\ ==== disasm: main decoders x=1 and x=2
: DZ-D1 ( b -- )
  >R
  R@ DZ-FY 6 = R@ DZ-FZ 6 = AND IF
    ." HALT"
  ELSE
    ." LD "
    R@ DZ-FY 6 = IF 6 DZ-REG ." , " R@ DZ-FZ DZ-REG0 ELSE
      R@ DZ-FZ 6 = IF R@ DZ-FY DZ-REG0 ." , " 6 DZ-REG ELSE
      R@ DZ-FY DZ-REG ." , " R@ DZ-FZ DZ-REG THEN THEN
  THEN
  R> DROP ;
: DZ-D2 ( b -- )
  >R
  R@ DZ-FY DZ-ALU R@ DZ-FZ DZ-REG
  R> DROP ;

\ ==== disasm: main decoder x=3, part 1 of 3
: DZ-D3 ( b -- )
  >R
  R@ DZ-FZ CASE
    0 OF ." RET " R@ DZ-FY DZ-CC ENDOF
    1 OF R@ DZ-FQ IF
           R@ DZ-FP CASE
             0 OF ." RET" ENDOF        1 OF ." EXX" ENDOF
             2 OF ." JP (" 2 DZ-RP ." )" ENDOF
             3 OF ." LD SP, " 2 DZ-RP ENDOF
           ENDCASE
         ELSE
           ." POP " R@ DZ-FP DZ-RP2
         THEN ENDOF
    2 OF ." JP " R@ DZ-FY DZ-CC ." , " DZ-N16 ENDOF

\ ==== disasm: main decoder x=3, part 2 of 3
    3 OF R@ DZ-FY CASE
           0 OF ." JP " DZ-N16 ENDOF   1 OF DZ-DCB ENDOF
           2 OF ." OUT (" DZ-N8 ." ), A" ENDOF
           3 OF ." IN A, (" DZ-N8 ." )" ENDOF
           4 OF ." EX (SP), " 2 DZ-RP ENDOF
           5 OF ." EX DE, HL" ENDOF
           6 OF ." DI" ENDOF         7 OF ." EI" ENDOF
         ENDCASE ENDOF
    4 OF ." CALL " R@ DZ-FY DZ-CC ." , " DZ-N16 ENDOF

\ ==== disasm: main decoder x=3, part 3 of 3
    5 OF R@ DZ-FQ IF
           R@ DZ-FP CASE
             0 OF ." CALL " DZ-N16 ENDOF
             2 OF DZ-DED ENDOF
           ENDCASE
         ELSE
           ." PUSH " R@ DZ-FP DZ-RP2
         THEN ENDOF
    6 OF R@ DZ-FY DZ-ALU DZ-N8 ENDOF
    7 OF ." RST " R@ DZ-FY 3 LSHIFT DZ-H2 ." h" ENDOF
  ENDCASE  R> DROP ;

\ ==== disasm: entry point DZ-OP
: DZ-DECODE ( b -- )
  >R
  R@ DZ-FX CASE
    0 OF R@ DZ-D0 ENDOF 1 OF R@ DZ-D1 ENDOF
    2 OF R@ DZ-D2 ENDOF 3 OF R@ DZ-D3 ENDOF
  ENDCASE
  R> DROP ;
: DZ-FOP ( -- b )  \ opcode, after any DD/FD prefix bytes
  0 DZ-IX !
  BEGIN DZ-GET DUP 221 = OVER 253 = OR WHILE
    5 RSHIFT 1 AND 1+ DZ-IX !
  REPEAT ;
: DZ-OP ( addr -- next )  \ print the mnemonic only
  DZ-PC !  0 DZ-HD !  DZ-FOP DZ-DECODE  DZ-PC @ ;

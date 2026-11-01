\ camel-port.fth -- CamelFORTH port of the shared Z-80 disassembler
\
\ mkblocks.py splices z80dis.fth in at the "\ @core" line and packs the
\ result into blocks/30-disasm.fth .. 49-disasm.fth (one block per
\ "\ ====" section; text before the first marker is dropped).  This file
\ holds ONLY what is Camel-specific: the state variables and memory hook
\ the core needs (the port contract in z80dis.fth) and the user words.

\ ==== disasm: Camel port, state and memory hook
DECIMAL
VARIABLE DZ-PC  VARIABLE DZ-IX  VARIABLE DZ-DV  VARIABLE DZ-HD
: DZ@ ( addr -- b ) C@ ;
\ @core
\ ==== disasm: Camel user words
( usage:  <addr> <count> DISASM    e.g.  0 8 DISASM )
: DISASM-ONE ( addr -- next-addr )
  DUP DZ-H4 ." : " DZ-OP CR ;
: DISASM ( addr count -- )
  0 DO DISASM-ONE LOOP DROP ;

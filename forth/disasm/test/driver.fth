\ driver.fth -- test driver loaded by BOTH environments after z80dis.fth
\ ( addr n -- )  disassemble n 8-byte slots starting at addr.  One line each:
\   aaaa: <mnemonic>|<bytes consumed>
\ Needs only the core (DZ-OP, DZ-H4) and standard words, so the same text
\ exercises Camel and Mecrisp identically.
: DZT ( addr n -- )
  0 DO
    DUP DZ-H4 ." : " DUP DZ-OP OVER - ." |" . CR
    8 +
  LOOP DROP ;

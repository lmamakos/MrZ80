( 53 LIFE - drawing: one word is 16 cells = 8 window bytes  )
( A window byte holds 2 cells, even x in the low nibble;     )
( 4 quadrants of 32 x 32 cells.  Green is 10, dark is 0.     )
CREATE PAIR 0 C, 10 C, 160 C, 170 C,
: DADDR ( i -- a ) DUP 128 AND 3 LSHIFT  OVER 124 AND 2 LSHIFT +
  OVER 2 AND 8 LSHIFT +  SWAP 1 AND 3 LSHIFT +  WIN + ;
: DRAWW ( w i -- ) DADDR 8 0 DO  OVER 3 AND PAIR + C@ OVER C!
  1+ SWAP 2 RSHIFT SWAP  LOOP 2DROP ;
( next generation: compute each word from CUR into NXT and  )
( draw it if it changed, then swap the two boards           )
: GEN ( -- ) 256 0 DO  I NEWW DUP I W@ <> IF DUP I DRAWW THEN
  I 2* NXT @ + !  LOOP  CUR @ NXT @ CUR ! NXT ! ;

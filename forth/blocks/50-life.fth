( 50 LIFE - Conway's Life on the Cromemco Dazzler          )
( USAGE: 50 55 THRU  then  200 1234 LIFE!                  )
(   n seed LIFE! = n random cells, runs until a key        )
(   n RUN = n generations      x y PLANTAT = one cell      )
( 64 x 64 cells, one bit each: 4 words of 16 cells per row, )
( a whole generation is computed with bitwise logic.        )
( The Dazzler shows the bytes the CPU WRITES to its window, )
( so only words that change are written - no page flipping. )
HERE 32 + 511 + -512 AND CONSTANT WIN  WIN 2048 + DP !
CREATE ROWS 1024 ALLOT
: ?RAM HERE 30000 U> ABORT" out of RAM - load Life first" ;
VARIABLE CUR  VARIABLE NXT  ROWS CUR !  ROWS 512 + NXT !
14 CONSTANT DZCTRL  15 CONSTANT DZMODE   ?RAM
: DZ-INIT ( -- ) 48 DZMODE PC!  WIN 9 RSHIFT 128 OR DZCTRL PC!
  WIN 2048 0 FILL  ROWS 1024 0 FILL
  ROWS CUR !  ROWS 512 + NXT ! ;

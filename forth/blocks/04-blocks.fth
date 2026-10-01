( 04-blocks final blocks screen )
DECIMAL VARIABLE SCR 64 CONSTANT B/L
: LINE ( n -- addr) B/L *  SCR @ BLOCK  + ;
: LOAD ( n -- ) SCR ! 16 0 DO I LINES !
     I LINE B/L EVALUATE LOOP ;
: -->   ( n -- ) SCR @ 1+ LOAD ;
: THRU ( blk1 blk2 -- ) 1+ SWAP DO I DUP . LOAD  LOOP ;
: MAKE-BLOCKS 2DROP open-file FCB$ BHNDL !
   FIRST @ CELL+ B/BUF BL FILL  
 DUP HIGHBLK ! 1+  1 DO FIRST @ CELL+ I WBLK LOOP CLOSE-BLOCKS ;
: editor ." basic block editor.." HERE 5 7 THRU 
    HERE SWAP - ." done. " . ." bytes" CR ;
: screen ." Screen editor.. "  HERE 9 20 THRU
    HERE SWAP - ." done. " . ." bytes" CR ;
: see ." SEE word.." HERE 21 24 THRU HERE SWAP - ." done "
  . ." bytes" CR ;             0 0 OPEN-BLOCKS

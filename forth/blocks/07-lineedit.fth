( 07-lineedit.fth ) : DL  ( l# -- ) LINE B/L BLANK UPDATE L ;
: CP  ( L1 L2 -- ) (CP) UPDATE  L ; 
: MV  ( L1 L2 -- ) OVER >R (CP) R> DL ;
: EB  ( blk --) ?BLK  BLOCK B/BUF BLANK UPDATE ;
: UNDO ( -- ) EMPTY-BUFFERS L ;
: EACH ( n1 n2 XT --) ( MAP xt to range of blocks )
   ROT ROT 1+ SWAP 2DUP > IF
     DO  I OVER EXECUTE KEY? ABORT" Map halted" LOOP
   ELSE 2DROP THEN  DROP ;
: INDEX     ( n1 n2 --) CR  ['] .NDX EACH ;
: THRU ( n1 n2 --) 1+ SWAP 2DUP > IF DO I LOAD KEY?
   ABORT" Map halted" LOOP ELSE 2DROP THEN ;
: CLEANTHRU ( n1 n2 --)  ['] EB   EACH ;
: COPY ( src dst -- ) FLUSH SWAP BLOCK 2 - !  UPDATE ;
: PASTE  ( -- ) \ for pasting text into a block
      16 0 DO  I LINE B/L ACCEPT UPDATE LOOP FLUSH ;
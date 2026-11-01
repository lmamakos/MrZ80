( 1:0  utility words )  DECIMAL \ 567890123456789012345678901234
: ERASE ( addr u -- )  0 FILL ; : BLANK ( addr u -- ) BL FILL ;
: MOVE  ( c-addr c-addr u -- ) CMOVE ; : PAUSE ;
: ON -1 SWAP ! ; : OFF 0 SWAP ! ; VARIABLE LINES VARIABLE C/SCR
: UD.R  ( ud n --) >R  <# #S #>  R> OVER -  SPACES TYPE ;
: U.R   ( u n -- )  0 SWAP  UD.R  ;
: .R    ( n n -- ) >R DUP ABS 0 <# #S ROT SIGN #>
    R> OVER - SPACES TYPE ;
: -TRAILING ( addr len -- addr len') BEGIN DUP 0 <> WHILE 
      2DUP + 1- C@ BL <> IF EXIT THEN 1-  REPEAT ;
: .BASE BASE @ DUP DECIMAL . BASE ! ;

\ look up LOAD as it's defined in initial loaded screens
: blocks CR ." Loading.. " 9 2 DO I . I LOAD SPACE LOOP CR ;

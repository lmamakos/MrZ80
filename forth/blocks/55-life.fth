( 55 LIFE - the main loop                                   )
: RUN ( n -- ) 0 NG ! BEGIN DUP NG @ = 0= WHILE
  GEN 1 NG +! REPEAT DROP ;
: LIFE ( n -- ) DZ-INIT SPARK BEGIN GEN KEY? UNTIL KEY DROP ;
: LIFE! ( n u -- ) SEED LIFE ;

( 26 Front Panel LED debugging stuff                          )
HEX 0FF CONSTANT fpleds 40 CONSTANT NLED A0 CONSTANT fpdim
0A2 CONSTANT fpptr  0A3 CONSTANT fprgb 0A4 CONSTANT fpmode
0A5 CONSTANT fpmap 0A6 CONSTANT fpbit
: sel fpptr PC! ;  : delay 200 0 DO I DROP LOOP ;
: counter 100 0 DO I fpleds PC! delay LOOP ;
: times ( xt n -- )  0 DO DUP EXECUTE LOOP DROP ;
: setcolors ( pl -- ) fpptr PC!  50 fprgb PC! 00 fprgb PC!
  00 fprgb PC!  00 fprgb PC! 00 fprgb PC! 10 fprgb PC! ;
: on fpptr PC! 1 fpbit PC! ;  : off fpptr PC! 0 fpbit PC! ;
: mode0 0 fpmode PC! ;  : mode1 1 fpmode PC! ;
: clear NLED 0 DO I fpptr PC!  I setcolors I off LOOP ;
: chase  NLED 0 DO I on  I 1- 3F AND off delay LOOP ;
: fancy chase mode0 ['] delay 20 times mode1 ;
: map NLED 0 DO I sel I . I 0A5 PC@ . CR LOOP ;
( L15                                                         )

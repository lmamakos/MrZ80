( 27 benchmark; MS@ US@ return unsigned doubles ) BASE @ DECIMAL
: inner 1000 0 DO 1 2 3 + + 1 + DUP DUP DROP DROP DROP LOOP ;
: outer inner inner inner inner inner inner inner inner inner ;
: D+ ( d1 d2 -- d3 ) >R M+ R> + ;
: D- ( d1 d2 -- d3 ) DNEGATE D+ ;
: UD. ( ud -- ) <# #S #> TYPE SPACE ;
( timed: run xt, leave the elapsed milliseconds as a double )
: timed ( xt -- ud ) MS@ ROT EXECUTE MS@ 2SWAP D- ;
( utimed: as timed but microseconds, up to 71 minutes )
: utimed ( xt -- ud ) US@ ROT EXECUTE US@ 2SWAP D- ;
( times: run xt n times; print each run's time, then the total )
: times ( xt n -- ) CR MS@ 2SWAP 0 DO I . DUP timed UD. ." ms"
  CR LOOP DROP MS@ 2SWAP D- ." total " UD. ." ms" CR 7 EMIT ;
: bench ['] outer 50 times ;
( usage:  ' word utimed UD.    ' word 5 times    bench )
BASE !

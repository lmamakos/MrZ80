( 28 DEFER/IS test.  Run: t2 t3 t4 t5 t6 -> 5 PASS.  t1 last )
: ok CR ." PASS" ;   : fail CR ." **FAIL**" ;
VARIABLE V   : PING 1 V ! ;   : PONG 2 V ! ;
DEFER ROUTE   DEFER WOUT
( t1 default action is ABORT: ROUTE aborts, no PASS prints   )
: t1 CR ." T1 default-abort (no PASS): " ['] ROUTE EXECUTE ;
( t2 runs the action; t3 cell>=0 proves an xt; t4 re-targets )
: t2 ['] PING IS ROUTE ROUTE V @ 1 = IF ok ELSE fail THEN ;
: t3 ['] PING IS ROUTE ROUTE V @ 0< IF fail ELSE ok THEN ;
: t4 ['] PONG IS ROUTE ROUTE V @ 2 = IF ok ELSE fail THEN ;
( t5 IS compiled into go fires only when go RUNS, overriding )
: go ['] PING IS ROUTE ;
: t5 ['] PONG IS ROUTE go ROUTE V @ 1 = IF ok ELSE fail THEN ;
( t6 CODE-word action: after IS, WOUT behaves as EMIT char )
: t6 ['] EMIT IS WOUT 65 WOUT ['] WOUT >BODY @ ['] EMIT = IF ok
  ELSE fail THEN ;

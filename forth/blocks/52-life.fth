( 52 LIFE - the rule                                        )
( Add the 8 neighbours of all 16 cells of word i at once:   )
( weight-1 bits t0 c0 and weight-2 bits x0 x1.  A cell is   )
( alive next time if t0 or it is alive now, and exactly one )
( of x0 c0 is set with x1 clear: 2 or 3 neighbours.         )
VARIABLE CI
: NEWW ( i -- w ) DUP CI !  4 - 255 AND LCR FA >R
  CI @ LCR SWAP DROP HA >R  CI @ 4 + 255 AND LCR FA >R
  FA R> R> R> FA >R XOR R> INVERT AND
  SWAP CI @ W@ OR AND ;

( 51 LIFE - adding words of bits, and reading the board     )
( HA and FA add bit-planes: a sum word and a carry word     )
: HA ( a b -- sum carry ) 2DUP XOR ROT ROT AND ;
: FA ( a b c -- sum carry ) >R 2DUP XOR ROT ROT AND SWAP
  DUP R@ AND ROT OR SWAP R> XOR SWAP ;
( word i of the board is row i/4, cells 16 * i mod 4 and up )
: W@ ( i -- w ) 2* CUR @ + @ ;
: PK ( i -- j ) DUP 252 AND SWAP 1- 3 AND OR ;
: NK ( i -- j ) DUP 252 AND SWAP 1+ 3 AND OR ;
( r c l: the cells right of, at, and left of every bit of   )
( word i; the edge cells come from the neighbouring words   )
: LCR ( i -- r c l )
  DUP PK W@ 0< 1 AND >R  DUP NK W@ 1 AND NEGATE 32768 AND >R
  W@ DUP 2/ 32767 AND R> OR  SWAP DUP 2* R> OR ;

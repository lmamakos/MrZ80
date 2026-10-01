( 25 MMU related utils ) BASE @  ( save base on entry )
HEX 0B0 CONSTANT mmu-base    1E00 CONSTANT ram-disk-page 
: .## BASE @ SWAP HEX 0 <#  # #  #> TYPE BASE ! ;
: mmu. CR mmu-base 10 + mmu-base DO
  I .##  3A EMIT I PC@ .## SPACE LOOP CR
  4 0 DO  ." Frame " I . ." x" mmu-base 4 + I + PC@ .##
          mmu-base I + PC@ .## CR LOOP ;
: mmu.map ( page# frame -- ) 2DUP  mmu-base + PC!
     SWAP 8 RSHIFT SWAP mmu-base + 4 + PC! ;
: mmu.rdmap 01E00 3 mmu.map ;
: mmu.io ( low high -- ) ( setup MMU I/O direct access pointer)
  DUP mmu-base 0A + PC!  8 RSHIFT mmu-base 0B + PC! 
  DUP mmu-base 08 + PC!  8 RSHIFT mmu-base 09 + PC! ;
: ramdisk.io 0000 0780 ( low high ) mmu.io ;
: dumprd ramdisk.io 1000 0 DO I 3F AND 0= IF CR THEN
  0BC PC@ EMIT LOOP CR ;  BASE !  ( restore base )

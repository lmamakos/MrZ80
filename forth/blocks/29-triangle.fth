( 29 SIERPINSKI triangles                         )
: SIERPINSKI ( n -- )
   CR
   DUP 1-                       ( n y ) ( y = n-1 )
   BEGIN DUP 0< 0= WHILE        ( while y >= 0 )
      DUP SPACES                ( y leading spaces )
      2DUP - 0 DO               ( x = 0 .. n-y-1  x + y < n)
        I OVER AND IF 2 SPACES  ( x AND y != 0 -> blank cell )
                   ELSE ." * "  ( zero -> star )
                   THEN
      LOOP
      CR 1-                     ( newline, y = y - 1 )
   REPEAT 2DROP ;

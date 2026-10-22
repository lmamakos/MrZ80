# CamelFORTH Z-80 — Word Glossary

The word set implemented by the CamelFORTH Z-80 port in [`forth/`](../forth/)
(the CamelFORTH `CAMEL80` kernel). It is reproduced here from the two
glossary source files that ship with the port:

- [`forth/glosslo.txt`](../forth/glosslo.txt) — "Glossary of words in
  `CAMEL80.AZM`": the low-level words, usually written in `CODE`.
- [`forth/glosshi.txt`](../forth/glosshi.txt) — "Glossary of high-level
  words" (from `CAMEL80D.AZM` and `CAMEL80H.AZM`).

For background on the port (standalone/bare-metal vs. CP/M I/O modules, the
RAM-disk block device, the toolchain) see
[`forth/README.md`](../forth/README.md).

## Guide to stack diagrams

* `R:` = return stack
* `c` = 8-bit character
* `flag` = boolean (0 or -1)
* `n` = signed 16-bit
* `u` = unsigned 16-bit
* `d` = signed 32-bit
* `ud` = unsigned 32-bit
* `+n` = unsigned 15-bit
* `x` = any cell value
* `i*x j*x` = any number of cell values
* `a-addr` = aligned address
* `c-addr` = character address
* `p-addr` = I/O port address
* `sys` = system-specific

*Refer to the ANS Forth document for more details.*

# Low-Level Words (Written in CODE)

## ANS Forth Core Words

These are required words whose definitions are specified by the ANS Forth
document.

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `!` | `x a-addr --` | Store cell in memory |
| `+` | `n1/u1 n2/u2 -- n3/u3` | Add n1+n2 |
| `+!` | `n/u a-addr --` | Add cell to memory |
| `-` | `n1/u1 n2/u2 -- n3/u3` | Subtract n1-n2 |
| `<` | `n1 n2 -- flag` | Test n1<n2, signed |
| `=` | `x1 x2 -- flag` | Test x1=x2 |
| `>` | `n1 n2 -- flag` | Test n1>n2, signed |
| `>R` | `x -- R: -- x` | Push to return stack |
| `?DUP` | `x -- 0 \| x x` | DUP if nonzero |
| `@` | `a-addr -- x` | Fetch cell from memory |
| `0<` | `n -- flag` | True if TOS negative |
| `0=` | `n/u -- flag` | Return true if TOS=0 |
| `1+` | `n1/u1 -- n2/u2` | Add 1 to TOS |
| `1-` | `n1/u1 -- n2/u2` | Subtract 1 from TOS |
| `2*` | `x1 -- x2` | Arithmetic left shift |
| `2/` | `x1 -- x2` | Arithmetic right shift |
| `AND` | `x1 x2 -- x3` | Logical AND |
| `CONSTANT` | `n --` | Define a Forth constant |
| `C!` | `c c-addr --` | Store char in memory |
| `C@` | `c-addr -- c` | Fetch char from memory |
| `DROP` | `x --` | Drop top of stack |
| `DUP` | `x -- x x` | Duplicate top of stack |
| `EMIT` | `c --` | Output character to console |
| `EXECUTE` | `i*x xt -- j*x` | Execute Forth word 'xt' |
| `EXIT` | `--` | Exit a colon definition |
| `FILL` | `c-addr u c --` | Fill memory with char |
| `I` | `-- n R: sys1 sys2 -- sys1 sys2` | Get the innermost loop index |
| `INVERT` | `x1 -- x2` | Bitwise inversion |
| `J` | `-- n R: 4*sys -- 4*sys` | Get the second loop index |
| `KEY` | `-- c` | Get character from keyboard |
| `LSHIFT` | `x1 u -- x2` | Logical L shift u places |
| `NEGATE` | `x1 -- x2` | Two's complement |
| `OR` | `x1 x2 -- x3` | Logical OR |
| `OVER` | `x1 x2 -- x1 x2 x1` | Per stack diagram |
| `ROT` | `x1 x2 x3 -- x2 x3 x1` | Per stack diagram |
| `RSHIFT` | `x1 u -- x2` | Logical R shift u places |
| `R>` | `-- x R: x --` | Pop from return stack |
| `R@` | `-- x R: x -- x` | Fetch from return stack |
| `SWAP` | `x1 x2 -- x2 x1` | Swap top two items |
| `UM*` | `u1 u2 -- ud` | Unsigned 16x16->32 mult. |
| `UM/MOD` | `ud u1 -- u2 u3` | Unsigned 32/16->16 div. |
| `UNLOOP` | `-- R: sys1 sys2 --` | Drop loop parameters |
| `U<` | `u1 u2 -- flag` | Test u1<n2, unsigned |
| `VARIABLE` | `--` | Define a Forth variable |
| `XOR` | `x1 x2 -- x3` | Logical XOR |

## ANS Forth Extensions

Optional words specified by the ANS Forth document.

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `<>` | `x1 x2 -- flag` | Test not equal |
| `BYE` | `i*x --` | Return to CP/M |
| `CMOVE` | `c-addr1 c-addr2 u --` | Move from bottom |
| `CMOVE>` | `c-addr1 c-addr2 u --` | Move from top |
| `KEY?` | `-- flag` | Return true if char waiting |
| `M+` | `d1 n -- d2` | Add single to double |
| `NIP` | `x1 x2 -- x2` | Per stack diagram |
| `TUCK` | `x1 x2 -- x2 x1 x2` | Per stack diagram |
| `U>` | `u1 u2 -- flag` | Test u1>u2, unsigned |

## Private Extensions

Words unique to CamelForth. Many are needed to implement ANS Forth words but
are not specified by the ANS document; others are useful functions.

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `(DO)` | `n1\|u1 n2\|u2 -- R: -- sys1 sys2` | Run-time code for DO |
| `(LOOP)` | `R: sys1 sys2 -- \| sys1 sys2` | Run-time code for LOOP |
| `(+LOOP)` | `n -- R: sys1 sys2 -- \| sys1 sys2` | Run-time code for +LOOP |
| `><` | `x1 -- x2` | Swap bytes |
| `?BRANCH` | `x --` | Branch if TOS zero |
| `BDOS` | `DE C -- A` | Call CP/M BDOS |
| `BRANCH` | `--` | Branch always |
| `LIT` | `-- x` | Fetch inline literal to stack |
| `PC!` | `c p-addr --` | Output char to port |
| `PC@` | `p-addr -- c` | Input char from port |
| `RP!` | `a-addr --` | Set return stack pointer |
| `RP@` | `-- a-addr` | Get return stack pointer |
| `SCAN` | `c-addr1 u1 c -- c-addr2 u2` | Find matching char |
| `SKIP` | `c-addr1 u1 c -- c-addr2 u2` | Skip matching chars |
| `SP!` | `a-addr --` | Set data stack pointer |
| `SP@` | `-- a-addr` | Get data stack pointer |
| `S=` | `c-addr1 c-addr2 u -- n` | String compare (n<0: s1<s2, n=0: s1=s2, n>0: s1>s2) |
| `USER` | `n --` | Define user variable 'n' |

`PC!`/`PC@` are the raw I/O-port byte accessors (`OUT`/`IN`) that the console
and device words are built on.

# High-Level Words

## ANS Forth Core Words

These are required words whose definitions are specified by the ANS Forth
document.

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `#` | `ud1 -- ud2` | Convert 1 digit of output |
| `#S` | `ud1 -- ud2` | Convert remaining digits |
| `#>` | `ud1 -- c-addr u` | End conversion, get string |
| `'` | `-- xt` | Find word in dictionary |
| `(` | `--` | Skip input until ) |
| `*` | `n1 n2 -- n3` | Signed multiply |
| `*/` | `n1 n2 n3 -- n4` | n1*n2/n3 |
| `*/MOD` | `n1 n2 n3 -- n4 n5` | n1*n2/n3, rem & quot |
| `+LOOP` | `adrs -- L: 0 a1 a2 .. aN --` | |
| `,` | `x --` | Append cell to dict |
| `/` | `n1 n2 -- n3` | Signed divide |
| `/MOD` | `n1 n2 -- n3 n4` | Signed divide, rem & quot |
| `:` | `--` | Begin a colon definition |
| `;` | | End a colon definition |
| `<#` | `--` | Begin numeric conversion |
| `>BODY` | `xt -- a-addr` | Address of param field |
| `>IN` | `-- a-addr` | Holds offset into TIB |
| `>NUMBER` | `ud adr u -- ud' adr' u'` | Convert string to number |
| `2DROP` | `x1 x2 --` | Drop 2 cells |
| `2DUP` | `x1 x2 -- x1 x2 x1 x2` | Dup top 2 cells |
| `2OVER` | `x1 x2 x3 x4 -- x1 x2 x3 x4 x1 x2` | Per diagram |
| `2SWAP` | `x1 x2 x3 x4 -- x3 x4 x1 x2` | Per diagram |
| `2!` | `x1 x2 a-addr --` | Store 2 cells |
| `2@` | `a-addr -- x1 x2` | Fetch 2 cells |
| `ABORT` | `i*x -- R: j*x --` | Clear stack & QUIT |
| `ABORT"` | `i*x 0 -- i*x R: j*x -- j*x` | Print msg & abort if x1<>0 |
| `ABS` | `n1 -- +n2` | Absolute value |
| `ACCEPT` | `c-addr +n -- +n'` | Get line from terminal |
| `ALIGN` | `--` | Align HERE |
| `ALIGNED` | `addr -- a-addr` | Align given addr |
| `ALLOT` | `n --` | Allocate n bytes in dict |
| `BASE` | `-- a-addr` | Holds conversion radix |
| `BEGIN` | `-- adrs` | Target for backward branch |
| `BL` | `-- char` | An ASCII space |
| `C,` | `char --` | Append char to dict |
| `CELLS` | `n1 -- n2` | Cells->adrs units |
| `CELL+` | `a-addr1 -- a-addr2` | Add cell size to adrs |
| `CHAR` | `-- char` | Parse ASCII character |
| `CHARS` | `n1 -- n2` | Chars->adrs units |
| `CHAR+` | `c-addr1 -- c-addr2` | Add char size to adrs |
| `COUNT` | `c-addr1 -- c-addr2 u` | Counted->adr/len |
| `CR` | `--` | Output newline |
| `CREATE` | `--` | Create an empty definition |
| `DECIMAL` | `--` | Set number base to decimal |
| `DEPTH` | `-- +n` | Number of items on stack |
| `DO` | `-- adrs L: -- 0` | Start of DO..LOOP |
| `DOES>` | `--` | Change action of latest def'n |
| `ELSE` | `adrs1 -- adrs2` | Branch for IF..ELSE |
| `ENVIRONMENT?` | `c-addr u -- false` | System query |
| `EVALUATE` | `i*x c-addr u -- j*x` | Interpret string |
| `FIND` | `c-addr -- c-addr 0` | If name not found |
| | `xt 1` | If immediate |
| | `xt -1` | If "normal" |
| `FM/MOD` | `d1 n1 -- n2 n3` | Floored signed division |
| `HERE` | `-- addr` | Returns dictionary pointer |
| `HOLD` | `char --` | Add char to output string |
| `IF` | `-- adrs` | Conditional forward branch |
| `IMMEDIATE` | `--` | Make last def'n immediate |
| `LEAVE` | `-- L: -- adrs` | Exit DO..LOOP |
| `LITERAL` | `x --` | Append numeric literal to dict |
| `LOOP` | `adrs -- L: 0 a1 a2 .. aN --` | |
| `MAX` | `n1 n2 -- n3` | Signed maximum |
| `MIN` | `n1 n2 -- n3` | Signed minimum |
| `MOD` | `n1 n2 -- n3` | Signed remainder |
| `MOVE` | `addr1 addr2 u --` | Smart move |
| `M*` | `n1 n2 -- d` | Signed 16*16->32 multiply |
| `POSTPONE` | `--` | Postpone compile action of word |
| `QUIT` | `-- R: i*x --` | Interpret from keyboard |
| `RECURSE` | `--` | Recurse current definition |
| `REPEAT` | `adrs1 adrs2 --` | Resolve WHILE loop |
| `SIGN` | `n --` | Add minus sign if n<0 |
| `SM/REM` | `d1 n1 -- n2 n3` | Symmetric signed division |
| `SOURCE` | `-- adr n` | Current input buffer |
| `SPACE` | `--` | Output a space |
| `SPACES` | `n --` | Output n spaces |
| `STATE` | `-- a-addr` | Holds compiler state |
| `S"` | `--` | Compile in-line string |
| `."` | `--` | Compile string to print |
| `S>D` | `n -- d` | Single -> double precision |
| `THEN` | `adrs --` | Resolve forward branch |
| `TYPE` | `c-addr +n --` | Type line to terminal |
| `UNTIL` | `adrs --` | Conditional backward branch |
| `U.` | `u --` | Display u unsigned |
| `.` | `n --` | Display n signed |
| `WHILE` | `-- adrs` | Branch for WHILE loop |
| `WORD` | `char -- c-addr n` | Parse word delim by char |
| `[` | `--` | Enter interpretive state |
| `[CHAR]` | `--` | Compile character literal |
| `[']` | `--` | Find word & compile as literal |
| `]` | `--` | Enter compiling state |

## ANS Forth Extensions

Optional words specified by the ANS Forth document.

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `.S` | `--` | Print stack contents |
| `/STRING` | `a u n -- a+n u-n` | Trim string |
| `AGAIN` | `adrs --` | Uncond'l backward branch |
| `COMPILE,` | `xt --` | Append execution token |
| `DABS` | `d1 -- +d2` | Absolute value, dbl.prec. |
| `DEFER` | `"name" --` | Create a deferred-action word (see also `IS`) |
| `DNEGATE` | `d1 -- d2` | Negate, double precision |
| `HEX` | `--` | Set number base to hex |
| `IS` | `<action> "name" --` | Set the action of a `DEFER` word (e.g. `' EMIT IS ROUTE`) |
| `PAD` | `-- a-addr` | User PAD buffer |
| `TIB` | `-- a-addr` | Terminal Input Buffer |
| `WITHIN` | `n1\|u1 n2\|u2 n3\|u3 -- f` | Test n2<=n1<n3? |
| `WORDS` | `--` | List all words in dict. |

## Private Extensions

Words unique to CamelForth. Many are needed to implement ANS Forth words but
are not specified by the ANS document; others are useful functions.

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `!CF` | `adrs cfa --` | Set code action of a word |
| `!COLON` | `--` | Change code field to docolon |
| `!DEST` | `dest adrs --` | Change a branch dest'n |
| `#INIT` | `-- n` | #bytes of user area init data |
| `'SOURCE` | `-- a-addr` | Two cells: len, adrs |
| `(DOES>)` | `--` | Run-time action of DOES> |
| `(S")` | `-- c-addr u` | Run-time code for S" |
| `,BRANCH` | `xt --` | Append a branch instruction |
| `,CF` | `adrs --` | Append a code field |
| `,DEST` | `dest --` | Append a branch address |
| `,EXIT` | `--` | Append hi-level EXIT action |
| `>COUNTED` | `src n dst --` | Copy to counted str |
| `>DIGIT` | `n -- c` | Convert to 0..9A..Z |
| `>L` | `x -- L: -- x` | Move to Leave stack |
| `?ABORT` | `f c-addr u --` | Abort & print msg |
| `?DNEGATE` | `d1 n -- d2` | Negate d1 if n negative |
| `?NEGATE` | `n1 n2 -- n3` | Negate n1 if n2 negative |
| `?NUMBER` | `c-addr -- n -1` | Convert string->number |
| | `-- c-addr 0` | If convert error |
| `?SIGN` | `adr n -- adr' n' f` | Get optional sign; advance adr/n if sign, return NZ if negative |
| `CELL` | `-- n` | Size of one cell |
| `COLD` | `--` | Cold start Forth system |
| `COMPILE` | `--` | Append inline execution token |
| `DIGIT?` | `c -- n -1` | If c is a valid digit |
| | `-- x 0` | Otherwise |
| `DP` | `-- a-addr` | Holds dictionary ptr |
| `ENDLOOP` | `adrs xt -- L: 0 a1 a2 .. aN --` | |
| `HIDE` | `--` | "hide" latest definition |
| `HP` | `-- a-addr` | HOLD pointer |
| `IMMED?` | `nfa -- f` | Fetch immediate flag |
| `INTERPRET` | `i*x c-addr u -- j*x` | Interpret given buffer |
| `L0` | `-- a-addr` | Bottom of Leave stack |
| `LATEST` | `-- a-addr` | Last word in dictionary |
| `LP` | `-- a-addr` | Leave-stack pointer |
| `L>` | `-- x L: x --` | Move from Leave stack |
| `NFA>CFA` | `nfa -- cfa` | Name adr -> code field |
| `NFA>LFA` | `nfa -- lfa` | Name adr -> link field |
| `R0` | `-- a-addr` | End of return stack |
| `REVEAL` | `--` | "reveal" latest definition |
| `S0` | `-- a-addr` | End of parameter stack |
| `TIBSIZE` | `-- n` | Size of TIB |
| `U0` | `-- a-addr` | Current user area adrs |
| `UD*` | `ud1 d2 -- ud3` | 32*16->32 multiply |
| `UD/MOD` | `ud1 u2 -- u3 ud4` | 32/16->32 divide |
| `UINIT` | `-- addr` | Initial values for user area |
| `UMAX` | `u1 u2 -- u` | Unsigned maximum |
| `UMIN` | `u1 u2 -- u` | Unsigned minimum |

# BASIC Reference (Legacy)

Reference material for the BASIC interpreters associated with this core,
archived out of the top-level `README.md`.

## Status

* **Z-80 BASIC / monitor (`basmon`).** The Grant Searle boot monitor with its
  BASIC interpreter is **no longer the built-in boot ROM** — the FPGA core now
  boots only from a `.BIN` image the HPS loads (see `HARDWARE.md`, "Boot, reset
  and image loading"). The monitor/BASIC is still fully usable: build `intMon.hex`
  into a `.BIN` and select it with the OSD **Boot Rom Image** item, i.e. it is
  now just another bootable "ROM" alternative picked from the OSD. Its sources
  remain in `ROMS/Z80/` and `Z80 CPM and bootloader (basmon)/`.
* **BASIC under RomWBW.** A BASIC interpreter is also available as part of the
  RomWBW software environment, which is the project's current primary target.
* **6502 / 6809 BASIC.** These variants belonged to the original Grant Searle
  MultiComp multi-CPU design. The 6502 and 6809 CPUs have been **removed from
  the FPGA core** (the core is now Z-80 only, for RomWBW compatibility), so the
  6502/6809 columns below are kept for historical reference only.

## Z80 BASIC keywords

SGN, INT, ABS, USR, FRE, INP, POS, SQR, RND, LOG, EXP, COS, SIN, TAN, ATN,
PEEK, DEEK, LEN, STR$, VAL, ASC, CHR$, LEFT$, RIGHT$, MID$, END, FOR, NEXT,
DATA, INPUT, DIM, READ, LET, GOTO, RUN, IF, RESTORE, GOSUB, RETURN, REM, STOP,
OUT, ON, NULL, WAIT, DEF, POKE, DOKE, LINES, CLS, WIDTH, MONITOR, PRINT, CONT,
LIST, CLEAR, NEW, TAB, TO, FN, SPC, THEN, NOT, STEP, +, -, *, /, ^, AND, OR,
>, <, =

PLUS additional implementations (making it version 4.7b):

| Extension | Description |
|-----------|-------------|
| `HEX$(nn)` | Convert a SIGNED integer (-32768 to +32767) to a string containing the hex value |
| `BIN$(nn)` | Convert a SIGNED integer (-32768 to +32767) to a string containing the binary value |
| `&Hnn` | Interpret the value after the `&H` as a HEX value (signed 16-bit) |
| `&Bnn` | Interpret the value after the `&B` as a BINARY value (signed 16-bit) |

## 6502 BASIC (no SD card support — no CSAVE/CLOAD)

END, FOR, NEXT, DATA, INPUT, DIM, READ, LET, GOTO, RUN, IF, RESTORE, GOSUB,
RETURN, REM, STOP, ON, NULL, WAIT, DEF, POKE, PRINT, CONT, LIST, CLEAR, NEW,
TAB(, TO, FN, SPC(, THEN, NOT, STEP, SGN, INT, ABS, USR, FRE, POS, SQR, RND,
LOG, EXP, COS, SIN, TAN, ATN, PEEK, LEN, STR$, VAL, ASC, CHR$, LEFT$, RIGHT$,
MID$, +, -, *, /, ^, AND, OR, >, +, <

## Keywords by category

### Mathematical Functions

| Keyword | Z80 | 6502 | 6809 | Description | Usage Example |
|---------|-----|------|------|-------------|---------------|
| ABS | ✓ | ✓ | ✓ | Returns absolute value | `X = ABS(-5)` |
| ATN | ✓ | ✓ | ✓ | Returns arctangent | `A = ATN(1)` |
| COS | ✓ | ✓ | ✓ | Returns cosine | `C = COS(3.14159/2)` |
| EXP | ✓ | ✓ | ✓ | Returns e raised to power | `E = EXP(2)` |
| FIX | - | - | ✓ | Truncates decimal portion | `F = FIX(3.7)` |
| INT | ✓ | ✓ | ✓ | Returns integer portion | `I = INT(5.7)` |
| LOG | ✓ | ✓ | ✓ | Returns natural logarithm | `L = LOG(100)` |
| SGN | ✓ | ✓ | ✓ | Returns sign of number (-1,0,1) | `S = SGN(-42)` |
| SIN | ✓ | ✓ | ✓ | Returns sine | `S = SIN(3.14159/2)` |
| SQR | ✓ | ✓ | ✓ | Returns square root | `R = SQR(16)` |
| TAN | ✓ | ✓ | ✓ | Returns tangent | `T = TAN(0.785)` |

### String Functions

| Keyword | Z80 | 6502 | 6809 | Description | Usage Example |
|---------|-----|------|------|-------------|---------------|
| ASC | ✓ | ✓ | ✓ | Returns ASCII value of character | `A = ASC("A")` |
| CHR$ | ✓ | ✓ | ✓ | Returns character for ASCII value | `C$ = CHR$(65)` |
| INSTR | - | - | ✓ | Searches for substring | `I = INSTR(A$, "FIND")` |
| LEFT$ | ✓ | ✓ | ✓ | Returns leftmost characters | `L$ = LEFT$("HELLO", 2)` |
| LEN | ✓ | ✓ | ✓ | Returns string length | `L = LEN("TEST")` |
| MID$ | ✓ | ✓ | ✓ | Returns substring | `M$ = MID$("HELLO", 2, 2)` |
| RIGHT$ | ✓ | ✓ | ✓ | Returns rightmost characters | `R$ = RIGHT$("WORLD", 3)` |
| STR$ | ✓ | ✓ | ✓ | Converts number to string | `S$ = STR$(123)` |
| STRING$ | - | - | ✓ | Creates string of repeated characters | `S$ = STRING$(5, "*")` |
| VAL | ✓ | ✓ | ✓ | Converts string to number | `V = VAL("123")` |

### Program Control

| Keyword | Z80 | 6502 | 6809 | Description | Usage Example |
|---------|-----|------|------|-------------|---------------|
| CONT | ✓ | ✓ | ✓ | Continues program execution | `CONT` |
| END | ✓ | ✓ | ✓ | Ends program | `END` |
| FOR/NEXT | ✓ | ✓ | ✓ | Loop structure | `FOR I=1 TO 10 : PRINT I : NEXT I` |
| GOSUB | ✓ | ✓ | ✓ | Calls subroutine | `GOSUB 1000` |
| GOTO | ✓ | ✓ | ✓ | Jumps to line number | `GOTO 100` |
| IF/THEN | ✓ | ✓ | ✓ | Conditional execution | `IF X=5 THEN PRINT "YES"` |
| ON GOSUB | - | - | ✓ | Multiple branch subroutine | `ON X GOSUB 100,200,300` |
| ON GOTO | - | - | ✓ | Multiple branch jump | `ON X GOTO 100,200,300` |
| RETURN | ✓ | ✓ | ✓ | Returns from subroutine | `RETURN` |
| STOP | ✓ | ✓ | ✓ | Halts program execution | `STOP` |

### Data and Variables

| Keyword | Z80 | 6502 | 6809 | Description | Usage Example |
|---------|-----|------|------|-------------|---------------|
| DATA | ✓ | ✓ | ✓ | Stores program data | `DATA 100,200,"TEXT"` |
| DEF FN | ✓ | ✓ | ✓ | Defines function | `DEF FNA(X)=X*X+2` |
| DIM | ✓ | ✓ | ✓ | Declares array dimensions | `DIM A(10),B$(20)` |
| INPUT | ✓ | ✓ | ✓ | Accepts user input | `INPUT "Name?";N$` |
| LET | ✓ | ✓ | ✓ | Assigns variable value | `LET A=5` or `A=5` |
| LINE INPUT | - | - | ✓ | Inputs entire line | `LINE INPUT "Text?";A$` |
| READ | ✓ | ✓ | ✓ | Reads DATA values | `READ A,B,C$` |
| RESTORE | ✓ | ✓ | ✓ | Resets DATA pointer | `RESTORE` |

### System and Memory

| Keyword | Z80 | 6502 | 6809 | Description | Usage Example |
|---------|-----|------|------|-------------|---------------|
| DEEK | ✓ | - | - | Reads word from memory | `D = DEEK(16384)` |
| DOKE | ✓ | - | - | Writes word to memory | `DOKE 16384,12345` |
| FRE | ✓ | ✓ | - | Returns free memory | `F = FRE(0)` |
| INP | ✓ | - | - | Reads from I/O port | `I = INP(255)` |
| MEM | - | - | ✓ | Returns memory size | `M = MEM` |
| OUT | ✓ | - | - | Writes to I/O port | `OUT 255,10` |
| PEEK | ✓ | ✓ | ✓ | Reads byte from memory | `P = PEEK(16384)` |
| POKE | ✓ | ✓ | ✓ | Writes byte to memory | `POKE 16384,255` |
| USR | ✓ | ✓ | ✓ | Calls machine language routine | `U = USR(32768)` |
| VARPTR | - | - | ✓ | Returns variable address | `V = VARPTR(A)` |

### Program Editing

| Keyword | Z80 | 6502 | 6809 | Description | Usage Example |
|---------|-----|------|------|-------------|---------------|
| CLEAR | ✓ | ✓ | ✓ | Clears variables | `CLEAR` |
| CLS | ✓ | - | - | Clears screen | `CLS` |
| DEL | - | - | ✓ | Deletes program lines | `DEL 100-200` |
| EDIT | - | - | ✓ | Edits program line | `EDIT 100` |
| LIST | ✓ | ✓ | ✓ | Lists program | `LIST` or `LIST 100-200` |
| NEW | ✓ | ✓ | ✓ | Clears program | `NEW` |
| RENUM | - | - | ✓ | Renumbers program lines | `RENUM 100,10` |
| RUN | ✓ | ✓ | ✓ | Executes program | `RUN` or `RUN 100` |
| TRON/TROFF | - | - | ✓ | Trace mode on/off | `TRON` or `TROFF` |

### Operators

| Operator | Z80 | 6502 | 6809 | Description | Usage Example |
|----------|-----|------|------|-------------|---------------|
| + | ✓ | ✓ | ✓ | Addition | `A = B + C` |
| - | ✓ | ✓ | ✓ | Subtraction | `X = Y - Z` |
| * | ✓ | ✓ | ✓ | Multiplication | `P = Q * R` |
| / | ✓ | ✓ | ✓ | Division | `D = N / 2` |
| ^ | ✓ | ✓ | ✓ | Exponentiation | `E = 2 ^ 3` |
| AND | ✓ | ✓ | ✓ | Logical AND | `IF A>0 AND B<10 THEN...` |
| OR | ✓ | ✓ | ✓ | Logical OR | `IF X=0 OR Y=0 THEN...` |
| NOT | ✓ | ✓ | ✓ | Logical NOT | `IF NOT A THEN...` |
| > | ✓ | ✓ | ✓ | Greater than | `IF X > 10 THEN...` |
| < | ✓ | ✓ | ✓ | Less than | `IF Y < 5 THEN...` |
| = | ✓ | ✓ | ✓ | Equal to | `IF A = B THEN...` |
| & | - | - | ✓ | Bitwise AND | `R = X & Y` |

Notes:

1. Z80 BASIC is the most commonly used version for CP/M systems
2. 6502 BASIC is a Microsoft BASIC variant
3. 6809 BASIC has the most extensive command set but lacks storage commands
4. None of the 6502 and 6809 variants support CSAVE/CLOAD operations

Each example shows the most common usage pattern for the command. Many commands
have additional optional parameters or alternate syntaxes not shown in these
basic examples.

# BASIC Programming Examples

A collection of example programs demonstrating various BASIC programming
concepts and commands. Some of these may only run on the 6809.

## Number Guessing Game

Demonstrates input handling, loops, and conditional statements. The computer
picks a random number and the player has 10 tries to guess it.

```basic
10 REM Number Guessing Game
20 CLS
30 PRINT "Number Guessing Game!"
40 LET N = INT(RND(1) * 100) + 1
50 LET TRIES = 0
60 PRINT "Guess a number between 1 and 100"
70 INPUT "Your guess: "; G
80 LET TRIES = TRIES + 1
90 IF G = N THEN GOTO 150
100 IF G < N THEN PRINT "Too low!"
110 IF G > N THEN PRINT "Too high!"
120 IF TRIES < 10 THEN GOTO 70
130 PRINT "Sorry, you've run out of tries. The number was"; N
140 GOTO 160
150 PRINT "Congratulations! You got it in"; TRIES; "tries!"
160 INPUT "Play again (Y/N)? "; A$
170 IF LEFT$(A$, 1) = "Y" OR LEFT$(A$, 1) = "y" THEN GOTO 40
180 END
```

Key concepts:

- Random number generation
- Input validation
- Conditional branching
- Loop control
- String comparison

## String Manipulation

Demonstrates various string operations and functions available in BASIC.

```basic
10 REM String Manipulation Demo
20 LET A$ = "BASIC Programming"
30 PRINT "Original string: "; A$
40 PRINT "Length: "; LEN(A$)
50 PRINT "First 5 chars: "; LEFT$(A$, 5)
60 PRINT "Last 7 chars: "; RIGHT$(A$, 7)
70 PRINT "Middle 6 chars: "; MID$(A$, 7, 6)
80 FOR I = 1 TO LEN(A$)
90 PRINT MID$(A$, I, 1);
100 NEXT I
110 PRINT
120 END
```

Key concepts:

- String functions (LEN, LEFT$, RIGHT$, MID$)
- Character-by-character processing
- String concatenation
- FOR/NEXT loops with strings

## Math Functions Calculator

A simple calculator program that demonstrates mathematical functions and
structured programming using subroutines.

```basic
10 REM Math Functions Calculator
20 PRINT "Math Functions Calculator"
30 PRINT "1. Square Root"
40 PRINT "2. Sine"
50 PRINT "3. Cosine"
60 PRINT "4. Tangent"
70 PRINT "5. Exit"
80 INPUT "Choose a function (1-5): "; C
90 IF C = 5 THEN END
100 INPUT "Enter a number: "; N
110 ON C GOSUB 200, 300, 400, 500
120 GOTO 20
200 PRINT "Square root of"; N; "is"; SQR(N)
210 RETURN
300 PRINT "Sine of"; N; "is"; SIN(N)
310 RETURN
400 PRINT "Cosine of"; N; "is"; COS(N)
410 RETURN
500 PRINT "Tangent of"; N; "is"; TAN(N)
510 RETURN
```

Key concepts:

- Subroutines with GOSUB/RETURN
- ON GOSUB branching
- Mathematical functions
- Menu-driven interface

## Array Operations

Demonstrates array handling, loops, and basic statistical calculations.

```basic
10 REM Array Operations
20 DIM A(10)
30 REM Fill array with numbers
40 FOR I = 1 TO 10
50 LET A(I) = I * 2
60 NEXT I
70 REM Calculate sum and average
80 LET S = 0
90 FOR I = 1 TO 10
100 LET S = S + A(I)
110 NEXT I
120 PRINT "Sum:"; S
130 PRINT "Average:"; S/10
140 REM Find maximum value
150 LET M = A(1)
160 FOR I = 2 TO 10
170 IF A(I) > M THEN LET M = A(I)
180 NEXT I
190 PRINT "Maximum value:"; M
200 END
```

Key concepts:

- Array declaration and initialization
- Array traversal
- Running sums
- Finding maximum values
- Basic statistics

## Simple Data Management

Shows how to work with DATA statements for storing and accessing program data.

```basic
10 REM Simple Data Management
20 DIM N$(5), A(5)
30 FOR I = 1 TO 5
40 READ N$(I), A(I)
50 NEXT I
60 REM Print all records
70 PRINT "Name", "Age"
80 PRINT "----", "---"
90 FOR I = 1 TO 5
100 PRINT N$(I), A(I)
110 NEXT I
120 DATA "John", 25, "Mary", 32, "Bob", 45, "Alice", 28, "Tom", 19
130 END
```

Key concepts:

- DATA statements
- READ operations
- Parallel arrays
- Formatted output
- String and numeric arrays

## Custom Function Definition

Demonstrates how to create and use user-defined functions.

```basic
10 REM Custom Function Demo
20 DEF FNC(X) = 5 * X^2 + 2 * X + 1
30 DEF FNF(X) = (X * 9/5) + 32
40 INPUT "Enter a number: "; N
50 PRINT "Quadratic result:"; FNC(N)
60 PRINT N; "Celsius ="; FNF(N); "Fahrenheit"
70 END
```

Key concepts:

- Function definition with DEF FN
- Mathematical expressions
- Temperature conversion
- Function parameter passing

Each of these examples can be extended or modified to create more complex
programs. Note that some BASIC dialects may require slight modifications to
these programs depending on the specific implementation.

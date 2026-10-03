# Custom Z80 Instructions for the FORTH Inner Interpreter

The "MrZ80" is a MiSTer FPGA core that implements a Z80-based single-board
computer — 64 KB of block RAM, 128 MB of SDRAM behind a small MMU, and a boot
flow that can run CP/M, or our port of **Camel Forth** as a monitor.

Why this facination with FORTH?  It's a great environment for
interactively exploring and debugging hardware.  FORTH is pretty
compact, and more importantly, extensible at runtime.  The usage
contemplated is using FORTH as a replacement for a ROM monitor; but
this monitor can be easily extended while _using_ it in a debugging
session.  Dumping memory, poking at hardware peripherals, and
incrementally extending and expanding the interactions in real time.
And perhaps just as important, FORTH has it's own elegance in design.
Very powerfuly and flexible, like a chainsaw with no guards, it won't
get in your way or prevent you from doing questionable/stupid things.

One of the recent changes to the FPGA Z80 core is a set of **custom
Z80 instructions** aimed squarely at FORTH's interpreter overhead.
The first was a single instruction for the `NEXT` primitive - the
heart of FORTH's direct-threaded interpreter - absorbing a
seven-instruction sequence into one opcode.  Profiling after that
pointed at the next bottleneck, the return stack used by every
colon-definition call and return, which led to a second pair of
instructions, `PUSHIX` and `POPIX`.  This post describes both.

## Why `NEXT`

Camel Forth is a classic direct-threaded system.  Every word in the dictionary
ends with a short stub whose job is to fetch the address of the *next* word in
the thread, advance the interpreter pointer, and jump to the new word.  That
stub is the `NEXT` macro, and it executes **once per word step** - so for any
non-trivial program, a large fraction of the CPU's time and a large fraction
of the dictionary's byte count is spent on exactly this code.

The Z80 register allocation in the Camel Forth port is:

| Register | Role |
|----------|------|
| `BC`     | TOS - top of the parameter stack |
| `HL`     | W - volatile working register |
| `DE`     | IP - interpreter pointer |
| `SP`     | PSP - parameter stack pointer |
| `IX`     | RSP - return stack pointer |
| `IY`     | UP - user-area pointer |

`HL` is the register that does the most flexible memory addressing on the
Z80, so it is kept free as the general working register; the interpreter
pointer lives in `DE` and the parameter stack top in `BC`.  That allocation
dictates the shape of the standard `NEXT` implementation.

## The standard implementation

Here is the stock macro, inlined at the end of every code word:

```asm
; entry: DE = IP, HL = W
ex de,hl    ; DE = W (stashed), HL = IP - we need IP to fetch
ld e,(hl)   ; E  = (IP)       low byte of next cell
inc hl      ; HL = IP + 1
ld d,(hl)   ; D  = (IP + 1)   high byte of next cell
inc hl      ; HL = IP + 2
ex de,hl    ; DE = IP + 2 (new IP), HL = next cell
jp (hl)     ; PC <- HL  (register value, no memory access)
```

Two points are worth calling out:

- **`JP (HL)` does not dereference memory.**  It loads the *value already in*
  the HL pair into the program counter.  So the job of the sequence is to
  get the 16-bit cell out of memory and *into HL*, and with the effect of
  leaving the advanced IP in DE.
- The two `EX DE,HL` instructions are pure register shuttling: HL must hold
  the IP while we fetch the cell, must then hold the cell so `JP (HL)` can
  jump on it, and DE has to end up as the new IP.  The shuttling is the
  tax we pay for the Z80 having exactly one indirect-jump destination
  register.

Seven instructions, seven bytes and **38 T-states** per word, executed on
every single step of interpreter execution.  Which is what makes it such a
good candidate for a workload-specific instruction.

## The custom instruction

Since we own the silicon, we are not stuck with the 200-opcode ISA the Z80
happens to have.  The instruction we chose sits in the `ED`-prefixed
"Miscellaneous" space, at the previously-undefined slot **`ED 92`**, and its
operation is exactly the essential kernel of the macro:

```
F_NEXT:   PC <- (DE)        ; fetch 16-bit cell from memory at DE
         DE <- DE + 2      ; advance the interpreter pointer
```

That is all.  Flags are untouched.  `HL` is *not* written - because in this
FORTH it is a volatile working register, there is no requirement that `NEXT`
leave anything useful in it.  Everything the runtime needs (the new PC) comes
from the jump itself, and words that need the parameter-field address simply
pop it from the return stack into whichever register is convenient.  Dropping
the "store the cell into HL" requirement is what lets the instruction be this
small: it is a 16-bit memory read plus a jump, not a read, a register load,
and a jump.

Net effect per word step: **one instruction instead of seven, two bytes
instead of seven, 14 T-states instead of 38**, at the most frequently
executed point in the whole system.

## The VHDL side

The CPU core is T80, a well-known VHDL Z80 implementation.  Its datapath is
generic; the ISA is defined entirely by a microcode table
(`Components/Z80/T80_MCode.vhd`) that, for each opcode, emits the same bundle
of control signals - address-unit selects, register-file writes, the ALU
operation, and the jump/call/branch strobes - for each machine cycle of the
instruction.  Adding an instruction therefore means adding one decode arm to
that table, composed entirely out of signals the core already has.  For
`NEXT`, no other core file changes, and the core's port interface is
untouched.

The decode lives in the `ED`-prefixed case, alongside `RETI`/`RETN` - which
it closely resembles, since both load the PC from bytes just read from
memory:

1. **Carve the slot out.**  `0x92` was one of the bits in the long OR-list of
   "unknown ED opcode" arms; it is removed from that list and given a
   dedicated arm.

2. **Machine cycle 1** (the `ED` second-byte fetch) simply points the address
   unit at `DE` (`Set_Addr_To <= aDE`), so the upcoming data reads come from
   the interpreter pointer.

3. **Machine cycle 2** reads the low byte of the cell into the core's W/Z
   temporary area (`LDZ`) and, at the end of the cycle, bumps DE by one
   through the shared 16-bit increment/decrement unit.

4. **Machine cycle 3** reads the high byte into the same area (`LDW`) and
   fires the ordinary **`Jump`** strobe - the same one `RET` and `RETI` use,
   which latches the program counter directly from the freshly-read byte
   pair (`DI_Reg & WZ`), with no register-file read hazard.  DE is incremented
   a second time, ending as `DE + 2`.

Three machine cycles, two memory reads, and the standard jump path.  Because
the arm drives only pre-existing control signals, synthesis treats it like
any other opcode: the implementation cost is a handful of extra rows in the
decode logic.

## The Camel Forth side

The software change is a build-time switch, so the *same kernel source* still
assembles for a stock Z80.  The `next` macro is wrapped in `IFDEF CUSTNEXT`:

```asm
    IFDEF CUSTNEXT
next    MACRO
        DB  0EDh,092h   ; one custom instruction
    ENDM
    ...
    ELSE
next    MACRO
        ex de,hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ex de,hl
        jp (hl)
    ENDM
    ENDIF
```

Two more adjustments:

- **`ENTER` (the `DOCOLON` entry point)** had to be re-plumbed.  Stock FORTH
  does `pop hl` + a `nexthl` variant, because the stock `NEXT` gets its target
  from HL.  Since the custom instruction reads its target from DE, the
  CUSTNEXT build does `pop de` + `next` - the parameter-field address is
  popped straight into the IP register and `HL` stays free for the word that
  follows.

- **The build system** keeps two variants of the kernel side by side: the
  Makefile assembles `camel80.bin` without the define (stock macro, for a
  plain Z80) and `camelf.bin` with the custom instructions enabled (for the
  FPGA core).  The boot banner picks up a `", with custom NEXT instruction"`
  suffix in the custom build so you can tell at a glance which kernel is
  running.


## The next bottleneck: the return stack

With `NEXT` reduced to 14 T-states, the most expensive remaining overhead is
calling and returning from colon definitions.  FORTH keeps return addresses
on a **return stack** separate from the parameter stack; Camel Forth puts it in
memory addressed by `IX`, growing downward, with `IX` pointing at the low
byte of the top item.  Every colon-definition call (`ENTER`) pushes the
interpreter pointer onto it, and every `EXIT` pops it back.  The words `>R`,
`R>`, `DO` and `DOES>` use the same stack.

The Z80 has no push or pop for an `IX`-addressed stack, so each operation is
four instructions:

```asm
; push DE onto the return stack   ; pop DE from the return stack
dec ix          ; 10 T            ld e,(ix+0)     ; 19 T
ld (ix+0),d     ; 19 T            inc ix          ; 10 T
dec ix          ; 10 T            ld d,(ix+0)     ; 19 T
ld (ix+0),e     ; 19 T            inc ix          ; 10 T
```

That is **58 T-states and 10 bytes** for each push and each pop - more than
the stock `NEXT` itself, and four times what the custom `NEXT` now costs.
The indexed `(IX+d)` instructions are the slowest common addressing mode on
the Z80, because each one fetches a prefix, an opcode and a displacement
byte before touching memory.

## `PUSHIX` and `POPIX`

The second pair of instructions does exactly these stack operations, for any
of the three general register pairs:

| Instruction | Encoding | Operation |
|---|---|---|
| `PUSHIX BC` / `DE` / `HL` | `ED C5` / `ED D5` / `ED E5` | `(IX-1) <- high`, `(IX-2) <- low`, `IX <- IX-2` |
| `POPIX BC` / `DE` / `HL`  | `ED C1` / `ED D1` / `ED E1` | `low <- (IX)`, `high <- (IX+1)`, `IX <- IX+2` |

Each takes **14 T-states and 2 bytes**, versus 58 T-states and 10 bytes.
Flags are untouched, and the memory layout is exactly what the four-instruction
sequences produce, so the remaining `(IX+d)`-based words (`R@`, `I`, `J`,
`LOOP`) keep working on the same stack unchanged.

### Why the `ED` page and not `DD`

The natural home for an `IX` instruction would seem to be the `DD` prefix,
which is how the Z80 normally selects `IX`.  But in T80, as on the real
chip, `DD` is not a separate instruction table: it is a *modifier* on the
unprefixed instructions.  The prefix just sets an internal "use IX" flag, and
then:

- the microcode decodes the following opcode from the ordinary unprefixed
  table, so it cannot tell `DD C0` from a plain `C0` (`RET NZ`);
- every reference to `H` or `L` is quietly redirected to the halves of `IX`
  (that's how the undocumented `LD IXH,n` works), so a "push HL" under `DD`
  would actually push `IX`;
- any "address from HL" becomes `(IX+d)`, automatically inserting the extra
  displacement-fetch cycle - exactly what we were trying to get rid of.

The `ED` page has its own fully decoded table, none of those side effects,
and plenty of undefined slots.  The chosen encodings also mirror the Z80's
own `PUSH`/`POP` opcodes (`C5/D5/E5` and `C1/D1/E1`), so the same two opcode
bits select the register pair.  And it keeps all of the project's custom
FORTH instructions together in one place, next to `ED 92`.

### The VHDL side, part two

Unlike `NEXT`, these instructions could not be built purely from existing
control signals, because T80 had no way to do two things outside of `DD`
mode:

1. put `IX` on the address bus *without* adding a displacement, and
2. increment or decrement `IX` with the 16-bit increment/decrement unit
   (which only knows BC, DE, HL and SP).

Both were added with small, isolated changes to `T80.vhd`: a new address
source (`aIX`, using a previously unused code of the address-select field)
that reads `IX` straight from the register file, and a new microcode output
(`IncDec_IX`) that steers the existing increment/decrement unit from HL to
IX.  The rest - memory read and write cycles, register write-back,
wait-state handling - is the same machinery the standard `PUSH`/`POP`
instructions use.  The CPU's external interface is still unchanged.

One detail is worth mentioning because it is an easy mistake.  The register
file stores BC, DE and HL in slots 0–2, `IX` in slot 3, the `EXX` alternate
set in slots 4–6, and `IY` in slot 7.  Most register selects are formed by
prefixing the `EXX` bank bit - but doing that for `IX` would silently select
`IY` whenever the alternate bank is active.  The `IX` select is therefore
hard-wired, and the testbench includes an `EXX` case specifically to catch
this.

The timing comes out at the same 14 T-states as `NEXT`.  The Z80's own
`PUSH` needs a 5-T-state opcode fetch because SP is a separate register
updated late in the cycle; `IX` lives in the register file and is updated a
cycle earlier, so the opcode fetch can stay at the normal 4 T-states:
`ED` fetch (4) + opcode fetch (4) + two memory cycles (3 + 3).

### The Camel Forth side, part two

As with `NEXT`, a build-time define (`CUSTRSP`) selects between the custom
instructions and the original code through a small set of macros:

```asm
    IFDEF CUSTRSP
rpushde MACRO
        DB  0EDh,0D5h  ; custom PUSHIX DE
        ENDM
    ...
    ELSE
rpushde MACRO
        dec ix
        ld (ix+0),d
        dec ix
        ld (ix+0),e
        ENDM
    ...
    ENDIF
```

Seven sites use them: `EXIT`, `ENTER`, `DOES>`'s runtime (`DODOES`), `>R`,
`R>`, and the two pushes in the runtime for `DO`.  Built without the define,
the kernel is byte-for-byte identical to the original, so the same source
still runs on a stock Z80.  `EXIT` becomes simply:

```asm
    head EXIT,4,'EXIT',docode
        rpopde         ; pop old IP from ret stk
        next
```

- two custom instructions, 4 bytes, 28 T-states.

### Making sure the CPU matches the kernel

A kernel built for the custom instructions will crash on a CPU that doesn't
have them, so the custom builds now check at startup.  On a stock Z80 (and
on older versions of this core) the undefined `ED` opcodes execute as
harmless 2-byte NOPs, which makes the test simple:

- **`NEXT`:** point DE at a table entry and execute `ED 92`.  A working
  instruction jumps through the table; a NOP falls through to the error
  path.
- **`PUSHIX`/`POPIX`:** with BC = 0 and DE = 1234h, execute `PUSHIX DE` then
  `POPIX BC`.  BC must come back as 1234h.

If either test fails, the kernel prints a message naming the missing
instruction and then halts the standalone system, or returns to CP/M in the
CP/M build.  Loading the new kernel onto an older FPGA image now produces a
clear message instead of a crash.

## Results

The instructions were verified in simulation (GHDL) before going to
hardware: each instruction in isolation, combinations of them, behaviour
with random memory wait states, and a real Camel Forth kernel booting and
running FORTH code on the simulated CPU.  The cycle counts below were
measured on the simulated core and match the Z80 datasheet figures for the
stock instructions.

Per FORTH primitive, in T-states (including each primitive's own trailing
`NEXT`, and the `CALL` that enters `ENTER` and `DODOES`):

| Primitive | Stock Z80 | Custom `NEXT` | `NEXT` + `PUSHIX`/`POPIX` |
|---|---:|---:|---:|
| `NEXT` | 38 | 14 | 14 |
| `ENTER` (start of a colon definition) | 119 | 99 | **55** |
| `EXIT` (end of a colon definition) | 96 | 72 | **28** |
| `>R` / `R>` | 106 / 107 | 82 / 83 | **38 / 39** |
| `DOES>` runtime | 152 | 128 | **84** |
| `DO` runtime | 241 | 217 | **129** |

The number that matters most for typical FORTH code is the overhead of
calling a colon definition: the `NEXT` that dispatches to it, its `ENTER`,
the `NEXT` that dispatches to its `EXIT`, and the `EXIT` itself:

| | Stock Z80 | Custom `NEXT` | `NEXT` + `PUSHIX`/`POPIX` |
|---|---:|---:|---:|
| Colon call + return overhead | 291 T | 199 T | **111 T** |
| relative to stock | 100 % | 68 % | **38 %** |

Idiomatic FORTH is built from many small definitions, so this overhead is
paid constantly; the return-stack instructions cut it by a further 44 % on
top of the custom `NEXT`.  Code made mostly of machine-code primitives
benefits mainly from `NEXT`.

On the board, timing with the custom `NEXT` alone showed running FORTH code
completing roughly **20% faster** than the same code under the stock macro.
The custom build is also a more compact image: every code word is five bytes
shorter, and each converted return-stack operation shrinks from 10 bytes to 2.
Since `NEXT` runs on every word step and `ENTER`/`EXIT` on every colon call,
their cost is multiplied by the length of the program; collapsing them buys
back both execution time and dictionary space at once.

<!-- TODO: update with on-board measurements for NEXT + PUSHIX/POPIX. -->

The broader lesson is one that is easy to forget when working with a
documented ISA: on an FPGA, the ISA is just source code.  If a few short
sequences account for a disproportionate share of a single workload's cycles
(and FORTH's `NEXT`, `ENTER` and `EXIT` are the textbook examples) the
cleanest fix is often to add instructions that do exactly those jobs, and let
the assembler macros pick the right encoding for the silicon they are
targeting.

## More about Camel Forth


The best way to learn and appreciate FORTH is to write one of your
own.  Or maybe just read the code and adapt one, like I did..
CamelForth is approachable in the regard.  CamelForth is written in
assembly code with macros to link things together; one you get
familiar with how they are used, it makes more sense.  "Higher level"
parts of Camel Forth also written in FORTH.

Regarding CamelForth, go right to the source and read a series of
articles called [Moving Forth](https://www.bradrodriguez.com/papers/index.html)
by Brad J. Rodriguez.   CamelForth has been ported to multiple
microprocessors and his series of articles describe implementation
choices in the context of these different CPUs.

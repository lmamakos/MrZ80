# Shared Z-80 disassembler

One disassembler, two Forth environments, **one source of truth**:

| Environment | Cells | Loads it as | Port (the only per-environment code) |
|---|---|---|---|
| CamelFORTH (Z-80, standalone / CP/M) | 16-bit | blocks 30-49, generated | `camel-port.fth` |
| Mecrisp-Quintus on the RISC-V SSP | 32-bit | spliced into the monitor dictionary build | `ssp/fw/apps/monitor.fs` (the `U` command and the `S` step display) |

`z80dis.fth` is the core. It is edited by hand; nothing generated is committed
(`forth/blocks/[34]?-disasm.fth` are git-ignored build products). It decodes
every documented and undocumented Z-80 instruction plus the project's custom
CPU instructions (`F_NEXT`, `PUSHIX`, `POPIX`; `HARDWARE.md`), and prints the
**mnemonic text only**. Addresses, byte columns and newlines belong to the port.

## Files

| File | Role |
|---|---|
| `z80dis.fth` | The core. Entry point `DZ-OP ( addr -- next )`. |
| `camel-port.fth` | Camel template: state variables, `DZ@`, `DISASM` / `DISASM-ONE`. Its `\ @core` line is where the core is spliced in. |
| `mkblocks.py` | Packs port + core into Camel blocks 30-49 and lints them (see Rules). Run by `forth/blocks/Makefile` at every `make`. |
| `Makefile` | `make check` runs the whole test matrix (below). |
| `test/` | `cases.py` (1,784 test encodings), `driver.fth` (the same driver text in both environments), `harness_camel.py`, `harness_mecrisp.py`, `verify.py`, `compare.py`, `mecrisp-port.fs` (test-only port). |

## The port contract

The core assumes nothing else. A port must define, **before** the core loads:

- `DZ@ ( addr -- b )` read one Z-80 memory byte. It may return junk and flag a
  failure itself (the SSP port sets `m-dzbad`); the core uses only the low 8 bits.
- The variables `DZ-PC DZ-IX DZ-DV DZ-HD` (the core's private state). Declared
  by the port because `VARIABLE` differs: Mecrisp needs `0 variable x` under
  `compiletoflash`, Camel's `VARIABLE` takes no initial value.
- The standard output words `EMIT SPACE ."`.

Address arithmetic is **not** masked in the core. The port's `DZ@` wraps the
address for its own address space (the SSP port applies `m-amask`: 16 bits
logical, 28 bits under `PHY`). The core prints addresses and `JR`/`DJNZ`
targets as their low 16 bits. The core never prints an address or a newline, so
each port decides the listing format: Camel prints `aaaa: mnemonic`; the SSP
monitor prints `aaaa: bb bb bb bb  mnemonic` and uses Mecrisp's `hook-emit` to
run a silent first pass that finds the instruction length.

Public words (`DZ-OP`, `DZ-H1/H2/H4` hex printers) are for ports; everything
else in the core is internal. All names start `DZ-`.

## Rules for editing `z80dis.fth`

The Camel build lints most of these (`mkblocks.py`); the cross-environment test
catches the rest.

- Lines at most 64 columns. A `\ ==== title` line starts a new Camel block;
  at most 15 lines of text under it. Titles may not contain parentheses.
  Comments cost Mecrisp nothing (the dictionary build strips them).
- A parsing word and its argument stay on **one line**: `."` strings, `( )`,
  and never end a line with `POSTPONE`, `'`, `CHAR`, ... (Camel evaluates a block
  line by line). A definition *may* span blocks (loaded by `THRU`).
- UPPERCASE names only (Camel is case-sensitive; Mecrisp is not).
- Decimal literals. No `BASE`, `<# #>`, `.R`, `WITHIN`, `?OF`, `RECURSE`, and no
  cell-size assumptions: mask to 8 or 16 bits explicitly.
- Every name starts `DZ-`; the core must never print an address or a newline.
- `CASE`/`OF`: in this project's `OF` the selector is dropped on a match; a
  default clause sees it and must NOT `DROP` it (`ENDCASE` does).

## Tests: `make -C forth/disasm check`

About 6 seconds. It needs the `z80` Python package (`pip install --user z80`),
`qemu-system-riscv32`, and the um80 toolchain (`tools/um80.sh`); see
`AGENTS.md` ("Running bare-metal code without hardware").

1. `harness_camel.py` boots the stock Camel kernel in the Python Z-80 emulator,
   loads the generated blocks the way a user does (`0 LOAD 1 LOAD blocks
   30 49 THRU`), and disassembles all 1,784 encodings.
2. `harness_mecrisp.py` feeds the same core, comment-stripped, to the SSP
   firmware's REPL under QEMU with `compiletoflash`, and does the same.
3. `verify.py` checks each environment: every disassembled line is assembled
   again with um80 and must reproduce the original bytes, and the number of
   bytes the disassembler consumed must equal the real instruction length.
   Cases no assembler can reproduce are checked by named rules (ED mirror
   encodings, undocumented `IXH`/`IXL`, DDCB register copies, ignored prefixes,
   the custom instructions). The stack must be balanced afterwards.
4. `compare.py` requires **byte-identical output from the two environments**.
   This is the sync guarantee: a difference means a port leaked into the core
   (cell size, case, a missing mask). Dropping the 8-bit mask in `DZ-GET` passes
   Camel and fails Mecrisp; a decode bug fails both.

The SSP monitor's own port (`dz@` through the D-30 engine, the `U` command, the
physical mode) is tested on the Verilator lane: `PARTS=H sim/ssp/p1a_smoke.sh`.

## Adding another port (or changing the core)

1. Change the core; run `make -C forth/disasm check`. Fix lint errors (Camel
   block rules) and any difference between environments.
2. A new environment needs only the contract above. Add a `harness_*.py` that
   returns the same JSON shape (see `harness_camel.py`) and a line in the
   `Makefile`; `verify.py` and `compare.py` work unchanged.
3. Camel: `make -C forth/blocks` regenerates blocks 30-49 and `forth.blk`
   (redeploy it). SSP: `make -C sim fw-rom` rebuilds the dictionary and the
   factory ROM image (`ssp/fw/forth_rom.mif`); recommit the MIF.

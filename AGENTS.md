# MrZ80 MiSTer FPGA

This project implements a Z-80 based system to run CP/M 2.2, CP/M 3.0 and
other operating systems at present.  The intent is to port the RomWBW
system to run on this core in the future.

## Project structure

- **Top-level entity**: `sys_top` (`sys/sys_top.v`). Wraps the MiSTer framework
  (video, audio, SD, HPS I/O) and instantiates CPU/memory components.
- **`MrZ80.sv`**: `module emu` — the MiSTer core shell. Connects to
  `sys_top` via MiSTer's standard interface. Not the top-level entity.
- Project development occurs in a Linux environment.  When editing files,
  use only LF (line feed) characters for end of line; do not insert
  carriage return 0x0D characters.
  
## Quartus revision

`MrZ80.qpf` defines a single revision, `MrZ80`, with its settings
in `MrZ80.qsf` (USB support, Z80, SignalTap off by default, aggressive
optimization settings).

Run Analysis & Synthesis after changing `.qsf` assignments.

## How to add HDL source files

Three mechanisms, pick the right one:

1. **Files under `sys/`**: These files **MUST NEVER BE MODIFIED** and are maintained
   externally.  They are an interface to the "hard wired" ARM CPU running a
   common support application for all MiSTer cores.
2. **Files elsewhere (Components/, new dirs)**: add a direct
   `set_global_assignment -name SYSTEMVERILOG_FILE path/to/your.sv` to
   `MrZ80.qsf`.
3. **IP cores**: create a `.qip` file (same format as `sys.qip`) and add
   `set_global_assignment -name QIP_FILE path/to/core.qip` to
   `MrZ80.qsf`.

## Conditional compilation macros

All macros in `MrZ80.qsf` are **commented out**:

```
ARCADE_SYS, USE_FB, USE_SDRAM, USE_DDRAM, DEBUG_NOHDMI
```

`MISTER_DUAL_SDRAM` in `sys_dual_sdram.tcl` is unused (file is never
sourced).

There are **no active conditional compilation macros** in the current build.

## Build commands

### Using the build wrapper scripts (recommended)

Two wrapper scripts in `tools/` simplify remote Quartus invocation via SSH+Docker on `tycho`:

```sh
# Full build (analysis, synthesis, place & route):
tools/build.sh

# Synthesis only (skip place & route):
tools/build.sh synth

# Show help:
tools/build.sh help

# Custom quartus_sh arguments:
tools/quartus_build.sh --flow analysis_and_synthesis MrZ80 -c MrZ80
```

**How it works:**
- Both scripts detect the project root automatically (by finding `MrZ80.qpf`/`MrZ80.qsf`).
- `tools/quartus_build.sh`: low-level wrapper that SSH's to `tycho`, runs Docker with Quartus 17.0, and passes all arguments directly to `quartus_sh`.
- `tools/build.sh`: high-level convenience wrapper with common targets (`full`, `synth`, `help`).
- The Docker container mounts the local project directory as `/build`, so output files are written back to the local `output_files/MrZ80.rbf`.

### Manual build via Quartus GUI/CLI (advanced)

If you have Quartus installed locally:

```sh
# GUI: open MrZ80.qpf, Process → Start Compilation
# CLI (headless):
quartus_sh --flow compile MrZ80 -c MrZ80
```

Output: `output_files/MrZ80.rbf`.

**Note:** Building the HDL core typically happens via the wrapper scripts above, which invoke
a containerized Quartus environment on `tycho` to avoid local tool dependencies.

### Architecture diagrams

`doc/ARCHITECTURE.md` leads with `block.svg` — a high-level view of the major
functional blocks on the Z-80 bus, labelled only with their I/O ports and memory
ranges, for people *using* the machine. Behind it sit the implementation sheets
(overview, Z-80/memory, peripherals, port map, sound, SSP, clocks). All of them
come from `doc/architecture/*.dot`:

```sh
make -C doc/architecture      # -> .svg and .png per sheet (needs graphviz/dot)
```

Update the `.dot` source, not the rendered image, whenever the structure changes
(new port, new reset term, new clock domain). Add a port to `block.dot` only if a
user of the machine needs to know it exists; the detail belongs in the subordinate
sheets and in `HARDWARE.md`. The committed artifacts are the `.dot` files and the
`.svg`s; PNGs are ignored. `doc/ARCHITECTURE.md` also holds the port map and the
on-screen file-load targets in text form.

## Z-80 assembler toolchain (`forth/`, and any future Z-80 `.azm`/`.mac` work)

The `forth/` directory (CamelFORTH port) is assembled with **um80/ul80**,
a MACRO-80/LINK-80-compatible toolchain (Python package `um80`, source:
<https://github.com/avwohl/um80_and_friends>). It is *not* preinstalled on a
fresh environment, and a `pip install --user um80` can leave a **broken**
`~/.local/bin/um80` shim ahead of a working copy elsewhere on `$PATH` (e.g.
`~/um80_and_friends/bin`) — always use the wrapper scripts below rather than
invoking `um80`/`ul80` by bare name, since they were specifically built to
avoid that trap.

```sh
# Locate + run any tool from the toolchain (um80, ul80, ud80, ux80, ...):
tools/z80tool.sh um80 forth/camel80.azm -D CPM -g -o /tmp/out.rel -l /tmp/out.prn
tools/z80tool.sh ul80 -p 0 --sym -x -o /tmp/out.hex /tmp/out.rel

# Thin wrappers for the two most commonly used tools:
tools/um80.sh <args...>
tools/ul80.sh <args...>

# One-shot assemble + link + flatten-to-binary (the same recipe
# forth/Makefile uses for camel80.bin), for one-off/exploratory builds:
tools/z80asm.sh forth/camel80.azm                       # -> forth/camel80.{prn,sym,bin}
tools/z80asm.sh -D CPM -o /tmp/camel80cpm forth/camel80.azm
tools/z80asm.sh --help
```

**How the wrappers find a working toolchain:** `tools/z80tool.sh` checks
`$Z80TOOLS_BIN/<tool>` (if set), then `~/um80_and_friends/bin/<tool>`, then
`$PATH` — and actually **runs `<tool> --version`** on each candidate to
confirm it works before using it, rather than trusting whichever comes first
on `$PATH`. If none work, it prints install instructions. Set `Z80TOOLS_BIN`
to override the search if the toolchain lives somewhere else on a given
machine.

For real, repeatable builds (not one-off exploration), prefer `forth/Makefile`
(`cd forth && make`) over `z80asm.sh` — the Makefile is the source of truth
for how `camel80.bin`/`forth.blk` are actually built and installed.

Despite `pasmo` being available, DO NOT use `pasmo` to assemble any Z80
assembly code programs.  Use the `um80`, `ul80` tools instead.

um80 accepts `.PHASE`/`.DEPHASE` but silently IGNORES them (no address
shift). For code copied to and run at another address, write its absolute
self-references as `label+OFFSET` (see `IM` in `testing/sdramstress.asm`).

## Running bare-metal code without hardware

Two quick emulator wrappers live in `tools/`. Use them for fast edit/run
cycles on Forth code; the GHDL/Verilator lanes (`sim/`, commands in
`doc/SSP_STATUS.md` §7) remain the authority for anything cycle- or
RTL-dependent. Both are scriptable from the shell or importable as a library
(`sys.path.insert(0, 'tools')`). `z80sim.py` exits 2 if the target hangs
(no prompt); `qforth.py --check` exits 1 if any line errors. Neither parses
Camel's `word?` error text, so grep the transcript for it when that matters.

### CamelFORTH (Z-80): `tools/z80sim.py`

Runs the bootable kernel in the Python `z80` emulator (`pip install --user
z80`; not preinstalled) with the console (ports 82h/83h) and the RAM-disk
MMU ports (B8h..BCh) modelled, so the kernel's own `LOAD`/`BLOCK` read the
real `forth/blocks/forth.blk`. A whole session takes seconds.

```sh
# build the stock bootable kernel, load the blocks, run commands:
tools/z80sim.py --build --blk forth/blocks/forth.blk \
    -e '0 LOAD' -e '1 LOAD' -e 'blocks' -e '30 49 THRU' -e 'HEX 0 4 DISASM'
tools/z80sim.py --bin forth/camel80.bin -f myscript.fth   # prebuilt kernel
```

```python
from z80sim import Z80Forth, build_kernel     # library use
f = Z80Forth(build_kernel(), blk='forth/blocks/forth.blk')
text, ok = f.send('1 2 + .')      # ok=False: no prompt (hung/crashed)
f.poke(0x9000, b'\xf3\xc3'); f.peek(0x9000, 2)    # 64 KB flat RAM
```

Limits: a **stock** Z-80 only. Kernels built with `CUSTNEXT`/`CUSTRSP` use
the custom `ED` opcodes and will not run; use `sim/run_forth.sh` (real T80
under GHDL, slow) for those. No SSP, MMU frame remapping or SD card. It
reproduced real crashes (e.g. the RST 38 on a block that spans a `THRU`), so
trust it for logic bugs; it cannot show hardware timing.

### Mecrisp-Quintus (RISC-V SSP): `tools/qforth.py`

Drives the Mecrisp REPL of the SSP firmware under `qemu-system-riscv32`
(`make -C ssp/fw qemu`, or `--build`). Same kernel and Forth sources as the
silicon image, ns16550 console, everything in DRAM.

```sh
tools/qforth.py --build -e ': sq dup * ;' -e '7 sq .'
tools/qforth.py -f ssp/fw/apps/mycode.fs --strip --check   # exit 1 on any error
# preload a test image into guest RAM (free from 0x80100000):
tools/qforth.py --load /tmp/img.bin@0x80100000 -e '$80100000 c@ .'
```

Limits: no SSP bridge registers (`SSP_*`), no Z-80, no real UART timing.
Code that touches `SSP_*` or the monitor is tested on the Verilator lane:
`make -C sim p1a dict-rtl smoke-p1a`. Input is paced byte-by-byte on the echo
(unpaced bursts silently lose characters); an error line has no `ok.`, which
is how `--check` detects it.

### Shared Forth source: the Z-80 disassembler

`forth/disasm/z80dis.fth` is loaded unchanged by both CamelFORTH (generated
blocks 30-49) and the SSP monitor (spliced in by `sim/ssp/dictbuild.sh` at
the `\ @include` line of `ssp/fw/apps/monitor.fs`). Edit only the shared core
and the small per-environment ports; never the generated `3x-`/`4x-disasm.fth`.
`make -C forth/disasm check` (~6 s) assembles every disassembled line back to
bytes and requires byte-identical output from both environments. Rules, port
contract and workflow: `forth/disasm/README.md`. The monitor's own port is
tested by `PARTS=H sim/ssp/p1a_smoke.sh`. After changing the core, rebuild the
Camel blocks (`make -C forth/blocks`) and the factory ROM (`make -C ssp/fw`,
which rebuilds only what changed; recommit `ssp/fw/forth_rom.mif`).

### Porting facts that bit us

- Mecrisp is **case-insensitive**; CamelFORTH is **case-sensitive** (kernel
  names are uppercase). Shared Forth source is therefore written UPPERCASE.
- Mecrisp has no `.R`, `WITHIN` or `?OF`-style helpers; its `CASE`/`OF` is
  standard (`OF` drops the selector). It needs `0 variable x` in
  `compiletoflash`; Camel's `VARIABLE` takes no initial value.
- Camel blocks are 16 lines x 64 columns, evaluated one line at a time: a
  parsing word and its argument (`."`, `(`, `POSTPONE x`) must share a line.
  A definition may span blocks only if loaded by `THRU` (a typed `n LOAD` in
  compile state just compiles the `LOAD`).

## Target device

Cyclone V `5CSEBA6U23I7` (DE10-Nano / MiSTer).

## Important gotchas
- None of the files in the  `sys/` directory shall be modified or changed in any way.
  They are maintained externally and define an interface to the ARM processor running
  a support application for the FPGA core.
- **PLLs are generated IP** — `rtl/pll/`, `sys/pll_hdmi/`, `sys/pll_audio/`.
  Regenerate via MegaWizard; do not hand-edit `.v` files in these dirs.
- **No automated tests exist.** Verification is done by compiling and running
  on hardware or in ModelSim.
- **The `*.qsf~` file** and other files with a `~` suffix are a stale editor
  backup files; ignore them.
- When adding pins, add both the `set_location_assignment` and
  `set_instance_assignment` IO standard, matching the pattern of existing
  entries in the `.qsf`.

## SSP documentation

The System Support Processor work is documented in two files in `doc/`:

- `doc/SSP_STATUS.md` — current state, the active and next milestone plans
  with checklists, backlog, owner questions, hazards, commands and
  environment. Read it first; update its §1–§5 at the end of every session.
- `doc/SSP_DESIGN.md` — spec and decisions (what and why). Change spec
  sections only when a design decision changes; append one §17 entry per
  round. Never rewrite earlier history (mark errors `[Rn erratum: …]`).

Keep milestone plans in `SSP_STATUS.md`, not in separate plan files.

Console surfaces (R44): the serial port (`$82`/`$83`) and the video terminal
+ keyboard (`$80`/`$81`) both follow the 6850 master-reset semantics RomWBW's
ACIA driver detects; the SSP monitor can sit on its own video terminal
(`ssp/rtl/ssp_vdu.vhd`), entered by OSD **Enter SSP Monitor** with **SSP
Console** picking Serial/Video. Regression lanes: `make -C sim terminal`
(real terminal RTL + `ssp_vdu` + ACIA master reset, GHDL) and
`make -C sim vdu` (console routing on the p1a lane).

## What not to commit

Do **not** track intermediate files that are ephemeral or can easily be
regenerated from sources in the repo. Examples:

- Simulator build/work dirs: Verilator `sim/ssp/obj*/`, GHDL
  `work-obj*.cf`, `/tmp/<name>` work dirs.
- Waveform/debug dumps: `*.vcd`, `*.fst`, `*.ghw`, `*.lxt`, `*.wlf`, etc.
- Compiler/tool outputs: object files, executables, Quartus `db/`,
  `incremental_db/`, `output_files/`, scratch logs and captured traces.

Before committing, check `git status` for new build or debug output, and
stage files explicitly rather than with `git add -A` or `git add .`. When a
new tool produces a new kind of intermediate file, add it to the relevant
`.gitignore` in the same change. Exceptions are deliberate deliverables
built by a documented recipe, such as committed firmware `.hex` goldens or
release `.rbf` files. Large generated files committed by mistake bloat the
history permanently unless it is rewritten, which happened once already
(see `doc/SSP_STATUS.md` §1.5).

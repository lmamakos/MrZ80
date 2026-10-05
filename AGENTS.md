# MultiComp MiSTer FPGA

This project implements a Z-80 based system to run CP/M 2.2, CP/M 3.0 and
other operating systems at present.  The intent is to port the RomWBW
system to run on this core in the future.

## Project structure

- **Top-level entity**: `sys_top` (`sys/sys_top.v`). Wraps the MiSTer framework
  (video, audio, SD, HPS I/O) and instantiates CPU/memory components.
- **`MultiComp.sv`**: `module emu` — the MiSTer core shell. Connects to
  `sys_top` via MiSTer's standard interface. Not the top-level entity.
- **CPU cores** under `Components/` (Z80 via T80 VHD).
  Machine selection is done via OSD, wired through `MultiComp.sv`.  
- Project development occurs in a Linux environment.  When editing files,
  use only LF (line feed) characters for end of line; do not insert
  carriage return 0x0D characters.
  
## Quartus revision

`MultiComp.qpf` defines a single revision, `MultiComp`, with its settings
in `MultiComp.qsf` (USB support, Z80, SignalTap enabled, aggressive
optimization settings).

Run Analysis & Synthesis after changing `.qsf` assignments.

## How to add HDL source files

Three mechanisms, pick the right one:

1. **Files under `sys/`**: These files **MUST NEVER BE MODIFIED** and are maintained
   externally.  They are an interface to the "hard wired" ARM CPU running a
   common support application for all MiSTer cores.
2. **Files elsewhere (Components/, new dirs)**: add a direct
   `set_global_assignment -name SYSTEMVERILOG_FILE path/to/your.sv` to
   `MultiComp.qsf`.
3. **IP cores**: create a `.qip` file (same format as `sys.qip`) and add
   `set_global_assignment -name QIP_FILE path/to/core.qip` to
   `MultiComp.qsf`.

## Conditional compilation macros

All macros in `MultiComp.qsf` are **commented out**:

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
tools/quartus_build.sh --flow compile_synthesis MultiComp -c MultiComp
```

**How it works:**
- Both scripts detect the project root automatically (by finding `MultiComp.qpf`/`MultiComp.qsf`).
- `tools/quartus_build.sh`: low-level wrapper that SSH's to `tycho`, runs Docker with Quartus 17.0, and passes all arguments directly to `quartus_sh`.
- `tools/build.sh`: high-level convenience wrapper with common targets (`full`, `synth`, `help`).
- The Docker container mounts the local project directory as `/build`, so output files are written back to the local `output_files/MultiComp.rbf`.

### Manual build via Quartus GUI/CLI (advanced)

If you have Quartus installed locally:

```sh
# GUI: open MultiComp.qpf, Process → Start Compilation
# CLI (headless):
quartus_sh --flow compile MultiComp -c MultiComp
```

Output: `output_files/MultiComp.rbf`.

**Note:** Building the HDL core typically happens via the wrapper scripts above, which invoke
a containerized Quartus environment on `tycho` to avoid local tool dependencies.

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

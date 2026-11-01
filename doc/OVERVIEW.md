# MrZ80 — A Technical Tour for Users

*The machine, the software, and the experience of running RomWBW, CP/M and
Z80 assembly — plus a Forth-powered debug monitor — on a MiSTer FPGA.*

This document is for the people who will actually sit down in front of a
MrZ80: CP/M application users, Z80 assembly programmers, and anyone curious
about what a 1970s microcomputer looks like when it is rebuilt with 2020s
silicon technology and the rulebook of "what fits on the board" is thrown
away. It is a tour, not a reference — the full register-level detail lives
in [`HARDWARE.md`](../HARDWARE.md) and the linked documents cited at the end.

---

## 1. What is the MrZ80?

MrZ80 is a Z-80-based microcomputer that lives entirely inside the FPGA on a
**MiSTer** board (Cyclone V `5CSEBA6U23I7`, the same silicon as the
Terasic DE10-Nano). It descends from Grant Searle's MultiComp, but has been
rebuilt around two deliberate goals:

1. **Host RomWBW** — Wayne Warthen's ROM firmware, HBIOS driver layer and
   multi-boot environment for Z-80 hardware, which boots CP/M 2.2, CP/M 3.0,
   ZSDOS, the Z-System/ZPM3 environment, CamelFORTH and other operating
   systems from one firmware image. This drove the removal of MultiComp's
   non-Z-80 CPUs and the addition of a banked-memory MMU.
2. **"Maximum Blinkenlights"** — take the IMSAI 8080 control-panel motif to
   its logical, over-the-top conclusion. In an FPGA, every internal signal of
   the CPU is observable, so MrZ80 drives **256 addressable RGB LEDs** with
   the live state of the *entire machine*: both buses, and every register of
   the CPU including the shadow banks.

Around those two goals sits a complete, practical microcomputer: 128 MB of
SDRAM, an 80×25 color ANSI VGA terminal, hardware serial, SD-card and
disk-image storage, a DS12887 clock/calendar, free-running microsecond- and
millisecond-resolution counters, a bootable ANS Forth, and an embedded RISC-V
"system support processor" running Forth that gives the machine a
PDP-11-ODT-style debug console. And none of this comes close to filling the
chip: the current build occupies barely a third of the FPGA fabric, which
matters when we talk about room to grow (§8).

### The CPU and memory in one paragraph

A single **T80** Z-80-compatible core runs at **10 MHz** (the FPGA generates
a clock-enable pulse one cycle in five from its 50 MHz system clock, so the
CPU sees true Z80 T-states). It sits on a banked memory system:

* **128 MB of SDRAM** — main RAM, physical addresses `0x0000000`–`0x7FFFFFF`.
* **64 KB of on-FPGA block RAM** — fast scratch memory at physical
  `0x8000000`, handy for benchmarking "what would a cache buy me?".
* An **MMU** (compatible with the RomWBW **Z2** platform) maps four 16 KB
  frames anywhere in the resulting 28-bit / 256 MB physical address space.
  The Z80's 64 KB logical address space is thus four live pages over a
  quarter-gigabyte machine — exactly the banked model RomWBW expects.

The MMU is programmed from Z80 I/O ports `$B0`–`$BF`: four frame-low bytes,
four frame-high bytes, and a **direct-access window** — a 28-bit physical
address pointer port plus a data port that auto-increments after every read or
write. That last port deserves applause: `INIR`/`OTIR` through it becomes a
block-move instruction for the whole 128 MB of RAM, which is how the Forth
block device and (in RomWBW) bank-to-bank copies are meant to work.

---

## 2. The CP/M peripheral environment

If you write CP/M applications or bare-metal Z80 assembly, this is the I/O
world you program against. Every device is a chip-select in I/O space, and
`HARDWARE.md` keeps the authoritative map; here is the flavor of it:

| Ports | Device | What it is |
|-------|--------|-----------|
| `$70`–`$71` | DS12887 clock/calendar | AT-style index/data pair: time, date, day-of-week, alarms and 112 bytes of general-purpose RAM. Time is seeded from the MiSTer Linux host at power-up, so the clock is always valid. Software may then take over. |
| `$80`–`$81` | VGA text terminal | 80×25 ANSI terminal: color (SGR) attributes, cursor positioning, line erasure; keyboard arrives as if from a serial line (see §3). 6850-ACIA programming model. |
| `$82`–`$83` | ACIA UART | The serial console — either MiSTer's `/dev/ttyS0` (USB/SSH) or hardware TTL serial on the USER connector. Also 6850-style: status/data, `RXRDY`/`TXDONE` handshake. |
| `$88`–`$8F` | SPI SD card | Talks to the physical SD socket on the I/O board. 512-byte blocks, SDHC addressing. |
| `$90`–`$97` | HPS block device | A disk-image file on the MiSTer Linux side, mounted from the OSD. Same register layout as the SD controller *plus* size registers, and it lets you move a whole sector with `INIR`/`OTIR` because its ready flag stays asserted for the block. Hot-mountable while running. |
| `$A0`–`$A7` | Front panel | Brightness, LED mapping, colors, profile select for the blinkenlights (§4). |
| `$B0`–`$BF` | MMU | Frame mapping + direct physical-access port (§1). |
| `$C0`–`$CF` | Benchmark timers | Free-running 32-bit **microsecond and millisecond** counters that never reset — monotonic across CPU resets, core reloads, everything. Four snapshot channels so your program and a monitor can time things simultaneously without corrupting each other. |
| `$FF` | Output latch | An IMSAI-style 8-bit latch that feeds the LED panel: `OUT ($FF),A` and the lights show your byte. |

Three details programmers will care about:

* **Two independent block devices.** The physical SD socket and the mounted
  image can both be in service at once — two "drives" of genuinely different
  provenance — and neither can disturb the other's hardware.
* **Time, at every resolution.** The RTC gives wall-clock date and time; the
  benchmark timers give elapsed time at **microsecond and millisecond**
  resolution, monotonic from the moment the FPGA is configured, on four
  independent snapshot channels. Write to any port of a channel to latch it,
  read the four bytes back little-endian, idempotently; elapsed time is
  `end − start` mod 2³². The µs counter rolls after ~71.6 minutes, plenty.
* **Color on the console.** The VGA terminal is an ANSI device: escape
  sequences for SGR color, cursor addressing and erasure, so CP/M software can
  be as vivid (or as WordStar-shaped) as you like. And because the terminal
  emulator is a state machine in the FPGA fabric rather than fixed silicon,
  extending its repertoire is a weekend of HDL, not a hardware mod.

### Writing and loading your own code

As a CP/M user you transfer `.COM` files the traditional way (serial, or by
populating the disk image on your PC with `cpmtools` — `cpmls`/`cpmcp` — and
mounting it in the OSD). As a bare-metal Z80 programmer, MrZ80 is even more
welcoming: any `.BIN` file is a bootable ROM. Assemble your code to load at
`$0000`, copy it to the SD card on the MiSTer, pick it as the **Boot Rom
Image**, and the machine *is* your program from the first instruction — no
EPROM burner required. (The repo itself builds its Z-80 software with the
MACRO-80-compatible `um80`/`ul80` toolchain; see `AGENTS.md` if you want to
reproduce those builds exactly.)

---

## 3. The user experience: the OSD, and why it exists

MrZ80 hardware has no knobs, DIP switches, or drive bays — it is a circuit
board inside an FPGA. The MiSTer platform therefore provides a standard
**On-Screen Display (OSD)**: a menu drawn over the video output, generated not
by the core but by the board's resident **ARM SoC running Linux** (the "HPS").
Each FPGA core describes its menu as data; MiSTer draws it, persists the
settings, and hands the core a status word. This is why configuration that in
1978 would have been jumper blocks and rotary switches — baud rate, which
serial port is live, which disk is mounted — is an OSD menu item here, saved
between sessions and re-applied automatically at power-up. It also means the
core can offer conveniences the original hardware never dreamed of: mounting a
disk image while the machine runs, or overriding the LED display without the
CPU ever noticing.

The MrZ80 OSD menu, and what it means:

* **Boot Rom Image** (`.BIN`/`.ROM`) — the machine has **no boot ROM at all**.
  The Z80 sits in reset until the HPS streams the file you pick into SDRAM at
  address 0; then it is released and runs your "ROM". This single mechanism
  makes *everything* swappable: a RomWBW ROM, a CP/M boot image, the
  standalone CamelFORTH kernel, or Grant Searle's classic BASIC/monitor.
* **"Sticky" selections** — the file you chose is remembered and auto-loaded
  on every core start, so the machine boots into your OS like a real computer.
  (If a sticky image ever hangs the system, open the file picker and press
  **Backspace** — MiSTer's undocumented little hatch — to clear the saved
  selection.)
* **8MB Disk Image** (`.DSK`) — streams an image into the top 8 MB of SDRAM,
  where it becomes a RAM disk (also used for Forth blocks, §5).
* **SD card image** (`.IMG`) + **Reset after Mount** — mounts a disk image on
  the HPS block device (`$90`); you can swap images at any time — an in-flight
  transfer simply aborts.
* **Serial Port / Baud Rate / Flow Control** — console port (`/dev/ttyS0` over
  USB or SSH) versus the USER-connector hardware UART; 2400–115200; optional
  RTS/CTS. *Remember the USER port is 3.3 V TTL — the FPGA is not 5 V
  tolerant.*
* **Front Panel Profiles** (`.FPP`) and **Front Panel Profile** — load and
  live-select the blinkenlights maps (§4).
* **SSP Monitor / SSP Serial Escape / Reset SSP** — enable and use the
  embedded debug console (§6).
* **Reset** — restarts the loaded image (SDRAM contents survive). A **hard**
  reset (the framework Reset) discards the loaded boot image; OSD Reset
  doesn't. Rule of thumb: *OSD Reset restarts the software; hard reset removes
  it.*

The console you type into is a choice: the classic route is a USB cable to the
MiSTer and `screen /dev/ttyS0 115200` (or SSH into the MiSTer and run
`screen` there); the purist route is a USB-serial adapter on the USER
connector with real handshake lines. Meanwhile the **VGA/HDMI 80×25 ANSI
terminal** works independently — the MiSTer framework takes your USB keyboard,
synthesizes PS/2 scan codes, and the core's terminal decoder turns them back
into characters, so the machine has a "screen and keyboard" even though neither
is physically attached to the core.

### Booting, honestly

The MrZ80 boot path today is: core loads → pick (or auto-load) a Boot Rom
Image → the Z80 runs it. CP/M and the standalone CamelFORTH kernel boot this
way, and the **RomWBW port exists as an MVP — a minimum viable product**:
HBIOS and the multi-boot environment come up on the banked-memory MMU and the
block devices and run. "Viable, not yet luxurious" has one concrete meaning:
the paths RomWBW leans on hardest — **bank swaps and bank peek/poke** through
the MMU — are functionally correct but not yet optimized for speed.
Acceleration is an explicit roadmap item: the memory-subsystem work in
`REQUIREMENTS.md` item 4 (clock-enable CPU timing, a cache for hot SDRAM
pages, optionally placing the hot RomWBW banks in fast block RAM) targets
exactly these paths. One RomWBW ROM multi-boots the family — CP/M 2.2 and
3.0, ZSDOS, Z-System, CamelFORTH, N8DOS, and the other HBIOS-aware guests.
See §7 for the status snapshot.

---

## 4. Maximum Blinkenlights

The IMSAI 8080 front panel — rows of lamps for address, data and status, a
bank of toggle switches — is the ur-image of the microcomputer age. It was
always a compromise: you could probe a few bus wires because that's all the
edge connector and your patience allowed.

MrZ80 asks: *what if the CPU lives in an FPGA, and every internal signal is
already visible?* Its answer is a strip of **256 WS2812/SK6812 RGB LEDs driven
from a single FPGA pin** (the MiSTer USER header), refreshed ~62.5 times a
second, each LED independently colored and independently mapped to *any* bit of
the machine.

What the LED string can show, straight out of the shipped core:

* The **address bus** (16 bits) and **data bus** (8 bits).
* **Every T80 register — all 192 bits of it**: `A F B C D E H L`, the entire
  **shadow bank** `A' F' B' C' D' E' H' L'`, `IX`, `IY`, `PC`, and `SP`. You
  can literally watch `EXX` flip banks, or see `SP` breathe as calls and
  returns run.
* The MMU's **28-bit physical address** — logical banking made visible.
* CPU **control signals**: `/WR` `/RD` `/INT` `/NMI` `/M1` `/HALT` `/BUSRQ`…
* A legacy **8-bit output latch** at port `$FF`, because an IMSAI panel isn't
  complete without a byte you drive yourself.

Bus strobes last microseconds — invisible at 60 Hz. So the capture hardware
**stretches** selected pulses: a `/RD` or `/WR` glows for about 50 ms, long
enough to see. Reading memory makes the data lamps shimmer with your program's
traffic; a HALT lights the halt lamp. This is honest instrumentation, at
blinky-light speed.

Programmatic control lives at `$A0`–`$A7`: global brightness (classic `scale8`
dimming — these LEDs can be *blinding*), a streaming port that programs each
LED's ON and OFF color (OFF is usually a dim glow, not dark, so a zeroed
register still breathes faintly), a 256-entry mapping table per profile, and a
framebuffer mode for software that just wants to paint. There are **8
profiles** — one can paint the registers, another the buses, another your
telemetry — switched instantly from software, or **live from the OSD** in a way
that is completely invisible to the running program (port `$A7` reads back what
the Z80 wrote, not what the human overrode to).

Profiles are authored in **YAML** — you name the signals (`ADDR`, `DATA`,
`REG_AF`, `PC`, `STROBES`…) and give per-signal colors — and the
`fpprofile.py` tool bakes them into a 16,400-byte `.FPP` file mounted from the
OSD. Your register map is
a *software* artifact now. Dream it, edit the YAML, re-mount, and the panel
physically re-interprets the machine.

**Coming next (P2):** the other half of the IMSAI ritual — switches. A bridge
board design exists for **32 toggle switches** (dual personality: panel inputs
*and* classic sense switches readable by your Z80 code at `$FC`–`$FF`),
two-way function levers for EXAM/DEPOSIT/START/BP-ARM/FREEZE, a rotary
encoder, and a hardware **panel engine** that executes Reset, Step, Examine and
Deposit *in the FPGA itself* — so the panel works even if the monitor firmware
(§6) is absent or hung. The lights are shipping today; the switches are on the
drawing board — literally: a **PCB design** to interface the panel to the
MiSTer's USER header and drive the LED string is upcoming hardware work (§8).

---

## 5. CamelFORTH: an ANS Forth that boots like an operating system

MrZ80 ships a port of the classic **CamelFORTH** for the Z-80, and treats it
as a first-class citizen of the system rather than just another program. It
runs two ways, from the same dictionary:

* **Under CP/M** — a normal `.COM` application using BDOS for console and
  files.
* **Standalone, on bare metal** — a bootable `.BIN` with no OS at all: direct
  ACIA I/O, direct memory, and *you* own the machine. This is where it stops
  being merely a programming environment and becomes the **diagnostic and
  exploration monitor** for the hardware.

Boot the standalone kernel from the OSD and you have a full ANS Forth REPL at
the console within a blink. Because Forth is live on the bare hardware,
diagnostics are one line long:

* `PC@` / `PC!` expose raw `IN`/`OUT` port access — poke the RTC, snapshot
  the benchmark timers, write the LED latch at `$FF` and watch the panel.
* `MS@` / `US@` return the monotonic millisecond/microsecond hardware counters
  as 32-bit doubles — real timing measurements, not a software tick.
* `@` `C@` `!` `C!` roam the four mapped frames; the MMU direct-access pointer
  lets you walk all 128 MB of physical SDRAM; and the block package loads
  **1 KB Forth blocks straight out of the OSD-loaded 8 MB RAM disk** — code,
  saved state, and a screen editor live in a block device you can refill from
  your PC in seconds.
* The blocks that ship with the image include a line-oriented **screen
  editor**, `DUMP`/`DUMPW` hex dumps, double-number utilities, a benchmark
  suite (`timed`, `utimed`, `times`, `bench`) that measures the machine with
  its own hardware timers, and **`DISASM`** — a full Z-80 disassembler
  (`HEX 100 10 DISASM`) that even decodes the custom instructions below. It is
  the same source the SSP monitor's `U` command uses (see §6).

### Custom Z-80 instructions, forged for Forth

Here is the part that makes this core genuinely unusual: **the CPU itself was
modified to run Forth faster.** The T80 decoder implements instructions in
previously-undefined `ED`-prefixed slots — harmless NOPs on a stock Z-80, so
software that avoids them is untouched:

| Mnemonic | Encoding | Operation | T-states | Stock Z-80 equivalent |
|----------|----------|-----------|---------:|-----------------------|
| `F_NEXT` | `ED 92` | `PC ← (DE)`; `DE ← DE+2` | 14 | the Forth `NEXT` primitive: 7 instructions, 38 T |
| `PUSHIX rr` | `ED C5/D5/E5` | store BC/DE/HL at `IX−1,IX−2`; `IX ← IX−2` | 14 | 4 instructions, 58 T |
| `POPIX rr` | `ED C1/D1/E1` | load BC/DE/HL from `(IX)`; `IX ← IX+2` | 14 | 4 instructions, 58 T |

`F_NEXT` *is* the inner interpreter of a threaded Forth: one instruction that
fetches the next word's address and advances the instruction pointer.
`PUSHIX`/`POPIX` make `IX` a true return-stack pointer, which is exactly how
CamelFORTH organizes its return stack. None of them disturb the flags.

The measured payoff on this hardware (the same loop benchmark, timed by the
on-chip µs timer):

| Kernel | From block RAM | From SDRAM |
|--------|-------------:|-----------:|
| Stock Z-80 sequences | 13.0 s | 19.3 s |
| Custom `F_NEXT`/`PUSHIX`/`POPIX` | **9.0 s** | **13.4 s** |

About **30% faster, in hardware, for a handful of two-byte opcodes** — and the
CP/M application and the standalone kernel are the same dictionary. CamelFORTH wraps
the encodings in macros (`CUSTNEXT`, `CUSTRSP`) so one source builds for a
stock Z-80 or for this core; a kernel built with them verifies at startup that
the CPU really implements them. No assembler knows the mnemonics — you emit
`DB 0EDh,092h` like a pioneer, exactly as you would have coded undocumented
opcodes in 1979. (When RomWBW's bundled CamelFORTH runs on this core, it gets
the same wind.)

---

## 6. The SSP: ODT reborn on a RISC-V core

The **System Support Processor (SSP)** is the most ambitious piece of the
project: a second, complete soft CPU resident in the FPGA alongside the Z80 —
a **FemtoRV32** RV32IMC core running **Mecrisp-Quintus Forth** — whose whole
job is to know everything the Z80 is doing and let you interrogate it.

Why would you want that? Because MrZ80's designers grew up on the **ODT
consoles** of the 1970s: the PDP-11's `.` prompt, Intel's and IMSAI's
examine/deposit monitors. Type a letter and an address, and the machine shows
you memory; poke bytes; land the CPU wherever you like. MrZ80's SSP is that
experience, *improved in every dimension the FPGA makes possible*.

### Using it

1. Turn on **SSP Monitor** in the OSD (with it off, the subsystem is
   electrically indistinguishable from absent — the Z80 machine is untouched).
   Turn on **SSP Serial Escape** if you want the keyboard hatch.
2. While CP/M (or anything else) runs, type **`^]`** on the serial console.
   The escape is recognized **in hardware** in the RX stream and consumed —
   the running software never sees the byte.
3. The Z80 is parked **at an instruction boundary** — never mid-instruction:
   the CPU's own freeze logic grants the bus only where the next state is an
   M1 cycle, prefix-aware, honoring the EI shadow and completing interrupt
   acknowledges. The console silently hands over to the monitor:

```
MRZ80 SSP MONITOR  ? = HELP
.R
PC=00E9 SP=FFFE AF=0044 BC=0000 DE=0000 HL=00C3
IX=0000 IY=0000 AF'=0000 BC'=0000 DE'=0000 HL'=0000
I=00 R=07 IM=1 IFF=3
.
```

The command set is deliberately tiny and classic:

| Command | Function |
|---------|----------|
| `E [aaaa [n]]` | **Examine** — hex+ASCII dump; a bare `E` carries on where the last one stopped. Logical address by default, physical after `PHY` |
| `D [aaaa]` | **Deposit** — prompts with each address and its current byte; type a value to replace it, a bare CR to skip, `.` to end |
| `G [aaaa]` | **Go** — resume where you stopped, or start the Z80 at an arbitrary address via a hardware reset trampoline that injects `JP aaaa` at the reset vector |
| `R` | **Registers** — PC, SP, AF, BC, DE, HL, IX, IY, the whole shadow bank, I, R, interrupt mode and flip-flops |
| `I aaaa` / `O aaaa dd` | **Input/Output** — master Z80 I/O ports while the CPU is parked |
| `MAP` | **MMU decode** — the four logical frames and the physical pages they point at |
| `S [n]` | **Single-step** — one line per instruction: `PC`, its bytes, the registers after the step and the **disassembled next instruction**; CR repeats; any key breaks out. `HALTED` when the CPU halts. |
| `U [aaaa [n]]` | **Unassemble** — address, instruction bytes and Z-80 mnemonic, `n` instructions (default 16; a bare `U` carries on); `JR`/`DJNZ` show the target address; understands `F_NEXT`/`PUSHIX`/`POPIX`; any key breaks out. The decoder is the same source CamelFORTH uses (`forth/disasm/`) |
| `PHY` / `LOG` | Switch examine/deposit between the **28-bit physical** SDRAM view (up to 7-digit addresses, `0000000`–`7FFFFFF`) and the Z80's logical, MMU-translated view |
| `F` | Drop out of the ODT skin into the **raw Mecrisp Forth** that the monitor is written in |

That last one is the trick the PDP-11 never had: the monitor *is* Forth. The
ODT command layer is a friendly skin over a live, extensible RISC-V Forth
dictionary — you can define new commands on the console itself, in the same
keystrokes. The monitor also never *disturbs* what it watches (the design's
"state-neutral observation" invariant): registers come from side taps in the
T80, the MMU map is read back through the MMU's own ports (reading them has
no side effects), and physical memory access happens only while the Z80 is
parked, by a small client that borrows the SDRAM wiring for one transaction
at a time — it cannot even request the bus while the Z80 runs, and the Z80's
bus multiplexer is untouched. The Z80's own state, ports and MMU come back
bit-identical when you type `G`.

### A taste of it: physical memory and single-stepping

*(An illustrative session — the format is exact, the contents are made up.)*

```
.PHY
PHYSICAL (SDRAM, 28-BIT)
.E 2000000 10
2000000: 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F  ................
.LOG
LOGICAL
.S 3
0100: C3 00 50 00 AF=005A BC=0000 DE=0000 HL=0000 SP=FFFE JP 5000h
5000: 21 00 80 7E AF=005A BC=0000 DE=0000 HL=0000 SP=FFFE LD HL, 8000h
5003: 7E 23 B7 20 AF=005A BC=0000 DE=0000 HL=8000 SP=FFFE LD A, (HL)
.U 5003 4
5003: 7E            LD A, (HL)
5004: 23            INC HL
5005: B7            OR A
5006: 20 FB         JR NZ, 5003h
```

`PHY` lets you look at — and patch — any byte of the 128 MB of SDRAM by its
true physical address, regardless of how the MMU currently maps the Z80's four
windows: handy for checking that a RomWBW bank swap put the bytes where you
meant. (The 64 KB of fast block RAM at `0x8000000` is reachable through the
Z80's logical view only; a physical address at or beyond `08000000` just gets a
`?`.) `S` retires one instruction at a time with a hardware one-shot — release,
wait for the CPU to actually leave the parked state, re-park at the next
boundary — and prints the next instruction's address, bytes and disassembly
plus the registers after the one that just ran, so a trace reads like a
listing. The interrupt line is masked for the whole sequence, so a clock tick
cannot hijack it. `U` lists code the same way without running anything.

### One disassembler, two Forths

The disassembler behind `S` and `U` is a Z-80 decoder written in Forth — and
the very same source file also runs **on the Z-80 itself**, inside
CamelFORTH. Type `HEX 0 2 DISASM` at the standalone Forth prompt and the
Z-80 reads its own memory and decodes its own boot vector with a disassembler
that is itself running on that Z-80:

```
HEX 0 2 DISASM
0000: DI
0001: JP 008Dh
```

On the other side of the wall, the SSP's 32-bit RISC-V Forth runs the identical
text against the *parked* Z-80's memory — logical or physical, through the same
sequencer the `E` command uses. One source file, two cell sizes, two CPUs, two
Forths; a thin per-environment "port" supplies only the byte reader and the
output format, so a fix or a new instruction made once appears in both.

It knows the undocumented corners too (`IXH`/`IXL`, the `DDCB` register-copy
forms, the mirror encodings of `NEG`/`RETN`/`IM`) — and it knows this core's
three custom instructions *by name*, which no stock disassembler can do. Here
is CamelFORTH's own `>R` on a custom-instruction kernel, as the monitor's `U`
shows it:

```
.U 31C 3
031C: ED C5         PUSHIX BC
031E: C1            POP BC
031F: ED 92         F_NEXT
```

Three instructions are the whole word: push the old top of stack onto the
return stack, pop the new one off the data stack, run the inner interpreter.
(The same `>R` on a stock Z-80 is twelve instructions.)

The disassembler is trusted because it is tested to the bone, not because it
looks right. A repeatable check (`make -C forth/disasm check`, six seconds)
disassembles **all 1,784 instruction encodings** — every base opcode, the full
`CB`, `ED`, `DD`, `FD` and `DDCB`/`FDCB` pages, negative displacements, stacked
prefixes — in CamelFORTH (under a Z-80 emulator, loaded from the real Forth
blocks) *and* in Mecrisp (under QEMU). Each line of output is then fed back to
a Z-80 assembler and must reproduce the original bytes, and the two Forths
must print **byte-for-byte identical text**. Deliberately breaking either the
decoder or the 16/32-bit portability makes the check fail, which is the point.
(It also found a handful of bugs in an earlier, hand-written version — the
sort of thing that only shows when you assemble the output back.)

### Engineering underneath (because you'll appreciate it)

* **Sovereignty and watchdogs.** The Z80 owns the console at power. If the
  monitor firmware ever dies or wedges, hardware watchdogs demote it and the
  Z80 machine carries on — a broken debugger can never brick a running
  computer. Transient monitor holds of the Z80 are capped at ~4 ms.
* **Transparency by default.** Without OSD `OM`, no byte value on the wire has
  special meaning — WordStar `^K` sequences and binary uploads are safe. Only
  an enabled, single configurable escape character (`ESC_CHAR`, default `^]`)
  triggers a hand-over.
* **Interrupts held during stepping** so a 50 Hz clock tick can't hijack your
  trace; pending sources stay visible.
* **Roadmap:** breakpoints with stop-before-execute (the hardware injects a
  self-loop at the matched opcode so `PC` is exactly the breakpoint), a
  16-entry jump-history ring, T-state and machine-cycle stepping, downloadable
  monitor firmware and Forth source packs *via the OSD* (no FPGA reflash to
  update the monitor), an HDMI+keyboard console, and integration with the
  switch panel and lamp pages (profile 7 is reserved, in hardware, for the
  monitor's own lamp display). A mailbox at Z80 ports `$D0`–`$D3` is reserved
  as the seed of HBIOS cooperation — the RomWBW world talking to the Forth
  world deliberately, not just observingly.

**Status today:** the full escape → park → examine/deposit → resume cycle has
been proven on hardware, as has transparency with the SSP disabled. The
later commands — `I`/`O`, `MAP`, single-step `S`, the `U` unassembler (and the
mnemonic on each `S` line, simulation-checked so far), and physical examine/deposit
under `PHY` — each passed a simulation campaign (including mutation testing,
and checks against the real T80 and the real SDRAM fabric) and then a check on
the bench. It's a live development, and §7 says how to follow it.

---

## 7. Status at a glance

| Area | State |
|------|-------|
| Z80 + MMU + SDRAM/BRAM memory system | Shipping and exercised on hardware |
| VGA ANSI terminal, serial console, RTC, timers, SD + image block devices | Working |
| Front panel: 256-LED panel, profiles, OSD override | Shipping |
| Front panel: switch panel + LED-driver PCB, hardware panel engine | PCB design upcoming; panel engine spec'd (P2) |
| CamelFORTH standalone & CP/M, custom instructions, RAM-disk blocks | Working |
| CP/M 2.2/3.0 boot images | Working |
| RomWBW (HBIOS + multi-boot) | **MVP** — boots and runs; bank-swap / peek-poke acceleration on the roadmap |
| AY-3-8910 PSG audio (possibly a stereo pair) | Roadmap |
| SSP monitor: escape/park/E/D/G/R | Proven on hardware |
| SSP: `I`/`O`, `MAP`, `S` (single-step), `PHY`/`LOG` (physical SDRAM examine/deposit) | Working — verified in simulation and on hardware |
| SSP: `U` (unassemble, shared with CamelFORTH's `DISASM`); `S` shows the next instruction | `U` working on hardware (owner, 2026-11-01); `S` mnemonic verified in simulation |
| SSP: breakpoints, T-state/machine-cycle stepping, BRAM-page physical access, panel integration | Roadmap |
| Legacy Grant Searle BASIC/monitor (`basmon`) | Still available as a bootable `.BIN` |

## 8. Room to grow

Headroom *is* a feature. The latest fit report puts the entire machine — CPU,
MMU, SDRAM controller, terminal, UARTs, front-panel engine, the whole
SSP — at **13,128 of 41,910 ALMs: about 31% of the FPGA's logic elements**,
with the block-RAM and DSP budgets similarly relaxed. Less than half the
fabric spoken for — barely a third — is not a finish line; it's real estate.
An SDRAM cache, another serial port, new peripherals, whatever gets dreamed up
next: there's a place for it.

* **A real front-panel PCB.** Upcoming hardware design: a board that
  interfaces to the MiSTer's USER header, drives the 256-WS2812 light strip,
  and carries the toggle bank, function levers and encoder from §4's panel
  engine. The IMSAI reference becomes physical.
* **PSG audio on the roadmap.** Planned: the General Instrument
  **AY-3-8910** — the three-voice programmable sound generator (three square
  waves, noise, envelopes) that sang in the ZX Spectrum 128K, the Amstrad
  CPC, the Atari ST and countless arcade cabinets — and maybe *two* of them
  for stereo. Authentic 1980s sound for a 1970s CPU, inside a 2010s FPGA.
* **The SSP will keep evolving — because it's just software.** The monitor is
  not etched anywhere: it's Forth code in a downloadable ROM image that the
  HPS loads when the core starts. New commands — breakpoints, search,
  another console skin — mean *new Forth source*, re-mounted from the OSD, not
  an FPGA recompile (the unassembler was the first such addition, and it was
  written once for both Forths); even the bridge's register file is generated
  from one CSV so hardware and firmware grow together. The pace so far — from
  no monitor at all to escape, park, examine, deposit, step and physical
  memory access in a few dozen development rounds — suggests the command set
  will keep getting taller.
* **Customization is the design idiom.** ANSI terminal emulation you can
  extend in the fabric, panel maps that are YAML data files, boot behavior and
  serial routing chosen in the OSD, the debugger written in an interactive
  Forth… On a machine whose hardware is reconfigurable by design, the line
  between user and designer is thin on purpose.

## 9. Where to read more

| Document | Contents |
|----------|----------|
| [`README.md`](../README.md) | Project overview, console wiring, OSD, build |
| [`HARDWARE.md`](../HARDWARE.md) | Authoritative memory map, full I/O port maps, boot/reset semantics, custom instructions |
| [`Components/FRONTPANEL/README.md`](../Components/FRONTPANEL/README.md) | Front-panel datasheet, profile file format, capture chain |
| [`forth/README.md`](../forth/README.md) + [`doc/FORTH-GLOSSARY.md`](FORTH-GLOSSARY.md) | CamelFORTH port notes and complete word glossary |
| [`doc/SSP_DESIGN.md`](SSP_DESIGN.md) / [`doc/SSP_STATUS.md`](SSP_STATUS.md) | SSP architecture and decisions / live milestone status |
| [`doc/SSP_PANEL_UX.md`](SSP_PANEL_UX.md) | The classic switch-panel user-experience spec |
| [`HISTORY.md`](../HISTORY.md) / [`REQUIREMENTS.md`](../REQUIREMENTS.md) | Design rationale, development log, roadmap |

*Stop-hazards are for 1978. On MrZ80 the machine glows, the Forth answers,
and the `.` prompt is waiting.*

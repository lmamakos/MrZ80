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

* **128 MB of SDRAM** — main RAM, physical addresses `0x0000000`–`0x7FFFFFF`,
  at essentially block-RAM speed (§8).
* **64 KB of on-FPGA block RAM** — the fastest memory in the machine, at
  physical `0x8000000`; the OSD can load a boot image straight into it.
* An **MMU** (compatible with the RomWBW **Z2** platform) maps four 16 KB
  frames anywhere in the resulting 28-bit / 256 MB physical address space.
  The Z80's 64 KB logical address space is thus four live pages over a
  quarter-gigabyte address space — exactly the banked model RomWBW expects.

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
* **Boot Load Target** (`SDRAM` / `Block RAM`) — where that image lands: SDRAM
  at address 0 as usual, or the 64 KB of on-FPGA block RAM for a run at the
  machine's fastest memory. Manual picks only; a sticky auto-load uses SDRAM.
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
* **SSP Monitor / SSP Serial Escape / SSP Console / Enter SSP Monitor / Reset
  SSP** — enable and use the embedded debug console (§6), on the serial port or
  on its own screen with the keyboard. **SSP Monitor ROM** (`.MRZ`) loads a new
  monitor firmware image without touching the running Z80.
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
is physically attached to the core. Under RomWBW both are consoles at once: the
serial port is unit 0, the screen and keyboard unit 1, and a key pressed on
either at the boot loader prompt takes the console there. The arrow, Home/End,
Page and function keys send the usual VT100/xterm sequences.

### Booting, honestly

The MrZ80 boot path today is: core loads → pick (or auto-load) a Boot Rom
Image → the Z80 runs it. CP/M and the standalone CamelFORTH kernel boot this
way, and the **RomWBW port exists as an MVP — a minimum viable product**:
HBIOS and the multi-boot environment come up on the banked-memory MMU and the
block devices and run. What "viable, not yet luxurious" means today: the
banked paths RomWBW leans on need measuring and tuning under a real workload
(the MrZ80 HBIOS platform and its drivers now exist; §9 records them). The memory
underneath them is not the problem — SDRAM runs within 0.7% of block RAM (§8),
and RomWBW's hot banks can be placed in block RAM by programming the MMU. One
RomWBW ROM multi-boots the family — CP/M 2.2 and 3.0, ZSDOS, Z-System,
CamelFORTH, N8DOS, and the other HBIOS-aware guests.
See §9 for the RomWBW port and §7 for the status snapshot.

---

## 4. Maximum Blinkenlights

The IMSAI 8080 front panel — rows of lamps for address, data and status, a
bank of toggle switches — is the ur-image of the microcomputer age. It was
always a compromise: you could probe a few bus wires because that's all the
edge connector and your patience allowed.

MrZ80 asks: *what if the CPU lives in an FPGA, and every internal signal is
already visible?* Its answer is a strip of **256 WS2812/SK6812 RGB LEDs driven
from a single FPGA pin** (the MiSTer USER header), refreshed 75 times a
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
enough to see, and so do four interrupt lamps (the interval timer's request,
the two UARTs' interrupt outputs, and `INT` as the CPU sees it). Reading memory
makes the data lamps shimmer with your program's traffic; a HALT lights the
halt lamp. (RomWBW ticks the timer every 20 ms, faster than the hold, so its
interrupt lamps simply glow while it runs.) This is honest instrumentation, at
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

Kernels and library: `make -C forth install` copies `camel80.bin` (the stock
kernel), `camelf.bin` (custom-instruction kernel), `camel80cpm.com` for CP/M, and
`forth.blk` — the library you mount as **8MB Disk Image**. Typing `blocks`
loads the block package and screen editor, and three words then cover "what is
this machine doing": `SEE` reads a Forth definition back as source, `DISASM`
disassembles the machine code underneath it, and the SSP's `U` (§6) does the
same from *outside*. What to load, and what each word does: `forth/README.md`
and `doc/FORTH-GLOSSARY.md`.

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

About **30% faster, in hardware, for a handful of two-byte opcodes**: the
T-state counts above are architectural, and on the board a CamelFORTH loop ran
that much faster on the custom kernel. (Those wall-clock figures predate the
memory work in §8; re-recording them on the current core is an open item in
`REQUIREMENTS.md`.) The CP/M application and the standalone kernel are the same
dictionary: CamelFORTH wraps the encodings in macros (`CUSTNEXT`, `CUSTRSP`) so
one source builds for a stock Z-80 or for this core, and a kernel built with
them verifies at startup that the CPU really implements them. No *assembler*
knows these mnemonics — you emit `DB 0EDh,092h` like a pioneer, exactly as you
would have coded undocumented opcodes in 1979. The disassembler does know them,
and prints them by name (§6). (When RomWBW's bundled CamelFORTH runs on this
core, it gets the same wind.)

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
   the running software never sees the byte. (Or pick **Enter SSP Monitor** in
   the OSD; with **SSP Console** set to Video the monitor comes up on its own
   green-on-black screen with the keyboard, the Z80's screen put aside
   untouched until `G`.)
3. The Z80 is parked **at an instruction boundary** — never mid-instruction:
   the CPU's own freeze logic grants the bus only where the next state is an
   M1 cycle, prefix-aware, honoring the EI shadow and completing interrupt
   acknowledges. The console silently hands over to the monitor:

```
MrZ80 SSP MONITOR  ? = HELP
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

*(An illustrative session: the format is exactly what the monitor prints; the
contents come from a simulated machine.)*

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
sort of thing that only shows when you assemble the output back.) It is not
free: the decoder took the monitor's dictionary from 11.7 KB to 22.4 KB — which
is why the monitor's ROM has since doubled to 128 KB, leaving a 108 KB
dictionary window with room to grow.

### Building your own monitor

The monitor is a ROM image, and making a new one takes one command:

```sh
make -C ssp/fw image               # check, then build  ->  ssp/fw/build/mrz80-ssp.mrz
make -C ssp/fw check               # just the quick compile check (about 2 seconds)
make -C ssp/fw install             # build if needed, then scp it to the MiSTer
make -C ssp/fw                     # the image plus the factory ROM (below)
```

The Makefile rebuilds only when an input changed, so running it again after
an edit is always safe. It drives `tools/ssp_image.py`, which you can also run
directly (`-o FILE` to put the image elsewhere, `--dest user@host:/path` for
`--install`).

Copy the `.mrz` to the MiSTer (`install` puts it at
`/media/fat/games/MrZ80/mrz80-ssp.mrz`; `make -C ssp/fw install
MISTER_DEST=user@host:/path` changes that), pick it with the OSD's **SSP Monitor ROM** item and **Reset SSP**. The
Z80 side keeps running throughout, and no FPGA rebuild is involved.

**What goes in.**

| Input | What it is |
|-------|-----------|
| `ssp/fw/apps/monitor.fs` | The monitor itself: every command, the banner, the prompt loop. This is the file you edit. Its `\ @include <file>` lines splice in shared source such as the Z-80 disassembler, `forth/disasm/z80dis.fth` |
| `ssp/regs/ssp_regs.csv` | The bridge's register file, the one source for both RTL and firmware. It is generated into `ssp/fw/ssp-regs.fs`; the build picks out the `SSP_*` constants that `monitor.fs` mentions *by name*, so a register you add to the CSV is usable in Forth by its name |
| `ssp/fw/*.s` + Mecrisp-Quintus | The Forth kernel for the RV32 core: our three board-specific assembly files plus the Mecrisp-Quintus source tree, which is referenced in place (`~/mecrisp-quintus/mecrisp-quintus-source`, or set `MECRISP`) |

The tools needed are the `riscv64-unknown-elf-` binutils, `qemu-system-riscv32`,
Verilator and Python 3.

**What the build does.** First comes the **compile check**: the same kernel
built for qemu is fed `compiletoflash` and `monitor.fs`, and any line that
doesn't answer `ok.` (an unknown word, a stack error) stops the run in a couple
of seconds, before the slow step. The check can't exercise the SSP registers, and
its dictionary can't be loaded on the board, because that image is linked at qemu's
addresses. Then the **image build** (3 to 4 minutes) types the monitor into the *actual
SSP RTL* running in a Verilator model, at the board's real addresses. It dumps the
ROM, checks that the kernel bytes are untouched, and boots the result once to
prove the monitor's words are resident from power-on.

**What comes out** (all under `ssp/fw/build/`, which git ignores):

| Output | What it is |
|--------|-----------|
| `mrz80-ssp.mrz` | **The image to mount**: 128 KiB, kernel plus compiled dictionary (`-o` changes the name) |
| `mecrisp-ssp-app.bin` / `.hex` | The same image as the build leaves it: the `.bin` is what `mrz80-ssp.mrz` is copied from, the `.hex` is what the simulator lanes load |
| `dict.bin` / `.hex` | Just the dictionary part, from `0x5000` up, handy for diffing two builds |
| `mecrisp-ssp.hex` / `.bin` / `.elf` | The bare kernel with an empty dictionary |

The log of the slow step is `/tmp/opencode/ssp_image.log`. The image baked into
the FPGA bitstream, `ssp/fw/forth_rom.mif`, is a separate, committed artifact:
`make -C ssp/fw rom` regenerates it from the same image (plain `make -C ssp/fw`
does both), and it only reaches the board with the next FPGA build, so everyday
testing never needs it.

**Why this belongs in a tour.** A new monitor command is a Forth word in one
text file. It is compiled and tested in seconds, built into a ROM image in
minutes, and mounted from a menu while the machine it observes carries on. The
same pipeline carries whatever else you teach the SSP, whether that is a new
register in the CSV, a shared piece of Forth or a different monitor altogether.
That is the sense in which the SSP is extensible: the hardware only provides the
bridge and the kernel runs whatever dictionary is in the ROM.

### Engineering underneath (because you'll appreciate it)

* **Sovereignty and watchdogs.** The Z80 owns the console at power, and the
  hardware escape works even with the monitor firmware dead. Transient monitor
  holds of the Z80 are capped at ~4 ms by a hardware watchdog. A *parked* Z80
  waiting at a hung monitor prompt is not yet released automatically: the way
  out is the OSD's **Reset SSP**, which restarts the monitor and leaves the Z80
  and its memory untouched. (Replacing this with a watchdog task inside the
  monitor's own Forth, once it can multitask, is the planned direction.)
* **Transparency by default.** Without the OSD's **SSP Serial Escape**
  (`OM`), no byte value on the wire has special meaning — WordStar `^K`
  sequences and binary uploads are safe. Only an enabled, single configurable
  escape character (`ESC_CHAR`, default `^]`) triggers a hand-over; with `OM`
  off, the only way in left is deliberately picking **Enter SSP Monitor** in
  the OSD.
* **Interrupts held during stepping** so a 50 Hz clock tick can't hijack your
  trace; pending sources stay visible.
* **Roadmap:** breakpoints with stop-before-execute (the hardware injects a
  self-loop at the matched opcode so `PC` is exactly the breakpoint), a
  16-entry jump-history ring, and
  integration with the switch panel and lamp pages (profile 7 is reserved by
  design for the monitor's own lamps). A mailbox at Z80 ports `$D0`–`$D3` is
  reserved as the seed of HBIOS cooperation — the RomWBW world talking to the
  Forth world deliberately, not just observingly.

**Status today:** the full escape → park → examine/deposit → resume cycle has
been proven on hardware, as has transparency with the SSP disabled. The later
commands — `I`/`O`, `MAP`, single-step `S`, the `U` unassembler (and the
mnemonic on each `S` line), and physical
examine/deposit under `PHY` — each passed a simulation campaign (including
mutation testing, and checks against the real T80 and the real SDRAM fabric)
and then a check on the bench. It's a live development, and §7 says how to
follow it.

---

## 7. Status at a glance

*As of 2026-11-02.*

| Area | State |
|------|-------|
| Z80 + MMU + SDRAM/BRAM memory system | Shipping and exercised on hardware |
| Memory speed — SDRAM within 0.7% of block RAM | Working on hardware |
| VGA ANSI terminal, serial console, RTC, timers, SD + image block devices | Working |
| Front panel: 256-LED panel, profiles, OSD override | Shipping |
| Front panel: switch panel + LED-driver PCB, hardware panel engine | PCB design upcoming; panel engine spec'd (P2) |
| CamelFORTH standalone & CP/M, custom instructions, RAM-disk blocks | Working |
| CP/M 2.2/3.0 boot images | Working |
| RomWBW (HBIOS + multi-boot) | **MVP** — the MrZ80 HBIOS platform (MMU, consoles, ROM/RAM disks, HPS and SD disks, RTC, front-panel LEDs) comes up and runs; the 50 Hz interval-timer tick driver is built but awaiting a hardware check, and tuning under a real workload remains (§9) |
| AY-3-8910 / YM2149 PSG audio: two chips at `$50`/`$51` and `$68`/`$60`, stereo mixers with OSD Mono/ABC/ACB panning (`REQUIREMENTS.md` item 6) | Working on hardware (owner, 2026-11-04: `psgtest`, RomWBW `TUNE.COM`); simulation lane `make -C sim psg` |
| Programmable millisecond interval timer and Z80 `INT` source, ports `$D0`-`$D3` (`REQUIREMENTS.md` item 7) | Working on hardware (owner, 2026-11-02); RomWBW tick driver `itim.asm` written 2026-11-02, hardware check pending (§9) |
| SSP monitor: escape/park/E/D/G/R | Proven on hardware |
| SSP: `I`/`O`, `MAP`, `S` (single-step), `PHY`/`LOG` (physical SDRAM examine/deposit) | Working — verified in simulation and on hardware |
| SSP: `U` (unassemble, shared with CamelFORTH's `DISASM`); `S` shows the next instruction | Working on hardware (owner, 2026-11-01 and 2026-11-02) |
| SSP: breakpoints, BRAM-page physical access, panel integration | Roadmap |
| SSP: T-state/machine-cycle stepping | Shelved: no schedule |
| SSP: monitor ROM (128 KB) loaded from the OSD, no FPGA rebuild; words compiled into it survive Reset SSP | Working on hardware (owner, 2026-11-01). Forth source packs from the OSD: not planned for now |
| SSP on its own screen + keyboard; OSD "Enter SSP Monitor" | Working on hardware (owner, 2026-11-02) |
| SSP monitor colours: your input bright green, the monitor's output bright blue | Working in simulation; hardware check pending |
| RomWBW with two consoles (serial + screen/keyboard) via the stock ACIA driver | Working on hardware (owner, 2026-11-02) |
| Legacy Grant Searle BASIC/monitor (`basmon`) | Still available as a bootable `.BIN` |

## 8. Room to grow

Headroom *is* a feature. The latest fit report puts the entire machine — CPU,
MMU, SDRAM controller, terminal, UARTs, front-panel engine, the whole
SSP — at **14,191 of 41,910 ALMs: about 34% of the FPGA's logic elements**,
with under half the block-RAM bits and a third of the DSPs in use. Less than
half the fabric spoken for — barely a third — is not a finish line; it's real
estate. Another serial port, new peripherals, whatever gets dreamed up next:
there's a place for it.

* **The memory penalty, designed out instead of cached over.** SDRAM used to
  cost about half again as much time as block RAM. A series of timing and
  protocol fixes — a clock-enabled CPU, waits released the cycle the data
  arrives, speculative reads and posted writes — brought that to **0.7%**: the
  CamelFORTH benchmark now runs at effectively the same speed from either. The
  block-RAM cache designed to fix the problem is shelved, and the fast RAM is
  free for other uses. How, and what was deliberately not done:
  `doc/SDRAM_REWORK_PLAN.md`.
* **A real front-panel PCB.** Upcoming hardware design: a board that
  interfaces to the MiSTer's USER header, drives the 256-WS2812 light strip,
  and carries the toggle bank, function levers and encoder from §4's panel
  engine. The IMSAI reference becomes physical.
* **PSG audio, now in.** The General Instrument **AY-3-8910** — the
  three-voice programmable sound generator (three square waves, noise,
  envelopes) that sang in the ZX Spectrum 128K, the Amstrad CPC, the Atari ST
  and countless arcade cabinets — and *two* of them, in stereo, as a YM2149
  pair with programmable mixers. RomWBW's stock AY driver finds the first chip
  and `TUNE.COM` plays on hardware; the second chip is mapped for two-chip
  TurboSound players such as vibetune. Authentic 1980s sound for a 1970s CPU,
  inside a 2010s FPGA (`HARDWARE.md`, "PSG sound").
* **The SSP will keep evolving — because it's just software.** The monitor is
  not etched anywhere: it is Forth source assembled into a ROM image that ships
  in the core, and even the bridge's register file is generated from one CSV so
  hardware and firmware grow together. A new monitor is a file, not an FPGA
  build: rebuild the ROM image (`tools/ssp_image.py`, see §6) and load it from the
  OSD, and the Z80 never notices. Words can even be compiled straight into the ROM's dictionary
  window on the running board. The pace so far — from no monitor at all to
  escape, park, examine, deposit, step, physical memory and disassembly in a
  few dozen development rounds — suggests the command set will keep getting
  taller.
* **Customization is the design idiom.** ANSI terminal emulation you can
  extend in the fabric, panel maps that are YAML data files, boot behavior and
  serial routing chosen in the OSD, the debugger written in an interactive
  Forth… On a machine whose hardware is reconfigurable by design, the line
  between user and designer is thin on purpose.

## 9. RomWBW on the MrZ80

RomWBW is the reason the MrZ80 has an MMU, so it deserves a section of its own.
The port lives in a fork of the RomWBW tree (`~/RomWBW`, platform id
`PLT_MRZ80`). This section is the one place that records what is MrZ80-specific
in that fork: how it is built, how it maps onto the hardware, which drivers it
uses, and the decisions and gotchas that came out of bringing it up. (The RomWBW
tree's own `AGENTS.md` carries the same facts from the RomWBW side.)

### Building and loading it

```
cd ~/RomWBW/Source/HBIOS
ROM_PLATFORM=MRZ80 ROM_CONFIG=std bash Build.sh      # -> Binary/MRZ80_std.rom (+ .upd, .com)
```

`MRZ80_std.rom` **is** the `.BIN` the core loads: pick it as the **Boot Rom
Image** in the OSD and the machine boots RomWBW. It is 512 KB: four 32 KB HBIOS
banks (HBIOS, loader/OS, apps, utilities) followed by a 384 KB ROM disk. There
is also an `MRZ80_debug` configuration that turns HBIOS diagnostics and driver
tracing up and waits five seconds before booting, for bring-up.

Configuration is RomWBW's usual cascade: `cfg_MASTER.asm` defines every setting,
`cfg_MRZ80.asm` holds the MrZ80 defaults, and `Config/MRZ80_std.asm` /
`MRZ80_debug.asm` are the builds. Override with `.SET` in a config file, never
by editing the master.

### Memory

| | |
|--|--|
| **MMU** | RomWBW's stock `MM_Z2` memory manager, unmodified. Frame registers `MPGSEL_0..3` are ports `$B0`–`$B3`. The Z2 "MMU enable" write is skipped for this platform because the MrZ80 MMU is always on, and `MPGENA` is pointed at `$BD`, a reserved write-ignored port, as belt and braces. |
| **ROM** | `ROMSIZE=512`: the `.BIN` the core preloads into SDRAM at physical address 0. The core starts the Z80 at `$0000` with the boot ROM already disabled, so RomWBW never writes the `$38` ROM-disable port. |
| **RAM** | `RAMSIZE=2048`: the SDRAM directly above the ROM image. |
| **Banks** | 16 ROM banks (12 are the 384 KB ROM disk), 64 RAM banks (48 are the 1536 KB RAM disk), 11 application banks. The common top 32 KB is the last two pages of RAM. |
| **CPU** | `CPUOSC=10000000`, fixed speed (50 MHz ÷ 5). |

### Drivers and ports

Everything is a stock RomWBW driver except the block device and the timer.

| Function | Ports | RomWBW driver and notes |
|----------|-------|-------------------------|
| Console 0, serial | `$82`/`$83` | Stock **ACIA** (6850) driver, unit 0, the boot console (`BOOTCON=0`). The `bufferedUART` follows the 6850 master-reset semantics the driver's detection relies on. The baud rate is set in the OSD, so `DEFSERCFG` is report-only. |
| Console 1, screen and keyboard | `$80`/`$81` | Stock **ACIA** driver, unit 1 (the VGA terminal). `AUTOCON` lets a key pressed on either console at the loader prompt take the console. |
| ROM and RAM disks | MMU | Stock **MD** driver. |
| Disk, HPS image | `$90`–`$97` | **`mrz80sd.asm`** (`MRZ80SDENABLE`), unit 1 of that driver: the mounted image, with size registers. 512-byte blocks moved with `INIR`/`OTIR`. |
| Disk, SPI SD card | `$88`–`$8F` | `mrz80sd.asm`, unit 2 (`MRZ80SDCNT=2`). It has no size registers, so the capacity comes from `MRZ80SD1BLKS` (default `$FFFFFF`, 8 GB). **Set it no larger than the real card**: a read past the end of the card hangs the controller until reset. Status bit 4 is "init busy" and stays set with no card; the driver times out and reports no media. |
| Clock/calendar | `$70`/`$71` | Stock **DS12RTC** driver for the DS12887 (`DS12RTC_BASE=$70`), seeded from the MiSTer Linux host at power-up. |
| Front panel LEDs | `$FF` | Stock **FP** driver on the output latch (`FPLED_IO=$FF`): HBIOS progress codes and disk activity show on the LEDs. |
| System tick | `$D0`–`$D3` | **`itim.asm`** (`ITIMENABLE`, `ITIMIO`), described next. |
| Sound | `$50`/`$51` | Stock **AY** driver (`ay.asm`), `AYENABLE=TRUE`, `AYMODE=AYMODE_COLECO`, `AY_CLK=1789772`: PSG device 1's ports are exactly the Coleco layout. Boot banner `AY: MODE=COLECO IO=0x50`, verified on hardware (2026-11-04). RomWBW drives one AY; device 2 (`$68`/`$60`) is for software such as vibetune. |

### The system tick: `itim.asm`

HBIOS keeps time with a periodic interrupt that increments `HB_TICKS`, rolls
into `HB_SECS`, and feeds SYSGET TIMER, the boot timeout and the drivers that
check `SYSTIM`. On the MrZ80 that interrupt comes from the **IntervalTimer**
(`Components/TIMER/IntervalTimer.vhd`, §2 and `HARDWARE.md`). It shares the Z80
`INT` pin with the two ACIAs' interrupt outputs (the three active-low requests
are ANDed); each handler checks its own device, as described below.

**Why a separate file.** Every RomWBW tick source (`sctim.asm`, `ctc.asm`,
`ez80tmr.asm`) is its own HBIOS module with PREINIT and INIT phases, and
`hbios.asm` only includes it under a config switch. `itim.asm` follows that
pattern, so the register spec, probe code and handler stay out of the 9,700-line
`hbios.asm`. The hook-up is one `#IF (ITIMENABLE) #INCLUDE "itim.asm"` block in
`hbios.asm`, a `TM_ITIM` system-timer type in `std.asm`, and the
`ITIMENABLE`/`ITIMIO` settings in `cfg_MASTER.asm`, `cfg_TEMPLATE.asm` and
`cfg_MRZ80.asm`.

**How it works.**

* **PREINIT** stops the timer and acknowledges anything pending first, because a
  Z80 reset clears the timer but an HBIOS restart in place does not. It then
  probes the device by writing different patterns to the two INTERVAL bytes and
  reading them back (an empty bus cannot return both). If the timer is there it
  adds `ITIM_INT` to HBIOS's interrupt-mode-1 call list.
* **INIT** programs INTERVAL = `1000 / TICKFREQ` ms and starts the timer
  **periodic** (RUN + IE + AUTO), so ticks do not drift. It prints
  `ITIM: IO=0xD0 INTERVAL=20MS`, or `NOT PRESENT` with no hardware.
* **`ITIM_INT`** checks STATUS bit 3 (INTREQ). If it is not set the interrupt is
  somebody else's and the handler returns "not handled" so the next entry in the
  list gets its turn. Otherwise it writes ACK (COMMAND bit 1), which releases the
  level request before the return, and chains to `HB_TIMINT`.

**Settings.** `INTMODE=1`, `TICKFREQ=50` (20 ms), `ITIMIO=$D0`. `TICKFREQ` must
divide 1000 because the interval is a whole number of milliseconds (10, 20, 25,
40, 50, 100 …); 60 Hz is not possible. The module refuses to assemble with
`INTMODE` other than 1 or with a `TICKFREQ` that does not divide 1000.

**Limits.** If interrupts stay masked for more than one interval the timer sets
its sticky OVERFLOW status bit, but the missed tick is not made up, so
`HB_TICKS` would lag a little. While the SSP single-step sequencer is armed `INT`
is masked at the CPU, so ticks are not delivered during a trace; the timer keeps
counting and the next interrupt arrives when stepping ends.

### `ACIAINTS`: interrupt-driven or polled ACIA receive

Turning on `INTMODE=1` for the timer has a side effect that is easy to miss.
RomWBW's ACIA driver ties **interrupt-driven receive** to `INTMODE`: with
`INTMODE=1` it reads characters only from its interrupt handler, into a ring
buffer, and its "character waiting?" test looks only at that buffer. When the
timer tick was added, the ACIAs' interrupt outputs were not yet connected to
`INT`, so receive interrupts would never have come and the console would have
printed but never received.

The fix was a new setting, **`ACIAINTS`**, in `acia.asm`: interrupt-driven
receive is used only when `ACIAINTS` is TRUE *and* `INTMODE` is 1. It defaults
to TRUE in `cfg_MASTER.asm`, so every other platform builds exactly as before
(RC2014's ROM is byte-identical with and without the change), and
`cfg_MRZ80.asm` set it FALSE, polling the ACIAs exactly as under `INTMODE=0`.

The ACIA interrupt outputs are now wired to `INT` (MrZ80 commit `6dc802c`), and
`cfg_MRZ80.asm` sets `ACIAINTS` TRUE (RomWBW commit `9f384430`): the build
reports `ACIA: … INTERRUPTS ENABLED` for both consoles. The three sources share
the level interrupt because every handler in the interrupt-mode-1 call list
checks its own device's status and returns "not handled" otherwise, so the next
entry gets its turn. Set `ACIAINTS` FALSE to go back to polling, for example
with an older core that lacks the ACIA wiring.

Related and worth knowing: with `INTMODE=1`, HBIOS and CP/M applications run with
interrupts enabled, so page zero needs the RST 38h vector in every bank.
RomWBW's boot loader and CBIOS already arrange that; bare-metal code you load as
a `.BIN` is not affected unless it executes `EI`.

### Status and what is next

| Item | State |
|------|-------|
| HBIOS platform: MMU, two ACIA consoles, ROM/RAM disks, HPS and SPI-SD disks, DS12887 clock, front-panel LEDs | Working on hardware (the two-console boot, owner, 2026-11-02) |
| Interval-timer tick (`itim.asm`) | Builds and assembles correctly; **not yet run on hardware**. Things to check: the `ITIM: … INTERVAL=20MS` line at boot, SYSGET TIMER advancing at 50 Hz, console input still working, and the first HPS/SD transfers with interrupts enabled |
| ACIA interrupt outputs wired to `INT`, `ACIAINTS=TRUE` | Done: HDL in MrZ80 `6dc802c`, RomWBW `9f384430`; the ROM builds with `ACIA: … INTERRUPTS ENABLED` on both consoles |
| Sound device driver (stock `ay.asm`, `AYMODE_COLECO`) | **Verified on hardware** (owner, 2026-11-04): the `AY: MODE=COLECO IO=0x50` line at boot and `TUNE.COM` playing PT3 tunes. Note that `TUNE.COM` needs its `-coleco` switch — its auto-detect reads the chip back at `$52`, which the core does not decode (`HARDWARE.md`, "PSG sound"). Vibetune single- and dual-chip play still to check |

## 10. Where to read more

| Document | Contents |
|----------|----------|
| [`README.md`](../README.md) | Project overview, console wiring, OSD, build |
| [`HARDWARE.md`](../HARDWARE.md) | Authoritative memory map, full I/O port maps, boot/reset semantics, custom instructions |
| [`Components/FRONTPANEL/README.md`](../Components/FRONTPANEL/README.md) | Front-panel datasheet, profile file format, capture chain |
| [`forth/README.md`](../forth/README.md) + [`doc/FORTH-GLOSSARY.md`](FORTH-GLOSSARY.md) | CamelFORTH port notes and tooling, and the kernel word glossary |
| [`forth/disasm/README.md`](../forth/disasm/README.md) | The Z-80 disassembler shared by CamelFORTH and the SSP monitor |
| [`doc/SSP_DESIGN.md`](SSP_DESIGN.md) / [`doc/SSP_STATUS.md`](SSP_STATUS.md) | SSP architecture and decisions / live milestone status |
| [`doc/SSP_REGS.md`](SSP_REGS.md) | SSP bridge register map (generated from `ssp/regs/ssp_regs.csv`) |
| [`doc/SSP_PANEL_UX.md`](SSP_PANEL_UX.md) | The classic switch-panel user-experience spec |
| [`HISTORY.md`](../HISTORY.md) / [`REQUIREMENTS.md`](../REQUIREMENTS.md) | Design rationale, development log, requirements and roadmap |
| [`AGENTS.md`](../AGENTS.md) | Contributor guide: repository layout, build commands, toolchain |
| `~/RomWBW/AGENTS.md`, `~/RomWBW/Source/HBIOS/itim.asm`, `mrz80sd.asm`, `cfg_MRZ80.asm` | The RomWBW side of §9: port status, drivers, configuration |

*Stop-hazards are for 1978. On MrZ80 the machine glows, the Forth answers,
and the `.` prompt is waiting.*

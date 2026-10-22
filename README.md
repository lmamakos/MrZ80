MrZ80 — a Z-80 MiSTer core for RomWBW
================

A Z-80 based system for the [MiSTer](https://github.com/MiSTer-devel/Main_MiSTer/wiki)
FPGA platform, originally a port of Grant Searle's MultiComp and now being
rebuilt around two goals:

1. **Host the [RomWBW](https://github.com/wwarthen/RomWBW) system software** —
   Wayne Warthen's ROM firmware, HBIOS driver layer and OS build environment for
   Z80/Z180 hardware, which multi-boots CP/M and a family of other operating
   systems. This drove the removal of the original MultiComp's non-Z-80 CPUs and
   the addition of a banked-memory MMU.
2. **A "Maximum Blinkenlights" front panel** — take the IMSAI 8080 motif to its
   over-the-top conclusion: because the CPU lives in an FPGA, every internal
   signal is observable, so drive **256 addressable RGB LEDs** with the state of
   the whole machine.

The core boots CP/M 2.2/3.0 today; RomWBW bring-up is ongoing.

## Credits & origin

Port of Grant Searle's MultiComp to the MiSTer by Louis Mamakos.

Ported by Cyril Venditti and Fred VanEijk.

Updated by S0urceror to use MiSTer image files, use all 4 machine types, and
have the MiSTer UART connected to serial interface 2 of the core (the latter
allows the core to be used remotely).

The original MultiComp design and much of its software are by **Grant Searle**
— see [Grant's MULTICOMP pick-and-mix computer](http://searle.x10host.com/Multicomp/).

## What's in the core

A single **T80 Z-80** CPU (the 6502 and 6809 from the original MultiComp have
been removed for RomWBW compatibility) on an Altera Cyclone V
(`5CSEBA6U23I7`, DE10-Nano / MiSTer), with 128 MB of SDRAM and 64 KB of
on-FPGA block RAM. Peripherals:

| Block | I/O ports | Notes |
|-------|-----------|-------|
| MMU (Z2-compatible, banked memory) | `$B0`–`$BF` | 4 × 16 KB frames over a 256 MB address space; the key addition for RomWBW. `Components/MMU/MMU.vhd` |
| ACIA UART (6850 model) | `$82`–`$83` | Console — MiSTer `/dev/ttyS0` or the USER-port hardware serial |
| VGA text terminal (80×25 ANSI) | `$80`–`$81` | Keyboard synthesized from USB via the MiSTer framework |
| SPI SD-card controller | `$88`–`$8F` | Physical SD socket |
| HPS image block device | `$90`–`$97` | Disk image mounted from the OSD; usable alongside the SD socket |
| Front-panel subsystem | `$A0`–`$A7` | The blinkenlights panel (see below) |
| Front-panel data latch | `$FF` | IMSAI-style 8-bit output latch feeding the capture chain |
| Benchmark timers | `$C0`–`$CF` | Free-running µs/ms counters with snapshot channels |
| DS12887 real-time clock | `$70`–`$71` | Time seeded from the MiSTer host |

The authoritative **memory map and full I/O port map** live in
[`HARDWARE.md`](HARDWARE.md). Development history and design rationale are in
[`HISTORY.md`](HISTORY.md).

### Custom Z-80 instructions

The T80 core implements a few extra instructions in previously-undefined `ED`
slots — `F_NEXT` and the `PUSHIX`/`POPIX` family — sized to speed up the
CamelFORTH `next` primitive and return-stack push/pop. Details in
`HARDWARE.md` ("Custom CPU instructions").

## Booting & boot "ROM" images

The FPGA core contains **no built-in boot ROM**. Everything the Z-80 runs comes
from a bootable `.BIN` image that the MiSTer HPS (the ARM side) streams into
memory; you pick it with the OSD **Boot Rom Image** item. Until one is loaded the
Z-80 is held in reset. The last image chosen is remembered and auto-loaded at
core start ("sticky" `FC` items) — press Backspace in the file picker to clear
one.

This makes any `.BIN` a bootable "ROM" alternative, including:

* a **RomWBW** ROM image (the target boot path),
* a **CP/M** boot image,
* the standalone **CamelFORTH** kernel (`forth/`),
* the classic Grant Searle **BASIC/monitor** (`basmon`), built from
  `intMon.hex` — see [Legacy BASIC](#legacy-basic) below.

The exact reset / auto-load / sticky behaviour (what survives OSD Reset vs. a
hard reset, block-RAM vs. SDRAM load targets) is fully specified in
[`HARDWARE.md`](HARDWARE.md), "Boot, reset and image loading".

## RomWBW & supported operating systems

RomWBW's HBIOS presents a uniform driver layer, so a single firmware image can
multi-boot a range of Z-80 operating systems. The port's target is to boot these
through the `.BIN` loader with the MMU providing banked RAM:

* **CP/M-80** family — CP/M 2.2 and CP/M 3.0, plus DOS variants such as **ZSDOS**
  and the **Z-System/ZPM3** environment,
* **CamelFORTH** (bundled with RomWBW; also runnable standalone — see below),
* other HBIOS-bootable systems RomWBW supports (e.g. N8DOS, and, on capable
  configurations, Fuzoss, Nut/OS and µClinux).

**Current status:** the MMU, block storage and boot path needed for RomWBW are in
place, and CP/M and the standalone CamelFORTH kernel boot today; full RomWBW
bring-up (including the MrZ80 HBIOS platform driver) is the active milestone.
See `REQUIREMENTS.md` ("Next milestone: RomWBW port") and `HISTORY.md`.

## Front Panel — Maximum Blinkenlights

A WS2812/SK6812 blinkenlights front panel: **256 RGB LEDs driven from a single
FPGA pin** (`USER_IO` `USER_OUT[6]`), mirroring live CPU state — the address and
data buses **and every T80 register**, including the shadow banks, `IX`/`IY`,
`PC` and `SP`. This is the IMSAI 8080 control-panel idea taken to its FPGA
conclusion: with the CPU in the fabric, there is no reason to show only a few
lamps, so it shows the entire machine.

Highlights of the current build:

* A **384-bit capture chain** feeds the panel; brief pulses (bus and interrupt
  strobes `/RD`, `/WR`, `/MREQ`, `/IORQ`) are **stretched** so they're visible to
  the eye.
* **8 programmable profiles**, each independently mapping LEDs to signal bits
  with per-LED ON/OFF colours — one profile can paint all the registers, another
  the buses. Switch them from software or **live from the OSD** (invisible to
  the running software).
* Profiles are authored in YAML and built with
  [`Components/FRONTPANEL/tools/fpprofile.py`](Components/FRONTPANEL/tools/fpprofile.py)
  into a `.FPP` file, mounted from the OSD.
* Global brightness control, ~62.5 Hz refresh (physical ceiling ~129 Hz).

The subsystem is decoded at `$A0`–`$A7` with the `$FF` latch port. The full user
guide, register map and profile-file format are in
[`Components/FRONTPANEL/README.md`](Components/FRONTPANEL/README.md); the
CPU-side signal source is in [`doc/t80_reg_debug_vector.md`](doc/t80_reg_debug_vector.md);
the wish-list it grew from is in `Components/FRONTPANEL/FEATURE.md`.

## CamelFORTH

There is a port of **CamelFORTH** for the Z-80 (`forth/`). It runs both as a
CP/M application and standalone on bare metal (direct console I/O, no OS), where
it doubles as a monitor for exploring the hardware. It can be booted directly
from the OSD, and an up-to-8 MB disk image loaded into the top of SDRAM serves
as a Forth **block device** (RAM disk) for loading, listing and editing code.
The custom `F_NEXT`/`PUSHIX`/`POPIX` instructions exist to speed up its `NEXT`
primitive.

* Port background, I/O modules and tooling: [`forth/README.md`](forth/README.md)
* Full word glossary: [`doc/FORTH-GLOSSARY.md`](doc/FORTH-GLOSSARY.md)
* Build: `cd forth && make` (uses the um80/ul80 toolchain — see
  [Building](#building--toolchain))

For a gentle introduction to the language, *Starting Forth* is the classic:
<https://www.forth.com/starting-forth/>.

### Forth programming examples

```forth
\ Basic stack operations
5 3 2    \ put three numbers on the stack
.S       \ print stack contents -- output: 5 3 2
DUP      \ duplicate top number
.S       \ stack now: 5 3 2 2
SWAP     \ swap top two numbers
DROP     \ remove top number
.        \ print top number
CR       \ newline

\ Definitions
: SQUARE ( n -- n^2 ) DUP * ;
: CUBE   ( n -- n^3 ) DUP SQUARE * ;
5 SQUARE .   \ 25
3 CUBE .     \ 27

\ A counter variable
VARIABLE COUNT
0 COUNT !
: INC-COUNT ( -- ) 1 COUNT +! ;
: SHOW-COUNT ( -- ) ." Counter: " COUNT @ . CR ;
SHOW-COUNT     \ Counter: 0
INC-COUNT SHOW-COUNT   \ Counter: 1
```

## Legacy BASIC

The classic **Grant Searle BASIC/monitor (`basmon`)** that used to live in the
built-in boot ROM is still available — it is now just another bootable `.BIN`
image you select with the OSD **Boot Rom Image** item (see
[Booting](#booting--boot-rom-images)). Its sources remain in `ROMS/Z80/` and
`Z80 CPM and bootloader (basmon)/`, and `intMon.hex` can be built into a `.BIN`.
BASIC is also reachable through the RomWBW environment.

The 6502 and 6809 BASIC variants belonged to the original MultiComp multi-CPU
design; those CPUs have been removed from the core.

The full keyword reference and BASIC program examples (including the
6502/6809 comparisons, kept for historical reference) are archived in
[`doc/BASIC.md`](doc/BASIC.md).

## Using the MiSTer serial terminal/console

### Connection methods

1. **USB:** connect the MiSTer's console port to your computer with a USB cable.
2. **Network:** SSH into the MiSTer over Ethernet or Wi-Fi.
3. **USB/serial cable** to the USER port — see the pinouts below (and the
   Serial Port section of the Altair8800_MiSTer repository:
   <https://github.com/MiSTer-devel/Altair8800_MiSTer>).

### Setting up the connection

#### UART/serial with PuTTY

Connect at 115200 baud, 8 bits, no parity to the COM port.

#### SSH with PuTTY

Connect to the IP address of your MiSTer FPGA.

#### USER port — extra USB 3.1-A style connector on MiSTer

| USB | P7 | Name |   | MiSTer | emu wire |
|---|---|---|---|---|---|
| 1 | +5V | +5V | | | |
| 2 | 2 | TX | SDA | AH9 | `USER_IO[1]` |
| 3 | 1 | RX | SCL | AG11 | `USER_IO[0]` |
| 4 | GND | GND | | | |
| 5 | 8 | DSR | IO10 | AF15 | `USER_IO[5]` |
| 6 | 7 | DTR | IO11 | AG16 | `USER_IO[4]` |
| 7 | 6 | CTS | IO12 | AH11 | `USER_IO[3]` |
| 8 | 5 | RTS | IO13 | AH12 | `USER_IO[2]` |
| 9 | 10 | IO6 | IO8 | AF17 | `USER_IO[6]` |
| 10 | Shield | Shield | | | |

> The USER-port signals are **3.3 V TTL** — the FPGA is not 5 V tolerant.

#### FT232 USB-to-serial cable

| Wire | Name | MiSTer USB IO |
|---|---|---|
| Red | 5V | N/C |
| Black | GND | GND |
| White | RXD | 2 |
| Green | TXD | 3 |
| Yellow | RTS | 7 |
| Blue | CTS | 8 |

#### Linux command line

1. Identify the UART device (usually `/dev/ttyS1` or `/dev/ttyUSB0`):

   ``` bash
   dmesg | grep tty
   ```

2. Access the serial terminal with `screen` or `minicom`:

   ``` bash
   screen /dev/ttyS1 115200
   ```

   Replace `/dev/ttyS1` with the correct device and adjust the baud rate.

3. Enable hardware flow control before `screen`:

   ``` bash
   stty -F /dev/ttyS1 crtscts
   ```

### Additional information

For more on console connections, see the official
[MiSTer Console Connection Guide](https://MiSTer-devel.github.io/MkDocs_MiSTer/advanced/console/).

## OSD configuration

The On-Screen Display controls boot, storage and serial parameters. (There is no
CPU selection any more — the core is Z-80 only.)

### System control

* **Boot Rom Image** (`.BIN`/`.ROM`, `FC1`) — loaded into SDRAM at address 0 and
  started from there. There is no built-in boot ROM; the Z-80 is held in reset
  until a boot image is loaded. The last file chosen is remembered and
  auto-loaded at core start. **OSD Reset** restarts the loaded image; a hard
  reset discards it. To clear a saved (sticky) selection, open the file picker
  and press Backspace.
* **SD card image** (`*.IMG`, `FC2`) — mounts an image file as the HPS block
  device at ports `$90`–`$97` (see `HARDWARE.md`, "Storage"). Independent of the
  physical SD socket (SPI controller, `$88`–`$8F`); both can be used at once.
* **Reset after Mount** — reset the system after mounting storage (No/Yes).
* **Reset** — system reset (CPU restart; the loaded image is kept).

### Front panel

* **Front Panel Profiles** (`.FPP`, `FC5`) — loads the 8-profile blinkenlights
  map/colour file.
* **Front Panel Profile** (`Software`, `0`..`7`) — overrides which profile the
  LEDs display, live, without affecting software's view.

### Communication settings

* **Baud Rate** — 115200 / 38400 / 19200 / 9600 / 4800 / 2400.
* **Serial Port** — Console Port (MiSTer console) or User IO Port (USER
  connector).
* **Flow Control** — None, or RTS/CTS hardware flow control.

## Building / toolchain

Target device: Cyclone V `5CSEBA6U23I7` (DE10-Nano / MiSTer).

The FPGA build runs Quartus 17.0 in Docker on a remote host via wrapper scripts
in `tools/`:

```sh
tools/build.sh          # full build (analysis, synthesis, place & route)
tools/build.sh synth    # synthesis only
tools/build.sh help     # more options
```

Output: `output_files/MrZ80.rbf`.

Z-80 software (`forth/`, any `.azm`/`.mac` work) is assembled with the
**um80/ul80** MACRO-80/LINK-80 toolchain (not `pasmo`):

```sh
tools/z80asm.sh forth/camel80.azm          # assemble + link + flatten to .bin
tools/um80.sh <args...>                     # the assembler
tools/ul80.sh <args...>                     # the linker
cd forth && make                            # the repeatable build (source of truth)
```

See `AGENTS.md` for the full toolchain notes and the `MRZ80_SD_*` build macros
in `HARDWARE.md` for SD-card board options.

## Documentation map

| Where | Contents |
|-------|----------|
| `README.md` (this file) | Project overview, features, booting, OSD, build |
| [`HARDWARE.md`](HARDWARE.md) | Memory map, full I/O port map, boot/reset behaviour, SD-card board options, custom instructions |
| [`HISTORY.md`](HISTORY.md) | Development history and design rationale |
| [`REQUIREMENTS.md`](REQUIREMENTS.md) | Requirements and the RomWBW roadmap |
| [`Components/FRONTPANEL/README.md`](Components/FRONTPANEL/README.md) | Front-panel subsystem user guide / datasheet |
| [`doc/FORTH-GLOSSARY.md`](doc/FORTH-GLOSSARY.md) | CamelFORTH word glossary |
| [`forth/README.md`](forth/README.md) | CamelFORTH Z-80 port notes and tooling |
| [`doc/BASIC.md`](doc/BASIC.md) | Legacy BASIC keyword reference and examples |
| [`AGENTS.md`](AGENTS.md) | Contributor guide (structure, build, toolchain) |

## Troubleshooting

### Serial communication

* If there's no response when typing: verify the baud rate, that the right
  serial port (Console vs User IO) is selected, and try toggling flow control.
  For the USER port, recheck the pinout above (3.3 V signals).

### Storage

* If CP/M can't access storage: for the physical SD socket (`$88`–`$8F`) ensure a
  card is formatted and seen; for the image block device (`$90`–`$97`) ensure an
  image is mounted in the OSD. Try toggling **Reset after Mount**. The mounted
  image can be swapped at any time; a transfer in progress aborts. Board-specific
  SD-card build macros and a verified configuration are described in
  `HARDWARE.md`.

### System stability

* Unresponsive? Use **OSD Reset** (keeps the loaded image), or power-cycle the
  MiSTer. If it boots into a bad sticky image, clear it with Backspace in the
  Boot Rom Image picker.

### Known limitations

* The `DOWNLOAD.COM` program can drop characters over CP/M at high baud; 2400
  and 9600 have proven reliable, 115200 can drop characters even with flow
  control.
* RomWBW bring-up is in progress (see the RomWBW section above).

## License

By downloading the software and VHDL project you agree to the following: the
original copyright owners of the ROM contents are respectfully acknowledged. Use
of the contents of any file within your own projects is permitted freely, but
any publishing of material containing whole or part of any file distributed here,
or derived from the work done here, will contain an acknowledgment back to
Grant Searle and a link back to his page. Any file published or distributed that
contains all or part of any file from here must be made available free of charge.

### Original author

Grant Searle

### URL

[Grant's MULTICOMP pick-and-mix computer](http://searle.x10host.com/Multicomp/)

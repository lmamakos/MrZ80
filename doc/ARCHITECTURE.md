# MrZ80 architecture, in diagrams

Block diagrams of the FPGA core, generated from Graphviz sources that live next
to this file. They cover **everything except the MiSTer framework under `sys/`**,
which is a set of externally maintained files that are never modified — in these
pictures it is a single grey box on the left, with the interfaces the core uses
labelled on the arrows.

The top-level entity of the build is `sys_top` (`sys/sys_top.v`); it instantiates
`emu` (`MrZ80.sv`), and `emu` holds the glue, the Z-80 computer, the SSP and the
sound. So "the core" in these diagrams means `MrZ80.sv` +
`MicrocomputerZ80CPM.vhd` + `Components/` + `ssp/`.

## The sheets

Start at the top; each sheet links down to the next level of detail.

| Sheet | What it shows |
|-------|---------------|
| [**overview**](architecture/overview.svg) | The whole core in nine boxes: framework, glue, Z-80 computer, memory, peripherals, sound, SSP, and what crosses between them. |
| [**z80**](architecture/z80.svg) | The CPU complex: `T80s`, `z80_bus_mux` (two masters, one bus), `ssp_tramp` (reset vent + reset-vector injection), the MMU, block RAM, the SDRAM client FSM and how `WAIT_n` is built. |
| [**peripherals**](architecture/peripherals.svg) | The I/O devices — terminal, serial ACIA, SD card, HPS block device, RTC, timers, front panel — and what each reaches off-core. |
| [**iomap**](architecture/iomap.svg) | The Z-80 port map, plus the register windows inside the MMU, the front panel and the PSG. |
| [**psg**](architecture/psg.svg) | Dual YM2149 sound: the `MrZ80_PSG` wrapper (SELECT latches, bus steering, mute + pan sequencer) around the vendored `YM2149_PSG_system`. |
| [**ssp**](architecture/ssp.svg) | The System Support Processor: FemtoRV32, its ROM/RAM/bridge map, and the seam to the Z-80 (parking, bus engine, physical-memory client). |
| [**clocks**](architecture/clocks.svg) | Clock domains, the reset tree, and every clock-domain crossing. |

Sources are the `.dot` files in this directory; regenerate with

```sh
make -C doc/architecture          # SVGs and PNGs; needs graphviz (dot)
```

The SVGs are committed so the documentation reads without a toolchain; PNGs are
build output and are gitignored.

## The boundary

`sys/` (never modified — see `AGENTS.md`) provides:

- `sys_top`: top level, HDMI/VGA pipeline, OSD overlay, audio fan-out, LEDs, UART and GPIO pins.
- `hps_io`: the bridge to the Arria SoC's Linux side — OSD `status[127:0]`, the `ioctl_*`
  file stream, the `sd_*` block-device interface, USB keyboard as PS/2, and the real-time
  clock. It is instantiated by `emu`, on `clk_sys`.
- `video_cleaner`, `audio_out`: the last stage before the pins.

Everything else on the board is this project's design.

## Port map

Decoded in `MicrocomputerZ80CPM.vhd` ("CHIP SELECTS GO HERE"). A device is
selected only when its window matches **and** `IORQ` is active with `RD` or `WR`;
an unclaimed port reads `$FF`.

| Ports | Device | Notes |
|-------|--------|-------|
| `$50`, `$51` | PSG device 1 SELECT / DATA | RomWBW `AYMODE_COLECO`; both ports read back the selected register |
| `$68`, `$60` | PSG device 2 SELECT / DATA | the address vibetune calls its "EB" dual-card option |
| `$70`, `$71` | DS12887 RTC index / data | time-of-day supplied by the HPS |
| `$80`, `$81` | video terminal data / status-control | 6850 ACIA semantics, PS/2 keyboard |
| `$82`, `$83` | serial ACIA data / status-control | DDS baud rate, optional RTS/CTS |
| `$88`–`$8F` | SD card, raw SPI | SDHC-style block registers |
| `$90`–`$97` | HPS block device | identical registers, backed by an OSD-mounted image |
| `$A0`–`$A7` | front-panel subsystem | 8 profiles × 256 WS2812/SK6812 LEDs |
| `$B0`–`$BF` | MMU | see below |
| `$C0`–`$CF` | BenchTimer | four 32-bit snapshots, 1 ms ×2 and 1 us ×2 |
| `$D0`–`$D3` | IntervalTimer | programmable tick; the RomWBW system tick |
| `$FF` | front-panel data latch | 8 bits of CPU state, also captured for the panel |

`HARDWARE.md` is authoritative and adds the bit-level detail for every one of
these, including the PSG mixer registers and the front-panel profile file format.

## Memory

The MMU is a 4 × 16 KB pager with a 14-bit hardware page number, so the physical
space is 28 bits — 16384 pages of 16 KB:

| Physical | Size | What |
|----------|------|------|
| `0x0000_0000` | 128 MB | SDRAM (pages 0–8191) |
| `0x0800_0000` | 64 KB | on-chip block RAM (page 8192) |

- Logical frame 0 comes out of block RAM by default, or out of SDRAM page 0 once
  a `.BIN` boot image has been loaded — that is the whole boot mechanism, since
  there is no built-in boot ROM.
- Writing a frame's low byte (`$B0`–`$B3`) clears that page's high byte, for
  exact RomWBW "Z2" compatibility; write `$B0`–`$B3` first, then `$B4`–`$B7`.
- `$B8`–`$BB` is a 32-bit direct-access pointer and `$BC` is its data port: an
  I/O cycle that the MMU rewrites into a physical memory access, post-incrementing
  so `INIR`/`OUTIR` walk through physical memory. The CPU is forced to wait for it.

Files streamed in from the OSD land at fixed physical addresses:

| OSD item | Target |
|----------|--------|
| `.BIN` boot ROM (index 1) | SDRAM `0x0000_0000`, or the first 64 KB of block RAM if *Boot Load Target* is set |
| `.DSK` RAM disk (index 2–4) | slot *n* at `128 MB − (n+1) × 8 MB`, so the first is `0x0780_0000` |
| `.FPP` front-panel profiles (index 5) | front-panel RAM, never memory |
| `.MRZ` SSP monitor ROM (index 6) | the SSP's own 128 KiB MROM; the Z-80 is not reset |

The SSP has its own map: MROM 128 KiB at `0x0000_0000` (only the dictionary
window from `DICT_BASE` = `0x5000` is writable, matching Mecrisp
`compiletoflash` on silicon), RV RAM 64 KiB at `0x1000_0000`, bridge registers
4 KiB at `0x2000_0000`.

## Clocks and resets

| Domain | Frequency | Contents |
|--------|-----------|----------|
| `clk_sys` | 50 MHz | the entire core, including `hps_io` and the download path |
| `clk_ram` | ~112 MHz | the SDRAM controller only (a 100 MHz tap is available via `SDRAM_CLK_100`) |
| Z-80 | 10 MHz | `cpu_cen` is high one `clk_sys` cycle in five |
| serial | from a DDS | `serialClkCount` accumulates `baud_increment`, bit 15 is the clock |

Crossings: the SDRAM request level is 2-FF synchronised into `clk_ram` and edge
detected; completion toggles back into `clk_sys`; controller `init` is registered
in `clk_sys` first, then synchronised, so every controller register changes on the
same edge. `hps_io` runs on `clk_sys` deliberately, so `status`, `ioctl` and the
block-device buffer are already synchronous where they are consumed.

Reset sources, and what each one actually resets:

| Source | Resets |
|--------|--------|
| framework `RESET` (hard) | everything, including SDRAM controller re-init |
| OSD *Reset* (`status[0]`), user button | the CPU only — the loaded image restarts |
| *Reset after Mount* (`status[15]`) | the CPU, when an image is mounted |
| a file download, plus a short stretch afterwards | the CPU (except an `.MRZ` mount, which leaves the Z-80 alone) |
| `~bin_loaded` | holds the CPU in reset until a `.BIN` has been loaded |
| *Reset SSP* (`status[23]`), the SSP's reset vent | the RISC-V core / the T80 alone, never the peripherals |

Interrupts: `INT_n` is the wired-AND of three open-collector sources — the video
terminal ACIA, the serial ACIA and the IntervalTimer — and the SSP can hold it
inactive during a single-step sequence. `NMI` is unused (held high).

## OSD control bits

The core's `CONF_STR` and the bit assignments it produces (both in `MrZ80.sv`):

| Bit(s) | OSD item | Effect |
|--------|----------|--------|
| 0 | *Reset* | CPU reset only, keeps the loaded image |
| 12 | *Serial Port* | console port vs USER_IO (SNAC) port |
| 13 | *Boot Load Target* | `.BIN` into SDRAM (default) or block RAM (debug) |
| 14 | *Flow Control* | RTS/CTS on the serial port |
| 15 | *Reset after Mount* | reset the CPU when an image is mounted |
| 16–19 | *Front Panel Profile* | 0 = software selects, 1–8 = force profile 0–7 |
| 20 | *SSP Monitor* | SSP enable; off is indistinguishable from absent |
| 21 | *Enter SSP Monitor* | trigger: park the Z-80 and enter the monitor |
| 22 | *SSP Serial Escape* | an escape byte on the serial port enters the monitor |
| 23 | *Reset SSP* | trigger: ~1.3 ms reset of the RISC-V core |
| 24 | *SSP Console* | monitor console on the serial port or its own video terminal |
| 25–26 | *PSG Stereo* | Mono / ABC / ACB panning |

## Where things live

| Block | File(s) |
|-------|---------|
| core glue: PLL, resets, download router, serial routing, SDRAM CDC and controller, OSD config string | `MrZ80.sv` |
| Z-80 computer, decode, MMU hookup, SDRAM client FSM | `MicrocomputerZ80CPM.vhd` |
| Z-80 CPU | `Components/Z80/` (T80) |
| MMU | `Components/MMU/MMU.vhd` |
| 64 KB block RAM | `Components/INTERNALRAM/InternalRam64K.vhd` |
| SDRAM controller | `Components/SDRAM/sdram2.sv` (from the CoCo3 core) |
| text terminal + font ROM | `Components/TERMINAL/` |
| serial ACIA | `Components/UART/bufferedUART.vhd` |
| SD card SPI, HPS block device | `Components/SDCARD/` |
| RTC | `Components/RTC/ds12887.vhd` |
| timers | `Components/TIMER/` |
| front panel + capture chains | `Components/FRONTPANEL/` |
| sound wrapper, pan sequencer, Quartus-17 LUT drop-in | `Components/PSG/` |
| vendored YM2149 / jt49 cores | `Components/YM2149/` (unmodified; configured by `USE_STEREO` and `USE_DUAL_PSG` in `MrZ80.qsf`) |
| RISC-V core | `Components/RISCV/femtorv32_gracilis.v` |
| SSP: top, bridge, UART, video terminal, memories, bus mux, trampoline, memory client | `ssp/rtl/` |
| bridge register map (single source of truth) | `ssp/regs/ssp_regs.csv` → `ssp/rtl/ssp_regs.vh` |

## Related documents

- [`HARDWARE.md`](../HARDWARE.md) — authoritative memory map, bit-level port detail, boot and reset behaviour, custom Z-80 instructions.
- [`doc/OVERVIEW.md`](OVERVIEW.md) — the narrative tour of the machine, its Forth and the SSP.
- [`doc/SSP_DESIGN.md`](SSP_DESIGN.md), [`doc/SSP_STATUS.md`](SSP_STATUS.md), [`doc/SSP_REGS.md`](SSP_REGS.md) — SSP decisions, status and register map.
- [`Components/FRONTPANEL/README.md`](../Components/FRONTPANEL/README.md) — front-panel datasheet and profile format.
- [`REQUIREMENTS.md`](../REQUIREMENTS.md), [`HISTORY.md`](../HISTORY.md) — what was asked for, and why it ended up this way.

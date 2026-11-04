## Memory Map

Pages are 16K each (14 bits).   Total address space is 256MB,
with 128MB (SDRAM) followed by 64K of Block Ram at the start
of the upper 128M address space - total of 27 bits.

1MB    =  0x10 0000
8MB    =  0x80 0000
128MB  = 0x800 0000
120MB  = 0x780 0000

Address format:    (Virtual)
          |           |           |           |           |           |
  26 25 24.23 22 21 20.19 18 17 16.15 14 13 12.11 10 09 08.07 06 05 04.03 02 01 00
  \--high pg#--/ \-- low order page #--/ \--- In-page low order address bits ----/
          |           |           |           |           |           |
                   (Logical)       15 14 13 12.11 10 09 08.07 06 05 04.03 02 01 00
                                   \pg#/ \--------- offset in 16K page ---------/

When bit 26 is zero, the lower 128MB is the SDRAM.
When bit 26 is one, the first 64KB is the on-FPGA Block RAM memory.

| Memory Address  | 16K Page #  |  High MMU   |   Low MMU   | Pnysical   |
|-----------------|-------------|-------------|-------------|------------|
| SDRAM Start     |     0       |     0 /  0  |    0 / 0    | 0x000 0000 |
| SDRAM Disk Img  |    7680     |  0x1E / 30  | 0x00 / 0    | 0x780 0000 |
| SDRAM Disk End  |    8191     |  0x1F / 31  | 0xFF / 255  | 0x7FF FFFF |
| SDRAM End       |    8191     |  0x1F / 31  | 0xFF / 255  | 0x7FF FFFF |
| Block RAM Start |    8192     |  0x20 / 32  | 0x00 / 0    | 0x800 0000 |
| Black RAM End   |    8195     |  0x20 / 32  | 0x03 / 3    | 0x801 0000 |


Initial default mapping has:

| 16K Page Frame  |  Page Number | Upper | Lower |
|-----------------|--------------|-------|-------|
| 0 (0000-3FFF)   |    8192      | 0x20  | 0x00  |
| 1 (4000-7FFF)   |      1       | 0x00  | 0x01  |
| 2 (8000-BFFF)   |      2       | 0x00  | 0x02  |
| 3 (C000-FFFF)   |      3       | 0x00  | 0x03  |


So the SDRAM Disk Image is at page 7680 (0x1E00), i.e. page# 7680 x 16K
(0x4000) = physical byte address 0x07800000:

      7   |     8     |    0      |    0      |    0      |    0      |    0     |
  0  1  1  1  1  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
  26 25 24.23 22 21 20.19 18 17 16.15 14 13 12.11 10 09 08.07 06 05 04.03 02 01 00
  \--high pg#--/ \-- low order page #--/ \--- In-page low order address bits ----/
       1E                  0

Start phys addr 0x7800000   0x07 80 00 00

This matches the download path in `MultiComp.sv`:
`dl_dsk_base = SDRAM_TOP - (slot+1)*8MB` with `SDRAM_TOP = 0x8000000` and
`DSK_IMAGE_SIZE = 0x0800000`, so the first RAM disk (slot 0) lands in the
top 8 MB at `0x7800000`.

OSD file indices (`ioctl_index[5:0]`): 1 = `.BIN` boot image (SDRAM at 0, or
block RAM), 2 = `.DSK` RAM disk, 3 and 4 = reserved for larger RAM-disk
images (SDRAM, same slot/base scheme as index 2), 5 = front-panel profile
file (`FC5`; goes to `FrontPanel_Subsystem`, never to SDRAM), 6 = SSP monitor
ROM (`FC6`, `.MRZ`; goes to the SSP's 128 KB ROM, never to SDRAM, and does not
reset the Z-80), 7 = reserved for the SSP.

## Boot, reset and image loading

### No ROM in the FPGA load

The FPGA core contains **no boot ROM**. Everything the Z-80 runs at power-on
comes from a boot image (`.BIN`) that the HPS (the ARM side of the MiSTer)
streams into memory through the `ioctl` download path. Selecting which bootable
software runs is therefore done entirely in the OSD with the
**Boot Rom Image** item (`FC1`, file index 1); nothing about any particular
image is compiled into the core.

Until a boot image has been loaded, the internal flag `bin_loaded` (in
`MrZ80.sv`) is clear and the Z-80 is **held in reset**. The core will then
look dead: no video activity from the CPU, no serial output. This is expected;
select a Boot Rom Image in the OSD.

Once a `.BIN` download finishes, `bin_loaded` is set, the CPU is released
after a short reset stretch (65536 `clk_sys` cycles), and the MMU reset map
points logical frame 0 at SDRAM page 0 so the image starts at `0x0000`
(see the memory map above). With the debug option
**Boot Load Target = Block RAM** the image goes to the on-chip block RAM
instead and frame 0 maps to the block RAM page; `bin_loaded` is still set so
the CPU runs.

### When the HPS loads a file

The HPS writes to the core in exactly these situations:

1. **You pick a file in the OSD** (any of Boot Rom Image, 8MB Disk Image,
   Front Panel Profiles, SSP Monitor ROM). The file is streamed in immediately. The HPS also
   remembers the file name for that menu item (see "Sticky" below).
2. **The core is started** (power-up, or the core is (re)loaded by the
   MiSTer menu / FPGA reconfiguration). For each `FC` item that has a
   remembered file name, the HPS loads that file automatically, before the
   Z-80 runs. The HPS holds `status[0]` (OSD Reset) high while it does this
   and restores the saved OSD settings only afterwards.

The HPS does **not** reload files on any reset that happens while the core
stays running (OSD Reset, the user button, mount reset, the framework `RESET`
described below). Those only reset the CPU/state in the core; whether the
image is still there afterwards is decided by the table below.

Consequences of the "files are loaded before the settings are restored" ordering:

- An auto-loaded Boot Rom Image **always goes to SDRAM**, even if
  *Boot Load Target = Block RAM* is saved. Block RAM loading only works for a
  file you pick manually in the OSD.
- A `.DSK` image is written into the top of SDRAM (slot base as in the memory
  map) and a `.FPP` profile into the front-panel subsystem; neither one starts
  the CPU. Only a `.BIN` sets `bin_loaded`.
- Any completed download (`.BIN`, `.DSK` or `.FPP`) resets the CPU for a short
  stretch afterwards so it restarts cleanly into the new memory contents.
  While a download is in progress the CPU is held in reset.
- The exception is an **SSP Monitor ROM** (`.MRZ`): the Z-80 keeps running and
  keeps the SDRAM. Only the SSP is held in reset while the file streams in; its
  ROM is first cleared, and the monitor restarts on the new image when the
  download ends. The SSP no longer waits for a Boot Rom Image: it runs from its
  own ROM even while the Z-80 is held in reset.

### "Sticky" `FC` selections and how to clear one

The `C` in `FC1`, `FC2`, `FC5`, `FC6` means the HPS stores the chosen file name per
menu item in the core's configuration area on the SD card and re-selects it at
every core start. That is what makes a Boot Rom Image "sticky": after you have
chosen it once, the core boots into it at power-up with no further action.

The stored name is not removed by any reset. **To delete a saved file specification,
open the item's file picker in the OSD and press the Backspace key.** (This is
a MiSTer OSD feature and is not advertised on screen.) After clearing:

- Nothing is unloaded from the running core: a currently running image keeps
  running, and its bytes stay in SDRAM.
- At the next core start, or after the next hard reset, no file is loaded for
  that item. With no Boot Rom Image saved the CPU stays held in reset until you
  select one.

Use Backspace to get out of a bad sticky boot image (for example one that
hangs the system) if you cannot otherwise get a working one selected, or to
return to the "nothing loaded" state.

### The different (re)start cases

| Case | How it happens | Z-80 | `bin_loaded` / loaded boot image | Files from HPS |
|------|----------------|------|----------------------------------|----------------|
| **Power-up / core (re)load** | FPGA configured, core loaded from the MiSTer menu | Held in reset until a `.BIN` has loaded | Starts clear | Every `FC` item with a saved file name is auto-loaded. A saved Boot Rom Image therefore boots by itself; with none saved, the CPU stays in reset |
| **Hard reset** | Framework `RESET` from the HPS; rising edge (the user button, `buttons[1]`, only resets the CPU, like OSD Reset: image and SDRAM kept) | Reset | **Cleared**: the image is discarded and the CPU is held in reset | **Not reloaded.** You must pick the Boot Rom Image in the OSD again. The front-panel profile (`.FPP`) is also cleared |
| **OSD Reset** | OSD item *Reset* (`R0`, `status[0]`) | Reset while asserted | **Kept**: the loaded image is restarted from `0x0000`. SDRAM is not re-initialised, so the image is intact | None |
| **Reset after Mount** | OSD option *Reset after Mount = Yes*, then mounting an `*.IMG` | Reset for 65536 `clk_sys` cycles | Kept (image restarted) | None. CPU-only reset like OSD Reset: the SDRAM controller is not re-initialised and the image is untouched |
| **Manual file load** | You pick a file in the OSD | Reset during the download and for a short stretch after | `.BIN` sets it, `.DSK`/`.FPP` leave it unchanged | The picked file only |
| **Post-download restart** | Automatic, end of any download | Reset for 65536 `clk_sys` cycles | Unchanged (a `.BIN` sets it) | None |

Rules of thumb:

- **OSD Reset restarts the software; hard reset removes it.** Use OSD Reset
  to restart a loaded image, and re-select the Boot Rom Image after a hard reset
  (or after a core reload with no saved Boot Rom Image).
- The SDRAM controller is initialised at power-up and on a hard reset
  (core reload), but never by OSD Reset, the user button, Reset after Mount or while a download is in
  progress (that would stall the HPS in the middle of a transfer).
- Because there is no ROM, any Z-80 write to port `0x38` (the old ROM-disable
  trigger) is ignored.

## Build configuration: conditional compilation

Every macro the sources test — this project's, plus the framework macros in `sys/`
that bear on this core's configuration — and its state in this build.  Synthesis
macros are set in `MrZ80.qsf` as `VERILOG_MACRO` unless the table says otherwise.
VHDL has no preprocessor: everything tunable in the VHDL components is a
*generic*, listed with the block it belongs to (`HS_DIVIDER`, `CLKEDGE_DIVIDER`,
the MMU geometry, `NUM_LEDS`, and so on).

### Active

| Macro | Set in | What it selects |
|-------|--------|-----------------|
| `USE_STEREO` | `MrZ80.qsf` | the right-hand `BHG_audio_filter_mixer` in the vendored `YM2149_PSG_system` — stereo output (see the PSG section) |
| `USE_DUAL_PSG` | `MrZ80.qsf` | the second `BHG_jt49` — channels D, E, F, i.e. two PSGs |
| `MRZ80_SD_IGNORE_CD` | `MrZ80.qsf` | card-detect stops gating the secondary SD pins in `sys/sys_top.v` |
| `MRZ80_SD_FORCE` | `MrZ80.qsf` | SD signals always routed to the SDIO pins, at the cost of analog video on those pins |
| ``` `define SDRAM_CLK_100 ``` | `MrZ80.sv` (source-level, not the `.qsf`) | the SDRAM controller runs on the PLL's 100 MHz tap instead of 112 MHz |

The net clocking, as built: `clk_sys` = 50 MHz for the whole computer (CPU, MMU,
peripherals, sound, SSP and `hps_io`), `clk_ram` = 100 MHz for the SDRAM
controller alone, and the Z-80 enabled one `clk_sys` cycle in five for a 10 MHz
core.

`sim/run_psg.sh` defines the same two sound macros as the `.qsf`, which is what
keeps the simulation lane testing the configuration the hardware is built with.

### Present but off

| Macro | Where | Effect if switched on |
|-------|-------|-----------------------|
| `MISTER_DUAL_SDRAM` | `sys/sys_dual_sdram.tcl`, which `MrZ80.qsf` never sources (it sources `sys/sys.tcl` and `sys/sys_analog.tcl`) | second SDRAM device wiring in `sys/sys_top.v`; also changes how the SD pins are routed |
| `MISTER_FB`, `MISTER_FB_PALETTE`, `MISTER_DOWNSCALE_NN`, `MISTER_SMALL_VBUF`, `MISTER_DISABLE_ADAPTIVE`, `MISTER_DISABLE_ALSA`, `MISTER_DISABLE_YC`, `MISTER_DEBUG_NOHDMI` | the MiSTer build system, not this repository | the framework's framebuffer, scaling, ALSA/YC and no-HDMI variants.  `MrZ80.sv` and `sys/` test these names; nothing here defines them, so the ports they guard are simply absent |
| `OSD_HEADER` | `sys/osd.v`, set by the MiSTer build system | the framework OSD reserves 24 header rows instead of 0 |
| `USE_I2S` | tested by the vendored `YM2149_PSG_system.sv`; not set here | the core would drive an I2S DAC interface itself; MiSTer's `audio_out` does that conversion, so it stays off |
| `ARCADE_SYS`, `USE_FB`, `USE_SDRAM`, `USE_DDRAM`, `DEBUG_NOHDMI` | commented out in `MrZ80.qsf` | **nothing at all in this tree** — these are stock MiSTer `.qsf` boilerplate, and no source here (this core or `sys/`) tests those names.  The framework's equivalents are the `MISTER_*` names above.  Keep them commented; deleting them is also harmless |

### Off in synthesis, and only meaningful in simulation

| Macro | Where |
|-------|-------|
| `SIMULATION` | `Components/YM2149/jt49_hdl/filter/jt49_dly.v` — zero-initialises the delay RAM so simulators start from a known state |
| `BENCH` | `Components/RISCV/femtorv32_gracilis.v` (compiled) and `utils.v` (not compiled) — benchmark/trace hooks in the vendored core |
| `verilator`, `QUIET`, `VERBOSE` | `Components/RISCV/utils.v`, which is not in the synthesis file list |
| `DEBUG`, `DEBUGNETS`, `DEBUGREGS`, `DEBUGASM`, `FORMAL`, `RISCV_FORMAL*` | `Components/RISCV/picorv32.v`, which is **not compiled** into this build (the SSP runs `femtorv32_gracilis.v`); the file is kept for the CPU bakeoffs |
| `use_legacy_jt49` | `Components/YM2149/YM2149_PSG_system_tb.sv`, the vendored testbench, which is not in the synthesis file list |
| `SSP_REGS_VH` | include guard of the generated `ssp/rtl/ssp_regs.vh` |

Nothing else in the compiled sources is conditional.

## I/O port map (reference)

A consolidated list of all I/O ports identified for use by this
project so far. The "Core" column shows which Z-80 wrapper(s)
currently decode the port (`CPM` = `MicrocomputerZ80CPM`,
`Basic` = `MicrocomputerZ80Basic`). Ports marked "planned" are
reserved by these requirements but not yet wired up in any wrapper.
Entries should be kept in sync with the `n_*CS` decodes in the
"CHIP SELECTS" section of each `Microcomputer*.vhd` wrapper.

| Port(s)       | Width | Function                                                                                                  |
|---------------|-------|-----------------------------------------------------------------------------------------------------------|
| `0x38`        | 1     | Unmapped. Formerly the ROM-disable trigger; the boot ROM has been removed, so writes are ignored.        |
| `0x50`-`0x51` | 2     | PSG device 1, YM2149/AY-3-8910 (`n_psg1SelCS`/`n_psg1DatCS`, `Components/PSG/MrZ80_PSG.sv`). `0x50` = register SELECT, `0x51` = DATA; both read the selected register. RomWBW `AYMODE_COLECO`. Also reaches the stereo mixers. See PSG sound below. |
| `0x60`, `0x68` | 2    | PSG device 2 (`n_psg2DatCS`/`n_psg2SelCS`). `0x68` = register SELECT, `0x60` = DATA; both read the selected register (vibetune's "EB" second card). See PSG sound below. |
| `0x70`-`0x71` | 2     | DS12887 real-time clock (`n_rtcCS`, `Components/RTC/ds12887.vhd`). AT-style index/data pair: `0x70` = register index, `0x71` = selected register. See below. |
| `0x80`-`0x81` | 2     | SBCTextDisplayRGB (`n_interface1CS`). VGA/PS-2 text display, 6850 ACIA programming model. RomWBW video console (ACIA unit 1). See Serial-like devices below. |
| `0x82`-`0x83` | 2     | bufferedUART (`n_interface2CS`). Serial console, 6850 ACIA programming model. RomWBW boot console (ACIA unit 0). See Serial-like devices below. |
| `0x88`-`0x8F` | 8     | SPI SD card controller (`n_sdCardCS`, `sd_controller.vhd`). Talks only to the physical SD socket. Register offset via `cpuAddress(2 downto 0)`. See SD storage below. |
| `0x90`-`0x97` | 8     | HPS image block device (`n_blockDevCS`, `Components/SDCARD/hps_blockdev.vhd`). Same register layout as the SD controller plus image-size registers; storage is an image file on the MiSTer Linux side, mounted from the OSD. See SD storage below. |
| `0xA0`-`0xA7` | 8     | Front-panel subsystem control window (`n_fpSubsysCS`). See Front-panel I/O register map below.            |
| `0xB0`-`0xBF` | 16    | MMU register window (`n_mmuCS`). 4 frame-mapping low bytes at `+0..+3` (Z2-compatible), 4 high bytes at `+4..+7`, direct-access pointer at `+8..+11` (little-endian), direct-access data port at `+12`. |
| `0xC0`-`0xCF` | 16    | Benchmark timers (`n_timerCS`, `BenchTimer`). Four 32-bit snapshot channels: ch0/ch1 1 ms/tick, ch2/ch3 1 µs/tick. See below. |
| `0xD0`-`0xD3` | 4     | Interval timer and interrupt source (`n_itimerCS`, `Components/TIMER/IntervalTimer.vhd`). One of three sources driving the Z80 `INT` pin (interrupt mode 1; with the terminal and serial ACIAs). See below. |
| `0xFF`        | 1     | Front-panel data latch (R/W). Software writes drive the 8-bit transparent capture chain; reads return the last-written value. |

### Storage: SPI SD card (`0x88`) and HPS image block device (`0x90`)

The core has two independent block storage devices that can be used at the
same time. Both transfer 512-byte blocks addressed by a 24-bit block number
(SDHC-style: the block number, not a byte address) and have the same
register layout, so one driver can serve both with only a different base
port.

| Device | Base | Backing store | Module |
|--------|------|---------------|--------|
| SPI SD card | `0x88` | a physical SD card in the SD-card socket (SPI wires `SD_CS`/`SD_SCK`/`SD_MOSI`/`SD_MISO` are connected directly to it) | `Components/SDCARD/sd_controller.vhd` |
| HPS image block device | `0x90` | an image file on the MiSTer Linux host, mounted with the OSD **SD card image** entry (`S,IMG`) | `Components/SDCARD/hps_blockdev.vhd` |

The SPI controller never touches the HPS image interface and the block
device never touches the SD pins, so neither can disturb the other. (Earlier
versions emulated an SD card on the SPI wires and switched the one
`sd_controller` between the socket and the image; that was removed.) With no
physical card inserted `sd_controller` stays in its initialisation state
(`STATUS` bit 4 stays set), which is how software sees an absent card.

#### Register map (offsets from the base port: `0x88` or `0x90`)

| Offset | Read | Write | Notes |
|--------|------|-------|-------|
| 0 | DATA | DATA | Sequential byte stream of the current block |
| 1 | STATUS | CONTROL | Control: `0x00` = read block, `0x01` = write block |
| 2 | - | LBA0 | block number bits 7:0 |
| 3 | - | LBA1 | block number bits 15:8 |
| 4 | - | LBA2 | block number bits 23:16 (24-bit block numbers = 8 GB) |
| 5 | SIZE0 | - | **HPS block device only**: image size in 512-byte blocks, bits 7:0 |
| 6 | SIZE1 | - | bits 15:8 |
| 7 | SIZE2 | - | bits 23:16 |

The SPI controller has no size registers. Its registers 5-7 are read-only
diagnostics that show where an initialisation that does not finish is stuck:

| Offset | Read (SPI SD card only) |
|--------|-------------------------|
| 5 | current FSM state number (`state_code` in `sd_controller.vhd`; `09h` = idle, `10h` = waiting for a response) |
| 6 | the step that follows the current command/response: while waiting for a response this names the command (`03h` = response to CMD0, `04h` = CMD8, `05h` = CMD55, `06h` = ACMD41, `07h` = CMD58 response) |
| 7 | b7 `SD_MISO` (live level), b6 `SD_CS`, b5 `SD_SCK`, b4 card is SDHC, b3 `SD_CD` (the MiSTer framework's card detect, 1 = **no card seen**), b2:0 number of init restarts since reset (saturates at 7) |

FPGA builds from before the diagnostics read 0 in registers 5-7.

The card is initialised at about 250 kHz SPI clock after reset (80 clocks with
CS high, CMD0, CMD8, CMD55/ACMD41 until ready, CMD58), then the controller runs
at 6.25 MHz (`HS_DIVIDER` = 4 in `sd_controller.vhd`: SPI clock = 50 MHz / (2 * HS_DIVIDER);
1 = 25 MHz, 2 = 12.5 MHz). 25 MHz returned corrupt data on a MiSTer I/O board, see HISTORY.md. While initialising, a response that does not arrive within about
65 ms restarts the sequence from the beginning (init restarts, register 7), so a
card that is inserted after the core was loaded, or that was left in an odd
state, is picked up without a reset. STATUS bit 4 stays set until the card is
ready. Note that the MiSTer framework (`sys/sys_top.v`) forces `SD_MISO` high
and tri-states the SPI pins when it believes there is no card in the secondary
SD socket (`SD_CD` high); that looks exactly like a card that never answers.

STATUS bits:

| Bit | SPI SD card (`0x88`) | HPS block device (`0x90`) |
|-----|----------------------|---------------------------|
| 7 | write byte can be accepted | same |
| 6 | read byte available | same |
| 5 | block busy | block busy (command in progress / waiting for the HPS) |
| 4 | **init busy** (card being initialised, or absent) | **no image mounted** |
| 3 | 0 | image is **read-only** |
| 2 | 0 | last command was **rejected** (no image, LBA >= size, or a write to a read-only image); cleared by the next accepted command |
| 1:0 | 0 | 0 |

Typical HPS block device status values: `0x90` no image, `0x80` idle (`0x88`
if the image is read-only), `0x20` command accepted and waiting for the HPS,
`0xE0` read data ready, `0xA0` ready for write data, `0x84`/`0x8C` idle with
the "rejected" flag set.

SIZE0..2 read 0 when no image is mounted and saturate at `0xFFFFFF` blocks
(8 GB). A mounted size that is not a multiple of 512 is rounded down.

#### Programming sequence

```
read block N:    wait STATUS = 0x80 (mask 0xF0)    ; previous command done
                 OUT LBA0, LBA1, LBA2
                 OUT CONTROL, 0x00
                 512 times: wait STATUS = 0xE0 ; IN DATA
write block N:   wait STATUS = 0x80 (mask 0xF0)
                 OUT LBA0, LBA1, LBA2
                 OUT CONTROL, 0x01
                 512 times: wait STATUS = 0xA0 ; OUT DATA
                 (the device then writes the block; STATUS = 0x20 until it
                  has finished, then 0x80 again)
```

The HPS block device keeps the STATUS read/write-ready bits set for the
whole block, so after the first status check the 512 bytes can be moved
with `INIR` / `OTIR` (the SPI controller needs a status check per byte). A
rejected command leaves the device idle with bit 2 set, so after issuing a
command wait for `0xE0`/`0xA0` *or* for bit 2 to get set; do not wait for
`0xE0` alone. Completed transfers with bit 2 clear show STATUS `0x80`.

#### HPS block device details

- **Mounting.** Choose an image with the OSD *SD card image* entry. The HPS
  reports the mount once; the device remembers the image presence, the
  read-only flag and the size across a CPU reset or an OSD Reset, and
  forgets them only if the image is un-mounted (size 0) or the core is
  reloaded. A mount (or un-mount) aborts a transfer that is in progress.
  With the OSD option *Reset after Mount* set to *Yes* the core is reset
  after every mount.
- **Writes.** STATUS returns to idle only after the HPS has taken the block
  from the device's buffer, so a following read of the same block sees the
  new data.
- **Block addressing** is the same for any image size; there is no
  partitioning or file system in the hardware.
- **Activity LEDs.** The disk LED (`LED_DISK`) is lit by activity on either
  device. The user LED (`LED_USER`) shows SD-socket SPI line activity OR
  block device activity. The block device stretches its activity signal
  by 20 ms so that short transfers are visible.
- **Clocking.** `hps_io` runs on `clk_sys` (the core PLL clock), not on
  `CLK_50M`, so the mount, block-transfer and file-download signals are
  synchronous with this device and with the boot-source latch. (An earlier
  version clocked `hps_io` from `CLK_50M`; `sys_top.sdc` treats that as an
  asynchronous clock group, so the crossing was unsynchronised and untimed
  and made behaviour depend on the fit.)
- **Test program.** `testing/blockdevtest.asm` (read tests, then optional
  write/read-back tests on the 100 sectors at the top of the image, which
  are backed up and restored; verified on hardware with a 128 MiB image).
  Simulated end to end in GHDL by `sim/run_blockdev_prog.sh`; unit testbench `sim/tb_hps_blockdev.vhd`
  (`sim/run_blockdev.sh`).

### FPGA build options for the SPI SD card socket (board configuration)

Whether the SPI SD controller (`0x88`-`0x8F`) can reach a card depends on how
the board's SD socket is wired and on how the MiSTer framework (`sys/sys_top.v`)
routes it, which differs between I/O boards. The options below are set when the
FPGA image is built (`MrZ80.qsf`, `sys/sys_top.v`, `Components/SDCARD/sd_controller.vhd`);
rebuild with `tools/build.sh` after changing them. `testing/sdcardtest.asm` prints
the controller's diagnostics (`MISO`, `CS`, `SCLK`, `SDHC`, `CD`, init restarts)
and is the way to check a configuration.

#### Which configuration do I need?

The framework looks for an **MCP23009** I2C I/O-expander chip (address `0x20`) on
the I/O board at power-up. When it is present the I/O board's buttons, LEDs,
digital/analog mode and the SD socket's card-detect all go through that chip and
the SD socket is wired to the `SD_SPI_*` pins. When it is absent the framework
uses the older scheme: card detect is the `SDCD_SPDIF` pin (a bare FPGA pin with
a weak pull-up), the SD signals share the `SDIO_*` pins with the analog video,
and the four DE10-Nano slide switches select modes (see below).

| Your hardware | `MRZ80_SD_IGNORE_CD` | `MRZ80_SD_FORCE` | Notes |
|---------------|----------------------|------------------|-------|
| I/O board **with** an MCP23009 and a working card-detect switch | off | off (no effect) | Stock framework behaviour. |
| I/O board **with** an MCP23009 but the socket's card-detect pin not wired or not working | **on** | off (no effect) | `SD_CD` reads 1 (no card), which makes the framework tri-state the SPI pins and force `SD_MISO` high. |
| I/O board **without** an MCP23009, socket card-detect not connected | **on** | **on** | The configuration tested on a QMTech DE10-Nano clone and its I/O board (micro SD socket pin 9 unconnected, no MCP23009). The slide switches do not affect the SD socket. Analog video on the shared `SDIO` pins is lost. |
| I/O board **without** an MCP23009, card-detect wired so it pulls `SDCD_SPDIF` low with a card, and the analog video is wanted | off | off | Stock framework: needs `SW[3]` = 0, the `VGA_EN` pin low (the analog I/O board pulls it low), and either the card-detect pin low or `SW[2]` = 1. |

How to tell which case you are in: with the diagnostics, register `8Fh` bit 3
(`CD`) reads 1 and the controller never leaves init (`STATUS` stays `90h`, init
restarts count up to 7) when the framework hides the card. `CD` reading 1 with a
card inserted means the card-detect is not wired, or no MCP23009 exists and
`SDCD_SPDIF` is floating high. `CD` is the framework's own signal; with
`MRZ80_SD_IGNORE_CD` set it is still reported but no longer used for gating, so
`CD=1` is normal on a board without a working card-detect.

#### Build parameters

| Parameter | Where | Default | Meaning |
|-----------|-------|---------|---------|
| `MRZ80_SD_IGNORE_CD` | `MrZ80.qsf`, `VERILOG_MACRO` | defined | The card detect no longer gates `SD_MISO` and the `SD_SPI_CS/CLK/MOSI` pins in `sys/sys_top.v` (`sd_cd_g` forced to 0). The core still receives the real `SD_CD`. For boards whose card-detect is not connected. Delete the line to restore the stock behaviour. |
| `MRZ80_SD_FORCE` | `MrZ80.qsf`, `VERILOG_MACRO` | defined | Only affects boards without an MCP23009. Always routes `SD_SCK`, `SD_MOSI` and `SD_CS` to `SDIO_CLK`, `SDIO_CMD` and `SDIO_DAT[3]`, and reads `SD_MISO` from `SDIO_DAT[0]`, ignoring `SW[2]`, `SW[3]`, `VGA_EN` and the card detect. The analog video outputs that share these pins stop working. Delete the line for the stock routing. |
| `HS_DIVIDER` | generic of `sd_controller` (`Components/SDCARD/sd_controller.vhd`) | 4 | SPI clock after init = 50 MHz / (2 * `HS_DIVIDER`): 1 = 25 MHz, 2 = 12.5 MHz, 4 = 6.25 MHz, 8 = 3.1 MHz. 25 MHz returned corrupt data on the QMTech clone (see below); 6.25 MHz passed all read and write tests. Raise it if reads are unreliable, lower it (2) to try for speed on short, clean wiring. Change the default in the entity, or add a `generic map` on the `sd1` instance in `MicrocomputerZ80CPM.vhd`, then run `sim/check_sync.sh` and refresh the `sim/*_sim.vhd` copies (see `sim/STATUS.md`). |
| `CLKEDGE_DIVIDER` | generic of `sd_controller` | 100 | Clock divider during card initialisation: 50 MHz / (2 * 100) = 250 kHz (the SD specification allows up to 400 kHz). Leave unchanged. |

Why the data-phase clock is slow: the controller samples `SD_MISO` just before
the rising edge of `SD_SCK`. The clock leaving the FPGA, the card's output delay
(up to 14 ns) and the data coming back through the pins and boards have to fit in
half a clock period, 20 ns at 25 MHz. Reads were then corrupt and unrepeatable
(a block read differently each time); initialisation, which runs at 250 kHz, was
fine. At 6.25 MHz (80 ns) there is plenty of margin.

Two more macros matter to this socket, in a different category from the two
above:

- **`SDRAM_CLK_100` is defined**, so the SDRAM controller runs on the PLL's
  100 MHz tap (`outclk_2`) and not on the 112 MHz `outclk_1` the CoCo3
  `sdram_32r8w` controller was ported for. It is a source-level
  ``` `define ``` in `MrZ80.sv` rather than a `.qsf` `VERILOG_MACRO`, so only the
  source controls it. The controller itself is correct at either frequency (its
  refresh constant is derived for 112 MHz and is therefore conservative at
  100 MHz). This is the timing-closure fallback, and it is the state the machine
  runs in today; raising it back to 112 MHz is a deliberate piece of deferred
  work — see `REQUIREMENTS.md` item 4.
- **`MISTER_DUAL_SDRAM` is not defined** (its home, `sys_dual_sdram.tcl`, is
  never sourced). If it were, `sys/sys_top.v` would use a different SD wiring
  (`SD_SPI_*` pins only, MCP23009 card-detect required) and the two options above
  would not apply.

#### The slide switches (boards without an MCP23009)

The framework reads the four DE10-Nano slide switches as plain FPGA inputs
(`SW[0]`..`SW[3]`, pins Y24, W24, W21 and W20 as assigned in `sys/sys.tcl`); a
switch is "on" when its input is at 3.3 V (logic 1). Which way the lever moves
for 3.3 V, and which silkscreen label is which pin, depend on the board: check the
schematic (on the QMTech DE10-Nano clone, `SW[2]` was traced to W21) or measure
the pin with a multimeter. When an MCP23009 is present the framework ignores
most of them (the chip supplies the mode and buttons).

| Switch | Function in the framework (no MCP23009) | Setting for this core |
|--------|------------------------------------------|-----------------------|
| `SW[0]` | Audio output pins on the I/O board (`AUDIO_L`, `AUDIO_R`, `AUDIO_SPDIF`): on = digital audio (HDMI I2S/SCLK/LRCLK), off = analog audio and S/PDIF. | Not used by the SD card or the serial ports. Leave off. |
| `SW[1]` | User port (USB 3.0 connector) pins `USER_IO[2]`, `[4]`, `[5]`: on = they carry HDMI I2S digital audio (for an I2S DAC on the user port) and the core's `USER_IN[2]`, `[4]`, `[5]` read 1; off = normal user I/O. | This core's user-port serial uses `USER_IO[0]`, `[1]` and `[3]`, which are not affected. Leave off. |
| `SW[2]` | SD socket routing: when the card-detect pin (`SDCD_SPDIF`) is high (no card seen), on forces the SD signals onto the `SDIO_*` pins (otherwise those pins carry analog video). A manual override for boards whose card-detect does not work. | **Ignored** with `MRZ80_SD_FORCE`. Without it, turn on if the card-detect is not wired. |
| `SW[3]` | I/O board type: off = analog I/O board (its analog video, audio and LED pins are driven and its `BTN_RESET`/`BTN_OSD`/`BTN_USER` buttons are used); on = digital I/O board (analog pins tri-stated, buttons expected from the MCP23009, so none work on a board without it). | Leave **off** on an I/O board without an MCP23009. With `MRZ80_SD_FORCE` it does not affect the SD socket. |

The five small DIP switches on the QMTech clone are not read by the framework or
by this core; consult the board documentation (they are normally FPGA/HPS
configuration or boot-select switches) before changing them.

#### Verified configuration

QMTech DE10-Nano clone with 128 MB SDRAM and its I/O board (no MCP23009,
micro SD socket card-detect pin not connected, socket wired to `SDIO_CLK`
(AH26), `SDIO_CMD` (AF27), `SDIO_DAT[3]` (AF28) and `SDIO_DAT[0]` (AF25)):
`MRZ80_SD_IGNORE_CD` and `MRZ80_SD_FORCE` defined, `HS_DIVIDER` = 4. A micro SD
card (SDHC) initialised with `STATUS` `80h`, and `testing/sdcardtest.asm`
passed the read tests and the write tests (backup, two write patterns, restore)
on two consecutive runs.

### Serial-like devices

There are two devices, occupying 4 total I/O ports between `0x80` and `0x83`.  Both of these
emulate the programming interface of an 6850 ACIA device, including its
**master reset**: writing a control byte with bits 1:0 = `11` makes the status
read `0x00` (no RDRF, no TDRE) and discards buffered input (video terminal),
until the next control write.  RomWBW's ACIA driver detects the devices this way
(write `03`, expect status `00`; write `02`, expect TDRE with DCD and CTS low).
Software that never writes the control register is unaffected.

#### Video Terminal Display Device

The video display implements a VGA display resolution terminal.  It has
a display resolution 80x25 characters.  It emulates a basic ANSI terminal
with display attributes, cursor positioning, etc.

##### I/O Ports

| Port       | Function                                                |
|------------|---------------------------------------------------------|
| `80`       | Read: Status Register, Write: Control register          |
| `81`       | Read: Keyboard input character, Write: Display terminal emulator |

##### Status register 
|  7   |  6 |  5  |  4  |  3  |  2  |  1  |  0  |
|-----------------------------------------------|
| nInt |  -  |  -  |  -  | nCTS | nDCD | TXDONE | RXRDY |

##### Status Register Signal Descriptions

| Signal | Description                              |
|--------|------------------------------------------|
| nInt   | active low Interrupt - interrupt pending if interrupts enabled. |
| nCTS   | reads 0 (clear to send — always ready; there is no handshake) |
| nDCD   | reads 0 (data carrier present — always ready) |
| TXDONE | Ready to send more characters to display |
| RXRDY  | Input character from keyboard ready      |

While the device is in 6850 **master reset** (control write `03`: bits 1:0 =
`11`) the whole status reads `0x00` and display writes are ignored, until the
next control write.

##### Keyboard Input

Keys are kept in a 16-entry buffer; when it is full, further keys are dropped
(older keys are never overwritten).  Besides the ASCII keys (Ctrl and Caps Lock
apply; Caps Lock starts on):

| Key | Sends |
|---|---|
| Esc | `1B` |
| Delete | `7F` |
| Up / Down / Right / Left | `ESC [ A` / `ESC [ B` / `ESC [ C` / `ESC [ D` |
| Home / End | `ESC [ H` / `ESC [ F` |
| Insert / Page Up / Page Down | `ESC [ 2 ~` / `ESC [ 5 ~` / `ESC [ 6 ~` |
| F1–F4 | `ESC O P` … `ESC O S` |
| F5–F12 | `ESC [ 15 ~`, `17`, `18`, `19`, `20`, `21`, `23`, `24 ~` |

(Before R44 the Esc key sent `03` and the arrow block sent keypad digits.) The
keypad keys always send digits (there is no Num Lock handling).  While the SSP
monitor has its own screen up (see the SSP section), this terminal keeps no
keys.

This module processes PS/2 keyboard input events.  Of course, on the
MiSTer there are no PS/2 keyboards connected to the hardware.  The
host Linux system takes keybaord input from a USB attached keyboard
device and then synthesizes PS/2 keyboard events to pass to this
terminal emulator.  This device then turns these events back into
characters that appear as if they were received on a serial port.

There is no mapping for different keyboard layouts here; I believe
that's a capability abstracted away to the general MiSTer platform to
manage, rather than specific FPGA cores such as this one.

##### ANSI Terminal Emulation

The terminal emulates a basic ANSI terminal on output.

#### ACIA UART

This is not an emulated terminal, but either an emulated serial port or
an actual serial UART implemented in the FPGA.  In either case, the
programming model for Z80 programs is a 6850 ACIA serial controller.  This
peripheral can be connected in either of two ways.

1. By default, when the MrZ80 MiSTer core starts up, this serial device
is connected to a virtual serial device on the MiSTer's Linux
host.  It is available as a /dev/ttyS0 device in the Linux environment.
You can SSH into the Linux host, and use the `screen` program to talk
to that serial device that's connected to the Z80.

2. Using the OSD (on screen display) of the MiSTer, you can alternatively
select the `USER` device which are hardware serial in and out pins on
the USER connector on the side of the MiSTer I/O board.  Inexplicably,
the designers chose to use a USB3 **A** connector.. because it had enough
pins?  Here there are 3.3V TTL level signals that you can connect to
a USB/serial adapter or other device.  **It is important to recognicze
that these are 3.3V logic signals, and you should not connected 5V
TTL level signals to these FPGA pins.**  The FPGA is _not_ 5V tolerant
and it is easy to damage those I/O pins.

##### I/O Ports

| Port       | Function                                                |
|------------|---------------------------------------------------------|
| `82`       | Read: Status Register, Write: Control register          |
| `83`       | Read: received character, Write: character to transmit  |

##### Status register 
|  7   |  6 |  5  |  4  |  3  |  2  |  1  |  0  |
|-----------------------------------------------|
| nInt |  -  |  -  |  -  | nCTS | nDCD | TXDONE | RXRDY |

##### Status Register Signal Descriptions

| Signal | Description                              |
|--------|------------------------------------------|
| nInt   | active low Interrupt - interrupt pending if interrupts enabled. |
| nCTS   | active low CTS signal, tied low (always clear to send) |
| nDCD   | active low DCD signal, tied low (carrier always present) |
| TXDONE | Transmit holding register empty — ready for the next character |
| RXRDY  | Received character ready                 |

The same 6850 **master reset** applies (control write `03` -> status `0x00`
until the next control write). Note that a master reset also resets the
transmitter state machine, so a character in flight or queued at that moment may
be truncated or lost — as on a real 6850.

### MMU I/O register window detail
16 consecutive ports, decoded relative to `io_cs` on the low 4 address bits, `0xB0` - `0xBF`:

| Port       | Function                                                |
|------------|---------------------------------------------------------|
| `B0`..`B3` | Frame 0..3 mapping register, bits 7:0 (Z2-compatible)   |
| `B4`..`B7` | Frame 0..3 mapping register, bits 15:8 (extension;      |
| `B8`..`BB` | Direct-access pointer bytes, little-endian (LSB at `B8`)|
| `BC`       | Direct-access data port (R/W triggers a physical memory cycle at the pointer; pointer post-increments after the access) |
| `BD`..`BF` | Reserved (reads 0, writes ignored)                     |

### Benchmark timer window detail (`0xC0`-`0xCF`)

`Components/TIMER/BenchTimer.vhd`. Two free-running 32-bit counters, derived
from the 50 MHz system clock, count microseconds (wraps after ~71.6 min) and
milliseconds (wraps after ~49.7 days). They start at 0 when the FPGA is
configured (core loaded) and are **never reset** afterwards — not by the
CPU reset button, the OSD reset or software — so they are monotonic.

Each of four channels has its own 32-bit snapshot latch:

| Ports        | Channel | Time base | Write (any value)                | Read                              |
|--------------|---------|-----------|----------------------------------|-----------------------------------|
| `C0`..`C3`   | 0       | 1 ms      | latch the ms counter into ch0    | ch0 bytes 0..3 (LSB at `C0`)      |
| `C4`..`C7`   | 1       | 1 ms      | latch the ms counter into ch1    | ch1 bytes 0..3 (LSB at `C4`)      |
| `C8`..`CB`   | 2       | 1 µs      | latch the µs counter into ch2    | ch2 bytes 0..3 (LSB at `C8`)      |
| `CC`..`CF`   | 3       | 1 µs      | latch the µs counter into ch3    | ch3 bytes 0..3 (LSB at `CC`)      |

- A write to **any** of a channel's four ports latches that channel (data
  ignored), once per `OUT`.
- Reads have no side effects: bytes can be read in any order, repeatedly,
  and channels are independent (e.g. a benchmark can own ch0 while a
  monitor uses ch1).
- Elapsed time = `end - start` modulo 2^32.

```
        OUT  (0C0h),A      ; snapshot channel 0 (ms)
        IN   A,(0C0h)      ; bits  7:0
        IN   A,(0C1h)      ; bits 15:8
        IN   A,(0C2h)      ; bits 23:16
        IN   A,(0C3h)      ; bits 31:24
```

Test program: `testing/timertest.asm`.

CamelFORTH (embedded kernels `camel80.bin` / `camelf.bin`): `MS@ ( -- ud )`
returns channel 0 (ms) and `US@ ( -- ud )` channel 2 (µs), each latched at
the start of the word, as an unsigned double (low cell, high cell on top).
Channels 1 and 3 are not used by the kernel.

### Interval timer window detail (`0xD0`-`0xD3`)

`Components/TIMER/IntervalTimer.vhd`. Counts milliseconds from the 50 MHz
system clock (independent of the CPU clock and wait states) and raises a
**level** interrupt request every INTERVAL ms. Together with the two ACIA
interrupt outputs — the video terminal (`$80`/`$81`) and the serial port
(`$82`/`$83`) — it is wired to the Z80 `INT` pin: the three active-low
requests are ANDed, so any asserted source drives `INT`. Use Z80
**interrupt mode 1**: the CPU takes `RST 38h`, and the
handler polls this device's STATUS (and any other device's) to find the
source. Mode 0, the reset default, also works: the interrupt-acknowledge
read floats to `FFh`, which is `RST 38h`. A Z80 reset clears the timer.
While the SSP single-step sequencer is armed `INT` is masked at the CPU; the
timer keeps counting and EXPIRED stays set.

| Port | Write                       | Read                       |
|------|-----------------------------|----------------------------|
| `D0` | INTERVAL, low byte          | INTERVAL, low byte         |
| `D1` | INTERVAL, high byte         | INTERVAL, high byte        |
| `D2` | CONTROL (levels)            | STATUS                     |
| `D3` | COMMAND (one-shot strobes)  | STATUS (same as `D2`)      |

INTERVAL is 16 bits of milliseconds (1 = every ms, 0 counts as 1; up to
65535 ms). It may be changed while running.

CONTROL (each write sets IE and AUTO, and acts on RUN):

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | RUN  | 1 = start counting from 0 if stopped (no effect if already running); 0 = stop and clear the count |
| 1 | IE   | 1 = EXPIRED drives `INT` |
| 2 | AUTO | 1 = restart on expiry (periodic, no drift); 0 = one-shot, stops on expiry |

COMMAND (nothing is stored; write 1 to act):

| Bit | Name   | Meaning |
|-----|--------|---------|
| 0 | RESET  | clear the count to 0; a running timer keeps running and counts a full interval |
| 1 | ACK    | clear EXPIRED, which releases the interrupt request |
| 2 | CLROVF | clear OVERFLOW |

STATUS:

| Bit | Name     | Meaning |
|-----|----------|---------|
| 0 | EXPIRED  | set when the interval elapses; stays set until ACK |
| 1 | OVERFLOW | set when it expires again while EXPIRED is still set (a missed tick); stays set until CLROVF |
| 2 | RUNNING  | counting (a one-shot clears it on expiry) |
| 3 | INTREQ   | this timer is asserting `INT` (EXPIRED and IE) |
| 4 | IE       | as written to CONTROL |
| 5 | AUTO     | as written to CONTROL |
| 7:6 | | 0 |

Stopping (RUN = 0) keeps EXPIRED and OVERFLOW. An ACK in the same clock as an
expiry leaves EXPIRED set (the new expiry is kept) without OVERFLOW.

```
        IM   1
        LD   A,10         ; 10 ms
        OUT  (0D0h),A
        XOR  A
        OUT  (0D1h),A
        LD   A,07h        ; RUN + IE + AUTO
        OUT  (0D2h),A
        EI
; handler at 0038h:
        IN   A,(0D2h)     ; STATUS
        AND  08h          ; INTREQ: ours?
        ...
        LD   A,02h        ; ACK
        OUT  (0D3h),A
```

Tests: `sim/run_interval_timer.sh` (unit bench) and `sim/run_itimer_z80.sh`
(Z80 program through the real fabric, modes 0 and 1); both in `sim/Makefile`.
On hardware: section 6 of `testing/timertest.asm` (after the BenchTimer tests)
times the interval timer against the BenchTimer microsecond counter and tests
interrupt modes 0 and 1.

### Real-time clock window detail (`0x70`-`0x71`)

`Components/RTC/ds12887.vhd`, a behavioural Dallas DS12887 (MC146818
compatible) with 128 registers. The 7-bit register address cannot be decoded
directly in the 8-bit I/O space, so access is through an AT-style index/data
pair (decode `n_rtcCS`, `cpuAddress(7 downto 1) = "0111000"`):

| Port   | Write                                   | Read                         |
|--------|-----------------------------------------|------------------------------|
| `0x70` | register index (bits 6..0; bit 7 ignored) | current index (bit 7 = 0)  |
| `0x71` | write the register selected by the index | read the register selected by the index |

The index is not auto-incremented and is cleared on reset.

Register map (see `Components/RTC/README.md` for full detail):

| Index         | Register                                                                  |
|---------------|---------------------------------------------------------------------------|
| `00`          | Seconds                                                                   |
| `01`          | Seconds alarm                                                             |
| `02`          | Minutes                                                                   |
| `03`          | Minutes alarm                                                             |
| `04`          | Hours                                                                     |
| `05`          | Hours alarm                                                               |
| `06`          | Day of week (1 = Sunday)                                                  |
| `07`          | Day of month                                                              |
| `08`          | Month                                                                     |
| `09`          | Year (00-99)                                                              |
| `0A`          | Register A (UIP, DV2..0, RS3..0)                                          |
| `0B`          | Register B (SET, PIE, AIE, UIE, SQWE, DM, 24/12, DSE)                     |
| `0C`          | Register C (IRQF, PF, AF, UF); read clears all flags                      |
| `0D`          | Register D (VRT)                                                          |
| `0E`,`0F`     | Unused, read `0xFF`                                                       |
| `10`-`7F`     | 112 bytes of general-purpose RAM (volatile; not battery backed)           |

- **Time source:** the MiSTer HPS pushes the host's local time (BCD) when the
  core is loaded and once a minute thereafter (`hps_io` `RTC[64:0]`). The
  clock starts running from that time in 24-hour BCD mode, so software sees a
  valid clock without any setup. Once software writes the time/calendar
  registers the periodic host refresh no longer overrides them. The time is
  re-read from the host on each core reset, and the RAM is not preserved
  across FPGA reconfiguration.
- **Bus timing:** the DS12887 model sees a one-clock `req`/`wrt` pulse per
  `IN`/`OUT` to `0x71`, so reading Register C clears the flags exactly once.
- **Not implemented / deviations:** the SQW output is not generated, DST is
  stored but has no effect, and the interrupt output is **not connected**
  to the Z-80 `/INT` (that pin is driven by the interval timer, terminal
  and serial UART, above); software must poll Register C.
  Periodic-interrupt tap rates are derived from the 50 MHz clock (< 0.02 %
  error).

```
        LD   A,00h
        OUT  (70h),A       ; select seconds
        IN   A,(71h)       ; A = seconds (BCD)
        LD   A,0Bh
        OUT  (70h),A       ; select Register B
        IN   A,(71h)
```

### PSG sound: dual YM2149 (`0x50`/`0x51` and `0x68`/`0x60`)

Two YM2149 / AY-3-8910 programmable sound generators, three tone channels
and one noise generator each, mixed to stereo and played through the
MiSTer audio output (HDMI and the analog jack). `Components/PSG/MrZ80_PSG.sv`
wraps the vendored `YM2149_PSG_system` (`Components/YM2149`, from
[epsilon537/YM2149_PSG_system](https://github.com/epsilon537/YM2149_PSG_system),
built on [jotego/jt49](https://github.com/jotego/jt49), GPL-3.0). The chips
are clocked at 1.7897725 MHz (the MSX clock, RomWBW's `AY_CLK`), derived
from the 50 MHz system clock, so pitch does not depend on the CPU speed.
Each channel uses a 10-bit logarithmic DAC table, which is a close match to
a real YM2149's output levels.

#### Programming model

Each chip is a standard AY-style SELECT/DATA port pair: write the register
number to SELECT, then write the value to DATA (or read it back).

| Port   | Write                 | Read                                         |
|--------|-----------------------|----------------------------------------------|
| `0x50` | device 1 SELECT       | selected register                            |
| `0x51` | device 1 DATA         | selected register (where RomWBW `ay.asm` reads) |
| `0x68` | device 2 SELECT       | selected register (where vibetune reads an "EB" card) |
| `0x60` | device 2 DATA         | selected register                            |

| SELECT value | Device 1                          | Device 2               |
|--------------|-----------------------------------|------------------------|
| `0x00`-`0x0F` | PSG registers R0-R15             | PSG registers R0-R15   |
| `0x80`-`0x89` | left mixer registers 0-9 (MrZ80 extension) | deselected |
| `0x90`-`0x99` | right mixer registers 0-9 (MrZ80 extension) | deselected |
| anything else | deselected                       | deselected             |

A deselected chip drops DATA writes and reads `0xFF`, the way a real
AY-3-8910 ignores a latched address whose upper nibble is not its chip
code. Legacy software never writes a SELECT value above 15, so it cannot
reach the mixer registers by accident. The SELECT latches clear on reset.

The PSG registers are the standard AY-3-8910 set: R0/R1, R2/R3 and R4/R5 are
the 12-bit tone periods of channels A, B and C (frequency =
1789772 / (16 x period)); R6 is the noise period; R7 is the mixer enable
(bits 0-2 tone A-C, bits 3-5 noise A-C, **0 = on**; bits 6-7 I/O port
direction); R8-R10 are the channel volumes (0-15, bit 4 = use envelope);
R11/R12 are the envelope period, R13 the envelope shape (a write restarts
it), and R14/R15 the I/O ports (not wired to anything; they read back the
written value when set as outputs, R7 bits 6/7 = 1, and 0 as inputs). Unused bits read back as 0, as on the
AY-3-8910 (for example R1 reads back 4 bits).

#### The stereo mixers

The two chips do not each get one output. Both feed **two mixers, one for
the left output and one for the right**, and each mixer sums all six
channels, A, B, C of device 1 (mixer inputs A-C) and A, B, C of device 2
(mixer inputs D-F), each with its own gain, and then applies a DC filter,
bass and treble shaping and a master volume. Panning a channel is therefore
a matter of giving it different gains on the two sides. Registers of one
mixer (SELECT `0x80`+n for the left, `0x90`+n for the right, through the
device-1 ports):

| n | Register | Notes |
|---|----------|-------|
| 0-5 | gain of A, B, C, D, E, F | 0 = off; the product is input x gain / 256, so 64 = 1/4 of full scale |
| 6 | master volume | 0 = mute, 128 = 100 %, 255 = 200 % with a limiter |
| 7 | phase invert | bit n inverts channel n (A-F) on this side |
| 8 | bass | 1 = most bass ... 63 = least; 0 lets DC through, do not use |
| 9 | treble | 0 = full bandwidth ... 255 = muffled |

#### OSD "PSG Stereo": Mono, ABC, ACB

The OSD option picks the panning that the core writes into the mixers.
"ABC" and "ACB" are the two stereo conventions used by AY music, named
after the left-to-right order of the three channels:

| OSD | Channel A | Channel B | Channel C | Used by |
|-----|-----------|-----------|-----------|---------|
| Mono | centre | centre | centre | MSX, the vendor default |
| ABC | left | centre | right | ZX Spectrum 128 stereo add-ons, Amstrad CPC |
| ACB | left | right | centre | Pentagon and many demoscene players and trackers |

Device 2's channels are panned the same way as device 1's, so a
TurboSound (two-chip) tune keeps each chip's stereo image. "Left" and
"right" are not hard: a side channel is mixed 3:1 (gains 96 and 32 of 256),
so it never disappears from one ear on headphones, and a centre channel is
64 on both sides. Every mode keeps the total gain per side at 384, so
changing the option does not change the loudness. The MiSTer framework's
own L/R mix (`AUDIO_MIX`) is left off.

The core applies the option after every reset and whenever it changes in
the OSD. An OSD change rewrites only the gains (registers 0-5) of both
mixers: software changes to the master volume, phase invert, bass or
treble are kept, but software gain settings are overwritten. Software can
read the gains back to see which mode is in effect (`testing/psgtest.asm`
does).

#### Reset: both chips start silent

A Z-80 reset (OSD Reset, the reset button, power-up) resets both PSGs and
both mixers. The PSG registers reset to 0, so every channel volume is 0 and
neither chip makes a tone. The mixers' DC filter would still produce a thump
at power-up, because the silent DAC level is not centred and the filter
takes about 12 ms per time constant to centre it. The core therefore holds
both master volumes at 0 for 200 ms after reset (about 17 time constants),
then writes the OSD panning and sets the master volume to 128. The output
is exactly zero during that window, and afterwards it is a constant
residual of a few LSB (-72 dBFS, the filter's resolution) with no AC
content. Software can write the PSG registers at any time; it is only the
mixer output that is held off for those first 200 ms.

#### Software

- **RomWBW:** `cfg_MRZ80.asm` sets `AYENABLE TRUE`, `AYMODE AYMODE_COLECO`
  and `AY_CLK 1789772`. The stock `ay.asm` driver finds device 1 at
  `0x50`/`0x51` (it probes by writing R2 and reading it back from `0x51`) and
  the boot banner shows `AY: MODE=COLECO IO=0x50`. RomWBW drives only one AY.
  Verified on hardware (2026-11-04): `TUNE.COM` plays PT3 tunes, both through
  the sound driver (`--hbios`) and driving the ports itself (`-coleco`).
  `TUNE.COM` has one more wrinkle when neither switch is given: it does its own
  chip detection, writing R2 and reading it back from the third column (RIN) of
  its config table, and every Coleco row in that table uses `0x52` - the RC
  Sound Module's read port, which this core does not decode. The platform-29
  row added for the MrZ80 reads back at `0x51` instead, like `ay.asm`, so plain
  `TUNE file.pt3` detects the chip itself - confirmed on hardware (2026-11-04),
  where it prints `MrZ80 YM2149 PSG (50H/51H), timer mode` and plays.
- **vibetune** (`VTUNE.COM`, [jduraes/vibetune](https://github.com/jduraes/vibetune)):
  takes device 1 from the HBIOS sound driver automatically. For two-chip
  TurboSound tunes, run `VTUNECFG` and set the TurboSound hardware to
  dual-card and the second AY card to **EB**, which is `0x68`/`0x60` on a
  Z-80. Do not use the `-coleco` switch: vibetune's forced Coleco
  configuration swaps the SELECT and DATA ports (it uses `0x51`/`0x50`),
  unlike its own card-2 table, its README and RomWBW. The automatic (HBIOS)
  path is correct.
- **`testing/psgtest.asm`** probes both chips, prints the mixer gains and
  the OSD mode, and plays the opening motif of *Close Encounters of the
  Third Kind* (G4 A4 F4 F3 C4) on device 1 channel A, then device 2
  channel C. Under ABC the first pass is heard on the left and the second
  on the right. Passes on hardware (2026-11-04).

#### Implementation notes

- `MrZ80_PSG` holds the two SELECT latches and steers one shared bus into
  `YM2149_PSG_system`, whose own interface is a flat 8-bit address (high
  nibble 0 = PSG A, 1 = PSG B, 8 = left mixer, 9 = right mixer) with
  level-sensitive writes. The CPU always has priority on that bus; the
  panning sequencer writes only in idle clock cycles. Register reads are
  registered and valid about 2 clocks after the address settles, well
  inside a 10 MHz Z-80 I/O cycle.
- `YM2149_PSG_system.sv` takes its build options from the build, not the
  file (upstream sets them from a manifest): `MrZ80.qsf` defines
  `USE_STEREO` and `USE_DUAL_PSG` as `VERILOG_MACRO`s, and `sim/run_psg.sh`
  passes the same macros. Without them the core would have one mono PSG
  and no device 2. `USE_I2S` stays undefined.
- `Components/YM2149` is vendored unmodified, but its `BHG_jt49_exp.sv` is
  not compiled: Quartus 17.0 rejects the way its `BHG_jt49_exp_lut.vh`
  builds the table. `Components/PSG/BHG_jt49_exp_q17.sv` (same module,
  generated by `tools/gen_bhg_lut.py` from that `.vh`, identical tables)
  replaces it in `MrZ80.qsf` and in the simulation lane.
- Verification: `make -C sim psg` (Verilator, about 25 s) checks the ports,
  readback, read masks, deselection, the sequencer in all modes, silence
  from reset, and tone pitch and panning on both chips. The GHDL lanes use
  `sim/MrZ80_PSG_stub.vhd`, an absent device.

### Front-panel subsystem register map (within the `0xA0`-`0xA7` window)

Decoded by the `FrontPanel_Subsystem` block from `addr(2 downto 0)`
relative to `io_cs`. Offsets are shown against the current base of
`0xA0`; if the window is relocated later, software access addresses
shift accordingly.

| Port  | R/W | Function                                                                                  |
|-------|-----|-------------------------------------------------------------------------------------------|
| `0xA0`| R/W | Global brightness (0..255, "scale8" style: 0xFF ~= full brightness, 0x00 = fully off). Applied to every channel of the selected colour -- see `Components/FRONTPANEL/README.md`. |
| `0xA1`| R/W | Map high: write sets map bits 9:8 for later `0xA5` writes (chain longer than 256 bits); read returns map bits 9:8 of the entry at the global pointer (read before `0xA5`). Replaces the former inert fade-rate register -- see `Components/FRONTPANEL/README.md`. |
| `0xA2`| R/W | Global pointer (LED index used by `0xA3`, `0xA5`, `0xA6`). Auto-advance on `0xA3`/`0xA5`/`0xA6` wraps at `NUM_LEDS` back to 0. |
| `0xA3`| W   | Colour stream, R,G,B order (not the LEDs' native GRB -- reordered internally, hidden from software). Six bytes per LED: on-R, on-G, on-B, off-R, off-G, off-B. The sixth byte auto-advances the global pointer.|
| `0xA4`| R/W | Mode register. Bit 0: 0 = mirror capture chain, 1 = framebuffer.                          |
| `0xA5`| R/W | Mapping-table entry at the global pointer. Both reads and writes auto-advance the pointer.|
| `0xA6`| R/W | Framebuffer bit at the global pointer. Both reads and writes auto-advance the pointer.    |
| `0xA7`| R/W | Active profile number (low 3 bits, 0 at reset). Selects the profile whose map/colours `0xA3`/`0xA5` access and that drives the LEDs (latched per refresh frame). The OSD item "Front Panel Profile" can override the displayed profile without affecting this register. See `Components/FRONTPANEL/README.md`. |


## System Support Processor (SSP) monitor

An embedded RISC-V core (FemtoRV32) running Mecrisp-Quintus Forth gives the
machine a debug console.  It claims **no Z80 I/O ports** today: it reaches the
Z80 side only through the CPU's bus-request path (parking the T80 on an
instruction boundary) and, for physical memory, by borrowing the SDRAM client
wiring while the Z80 is parked.  With the OSD **SSP Monitor** item off it is
electrically transparent.  Reserved for later: `0xD0`-`0xD3` (mailbox) and
`0xFC`-`0xFF` sense switches (panel phase P2).

* **Entry from the OSD:** **Enter SSP Monitor** parks the Z80 and enters the
  monitor without needing **SSP Serial Escape**; **SSP Console** chooses where:
  *Serial*, or *Video* -- the monitor's own 80x25 terminal (green text), which
  replaces the Z80's screen on HDMI/VGA and takes the keyboard until `G`
  resumes the Z80.  The Z80's terminal is untouched (screen, cursor, unread
  keys), and with the monitor on video the serial port stays the Z80's.
* **Entry:** the escape character (`^]` by default; OSD **SSP Serial Escape**
  on) typed on the active serial port parks the Z80 and hands that serial
  console to the monitor (whatever **SSP Console** says).  `G` hands it back.
* **Commands:** `E`/`D` examine/deposit, `R` registers, `G [aaaa]` go/continue,
  `I`/`O` Z80 I/O ports, `MAP` MMU frames, `S [n]` single-step (interrupts held
  off during the sequence), `U [aaaa [n]]` unassemble, `PHY`/`LOG` address mode, `F` raw Forth, `?` help.
* **Addressing:** logical (the Z80's MMU-translated 64 KB view, the default) or,
  after `PHY`, **physical**: up to 7 hex digits covering the SDRAM window
  `0x0000000`-`0x7FFFFFF`, bypassing the MMU.  The block-RAM page (physical
  `0x8000000`) is not reachable in physical mode (rejected with `?`); use the
  logical view for it.  Physical access works only while the Z80 is parked.
* **Reference:** user tour `doc/OVERVIEW.md` §6; design `doc/SSP_DESIGN.md`;
  live state `doc/SSP_STATUS.md`; register map `doc/SSP_REGS.md`.

## Custom CPU instructions

The T80 Z-80 core (`Components/Z80/T80_MCode.vhd`, `T80.vhd`) implements
the following non-standard instructions, all in previously undefined slots
of the `ED`-prefixed page.  On a stock Z-80 (and on earlier versions of this
core) these opcodes execute as 2-byte NOPs.  None of them affect the flags.

| Mnemonic    | Encoding | Operation                                              | T-states | Replaces (stock Z-80)                                   |
|-------------|----------|--------------------------------------------------------|---------:|---------------------------------------------------------|
| `F_NEXT`    | `ED 92`  | `PC <- (DE)`, `DE <- DE + 2`                           | 14 | `ex de,hl` / `ld e,(hl)` / `inc hl` / `ld d,(hl)` / `inc hl` / `ex de,hl` / `jp (hl)` (38 T, 7 bytes) |
| `PUSHIX BC` | `ED C5`  | `(IX-1) <- B`, `(IX-2) <- C`, `IX <- IX - 2`           | 14 | `dec ix` / `ld (ix+0),b` / `dec ix` / `ld (ix+0),c` (58 T, 10 bytes) |
| `PUSHIX DE` | `ED D5`  | `(IX-1) <- D`, `(IX-2) <- E`, `IX <- IX - 2`           | 14 | as above, with `d` / `e`                                |
| `PUSHIX HL` | `ED E5`  | `(IX-1) <- H`, `(IX-2) <- L`, `IX <- IX - 2`           | 14 | as above, with `h` / `l`                                |
| `POPIX BC`  | `ED C1`  | `C <- (IX)`, `B <- (IX+1)`, `IX <- IX + 2`             | 14 | `ld c,(ix+0)` / `inc ix` / `ld b,(ix+0)` / `inc ix` (58 T, 10 bytes) |
| `POPIX DE`  | `ED D1`  | `E <- (IX)`, `D <- (IX+1)`, `IX <- IX + 2`             | 14 | as above, with `e` / `d`                                |
| `POPIX HL`  | `ED E1`  | `L <- (IX)`, `H <- (IX+1)`, `IX <- IX + 2`             | 14 | as above, with `l` / `h`                                |

Notes:

- All instructions are 2 bytes long.  `ED F5` / `ED F1` (the `AF` positions
  in the `PUSH`/`POP` encoding pattern) are **not** implemented and remain
  NOPs.
- `PUSHIX`/`POPIX` treat `IX` as a stack pointer for a stack that grows
  downward, with `IX` pointing at the low byte of the top item — the layout
  CamelFORTH uses for its return stack.  The register pair is taken from the
  currently selected (`EXX`) register bank; `IX` itself is not banked.
- No assembler supports these mnemonics; emit them with `DB`.  CamelFORTH
  (`forth/camel80.azm`) wraps them in macros selected by build defines:
  `CUSTNEXT` (`next`) and `CUSTRSP` (`rpushbc`/`rpushde`/`rpushhl`,
  `rpopbc`/`rpopde`/`rpophl`).  Without the defines the macros expand to the
  equivalent stock Z-80 sequences.
- Kernels built with either define check at startup that the CPU implements
  the instructions, and print an error and halt (standalone) or exit
  (CP/M) if it does not.
- Design notes, cycle-level comparison and verification:
  `HISTORY.md` and `doc/custom-forth-instructions.md`.

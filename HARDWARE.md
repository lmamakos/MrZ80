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
file (`FC5`; goes to `FrontPanel_Subsystem`, never to SDRAM).

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
   Front Panel Profiles). The file is streamed in immediately. The HPS also
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

### "Sticky" `FC` selections and how to clear one

The `C` in `FC1`, `FC2`, `FC5` means the HPS stores the chosen file name per
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
| **Hard reset** | Framework `RESET` from the HPS, or the user button (`buttons[1]`); rising edge | Reset | **Cleared**: the image is discarded and the CPU is held in reset | **Not reloaded.** You must pick the Boot Rom Image in the OSD again. The front-panel profile (`.FPP`) is also cleared |
| **OSD Reset** | OSD item *Reset* (`R0`, `status[0]`) | Reset while asserted | **Kept**: the loaded image is restarted from `0x0000`. SDRAM is not re-initialised, so the image is intact | None |
| **Reset after Mount** | OSD option *Reset after Mount = Yes*, then mounting an `*.IMG` | Reset for 65536 `clk_sys` cycles | Kept (image restarted) | None. The SDRAM controller is re-initialised in this case, like a hard reset; the image bytes are not rewritten and a hardware check that they survive has not been done |
| **Manual file load** | You pick a file in the OSD | Reset during the download and for a short stretch after | `.BIN` sets it, `.DSK`/`.FPP` leave it unchanged | The picked file only |
| **Post-download restart** | Automatic, end of any download | Reset for 65536 `clk_sys` cycles | Unchanged (a `.BIN` sets it) | None |

Rules of thumb:

- **OSD Reset restarts the software; hard reset removes it.** Use OSD Reset
  to restart a loaded image, and re-select the Boot Rom Image after a hard reset
  (or after a core reload with no saved Boot Rom Image).
- The SDRAM controller is initialised at power-up and on a hard reset /
  user button / mount reset, but never by OSD Reset or while a download is in
  progress (that would stall the HPS in the middle of a transfer).
- Because there is no ROM, any Z-80 write to port `0x38` (the old ROM-disable
  trigger) is ignored.

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
| `0x70`-`0x71` | 2     | DS12887 real-time clock (`n_rtcCS`, `Components/RTC/ds12887.vhd`). AT-style index/data pair: `0x70` = register index, `0x71` = selected register. See below. |
| `0x80`-`0x81` | 2     | SBCTextDisplayRGB (`n_interface1CS`). VGA/PS-2 text display.                                              |
| `0x82`-`0x83` | 2     | bufferedUART (`n_interface2CS`). Serial console.                                                          |
| `0x88`-`0x8F` | 8     | SPI SD card controller (`n_sdCardCS`, `sd_controller.vhd`). Talks only to the physical SD socket. Register offset via `cpuAddress(2 downto 0)`. See SD storage below. |
| `0x90`-`0x97` | 8     | HPS image block device (`n_blockDevCS`, `Components/SDCARD/hps_blockdev.vhd`). Same register layout as the SD controller plus image-size registers; storage is an image file on the MiSTer Linux side, mounted from the OSD. See SD storage below. |
| `0xA0`-`0xA7` | 8     | Front-panel subsystem control window (`n_fpSubsysCS`). See Front-panel I/O register map below.            |
| `0xB0`-`0xBF` | 16    | MMU register window (`n_mmuCS`). 4 frame-mapping low bytes at `+0..+3` (Z2-compatible), 4 high bytes at `+4..+7`, direct-access pointer at `+8..+11` (little-endian), direct-access data port at `+12`. |
| `0xC0`-`0xCF` | 16    | Benchmark timers (`n_timerCS`, `BenchTimer`). Four 32-bit snapshot channels: ch0/ch1 1 ms/tick, ch2/ch3 1 µs/tick. See below. |
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

Other build macros that exist but are not SD socket settings: `SDRAM_CLK_100` in
`MrZ80.sv` (selects the PLL output that clocks the SDRAM controller). The
framework macro `MISTER_DUAL_SDRAM` is not defined; if it were, `sys/sys_top.v`
would use a different SD wiring (`SD_SPI_*` pins only, MCP23009 card-detect
required) and the options above would not apply.

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
emulate the programming interface of an 6850 ACIA device.

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
| nCTS   | active low CTS signal, tied low (active) |
| nDCD   | active low DCD signal, tied low (active) |
| TXDONE | Ready to send more characters to display |
| RXRDY  | Input character from keyboard ready      |

##### Keyboard Input

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
| `83`       | Read: Keyboard input character, Write: Display terminal emulator |

##### Status register 
|  7   |  6 |  5  |  4  |  3  |  2  |  1  |  0  |
|-----------------------------------------------|
| nInt |  -  |  -  |  -  | nCTS | nDCD | TXDONE | RXRDY |

##### Status Register Signal Descriptions

| Signal | Description                              |
|--------|------------------------------------------|
| nInt   | active low Interrupt - interrupt pending if interrupts enabled. |
| nCTS   | active low CTS signal, tied low (active) |
| nDCD   | active low DCD signal, tied low (active) |
| TXDONE | Ready to send more characters to display |
| RXRDY  | Input character from keyboard ready      |

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
  (the Z-80 `/INT` input is tied inactive); software must poll Register C.
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

### Front-panel subsystem register map (within the `0xA0`-`0xA7` window)

Decoded by the `FrontPanel_Subsystem` block from `addr(2 downto 0)`
relative to `io_cs`. Offsets are shown against the current base of
`0xA0`; if the window is relocated later, software access addresses
shift accordingly.

| Port  | R/W | Function                                                                                  |
|-------|-----|-------------------------------------------------------------------------------------------|
| `0xA0`| R/W | Global brightness (0..255, "scale8" style: 0xFF ~= full brightness, 0x00 = fully off). Applied to every channel of the selected colour -- see `Components/FRONTPANEL/README.md`. |
| `0xA1`| R/W | Fade rate (step per refresh tick). Stored/readable but currently has no effect (fade-ramp math removed for bring-up — see `Components/FRONTPANEL/README.md`). |
| `0xA2`| R/W | Global pointer (LED index used by `0xA3`, `0xA5`, `0xA6`). Auto-advance on `0xA3`/`0xA5`/`0xA6` wraps at `NUM_LEDS` back to 0. |
| `0xA3`| W   | Colour stream, R,G,B order (not the LEDs' native GRB -- reordered internally, hidden from software). Six bytes per LED: on-R, on-G, on-B, off-R, off-G, off-B. The sixth byte auto-advances the global pointer.|
| `0xA4`| R/W | Mode register. Bit 0: 0 = mirror capture chain, 1 = framebuffer.                          |
| `0xA5`| R/W | Mapping-table entry at the global pointer. Both reads and writes auto-advance the pointer.|
| `0xA6`| R/W | Framebuffer bit at the global pointer. Both reads and writes auto-advance the pointer.    |
| `0xA7`| R/W | Active profile number (low 3 bits, 0 at reset). Selects the profile whose map/colours `0xA3`/`0xA5` access and that drives the LEDs (latched per refresh frame). The OSD item "Front Panel Profile" can override the displayed profile without affecting this register. See `Components/FRONTPANEL/README.md`. |


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
  `HISTORY.md` and `blog-custom-instructions.md`.

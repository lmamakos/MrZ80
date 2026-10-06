# Feature and capability Requirements

## Background

The existing repository starts as a port of Grant Searle's "MultiComp"
project, with multiple 8 bit CPUs (Z-80, 6800, 6502, 6809) that was ported
to run on the MiSTer FPGA game emulator platform.  The MiSTer project is
based on a Cyclone V FPGA with added SDRAM memory.

The overall goal of this project to host the RomWBW Z-80/Z-180 software
platform that includes CP/M 2.2, CP/M 3.0, and related 8 bit operating
systems to run on the MiSTer hardware.   The work here started with
modifying the MiSTer HDL code to be suitable for RomWBW.  There will also
be work done at a later time to add or modify the HBIOS in RomWBW to target
the Z-80 computer system and peripherals implemented in the FPGA.

## Features and Requirements

### MMU changes

Modify the MMU VHDL (in `Components/alancox/MMU.vhd`) to implement 4 x 16
KByte pages, rather than the 16 x 4K pages that are in that module.
Initially the MMU shall handle 4 MBytes of physical address space, which
makes each of the 4 mapping registers 8 bits wide (8 bit page-number
extension + 14 bits of in-page logical address = 22 bits of physical
address, with the upper 2 bits of the CPU logical address selecting one of
the 4 mapping registers).

The MMU's mapping-register I/O interface shall be compatible with the
"Z2" MMU commonly used by RomWBW systems: the 4 mapping registers shall
appear as 4 consecutive 8-bit I/O ports that directly back the registers,
with no selector mux. These 4 ports shall sit at the start of the MMU's
decoded I/O window, aligned on a multiple-of-4 boundary.

The MMU shall also expose 4 additional I/O ports immediately following
the Z2-compatible ports, which can be used to write the *next* 8 bits of
each mapping register should the physical address space later be widened
beyond 4 MBytes. The width of the mapping registers (and therefore of the
physical address bus) shall be parameterizable so this widening can be
opted into without further source edits to the MMU. When the parameter is
set to the default value (8-bit mapping registers / 4 MBytes physical),
these extension ports shall read as 0 and ignore writes.

Per-frame read/write/execute permission bits are not required and shall be
removed.

The MMU shall retain a "direct access" capability (previously called the
"17th page" in the socz80 source) that allows code to read or write
physical memory directly through an I/O port without remapping any of the
4 logical pages. This is useful for copying data between banks without
disturbing the current mapping. The direct-access mechanism shall consist
of:

- A pointer register sized to match the physical address bus, programmed
  through dedicated I/O ports (little-endian: low byte at the lowest
  offset).
- A separate I/O port whose read or write the MMU rewrites into a physical
  memory read or write at the pointer address.
- Automatic post-increment of the pointer after each access, so block I/O
  instructions can walk forward through physical memory.

All MMU I/O port decoding shall be relative to an external chip-select
signal (`io_cs`), so the placement of the MMU's I/O window within the Z80
I/O address space is decided by the external decoder rather than baked
into the MMU.

### Implement MMU

We need to implement the MMU in the system design, rather than directly
accessing memory.

### Z-80 custom FORTH `NEXT` instruction

To support the CamelFORTH implementation distributed with RomWBW, add a
custom Z-80 instruction that implements the FORTH direct-threaded `NEXT`
inner-interpreter primitive in a single opcode, replacing the 7-byte
inline macro emitted at the end of every CamelFORTH CODE word. The goal is
to shrink the FORTH dictionary and speed up inner-interpreter dispatch.

The instruction shall use the Z-80 register conventions of CamelFORTH:

- `BC` = TOS (top parameter-stack item)
- `HL` = W (volatile working register)
- `DE` = IP (interpreter pointer)
- `SP` = PSP, `IX` = RSP, `IY` = UP

It shall be encoded in the `0xED` ("Misc. Instructions") prefix space at
opcode **`ED 92`** (`0x92` / `10010010`), a previously-undefined slot in
the ED page.  Its operation:

```
PC <- (DE)          ; load the 16-bit cell at (IP) into the PC
DE <- DE + 2        ; advance the interpreter pointer
```

i.e. read the 16-bit cell `W` from memory at `(IP)`, advance `IP` by 2, and
jump (`PC := W`).  Flags are untouched and `HL` is left alone: in this
implementation `HL` is a volatile working register, so `NEXT` has no
obligation to leave anything useful in it (unlike the stock macro, which
shuttles the cell through `HL` because `JP (HL)` is the Z80's only
indirect jump).  See the progress entry "Z-80 custom FORTH `NEXT`
instruction (`ED 92`) — implemented, working" for the final implementation.

### Implement SDRAM

Use the 128 Mbytes of SDRAM (XSDS dual-AS4C32M16SB module, two 64 MB
parts wired in parallel on a shared bus with the second physical chip
select derived from board-side logic) for additional Z-80 system memory
beyond the existing 64 KB of FPGA block RAM.

Initial physical memory layout target:

| Physical address | Contents |
|---|---|
| `0x0000_0000 – 0x0000_FFFF` | Existing 64 KB FPGA block RAM (unchanged) |
| `0x0001_0000 – 0x07FF_FFFF` | 128 MB SDRAM (minus the bottom 64 KB which is shadowed by block RAM) |

This lets the system continue booting from the proven block-RAM image
while exposing SDRAM for testing. The MMU will eventually be inserted
between the Z-80 and this layout; until it is, the SDRAM controller runs
idle (no client) so that init/refresh of the parts can be verified
independently.


### Loadable Boot ROM and RAM disk images from the MiSTer OSD

We want the user to be able to specify two types of files in the MiSTer OSD
interface.

1. A binary files (with a `.BIN` extension) that will be loaded into
SDRAM memory, starting at physical address 0x0000.  This file can be
as long as 512KB.  This would replace the 8KB ROM image that overlays
the bottom of the address space, and when this file is loaded, the ROM
should be disabled and the 64KB of block RAM should also be disabled.
When this file is loaded, it is essentially the "Boot" image that's
started when the Z-80 CPU comes out of reset and starts executing at
address 0x0000.

2. One or more "RAM Disk" images, which would be 8MB in length and be
accessed as a memory/RAM disk device by RomWBW.  Minimally, we should
support one of these images, and it would be loaded (by default) in
the top 8MB of the 128MB SDRAM address space.  It should be possible
to easily extend this implementation to load additiona 8MB RAM disk
images at other starting addresses.  These RAM disk images would have
the file extension `.DSK` in their names.

Having this capability means that software upgrades no long require
regenerating an FPGA core with, e.g., updated boot monitor, etc.

The anticipated uses of this "boot ROM" capability are:

- load RomWBW 
- load the existing 8KB boot ROM that's part of the FPGA core so far.
- build alternative Boot ROMs and easily test and use them
- boot a standalone FORTH-based monitor capability

The 8MB RAM Disk file image would be used by RomWBW after it is loaded
and started.

This feature should use the MiSTer configuration string to specify the
options to load the Boot ROM and RAM disk images.

### Integrated Camel FORTH

A more powerful tool than BASIC is required for further testing of the
HDL changes, and more generally, Z-80 "monitor program" than can be
booted.  We are going to integrate Camel FORTH into the system, which
is present in the `forth` top-level directory.  This will enable
interactive testing.

The intent is to take advantage of the "ROM Boot" capability that was
recently added to the project, which can preload memory starting at
logical address 0x0000.  This will be used for a variety of purposes,
eventually intended to load and start RomWBW.  It can also be used to
load a FORTH interpreter as an alternative to the Basic / CP/M Boot
ROM that is built into the FPGA image.  Loading this from the ARM
processor's file system will enable easy updates of the code without
having to rebuild the FPGA image.

The FORTH interpreter presently runs.  The next feature to complete in
Camel FORTH is to give it access to the 8 MB "RAM Disk" that can be
preloaded from a specified file from the MiSTer OSD.  This image will
contain FORTH blocks with addtional FORTH word definitions than can
be used to extend the base interpreter.

## Progress

### MMU rework (`Components/alancox/MMU.vhd`) — design complete, GHDL-verified,

The MMU source file has been rewritten in place to match the requirements
above. GHDL (`ghdl -a --std=08`) accepts the file with no errors.
Elaboration of the entity also passes. The file is not yet referenced from
either Quartus revision (no `.qsf` entries) and is not yet instantiated
anywhere in the system, so the build is unaffected by the change.

What the file now provides:

- **Page geometry**: 4 logical pages of 16 KB each. Top 2 bits of the
  16-bit CPU address select a mapping register; low 14 bits are the
  in-page offset.
- **Parameterizable physical address width**: VHDL generic
  `physical_page_bits` (default 8). With the default, the physical address
  bus (`address_out`) is 22 bits wide (4 MB). Larger values widen the bus
  and enable the extension I/O ports.
- **I/O register window** — 16 consecutive ports, decoded relative to
  `io_cs` on the low 4 address bits:

  | Offset | Function |
  |---|---|
  | +0..+3 | Frame 0..3 mapping register, bits 7:0 (Z2-compatible) |
  | +4..+7 | Frame 0..3 mapping register, bits 15:8 (extension; reads 0 / ignores writes when `physical_page_bits = 8`) |
  | +8..+11 | Direct-access pointer bytes, little-endian (low byte at +8) |
  | +12 | Direct-access data port (R/W triggers a physical memory cycle at the pointer; pointer post-increments after the access) |
  | +13..+15 | Reserved (reads 0, writes ignored) |

- **Direct-access window**: retained. Mechanism (address rewrite,
  `req_mem_out` forced high, `req_io_out` forced low, one-cycle `cpu_wait`
  pulse, pointer post-increment) is unchanged from the original socz80
  design, just relocated to port offset +12 and renamed.
- **Permissions removed**: the `can_read`/`can_write` record fields and
  the `access_violated` output port have been deleted.
- **Selector mux removed**: the old "write to port +0 to choose what
  ports +3..+7 mean" mechanism is gone; each register has its own port.
- **Reset map**: placeholder identity map (frame K -> physical page K for
  K = 0..3, direct-access pointer = 0). Marked in source as TODO to be
  revisited once the physical ROM/SDRAM layout is decided.

### SDRAM controller (`Components/SDRAM/sdram.sv` + `sdram_z80.sv`) — in the build, currently idle

The 128 MB dual-chip SDRAM controller from the MiSTer N64 core
(`MiSTer-devel/N64_MiSTer rtl/sdram.sv`, GPLv3, Sorgelig) has been adopted
verbatim as `Components/SDRAM/sdram.sv`. The pre-existing 32 MB controllers
that shipped in `Components/SDRAM/` (a single-port `sdram.sv` and a
multi-port `sdram.v`) are no longer suitable for the 128 MB module and
have been replaced/removed.

Key behaviour of the adopted controller:

- 27-bit byte address per channel, covering the full 128 MB.
- Drives the single FPGA `SDRAM_nCS` from an internal `chip` register;
  the XSDS board derives the two physical device chip-selects from that
  line plus board-side routing. The controller selects device 0 vs 1 by
  copying the top address bit (`chN_addr[26]`) into `chip` for each
  ACTIVE/READ/WRITE, and walks `chip` 0 -> 1 during init and refresh so
  both devices are configured and refreshed.
- Three channels: ch1 (32-bit + byte enables), ch2 (32-bit), ch3 (16-bit).

A thin 8-bit wrapper, `Components/SDRAM/sdram_z80.sv`, exposes a simple
`addr/din/dout/we/rd/ready` interface and uses the controller's ch1
channel (the only one with proper per-byte enables, allowing clean 8-bit
writes). ch2 and ch3 are tied off. The wrapper also drives `SDRAM_CLK`
via `altddio_out` since the controller intentionally leaves that to the
integrator.

The wrapper is instantiated in `MultiComp.sv` (replacing the previous
`assign {SDRAM_*} = 'Z;` tri-state at line 225). For this phase the
client side of the wrapper is held idle (`we = rd = 0`); the SDRAM is
therefore initialized and refreshed but not yet read or written by the
Z-80. The Z-80 still boots from the existing 64 KB FPGA block RAM as
before.

`MultiComp.qsf` has been updated with `SYSTEMVERILOG_FILE` entries for
the two new files. The SDRAM controller
runs from the existing `clk_sys` (50 MHz from `rtl/pll.v`); the
AS4C32M16SB timing constants in the controller comfortably hold at this
frequency, so PLL regeneration is not required for first bring-up.

### Front-panel LED subsystem (`Components/FRONTPANEL/`) — wired into the CPM core for initial bring-up

The WS2812/SK6812-based blinkenlights front panel has been added to the
build of the Z-80 CPM core. Files are referenced from `MultiComp.qsf`;
the subsystem and capture chain are instantiated in
`MicrocomputerZ80CPM.vhd`.

Initial configuration:

- **I/O port 0x47** (`n_fpLatchCS`): 8-bit R/W latch. Software writes
  set the bit pattern displayed on the front panel; reads return the
  last-written value.
- **I/O ports 0xA0..0xA7** (`n_fpSubsysCS`): the `FrontPanel_Subsystem`
  8-port control window (brightness, fade rate, pointer, colour stream,
  mode, mapping table, framebuffer, reserved).
- **`Transparent_Capture_Chain` (8 bits wide)**: sources its
  `combined_data` from the port 0x47 latch and delivers it on the
  serial chain into `FrontPanel_Subsystem`.
- **NUM_LEDS = 16** for first bring-up. The default identity mapping
  (mapping.mif) maps LED i to chain bit i; with an 8-bit chain only
  LEDs 0..7 mirror the port-0x47 latch, while LEDs 8..15 mirror chain
  bit positions that have not been written and therefore stay at
  reset value (0 = off colour). Software can rewrite the mapping
  table at runtime to point any LED at any chain bit.
- **Refresh tick** generated locally at ~60 Hz from `clk` (50 MHz /
  833_333).
- **Physical output**: `MultiComp.sv` routes the WS2812 serial line
  through `USER_OUT[4]` of the MiSTer USER_IO port. The Basic core's
  matching pin is tied to `'0'` (no front panel in Basic mode for
  now); the existing cpu_type mux selects which core's signal reaches
  the pin.


### SDRAM controller: ported CoCo3 `sdram_32r8w` (`Components/SDRAM/sdram2.sv`)

We ported the SDRAM controller from the MiSTer **CoCo3** core
(`MiSTer-devel/CoCo3_MiSTer rtl/sdram/sdram2.sv`, module `sdram_32r8w`,
© Sorgelig / Stan Hodge), imported verbatim as
`Components/SDRAM/sdram2.sv`. It is written for **exactly** our board
(`Alliance AS4C32M16SB-7TIN (x2)`, 128 MB) and fixes byte writes with
a different, robust technique:

```verilog
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11]; // A12/A11 unused -> free for DQM
...
// fix byte writes [no new command until data is actually written]
if (~sdram_cpu_rnw)
  {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <=
    {~sdram_cpu_addr[0], sdram_cpu_addr[0], 2'b10, sdram_cpu_addr[24:1]};
```

The DQM lanes are driven from the upper address-register bits, loaded
in the same register write as the column address. This guarantees the
mask is cycle-aligned with CAS. For `addr[0]=0` (even/low byte):
`{DQMH,DQML} = {1,0}` (write low, mask high); for `addr[0]=1`:
`{0,1}` (write high, mask low).

**Clock.** This controller runs at ~112 MHz (CAS_LATENCY=3, startup
timing assumes ~100 MHz), while the Z-80 CPM core's SDRAM client FSM
runs at 50 MHz (`clk_sys`). The controller derives the inverted
SDRAM chip clock internally via its own `altddio_out`, so only **one**
extra ~112 MHz clock (`clk_ram`) is needed.

> **PLL REGENERATION REQUIRED.** The current PLL (`rtl/pll.qip` →
> `rtl/pll/pll_0002.v`) only generates `outclk_0 = 50 MHz`
> (`number_of_clocks = 1`). It must be regenerated in MegaWizard to also
> expose `outclk_1 ≈ 112 MHz`. `MultiComp.sv` references `pll`'s
> `.outclk_1(clk_ram_112)`. The saved PLL parameter set in `rtl/pll.qip`
> already contains an `outclk_1 = 112 MHz` definition, so the
> multiply/divide is known-good. Per AGENTS.md, PLLs are generated IP and
> must be regenerated via MegaWizard rather than hand-edited.
> `derive_pll_clocks` in `sys/sys_top.sdc` will pick up the new clock
> automatically, and the existing clock-group constraint already covers
> `*|pll|pll_inst|...|divclk`.
>
> **What MegaWizard rewrites:** only files under `rtl/pll*` — `rtl/pll.v`
> (gains the `outclk_1` port), `rtl/pll.qip`/`.cmp`/`.ppf`/`.sip`/`.spd`,
> and `rtl/pll/pll_0002.*`. It does **not** modify `MultiComp.qsf` or
> `MultiComp.qpf`; the design references the PLL through the single
> `QIP_FILE rtl/pll.qip` line in `MultiComp.qsf`, which is unchanged.
>
> **100 MHz fallback.** If 112 MHz fails timing closure on the SDRAM
> paths, build with the `SDRAM_CLK_100` Verilog define (uncomment the
> `` `define SDRAM_CLK_100 `` line in `MultiComp.sv`'s CLOCKS section). In
> that configuration `clk_ram` is driven by `outclk_2 ≈ 100 MHz`, and the
> PLL must be regenerated with **three** outputs (`outclk_0` = 50,
> `outclk_1` = 112, `outclk_2` = 100). With the define OFF (default) only
> two outputs (`outclk_0`, `outclk_1`) are required. The CoCo3
> `sdram_32r8w` controller is unchanged for either frequency: its refresh
> interval constant (890 cycles, tuned for ~114 MHz) merely refreshes
> slightly more often than necessary at 100 MHz, which is harmless. As an
> even simpler alternative, you may instead set `outclk_1` itself to
> 100 MHz and leave the define OFF — no third tap needed.

**Clock-domain crossing (in `MultiComp.sv`).** The CPM FSM asserts
`we`/`rd` and holds it stable until it sees `ready`. The adapter:
1. 2-FF-synchronizes the held request level (`we|rd`) into `clk_ram`.
2. On its rising edge, latches addr/din/direction and raises `ram_req`
   to the controller; holds `ram_req` until `sdram_cpu_ack`, then drops
   it (the controller's STATE_IDLE accepts only while `req & !ack`).
3. On `sdram_cpu_ready`, byte-selects `sdram_dout16` by `addr[0]` into
   `ram_byte` and toggles a `ram_done` completion level.
4. 2-FF-synchronizes `ram_done` back into `clk_sys` and edge-detects it
   to produce the single-cycle `sdram_ready_mux` pulse the CPM FSM
   expects. `sdram_dout_mux = ram_byte`.
Because the request level is held stable for the whole transaction,
simple 2-FF synchronizers are sufficient; the read data is stable
before the completion flag crosses domains.

**Address mapping (full 128 MB).** The controller now takes the full
27-bit byte address and reaches the entire 128 MB module. The XSDS board
carries two AS4C32M16SB devices on a single shared 16-bit bus; device 1's
chip-select is the inverted copy of device 0's, so the single `SDRAM_nCS`
pin selects between them. (Note: `SDRAM2_*` in the MiSTer framework is a
separate physical expansion board, not the second device on this module.)
The 27-bit byte address decomposes as:

```
addr[26]    = chip   -> SDRAM_nCS (device 0 / 1)
addr[25:13] = row    (13 bits, 8192 rows)
addr[12:11] = bank   (2 bits, 4 banks)
addr[10:1]  = column (10 bits, 1024 columns)
addr[0]     = byte within the 16-bit word (DQM select)
```

Controller changes (`Components/SDRAM/sdram2.sv`, all marked `LOCAL MOD`):
- Address ports widened to `[26:0]`; the column/bank/row packing was
  rewritten from upstream's 24-bit (32 MB, wrong split) to the correct
  per-device decomposition above.
- `SDRAM_nCS` driven from a `chip` register loaded with `addr[26]` at
  command time (was hardcoded 0).
- **Two-pass init**: `STATE_STARTUP` runs the precharge/refresh/load-mode
  sequence once per device (driven by an `init_chip` bit) before entering
  `STATE_IDLE`.
- **Alternating refresh**: the refresh logic toggles `chip` each interval
  so both devices are refreshed. Because each device is then refreshed
  every *other* interval, `cycles_per_refresh` is halved to `14'd390`
  (`(64ms/8192 @ 100MHz)/2`) to keep each device within its 7.8 us row
  refresh period.

The CDC adapter in `MultiComp.sv` passes the full `sdram_addr_mux[26:0]`
(no truncation) into a 27-bit `ram_addr` and the controller's widened
`sdram_cpu_addr`. The video read port (`sdram_vid_*`) is tied off.

The 32 MB single-device configuration is preserved at git tag
`sdram-32mb-working` (commit `ff7a1a0`) as a rollback point.

`LED_USER` now follows `~sdram_busy` (lit when the controller is idle /
init complete). `sdram_simple.sv`, `sdram.sv`, and `sdram_z80.sv` remain
in the tree but are commented out of both `.qsf` files.

### MMU + SDRAM integration into the CPM core — done

The MMU has been instantiated inside `MicrocomputerZ80CPM.vhd` between
the Z-80 and the memory subsystem, and the SDRAM controller's client
side is now driven from that same core. Both Quartus revisions have
been updated.

Plumbing summary:

- **MMU instantiation**: `mmu1 : entity work.MMU` with
  `physical_page_bits => 8` (22-bit / 4 MB physical address space,
  Z2-compatible). Reset is `not N_RESET` (MMU is active-high).
- **I/O window**: 16 ports at **`0xB0..0xBF`** (`n_mmuCS`). Inverted
  to active-high `mmu_io_cs` for the MMU's `io_cs` input.
- **CPU bus**: active-low Z-80 strobes are inverted into the MMU's
  active-high `req_mem_in / req_io_in / req_read / req_write`.
- **Block RAM rewiring**: `InternalRam64K` is now addressed by
  `mmu_phys_addr(15 downto 0)` (physical) instead of `cpuAddress`
  (logical). Its chip select fires when `phys_in_blockram = '1'`
  (i.e. `phys_addr(21:16) = "000000"`), regardless of the boot-ROM
  overlay; writes through the ROM-overlay region still silently
  update the underlying block RAM.
- **Boot ROM overlay**: unchanged — `Z80_CPM_BASIC_ROM` continues to
  win on the `cpuDataIn` mux at logical `0x0000..0x1FFF` while
  `n_RomActive = '0'`, ahead of the physical-memory sources. The MMU
  is invisible until the ROM unmaps itself.
- **MMU read-back**: `mmu_dataOut` is selected on the `cpuDataIn` mux
  when `mmu_io_cs = '1'` **except** for port `+12` (the direct-access
  data port), where the cycle has been promoted to a physical memory
  access and the data must come from the block RAM / SDRAM path.
- **SDRAM client FSM**: a three-state machine (`S_IDLE`, `S_REQ`,
  `S_DONE`) in `MicrocomputerZ80CPM.vhd` issues `we`/`rd` to the
  SDRAM wrapper when the MMU's `req_mem_out = '1'` and
  `phys_in_sdram = '1'`. The Z-80 is stalled via `wait_n` from
  `S_REQ` until the controller pulses `ready`; `sdram_dout` is
  latched into `sdramReadData` for the `cpuDataIn` mux. The FSM
  returns to `S_IDLE` after the CPU releases `MREQ`.
- **`wait_n` to the t80s core**: `cpu_wait_n = (not mmu_cpu_wait) and
  sdram_wait_n`. The MMU asserts its one-cycle wait pulse on
  direct-access cycles to give synchronous memory a beat to respond;
  the FSM holds it for as many beats as the SDRAM controller needs.
- **Top-level wiring** (`MultiComp.sv`): six new ports on the CPM
  core (`sdram_addr`, `sdram_din`, `sdram_we`, `sdram_rd`,
  `sdram_dout`, `sdram_ready`) are fed through per-CPU arrays
  mirroring the `_fpLED_serial` pattern. The mux on `cpu_type` picks
  the active set; `we`/`rd` are additionally masked by
  `(cpu_type == cpuZ80CPM)` so selecting the Basic core leaves the
  SDRAM idle. The previously idle `sdram_z80_inst` is now driven by
  these muxed signals (the `27'd0` / `1'b0` tie-offs are gone).

Reset map (unchanged from the MMU's placeholder): frames 0..3 map
identically to physical pages 0..3. With block RAM covering physical
0x000000..0x00FFFF, this means the Z-80's first 64 KB of logical
address space sees the same block RAM it did before — boot and CP/M
behaviour are preserved. Remapping frame 3 to physical page 4 (or
higher) is the canonical way to reach into SDRAM.

### MMU widened to 13 bits (128 MB)

With the SDRAM data path proven on hardware, the MMU was widened from
`physical_page_bits = 8` (22-bit / 4 MB) to `physical_page_bits = 13`
(27-bit / 128 MB), covering the full XSDS module.

Changes (`MicrocomputerZ80CPM.vhd`):
- `mmu1` generic `physical_page_bits => 13`.
- `mmu_phys_addr` widened to `std_logic_vector(26 downto 0)` (27 bits).
- `sdram_addr <= mmu_phys_addr;` directly — no more zero-extension; the
  27-bit physical address now fills the controller's address port.
- Block-RAM decode tightened to `mmu_phys_addr(26 downto 16) =
  "00000000000"`, so high SDRAM pages cannot alias into the low-64 KB
  block RAM.

The MMU module itself needed no width edits — it is parameterised by the
generic. 8192 pages x 16 KB = 128 MB; pages 0..3 (physical
0x000000..0x00FFFF) remain block RAM, pages 4..8191 are SDRAM.

### Block RAM relocated above SDRAM + MMU widened to 14 bits (256 MB)

The 64 KB on-chip block RAM (`InternalRam64K`) used to occupy physical page
0 and shadow the bottom 64 KB of the 128 MB SDRAM, making that SDRAM
unreachable. It has been **relocated to its own physical page above the
SDRAM** so the full 128 MB of SDRAM is contiguously addressable with no
shadowing, and so the boot source is chosen purely by the MMU's default
mapping rather than by external "force block RAM on/off" control signals.

Note on terminology: the relocated component is the **64 KB read/write
block RAM**, not the 8 KB boot ROM (`Z80_CPM_BASIC_ROM`). The 8 KB ROM
overlay at logical `0x0000..0x1FFF` is unchanged.

Physical memory layout (28-bit / 256 MB space):

| Physical address | Contents |
|---|---|
| `0x0000000 – 0x7FFFFFF` | 128 MB SDRAM (pages 0..8191), now fully addressable |
| `0x8000000 – 0x800FFFF` | Relocated 64 KB block RAM (page 8192), just above SDRAM |
| `0x8010000 – 0xFFFFFFF` | Unmapped |

**MMU changes (`Components/alancox/MMU.vhd`):**
- New generic `block_ram_page` (default 8192): physical page of the
  relocated block RAM, used by the reset map.
- New input `bin_loaded`: selects the reset mapping of frame 0.
- **Reset map** is no longer identity. Frame 0 → `block_ram_page` (so the
  Z-80 boots from block RAM at logical `0x0000`) when `bin_loaded = '0'`,
  or → SDRAM physical page 0 when `bin_loaded = '1'` (a `.BIN` was loaded
  into SDRAM at physical `0x0000`). Frames 1..3 → SDRAM physical pages
  1..3 (logical `0x4000..0xFFFF` = SDRAM low memory).
- The module is still fully parameterised; the 4-byte direct-access pointer
  ports and `+4..+7` extension ports already guard against the wider
  register width, so no further width edits were needed. GHDL
  (`ghdl -a/-e --std=08`) analyzes and elaborates the widened MMU cleanly.

**Wrapper changes (`MicrocomputerZ80CPM.vhd`):**
- `mmu1` generics `physical_page_bits => 14, block_ram_page => 8192`
  (28-bit / 256 MB physical address space).
- `mmu_phys_addr` widened to `std_logic_vector(27 downto 0)` (28 bits).
- New **disjoint** physical decode: `phys_in_blockram` =
  `mmu_phys_addr(27 downto 16) = "100000000000"` (the 64 KB window at
  `0x8000000`); `phys_in_sdram` = `mmu_phys_addr(27) = '0'` (low 128 MB).
  The `bin_loaded`/`boot_to_blockram` terms were removed from
  `phys_in_blockram` — whether logical `0x0000` resolves to block RAM or
  SDRAM is now decided solely by the MMU's frame-0 mapping.
- `sdram_addr <= mmu_phys_addr(26 downto 0)` — SDRAM accesses always have
  bit 27 = 0, so the low 27 bits fully address the controller; the
  `MicrocomputerZ80CPM` `sdram_addr` port and the SDRAM controller stay
  27-bit/128 MB (unchanged).
- `mmu_bin_loaded <= bin_loaded and not boot_to_blockram`: the
  frame-0→SDRAM remap is suppressed in the block-RAM debug-boot path so
  frame 0 stays on the block RAM page (where the debug BIN was written).
- The block-RAM debug download path (`boot_to_blockram` / `dl_bram_*`) is
  retained as the known-good comparison path for SDRAM diagnostics.

The `MultiComp.sv` top level needed no port-width changes (the core's
`sdram_addr` port is still 27-bit); it only gained the SDRAM-boot fix
below.

### SDRAM boot-from-`.BIN` non-determinism — root cause and fix

**Symptom:** a `.BIN` booted from **block RAM** ran reliably, but the same
`.BIN` streamed into **SDRAM** booted non-deterministically — yet the
standalone Z-80 SDRAM memory test (`testing/sdramtest.asm`) passed both its
direct-access and MMU-paged phases. So the raw SDRAM array and both CPU
read/write paths are good; the fault was specific to the **OSD download
write path**, the one thing the memory test does not exercise.

**Root cause:** the imported `sdram_32r8w` controller
(`Components/SDRAM/sdram2.sv`) asserts its write completion
(`sdram_cpu_ready`, source of `sdram_ready_mux`) in `STATE_RW1` — the cycle
the `WRITE` command is issued — and only *then* walks `STATE_DLY1 →
STATE_DLY2 → STATE_IDLE`. "Ready" is therefore raised **before** the
write's auto-precharge / write-recovery (tWR/tRP) has elapsed and before
the controller can accept the next command. The Z-80 client never tripped
this because each CPU write is paced by a whole instruction, but the OSD
download FSM (`MultiComp.sv`) streams bytes back-to-back: it dropped
`dl_we` on `sdram_ready_mux` and re-raised it on the very next byte, so the
next `ACTIVE` could be launched before the previous write settled,
corrupting the loaded image.

**Fix (`MultiComp.sv` download FSM, low-risk — the imported controller is
left untouched):** after each streamed write completes, the FSM now holds
`dl_busy`/`ioctl_wait` for a short fixed **recovery cooldown**
(`DL_WR_COOLDOWN = 8` `clk_sys` cycles) before accepting the next byte.
At 50 MHz `clk_sys` vs ~100 MHz `clk_ram`, 8 cycles comfortably span the
controller's `DLY1/DLY2` + recovery window with margin, and they also
guarantee `dl_we` is low long enough for the `clk_ram` CDC edge-detector to
see two distinct write requests (closing a secondary back-to-back
edge-merge hazard). This keeps the CPU-paced client path — proven by the
memory test — unchanged.

**Diagnostic note (if boot still fails after this):** the next suspect is
the post-download `bin_loaded` / frame-0 switch-over. After a download the
top level pulses the CPU reset (`dl_reset_stretch`) while `bin_loaded`
latches; the MMU reset map reads `bin_loaded` (via `mmu_bin_loaded`) at the
reset edge, so frame 0 must already reflect the loaded BIN when reset
deasserts. To localize: have the block-RAM-resident memory test read back
the just-written SDRAM region via the direct-access port and compare — a
clean readback isolates the fault to the switch-over rather than the write
path.

### SDRAM *execution* test (`testing/sdramexec.asm`) — fetch-from-SDRAM diagnostic

After the relocation/widening and the download-FSM cooldown fix, a `.BIN`
still ran from **block RAM** but not from **SDRAM**, while the SDRAM
**memory** tests (`testing/sdramtest.asm`) continued to pass. The memory
tests only ever do **data** accesses (`LD (HL),A` / `LD A,(HL)`,
direct-access port) into a paged window while the test code itself keeps
running from block RAM. They never **fetch and execute instructions** out
of SDRAM — which is exactly what a boot image must do. `sdramexec.asm`
isolates that missing case.

It is built to a flat `.BIN` and loaded into **block RAM** (the known-good
path), then:

1. Maps SDRAM physical page 4 (physical `0x010000`) into **frame 1**
   (logical `0x4000..0x7FFF`) via `OUT (0xB1)` / `OUT (0xB5)`. Frame 1 is
   used so the test's own code (frames 0–2) and stack/scratch (frame 0)
   are undisturbed.
2. Copies a tiny self-contained subroutine into `0x4000` with `LDIR`
   (the proven data-write path).
3. Reads the copy back byte-for-byte and verifies it (data-path sanity —
   confirms the bytes really landed in SDRAM before trying to run them).
4. `CALL 0x4000` to **fetch and execute the routine straight out of
   SDRAM**, repeated `EXEC_RUNS` (16) times to catch intermittent /
   non-deterministic fetch failures. The routine sums a 5-byte table and
   adds a constant, returning a known value (`0xC3`); a correct return
   proves real multi-instruction fetch (including a `DJNZ` loop branch)
   from SDRAM, not a lucky single byte.

Each stage prints PASS/FAIL on the serial console.

**Position independence:** the Z-80 has no PC-relative `CALL`, so rather
than relocating the routine's self-references, the routine has *none*: its
only data (the sum table) lives at a **fixed block-RAM scratch address**
(`srctn_tab`, filled at runtime) that is identical whether the code runs
from block RAM or SDRAM. The copied body is just register ops, an
immediate-loaded pointer to that fixed table, a `DJNZ` loop, and `RET` —
all inherently relocatable.

**Interpreting the result:**
- *Copy+verify passes but EXECUTE fails (or is flaky)* → the fault is
  specifically in the **SDRAM instruction-fetch / wait-state path** (the
  `S_IDLE→S_REQ→S_DONE` SDRAM client FSM interacting with the Z-80 M1
  opcode-fetch cycle and `wait_n`), which is the same path a boot image
  depends on and the prime remaining suspect for the boot failure.
- *Both copy+verify and EXECUTE pass* → SDRAM fetch is sound, pushing the
  boot failure back toward the download write/handshake or the
  `bin_loaded`/frame-0 switch-over.

Build: `pasmo --bin testing/sdramexec.asm testing/sdramexec.bin` (≈1.8 KB
flat binary, entry at `0x0000`).

### Wait-line phase race: intermittent off-by-one on execute-from-SDRAM (RESOLVED)

> **Resolved** by the `S_DONE` wait-release phase guard — see "Session
> update — SDRAM reliability fixes" at the end of this file and
> `SDRAM-review-handoff.md`. The narrative below is kept for history.

**Symptom (after the S_GAP deadlock fix below).** `sdramexec.bin` loaded into
block RAM runs the routine out of SDRAM and *mostly* returns the correct
`0xC3`, but **intermittently** one run in ~16 returns `0xC4` (one too high),
e.g.:

```
EXECUTE from SDRAM: .....got=C4 ..........
RESULT: SDRAM EXECUTION FAILED (fetch path)
```

`0xC4 = 0xC3 + 1`: the routine's table sum came out `0x100` instead of
`0xFF` — i.e. exactly one instruction in the fetched-from-SDRAM routine
mis-executed on that run. The failure is non-deterministic (different run
each time), which points at a timing/CDC race rather than a logic error.

**Hypothesis (unconfirmed).** The SDRAM client FSM and the MMU run on the
fast 50 MHz `clk`, but the Z-80 (`t80s`) is clocked by `cpuClock` (a `clk/5`,
~10 MHz *derived clock*, not a clock-enable). The combined `cpu_wait_n` is
fed straight to the core, so the FSM can change it on the same `clk` edge
that is also a `cpuClock` edge, leaving little setup margin.

**ATTEMPTED FIX — REVERTED (regression).** A phase-aligned wait flop
(`cpu_wait_n_sync`) that applied stalls immediately but deferred wait
*releases* to the `cpuClock`-low phase was tried. On hardware it was a
**regression**: the CPU appeared to reset when loading/running
`sdramexec.bin`, and even the BASIC "ROM" no longer started. The change was
rolled back in full (`MicrocomputerZ80CPM.vhd` restored to feeding
`cpu_wait_n` directly to the core). **Do not re-apply that approach** without
understanding why it broke normal operation — most likely it interfered with
the MMU's own single-cycle `mmu_cpu_wait` handshake and/or the normal
(non-SDRAM) cycle timing the whole machine depends on, effectively stalling
or mis-timing every cycle, not just SDRAM ones.

This off-by-one remains **OPEN**. Next investigation should:
- Confirm the failing instruction with a targeted diagnostic (re-read the
  SDRAM bytes on mismatch; dump A/PC) before changing RTL.
- If it is the wait CDC, gate any phase-alignment to SDRAM cycles ONLY
  (`phys_in_sdram`), never touching MMU/normal-cycle wait behaviour, and
  prove it in simulation against a normal ROM/RAM cycle first.

### SDRAM client FSM: back-to-back request deadlock (root cause of the execute-from-SDRAM hang)

**Symptom.** With `sdramexec.bin` loaded into **block RAM** (frame 0 = block
RAM, the known-good boot path), the test prints `EXECUTE from SDRAM: ` and
then **hangs** — the `CALL 0x4000` into SDRAM never returns. No progress
dots, no `got=` value, no `RESULT:` verdict. Yet the preceding copy and
data-path **verify** of the very same SDRAM bytes pass.

**Root cause — a clock-domain-crossing deadlock on tightly spaced requests.**
The SDRAM request is handed from the 50 MHz `clk_sys` FSM to the 112 MHz
`clk_ram` controller through a level handshake in `MultiComp.sv`
(lines ~266-309): the request level `cpu_req_level = sdram_we_mux |
sdram_rd_mux` is passed through a 2-FF synchroniser (`req_sync`) and a new
transaction is launched **only on its rising edge** (`req_sync[1] &
~req_seen`). For that rising edge to be detectable, the request level must
first be observed **low** by the synchroniser between transactions.

A data-only test (`sdramtest.asm`, which copies with `LDIR`) always supplies
that low gap "for free": between any two SDRAM data accesses the CPU runs
many **non-SDRAM** cycles (opcode fetches and the source byte read, all from
block RAM), so `cpu_req_level` is low for a long time and the synchroniser
always re-arms.

**Instruction fetch from SDRAM removes the gap.** When code executes *out of*
SDRAM, consecutive M1 opcode fetches are back-to-back SDRAM reads with only a
short refresh phase between them. The old FSM dropped its strobe in `S_DONE`
and immediately allowed the next request from `S_IDLE`, so two successive
SDRAM accesses could merge into one **continuously-high** `cpu_req_level` as
seen by the 112 MHz synchroniser — it never observes the intervening low,
never detects a fresh rising edge, never launches the second transaction.
The controller therefore never pulses `ready`, the FSM is stuck in `S_REQ`,
`wait_n` stays low, and **the Z-80 hangs** mid-routine. This is exactly the
"runs fine from block RAM, hangs the instant it is CALLed in SDRAM" symptom,
and it is invisible to the data-only tests for the gap reason above.

**The fix — an explicit inter-request dead-time state (`S_GAP`).** A fourth
FSM state was added (`MicrocomputerZ80CPM.vhd`). After `S_DONE` (once the CPU
drops its read/write strobe) the FSM enters `S_GAP`, holding `sdram_we`/`rd`
**low** for a small counted number of `clk_sys` cycles (`sdram_gap_cnt`, 3
cycles) before returning to `S_IDLE` to accept the next request. Because
`clk_ram` (112 MHz) is ~2.24× `clk_sys` (50 MHz), 3 `clk_sys` cycles of
enforced low guarantee ≥2 `clk_ram` edges sample the request level low, so
the synchroniser re-arms and the next SDRAM access is always seen as a fresh
rising edge. The dead time is incurred only between SDRAM transactions and
does not affect non-SDRAM cycles.

State graph is now `S_IDLE → S_REQ → S_DONE → S_GAP → S_IDLE`.

### SDRAM client FSM hardened against the M1 opcode-fetch / refresh hazard

Investigation of the SDRAM **instruction-fetch** path (the one execution and
boot use but the data-only memory tests do not) also found a separate
structural hazard in the SDRAM client FSM (`MicrocomputerZ80CPM.vhd`) around
the Z-80 **M1 opcode fetch** (relevant specifically when frame 0 maps to
SDRAM, i.e. a `.BIN` booted directly into SDRAM).

**The hazard.** On an M1 fetch the T80 core asserts `MREQ` **twice** within
one machine cycle:
- **T2** — the data phase, with `RD` also asserted (the opcode read), and
- **T3** — the *refresh* phase, with `RD`/`WR` deasserted and the refresh
  address `I:R` driven on the bus (`Components/Z80/T80.vhd:411-415`,
  `T80s.vhd:163-165`).

With `I = 0` the refresh address `0x00:R` decodes to **frame 0**. When
frame 0 maps to **SDRAM** (the boot-from-`.BIN` case, where frame 0 = SDRAM
page 0), the refresh phase *also* decodes as SDRAM, so `mmu_req_mem_out`
stays continuously high from the T2 data phase straight into the T3 refresh
phase — there is **no clean `MREQ = 0` gap** between them. The old FSM keyed
its `S_DONE → S_IDLE` exit on `mmu_req_mem_out = '0'`; because the CPU runs
on the ~10 MHz `cpuClock` while the FSM samples at 50 MHz, whether the FSM
caught the momentary `MREQ` deassert at the T2→T3 boundary was
**clock-alignment dependent → non-deterministic**. This is exactly the
"runs from block RAM, fails non-deterministically from SDRAM" signature, and
it is invisible to `sdramtest.asm` (whose code runs from block RAM and only
*data*-accesses SDRAM, so it never issues an M1 fetch to SDRAM).

**The fix.** Key the FSM's `S_DONE` exit (and the `S_IDLE` re-arm) off the
actual **read/write strobe** (`mmu_req_read` / `mmu_req_write`) instead of
`MREQ`. Both strobes are deasserted in T3 (`RD_n = WR_n = 1`), so:
- the `S_DONE → S_IDLE` boundary is the clean RD/WR falling edge, immune to
  the T3 refresh `MREQ` pulse; and
- a refresh cycle (MREQ high, RD/WR low) can never start a spurious SDRAM
  access, even when frame 0 maps to SDRAM.

The strobe-based exit is also inherently safe against re-triggering the same
read inside a wait-stretched T2: while the CPU is still wait-stated, `RD`
remains asserted, so the FSM stays in `S_DONE` until the CPU actually
advances past T2 and drops `RD`. (A timing model across SDRAM-read latencies
of 2–25 `clk` cycles confirmed the fix introduces no data mismatch, no
spurious refresh-triggered request, and no same-cycle re-trigger.)

**Note on the execution test vs. the real boot.** In `sdramexec.asm` the
`.BIN` is loaded into **block RAM**, so frame 0 maps to block RAM and the M1
**refresh** address decodes to block RAM (not SDRAM) while the executed code
in frame 1 is fetched from SDRAM. That still exercises SDRAM M1 fetch (and
the hardened exit), but it does **not** reproduce the worst case where the
refresh address itself decodes to SDRAM. To stress that exact boot
condition, either load the `.BIN` into SDRAM (frame 0 → SDRAM) or extend the
execution test to map the SDRAM page into **frame 0** and run from there.

### Legacy SRAM device removed (`MicrocomputerZ80CPM.vhd`)

The dormant external-SRAM interface inherited from Grant Searle's original
MultiComp has been deleted. It was never connected at the top level
(`MultiComp.sv` left all `sram*` ports open) and its chip-select never
fired in the MMU/SDRAM memory map. Removed:

- Entity ports `sramData`, `sramAddress`, `n_sRamWE`, `n_sRamCS`,
  `n_sRamOE`, `n_sRamLB`, `n_sRamUB`.
- Signals `n_externalRamCS`, and the unused `internalRam2DataOut` /
  `n_internalRam2CS`.
- The `sramData when (n_externalRamCS = '0')` arm of the `cpuDataIn` bus
  isolation mux.

No `MultiComp.sv` change was needed (the ports were unconnected). This
addresses outstanding-work item #7 (clean-up legacy memory device).

#### Z2-compatible low-byte write (MMU.vhd)

Writing a frame's low byte (ports +0..+3) now clears the entire mapping
register first, forcing the high byte (bits 15:8) to 0. Rationale: Z2 MMU
software only ever writes the 8-bit page number via the low-byte ports;
without this, a stale high byte left by 128 MB-aware code could leave such
a write pointing at an unexpected high page. Clearing on low-byte write
guarantees a low-byte-only write always lands in the low 256 pages,
regardless of prior state. To select a page >= 256, write the low byte
first, then the high byte (+4..+7); the high-byte write does not disturb
the low byte. Implemented as two sequential signal assignments in the
register process (whole-register clear, then low-byte overwrite — the
later slice assignment wins for bits 7:0).

#### Stale-read-by-one fix (SDRAM client FSM, `MicrocomputerZ80CPM.vhd`)

The first SDRAM read after any change initially returned the *previous*
transaction's byte; the second/third reads were correct. Root cause: in
`S_REQ` the FSM latched `sdramReadData <= sdram_dout` **and** released the
CPU wait (`sdram_wait_n <= '1'`) on the *same* clock edge. Because
`sdramReadData` is a registered assignment, its new value is not visible
until after that edge, so the Z-80 sampled `cpuDataIn` (→ `sdramReadData`)
while it still held the previous value. Fix: hold the wait through `S_REQ`
and release it one cycle later in `S_DONE`, after `sdramReadData` is
stable (matching the FSM's own documented intent). This also explains the
earlier intermittent `FLAKY-READ` failures — retries "passed" because the
second read caught up. Verified by the 3-read and A/B/C/D BASIC tests and
a clean soak.

### SDRAM controller extended to full 128 MB (dual-device shared bus)

Commit `98bb963`. The XSDS expansion board carries two AS4C32M16SB devices
on a single shared 16-bit bus; **device 1's chip-select is the inverted
copy of device 0's**, so the single FPGA `SDRAM_nCS` pin selects between
them. (`SDRAM2_*` in the MiSTer framework is a *separate* expansion board,
not the second device on this module — an easy and important point to get
wrong.) The CoCo3 `sdram_32r8w` controller, which upstream reached only
32 MB of one device with the wrong row/bank/col split, was extended:

- Address ports widened 25 → 27 bits.
- Correct per-device decomposition (AS4C32M16SB = 4 banks × 8192 rows ×
  1024 cols × 16 bit = 64 MB/device):
  ```
  addr[26]    = chip   -> SDRAM_nCS (device 0 / 1)
  addr[25:13] = row    (13 bits)
  addr[12:11] = bank   (2 bits)
  addr[10:1]  = column (10 bits)
  addr[0]     = byte within the 16-bit word (DQM select)
  ```
- `SDRAM_nCS` driven from a `chip` register loaded with `addr[26]` at
  command time (was hardcoded 0).
- **Two-pass init**: `STATE_STARTUP` runs the precharge/refresh/load-mode
  sequence once per device (via an `init_chip` bit) before entering IDLE.
- **Alternating refresh**: refresh toggles `chip` each interval so both
  devices are refreshed; `cycles_per_refresh` halved to `14'd390`
  (`(64ms/8192 @ 100MHz)/2`) so each device still meets its 7.8 µs row
  refresh period.
- `MultiComp.sv` CDC adapter passes the full `sdram_addr_mux[26:0]` (no
  longer truncated to 25 bits) into a 27-bit `ram_addr` and the widened
  `sdram_cpu_addr`.

All `sdram2.sv` divergences from upstream are marked `LOCAL MOD`. The
prior 32 MB single-device config is preserved at git tag
`sdram-32mb-working` (`ff7a1a0`) as a rollback point.

### MMU direct-access window — verified on hardware

The MMU's "direct access" window (ports `0xB8..0xBC`: a 4-byte
little-endian physical-address pointer at `+8..+11` plus a data port at
`+12`) is now **proven on real DE10-Nano silicon**, covering the full
128 MB address space. The feature itself was already in the build
(committed in `ff7a1a0`); this entry records its hardware verification.

Verification was done with the BASIC test program
`testing/directaccess.bas` (a scratch test, not tracked in git), which
exercises:

1. **Single-byte R/W** — write a byte through `OUT &HBC`, reload the
   pointer, read it back through `INP(&HBC)`.
2. **Pointer post-increment** — write four consecutive bytes with a
   single pointer setup (relying on the auto-increment), reload, and read
   four bytes back. Confirms the post-increment fires on **both** reads
   and writes (it is triggered by the `+12` access ending, independent of
   direction).
3. **Direct write vs windowed read** — direct-write at a page's physical
   base, then read the same bytes through the normal frame-3 `PEEK`
   window. Confirms both paths address the same physical cells.
4. **Windowed write vs direct read** — the reverse cross-check (`POKE`
   through the window, `INP` through direct access).
5. **High address / upper device** — direct R/W at physical `0x04E20000`
   (page 5000, > 64 MB), exercising pointer bit 26 and the second
   AS4C32M16SB device.

All subtests pass. This validates the direct-access address rewrite
(`req_mem_out` forced high, `req_io_out` low, `address_out` driven from
the pointer), the one-cycle `cpu_wait` pulse for synchronous memory, the
exclusion of port `+12` from the MMU read-back mux (so data flows through
the block-RAM/SDRAM path rather than the MMU register file), and the
27-bit pointer reaching the upper SDRAM device.


### Loadable Boot ROM (`.BIN`) and RAM-disk (`.DSK`) images from the OSD — HDL implemented, hardware test pending

The OSD file-download feature is implemented across `MultiComp.sv` (top
level) and `MicrocomputerZ80CPM.vhd` (CPM core). The user can select a
`.BIN` boot image and one or more `.DSK` RAM-disk images in the MiSTer OSD;
both are streamed into SDRAM via the HPS `ioctl` download interface. No
`sys/` files and no `.qsf`/IP changes were needed (both edited files are
already in the build; `hps_io` is part of `sys.qip`).

**Config string (`MultiComp.sv`):** two generic load entries added —
`"F1,BIN;"` (load index 1) and `"F2,DSK;"` (load index 2). The explicit
index digits give deterministic `ioctl_index[5:0]` values for HDL decode.

**`hps_io` ioctl ports wired:** `ioctl_download`, `ioctl_index`,
`ioctl_wr`, `ioctl_addr` (27-bit byte offset within the file),
`ioctl_dout` (8-bit), and `ioctl_wait`. None were connected before.

**Target physical address mapping (`MultiComp.sv`):**
- `.BIN` (index 1): SDRAM physical `0x000000 + ioctl_addr` (≤512 KB). Boots
  at `0x0000`.
- `.DSK` (index 2): SDRAM physical `base + ioctl_addr`, where
  `base = 128MB - (slot+1)*8MB` and `slot = ioctl_index[15:6]`. The first
  RAM disk lands in the **top 8 MB** (`0x7800000`); each additional image
  is placed 8 MB lower. With the single `"F2,DSK;"` entry the slot is 0;
  adding more `F,DSK` entries (or HPS multi-load) increments the slot
  automatically — this is the **multi-DSK index decode** (`localparam`s
  `SDRAM_TOP`/`DSK_IMAGE_SIZE`, wires `dl_dsk_slot`/`dl_dsk_base`).

**Write path:** downloads reuse the **existing CPU-port SDRAM CDC adapter**.
During any download the whole CPM core is held in reset (the top-level
`reset` wire now includes `ioctl_download`), so the adapter is otherwise
idle and there is no contention. A small `clk_sys` handshake FSM latches
each byte on a synchronized `ioctl_wr` edge, drives the muxed
`sdram_addr_mux`/`sdram_din_mux`/`sdram_we_mux` (overriding the CPU client
while `ioctl_download` is high), **holds** the write-request level until the
adapter pulses `sdram_ready_mux`, and asserts `ioctl_wait` for the whole
in-flight window so HPS throttles the byte stream until each byte is
committed.

**Boot-source latch + auto-reset (`MultiComp.sv`):** a `bin_loaded`
register is set on the falling edge of a `.BIN` download and persists until
a genuine hard reset (`RESET`/OSD Reset/`status[0]`). A `dl_reset_stretch`
counter pulses the CPU reset for ~65 k cycles after any download completes
so the Z-80 restarts cleanly into the new image; this stretch does **not**
clear `bin_loaded`, so the freshly-loaded BIN boots.

**Critical detail — separate SDRAM init reset:** the SDRAM controller's
`.init` is driven by a **new, narrower** `sdram_init_reset` wire
(`RESET | status[0] | buttons[1] | reset_from_mount`) — explicitly NOT the
expanded `reset` — so the controller is not re-initialized during a
download (which would wipe the bytes being streamed in) or during the
post-download CPU-reset stretch.

**CPM core changes (`MicrocomputerZ80CPM.vhd`):** new input port
`bin_loaded` (defaulted `'0'`). When high:
- the boot ROM overlay decode (`n_basRomCS`) is forced inactive, and
- `phys_in_blockram` is forced low so the low 64 KB is served from SDRAM
  (where the BIN was written) rather than block RAM; `n_internalRam1CS`
  follows `phys_in_blockram`, so block RAM is deselected automatically and
  the `cpuDataIn` mux returns `sdramReadData` for `0x0000+`.

Net effect: with a BIN loaded, ROM and block RAM are disabled and the Z-80
boots the loaded image from physical/logical `0x0000` out of SDRAM, exactly
as required. With no BIN loaded (`bin_loaded = 0`) behaviour is unchanged
(built-in 8 KB ROM boot, block RAM at `0x0000`).

**Debug option — `.BIN` into block RAM (OSD `status[13]`).** Early
hardware testing showed a loaded `.BIN` printing its initial prompt but then
behaving unpredictably, suggesting either a faulty load or an SDRAM-path
problem. To isolate the two, a new OSD toggle `"OD,Boot Load Target,SDRAM,
Block RAM;"` (`status[13]`) routes a `.BIN` into the on-chip 64 KB block RAM
instead of SDRAM:
- `MultiComp.sv`: `dl_to_bram = ioctl_download & dl_is_bin & status[13]`.
  When set, the SDRAM download FSM is idled and a one-cycle-per-byte
  block-RAM write strobe (`dl_bram_we_r`/`dl_bram_addr_r`/`dl_bram_data_r`,
  address = `ioctl_addr[15:0]`) is driven into the CPM core. DSK images
  (8 MB) ignore this and always go to SDRAM.
- `MicrocomputerZ80CPM.vhd`: new inputs `boot_to_blockram`,
  `dl_bram_addr/data/we`. The block RAM's `address/data/wren` are muxed to
  the download port while `dl_bram_we = '1'` (CPU is in reset then, so no
  contention). When `boot_to_blockram = '1'`, `phys_in_blockram` is NOT
  forced off by `bin_loaded`, so block RAM stays enabled and serves the low
  64 KB; only the ROM overlay is disabled, so the BIN runs from `0x0000` out
  of block RAM. Note the BIN's low 64 KB only fits block RAM, so images
  larger than 64 KB cannot be fully tested this way — it is purely a
  diagnostic to confirm the load mechanics and CPU execution independent of
  SDRAM.

**Hardware test results (current state):**
- **Block RAM target (`status[13]=1`): WORKS reliably.** A `.BIN` loaded
  into block RAM boots and runs as expected. This confirms the OSD download
  mechanics (file streaming, `ioctl_*` decode, `bin_loaded` latch,
  auto-reset, ROM-overlay disable, and Z-80 execution from `0x0000`) are all
  correct, and isolates the remaining fault to the **SDRAM data path**.
- **SDRAM target (`status[13]=0`): DOES NOT WORK.** The same `.BIN` routed
  into SDRAM does not run correctly. Because the block-RAM path proves the
  load/decode/boot machinery is sound, the problem is specifically in
  reading and/or writing SDRAM (controller, CDC adapter handshake, address
  mapping, or byte lane/timing) — not in the download or boot logic.

**Next diagnostic step — SDRAM memory-test program.** To characterize the
SDRAM fault independently of the boot image, a standalone Z-80 SDRAM memory
test (`testing/sdramtest.asm`) is booted from **block RAM** (the known-good
path) and exercises the SDRAM through the CPU's normal MMU window. It writes
and reads back known patterns and reports pass/fail and the failing
address/bit, so we can tell whether the SDRAM is dead, stuck, mis-addressed,
or bit-laned wrong. See "SDRAM memory-test program" below.

**Verification status:** HDL edits are concurrent-assignment / FSM logic;
no local simulator is available for this design (`MicrocomputerZ80CPM.vhd`
pulls in Quartus IP and Synopsys `std_logic_arith`/`std_logic_unsigned`,
which the installed GHDL cannot analyze; `MultiComp.sv` has no SV linter in
the environment). Verification is via Quartus compile + DE10-Nano hardware.

**Open items for hardware bring-up:**
1. ~~Confirm a known-good `.BIN` boots from `0x0000`~~ — **done for block
   RAM; SDRAM path confirmed broken (see test results above).**
2. **Diagnose the SDRAM data path** using the block-RAM-booted memory test
   (`testing/sdramtest.asm`).
3. Confirm `.DSK` bytes land at physical `0x7800000` (e.g. via the verified
   MMU direct-access port / a BASIC PEEK through the frame-3 window). Likely
   blocked behind the SDRAM-path fix.
4. CDC nicety: `ioctl_wait`/`dl_busy` is generated in `clk_sys` and consumed
   in hps_io's `CLK_50M` domain (both ~50 MHz PLL taps). It is a slow level
   and held for the whole transaction, so a direct connection is acceptable
   for bring-up; revisit with an explicit synchronizer if any
   write-throttle glitches appear.
5. **Software (RomWBW side, not HDL):** the RAM-disk driver must access the
   8 MB image at physical `0x7800000` via the MMU (paging the window) or the
   MMU direct-access port. Out of scope for this HDL change.

### SDRAM memory-test program (`testing/sdramtest.asm`)

A standalone Z-80 diagnostic that exercises SDRAM independently of the boot
image, to localize the SDRAM-path fault described above. It is assembled to a
flat binary and **loaded into block RAM** (OSD "Boot Load Target = Block RAM",
the known-good path), then run from `0x0000`. It runs **two phases** that reach
SDRAM by the two different routes the hardware provides, so a pass/fail split
between them localizes the fault.

Results are printed on the serial console (6850 ACIA, `io2`): status/control
at `0x82` (bit1 `0x02` = TX-ready/TDRE), data at `0x83`.

#### Phase 1 — direct-access port (small region) — PASSES on hardware

The CPU's low 64 KB of *physical* space is the on-chip block RAM, where the
test itself runs; SDRAM only exists at physical `0x010000`+. Phase 1 touches
SDRAM through the **MMU direct-access port** so it never disturbs its own code:
- `0xB8..0xBB` — 27-bit physical pointer, little-endian (write low byte first).
- `0xBC` — data port: each `IN`/`OUT` performs a physical memory cycle at the
  pointer and then **post-increments** the pointer by 1. The CPU is auto
  wait-stated until the access completes, so no polling is needed.

Region: configurable via `SDB0..SDB3` (base) and `TEST_PAGES`; default 256
256-byte pages from physical `0x010000` → the first **64 KB** of SDRAM, kept
small so it finishes quickly. **This phase PASSES on hardware** — the raw SDRAM
array and the direct-access read/write path are good.

#### Phase 2 — MMU-paged sweep (the path real software uses)

Because Phase 1 passes, the remaining suspect is the **normal paged-access
path** that CP/M / RomWBW actually use. Phase 2 maps each 16 KB *physical*
SDRAM page, in turn, into the unused top 16 KB of the Z-80's logical space
(**frame 3, logical `0xC000..0xFFFF`**) via the MMU mapping registers, then
tests that page with ordinary CPU memory accesses (`LD (HL),A` / `LD A,(HL)`):
- Map page `N` into frame 3: `OUT (0xB3),N_lo` (low byte — clears the whole
  map register first, then sets page bits 7:0) then `OUT (0xB7),N_hi` (high
  byte — page bits 12:8; `physical_page_bits = 13`).
- Sweeps every 16 KB SDRAM page above the block-RAM overlap, `PAGE_FIRST=4`
  (physical `0x010000`) .. `PAGE_LAST=8191` (top of the 128 MB / 27-bit space).
  Both configurable.
- Prints a **running per-page progress line** `page NNNN  errs=EEEE` ending in
  a bare CR so it overwrites in place on a serial terminal, plus a **running
  16-bit byte-error tally** (`perrcount`).

The program runs from frames 0–2 (`≤0xBFFF`) and the stack/scratch live in
frame 0, so remapping frame 3 never touches its own code.

#### Tests (comprehensive pattern set, used by both phases)

Each writes the whole region/window then reads it back and verifies:
1. **Stuck-data fills** `0x00`, `0xFF`, `0xAA`, `0x55` — stuck-at / shorted
   data bits.
2. **Address-in-data** — Phase 1: byte = `addr_lo XOR addr_mid`. Phase 2: byte
   = `logaddr_lo XOR logaddr_hi XOR page_lo`, mixing in the page number so it
   also catches **page-to-page aliasing** (a page wrongly mapped to another
   page's storage reads back the wrong value).
3. **Walking-ones** `01,02,04,…,80` repeating — bit-to-bit shorts / swapped
   bit lanes.

On the first mismatch of each Phase-1 test it prints
`MISMATCH @XXXXXX exp=EE got=GG` (physical address, low 24 bits). On the first
mismatch *per page* in Phase 2 it prints
`PAGE pppp @LLLL exp=EE got=GG` (physical page number and the LOGICAL window
address `0xC000..`), then suppresses further detail lines for that page (the
tally still counts every bad byte). A combined summary prints the Phase-1
failed-test count and the Phase-2 byte-error count.

#### Build

```sh
pasmo --bin testing/sdramtest.asm testing/sdramtest.bin
```
Produces a ~1.8 KB flat binary (entry `DI; LD SP,0x0A00; …` at `0x0000`).
`pasmo` is the assembler used (installed from the distro package); no Z-80
assembler ships in this repo's toolchain otherwise.

#### Interpreting the output

- *Phase 1 passes (confirmed) but Phase 2 fails* → the fault is in the
  **paged-access path**, i.e. the MMU frame-map → `sdram_addr` translation or
  the read mux for paged (non-direct) cycles — NOT the raw SDRAM array. This is
  the same path the boot-from-SDRAM image uses, so it is the prime suspect for
  the original failure.
- *Both phases pass* → SDRAM and both access paths are good; the boot-from-
  SDRAM failure is then most likely in the **download write FSM / CDC
  handshake** (`dl_we` hold vs `sdram_ready_mux`), the
  **`bin_loaded`/`phys_in_blockram` switch-over** that re-routes `0x0000` to
  SDRAM, or **timing** of the streamed write vs the auto-reset.
- *Stuck-data fails (all same bit)* → dead/stuck data lane or the controller
  never completing the cycle.
- *Address-in-data fails but fills pass* → address-line / decode / aliasing
  fault (within a page, or page-to-page in Phase 2).
- *Walking-ones fails* → adjacent data-bit short or swapped byte lanes.

### Known issues (acknowledged, not blocking)

#### Pre-existing setup-timing violation in `SBCTextDisplayRGB`

After the MMU/SDRAM integration, Quartus reports a setup violation on
the system PLL output (`clk_sys`, 50 MHz):

- **Worst-case setup slack**: -2.359 ns
- **TNS (Total Negative Slack)**: -264.109 ns across ~20 paths
- **Failing clock**: `emu|pll|pll_inst|...|PLL_OUTPUT_COUNTER|divclk`
- **Fmax achieved**: 40.46 MHz (against 50 MHz constraint)

All failing paths are inside the legacy `SBCTextDisplayRGB` text-mode
video controller. Specifically:

- **From**: `SBCTextDisplayRGB:io1|startAddr[5..6]` — the scroll-offset
  register, updated in a `falling_edge(clk)` process (`Components/TERMINAL/SBCTextDisplayRGB.vhd:410`).
- **To**: `DisplayRam2K:\GEN_2KATTRAM:dispAttRam|...|porta_address_reg0`
  — the attribute RAM's port-A address input, clocked on the rising
  edge of `clk`.
- **Launch-to-latch budget**: 10 ns (half a 20 ns period, because the
  launch is on the falling edge and the latch is on the rising edge).
- **Combinational delay**: 12.138 ns through ~30 logic levels.

The combinational chain is dominated by `Mod0|auto_generated|divider`
— a synthesized restoring divider implementing the `mod
CHARS_PER_SCREEN` operation in this concurrent assignment at
`SBCTextDisplayRGB.vhd:401`:

```vhdl
dispAddr <= (startAddr + charHoriz + (charVert * HORIZ_CHARS)) mod CHARS_PER_SCREEN;
```

**This violation pre-dates the MMU work.** None of the failing-path
nodes touch the MMU, SDRAM client FSM, block RAM rewiring, or any
other recent additions; the path is wholly inside legacy code that
has been in the build since the initial commit. The pre-MMU baseline
(`f4d6ab2`) almost certainly fails timing in exactly the same way.

The bitstream still builds, loads, and the legacy core has been
working on real DE10-Nano silicon, which suggests the actual silicon
delay at the operating temperature is comfortably below the slow-1100mV-100C
timing-model worst case used for sign-off.

**Decision: ignore for now.** Possible future fixes if it ever causes
real-world misbehaviour:

1. Register `dispAddr` (or its inputs) in a synchronous process so
   the `mod` operation has a full clock period to settle.
2. Replace `mod CHARS_PER_SCREEN` with conditional subtraction
   (cheap since the sum naturally wraps near `CHARS_PER_SCREEN`).
3. Add a `set_multicycle_path` constraint covering this specific
   register-to-RAM path. Cannot be added to `sys/sys_top.sdc` (that
   file is externally maintained). A project-level `MultiComp.sdc` now
   exists; this path is intentionally left unconstrained there so it
   stays visible until fixed in RTL (it is now the only setup
   violation in the design).

### Outstanding work toward the requirements above

1. **Hardware bring-up of the SDRAM controller**: **DONE.** The full
   128 MB is verified on real DE10-Nano silicon — byte-accurate writes,
   correct reads (after the stale-read fix), both devices initialised and
   refreshed. Verified via BASIC POKE/PEEK soak tests: a full-range soak
   (pages 4–2047) ran 76+ clean passes, and a 128 MB soak (pages 4–8191,
   crossing the device boundary at page 4096) plus a device-1 retention
   test all passed.
2. **Hardware bring-up of the front panel**: compile and load,
   confirm the WS2812 string lights up with the default identity map
   when software writes patterns to port 0x47, exercise the colour
   stream at port 0xA3 (six bytes per LED, on-G/R/B then off-G/R/B),
   confirm the brightness scaler at port 0xA0 dims/brightens, and
   confirm the framebuffer mode at port 0xA4 + 0xA6.
3. **Widen `physical_page_bits`** from 8 to 13 once SDRAM access is
   proven, to expose the full 128 MB of physical address space.
   **DONE** — see "MMU widened to 13 bits (128 MB)" below.
4. **Revisit the MMU reset map** once experience with SDRAM access
   suggests a better default than identity (e.g. frame 3 pointing
   into SDRAM as a default "high memory window").
5. **Expand the front-panel capture chain**: once the basic 8-bit
   chain proves out, add a wider `Transparent_Capture_Chain` (or a
   `Universal_Capture_Chain` with `STRETCH_MASK` set on a few control
   bits) sourced from CPU/MMU/SDRAM control signals to drive a real
   blinkenlights display.
6. **Optional**: move the SDRAM to a dedicated higher-frequency clock
   (e.g. 100 MHz from a regenerated PLL) once basic operation is proven.
   **DONE** — the SDRAM controller runs on a dedicated `clk_ram`. 112 MHz
   showed marginal read-data capture (occasional first-read bit flips on
   DQ 7/3/1, data stored correctly); 100 MHz (`SDRAM_CLK_100` define) is
   clean over 356+ soak passes and is the shipping configuration.
7. **Clean-up legacy memory device** in `MicrocomputerZ80CPM.vhd` - 
   remove references to externalRam (`n_externalRamCS` and varous 
   `internalRam2` related signals. **DONE** — the external-SRAM entity ports
   (`sramData`, `sramAddress`, `n_sRam*`), `n_externalRamCS`, the unused
   `internalRam2DataOut` / `n_internalRam2CS`, and the SRAM arm of the
   `cpuDataIn` mux have been removed. See "Legacy SRAM device removed" above.
8. **Loadable Boot ROM (`.BIN`) / RAM-disk (`.DSK`) from OSD hardware
   bring-up**: HDL implemented across `MultiComp.sv` and
   `MicrocomputerZ80CPM.vhd` (see the progress entry above). Quartus-compile
   and test on silicon: (a) load a known `.BIN`, confirm it boots from
   `0x0000` after the auto-reset and that `bin_loaded` clears on OSD Reset;
   (b) load a `.DSK`, confirm bytes land at physical `0x7800000`; (c) wire
   the RomWBW RAM-disk driver to that physical base (software).

---

## Session summary / current state (end of 2026-06 SDRAM bring-up)

This captures where the project stands after the SDRAM bring-up and MMU
widening work, for whoever picks it up next.

### What works (verified on hardware)

- **128 MB SDRAM** fully functional: byte writes, reads, both AS4C32M16SB
  devices initialised and refreshed. See the soak-test results above.
- **MMU** widened to `physical_page_bits = 13` (27-bit / 128 MB physical
  address). Pages 0–3 = on-chip block RAM, pages 4–8191 = SDRAM.
- **Z2-compatible** low-byte mapping-register writes (clears the high
  byte).
- **MMU direct-access window** (ports `0xB8..0xBC`) verified on hardware:
  pointer R/W, post-increment on both reads and writes, agreement with
  the windowed `PEEK`/`POKE` path, and access to the upper SDRAM device
  via the 27-bit pointer. See "MMU direct-access window" above.
- **Front-panel LED subsystem** is in the build and instantiated, but
  **not yet bring-up-tested on hardware** (item 2 above).
- **CP/M 2.2 / 3.0 and BASIC** run as before (block RAM boot path
  unchanged).

### Build configuration

- **Single Quartus revision** `MultiComp` (the stale `MultiComp-lite`
  revision was removed — commit `bfd0cbc`).
- Build: `quartus_sh --flow compile MultiComp -c MultiComp` →
  `output_files/MultiComp.rbf`.
- **Clocks**: `clk_sys` = 50 MHz (Z-80 + CPM FSM); `clk_ram` = **100 MHz**
  (SDRAM controller), selected by the `SDRAM_CLK_100` define in
  `MultiComp.sv` (currently **enabled** — this is the shipping config).
  The PLL emits outclk_0=50, outclk_1=112, outclk_2=100 MHz. 112 MHz was
  rejected for marginal SDRAM read-capture timing.
- The SDRAM controller runs in its own clock domain; a 2-FF-synchronizer
  CDC adapter in `MultiComp.sv` bridges the 50 ↔ 100 MHz boundary.

### Key facts / gotchas for the next session

- **Dual-SDRAM topology**: one shared 16-bit bus, device 1's CS = inverted
  device 0 CS, so `SDRAM_nCS` (single pin) selects the device.
  `SDRAM2_*` = a *different* expansion board, NOT the second chip.
- **`SBCTextDisplayRGB` setup-timing violation** is pre-existing and
  ignored (see Known Issues) — not caused by any recent work.
- `sys/` files must never be modified (externally maintained ARM
  interface).
- PLLs are generated IP — regenerate via MegaWizard, never hand-edit.
  Regeneration touches only `rtl/pll*` files, not the `.qsf`/`.qpf`.
- Rollback tag `sdram-32mb-working` (`ff7a1a0`) = last 32 MB single-device
  config.

### Git state at session end

- Branch `louie`. The SDRAM/MMU bring-up commits are pushed to
  `origin/louie` (notable: `bfd0cbc` remove lite, `98bb963` 128 MB SDRAM,
  `ff7a1a0` MMU 128 MB + Z2 + stale-read fix, `cfcc8fc` 100 MHz, `2a88f1c`
  PLL regen, `c531ead` SDRAM bring-up summary).
- This direct-access verification update is committed on top and tagged
  `mmu-direct-access-working`.
- Incidental Quartus housekeeping churn (`MultiComp.qsf`, `build_id.v`)
  remains uncommitted by design.

## Suggested next steps (priority order)

1. **Implement "RAM Disk" access inside of Camel FORTH. 
2. **Front-panel hardware bring-up** (outstanding item 2) — the subsystem
   is wired but never lit on real hardware.  THe subsystem needs to be
   modified to shift data out starting with the most significant bit (MSB)
   first. 
3. **MMU reset map** (item 4) — decide on a sensible default beyond the
   placeholder identity map now that SDRAM is real.
4. **Legacy memory cleanup** (item 7) — remove dead `externalRam` /
   `internalRam2` signals from `MicrocomputerZ80CPM.vhd`.
5. **Begin the RomWBW port** — the original project goal. The 128 MB
   paged-memory foundation (MMU + SDRAM, with a verified direct-access
   window for inter-bank copies) is now in place to host it.

---

## Session update — sustained/back-to-back SDRAM access re-investigation

This picks up the two OPEN items from the sections above ("Wait-line phase
race: intermittent off-by-one on execute-from-SDRAM" and "SDRAM client FSM:
back-to-back request deadlock"). Despite the `S_GAP` dead-time state and the
stale-read-by-one fix already in the tree, the underlying symptom is still
present and was re-reported directly against current hardware:

- SDRAM **passes** discrete/data-only tests (`testing/sdramtest.asm`, both
  the direct-access phase and the MMU-paged sweep) and code executes fine
  from **block RAM**.
- SDRAM **execution still fails/hangs or is flaky** (consistent with the
  documented `0xC3`→`0xC4` off-by-one).
- **Back-to-back memory cycles corrupt data**, specifically reported for a
  rapid, repeated read of SDRAM through the MMU direct-access port (an
  `INIR`-style access pattern) — a new, more specific report than the
  earlier general "execute from SDRAM" symptom.

### Architecture recap (for a fresh reader)

The read/write path a Z-80 memory or direct-access cycle takes:

```
Z-80 (t80s, clocked by cpuClock ~10 MHz, a /5 divider off clk_sys)
  -> MMU (Components/alancox/MMU.vhd, clk_sys 50 MHz)
       - frame-mapped access: address_out = mmu_frame(sel) & offset
       - direct-access (+12): address_out = pointer; single 1-cycle cpu_wait
  -> SDRAM client FSM (MicrocomputerZ80CPM.vhd:664, clk_sys 50 MHz)
       S_IDLE -> S_REQ -> S_DONE -> S_GAP -> S_IDLE
       stalls the CPU (sdram_wait_n) until the controller reports `ready`
  -> CDC adapter (MultiComp.sv:260-320, clk_sys 50 MHz <-> clk_ram)
       level+edge-triggered handshake: cpu_req_level is 2-FF synced into
       clk_ram and a new transaction is launched ONLY on its rising edge —
       this requires the request level to go LOW between accesses, which is
       exactly what S_GAP is there to guarantee.
  -> sdram_32r8w controller (Components/SDRAM/sdram2.sv, clk_ram)
       CAS_LATENCY=3, dual AS4C32M16SB devices, alternating refresh.
```

### New concrete finding: PLL frequency mismatch vs. documented intent

`MultiComp.sv:491` has `` `define SDRAM_CLK_100 `` **enabled**, routing
`clk_ram = clk_ram_100 = outclk_2`. But the actual generated PLL
(`rtl/pll/pll_0002.v`) emits:

```
output_clock_frequency1("111.538461 MHz")   -- outclk_1 ("112 MHz" tap)
output_clock_frequency2("96.666666 MHz")    -- outclk_2 ("100 MHz" tap)
```

i.e. the "100 MHz" fallback is actually running at **96.67 MHz**, not 100,
and the "112 MHz" tap is 111.54 MHz. This is close enough that
`CAS_LATENCY=3` and the refresh-interval constant (`cycles_per_refresh =
390`) still hold with margin, and the `S_GAP` dead-time (3 `clk_sys` cycles)
is still comfortably long enough for the `clk_ram` 2-FF synchroniser at
either frequency. So this mismatch is probably **not** the root cause, but
it should still be corrected (regenerate the PLL to the documented 112/100
MHz) so the `clk_ram`:`clk_sys` ratio the gap arithmetic assumes is actually
true, removing one variable from future debugging.

### Ranked hypotheses for the sustained-access fault

1. **Stale-read / wait-release race between the 50 MHz control logic and the
   10 MHz derived `cpuClock` (most likely).** `cpuClock` is a free-running
   `/5` counter (`MicrocomputerZ80CPM.vhd`, `cpuClkCount`/`cpuClock`
   process), not a clock-enable — the T80 core's `CEN` is hardwired to `'1'`
   in `T80s.vhd:115` and the real gating happens via the derived clock
   itself. `sdramReadData` and `sdram_wait_n` are both driven at 50 MHz
   (`clk_sys`), but the Z-80 only samples them at `cpuClock` edges
   (10 MHz, 3/5 duty cycle). Under a **single, isolated** access there is
   comfortable slack (this is why discrete probes and the paged sweep
   pass). Under **back-to-back** access, successive transactions complete
   at different phases of the 5-cycle `cpuClock` window, and if a
   transaction's data-latch/wait-release lands unfavourably relative to the
   next `cpuClock` sampling edge, the CPU can capture a stale (previous
   transaction's) byte. This exactly matches the documented `0xC3`→`0xC4`
   off-by-one and the newly reported `INIR` corruption. A previous attempt
   to fix this by deferring the wait release to the `cpuClock`-low phase
   was **reverted as a regression** (it applied to *every* cycle, not just
   SDRAM ones, and broke normal boot) — see "Wait-line phase race" above.
   The fix must be re-attempted **gated strictly to `phys_in_sdram`** so
   non-SDRAM cycles are provably untouched.
2. **`S_GAP` dead-time margin under real `INIR` cadence.** The gap (3
   `clk_sys` cycles low) was sized against consecutive M1 opcode fetches
   from SDRAM. `INIR`'s cadence (read, write, decrement/branch) has not been
   specifically measured against the gap; if the *effective* low-time seen
   by the `clk_ram` synchroniser is shorter than assumed under this
   instruction's real timing, the request-level rising edge could still be
   missed (dropped request → stale/repeated data rather than a hard hang,
   depending on exactly where in the sequence it happens).
3. **Direct-access (I/O port `+12`) sustained-read path may differ from the
   frame-mapped sustained-read path.** The MMU's direct-access mechanism
   issues only a single `cpu_wait` pulse itself (`MMU.vhd:230`) and relies
   entirely on the SDRAM FSM's `sdram_wait_n` for the rest of the stall;
   worth confirming this behaves identically under sustained access to the
   normal frame-mapped memory path used by `LD (HL),A`/`LDIR` (which is
   known to pass in `sdramtest.asm` Phase 2).
4. **`ram_done` toggle-handshake fragility under tightly-spaced
   completions** (`MultiComp.sv:285-320`). The completion flag is a level
   that toggles once per transaction and is recovered on the `clk_sys` side
   via a 2-FF sync + XOR edge detector. This is a standard, generally robust
   pattern, but has not been proven against the *specific* cadence `INIR`
   produces; listed for completeness / SignalTap confirmation rather than as
   the leading suspect.

### New diagnostic: `testing/backtoback.asm`

To convert "we think it's the sustained-read path" into a definitive,
hardware-runnable, localized result, a new standalone test was added
(modeled on `sdramtest.asm`/`sdramexec.asm`'s structure and print helpers).
It runs from **block RAM** (OSD "Boot Load Target = Block RAM") and reports
PASS/FAIL with the first bad byte's offset/expected/got, per phase, over the
serial console (ACIA `io2`, `0x82`/`0x83`).

Layout: frame 0 (block RAM, physical page 8192) holds the code, scratch, a
1024-byte golden ramp buffer (`GOLD_BASE = 0x2000`) and a 1024-byte LDIR
work buffer (`WORK_BASE = 0x2400`); frame 1 is mapped to SDRAM physical page
`TESTPAGE = 4` (physical `0x010000`) at logical `0x4000`, matching the
direct-access pointer base (`SDB2 = 0x01` → physical `0x00010000`).

- **Phase 0 (setup):** build a 1024-byte ramp (`GOLD[i] = i mod 256`) in the
  block-RAM golden buffer, then write the *same* ramp into the SDRAM region
  via the direct-access port (the proven single-touch write path).
- **Phase A — direct-access SUSTAINED READ:** a tight `IN (0xBC)` loop reads
  1024 consecutive SDRAM bytes (pointer auto-increments in hardware) and
  compares each against the golden ramp. Directly reproduces the reported
  `INIR`-via-direct-access corruption using the I/O-port read path.
- **Phase B — `LDIR` SDRAM → block RAM (native read path):** copies the
  SDRAM region into the work buffer with a single `LDIR`, then verifies the
  buffer against the golden ramp. Exercises the same *native* memory-read
  path that M1 instruction fetch from SDRAM depends on.
- **Phase C — `CPIR` sentinel search (read-only sustained):** see the
  "Phase C bug fix" note immediately below — this phase was originally
  specified incorrectly and has been corrected.
- **Phase D — `LDIR` block RAM → SDRAM (sustained write) + verify:** writes
  the golden ramp into SDRAM with a single `LDIR`, reads it back with a
  second `LDIR`, and verifies — exercising sustained SDRAM *write*
  (`tWR`/write-recovery) as a separate axis from the read-side hypotheses
  above.

**Interpreting the pass/fail matrix:**

| Result | Localization |
|---|---|
| A fails, B/C/D pass | Direct-access (I/O-port) SDRAM read path specifically. |
| B and/or C fail | Native SDRAM read path (M1-fetch/execute + `CPIR`'s own microcode); consistent with the stale-read-race hypothesis (#1 above). |
| D fails | Sustained SDRAM *write* path (`tWR`/write-recovery, or the LDIR/direct-access write path). |
| Multiple phases fail | Shared request-level CDC (#2/#4 above) is the common root cause, not a path-specific issue. |
| All pass | The fault is narrower than this test exercises (e.g. specific to real M1 opcode fetch timing, or the refresh-phase hazard when frame 0 itself maps to SDRAM) — extend `sdramexec.asm`-style execution testing next, or map the SDRAM page into **frame 0** to reproduce the M1-refresh-hazard worst case described earlier in this document. |

Build: `pasmo --bin testing/backtoback.asm testing/backtoback.bin`. Assembles
cleanly (2312-byte flat binary; verified with `pasmo` in this session; code +
messages end at `0x4C4`, well clear of `SCRATCH = 0x900` and the
`GOLD_BASE`/`WORK_BASE` buffers at `0x2000`/`0x2400`).

#### Phase C bug fix: `CPIR` does not compare two memory regions

The first version of Phase C was written as `ld de,GOLD_BASE` / `ld
hl,SDRAM_WIN` / `ld bc,REGION` / `cpir`, intending a DE-vs-HL block compare
(mirroring `REQUIREMENTS.md`'s own wording, "check whether block-compare
fails the same way block-copy does"). **This is not what `CPIR` does.**
Per the Z-80 instruction set, `CPI`/`CPIR` compares the accumulator (`A`)
against `(HL)` only; it never reads `DE`, and `DE` is not advanced by the
instruction. The original code left `DE` unused by the hardware and `A`
holding whatever value preceding code happened to leave in it — the phase
never validated anything and would have reported false confidence.

**Fix — use `CPIR` for what it actually does.** Rather than deleting the
phase, it was adapted into a genuine, correct sustained *search*: the golden
ramp (`GOLD[i] = i mod 256`) naturally places the byte value `0xFF` at every
256-byte boundary within the 1024-byte region (offsets 255, 511, 767, 1023).
Phase C first de-duplicates this — using three isolated, single-touch
direct-access writes (the already-proven, non-sustained write path) to
overwrite the SDRAM copies at offsets 255/511/767 with `0xFE` — leaving
offset `LASTOFF` (1023) as the *only* `0xFF` left in the region. A plain
`cpir` searching for `0xFF` (`ld hl,SDRAM_WIN / ld bc,REGION / ld a,0FFh /
cpir`) must then scan every one of the 1024 bytes back-to-back (no software
instructions between reads — they all happen inside the single `CPIR`
opcode) before it can find the match at the very end. Per the documented
`CPI`/`CPIR` semantics (each iteration: compare `A` to `(HL)`, `HL++`,
`BC--`, `Z` set iff `A==(HL)`; `CPIR` repeats while `BC!=0` and `Z=0`):

- `Z=1` and `BC=0` → sentinel found on the **last** iteration exactly as
  expected — the whole region was read back-to-back with no early false
  match and no missed match. **PASS.**
- `Z=1` and `BC!=0` → sentinel found **early** (some other offset read back
  as `0xFF`) — a corrupted/stale read produced a false match. **FAIL**
  (offset reported as `LASTOFF - BC`).
- `Z=0` (`BC=0`) → sentinel never found — the true last byte itself did not
  read back as `0xFF`. **FAIL.**

This keeps the diagnostic value `REQUIREMENTS.md` was asking for (a second,
*different* sustained instruction exercising the SDRAM read path — `CPIR`'s
microcode/timing in the T80 core differs from `LDIR`'s, see
`Components/Z80/T80_MCode.vhd`) while being technically correct about what
the instruction does. The `pc_first` scratch flag from the old design was
removed (this phase is single-shot: one `cpir` call, one pass/fail
determination, not a per-byte loop needing a "first mismatch" latch).

### Next steps for whoever picks this up

1. **Assemble and run `testing/backtoback.asm`** (Boot Load Target = Block
   RAM) and record which phase(s) fail, per the matrix above.
2. If SignalTap is available, capture (triggered on the first bad byte):
   `sdram_state`, `sdram_we_reg`/`sdram_rd_reg`, `sdram_wait_n`,
   `cpu_wait_n`, `n_RD`/`n_WR`/`n_MREQ`, `mmu_req_mem_out`, `phys_in_sdram`,
   and the CDC-side `cpu_req_level`/`req_sync`/`ram_req`/`sdram_cpu_ready`/
   `ram_done` in `MultiComp.sv`.
3. Apply the fix matching the localized hypothesis (see the ranked list
   above); if it is the stale-read/wait-release race, gate any
   phase-alignment change strictly to `phys_in_sdram` so the regression from
   the earlier reverted attempt cannot recur.
4. Regenerate the PLL (`rtl/pll.qip`) to the documented 112 MHz / 100 MHz
   taps so `clk_ram` matches what the `S_GAP` arithmetic and comments
   assume.
5. Regress with **both** `testing/sdramtest.asm` (discrete) and
   `testing/backtoback.asm` (sustained) before moving on.
 6. Once sustained access is solid, proceed to the arbiter + BRAM-cache
    architecture described in `REQUIREMENTS.md` ("Memory subsystem:
    sustained-access failures + new arbitrated/cached architecture").

### Proposed speculative fixes (advance review)

> **Superseded — do not apply.** `SDRAM-review-handoff.md` section 6 shows
> these fixes are a no-op/multiple-driver error (Fix 1), unnecessary (Fix 2),
> a deadlock (Fix 3) or not behaviour-neutral (Fix 4). The actual fixes are
> in "Session update — SDRAM reliability fixes" at the end of this file.

The four fixes below are recorded here for future reference. After the
`backtoback.asm` run (see "Test result" immediately below), the plan is to
apply **Fix 1 first** (see the "Next action" note at the end of this section).
Each fix is scoped to one of the ranked hypotheses above so a single, targeted
change can be validated at a time (do not combine them until a result tells us
which one is needed; applying all of them at once would reintroduce the "changed
everything, don't know what fixed it" problem, and the earlier `cpu_wait_n_sync`
attempt *did* combine phases and became a regression).

#### Test result of `testing/backtoback.asm` (run on hardware)

The `backtoback.bin` image (2312-byte flat binary, built with
`pasmo --bin testing/backtoback.asm testing/backtoback.bin`) was loaded into
**block RAM** (OSD "Boot Load Target = Block RAM") and run. **All four
functional phases failed**, with the very first byte of the SDRAM region
(offset `0000`) reading back as `0x44` instead of the golden `0x00`:

```
MultiComp SDRAM back-to-back (sustained) test
region
PHASE 0: build golden ramp + fill SDRAM (direct-access)
  PHASE 0 OK

PHASE A: direct-access SUSTAINED READ
    FAIL @0000 exp=00 got=44

PHASE B: LDIR SDRAM->BRAM (native read path)
    FAIL @0000 exp=00 got=44

PHASE C: CPIR sentinel search (read-only sustained)
    FAIL sentinel found EARLY @0001

PHASE D: LDIR BRAM->SDRAM (sustained) + verify
    FAIL @0000 exp=00 got=44

==== VERDICT ====
RESULT: FAILURES DETECTED (see phases above)
```

**Observations on the result:**

1. **Phase 0 (the proven single-touch direct-access *write* path) passed** —
   so the write path into the SDRAM region works for the direct-access port,
   and the block-RAM golden ramp built there is fine.
2. **Every read-back of the first SDRAM byte returns `0x44`, not the golden
   `0x00`** — in Phase A (direct-access read), Phase B (`LDIR` native read),
   and Phase D (`LDIR` read-back after write). The failing offset is `0000` in
   all three, and the failing value is the **same** `0x44` — i.e. the first
   byte of the region is consistently corrupted to a *fixed* value independent of
   the three different read paths.
3. **Phase C** (`CPIR` search for the `0xFF` sentinel) reports the sentinel
   found **early at offset `0001`** — i.e. the second byte read back as `0xFF`
   when it should have been `0x01`. Combined with #2, this points at a
   *read-side* corruption of the first byte(s) of the region rather than a
   write-path corruption (the writes themselves are what Phase 0 exercised and
   it passed).

**Interpretation against the pass/fail matrix (this document, "Interpreting the
pass/fail matrix" table):** the row for "Multiple phases fail" states:

> Multiple phases fail → **Shared request-level CDC (#2 / #4 above) is the
> common root cause, not a path-specific issue.**

That is the matrix-consistent reading: the fault is *not* isolated to one read
path (not just the direct-access port — that would be "A fails, B/C/D pass"),
and it is *not* a sustained-write fault (that would be "D fails"), but a
**shared** defect on the request-level CDC handshake that corrupts the first
byte of a sustained read sequence. This maps to ranked hypotheses **#2**
(`S_GAP` dead-time margin under sustained cadence — a *dropped* request on the
first sustained access, which would leave the read data latched at a stale/
fixed value) and **#4** (the `ram_done` toggle-handshake under tightly-spaced
completions). Hypothesis #1 (stale-read / wait-release race, the `0xC3`→
`0xC4` off-by-one) is the *most likely* per the earlier ranking and is the
natural first fix to try, and is in fact the one chosen next (see below); but
note the matrix evidence leans toward the *shared* CDC (#2/#4) rather than
strictly the phase-race (#1), so if Fix 1 does not clear offset `0000`,
Fix 2 (and then the Fix 2b `MultiComp.sv` escalation) is the fallback path.

The common, fixed `got=44` at offset 0 is notable: a constant wrong value on
the *first* byte of a sustained read is a classic signature of the **first
request after the FSM/`S_GAP` re-arm being dropped or reading a stale latch**,
i.e. the request-level synchroniser in `MultiComp.sv` (`req_sync`/`req_seen`,
`:266-301`) not re-arming for the very first sustained access — exactly the
condition the `S_GAP` dead time exists to prevent.

#### Next action

Per the decision to proceed: **implement Fix 1** (the SDRAM-gated,
phase-aligned wait release shown in "Fix 1" below) as the first attempt,
**gated strictly to `phys_in_sdram`** (the property the reverted
`cpu_wait_n_sync` lacked), and validate against a normal ROM/RAM cycle in
simulation before flashing. If Fix 1 does not clear the offset-`0000`
`0x44` failure, escalate to **Fix 2** (`S_GAP` widening, then the `2b`
`MultiComp.sv` `req_low_confirmed` path), which is the matrix-consistent
"shared CDC" fallback. Do **not** apply Fix 3 (direct-access-only) — the
result shows all paths failing, not just the direct-access one. Fix 4 (PLL
regeneration) remains an orthogonal clean-up to be done alongside, not as a
substitute.

All four fixes below (Fix 1, Fix 2 incl. 2a/2b, Fix 3, Fix 4) are retained in
this section verbatim for future reference regardless of which one clears the
fault.

---

**Fix 1 — SDRAM-gated phase-aligned wait release (Hypothesis #1: stale-read /
wait-release race).**

This is a *re-attempt* of the earlier reverted `cpu_wait_n_sync`, but this time
**strictly gated to `phys_in_sdram`** so non-SDRAM cycles are provably untouched
— the very property that the reverted attempt lacked (it applied to *every*
cycle and broke normal boot).

The idea: the 50 MHz FSM releases `sdram_wait_n` in `S_DONE` at an arbitrary
`clk` edge, but the Z-80 only samples `cpuDataIn` / `cpuWait_n` on the `cpuClock`
rising edge (a free-running `/5` of `clk`, `MicrocomputerZ80CPM.vhd:771-785`,
3/5 duty cycle). Under back-to-back SDRAM reads the `S_DONE` release can land
unfavourably relative to the next `cpuClock` sampling edge, so the CPU samples a
stale byte — the documented `0xC3`→`0xC4` off-by-one.

The fix holds a *second*, SDRAM-only wait line (`sdram_wait_n_phase`) that, after
the original `S_DONE` release, keeps the CPU stalled until the **next** `cpuClock`
rising edge. Important timing detail (from `MicrocomputerZ80CPM.vhd:775-785`):
`cpuClkCount` counts `0..4`, and `cpuClock` is high while `cpuClkCount >= 2` and
low while `cpuClkCount < 2`, so the **`cpuClock` rising edge is the `clk` edge
where `cpuClkCount == 2`** (not `0`). The phase line must therefore release on
`cpuClkCount == 2`, aligning the wait release with the edge the T80 actually
samples. Because it is computed only from `cpuClkCount` and applied only when
`phys_in_sdram = '1'`, ordinary ROM/RAM/I/O cycles never see it and the
`0xC3`/normal-boot path is unchanged.

Proposed shape (added near the `cpu_wait_n` combine at
`MicrocomputerZ80CPM.vhd:334-335` and the S_DONE block at `:717-727`):

```vhdl
-- New signal: an SDRAM-only, phase-aligned wait.
-- '0' means "still hold the CPU" for the rest of the cpuClock window.
signal sdram_wait_n_phase   : std_logic := '1';
signal sdram_phase_pending  : std_logic := '0';

-- Combined wait into the CPU. The phase line is ANDed in ONLY for SDRAM
-- physical addresses, so non-SDRAM cycles are provably untouched (this is the
-- property the earlier cpu_wait_n_sync lacked).
cpu_wait_n <= (not mmu_cpu_wait) and sdram_wait_n
              and (sdram_wait_n_phase when phys_in_sdram = '1' else '1');

-- In S_DONE, instead of releasing immediately, raise phase-pending so the
-- release is deferred to the next cpuClock rising edge.
--   (original line:  sdram_wait_n <= '1';  is replaced by:)
--   sdram_wait_n      <= '1';
--   sdram_phase_pending <= '1';
--
-- Phase-pending is cleared on the *next* cpuClock rising edge. From
-- MicrocomputerZ80CPM.vhd:781-785 cpuClock is high while cpuClkCount >= 2,
-- so the cpuClock rising edge is the clk edge where cpuClkCount == 2.
process(clk)
begin
  if rising_edge(clk) then
    if sdram_phase_pending and cpuClkCount = "000010" then
      sdram_wait_n_phase  <= '1';   -- release on the next cpuClock rising edge
      sdram_phase_pending <= '0';
    end if;
     -- (sdram_wait_n_phase is held '0' while pending; see below)
  end if;
end process;
```

Caveat to resolve before applying: `cpuClkCount` shares the same `clk`-driven
process that generates `cpuClock` (both at `:771-785`), so the "next rising
edge of `cpuClock`" is pinned to `cpuClkCount == 2` as above. If the FSM's
`S_DONE` happens to fall *on* that same `clk` edge, the phase line must instead
wait for the *following* `cpuClkCount == 2` (one full 5-cycle window later) —
otherwise it releases a beat early. This must be **validated against a normal ROM
cycle in simulation first** (the same regression guard the previous
`cpu_wait_n_sync` attempt missed, when it applied the stall to every cycle).

---

**Fix 2 — Widen / adapt the `S_GAP` dead time (Hypothesis #2: gap margin under
`INIR` cadence).**

The current `S_GAP` holds the `sdram_we`/`sdram_rd` request strobes low for
`sdram_gap_cnt = "10"` (3 `clk_sys` cycles, `MicrocomputerZ80CPM.vhd:742`).
That was sized against consecutive M1 opcode fetches, not against `INIR`'s
read/then-write/then-decrement cadence. If the *effective* low-time seen by the
112 MHz 2-FF `req_sync` synchroniser (`MultiComp.sv:285-301`) is shorter than
assumed under `INIR`, the request-level rising edge can be missed — producing a
*dropped* request (stale/repeated data) rather than a hang.

Two alternative, independently applicable sub-fixes:

**2a (cheap, first try): lengthen the gap.** Change the count at `:742` from
`"10"` (3 cycles) to `"11"` (4 cycles), or `"00"`/`"11"` depending on the
width of `sdram_gap_cnt` (currently `unsigned(1 downto 0)`, so max 3). If 4 is
needed, first widen the counter:

```vhdl
-- signal sdram_gap_cnt : unsigned(1 downto 0)  ->  unsigned(2 downto 0)
signal sdram_gap_cnt    : unsigned(2 downto 0) := (others => '0');
-- ...
-    sdram_gap_cnt <= "10";  -- 3 clk_sys cycles of dead time
+    sdram_gap_cnt <= "011"; -- 4 clk_sys cycles of dead time
```

At ~2.2× `clk_ram`:`clk_sys`, 4 `clk_sys` cycles still guarantee ≥9 `clk_ram`
edges sample the level low, so re-arm is safe; the only cost is one extra
`clk_sys` stall per SDRAM access (irrelevant at 10 MHz CPU speed).

**2b (robust, if 2a does not help): make the gap self-asserting off
`req_sync`/the synced level.** Rather than a fixed count, exit `S_GAP` only
when the *synchronised* request level in `clk_ram` has actually observed a low
— but `req_sync` lives in `MultiComp.sv`'s `clk_ram` domain and is not currently
exposed back to `clk_sys`. A minimal version: have `MultiComp.sv` pulse a
`req_low_confirmed` level (set when `req_sync(1) = '0'`), synchronise it back
into `clk_sys` (2-FF), and let `S_GAP` clear on that. This removes the
frequency-ratio assumption entirely. This is a larger change touching
`MultiComp.sv` and is listed as a *fallback*, not a first attempt.

---

**Fix 3 — Align the direct-access (`I/O port +12`) sustained-read path with the
frame-mapped path (Hypothesis #3: direct-access vs. frame-mapped divergence).**

The `INIR`-via-direct-access report suggests the MMU's `+12` direct-access
mechanism (single self-issued `cpu_wait` pulse at `Components/alancox/MMU.vhd:230`,
relying entirely on the FSM's `sdram_wait_n` for the rest of the stall) may
behave differently from the frame-mapped `LD (HL),A` / `LDIR` path (known good in
`sdramtest.asm` Phase 2). The likely divergence: the direct-access port may emit
its *own* single-cycle `mmu_cpu_wait` on top of (or racing with) the FSM's
`sdram_wait_n`, so on a back-to-back direct read the MMU's one-cycle wait
"pre-arms" the next access before the FSM's `S_GAP` has elapsed, collapsing the
gap.

The fix is to make the direct-access read path **defer to the SDRAM FSM's
wait entirely** when `phys_in_sdram = '1'`, i.e. suppress the MMU's own
`mmu_cpu_wait` pulse for SDRAM-targeted direct accesses so the FSM is the sole
authority on the wait line (the same single-source-of-wait the frame-mapped path
already has). Concretely, in `MMU.vhd` where the `+12` direct port drives
`cpu_wait`, gate that pulse with `not phys_in_sdram`:

```verilog
// (pseudo) in MMU.vhd direct-access cpu_wait driving logic:
// before:  mmu_cpu_wait <= (direct_access && !sdram_ready) ? 1 : 0;
// after:   mmu_cpu_wait <= (direct_access && !sdram_ready && !phys_in_sdram) ? 1 : 0;
```

This requires `phys_in_sdram` (or an equivalent "this access is SDRAM" flag) to be
available inside the MMU. If it is not, an alternative is to add such a flag to the
MMU input list (the physical decode already exists at
`MicrocomputerZ80CPM.vhd:332`). **This fix is distinct from Fix 1 and Fix 2 and
should only be applied if the `backtoback.asm` matrix shows Phase A (direct-access
sustained read) failing while B/C/D pass** — in which case the fault is
path-specific to the direct-access port, not a shared CDC issue.

---

**Fix 4 — Regenerate the PLL to the documented 112 MHz / 100 MHz taps
(orthogonal clean-up, not a data fix).**

`MultiComp.sv:491` has `` `define SDRAM_CLK_100 `` enabled, so `clk_ram` takes
`outclk_2`. But the generated PLL (`rtl/pll/pll_0002.v`) actually emits
`outclk_2 = 96.67 MHz` and `outclk_1 = 111.54 MHz`, not the documented 100 / 112.
This is *probably* not the root cause (the `S_GAP` math and refresh interval still
hold with margin at 96.67 MHz), but the `clk_ram`:`clk_sys` ratio the
`S_GAP` dead-time arithmetic assumes is the documented one. Regenerate
`rtl/pll.qip` via MegaWizard to the true 112/100 MHz taps so the ratio is
exactly what the comments and Fix 2a's "≥9 `clk_ram` edges" claim assume. This is
a no-behaviour-change-for-correct-data cleanup that removes one variable from
future debugging; it should be done alongside, not instead of, the targeted fix.

---

**Application policy for the above (do not deviate):**

1. Run `testing/backtoback.asm` first; do **not** apply any fix before the
   pass/fail matrix is recorded.
2. Apply **exactly one** fix, the one matching the matrix (A→Fix 3, B/C→Fix 1
   with Fix 2b as escalation, D→write-path investigation, multi-phase→Fix 2).
3. Verify the applied fix against a **normal ROM/RAM cycle in simulation**
   (or a block-RAM boot) before flashing — the `cpu_wait_n_sync` regression
   shows that an "SDRAM-only"-claiming change can still leak across to
   non-SDRAM cycles if the gating is wrong.
4. Regress with **both** `testing/sdramtest.asm` and `testing/backtoback.asm`
   after each single fix.
5. Keep each fix in its own commit so a regression can be isolated and reverted
   without touching the others.

## Session update — CamelFORTH CP/M port: block I/O, dynamic buffers, and
## a per-line `LOAD`/`EVALUATE` bug report investigation

Continuation of "Integrated Camel FORTH" (see above). This session's work is
entirely in `forth/`; no HDL was touched. Goal: get a CP/M 2.2/3.0-hosted
build of CamelFORTH (`io-cpm.azm`) able to use a real CP/M file as FORTH
block storage, on par with the embedded/bare-metal build (`io-multi.azm`),
and get rid of hand-picked absolute-address hacks in the block-buffer code.

### `io-cpm.azm`: CP/M 2.2 compatibility fix for multi-sector block I/O — done

**Problem.** The prototype `file$io` word used BDOS function 44
(`BD$SMSCNT`, "set multi-sector count"), which is a **CP/M 3.x-only**
call — it does not exist on CP/M 2.2, which was a hard requirement.

**Fix.** `file$io` (`forth/io-cpm.azm`) now moves a 1024-byte FORTH block as
**eight separate 128-byte CP/M records** in a loop, using only BDOS calls
available since CP/M 1.4/2.2 (`BD$SETDMA`=26, `BD$RDRND`=33, `BD$WRRND`=34,
`BD$WRRNDZ`=40):

1. `SWOP, file$seek` — seek once to the base record (`block# * 8`).
2. `LIT,8, LIT,0, XDO` — loop `I = 0..7` using the kernel's existing
   `(do)/(loop)` primitives (`XDO`/`XLOOP`, same idiom as `load$extend`).
3. Each pass: compute `buffer-adr + I*128` (`DUP, II, LIT,80h, STAR, PLUS`),
   `BD$SETDMA` to that address, do the single-record BDOS call (whichever
   `operation` was passed in), then bump the FCB's 16-bit random-record
   field (offset 33) by one for the next pass.
4. Return a placeholder `0` status (unused — `read-file`/`write-file` already
   `DROP` it).

`read-file`/`write-file`'s external signature
(`operation block# buffer-adr -- status` for `file$io`;
`block# buffer-adr --` for the callers) is unchanged, so nothing else needed
to be touched. `BD$SMSCNT` is left defined (for documentation) but marked
unused.

**Verification.** No Z80 hardware available in this environment; verified by
reassembling a CP/M variant (`um80 camel80.azm -D CPM`) and checking the
`.prn` listing byte-for-byte for the expected thread, then linking with
`ul80` to confirm no assembler/linker errors. See "Z-80 emulation harness"
below for how this was later exercised dynamically too (the `LOAD` word
built on top of this code was run end-to-end in emulation and correctly
round-tripped multi-line block content through this exact 8-record loop).

### Dynamic block-I/O transfer buffer (`BLKBUF`), replacing hard-coded `disk$buf` — done

**Problem.** Both `io-cpm.azm` and `io-multi.azm` used
`disk$buf EQU 8000h` — a hand-picked absolute address for the one-block
(1024-byte) scratch buffer used by the low-level bootstrap `LOAD` word,
already flagged in the source as "I know this is ugly, for now". This
address has no relationship to the actual dictionary size or target memory
map, and (not coincidentally) collides on purpose with `blocks.fth`'s own
`FIRST` buffer-pool base — a second instance of the same hack (see below).

**Fix — recommended mechanism (portable across CP/M, embedded, and a future
RomWBW/HBIOS target):** allocate the buffer once, at cold-start, using the
ordinary `HERE`/`ALLOT` dictionary-growth primitives — exactly what a Forth
programmer would type interactively (`CREATE X 1024 ALLOT`), just invoked
directly from the `COLD` thread since `HERE`/`ALLOT` need no input-stream
parsing (unlike `CREATE`). This works on every target because `HERE` reads
back the `DP` user variable, which every target already initializes to
`enddict` (the address immediately following that target's own compiled
dictionary, computed automatically by the assembler for each target/build) —
so the buffer always lands in free RAM just past the dictionary, with no
target-specific address to hand-pick, ever.

Implementation (`forth/camel80h.azm`, shared/portable core — used by every
target):

```
    head BLKBUF,6,'BLKBUF',dovar
        DW 0
BLKBUFSIZE EQU 1024
    head COLD,4,'COLD',docolon
        DW UINIT,U0,NINIT,CMOVE
        DW HERE,BLKBUF,STORE, LIT,BLKBUFSIZE,ALLOT
    IFDEF CPM
        DW LIT,80h,COUNT,INTERPRET
    ENDIF
        ...
```

`io-cpm.azm` and `io-multi.azm`: removed `disk$buf EQU 8000h`; every
`LIT,disk$buf` became `BLKBUF,FETCH` in `load$extend`. Verified by
reassembling both the `-D CPM` and default (embedded) targets cleanly and
confirming the `.prn` listings show `COLD` allocating the buffer and
`load$extend` fetching it correctly on both.

### `blocks.fth` / `forth/blocks/*.fth`: same fix applied to the `FIRST`/`LIMIT` block-buffer pool — done

**Important discovery:** `forth/blocks.fth` (the single monolithic file) is
**not actually used by any build** — its own header comment says it's "the"
reference copy, "manually split into multiple 16-line screens ... within the
`blocks` directory". The code that actually ships (built into
`blocks/forth.blk` by `forth/blocks/Makefile`, then loaded at runtime by both
targets) is the separately-maintained, slightly-diverged copy in
`forth/blocks/02-blocks.fth`, `03-blocks.fth`, `04-blocks.fth`, and (for a
derived constant) `10-editor.fth`. **Both copies needed the fix**; fixing
only `blocks.fth` would not have changed real runtime behaviour. Keep this in
mind for *any* future change to the block/editor code — check `blocks.fth`
*and* the matching `blocks/NN-*.fth` screen(s), and keep them in sync.

**The hack:** `8000 CONSTANT FIRST` / `FIRST B/REC #BUFF * + CONSTANT LIMIT`
— the `#BUFF`-buffer block-cache pool used by `BLOCK`/`BUFFER`/`FLUSH`, at
the same hand-picked `8000h` address as the old `disk$buf` (intentionally,
since the bootstrap `LOAD` only uses that memory transiently before
`blocks.fth`'s buffer pool takes it over — but still an address totally
disconnected from the real dictionary size).

**Fix (pure Forth, no OS-specific code needed at all — this file is loaded
identically on every target):** `FIRST` and `LIMIT` become `VARIABLE`s
(forward-declared early, like `BLKBUF`) instead of `CONSTANT`s with a
hard-coded value; every call site changed from bare `FIRST`/`LIMIT` to
`FIRST @`/`LIMIT @` (`+BUF`, `BUFFER`, `BLOCK`, `FLUSH`, `EMPTY-BUFFERS`,
`MAKE-BLOCKS`). `PREV`/`USE` are declared but no longer initialized inline
(their real value depends on `FIRST`, not known yet at that point). After
*every* word that references `FIRST`/`LIMIT` has been compiled, one small
one-time block does the real allocation:

```
HERE FIRST !
FIRST @ B/REC #BUFF * + LIMIT !
FIRST @ DUP PREV ! USE !
B/REC #BUFF * ALLOT
```

This must run exactly once (it's plain interpreted code at the end of the
file, *not* inside a re-callable word like `EMPTY-BUFFERS`/`OPEN-BLOCKS` —
calling `ALLOT` again on every `OPEN-BLOCKS` would leak dictionary memory
every time a block file is (re-)opened).

`forth/blocks/10-editor.fth`'s `ZZZ` scratch/working buffer
(`LIMIT 10 + CONSTANT ZZZ`) was updated to `LIMIT @ 10 +`, so it
automatically tracks wherever the now-dynamic pool ends up too. **Not fully
fixed / follow-up for later:** `ZZZ`'s own buffer memory (and the larger
buffer built on top of it via `PADDR` in later editor screens) is still
never `ALLOT`-protected — it just assumes free space past `LIMIT`. It no
longer depends on a hard-coded *address* (it tracks `LIMIT` dynamically
now), but the memory itself still isn't reserved. Apply the same
`HERE ... ALLOT` pattern there if this ever causes a real collision.

**`forth/blocks/*.fth` screen-format constraint to remember:** each `NN-*.fth`
file must stay within **16 lines × 64 columns** — `forth/blocks/Makefile`'s
per-file build rule enforces this with an `awk` check
(`length > 64` / `FNR > 16` → hard build error) before calling
`../mkblk.sh`. All the edits above were re-checked against this budget by
hand (e.g. shortening `( addr1-- addr2)` to `( a -- a)` in `+BUF`'s stack
comment on `02-blocks.fth` to make room). **Gotcha found incidentally (not
caused by this session's edits, pre-existing):** `forth/blocks/01-utils.fth`
line 4 is currently **65 characters** (one over the limit) —
`make -B 01-utils.blk` fails the `awk` check
(`01-utils.fth:4: line is 65 bytes (max 64)`). It didn't block this session's
work (only `02/03/04-blocks.fth` and `10-editor.fth` needed rebuilding, and
`make` without `-B` reused the existing, already-valid `01-utils.blk`), but
it means `forth.blk` cannot currently be regenerated from scratch
(`make -B forth.blk`) until that line is fixed or shortened. Flagging for a
future session — not fixed here since it's unrelated to the buffer-allocation
work and the offending character (in this specific case) is only a redundant
trailing space, so nothing is actually broken in the *currently checked-in*
`.blk` build products.

**Verification.** Rebuilt the affected screens with `mkblk.sh`/`make`
(`forth/blocks/Makefile`'s awk length/line-count checks all pass), and
visually diffed the assembled 1024-byte block content with `forth/blk2txt`.

### Z-80 emulation harness for dynamic testing (new capability for future sessions) — built, useful, kept in `/tmp` only

No Z80/CP/M emulator was preinstalled. Found and used the **`z80`** PyPI
package (`pip install --break-system-packages z80`; by Ivan Kosarev,
<https://github.com/kosarev/z80>) — a real, fast, well-documented Z80/8080
emulator with Python bindings (`z80.Z80Machine`), memory/IO
read/write/breakpoint callback hooks, and register access as Python
properties (`m.bc`, `m.pc`, `m.iy`, ...). This is a generically useful
capability worth remembering for any future "does this actually work"
question about the FORTH kernel that doesn't require real hardware.

**Harness technique that worked (documented here so it doesn't need to be
re-derived):**

- Assemble a CP/M variant of `camel80.azm` (temporarily stub out the two
  `call puts` / `call introdump` debug lines with `um80`/`sed`, since those
  are only defined in `io-multi.azm` and the code unconditionally calls them
  today — a pre-existing gap in `camel80.azm`'s `IFDEF CPM` separation, not
  something fixed in this session; see "Outstanding work" below).
  `um80 camel80.azm -D CPM -g -o out.rel -l out.prn`, then
  `ul80 -p 0 --sym -x -o out.hex out.rel`, `objcopy -I ihex -O binary` to get
  a flat image and a `.sym` symbol table (`ADDR NAME` per line, easy to
  `dict()`-ify in Python).
- Load the binary at `0x100` (the CP/M `org`) into a `z80.Z80Machine()`'s
  64 KB `memory` bytearray.
- **Do not bother running real `RESET`/`COLD`/`QUIT`.** For the CP/M build,
  `$ENDADDR EQU 8000h` is hard-coded (see "Outstanding work" below — this
  build does *not* probe CP/M's actual TPA size via location `0006h`), so
  `reset::`'s stack/user-area setup is fully deterministic:
  `SP=0x7F00` (param stack top), `IX=0x8000` (return stack top),
  `IY=0x7E00` (user-area base). Just poke these directly, and poke the
  18-byte user area (`UINIT`'s layout: `reserved@0, >IN@2, BASE@4,
  STATE@6, DP@8, 'SOURCE@10(2 cells), LATEST@14, HP@16`) with `DP=ENDDICT`
  (or `ENDDICT+BLKBUFSIZE` post-`BLKBUF`-alloc), `BASE=10`, `STATE=0`,
  `LATEST=<the LASTWORD symbol>`. All of `ENDDICT`/`LASTWORD`/`BLKBUF`/
  whatever word you want to call come straight out of the `.sym` file.
- To directly invoke *any* `docolon` word (e.g. `EVALUATE`, `LOAD$EXTEND`)
  without going through `QUIT`: push its Forth arguments the normal way
  (`BC` = TOS, rest on the Z80 hardware stack at `[SP]`, `[SP+2]`, ...), set
  `DE` (the Forth IP) to point at a 1-cell scratch thread containing
  `DW BYE` (`BYE` = `jp 0`, already in the kernel), set `PC` to the word's
  **CFA address** (the label itself, *not* its body) and `run()`. This works
  because a `docolon` word's CFA is `call docolon` — the Z80 `call`
  instruction's own return-address push (of the body's address) is exactly
  what `docolon`/`enter` expects to find on the Z80 hardware stack, so
  jumping to any docolon word's CFA "just works" as if it had been called
  from a running thread. When the word's `EXIT` eventually runs, it pops the
  old IP (which we set to the `DW BYE` cell) and continues there, hitting
  `BYE`'s `jp 0`. **Set a breakpoint at address `0` to detect clean
  completion**, and one at `ABORT`'s address to detect an interpreter error
  (undefined word / bad number) — no need to instrument `EMIT`/`TYPE`
  output at all for pass/fail detection, though capturing it (see next
  point) is useful for debugging.
- Stub BDOS (`mem[5] = 0xC9` i.e. `RET`) for a "don't care about I/O, just
  don't crash" run, **or** set a breakpoint at address `5` and manually
  handle just the functions needed (`6`=console char out, `15`=open,
  `26`=set DMA, `33`/`34`/`40`=random read/write — read the FCB's record
  number from `mem[fcb+33..34]`, serve 128 bytes from a canned in-memory
  "disk block", write to whatever the last `26` call set as the DMA
  address), then simulate the `RET` yourself
  (`pc = mem[sp] | mem[sp+1]<<8; sp += 2`) to resume. This is enough to run
  the *real* compiled `LOAD`/`open-file`/`read-file`/`file$io` code
  end-to-end against synthetic block content, which is exactly how the
  `io-cpm.azm` CP/M-2.2 8-record loop (above) and the per-line `LOAD`/
  `EVALUATE` investigation (below) were exercised.
- Watch out for the emulator's `run()` returning on an `_END_OF_FRAME` event
  (bit `1<<3`) even with no breakpoint hit and ticks remaining — it's a
  periodic/frame-boundary event unrelated to CPU halt state. Loop calling
  `run()` with a bounded `ticks_to_stop` per call, checking `pc` against
  your breakpoints after each call, until one hits or a generous chunk
  budget is exhausted (a full 16-line block `LOAD`, each line echoed via
  `TYPE`, needs on the order of 1000+ BDOS/breakpoint round-trips just for
  the character-by-character `EMIT` calls — size the chunk budget
  accordingly, e.g. 5000+ chunks of 200 000 ticks each was comfortably
  enough and still ran in well under a second).

The harness scripts themselves were exploratory/throwaway and were **not**
committed (kept under `/tmp/opencode/z80test/` only, outside the repo) —
recreate from the description above if needed again; the technique is the
useful, durable part.

### Investigated: reported subtle bug in per-line `LOAD`/`EVALUATE` — **not reproduced**; real limitation found and documented instead

**Report:** using the low-level bootstrap `LOAD` word (present in both
`io-cpm.azm` and `io-multi.azm`, which both interpret a 1024-byte FORTH
block **one 64-byte line at a time** via 16 separate `EVALUATE` calls), an
error was reported that seemed tied to whether the text on the *last line of
a block* runs all the way to column 64 or stops short of it (padded with
trailing spaces) — suspected off-by-one in `EVALUATE`/`WORD`/`INTERPRET`
(`forth/camel80h.azm`).

**Investigation performed (both static and dynamic):**

1. Fetched Bradford Rodriguez's original CamelForth-for-Z80/CP-M
   distribution (`http://www.camelforth.com/public_ftp/cam80-12.zip` — this
   project is a direct derivative; identical file names
   `CAMEL80.AZM`/`CAMEL80H.AZM`/etc.) and diffed `WORD`, `SCAN`, `SKIP`,
   `INTERPRET`, `EVALUATE` against this repo's `camel80.azm`/`camel80h.azm`.
   **They are byte-for-byte identical** to the original — nothing has been
   altered in this shared kernel code by this project.
2. Traced `WORD`'s algorithm by hand: `SKIP`/`SCAN` (`camel80.azm`, Z80
   `cpi`/`cpir`-based) are **strictly bounded by the Z80 `BC` count
   register** — they can never read past the `u` bytes handed to `WORD` by
   `SOURCE`/`/STRING`, regardless of whether a delimiter is found before the
   end of the given range or not (the "not found" case correctly falls back
   to "word extends to end of given range", consuming exactly the remaining
   length — verified this is exactly what the `DUP,qbranch,WORD1,ONEMINUS`
   dance in `WORD` computes). No over-read is possible by construction.
3. Built the Z80 emulation harness described above and dynamically tested,
   both via a single isolated `EVALUATE(addr,64)` call and via the *real*,
   fully end-to-end compiled `LOAD` word (16-line loop, real `BDOS`-served
   block content):
   - Words/numbers padded with trailing spaces vs. filling exactly to
     column 64 (both directions, many lengths).
   - A totally blank last line; an entire block of blank lines.
   - Colon definitions (`: NAME ... ;`) ending exactly at column 64 vs.
     short + padded.
   - `BASE`=10 and `BASE`=16 (blocks conventionally start `HEX`).
   - Real production block content (`forth/blocks/00-start.fth`,
     `01-utils.fth`) with the last line varied.
   - Two-block sequences via the real `INIT`/`bootextend` word
     (`LIT,0,load$extend, LIT,1,load$extend`), checking not just for a crash
     but final stack depth and `STATE` afterward (to catch a "silent"
     corruption that might only manifest later, not just an immediate `?`
     error).
   - **Every one of these passed correctly.** The only `?`/`ABORT` hits
     encountered were confirmed to be **bugs in the test's own crafted input
     text** (e.g. `DUP;` — no separating space before `;`, so it parses as
     one undefined token `DUP;` — correct interpreter behaviour, not a
     system bug), not spurious/incorrect failures.

**Conclusion:** could not reproduce the reported bug in
`EVALUATE`/`WORD`/`SCAN`/`SKIP`/`INTERPRET`; the code is provably unmodified
from the trusted original and behaves correctly across a wide, deliberately
adversarial battery of boundary conditions.

**One real, verified (but different-directioned) limitation *was* confirmed**
and is worth remembering: because `LOAD` calls `EVALUATE` **once per 64-byte
line**, no token (word/number) or multi-character construct (`( comment )`,
`S"`/`."`/`ABORT"` strings) can *span* a line boundary — each line is an
isolated source buffer with its own independent `>IN`/`'SOURCE`. If authored
text assumes it can "flow" past column 64 into the next line, the word gets
truncated at the boundary and (if the truncated fragment isn't a real word or
number) triggers the `?`/`ABORT` error path — but this requires the text to
*reach* column 64 (mid-token), which is the **opposite** of the reported
direction ("doesn't extend to the last character"). `io-multi.azm` already
has a `LOADLINES` `IFDEF` toggle specifically for this class of problem
(undefining it switches to whole-block `EVALUATE`, letting definitions span
lines, at the cost of losing the per-line echo); `io-cpm.azm`'s
`load$extend` has no such alternative at all currently — always per-line.

**Status: open, blocked on a reproducer.** Asked for (not yet received as of
this writing): the exact block/line content that triggers it, and what the
observed failure actually looks like (a `?` + `ABORT`? a hang? garbled
output?), plus confirmation this was tried against the *current*
`io-cpm.azm`/`io-multi.azm` (post the `BLKBUF`/multi-sector-loop changes
above) rather than an older build. **When a concrete failing case is
available, the harness technique documented above (real compiled `LOAD`,
synthetic canned block content, breakpoints at address `0` / `ABORT`) is the
fastest way to pin it down** — reproduce the exact reported block content in
the harness first, *then* start varying it, rather than guessing at
plausible-sounding variations as this session did.

### Outstanding / follow-up items noted during this session (not yet done)

- `camel80.azm`'s `COLD` unconditionally calls `puts`/`introdump`
  (debug/banner helpers), but those are only *defined* in `io-multi.azm`,
  not `io-cpm.azm` — a `-D CPM` assembly currently fails to link unless
  those two lines are commented out first. This is a pre-existing gap in the
  `IFDEF CPM` separation (flagged in-source: "XXX - this needs to move to a
  different file with all of the platform specific code in one spot"), not
  something fixed this session (worked around for testing by temporarily
  stubbing the two lines). Needs a real fix before a clean `-D CPM` build is
  possible without hand-patching.
- The CP/M build's `reset::` sizes the parameter/return stacks and user area
  off a hard-coded `$ENDADDR EQU 8000h` (`camel80.azm`), rather than probing
  CP/M's actual reported top-of-TPA via memory location `0006h`/`0007h` (the
  standard CP/M convention, and what the *embedded* build's `IFDEF
  $ENDADDR`/`ELSE` branch implies is the "normal" non-fixed-address path).
  This is yet another instance of the same "hand-picked `8000h`" pattern
  already fixed twice above (`BLKBUF`, `blocks.fth` `FIRST`/`LIMIT`) — worth
  applying the same treatment here if/when CP/M systems with a smaller TPA
  need to be supported, or if dictionary growth ever approaches `8000h`.
- `forth/blocks/01-utils.fth` line 4 is 65 characters (one over the 64-column
  block-screen limit) — see above. `make -B forth.blk` (full from-scratch
  rebuild) currently fails on this file; incremental `make forth.blk` works
  because the pre-built `01-utils.blk` is reused. Should be fixed (trim one
  character) before anyone next needs a truly from-scratch `forth.blk`
  rebuild.
- `forth/blocks/10-editor.fth`'s `ZZZ` working buffer (and the larger
  `PADDR`-based buffers built on it in later editor screens) still isn't
  `ALLOT`-protected — see "Not fully fixed / follow-up for later" above.

## Session update — custom FORTH `NEXT` instruction finalized (`ED 92`)

### Z-80 custom FORTH `NEXT` instruction (`ED 92`) — implemented, working

The CamelFORTH `NEXT` primitive is now a single custom Z-80 instruction,
`ED 92`.  An earlier attempt used a different `ED` slot and did not behave
correctly; it was removed and replaced by this `ED 92` implementation
(HDL and software together).  Nothing in the current design depends on the
abandoned encoding.

**Why `NEXT`.**  CamelFORTH is direct-threaded: every word in the dictionary
ends with a stub that fetches the address of the next word, advances the
interpreter pointer, and jumps.  That stub is the `NEXT` macro and it runs
once per word step, so a large fraction of both CPU time and dictionary byte
count is spent on it.  Register allocation is `BC`=TOS, `HL`=W (volatile
working register), `DE`=IP, `SP`=PSP, `IX`=RSP, `IY`=UP.

**Standard macro** (stock Z80, still in the source for portability):

```
; entry: DE = IP, HL = W
ex de,hl    ; DE = W (stashed), HL = IP — need IP to fetch
ld e,(hl)   ; E  = (IP)      low byte of next cell
inc hl      ; HL = IP + 1
ld d,(hl)   ; D  = (IP + 1)  high byte of next cell
inc hl      ; HL = IP + 2
ex de,hl    ; DE = IP + 2 (new IP), HL = next cell
jp (hl)     ; PC <- HL  (register value, no memory access)
```

Two points: `JP (HL)` loads the *value already in* HL into PC — it does not
dereference memory — so the sequence's real job is to get the 16-bit cell
into HL with the side effect of leaving the advanced IP in DE.  The two
`EX DE,HL` are pure register shuttling: HL must hold the IP while fetching,
then hold the cell so `JP (HL)` can jump on it, and DE must end as the new
IP.

**Custom operation.**  The instruction does the essential kernel of the
macro and nothing else:

```
PC <- (DE)        ; 16-bit read of the cell at the IP
DE <- DE + 2      ; advance the interpreter pointer
```

Flags are untouched and `HL` is not written.  Because `HL` is a volatile
working register here, `NEXT` has no obligation to leave the cell in it —
dropping that requirement is what lets the instruction stay small (a 16-bit
read plus a jump, not a read, a register load, and a jump).  Net effect: one
instruction and two bytes instead of seven at the hottest point in the
system, so the dictionary is smaller and per-step dispatch is cheaper.

### VHDL side (`Components/Z80/T80_MCode.vhd`)

The core is T80; the ISA is defined entirely by a microcode table that, per
opcode, emits a bundle of control signals (address-unit select,
register-file writes, ALU op, jump/call strobes) for each machine cycle.
Adding an instruction means adding one decode arm composed of signals the
core already has.  The arm sits in the `ED`-prefixed case next to
`RETI`/`RETN`, which it closely resembles since both load the PC from bytes
just read from memory:

1. Carve `0x92` out of the OR-list of "undefined ED opcode" arms and give it
   a dedicated arm.
2. Machine cycle 1 (the `ED` second-byte fetch): point the address unit at
   DE (`Set_Addr_To <= aDE`) so the data reads come from the IP.
3. Machine cycle 2: read the cell's low byte into the W/Z temporary area
   (`LDZ`) and, at end of cycle, increment DE by one via the shared 16-bit
   increment/decrement unit.
4. Machine cycle 3: read the high byte into the same area (`LDW`) and fire
   the ordinary `Jump` strobe (the one `RET`/`RETI` use) to latch PC from
   the freshly-read byte pair, with no register-file read hazard; DE is
   incremented a second time, ending as `DE + 2`.

Three machine cycles, two memory reads, standard jump path.  Only pre-existing
control signals are driven, so synthesis treats it like any other opcode — a
few extra rows of decode logic.  No other core file changes and the core's
port interface is untouched.

### CamelFORTH side

The change is a build-time switch so the *same kernel source* still assembles
for a stock Z80.  In `forth/camel80.azm` the `next` macro is wrapped in
`IFDEF CUSTNEXT`:

```
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

- **`ENTER` (the `DOCOLON` entry point)** is re-plumbed for the custom build.
  Stock FORTH does `pop hl` + the `nexthl` variant because stock `NEXT` gets
  its target from HL.  Since the custom instruction reads its target from DE,
  the CUSTNEXT build does `pop de` + `next` — the parameter-field address is
  popped straight into the IP register and HL stays free for the word that
  follows.
- **The build system** keeps two kernel variants side by side: the Makefile
  assembles `camel80.bin` without the define (stock macro, plain Z80) and
  `camelf.bin` with `-D CUSTNEXT=1` (custom instruction, FPGA core).  The boot
  banner picks up a `", with custom NEXT instruction"` suffix in the custom
  build so the running kernel is identifiable at a glance.

### Results

Preliminary on-board timing shows FORTH code completing roughly **20%
faster** than the same code under the stock macro, and the custom build is a
noticeably more compact image.  `NEXT` runs on every word step, so its cost
is multiplied by program length; collapsing it buys back both execution time
and dictionary space at once.


## Session update — custom return-stack instructions `PUSHIX`/`POPIX`

### Summary

Two families of custom Z-80 instructions were added to the T80 core to
accelerate CamelFORTH's return stack, which lives in memory addressed by `IX`
(RSP) and grows downward, with `IX` pointing at the low byte of the top
item:

| Instruction | Encoding | Operation | T-states | Bytes |
|---|---|---|---|---|
| `PUSHIX BC` / `DE` / `HL` | `ED C5` / `ED D5` / `ED E5` | `(IX-1) <- high`, `(IX-2) <- low`, `IX <- IX-2` | 14 | 2 |
| `POPIX BC` / `DE` / `HL`  | `ED C1` / `ED D1` / `ED E1` | `low <- (IX)`, `high <- (IX+1)`, `IX <- IX+2` | 14 | 2 |

Each replaces a four-instruction stock sequence of 58 T-states and 10 bytes:

```
; stock push of DE              ; stock pop of DE
dec ix          ; 10 T          ld e,(ix+0)     ; 19 T
ld (ix+0),d     ; 19 T          inc ix          ; 10 T
dec ix          ; 10 T          ld d,(ix+0)     ; 19 T
ld (ix+0),e     ; 19 T          inc ix          ; 10 T
```

Flags and `A` are untouched; no register other than the target pair and `IX`
is written.  The memory image is exactly what the stock sequences produce,
so custom and stock code — and the `(IX+d)`-based words `R@`, `I`, `J`,
`(loop)`, `UNLOOP` — can be freely mixed on the same return stack.

### Design considerations

**Encoding: `ED` space rather than `DD`.**  The initial idea was to place the
instructions in the `DD`-prefixed (IX) space, e.g. `DD C0`–`DD CA`.  That was
rejected after studying how T80 handles the `DD` prefix:

1. *The microcode cannot see a `DD` prefix.*  `DD` only sets the internal
   `XY_State` register; the opcode is then decoded by the **unprefixed**
   table (`ISet = "00"`).  `T80_MCode` has no input that distinguishes
   `DD C0` from plain `C0` (`RET NZ`), so a new port would be needed and
   every `DD xx` slot would have to be carved out of an existing unprefixed
   instruction's arm.
2. *`DD` silently remaps `H`/`L` to `IXH`/`IXL`.*  While `XY_State /= "00"`,
   `T80.vhd` redirects every register-file access to H or L onto IX (this is
   what makes the undocumented `LD IXH,n` etc. work).  `PUSHIX HL` would
   therefore push IX instead of HL unless that logic were special-cased.
3. *`DD` + "address from HL" means `(IX+d)`.*  `Set_Addr_To = aXY` under a
   `DD` prefix automatically inserts the displacement-fetch machine cycle —
   the opposite of what a stack operation wants.

The `ED` page has none of these problems: it has its own fully decoded
microcode table (`ISet = "10"`), `XY_State` is cleared, and the slots chosen
were previously in the "undefined ED opcode" list.  On a real Z-80 (and on
earlier versions of this core) those opcodes execute as 2-byte NOPs, which
is what makes the runtime CPU check (below) possible.  The encodings mirror
`PUSH qq`/`POP qq` (`C5/D5/E5`, `C1/D1/E1`): opcode bits 5:4 select the
register pair, so the microcode reuses the same `DPAIR` decode.  The `AF`
slots (`ED F5`/`ED F1`) are deliberately left undefined (still NOPs).  This
is the same page as the custom `NEXT` (`ED 92`), so all of the project's
custom Forth instructions now live in one place.

**Datapath: two small additions to T80.**  The core had no way to (a) put
`IX` on the address bus *without* a displacement, nor (b) increment or
decrement `IX` outside of `DD` mode (the 16-bit inc/dec unit selects BC, DE,
HL or SP; it only reaches IX via the `XY_State` remap).  Both were added
with minimal, isolated changes:

- **New address source `aIX`** (`Set_Addr_To = "011"`, an encoding that was
  previously unused).  In `T80.vhd` it forces the register-file read port C
  (`RegAddrC`) to register 3 (IX), and the address latch takes `RegBusC`
  just as it does for `aBC`/`aDE`.  Note that it is hard-wired to `"011"`,
  **not** `Alternate & "11"`: the register file holds BC/DE/HL at 0–2, IX at
  3, the alternate BC'/DE'/HL' at 4–6 and IY at 7, so using the `EXX` bank
  bit would select IY whenever the alternate bank is active.  (This exact
  bug was injected as a mutation test and is caught by the testbench.)
- **New microcode output `IncDec_IX`.**  When asserted together with
  `IncDec_16 = "x110"` (the HL code) it redirects the inc/dec unit's
  register-file port (`RegAddrA`) to IX.  The existing write-enable,
  `ID16` adder and `Wait_n` gating are reused unchanged.

`T80_MCode.vhd` gained the two decode arms, the `aIX` constant and the
`IncDec_IX` port (default `'0'`); `T80_Pack.vhd` the matching component
port.  The `T80`/`T80s` external interface is unchanged.

**Timing: 14 T-states, 4/4/3/3.**  `PUSH qq` needs a 5-T opcode fetch
because SP is a separate register updated at T4.  IX lives in the register
file, whose inc/dec happens at T3 of M1, so the first decrement is complete
before the address is latched at the end of T4 and M1 stays at the default
4 T.  Sequence for `PUSHIX`: M1 (`ED`, 4 T) → M1 (opcode, 4 T: `IX--`,
`A <- IX`) → M2 (3 T: write high, `IX--`, `A <- IX`) → M3 (3 T: write low).
`POPIX` is the mirror image, with register writes happening through the
normal `Read_To_Reg` path exactly as in `POP qq`.  This matches the custom
`NEXT`, which is also 14 T.

**Other properties checked.**
- *Flags:* the ED arms leave `ALU_Op` at its default `0 & IR(5:3)`
  (`0000`/`0010`/`0100`, never the `1001` that forces a flag update) with
  `Save_ALU = '0'`, and the `Z16` path is not triggered, so F is untouched.
- *Interrupts:* T80 never accepts an interrupt between a prefix and its
  opcode, so each instruction is atomic.
- *Wait states:* the IX update happens once per machine cycle regardless of
  how long `WAIT_n` is held (verified with random wait states — relevant
  because this board inserts waits for SDRAM).
- *`EXX`:* the pushed/popped pair comes from whichever bank is current; IX is
  not banked.

### Comparison with the standard CamelFORTH code

T-state figures below were **measured on the T80 core in simulation** for
every sequence involving the custom instructions, `NEXT`, `CALL`, `POP` and
`PUSH`; they match the Zilog datasheet exactly.  (Correction to the `ED 92`
notes above and in the commit message: the stock `NEXT` macro is **38 T**,
not 40 T; `nexthl` is 34 T.)  The remaining instructions in `(do)` use
datasheet values.  Each primitive's cost includes its own trailing `NEXT`;
`ENTER` and `DODOES` include the 17 T `CALL` from the word's code field.

| Primitive | Stock Z-80 | Custom `NEXT` only | `NEXT` + `PUSHIX`/`POPIX` | vs. `NEXT` only |
|---|---:|---:|---:|---:|
| `ENTER` (docolon) | 119 T | 99 T | **55 T** | −44 % |
| `EXIT` | 96 T | 72 T | **28 T** | −61 % |
| `>R` | 106 T | 82 T | **38 T** | −54 % |
| `R>` | 107 T | 83 T | **39 T** | −53 % |
| `DODOES` | 152 T | 128 T | **84 T** | −34 % |
| `(do)` | 241 T | 217 T | **129 T** | −41 % |

The figure that matters most is the overhead of calling a colon definition:
the `NEXT` that dispatches to it, `ENTER`, the `NEXT` that dispatches to its
`EXIT`, and `EXIT` itself (the definition's body is excluded):

| | Stock Z-80 | Custom `NEXT` only | `NEXT` + `PUSHIX`/`POPIX` |
|---|---:|---:|---:|
| Colon call + return overhead | 291 T | 199 T | **111 T** |
| relative to stock | 100 % | 68 % | **38 %** |

So the return-stack instructions remove 88 T from every high-level call on
top of what the custom `NEXT` already saved: colon-call overhead drops to
about 56 % of the NEXT-only build and 38 % of the stock build.  Since
`ENTER`/`EXIT` run once per call of every colon definition, code built from
many small definitions (idiomatic Forth) benefits most; tight loops of code
primitives benefit mainly from `NEXT`.

Code size: each converted site shrinks from 10 bytes to 2.  Seven sites were
converted (`EXIT`, `ENTER`, `DODOES`, `>R`, `R>`, and both pushes in
`(do)`), saving 56 bytes of kernel.

Not converted, because they *peek* or *modify in place* rather than push or
pop: `R@` (`ld c,(ix+0)` / `ld b,(ix+1)`, 38 T), `I`, `J`, `(loop)`/`(+loop)`
(read-modify-write of the index via `(IX+d)`) and `UNLOOP` (four `inc ix`,
40 T).  These are candidates for further instructions (e.g. a non-popping
"fetch top of return stack" or `IX += 4`) if profiling shows they matter.

### CamelFORTH changes (`forth/camel80.azm`, `forth/Makefile`)

- **`CUSTRSP` build define.**  New macros `rpushbc`, `rpushde`, `rpushhl`,
  `rpopbc`, `rpopde`, `rpophl` expand to the custom 2-byte instructions when
  `CUSTRSP` is defined, and to the original stock four-instruction sequences
  otherwise.  The stock, CP/M and NEXT-only kernels assemble
  **byte-identical** to the previous build without the define (verified by
  binary comparison).  `rpophl` is defined for completeness but currently
  unused: no kernel code pops the return stack into HL (the `HL` loads in
  `(loop)`, `I` and `J` read the loop parameters in place with `(IX+d)`).
- **um80 listing quirk** (found while checking `rpophl`): on a line that has
  both a label and a multi-line macro call, the `.prn` listing shows the
  address of the macro's *last* expanded instruction, not the label's.  The
  label's actual value (in the symbol table) and the generated code are
  correct.  Use the `.sym` file, not the listing, to find label addresses.
- **Makefile:** `camelf.bin` is now assembled with
  `-D CUSTNEXT=1 -D CUSTRSP=1`.  **It requires an FPGA core containing the
  new instructions.**  `camel80.bin` (stock) is unchanged.
- **Boot banner** adds `", with custom PUSHIX/POPIX instructions"`.
- **Startup CPU check.**  When either `CUSTNEXT` or `CUSTRSP` is defined
  (helper symbol `CUSTCPU`), `reset::` verifies, right after the stacks and
  IX/IY are set up, that the CPU really implements the instructions the
  kernel was built for:
  - `NEXT`: `ld de,cpuck1` / `ED 92` must jump through the table entry;
    falling through means `ED 92` executed as a NOP.
  - `PUSHIX`/`POPIX`: with BC=0 and DE=1234h, `PUSHIX DE` / `POPIX BC` must
    leave BC=1234h.

  On failure a message naming the missing instruction(s) is printed; the
  CP/M build then exits with `jp 0` (warm boot) and the standalone build
  disables interrupts and halts (looping on `HALT` so an NMI cannot restart
  it).  Cost: about 230 bytes, mostly message text; non-custom builds are
  unaffected.  Verified in simulation (table below); the CP/M exit path
  assembles but has not been run, because the simulator provides no CP/M
  environment.

  | Core | Kernel | Result |
  |---|---|---|
  | new (this work) | NEXT + PUSHIX/POPIX | passes, boots, `1 2 3 + + .` → `6 ok`, `: SQ DUP * ; 7 SQ .` → `49 ok` |
  | new | PUSHIX/POPIX only, NEXT only | passes, boots |
  | previous (`ED 92` only) | NEXT + PUSHIX/POPIX | prints PUSHIX/POPIX message, halts |
  | previous | NEXT only | passes, boots |
  | original stock T80 | NEXT only, NEXT + PUSHIX/POPIX | prints NEXT message (first check to fail), halts |

### Verification (GHDL, `sim/`)

- **`sim/run_ixmin.sh`** (`tb_ixmin.vhd`) — minimal, one instruction per
  case: a tiny hand-assembled program sets registers, executes a single
  custom instruction and halts; registers are checked via the core's `REG`
  debug output (read with a VHDL-2008 external name, because `T80s` leaves
  that port unconnected) and stack bytes in RAM.  10 cases: each of the six
  instructions, other pairs left untouched, AF preserved by push and pop,
  and a push/pop round trip.  All pass on the new core; as a control, the
  same test run against the previous core (where these opcodes are NOPs)
  fails in exactly the expected way.
- **`sim/run_ixstack.sh`** (`tb_ixstack.vhd`/`.asm`) — broader regression:
  59 result bytes covering all pairs, flags, back-to-back use, the `EXX`
  bank, `POPIX DE` immediately followed by `NEXT` (the `EXIT` path), IX
  wrap-around at 0000h, stock `(IX+d)`/`INC IX`/`PUSH`/`POP` still working,
  IY/SP untouched and `ED F5`/`ED F1` still NOPs; M1-to-M1 timing checks
  (14 T each); and three runs with pseudo-random `WAIT_n` states.  Two
  injected faults (wrong IX register select under `EXX`; IX inc/dec
  disabled) were both caught.
- **`sim/tb_forth.vhd`** — boots a real kernel image with an emulated ACIA
  console (ports 82h/83h) and feeds it Forth source.  Used for the
  CPU-check matrix above.  It simulates only about 27 k CPU clocks/s and one
  interpreted line costs 1–2 M clocks (mostly dictionary search), so
  `sim/run_forth.sh`, which runs a long script on three kernels, needs a
  much shorter script before it is practical; it should not yet be treated
  as a benchmark.

### Status / next steps

- HDL simulated and verified as above.  **Built and run successfully on
  hardware:** the new FPGA core with the `camelf.bin` kernel (custom `NEXT`
  + `PUSHIX`/`POPIX`) works on the board.
- Benchmark on the board: `camel80.bin` vs a NEXT-only build vs `camelf.bin`,
  ideally on a call-heavy word (e.g. recursive `FIB`) and a primitive-heavy
  loop, to compare with the per-primitive figures above.
- Possible follow-ups: non-popping return-stack fetch for `R@`/`I`, and
  `IX += 4` for `UNLOOP`/`(loop)` termination.

---

## Session update — SDRAM reliability fixes and project timing constraints

Follows the independent review in `SDRAM-review-handoff.md` (which
supersedes the diagnosis and the four "proposed speculative fixes" in
`SDRAM-bug-handoff.md` and in the section of that name above — **do not
apply those**). Starting symptoms: `sdramexec.bin` passed when loaded into
block RAM but, like `camel80.bin`/`camelf.bin`, printed one or two garbage
characters and hung when loaded into **SDRAM**.

### Wait-line release phase guard (`MicrocomputerZ80CPM.vhd`) — commit `5be2112`

Root cause of the hang and of the old intermittent `sdramexec` `got=C4`
(the "Wait-line phase race ... (OPEN)" section above — now **resolved**).
The T80 is clocked by `cpuClock`, a register dividing `clk` by 5 that is
promoted to a global clock; it rises on the `clk` edge where (old)
`cpuClkCount = 2`. When the SDRAM client FSM released `sdram_wait_n` in
`S_DONE` on that same edge, individual T80 flip-flops (TState, IR/DI_Reg
load, PC, strobes) could capture a mixture of `Wait_n = 0` and `1`
(fast-corner hold violations up to -4.1 ns) — a mis-executed instruction.
Roughly 1 in 5 SDRAM accesses released on that edge, so code running
entirely from SDRAM crashed almost immediately. Fix: in `S_DONE`, release
only when `cpuClkCount /= "000010"` (at most one extra `clk`). The earlier
reverted `cpu_wait_n_sync` attempt released on exactly this edge (the
rise is at 2→3, not 1→2 as previously assumed).

Result on hardware: `sdramexec` passes from both block RAM and SDRAM;
`camelf.bin` starts from SDRAM.

### T80 INI/IND/INIR/INDR and OUTI/OUTD/OTIR/OTDR never updated HL (`T80_MCode.vhd`) — commit `93e13c8`

Real core bug present since the initial commit (Wallner 0242): MCycle 3
used `IncDec_16 = "0010"/"1010"`, and `T80.vhd` only writes the
incremented value back when bit 2 is set, so HL never changed. Ported the
upstream "0240mj1" fix (`"0110"/"1110"`). This — plus stale block-RAM
contents from earlier runs — fully explains `backtoback.asm` A2/A3's "one
mismatch at offset 0, got=FF" and `sim/STATUS.md`'s "HL never increments"
blocker (now marked resolved). The GHDL testbench (`sim/run.sh`) reports
0 mismatches with the fix. `forth/io-multi.azm` still uses the explicit
`IN`/`LD (HL)`/`INC HL` loops ("slower INIR to avoid SDRAM problem"); they
can go back to `INIR`/`OTIR`.

### SDRAM refresh starvation (`Components/SDRAM/sdram2.sv`) — commit `c4786c1`

`sdramsum.bin` showed that the image loaded into SDRAM was intact (the
only in-image difference, block 15, is `COLD` storing `BLKBUF`), yet
`camelf.bin` became corrupted after a lot of processing from SDRAM. Cause:
each refresh toggled the shared `chip` select, but every CPU access reloads
`chip` from `addr[26]`; with code running from device 0, `chip` was always
0 before each refresh, so every refresh went to device 1 and device 0 was
**never refreshed** (and each device was refreshed only every ~16 µs at
best). Fix (all `LOCAL MOD`):

- a dedicated `refresh_chip` toggle and a `STATE_REFRESH` state issue the
  AUTO_REFRESH to alternating devices independent of CPU traffic;
- `REFRESH_INTERVAL = 350` `clk_ram` cycles (3.62 µs at 96.67 MHz), so
  each device is refreshed every ~7.2 µs (< 7.8 µs required); refresh has
  priority over a pending request;
- `STATE_DLY3`/`STATE_DLY4`: two extra recovery cycles after every access
  so the next ACTIVE/AUTO_REFRESH cannot reach a bank still in write
  recovery + auto-precharge (tDAL). Read/write ready timing is unchanged.

Verified with the new `testing/sdramret.asm` (below): the previous core
shows retention errors, the fixed core runs every round with
`errors=0000`. CamelFORTH (stock and custom-instruction kernels) then ran
the benchmark from SDRAM successfully over multiple runs.

### New diagnostics — commit `988ae33`

- `testing/sdramsum.asm` + `testing/binsums.py`: per-256-byte checksums,
  re-read check and hex dump of SDRAM page 0, to compare an OSD-loaded
  image (SDRAM is not cleared by a later download) against the `.bin` on
  the host.
- `testing/sdramret.asm`: fills 256 KB of device 0, hammers another
  device-0 page (the starvation trigger) for ~0 s / 1 s / 9 s / 70 s /
  280 s, then verifies and prints error counts and the first failures.
- `sim/`: the GHDL INIR testbench, `run.sh` now assembling with
  `tools/z80asm.sh` (um80/ul80) instead of pasmo.

### Project timing constraints (`MultiComp.sdc`)

New project-level SDC, added to `MultiComp.qsf` after `sys/sys.qip` so it
is read after `sys/sys_top.sdc` (which must not be edited). It:

- defines `cpuClock` as generated clock `cpuClk` (`-edges {1 7 11}` on the
  `clk_sys` PLL output: period 100 ns, high 60 / low 40), so every path
  into and out of the T80 is now analysed;
- relaxes the `clk_sys` → `cpuClk` **hold** check by one `clk_sys` period
  (`-hold -start 1`) only for registers that provably never change on the
  `cpuClk` rising edge: `sdram_wait_n` (phase guard above),
  `sdramReadData` (only loaded while wait is asserted), the MMU
  `mmu_frame`/`direct_access_pointer`/`was_map_io_to_direct`, `fpLatch`,
  and the block RAM / boot ROM internal registers;
- `cpuClk` → block RAM / boot ROM: `set_multicycle_path -setup -end 4 /
  -hold -end 3` (address stable from T1, data used ≥ 1 cpuClk period
  later; writes are repeated every `clk` while `WR_n` is low, so the last
  write of the window stores settled data);
- false paths for the front-panel capture chain (display only), the
  quasi-static `bin_loaded`/`status[13]`, the `MultiComp.sv` SDRAM CDC
  (`req_sync[0]`, `ram_addr`/`ram_din`/`ram_rnw`, `done_sync[0]`,
  `ram_byte` → `clk_sys`) and `reset_from_mount` → SDRAM controller init.

Deliberately **not** relaxed: peripheral read registers (`sd_controller`
data/status, `FrontPanel_Subsystem` dout, ...) can change on any `clk`
edge, so an `IN` can race the T80 capture. These are real; with the
constraints in place the fitter now pads them and hold is met at all
corners, but the clean fix is the clock-enable conversion
(`REQUIREMENTS.md` item 4).

Result (all four corners): **hold met everywhere; setup met everywhere
except the pre-existing `SBCTextDisplayRGB` `startAddr` → attribute-RAM
path** (-2.5 ns, slow corners; "Known issues" above — a real violation,
left visible on purpose). Before: clk_ram -10.5 / -390 ns TNS and clk_sys
-8.9 ns, dominated by false CDC paths, with all T80 paths unanalysed.
Still unconstrained (pre-existing ripple/glitch clocks, harmless warnings
332060): `T80s|IORQ_n` (clocks `n_RomActive` and a UART register via
`n_ioWR`) and `serialClkCount[15]` (UART baud clock).

### Performance note

CamelFORTH benchmark: block RAM 13.0 s vs SDRAM 19.3 s (stock kernel);
9.0 s vs 13.4 s with the custom `NEXT`/`PUSHIX`/`POPIX` instructions —
SDRAM costs ~30%. Accepted for now; see `REQUIREMENTS.md` item 4 (T80
clock-enable conversion and/or an SDRAM cache).

---

## Session update — benchmark timer peripheral (`BenchTimer`, ports 0xC0-0xCF)

Added so the CamelFORTH block-RAM vs SDRAM benchmark (and the coming
clock-enable / cache work, `REQUIREMENTS.md` item 4) can be timed by the
machine instead of with a stopwatch.

- `Components/TIMER/BenchTimer.vhd`: free-running 32-bit µs and ms
  counters from the 50 MHz `clk` (µs prescaler /50, ms = 1000 µs), with
  power-up initial values only — no reset input, so they are monotonic
  across CPU/OSD resets. Four channels, four ports each: ch0 `C0-C3` and
  ch1 `C4-C7` latch the ms counter, ch2 `C8-CB` and ch3 `CC-CF` the µs
  counter. `OUT` (any data) to any port of a channel snapshots it once, on
  the first `clk` of the write strobe; `IN` returns the snapshot byte
  `addr(1:0)` (little-endian) with no side effects.
- Design choice: one port per byte rather than a single port with an
  auto-incrementing byte pointer, or a control/data port pair. A hidden
  pointer can be desynchronised by a second user (interrupt handler,
  monitor) with no indication; per-byte ports make reads idempotent and
  order-independent, and independent channels let separate programs time
  things concurrently. A shared "latch several channels at once" mask
  register was considered and dropped in favour of a fourth channel.
- Wired into `MicrocomputerZ80CPM.vhd` (`n_timerCS`, `timer1`,
  `cpuDataIn` mux), `MultiComp.qsf`, `sim/run.sh`. `MultiComp.sdc`: the
  snapshot registers (`BenchTimer:timer1|snap*[*]`) join the
  `-hold -start 1` list — they change only on the first `clk` after a
  `cpuClk`-launched write strobe, like `fpLatch`. (First build used an
  array signal, which Quartus flattened to `snap~N` names that the SDC
  filter did not match; now four separate signals.)
- Verified: GHDL unit test (ms/µs values, re-read stability, 1000 µs per
  ms); `sim/run.sh` unchanged (0 mismatches); full build OK, ~143 ALUTs /
  209 registers; setup unchanged apart from the known `SBCTextDisplayRGB`
  path.
- Timing note: this placement shows small clk_sys → clk_sys **hold**
  violations at the slow -40 °C corner only (worst -0.144 ns:
  `done_seen` → `sdram_state`, `dl_bram_addr_r` → block-RAM `we_reg`,
  `bin_loaded`/`reset_from_mount` → `mmu_frame`), none involving the
  timer. They are placement-dependent (absent in the previous build): the
  compile flow only analyses the slow 100 °C model, so the fitter does not
  close hold at every corner. Candidate fix: enable multi-corner
  optimisation/analysis in `MultiComp.qsf`.
- `testing/timertest.asm`: prints all four channels, checks re-read
  stability and that the µs counter strictly increases over 4096
  snapshots, calibrates 1000 ms against the µs counter three times
  (PASS within ±200 µs), and prints its own run time. Hardware test
  pending.
- Port map documented in `HARDWARE.md` (the `IOPORTS.md` references in
  `REQUIREMENTS.md` now point there — that file was renamed earlier).

### CamelFORTH `MS@` and `US@`

`forth/io-multi.azm` (embedded kernels only; `io-cpm.azm` has no timer):
`MS@ ( -- ud )` latches BenchTimer channel 0 (port `C0`) and `US@
( -- ud )` channel 2 (port `C8`), reads the four latched bytes with
immediate-port `IN A,(n)` and leaves the 32-bit count as a double (low
cell below, high cell on top; HL/A scratch only, DE/IX/IY preserved).
Channels 1 and 3 stay free for application use. Verified under GHDL with
a copy of `sim/tb_forth.vhd` that emulates ports `C0-C3`/`C8-CB` (known
ms = `A1B2C3D4`, us = `01020304`): correct cell order, old TOS preserved,
`DEPTH` 0 after use, on both `camel80.bin` and `camelf.bin`. The kernel
still has no `D+`/`D-`/`UD.`, so computing and printing an elapsed time
needs small helper words (see `REQUIREMENTS.md` item 5).

`forth/blocks/27-bench.fth` now carries the double-cell helpers the kernel
lacks (it must fit one 16 x 64 block): `D+` (`>R M+ R> +`, using the
kernel's unsigned `M+`), `D-` (`DNEGATE D+`), `UD.`, `timed`/`utimed`
( xt -- ud ) (elapsed ms/µs of one execution; end minus start as a 32-bit
difference, so correct across a counter wrap) and `times` ( xt n -- )
(prints each run and the total in ms). `bench` is now 50 timed runs of the
existing `outer` loop. Added to `blocks/Makefile` (`forth.blk`). Verified
under GHDL on `camel80.bin` and `camelf.bin` with fake timer ports that
step 500 per latch from `FFFFFE00` (so the difference spans the 32-bit
wrap): `' nop timed UD.` -> 500, `utimed` -> 500, `' nop 2 times` -> 500,
500, total 2500, `DEPTH` 0, BASE restored. (The block is compiled by
`LOAD` as a whole, so `times` may span two lines; the testbench, which
feeds lines one at a time and waits for `ok`, needed that definition joined
onto one line.)

Hardware check: the new kernels (`MS@`/`US@`) and `forth.blk` with the
`27-bench.fth` helpers were run on the MiSTer and work as expected.

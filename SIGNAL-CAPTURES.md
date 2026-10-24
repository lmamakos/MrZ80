# Signal Capture Chain Map

> **Maintenance note:** This table is the authoritative reference for the
> capture-chain bit allocation. Whenever the chain in `MicrocomputerZ80CPM.vhd`
> is modified or extended — a segment added, removed, or re-ordered, a signal
> swapped, or a signal's width changed — update this table in the same change
> and keep it current.

The `MicrocomputerZ80CPM` core captures live system state onto a single
292-bit serial capture chain (`chain_out` of the last segment feeds
`FrontPanel_Subsystem`, `CHAIN_BITS => 384`). The subsystem samples the
chain on every refresh tick and the loaded bit values can be routed to the
WS2812/SK6812 LEDs through a front-panel profile LED map.

*Bit numbering:* chain bit 0 is the MSB of the first segment (closest to
`FrontPanel_Subsystem`); segment numbers increase toward the far end of the
daisy chain. Within a segment the source vector's MSB occupies the lowest
chain bit (e.g. `cpuAddress(15)` is chain bit 8). Multi-bit buses are
listed as one row; individual control signals each get their own row.

Segments, in daisy-chain order toward the output:
`fpChainEnd` → `fpChainCPUctl` → `fpChainPhysAddrBus` → `fpChainRegs` →
`fpChainStaticTest` → `fpChain` → `FrontPanel_Subsystem`.

## Capture bit table

| Start | End | Width | Signal | Source | Segment | Notes |
|------:|----:|------:|--------|--------|----------------------|-------|
| 0 | 7 | 8 | `fpLatch[7:0]` | I/O port `$FF` write latch | `fpChain` | Software-visible data latch; `fpLatch(7)` = bit 0. |
| 8 | 23 | 16 | `cpuAddress[15:0]` | Z-80 address bus | `fpChainStaticTest` | Live address bus; `A15` = bit 8. |
| 24 | 31 | 8 | data bus `D[7:0]` | `cpuDataIn` when `n_WR = '1'`, else `cpuDataOut` | `fpChainStaticTest` | Bus contents during reads/idle; CPU-driven value during writes. `D7` = bit 24. |
| 32 | 39 | 8 | `A` | T80 `REG` | `fpChainRegs` | Current register set. |
| 40 | 47 | 8 | `F` | T80 `REG` | `fpChainRegs` | Flags. |
| 48 | 55 | 8 | `A'` | T80 `REG` | `fpChainRegs` | Alternate bank. |
| 56 | 63 | 8 | `F'` | T80 `REG` | `fpChainRegs` | Alternate bank. |
| 64 | 71 | 8 | `B` | T80 `REG` | `fpChainRegs` | |
| 72 | 79 | 8 | `C` | T80 `REG` | `fpChainRegs` | |
| 80 | 87 | 8 | `B'` | T80 `REG` | `fpChainRegs` | Alternate bank. |
| 88 | 95 | 8 | `C'` | T80 `REG` | `fpChainRegs` | Alternate bank. |
| 96 | 103 | 8 | `D` | T80 `REG` | `fpChainRegs` | |
| 104 | 111 | 8 | `E` | T80 `REG` | `fpChainRegs` | |
| 112 | 119 | 8 | `D'` | T80 `REG` | `fpChainRegs` | Alternate bank. |
| 120 | 127 | 8 | `E'` | T80 `REG` | `fpChainRegs` | Alternate bank. |
| 128 | 135 | 8 | `H` | T80 `REG` | `fpChainRegs` | |
| 136 | 143 | 8 | `L` | T80 `REG` | `fpChainRegs` | |
| 144 | 151 | 8 | `H'` | T80 `REG` | `fpChainRegs` | Alternate bank. |
| 152 | 159 | 8 | `L'` | T80 `REG` | `fpChainRegs` | Alternate bank. |
| 160 | 175 | 16 | `IX` | T80 `REG` | `fpChainRegs` | MSB first (`IXH` = bit 160). |
| 176 | 191 | 16 | `IY` | T80 `REG` | `fpChainRegs` | |
| 192 | 207 | 16 | `PC` | T80 `REG` | `fpChainRegs` | |
| 208 | 223 | 16 | `SP` | T80 `REG` | `fpChainRegs` | |
| 224 | 251 | 28 | `mmu_phys_addr[27:0]` | MMU physical address output | `fpChainPhysAddrBus` | Translated physical address; bit 27 = bit 224. Bit 27 set ⇒ block-RAM page, clear ⇒ SDRAM. |
| 252 | 252 | 1 | `/WR` (active-high) | `not n_WR` from T80 | `fpChainCPUctl` | Lit = write strobe asserted. |
| 253 | 253 | 1 | `/RD` (active-high) | `not n_RD` from T80 | `fpChainCPUctl` | Lit = read strobe asserted. |
| 254 | 254 | 1 | `/INT` (active-high) | `not n_INT` | `fpChainCPUctl` | CPU interrupt input; currently tied inactive (`n_INT = '1'`). |
| 255 | 255 | 1 | `/NMI` (active-high) | `not n_NMI` | `fpChainCPUctl` | Currently tied inactive. |
| 256 | 256 | 1 | `/BUSRQ` (active-high) | `not n_BUSRQ` | `fpChainCPUctl` | Currently tied inactive. |
| 257 | 257 | 1 | `/M1` (active-high) | `not n_M1` from T80 | `fpChainCPUctl` | Lit = opcode-fetch cycle. |
| 258 | 258 | 1 | `/HALT` (active-high) | `not n_HALT` from T80 | `fpChainCPUctl` | Lit = CPU halted. |
| 259 | 259 | 1 | `/BUSAK` (active-high) | `not n_BUSAK` from T80 | `fpChainCPUctl` | Lit = bus acknowledge. |
| 260 | 279 | 20 | reserved (tied `0`) | `x"0000_0"` | `fpChainEnd` | Unused filler at the far end of the chain. |
| 280 | 280 | 1 | `/WR` (stretched) | `not n_WR` | `fpChainEnd` | Pulse-stretched (see below). |
| 281 | 281 | 1 | `/RD` (stretched) | `not n_RD` | `fpChainEnd` | Pulse-stretched. |
| 282 | 282 | 1 | `/MREQ` (stretched) | `not n_MREQ` | `fpChainEnd` | Pulse-stretched. |
| 283 | 283 | 1 | `/IORQ` (stretched) | `not n_IORQ` | `fpChainEnd` | Pulse-stretched. |
| 284 | 291 | 8 | `fpLatch[7:0]` (echo) | I/O port `$FF` write latch | `fpChainEnd` | Second copy of the port `$FF` latch. `fpLatch(7)` = bit 284. |

Total: **292 bits** (0–291).

## Notes

- **Transparent vs. stretched capture.** All segments except
  `fpChainEnd` are `Transparent_Capture_Chain`: captured bits follow their
  source continuously and are snapshotted by the `latch` pulse. The final
  `fpChainEnd` segment is a `Universal_Capture_Chain` with
  `STRETCH_MASK => x"0000_0F00"` — the `/WR`, `/RD`, `/MREQ`, `/IORQ` bits
  (280–283) hold high for `HOLD_CYCLES` (default 2,500,000 clk ≈ 50 ms at
  50 MHz) after a brief pulse, so short bus strobes remain visible in the
  LED display; the rest of the segment is transparent.
- **Polarity.** Active-low Z-80 control signals are inverted before capture,
  so throughout the chain a **logic 1 = the signal is asserted**.
- **Sampling rate.** The chain is latched on the `FrontPanel_Subsystem`
  refresh tick generated from `fpRefreshCount` (50 MHz / 800,000 = 62.5 Hz).
- **LED reach.** `FrontPanel_Subsystem` is instantiated with
  `NUM_LEDS => 256`, so an identity profile map exposes bits 0–255 only;
  bits 256–291 (upper CPU control signals, reserved filler, and the
  `fpLatch` echo) require a profile that maps them explicitly.
- **Register semantics.** `HL`/`DE`/`BC` are always the *current* register
  set — the T80 swaps the slots in `REG` on `EXX`, so these LED slots show
  whichever bank is active. See `doc/t80_reg_debug_vector.md`.
- The signal chain topology and declarations are documented in
  `MicrocomputerZ80CPM.vhd` (comment block "Capture-chain wiring between the
  front-panel chain segments").

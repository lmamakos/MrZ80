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
| 252 | 252 | 1 | `/WR` (active-high) | `not n_WR` from T80 | `fpChainCPUctl` | Transparent: lights only if the refresh happens to sample the strobe. Stretched copy at 280. |
| 253 | 253 | 1 | `/RD` (active-high) | `not n_RD` from T80 | `fpChainCPUctl` | Transparent. Stretched copy at 281. |
| 254 | 254 | 1 | `/INT` (active-high) | `not n_INT` | `fpChainCPUctl` | The CPU interrupt request (`n_INT <= n_int_itimer and n_int1 and n_int2`: IntervalTimer, video terminal, serial UART), before the SSP single-step mask (see 279). Transparent, so a 20 ms tick is too brief to see; 276-278 are the stretched copies of the individual requests. |
| 255 | 255 | 1 | `/NMI` (active-high) | `not n_NMI` | `fpChainCPUctl` | Currently tied inactive. |
| 256 | 256 | 1 | `/BUSRQ` (active-high) | `not n_BUSRQ` | `fpChainCPUctl` | Currently tied inactive. |
| 257 | 257 | 1 | `/M1` (active-high) | `not n_M1` from T80 | `fpChainCPUctl` | Lit = opcode-fetch cycle. |
| 258 | 258 | 1 | `/HALT` (active-high) | `not n_HALT` from T80 | `fpChainCPUctl` | Lit = CPU halted. |
| 259 | 259 | 1 | `/BUSAK` (active-high) | `not n_BUSAK` from T80 | `fpChainCPUctl` | Lit = bus acknowledge. |
| 260 | 267 | 8 | reserved (tied `0`) | `b"0000_0000"` | `fpChainEnd` | Unused filler at the far end of the chain. |
| 268 | 268 | 1 | `IFF1`              | `dbgReg_IFF1`  | `fpChainEnd` | Z80 IFF1 state |
| 269 | 269 | 1 | `IFF2`              | `dbgReg_IFF2`  | `fpChainEnd` | Z80 IFF2 state |
| 270 | 271 | 2 | `IM`                | `dbgReg_IM`  | `fpChainEnd` | Z80 Interrupt mode (0, 1, 2) |
| 272 | 272 | 1 | `/MREQ` (active-high) | `not n_MREQ` (post-`z80_bus_mux` net) | `fpChainEnd` | Transparent — not in `STRETCH_MASK`, so this is the raw strobe as the 75 Hz refresh samples it. Stretched copy at 282. |
| 273 | 273 | 1 | `/IORQ` (active-high) | `not n_IORQ` (post-`z80_bus_mux` net) | `fpChainEnd` | Transparent. Stretched copy at 283. |
| 274 | 275 | 2 | reserved (tied `0`) | `b"00"` | `fpChainEnd` | Unused filler. |
| 276 | 276 | 1 | `INT_TMR` (stretched) | `not n_int_itimer` | `fpChainEnd` | IntervalTimer (`$D0`-`$D3`) interrupt request. Pulse-stretched. At RomWBW's 50 Hz tick it looks permanently lit (see below). |
| 277 | 277 | 1 | `INT_IO1` (stretched) | `not n_int1` | `fpChainEnd` | ACIA interrupt output of the video terminal (`$80`/`$81`). ANDed into the CPU `INT` pin with the other sources (see 254/279). Dark unless software enables the terminal's receive interrupt. |
| 278 | 278 | 1 | `INT_IO2` (stretched) | `not n_int2` | `fpChainEnd` | ACIA interrupt output of the serial `bufferedUART` (`$82`/`$83`). ANDed into the CPU `INT` pin with the other sources. Dark unless software enables its receive interrupt. |
| 279 | 279 | 1 | `INT_CPU` (stretched) | `not n_INT_ssp` | `fpChainEnd` | `INT` as the T80 sees it: the combined request (timer + both ACIAs) after the SSP single-step mask (`ssp_int_hold`). Stays dark during a single-step trace even though 276 keeps lighting. |
| 280 | 280 | 1 | `/WR` (stretched) | `not n_WR` | `fpChainEnd` | Pulse-stretched (see below). |
| 281 | 281 | 1 | `/RD` (stretched) | `not n_RD` | `fpChainEnd` | Pulse-stretched. |
| 282 | 282 | 1 | `/MREQ` (stretched) | `not n_MREQ` | `fpChainEnd` | Pulse-stretched. |
| 283 | 283 | 1 | `/IORQ` (stretched) | `not n_IORQ` | `fpChainEnd` | Pulse-stretched. |
| 284 | 291 | 8 | `fpLatch[7:0]` (echo) | I/O port `$FF` write latch | `fpChainEnd` | Second copy of the port `$FF` latch. `fpLatch(7)` = bit 284. |

Total: **292 bits** (0–291). Positions 276–283 are the stretched ones.

## Notes

- **Transparent vs. stretched capture.** All segments except
  `fpChainEnd` are `Transparent_Capture_Chain`: captured bits follow their
  source continuously and are snapshotted by the `latch` pulse. The final
  `fpChainEnd` segment is a `Universal_Capture_Chain` with
  `STRETCH_MASK => b"0000_0000_0000_0000_1111_1111_0000_0000"` (bits 15:8) —
  the four interrupt bits (276–279) and the `/WR`, `/RD`, `/MREQ`, `/IORQ`
  bits (280–283) hold high for `HOLD_CYCLES` (default 2,500,000 clk ≈ 50 ms
  at 50 MHz) after a brief pulse, so short bus strobes and interrupt
  requests remain visible in the LED display. The rest of the segment —
  the raw `/MREQ` and `/IORQ` copies at 272/273, the `fpLatch` echo and the
  reserved filler — is transparent.
- **Stretching and fast pulse trains.** A stretched bit stays lit as long as
  pulses arrive faster than the hold time. RomWBW ticks the IntervalTimer at
  50 Hz (every 20 ms, shorter than the ≈ 50 ms hold), so `INT_TMR` (276) and
  `INT_CPU` (279) look steadily lit while HBIOS is running; `/WR`, `/RD`,
  `/MREQ` and `/IORQ` behave the same under any real workload. To see
  individual ticks, shorten `HOLD_CYCLES` on this segment.
- **Raw and stretched copies of one signal.** Each strobe appears twice in the
  chain: a transparent sample and a stretched one in `fpChainEnd`
  (`/WR` 252 and 280, `/RD` 253 and 281, `/MREQ` 272 and 282, `/IORQ` 273
  and 283 — raw first). `INT` likewise: the raw pre-mask request at 254, and
  the post-mask `INT_CPU` at 279 stretched. Mapping the raw and stretched copy
  side by side shows directly whether the refresh is missing pulses.
- **Interrupt sources.** Three sources are ANDed onto the CPU `INT` pin:
  the IntervalTimer (`INT_TMR`) and the two ACIAs — `INT_IO1` (video
  terminal) and `INT_IO2` (serial). The ACIAs assert only if software turns
  on a receive or transmit interrupt in the 6850 control register (RomWBW
  does not: `ACIAINTS=FALSE`).
- **Polarity.** Active-low Z-80 control signals are inverted before capture,
  so throughout the chain a **logic 1 = the signal is asserted**.
- **Sampling rate.** The chain is latched on the `FrontPanel_Subsystem`
  refresh tick generated from `fpRefreshCount` (50 MHz / 666,666 = 75 Hz).
- **LED reach.** `FrontPanel_Subsystem` is instantiated with
  `NUM_LEDS => 256`, so an identity profile map exposes bits 0–255 only;
  bits 256–291 (upper CPU control signals, the four interrupt bits, the
  `/WR` `/RD` `/MREQ` `/IORQ` strobes, and the `fpLatch` echo) require a
  profile that maps them explicitly.
- **Register semantics.** `HL`/`DE`/`BC` are always the *current* register
  set — the T80 swaps the slots in `REG` on `EXX`, so these LED slots show
  whichever bank is active. See `doc/t80_reg_debug_vector.md`.
- The signal chain topology and declarations are documented in
  `MicrocomputerZ80CPM.vhd` (comment block "Capture-chain wiring between the
  front-panel chain segments").

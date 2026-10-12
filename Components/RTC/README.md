# ds12887 — DS12887 (DS1288X) RTC + RAM model for MiSTer FPGA cores

Faithful VHDL model of the DS12887 battery-backed real-time clock + 112-byte
RAM peripheral, with the time sourced from the **MiSTer host's Linux RTC**
via the `hps_io` `.RTC` bus. Intended for Z80 (or any) MiSTer cores that
expect a DS12887/DS1386-style I/O peripheral.

* `ds12887.vhd` — the model (VHDL-93, synthesizes in Quartus 17.0, also compiles with `--std=08`)
* `tb_ds12887.vhd` — self-checking testbench (VHDL-2008, uses `std.env.finish`)

## Register map (A0–A6, 128 bytes)

| Addr | Name            | Notes                                                        |
|------|-----------------|--------------------------------------------------------------|
| 0x00 | Seconds         | BCD or binary per Reg B DM; 00–59                           |
| 0x01 | Alarm seconds   | raw 8-bit; 0xC0–0xFF = don't-care (never matches)            |
| 0x02 | Minutes         | BCD/binary; 00–59                                           |
| 0x03 | Alarm minutes   | raw 8-bit; 0xC0–0xFF = don't-care                            |
| 0x04 | Hours           | 24-h: 00–23. 12-h BCD: 01–12/81–92 (bit7=PM); 12-h bin: 01–0C/81–8C |
| 0x05 | Alarm hours     | raw 8-bit; 0xC0–0xFF = don't-care                            |
| 0x06 | Day of week     | 1–7, Sunday = 1                                             |
| 0x07 | Date (of month) | BCD/binary; 01–31                                           |
| 0x08 | Month           | BCD/binary; 01–12                                           |
| 0x09 | Year            | BCD/binary; 00–99, rolls 99 → 00                            |
| 0x0A | Register A      | UIP, DV2, DV1, DV0, RS3–RS0 (periodic rate select)          |
| 0x0B | Register B      | SET, PIE, AIE, UIE, SQWE, DM, 24/12, DSE                    |
| 0x0C | Register C      | IRQF, PF, AF, UF (bits 7–4) — **read clears flags**         |
| 0x0D | Register D      | read-only; VRT (bit 7) from `pof_in`, other bits 0          |
| 0x0E | —               | reads 0xFF, writes ignored                                  |
| 0x0F | —               | reads 0xFF, writes ignored                                  |
| 0x10–0x7F | RAM      | 112 general-purpose bytes (written in reset, reset clears)  |

Behaviour details:

* **SET (Reg B bit 7)** pauses the calendar (seconds/mins/hours/date advance
  stops) while the tick, UIP and periodic-tap pulse trains keep running, so
  the documented *SET=1 → write time → SET=0* programming sequence is
  race-free. CPU time/calendar writes update both the user and internal
  copies even while SET = 1.
* **DV2/DV1/DV0 (Reg A bits 6:4)**: `010` = run; any other pattern freezes
  the calendar (the 11X "hold in reset" state is only observable on SQW,
  which is not generated, so it is treated as frozen).
* **Alarms** are compared in encoded (mode-dependent) form at the update
  transfer; `0xC0–0xFF` alarm bytes never match (don't-care).
* **Reg A RS codes**: 0001/1000 → 256 Hz, 0010/1009 → 128 Hz, 0011 → 8192 Hz,
  0100 → 4096, 0101 → 2048, 0110 → 1024, 0111 → 512, 1010 → 64, 1011 → 32,
  1100 → 16, 1101 → 8, 1110 → 4, 1111 → 2 Hz. PF (and therefore IRQF when
  PIE=1) is set on the rising edge of the selected rate.
* **Calendar rollover** is a full Gregorian calendar: month lengths,
  leap years (div by 4, except centuries, except 400s — applied to the 2-digit
  year, so 00 is a leap year), month/year wrap, day-of-week wrap.

## MiSTer integration

### Host time source

The MiSTer host (`Main_MiSTer`) drives `hps_io` outputs that the core
receives before/at reset:

* `hps_io.RTC` — 65-bit BCD time, pushed **once at core load (before the
  core reset releases)** and then **again every 60 s** for generic 8-bit
  cores (`CORE_TYPE_8BIT`, 0xA4). Bit 64 toggles on every push.
* `hps_io.TIMESTAMP` — 32-bit Unix timestamp (reserved on this port; not
  consumed by the model, which uses the BCD bus).

BCD layout of `RTC[63:0]` (little-endian byte order):

| Bits    | Field            | Encoding                      |
|---------|------------------|-------------------------------|
| [7:0]   | seconds          | BCD, 00–59                    |
| [15:8]  | minutes          | BCD, 00–59                    |
| [23:16] | hours            | BCD, 24-hour, 00–23           |
| [31:24] | day of month     | BCD, 01–31                    |
| [39:32] | month            | BCD, 01–12                    |
| [47:40] | year             | BCD, 00–99                    |
| [55:48] | day of week      | binary 0=Sun … 6=Sat          |
| [63:56] | —                | 0x40 (fixed by host)          |

### Sync policy

1. **Load time.** The host push arrives while the core reset is still
   asserted. The model latches and applies it *during* reset, so the guest
   reads the correct host time from its very first read.
2. **Periodic refresh (60 s).** Applied on each `rtc(64)` toggle **unless**
   guest software has written any time/calendar register (0x00–0x09) — that
   sets a *guest-owned* flag, which is cleared when a sync is applied.
3. **First applied sync** forces 24-hour BCD mode (Reg B 24/12 = 1, DM = 0)
   and starts the oscillator chain (Reg A DV = 010), so the clock is live
   out of the box.
4. Host data is **range-checked** (sec/min ≤ 59, hour ≤ 23, mon 1–12,
   date 1–31, wday ≤ 6) before being applied; invalid pushes are ignored.

### Wiring (example: Z80, DS12887 at I/O port 0x70)

```vhdl
-- I/O decode: port 0x70, lower 7 port bits -> DS12887 A0-A6
rtc_cs  <= iorq and not port_in(15) and port_in(14) and port_in(13)
           and port_in(12) and not port_in(11) and not port_in(10)
           and not port_in(9) and not port_in(8);
rtc_wrt <= rtc_cs and iowr_n_bar_low;        -- i.e. /IOWR
-- port_in(7 downto 1) -> adr (A0..A6)

ds12887_inst : entity work.ds12887
    generic map (
        SYS_CLK => 50_000_000       -- or 100_000_000; see note below
    )
    port map (
        clk_sys   => clk_sys,
        reset     => reset,          -- core cold reset, active high
        req       => rtc_cs,
        wrt       => rtc_wrt,
        adr       => port_in(7 downto 1),
        dbo       => dout,           -- Z80 data bus
        dbi       => rtc_dbi,
        irq       => rtc_irq,        -- open-drain; wire into Z80 /IRQ OR net
        sqw       => open,           -- held low; not needed
        rtc       => hps_rtc,        -- hps_io .RTC [64:0]
        timestamp => hps_timestamp,  -- hps_io .TIMESTAMP (reserved)
        pof_in    => '0'
    );
```

* `req` must be asserted for the whole I/O access (chip-select level);
  `wrt` timed with /IOWR; `dbi` is combinational while `req` and not `wrt`.
* `irq` is open-drain (active low, high-Z when no interrupt is pending) —
  OR it with the core's other interrupt sources.
* **Clock:** the 1 Hz calendar tick is exact for 50 or 100 MHz
  (`TICK_MAX = SYS_CLK - 1`). Set the `SYS_CLK` generic to match `clk_sys`.
  The SQW/periodic-tap train is derived from the same clock (a 16384 Hz top
  event), so tap rates above 1 Hz carry a < 0.02 % rate approximation —
  there is no 32768 Hz reference on MiSTer.
* Any I/O port window works, as long as its lower 7 address bits map to
  `adr`; the decode above is just the common 0x70 choice.

### Deviations from the real DS12887 (documented)

* **SQW** — port exists, held low (no SQW use on MiSTer).
* **DST (DSE bit)** — stored, no effect.
* **Tap frequencies** — derived from 50/100 MHz, rate error < 0.02 %
  (no 32.768 kHz reference available).
* **Power-on Reg A** — after a valid host load the model starts with
  Reg A DV = 010 (oscillators running) rather than the real part's 111
  hold state, so the guest sees a running clock without driver setup.
* **Register D VRT** — driven by the `pof_in` simulation port; there is no
  real power-fail latch.
* **12-h/24-h mode** — the internal calendar is always 24-h; 12-h mode is
  applied at the I/O encoding level (mode switches do not change the
  underlying time, only the PM bit presentation).
* **UIP** — implemented as a coarse indicator (regenerated on the 1 Hz
  tick); the real part's 100 µs UIP timing is a documented approximation.

## Testing

Requires GHDL (verified with 6.0.0):

```sh
ghdl -a --std=08 ds12887.vhd tb_ds12887.vhd
ghdl -e --std=08 tb_ds12887
ghdl -r --std=08 tb_ds12887
```

The testbench instantiates the model with `TB_MODE = true`, which shrinks
the counters so one "second" = 25 clocks (50 ns each → 20 ns clock period).
It replays the real MiSTer sequence (host BCD push *before* reset release,
periodic refresh after) and self-checks:

| Test | Checks                                                        |
|------|---------------------------------------------------------------|
| T1   | load-time host BCD appears in sec/min/hr/dow/date/mon/yr, Reg A/B/D |
| T2   | local 1 Hz counting over a 10-s window                        |
| T3   | alarm (don't-care sec/min + exact hr) → AF + IRQF + UF, IRQ low, Reg C read clears, IRQ tri-state |
| T4   | guest-written time/calendar is not overridden by host refresh |
| T5   | 23:59:59 → 00:00:00 rollover, date+1, dow+1 via SET procedure  |
| T6   | RAM 0x20/0x7F r/w; unmapped 0x0E/0x0F read 0xFF               |
| T7   | binary mode (DM=1)                                            |
| T8   | periodic interrupt: PIE + RS=0011 → PF, IRQF, IRQ low         |
| T9   | SET=1 freezes the user copy; SET=0 resumes counting           |
| T10  | Register D VRT follows `pof_in`                               |

All 37 checks must print `PASS:` with no `FAIL:` lines.

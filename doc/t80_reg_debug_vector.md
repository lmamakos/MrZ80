# T80 `REG` Debug Vector and Register-File Implementation

Describes the 212-bit `REG` debug vector exported by the modified T80 CPU core
in this project, and how `Components/Z80/T80_Reg.vhd` implements the Z80
register set.  Several aspects of this core deviate from the stock OpenCores
T80 and are not obvious without reading `T80.vhd` closely; this document
records what was established (and machine-verified) during the `sim/tb_cpuregs`
testbench work.

Source files:

| File | Role |
|---|---|
| `Components/Z80/T80.vhd` | Datapath/control: builds `REG`, drives register-file addresses, owns A/F/A'/F'/PC/SP/I/R |
| `Components/Z80/T80_Reg.vhd` | The register *file*: 2 × 8 × 8-bit arrays + 3 read ports + flat `DOR` dump |
| `Components/Z80/T80_MCode.vhd` | Control store: emits the register/pair selectors that choose file slots |
| `sim/tb_cpuregs.vhd` | Ground-truth testbench validating every mapping below (8 cases, all passing) |

---

## 1. The `REG` debug vector

`T80.vhd` (line ~248) exposes a 212-bit debug output assembled by pure
concatenation:

```vhdl
REG <= IntE_FF2 & IntE_FF1 & IStatus &
       DOR &
       PC & SP & R & I & Fp & Ap & F & ACC            when Alternate = '0'
  else IntE_FF2 & IntE_FF1 & IStatus &
       DOR(127:112) & DOR(47:0) & DOR(63:48) & DOR(111:64) &
       PC & SP & R & I & Fp & Ap & F & ACC;           -- Alternate = '1'
```

`T80s.vhd` (the multi-core wrapper) leaves the inner core's `REG` port
unconnected, so testbenches read it through a VHDL-2008 external name
(`<< signal .tb_cpuregs.cpu.u0.REG : ... >>`).  At the board level,
`MicrocomputerZ80CPM.vhd` connects `REG` to `cpuDbgRegisters`, splits it into
`dbgReg_*` signals at **fixed bit positions**, and feeds the front-panel
capture chain.

### 1.1 Layout — normal case (`Alternate = '0'`)

`Alternate` is `1` only when an odd number of `EXX` instructions has been
executed since reset (see §2.4).  Fields below are `cpuDbgRegisters` / `REG`
bit ranges, MSB-first concatenation order:

| Bits | Register | Origin |
|---|---|---|
| 211 | IFF2 | `IntE_FF2` (T80.vhd) |
| 210 | IFF1 | `IntE_FF1` (T80.vhd) |
| 209:208 | IM (00=IM0, 01=IM1, 10=IM2) | `IStatus(1 downto 0)` |
| 207:192 | **IY** | file slot 7 via `DOR` |
| 191:176 | **HL'** | file slot 6 via `DOR` |
| 175:160 | **DE'** | file slot 5 via `DOR` |
| 159:144 | **BC'** | file slot 4 via `DOR` |
| 143:128 | **IX** | file slot 3 via `DOR` |
| 127:112 | **HL** | file slot 2 via `DOR` |
| 111:96 | **DE** | file slot 1 via `DOR` |
| 95:80 | **BC** | file slot 0 via `DOR` |
| 79:64 | PC | `PC` (T80.vhd) |
| 63:48 | SP | `SP` (T80.vhd) |
| 47:40 | R | `R` (T80.vhd) |
| 39:32 | I | `I` (T80.vhd) |
| 31:24 | F' | `Fp` (T80.vhd) |
| 23:16 | A' | `Ap` (T80.vhd) |
| 15:8 | F | `F` (T80.vhd) |
| 7:0 | A | `ACC` (T80.vhd) |

Within each 16-bit field the high byte is in the upper half (e.g. B = 95:88,
C = 87:80).

### 1.2 Layout — alternate window (`Alternate = '1')`

When `Alternate = '1'` the *same fields* are present but the `DOR` half is
re-concatenated:

| Bits | Register | Physical slot now visible there |
|---|---|---|
| 207:192 | IY | slot 7 (unchanged) |
| 191:176 | **HL** (current) | slot 2 |
| 175:160 | **DE** (current) | slot 1 |
| 159:144 | **BC** (current) | slot 0 |
| 143:128 | IX | slot 3 (unchanged) |
| 127:112 | **HL'** (shadow) | slot 6 |
| 111:96 | **DE'** (shadow) | slot 5 |
| 95:80 | **BC'** (shadow) | slot 4 |

### 1.3 The invariant that makes this work

The re-ordering in §1.2 is **not** cosmetic — it preserves a critical
invariant:

> A consumer that always reads the *fixed* positions of §1.1 (95:80 = "BC",
> 111:96 = "DE", ... 207:192 = "IY") always sees the architecturally correct
> **current** and **shadow** banks, whatever `Alternate` is.

Why: with `Alternate = '0'` the program's current BC lives in slot 0 and the
dump puts slot 0 at 95:80; with `Alternate = '1'` the program's current BC
lives in slot 4 (§2.4) and the re-ordered dump puts slot 4 at 95:80.  So the
core's `dbgReg_*` splitters (and `sim/tb_cpuregs.vhd`) never need to know the
window state.  IX/IY slots are bank-independent, hence unmoved.

`sim/tb_cpuregs` case *"EXX odd alternate window"* pins this behavior: it ends
in HALT with `Alternate = '1'` and verifies the fixed positions still report
the post-`EXX` loads as current and the pre-`EXX` loads as shadow.

### 1.4 `R` and PC caveats for consumers

* **R** increments on every M1 opcode fetch, including `HALT`'s refetch
  loops, so its value while halted is cycle-count-dependent — `tb_cpuregs`
  deliberately does not check it.
* After `HALT`, PC points at the byte following the `76h` opcode (verified to
  be exactly `halt_address + 1` in all tb cases; the tb allows +1 slack for
  refetch timing).

---

## 2. How `T80_Reg.vhd` implements the Z80 registers

### 2.1 The file is just two byte arrays

`T80_Reg.vhd` is deliberately dumb.  After the v0244 "single register file"
refactor it contains exactly:

```vhdl
signal RegsH : Register_Image(0 to 7);   -- 8 × 8-bit "high" bytes
signal RegsL : Register_Image(0 to 7);   -- 8 × 8-bit "low"  bytes
```

* **One write port**: `AddrA` + `WEH`/`WEL` strobes (H and L written
  independently, so 8-bit `LD r,n` writes one byte, 16-bit `LD rr,nn` both).
* **Three read ports**: `AddrA → DOA*`, `AddrB → DOB*`, `AddrC → DOC*`
  (addressed reads are *asynchronous*; the paired `RegBusA/B/C` in `T80.vhd`
  feed Bus A, Bus B and the address generator).
* **Flat debug dump**: `DOR` concatenates all 16 bytes, slot 7 first:
  `DOR = RegsH(7)&RegsL(7)& ... &RegsH(0)&RegsL(0)`.  `DOR` is used *only*
  by the `REG` vector (§1); it is not part of the datapath.
* **No reset.**  `RESET_n` does not reach the file.  After a CPU reset the
  eight slots hold stale/undefined values; `tb_cpuregs` therefore only checks
  slots a test program actually wrote.

### 2.2 The file stores *pairs*; slot index = pair code

Each index 0-7 is one 16-bit register pair.  The control store
(`T80_MCode.vhd`) never names slots directly — it emits the standard T80
register selectors, and `T80.vhd` derives the 3-bit file address
(`T80.vhd:725` ff.):

```
file address = Alternate & pair_index(1 downto 0)     -- XY redirect may override
```

8-bit selectors `Set_BusA_To` / `Set_BusB_To` (3 bits) split as
*pair = bits 2:1*, *low-byte-select = bit 0*:

| Selector value | Register | pair | byte |
|---|---|---|---|
| 000 / 001 | B / C | 00 | H / L |
| 010 / 011 | D / E | 01 | H / L |
| 100 / 101 | H / L | 10 | H / L |
| 110 | (HL) | 11 | — memory, not a file byte |
| 111 | A | 11 | — **dedicated register, not in file** |

16-bit selectors (`r16`/`DPAIR`, 2 bits): `00=BC, 01=DE, 10=HL, 11=SP-or-AF`
(SP/AF are handled outside the file).  So on its own, `pair_index` maps:

| pair | physical slot when `Alternate='0'` |
|---|---|
| 00 | BC |
| 01 | DE |
| 10 | HL (or IX/IY — see §2.3) |
| 11 | SP-type ops; SP itself is not in the file |

### 2.3 Slot map — the key deviation from stock T80

| Slot | Register | Slot | Register |
|---|---|---|---|
| 0 | BC | 4 | BC' |
| 1 | DE | 5 | DE' |
| 2 | HL | 6 | HL' |
| 3 | **IX** | 7 | **IY** |

The stock T80 (and the real Z80 silicon) has **no dedicated IX/IY storage** —
`LD IX,nn` swaps HL with a scratch register, and the notorious
"IX-indirect H/L bug" on `LD H,(IX+d)` etc. falls out of that aliasing.

This core gives IX and IY **real, permanent slots (3 and 7)**:

* The DD/FD prefix sets `XY_State` (`T80.vhd:435-440`): DD → `"01"`,
  FD → `"10"`.
* Whenever a pair index `10` (HL) is used with a pending index prefix, the
  address is redirected to `XY_State(1) & "11"` → **slot 3 (IX)** for DD,
  **slot 7 (IY)** for FD.  This applies to Bus A/write, Bus B, the address
  source, and the 16-bit inc/dec unit.
* `XY_Ind` is set during the displacement-fetch cycle (`MCycle "110"`).  While
  `XY_Ind = '1'` the *operand* redirect is suppressed, so
  `LD H,(IX+d)` / `INC L` etc. reach the **real H/L in slot 2** — this is the
  IX-indirect bug fix (verified by `sim/tb_ixmin`).  The address source stays
  redirected to IX/IY during that cycle, as it must.

### 2.4 `EXX` just flips the window bit

`EXX` executes `Alternate <= not Alternate` (`T80.vhd:604-606`). **No data
moves.**  Because the file address is `Alternate & pair`:

* `Alternate='0'`: current BC/DE/HL ↔ slots 0/1/2, shadow ↔ 4/5/6
* `Alternate='1'`: current BC/DE/HL ↔ slots 4/5/6, shadow ↔ 0/1/2

IX, IY, SP, A/F and their shadows are *not* affected by `EXX` (note the
address arithmetic can never even select slot 3/7 as "the alternate HL":
`Alternate & "11"` → slot 7/IY is only ever reached via the XY redirect, and
the custom PUSHIX path forces `011` explicitly).

`EX AF,AF'` likewise moves no file data — it swaps the dedicated register
pairs `ACC↔Ap`, `F↔Fp` (`T80.vhd:598-603`).

### 2.5 Registers that live *outside* the file

A, F, A', F', PC, SP, I and R are ordinary registers in `T80.vhd`:

* A/F/A'/F' shadow each other through dedicated `Ap`/`Fp` registers.
* Store paths: `Read_To_Reg_r` "10111" → ACC, "11011" → F,
  "11000"/"11001" → SP low/high (`T80.vhd:694-707`); file writes instead
  assert `RegWEH`/`RegWEL` for selectors "100xx".
* `LD SP,HL`/`EX (SP),HL` shuffle `SP` and the file's current-HL through the
  standard TmpAddr machinery.

Reset values (`RESET_n`):

| Register | Value | Register | Value |
|---|---|---|---|
| PC | 0000h | A, F, A', F' | FFh |
| SP | FFFFh | I, R | 00h |
| IM, IFF1, IFF2 | 0 / 0 / 0 | Alternate | 0 |
| file slots 0-7 | **undefined (stale)** | | |

### 2.6 Custom instructions exploiting slot 3: PUSHIX / POPIX

Because IX is a properly addressed file slot, `T80_MCode.vhd:1822-1890`
implements two custom (ED-prefixed) instructions used by the CamelFORTH
return stack:

| Opcode | Name | Action |
|---|---|---|
| ED C5 / D5 / E5 | `PUSHIX BC/DE/HL` | IX -= 1, (IX) <- high; IX -= 1, (IX) <- low |
| ED C1 / D1 / E1 | `POPIX BC/DE/HL` | low <- (IX), IX += 1; high <- (IX), IX += 1 |

Datapath: a new address source `aIX` ("011") forces `RegAddrC` straight to
slot 3 with **no displacement cycle and no bank bit** (IX is not banked), and
`IncDec_IX` steers the 16-bit increment unit from the default pair onto slot
3.  Pairs come from the currently-`EXX`-selected bank.  14 T-states vs 58 T
for the equivalent `DEC IX` / `LD (IX+0),r` sequence.

---

## 3. Verification

`sim/tb_cpuregs.vhd` (`sim/run_cpuregs.sh`) runs eight hand-assembled
micro-programs through the real `T80s`, HALTs, and checks each loaded value
appears at the fixed `REG` positions of §1.1 — including under the
`Alternate='1'` window — plus a cross-check of the `DOR` dump against the same
values.  Covers: 16-bit/8-bit loads, flag bytes, `EX AF,AF'` both ways, `EXX`
even and odd, `EI`/`IM 1`/`LD I,A`, `DI`.  All cases pass.  During
development the core corrected a hand-trace error (`SUB A` of 55h gives
F=42h, not 52h — H is the half-borrow out of bit 3, and `5h-5h` borrows
nothing), confirming the ALU/flag path as ground truth.

## 4. Board-level consumer (brief)

`MicrocomputerZ80CPM.vhd` splits `cpuDbgRegisters` at the fixed §1.1
positions into `dbgReg_*` and drives the front-panel capture chain
(`fpChainRegs`, LEDs 32-223 of the 384-bit chain, A first).  Thanks to the
§1.3 invariant no `Alternate` awareness is needed there either.  Note the
older chain-assignment table in `Components/FRONTPANEL/README.md` still
reflects the 256-bit era and is stale.

# ODT_PANEL_UX — Front-Panel User-Experience Specification

Status: **DRAFT v0.2** — v0.1 = first pass of the panel-UX deep-dive
(OQ-16b/OQ-12), owner session of 2026-10-23, recorded as round **R8** in
`ODT_MONITOR_DESIGN.md` §17; **v0.2** = round **R10** addendum — the MMU
map switch (§4A). Implements the panel-side surface of design
v0.7 §§11/6. Notation/tags as in the design doc; `[proposed]` marks items
still open to board-freeze adjustment.

Companions: `ODT_MONITOR_DESIGN.md` v0.7 (architecture, decisions D-23/D-24/G-8/G-9
introduced here), `HARDWARE.md` (port/lamp tables on landing), `fp_engine`/
`fp_capture`/`dbg_bridge` RTL (module specs reference this document).

---

## 1. Physical vocabulary (from design §11.1)

32 toggles `S31..S0` (address `S27..S0`, data = `S7..S0`, `S31` = PHYS,
`S30..S28` = modifiers, this spec §4) · 9 SPDT momentary function switches
(18 lever functions — F9 = MMU EXAM/DEPOSIT, new R10, §4A) · quadrature
encoder with push (menu selector) ·
escape/disable toggle · RUN/HALT state · 256-lamp WS2812 array ·
guest sense ports $FC–$FF/$FB (design §11.6, unchanged by this spec).

## 2. Lamp vocabulary

### 2.1 Zones (logical, independent of physical LED placement `[proposed]`)

| Zone | Lamps | Role |
|---|---|---|
| A | L00–L27 | primary content (AR on classic page; register fields elsewhere) |
| M | L28–L31 | **chrome — pinned in every page**: modifier arms {BP-ARM, FREEZE, START} + MD=PHYS |
| B | L32–L39 | secondary content (DR on classic; page-defined elsewhere) |
| T | L40–L47 | **chrome — pinned**: status strip §2.2 + page-ID 3 bits |
| D | L48–L63 | tertiary content (PR/reason on classic; page-defined elsewhere) |
| E | L64+ | reserved for a future second export word (richer pages) |

Chrome rows are **fixed across all pages** (hand-eye anchors: arms and
status never move). Content zones A/B/D are remapped per page (§3).

### 2.2 Status strip (zone T, pinned)

| Lamp | Meaning | Colour (default) |
|---|---|---|
| T0 | RUN | green |
| T1 | HALT (parked) | red |
| T2 | MON active (OSD OK ∧ S32) | white |
| T3 | CONSOLE_OWN (monitor holds SNAC) | pale white |
| T4 | PANEL_LOCK held (FW) | amber |
| T5 | FW alive | cyan, slow blink (WDG kick heartbeat) |
| T6 | WDG dead (FW presumed dead) | violet, solid |
| T7 | spare | — |
| +3 lamps | page-ID `P2..P0` (current page 0–7) | white, binary |

### 2.3 Colour conventions (profile-7 defaults)

green RUN · red HALT / BP-hit · amber BP-slot-set / PANEL_LOCK ·
blue PHYS mode · white data/“1” · violet watchdog-fault ·
cyan FW-alive blink · off = 0 / unarmed.
Colour lives in profile colour-RAM, so pages get colour semantics without
any FW traffic beyond page-switch map writes. `[proposed: exact hues/
intensities at board time]`

## 3. State pages (D-23/G-9: page = content **+ layout**)

Mechanism: page change ⇒ FW (or cold-boot defaults) rewrites **profile 7
`map_ram`** through the bridge LED path (`LED_ADDR/LED_DATA`, design §6) to
the page's layout, and sets `MON_CTRL.page` to swap the 64-bit export
content. Cold default = shipped identity map ⇒ page 0 CLASSIC works with
zero FW and zero profile load (identity over the classic export layout).
WDG-PARK expiry (FW dead) ⇒ engine forces content to page 0 (map frozen —
last layout stays, chrome intact).

| Pg | Name | Contents (≤64 b) | Layout intent |
|---|---|---|---|
| 0 | **CLASSIC** | AR[27:0] · DR[7:0] · PR[7:0] · halt-reason[3:0] · BP-hit[3:0] | lamps-under-switches; canonical identity layout |
| 1 | **CORE-A** | PC · SP · AF · HL | 4×16 in A(+M) / B / D rows |
| 2 | **CORE-B** | BC · DE · IX · IY | as above |
| 3 | **CORE-C** | PC · SP · I · R · {IFF2,IFF1,IM[1:0],ALT,alt3} | interrupt/status view |
| 4 | **MMU** | 4 × {valid, page[13:0]} (56 b) | four field groups with valid-dot lamps; single-entry live view from the panel lever: §4A |
| 5 | **BP** | 4 × addr[15:0]; per-slot arm/hit via lamp colour (amber/red) | four rows; slot index labels |
| 6 | **MSG** | MBX0..3 (32) · ENC cursor (8) · committed (8) · doorbell code (8) · spare | guest↔monitor conversation |
| 7 | **SYS** | ring-head {SRC, DST, type} · trap {port, data} · FW heartbeat bits · id nibble | diagnostics tail |

**Auto-paging (FW):** `E D F S? ME MD`→0 · `R`→1 (+`R2`→2, `R3`→3) ·
`P`→4 · `B`→5 · `MB`→6 · `SYS`→7. Sticky until next command or encoder
commit. `MON n` = explicit. Panel actions page 0 implicitly (EXAM/DEP/PORT
refresh zone A/B/D content even when entered from another page ⇒ landing
back to classic view after panel work). `[proposed: stickiness fine-tune at
board time]`

## 4. Modifier toggles (S28–S30) `[decided R8]`

- **S28 — BP ARM.** While on: `LOAD-ADDRESS`(up) also installs a
  breakpoint at `A[15:0]` into slot = low 2 bits of the committed encoder
  cursor (page-5 rows show slots). Arm lamp (M0). Un-arming leaves BP set;
  clear via serial `B.` or re-ARM + LOAD on the same slot with
  data switches `0xFF`?? — no: `[open: panel BP-clear gesture — candidate:
  armed LOAD-ADDRESS(down), or serial only in v1; board/UX freeze]`.
- **S29 — DISPLAY FREEZE.** Latches the export (and per-page map stays) so
  lamps snapshot the last instant while engine ops continue underneath;
  chrome updates normally. Lamp (M1).
- **S30 — START-AT-A.** While armed, `RUN`(up) executes the full classic
  START **in pure hardware**: `TRAMP_ADDR ← A[15:0]`, `tramp_en`, reset
  vent (stretched), release park ⇒ guest boots `JP A[15:0]`. Firmware-free
  (P-B); MD is display context only for START (target = guest-side fetch
  address at reset). Lamp (M2).

### 4A. MMU map switch (F9, SPDT #9, center-off momentary) `[decided R10]`

One center-off two-way lever, momentary in both directions like F1–F8 —
electrically two lines (frame bits 52/53):

- **UP — MMU EXAMINE.** Each UP edge queries MMU entry `n` = current
  **low 2 bits of the address switches (S1:S0)** via the monitor's
  `MAP0..3` tap — no bus cycle, guest untouched. The result overlays the
  address lamps **at the positions those bits hold in a physical address**:

  | Lamps | Content |
  |---|---|
  | L27..L14 | page number = physical `A27..A14` of the frame's base |
  | L1:L0 | entry (frame) number `n` — *which* mapping is displayed |
  | L12..L2 | dark |

  The display **sustains** until the next display-changing op (any panel
  op, encoder page commit, FW auto-page). Re-throw UP to re-query; while
  the overlay is active, moving `S1:S0` re-queries live — flick through
  frames 0–3 without re-throwing `[proposed: board-adjustable]`. No
  valid-bit lamp: this operation is inherently for a **stopped CPU**, where
  the taps are static and any mapped value is shown as-is (R10).
- **DOWN — MMU DEPOSIT.** Each DOWN edge stores page = `S27..S14` into
  entry `n` (same `S1:S0`). **Implicit validity:** the engine performs no
  sanity check — a bogus page misbehaves exactly as if guest software had
  written it (R10). Executed as a two-write macro through the existing
  port-master path (`OUT $B0+n` low byte, `OUT $B4+n` high byte), the
  guest transiently parked (G-4 budget). `S1:S0`/`S27..S14` moves alone
  do nothing until the lever is thrown.

Both directions work with **zero firmware** (tap + mastering). FW mirrors
the events (`FP_FN[17:16]`), prints `*` commentary (§7), and its MMU
translation shadow self-corrects from the tap.

## 5. Encoder `[decided R8: hold-cursor + double-press-zero]`

- Rotation: signed cursor, range page-menu 0..7 wrap (other menu consumers
  reserved). Cursor **persists after commit** (persistent index indicator,
  visible on MSG page + 3-bit page-ID chrome lamps).
- **Press**: commits cursor ⇒ page change (map rewrite request to FW? No —
  see below), sets `FP_ENC_STAT.committed`, pulses `commit_evt`.
- **Rapid double-press** (2nd press within `T_w`, default ≈500 ms
  `[proposed]`): zeroes the cursor; second press does **not** commit.
  `dbl_zero_evt` event bit to FW.
- **Page commit mechanics**: engine cannot rewrite profile-7 maps (FW job);
  therefore engine commits *page number* into `MON_CTRL.page` immediately
  (hardware: content swap + chrome page-ID reflect it), and raises
  `fp_done`/`ENG_LOG` so FW **optionally** rewrites the map for richer
  layouts. On FW-dead/absent, commits still switch content with the last
  map in place — degraded but never stuck `[proposed mechanism; verify UX]`.

## 6. Ownership, sovereignty and PANEL_LOCK `[decided R8 variant]`

Ladder, strongest first:

1. **Escape (S32) / OSD `OK`-off** — hardware, absolute: monitor released,
   guest controls forced inactive (park drops ⇒ guest resumes if parked),
   profile override drops (guest lamp profile returns), PANEL_LOCK cleared,
   `console_own` forced 0. Never lockable.
2. **PANEL_LOCK (`CTRL.bit9`, FW-set)** — gates only resumption-type
   actions: `RUN`(up) and START-AT-A are **rejected** while held (red-HALT
   flash + `lock_rejected` log/event). STOP, EXAM/DEP/PORT (which transient
   auto-park if needed), STEP, RESET, FREEZE, LOAD — all unaffected.
   Auto-clears: WDG_PARK expiry (FW presumed dead), escape/OK-off, MROM
   mount (monitor reset). FW clears explicitly at session end.
3. **Panel RUN / STOP** — honoured whenever not locked: panel intent wins
   over FW park requests for *resume* (G-8 base case); FW observes the
   state change asynchronously (STATUS is truth, never assume park persists).

Stop-latch and FW-hold park sources unchanged (design §6.9): escape clears
both; RUN clears both unless locked (lock never holds a park — lock only
blocks *new* resumes: actually RUN blocked by lock does **not** release
FW park; STOP releases engine park and *also* releases FW park? STOP's job
is halt: it asserts park, no conflict. RUN rejected ⇒ nothing happens).

## 7. Console commentary protocol `[decided R8]`

Panel-initiated operations produce a `*`-prefixed line from FW:
idle-at-prompt ⇒ printed immediately; FW-busy ⇒ queued, flushed before the
next prompt. Formats:

```
* EXAM 1234 -> A5 ; JP $12A5     (disasm tail when U available)
* DEP  1234 <- 3C
* PORT IN $82 -> A0
* PAGE 3
* BP2 SET @ 1234
* LOCKED (RUN ignored)
* START @ 1000
* MMU EX 2 -> page 0A5C (phys 0A5C000)
* MMU DP 2 <- 0A5C
```

Silent panel ops = never (hybrid chosen); `SW`, `ENC`, `ENG` commands for
manual dumps; mailbox doorbell events print `* MSG n <- dd`.

## 8. Walkthroughs (acceptance vignettes for sim/hardware)

1. **Cold classic, no FW**: power → page 0 identity map, chrome alive.
   RESET-CPU ⇒ guest held at $0000 (post-BIN-load), LOAD-ADDR(A=0100),
   DEP× (3C 00 C9 walk via DEP-NEXT), S30 arm + RUN ⇒ program runs from
   0100; lamps tracked AR/DR throughout; FW never involved.
2. **Serial session with panel browse**: `K` parks ⇒ red HALT, `R` pages to
   CORE-A; operator turns encoder to page 4 (MMU), FW prints `* PAGE 4`;
   RUN resumes; FW sees `fp_done`, keeps REPL.
3. **BP from switches**: ARM, cursor→2 (commit), LOAD-ADDR(A=12A5), un-ARM,
   GO ⇒ halt at BP2: red HALT + amber slot-2 lamp + `* BP2 HIT @ 12A5`
   when console attached; page-5 view after.
4. **FW lock**: FW scripted step-loop sets PANEL_LOCK; operator RUN press
   rejected (flash + `* LOCKED`); loop ends, lock clears, RUN honoured.
5. **FW death**: halt FW (test hook) ⇒ ≤2 s: cyan blink → violet, console
   demotes, page forces to CLASSIC content, engine full-function; escape
   still frees everything.
6. **Map surgery at the panel (§4A)**: with the CPU stopped (serial `K` or
   BP hit), set `S27..S14` = new page, `S1:S0` = target frame, throw
   MMU-DEP ⇒ FW prints `* MMU DP n <- pggg`; throw MMU-EXAM to confirm the
   lamps show the new page under A27..A14; FW `P` (map view) agrees — tap
   truth. Emergency path needs no serial at all.

## 9. Failure postures (summary)

| Condition | Lamps | Guest |
|---|---|---|
| FW dead (WDG_PARK) | violet T6, blink off, page→0, lock cleared | untouched unless FW had FW-hold park ⇒ released |
| Escape/OK-off | monitor chrome dark (profile returns to guest) | controls forced inactive; parked guest **resumes** (document loudly) |
| FREEZE | snapshot held; chrome live | unaffected |
| PANEL_LOCK | amber T4; RUN attempts flash | FW-controlled resume only |

## 10. Decisions taken here (feeds design §2/§17)

D-23 (panel UX package): sovereignty-with-lock (§6) · S28/S29/S30 =
BP-ARM/FREEZE/START-AT-A (§4) · per-page lamp remap with pinned chrome
(§2/§3, G-9) · encoder hold-cursor + rapid-double-press-zero (§5) ·
hybrid `*` commentary (§7) · colour conventions (§2.3) · WDG-dead forces
page 0 + clears lock (§3/§6) · **D-24 MMU map switch** (§4A: tap-exam
display at physical A27..A14 placements + frame echo in L1:L0, sustained +
live re-query; parked implicit-valid deposit macro; no validity checking,
no valid lamp).

## 11. Board-freeze hold-list (values/ergonomics, OQ-18)

LED physical placement vs switch banks (zone letter ↔ real geometry) ·
double-press window `T_w` · page-ID lamp physical encoding (binary vs
one-hot) · lock-reject flash pattern · BP panel-clear gesture (§4 open) ·
debounce/heartbeat constants · S28–S30 panel silkscreen labels · spare
bank (frame bits 54–67) future use · zone-E second export word capacity ·
MMU-switch silkscreen labels + 9th-SPDT physical mounting · live-re-query
on `S1:S0` policy (§4A) · FW MMU commentary number format (hex digits) ·
deposit valid-bit encoding verification against `MMU.vhd` at landing.

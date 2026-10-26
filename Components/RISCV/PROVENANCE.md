# Components/RISCV — Vendored Core Provenance

P0 two-core bake-off candidates (`doc/SSP_DESIGN.md` D-09 / OQ-20, round R14).
Vendored 2026-10-26 via raw HTTPS fetch from upstream `master`; files are
**verbatim upstream** (LF-normalization not required — fetched files contain
no CR bytes, confirmed by `grep -c $'\r'` = 0).

Do not hand-edit these files. To update: re-fetch from the pinned URL below
at a new revision, update pins + SHA-256 table, and note the delta here.

## picorv32 — PicoRV32 (bake-off entrant A)

| | |
|---|---|
| File | `picorv32.v` (self-contained; includes `picorv32_regs` and the PCPI/AXI/WB wrapper modules — unused wrappers inert when not instantiated) |
| Upstream | https://github.com/cliffordwolf/picorv32 (redirects to YosysHQ/picorv32) |
| Pinned at | repo HEAD `b91f32488a1f23b491b93d2c52bd45a4683c03f2` (2024-03-26); `picorv32.v` last modified `de92ce54e8a3f24f2adc6b5d04de35e4edb873e5` (2023-08-20) |
| License | ISC — full text in the file header (Claire Xenia Wolf, 2015) |
| Config for P0 | `COMPRESSED_ISA` param ⇒ RV32IMC (OQ-20: this parameter, not a separate file) |
| Intent | P0 bake-off entry: synth on `5CSEBA6U23I7` via `tools/build.sh synth`; optional riscv-formal (eqy container). **Not yet added to `MrZ80.qsf`** — wire in at P0 harness commit |

SHA-256:

```
0836050971b3c6cdd28ac3b1e5719a67fb645161912bef1e472e63995ceb0622  picorv32.v
```

## femtorv32_gracilis — FemtoRV32 "Gracilis" (bake-off entrant B)

| | |
|---|---|
| Files | `femtorv32_gracilis.v` (+ `utils.v`) |
| Upstream | https://github.com/BrunoLevy/learn-fpga — `FemtoRV/RTL/PROCESSOR/` |
| Pinned at | repo HEAD `5c08c870315c09ccd9ec64ccde20ab3375b3f273` (2025-11-18); `femtorv32_gracilis.v` last modified `ad5b19fb0b91cf6dbf9ad425ecbbde6e26831c3a` (2021-11-19) |
| License | BSD-3-Clause (c) 2020 Bruno Levy — `LICENSE.learn-fpga` (repo LICENSE; individual source files carry no SPDX headers). **OQ-20 license-terms check: satisfied — BSD-3-Clause is permissive-family; vendoring with the license text is compliant** |
| ISA | Header: **RV32IMC + CSR + MRET**; native interrupts via **standard** `mtvec/mepc/mcause/mstatus` CSRs (unlike picorv32's custom `getq/retirq/maskirq` instructions — v1 FW is polled anyway, `SSP_DESIGN.md` D-27) |
| Intent | P0 bake-off entry (same harness as picorv32). **Not yet added to `MrZ80.qsf`** |

SHA-256:

```
e000c6926586d6546bcc0ac3eb8829745dfff9f7a8c3a58a49faac9715c4039e  femtorv32_gracilis.v
3ec6a51a4959c976125c911faebcb9a6125bef578a9ed3da2717f5c5fd8b07d7  utils.v
dae852f7354066fe13901a60a49ac4f7e45b9ae16fec901e12e24218da0ea999  LICENSE.learn-fpga
```

### `utils.v` note

Upstream's synthesis file list pairs `femtorv32_gracilis.v` with `utils.v`,
so it is vendored for fidelity. Content is debug-macro glue only
(`VERBOSE`/`BENCH`/`verilator` `define wrappers) — `gracilis` itself does not
instantiate anything from it; keep it for simulation/lint parity.

### Flag for P0 (OQ-20 evidence list)

`femtorv32_gracilis.v` sets firmware-generation flags
`` `define NRV_ARCH "rv32imac" `` while its header documents the ISA as
**RV32IMC** (no atomics — consistent with R14's "atomics absent on both"
finding). The `NRV_*` defines are consumed by learn-fpga's firmware Makefiles
only, not by the RTL; at P0 we build FW with our own
`-march=rv32imc_zicsr_zifencei -mabi=ilp32` and ignore `NRV_ARCH`. Verify no
`AMO*` instruction is decoded (grep at P0 harness commit) to close this.

#
#    MrZ80 SSP terminal driver -- console UART on the ssp_bridge.
#
#    Register offsets: ssp/regs/ssp_regs.csv (canonical), 0x120..0x12C.
#    Polling-only (D-27): TX waits for tx_ready, RX waits for rx_avail.
#    Escape bytes are consumed by hardware before FW ever sees them (D-14).
#
#    The QEMU_NS16550 build (-DQEMU_NS16550) drives the qemu virt machine's
#    ns16550 at 0x1000_0000 instead, so the identical Forth core can be
#    smoke-tested without the stub SoC.
#

.include "../common/terminalhooks.s"

# `pause` (the multitasker's switch point, a Forth word) may clobber every scratch
# register, but callers of key and emit (accept keeps its state in x10-x12) rely on the
# hooks leaving them alone, so the waits below call it through this wrapper.
pause_safe:
  addi sp, sp, -32
  sw x1,  0(sp)
  sw x5,  4(sp)
  sw x6,  8(sp)
  sw x7,  12(sp)
  sw x10, 16(sp)
  sw x11, 20(sp)
  sw x12, 24(sp)
  sw x13, 28(sp)
  jal x1, pause
  lw x1,  0(sp)
  lw x5,  4(sp)
  lw x6,  8(sp)
  lw x7,  12(sp)
  lw x10, 16(sp)
  lw x11, 20(sp)
  lw x12, 24(sp)
  lw x13, 28(sp)
  addi sp, sp, 32
  ret

.ifdef QEMU_NS16550

# -----------------------------------------------------------------------------
# qemu virt ns16550 UART (COM1 @ 0x1000_0000) -- smoke-test path only
# -----------------------------------------------------------------------------

.equ UART_RBR_THR, 0x10000000 # receiver buffer / transmitter holding
.equ UART_FCR,   0x10000002   # FIFO control
.equ UART_LSR,   0x10000005   # line status
.equ LSR_DR,     0x01
.equ LSR_THRE,   0x20

uart_init:
  laf x14, UART_FCR
  li x15, 0x07                # enable FIFO, reset both FIFOs
  sw x15, 0(x14)
  ret

serial_emit: # ( c -- )  waits in `pause` so other tasks run
  push x1
1:laf x14, UART_LSR
  lb x15, 0(x14)
  andi x15, x15, LSR_THRE
  bne x15, zero, 2f
  jal x1, pause_safe
  j 1b
2:laf x14, UART_RBR_THR
  sb x8, 0(x14)
  drop # consume the character cell
  pop x1
  ret

serial_qemit: # ( -- ? )
  laf x14, UART_LSR
  lb x15, 0(x14)
  pushdatos
  andi x8, x15, LSR_THRE
  ret

serial_key: # ( -- c )  waits in `pause` so other tasks run
  push x1
1:laf x14, UART_LSR
  lb x15, 0(x14)
  andi x15, x15, LSR_DR
  bne x15, zero, 2f
  jal x1, pause_safe
  j 1b
2:laf x14, UART_RBR_THR
  pushdatos
  lbu x8, 0(x14)
  pop x1
  ret

serial_qkey: # ( -- ? )
  laf x14, UART_LSR
  lb x15, 0(x14)
  pushdatos
  andi x8, x15, LSR_DR
  ret

.else

# -----------------------------------------------------------------------------
# SSP bridge UART (real silicon + sim/ssp stub SoC)
# -----------------------------------------------------------------------------

.equ BRIDGE_BASE,   0x20000000
.equ UART_TXDATA,   BRIDGE_BASE + 0x120 # WO  byte lane: TX holding
.equ UART_RXDATA,   BRIDGE_BASE + 0x124 # RC  byte lane: RX FIFO pop
.equ UART_STAT,     BRIDGE_BASE + 0x128 # R   bit0 tx_ready, bit1 rx_avail, bit2 rx_overrun
.equ UART_CTRL,     BRIDGE_BASE + 0x12C # RW  bit0 en, bit1 rx_clr, bit2 tx_clr (self-clearing)
.equ WDG_PARK_KICK,  BRIDGE_BASE + 0x0B4 # WO  any write refreshes the park watchdog

.equ STAT_TX_READY, 0x01
.equ STAT_RX_AVAIL, 0x02

uart_init:
  laf x14, UART_CTRL
  li x15, 0x07                # enable, flush RX and TX FIFOs
  sw x15, 0(x14)
  ret

serial_emit: # ( c -- )  blocks until transmitter ready, in `pause` so other tasks run
  push x1
1:laf x14, UART_STAT
  lw x15, 0(x14)
  andi x15, x15, STAT_TX_READY
  bne x15, zero, 2f
  jal x1, pause_safe
  j 1b
2:laf x14, UART_TXDATA
  sb x8, 0(x14)
  drop # consume the character cell -- TOS reverts to the stack below
  pop x1
  ret

serial_qemit: # ( -- ? )
  laf x14, UART_STAT
  lw x15, 0(x14)
  pushdatos
  andi x8, x15, STAT_TX_READY
  ret

serial_key: # ( -- c )  blocks until a byte arrives
  # R30: a human at the prompt must not trip the ~0.4 s WDG_PARK (D-13): the
  # park is held for as long as the FW sits here, so refresh it while waiting.
  # Each lap also calls `pause`, so other tasks run while the monitor waits.
  push x1
1:laf x14, UART_STAT
  lw x15, 0(x14)
  andi x15, x15, STAT_RX_AVAIL
  bne x15, zero, 2f
  laf x15, WDG_PARK_KICK
  sw zero, 0(x15)             # any write re-arms (ssp_regs.csv 0x0B4)
  jal x1, pause_safe
  j 1b
2:
  laf x14, UART_RXDATA
  pushdatos
  lbu x8, 0(x14)
  pop x1
  ret

serial_qkey: # ( -- ? )
  laf x14, UART_STAT
  lw x15, 0(x14)
  pushdatos
  andi x8, x15, STAT_RX_AVAIL
  ret

.endif

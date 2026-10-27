// ssp_bridge.v -- SSP debug bridge register file (D-33 RV side, Verilog).
// Canonical map: ssp/regs/ssp_regs.csv (D-29); symbolic constants come from
// the generated ssp/rtl/ssp_regs.vh, so offsets cannot drift from the CSV
// without regmap-check failing (R-45).
//
// P1a scope (SSP_DESIGN 15): ID/CTRL/STATUS/TICK_US/ESC_CHAR/IRQ_*,
// MEM_CTL/MEM_ADDR/MEM_DATA + SNAP/LIVE regs, boundary-aligned parking
// (D-25 rev R25), micro-op sequencer (D-30) for FW MEM/IO kicks, the
// two-tier watchdog (D-13, FW-sovereignty), and UART register routing.
// Regions whose function is phased (STEP assist, BP/trap eval, panel/LED/
// SD/MBX/MAP -- P1b/P2) still DECODE per the CSV and read zero / accept-
// and-discard, so the address map is complete (gap rows 0x118 and 0xFF4+
// are the DEC_ERR_COUNT domain).
//
// Read latency: launch+1 (D-36 fabric truth): selects captured at the
// rstrb launch edge, data muxed at launch+1 -- proven stub shape
// (sim/ssp/ssp_stub_gracilis.v, bake-off R21).
//
// Parking (D-25 rev R25): the boundary decision lives INSIDE the T80
// (freeze_ok gates the BusAck grant at the T_Res of the instruction-end
// branch).  The bridge simply holds FREEZE_req_n (z_busrq_n) low while a
// park is requested; grant confirmation is BusAck.  Park sources = FW hold
// (CTRL.Z_BUSRQ_N) | panel stop-latch (tied 0 pre-P1b).  No INT-level
// gating: a level INT pending at park time is simply still pending and is
// serviced after resume (nothing lost); edge NMI survives in the T80's own
// NMI_s flopper.  STATUS.at_boundary = would_boundary latched at grant
// (1 by construction for instruction parks; 0 only for future off-boundary
// step modes via FREEZE_any).
//
// Boot sovereignty / FW hang (owner ruling R25): with !ssp_active (OSD OK
// off) every guest control is force-inactive -- monitor-disabled is
// indistinguishable from monitor-absent (P-B).  Additionally, guest
// controls, park holds and console ownership are released when the RV core
// is unwell: OSD rv_rst_n (host reset, sticky-pulsed at integration) and
// the WDG_RUN expiry (RV stalled on the bus ~1.3 ms) both assert
// rv_ctrl_ok=0.  A hung FW therefore cannot hold the guest: parks
// auto-release (WDG_PARK, ~1 s, D-13) and the escape hatch (hardware
// escape + WDG_PARK expiry) works even with FW dead.
//
// Escape (uart esc_evt) parks AND hands over the console in hardware:
// CTRL.{Z_BUSRQ_N,CONSOLE_OWN} set, HALT_REASON=4 (D-14/R24).  A same-
// cycle CTRL write loses to the escape hand-over (operator sovereignty).
//
// Shared registers MD/AR/DR/PR (G-3): FW controller lands here in P1a; the
// panel engine joins as second controller at P1b (RCW shape already).

`timescale 1 ns / 1 ps
`include "ssp_regs.vh"

module ssp_bridge (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- gracilis local bus (D-34) --------------------------
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wmask,
    input  wire        mem_rstrb,
    output wire [31:0] mem_rdata,
    output wire        mem_rbusy,           // register file: never stalls
    output wire        mem_wbusy,
    output wire        is_bridge,          // 0x2000_0xxx page hit (to top)

    // ---------------- guest clock + bus view (via z80_bus_mux) -----------
    input  wire        cpu_clk_en,        // cpu_cen RAW (never CEN-gated,
                                          //   else the engine stalls itself)
    input  wire [7:0]  cpu_din,          // cpuDataIn (peripheral/RAM mux)
    input  wire        cpu_wait_n,
    input  wire        z_busack_n,
    input  wire        z_halt_n,
    input  wire        z_m1_n,
    input  wire [2:0]  z_mc,             // MCycle   (D-08 export)
    input  wire [2:0]  z_ts,            // TState   (D-08 export)
    input  wire        z_alt,            // Alternate (D-08 export)
    input  wire        z_would_boundary, // boundary qualifier (D-25 rev R25)
    input  wire [211:0] t80_reg,        // architectural REG vector

    // ---------------- OSD / panel policy inputs ---------------------------
    input  wire        ssp_active,       // OSD OK (P-B)
    input  wire        osd_esc_en,      // OSD bit 22: Serial Escape (OM)
    input  wire        s32_disable,     // frame bit 32 escape/disable toggle
    input  wire        panel_stop,      // engine stop-latch (P1b; tie 0 now)
    input  wire        rv_rst_n,        // OSD RV-reset (host domain, R25;
                                        //   integration sticky-pulses ~1 ms)
    input  wire        rv_stalled,     // RV core waiting on bus/ALU (top)
    input  wire        rv_alive,       // RV seen fetching (top liveness)

    // ---------------- guest control outputs -------------------------------
    output wire        z_busrq_n,       // = FREEZE_req_n at T80s
    output wire        z_reset_n,       // CTRL.Z_RST_N effect (integration:
    output wire        z_wait_n,       //   AND with CPM reset stretcher)
    output wire        z_cen_gate,
    output wire        freeze_any,      // P1a constant 0 (step modes P1b)

    // ---------------- engine bus master (to z80_bus_mux) ------------------
    output reg         eng_own,        // engine in-cycle mux select (D-26)
    output reg  [15:0] eng_addr,
    output reg  [7:0]  eng_dout,
    output reg         eng_mreq_n,
    output reg         eng_iorq_n,
    output reg         eng_rd_n,
    output reg         eng_wr_n,
    output reg         eng_m1_n,       // engine cycles are never M1 (D-26)
    output reg         eng_mrd_t1,     // speculative-read trigger, T1 reads

    // ---------------- console UART ------------------------------------------
    input  wire [15:0] baud_increment, // O9B table value (to uart direct)
    output wire        uart_en,
    output wire        uart_rx_clr,
    output wire        uart_tx_clr,
    output wire [7:0]  uart_tx_wdata,
    output wire        uart_tx_wr,
    output wire        uart_rx_pop,
    input  wire [7:0]  uart_rx_rdata,
    input  wire [7:0]  uart_rx_rnext,
    input  wire        uart_tx_ready,
    input  wire        uart_rx_avail,
    input  wire        uart_rx_overrun,
    input  wire        uart_rx_push,
    output reg  [7:0]  esc_char,
    output wire        uart_esc_eff,   // OM & CTRL.esc_break_en & ssp_active
    output wire        uart_relay_en,  // OM & ssp_active: RX via relay
    input  wire        uart_esc_evt,

    // ---------------- console / park state (to top console mux) -----------
    output wire        console_own,    // fw_console_ok (D-01)
    output wire        parked,         // guest held by us (BusAck confirmed)

    // ---------------- optional IRQ line (v1 FW polls, D-27) ---------------
    output wire        ssp_irq
);

    localparam CLK_HZ     = 50;        // TICK_US prescale (50 MHz)
    localparam WDG_RUN_T  = 25'd65536;      // ~1.3 ms  (D-13 WDG_RUN band)
    localparam WDG_PARK_T = 25'd20_000_000; // ~0.4 s (D-13 WDG_PARK band:
                                             //  conservative fast release --
                                             //  live FW refreshes by kicking)

    wire [9:0] widx     = mem_addr[11:2];
    assign is_bridge    = (mem_addr[31:12] == 20'h20000);
    wire rd_fire = rst_n && mem_rstrb  && is_bridge;
    wire wr_fire = rst_n && (mem_wmask != 4'b0) && is_bridge;
    wire [7:0] w = mem_wdata[7:0];

    assign mem_rbusy = 1'b0;
    assign mem_wbusy = 1'b0;

    // offset-known table: every CSV row decodes (function may be phased);
    // unknown word offsets inside the page raise DEC_ERR_COUNT (0xFF0).
    function offset_known; input [9:0] ix;
        case (ix)
        `SSP_RIDX_ID, `SSP_RIDX_CTRL, `SSP_RIDX_TRAMP_ADDR, `SSP_RIDX_STATUS,
        `SSP_RIDX_HALT_REASON, `SSP_RIDX_PC_LATCH,
        `SSP_RIDX_SNAP_REG0, `SSP_RIDX_SNAP_REG1, `SSP_RIDX_SNAP_REG2,
        `SSP_RIDX_SNAP_REG3, `SSP_RIDX_SNAP_REG4, `SSP_RIDX_SNAP_REG5,
        `SSP_RIDX_SNAP_REG6,
        `SSP_RIDX_LIVE_REG0, `SSP_RIDX_LIVE_REG1, `SSP_RIDX_LIVE_REG2,
        `SSP_RIDX_LIVE_REG3, `SSP_RIDX_LIVE_REG4, `SSP_RIDX_LIVE_REG5,
        `SSP_RIDX_LIVE_REG6,
        `SSP_RIDX_STEP_CTL, `SSP_RIDX_BP0, `SSP_RIDX_BP1, `SSP_RIDX_BP2,
        `SSP_RIDX_BP3, `SSP_RIDX_BP_SKIP, `SSP_RIDX_TRAP_CTL,
        `SSP_RIDX_TRAP_ADDR, `SSP_RIDX_TRAP_DATA, `SSP_RIDX_MEM_CTL,
        `SSP_RIDX_MEM_ADDR, `SSP_RIDX_MEM_DATA, `SSP_RIDX_MD, `SSP_RIDX_AR,
        `SSP_RIDX_DR, `SSP_RIDX_PR, `SSP_RIDX_ENG_STAT,
        `SSP_RIDX_ENG_LOG_ADDR, `SSP_RIDX_ENG_LOG_DATA,
        `SSP_RIDX_SD_ADDR, `SSP_RIDX_SD_WDATA, `SSP_RIDX_SD_RDATA,
        `SSP_RIDX_SD_CTL, `SSP_RIDX_WDG_RUN_KICK, `SSP_RIDX_WDG_PARK_KICK,
        `SSP_RIDX_WDG_STAT, `SSP_RIDX_IRQ_EN, `SSP_RIDX_IRQ_PENDING,
        `SSP_RIDX_CONN_ROUTE, `SSP_RIDX_MBX0, `SSP_RIDX_MBX1,
        `SSP_RIDX_MBX2, `SSP_RIDX_MBX3, `SSP_RIDX_MAP0, `SSP_RIDX_MAP1,
        `SSP_RIDX_MAP2, `SSP_RIDX_MAP3, `SSP_RIDX_SSP_CTRL,
        `SSP_RIDX_LED_ADDR, `SSP_RIDX_LED_DATA0, `SSP_RIDX_LED_DATA1,
        `SSP_RIDX_FP_SW, `SSP_RIDX_FP_FN,
        `SSP_RIDX_FP_ENC_CNT, `SSP_RIDX_FP_ENC_STAT, `SSP_RIDX_ESC_CHAR,
        `SSP_RIDX_TICK_US, `SSP_RIDX_UART_TXDATA, `SSP_RIDX_UART_RXDATA,
        `SSP_RIDX_UART_STAT, `SSP_RIDX_UART_CTRL, `SSP_RIDX_DEC_ERR_COUNT:
            offset_known = 1'b1;
        default: offset_known = 1'b0;
        endcase
    endfunction

    // ------------------------------------------------ CTRL ---------------
    reg  [9:0]  ctr;
    wire        ctrl_or_rst = rst_n && rv_rst_n;   // host-reset domain
    // rv_ctrl_ok: FW may exert guest control only while the RV core itself
    // is healthy (R25).  WDG_RUN expiry also drops it (sticky until the FW
    // is reset or kicks WDG_RUN_KICK).
    reg         run_expired_l;                     // 0 = expired (active-low)
    wire        rv_ctrl_ok = ctrl_or_rst && run_expired_l;
    wire [9:0]  ctr_eff    = (ssp_active && rv_ctrl_ok) ? ctr : 10'd0;
    wire hold_fw     = ctr_eff[`SSP_BIT_CTRL_Z_BUSRQ_N];
    wire esc_brk_en  = ctr_eff[`SSP_BIT_CTRL_ESC_BREAK_EN];
    wire own_fw      = ctr_eff[`SSP_BIT_CTRL_CONSOLE_OWN];

    // ------------------------------------------------ park controller ------
    // (D-25 rev R25) boundary alignment is the T80's job; here the request
    // is just a level.  busrq_act additionally persists while the engine is
    // mid-cycle (R25/H4) so the mux never truncates an engine access.
    reg  busrq_act;                   // FREEZE_req asserted (line low)
    reg  park_act;                    // BusAck confirmed
    reg  at_boundary_q;
    reg  esc_pending;               // escape requested, park not yet taken
    reg  [3:0]  halt_reason;       // 1=fw-halt 2=bp 3=step 4=escape
                                    // 9=wdg_park expiry
    reg  [15:0] pc_latch;
    reg  [211:0] snap_q;

    wire park_req   = (hold_fw | panel_stop) & ssp_active & rv_ctrl_ok;
    wire seq_busy;
    wire busrq_keep = (park_req | (eng_own & ssp_active)) & rv_ctrl_ok;

    // ------------------------------------------------ watchdogs (D-13) -----
    // WDG_RUN: RV stalled on the bus (core hung on a peripheral that never
    // answers) for WDG_RUN_T -> run_expired_l <- 0 -> ALL guest controls
    // release (R25 sovereignty).  Refreshed while not stalled, by
    // WDG_RUN_KICK, or on any host-reset-domain transition.
    // WDG_PARK: a park held with no FW refresh for WDG_PARK_T releases the
    // guest (park_dead_l sticky; halt_reason=9).  A live FW kicks
    // WDG_PARK_KICK from its REPL loop each pass.
    reg  [24:0] wdg_run, wdg_park;
    reg         park_dead_l;                      // 0 = a park expired (sticky)
    reg         wdg_run_kick, wdg_park_kick;    // 1-cycle pulses from decode
    wire wdg_run_arm  = rst_n && rv_rst_n && rv_stalled;
    wire wdg_park_arm = busrq_act && park_act && rv_ctrl_ok;

    // single driver: park request line + grant tracking + watchdogs + park
    // stats latch (keeps every control signal one-owner, R25 review)
    always @(posedge clk) begin
        if (!rst_n) begin
            busrq_act <= 1'b0;  park_act <= 1'b0;  at_boundary_q <= 1'b0;
            wdg_run   <= 25'd0; run_expired_l <= 1'b1;
            wdg_park  <= 25'd0; park_dead_l   <= 1'b1;
        end else begin
            // ---- FREEZE request level
            if (park_req)    busrq_act <= 1'b1;
            if (!busrq_keep) busrq_act <= 1'b0;   // release / P-B / FW-dead
            park_act <= busrq_act & ~z_busack_n;
            // Grant was boundary-aligned by the T80 freeze gate: capture the
            // qualifier at the grant edge (D-25; constant 1 for P1a INSN
            // parks; FREEZE_any step modes arrive P1b).
            at_boundary_q <= park_act & (z_would_boundary | freeze_any);

            // ---- WDG_RUN
            if (wdg_run_kick) begin
                wdg_run       <= 25'd0;
                run_expired_l <= 1'b1;
            end else if (wdg_run_arm) begin
                if (wdg_run >= WDG_RUN_T) run_expired_l <= 1'b0;
                else                      wdg_run <= wdg_run + 25'd1;
            end else begin
                wdg_run <= 25'd0;                  // not stalled: refresh
            end

            // ---- WDG_PARK
            if (wdg_park_kick) begin
                wdg_park    <= 25'd0;
                park_dead_l <= 1'b1;
            end else if (!wdg_park_arm) begin
                wdg_park    <= 25'd0;              // no park held: refresh
            end else if (wdg_park >= WDG_PARK_T) begin
                park_dead_l <= 1'b0;               // dead FW console (D-13)
            end else begin
                wdg_park <= wdg_park + 25'd1;
            end
        end
    end
    // park force-release rides the rv_ctrl_ok/ssp_active gating above:
    // busrq_keep deasserts => request line drops; park_dead_l reports it.

    assign z_busrq_n   = ~(busrq_act & ssp_active & rv_ctrl_ok);
    assign z_reset_n   = ~ctr_eff[`SSP_BIT_CTRL_Z_RST_N];
    assign z_wait_n    = ~ctr_eff[`SSP_BIT_CTRL_Z_WAIT_N];
    assign z_cen_gate  =  ctr_eff[`SSP_BIT_CTRL_CEN_GATE];
    assign freeze_any  = 1'b0;          // P1a: step modes P1b (D-25)
    assign parked      = park_act;
    assign console_own = own_fw & ssp_active & rv_ctrl_ok;  // fw_console_ok

    // ------------------------------------------------ engine + arbiter -----
    // D-30 micro-op queue.  P1a primitives MEM_RD/MEM_WR/IO_RD/IO_WR,
    // FW-kick only (panel macro input joins P1b; simultaneity rule then:
    // panel wins, macros atomic).  Cycles are T80s-LITERAL (R25/H3,
    // production generics mode=1/t2write=1/iowait=0), advancing one T-state
    // per cpu_cen pulse (D-26):
    //   T1: address + MRD_T1 (mem reads); strobes inactive
    //   T2 entry: MREQ_n/iorq_n + (read: RD_n mem | write: WR_n t2write)
    //   T2 exit (wait-sensed): READ DATA CAPTURED (T80 DI_Reg discipline)
    //   io read: RD_n asserted at T2 exit, held through T3 (single-T)
    //   T3 exit: strobes release, ownership done
    reg         q_valid, q_rnw, q_isio;
    reg  [15:0] q_addr;
    reg  [7:0]  q_wdata;
    reg  [1:0]  st;                     // 0 IDLE, 1 T1, 2 T2, 3 T3
    reg  [7:0]  rd_cap;
    reg  [3:0]  eng_stat_last_op;      // 1 rd 2 wr 3 io-rd 4 io-wr
    reg         eng_err;               // sticky until ENG_STAT read
    reg  [27:0] ar_r;
    reg  [7:0]  dr_r, pr_r;
    reg         md_phys;

    assign seq_busy = q_valid | (st != 2'd0);
    wire kick     = wr_fire && (widx == `SSP_RIDX_MEM_CTL) && w[0];
    wire kick_rnw        = mem_wdata[1];
    wire kick_isio       = mem_wdata[2];
    wire kick_use_shared = mem_wdata[3];
    // Padding below is explicit and lossless (integer values identical);
    // linters flag the self-determined concat against the 28-bit LHS.
    // verilator lint_off WIDTHEXPAND
    wire [27:0] io_saddr  = { {16{1'b0}}, pr_r };       // PR = 8-bit port
    wire [27:0] mem_saddr = { {12{1'b0}}, ar_r[15:0] };  // AR LOG16 mode
    wire [27:0] sh_addr   = kick_isio ? io_saddr : mem_saddr;
    // verilator lint_on WIDTHEXPAND
    wire [27:0] kick_addr = kick_use_shared ? sh_addr : mem_addr_r;
    wire [7:0]  kick_wdat = kick_use_shared ? dr_r : mem_data_w;

    assign uart_esc_eff  = osd_esc_en & esc_brk_en & ssp_active;
    assign uart_relay_en = osd_esc_en & ssp_active;

    always @(posedge clk) begin
        if (!rst_n) begin
            q_valid <= 1'b0; st <= 2'd0; eng_own <= 1'b0;
            eng_addr <= 16'hFFFF; eng_dout <= 8'h00;
            eng_mreq_n <= 1'b1; eng_iorq_n <= 1'b1; eng_rd_n <= 1'b1;
            eng_wr_n <= 1'b1; eng_m1_n <= 1'b1; eng_mrd_t1 <= 1'b0;
            rd_cap <= 8'h00; eng_stat_last_op <= 4'd0; eng_err <= 1'b0;
        end else begin
            // completion flag: read clears (CSV ENG_STAT), errors set below
            if (rd_fire && (widx == `SSP_RIDX_ENG_STAT)) eng_err <= 1'b0;
            // enqueue (one-deep macro queue; parked-only per 9.1;
            // MD=physical needs ssp_mem_client -- P1b, R-27)
            if (kick) begin
                if (!park_act || md_phys)  eng_err <= 1'b1;
                else if (q_valid || (st != 2'd0)) eng_err <= 1'b1;
                else begin
                    q_valid <= 1'b1;
                    q_rnw   <= kick_rnw;
                    q_isio  <= kick_isio;
                    q_addr  <= kick_addr[15:0];
                    q_wdata <= kick_wdat;
                end
            end

            // engine FSM: one Z80 T-state per cpu_cen pulse (D-26)
            case (st)
            2'd0: if (q_valid && park_act) begin
                      eng_own    <= 1'b1;
                      eng_addr   <= q_addr;
                      eng_dout   <= q_wdata;
                      eng_m1_n   <= 1'b1;                      // never M1
                      eng_mrd_t1 <= ~q_isio & q_rnw;           // T1, mem reads
                      eng_mreq_n <= 1'b1; eng_iorq_n <= 1'b1;
                      eng_rd_n   <= 1'b1; eng_wr_n   <= 1'b1;
                      st         <= 2'd1;
                  end
            2'd1: if (cpu_clk_en) begin                  // T1 -> T2 entry
                      eng_mrd_t1 <= 1'b0;
                      if (q_isio) begin
                          eng_iorq_n <= 1'b0;                  // IORQ T2..T3
                      end else begin
                          eng_mreq_n <= 1'b0;                  // MREQ T2..T3
                          if (q_rnw) eng_rd_n <= 1'b0;         // RD  T2..T3
                          else       eng_wr_n <= 1'b0;          // WR  T2..T3
                      end
                      st <= 2'd2;
                  end
            2'd2: if (cpu_clk_en && cpu_wait_n) begin         // T2 -> T3
                      if (q_rnw) begin
                          rd_cap <= cpu_din;                   // DI_Reg @EoT2
                          if (q_isio) eng_rd_n <= 1'b0;       // io RD single-T
                      end
                      st <= 2'd3;
                  end
            2'd3: if (cpu_clk_en) begin                       // T3 -> done
                      eng_mreq_n <= 1'b1; eng_iorq_n <= 1'b1;
                      eng_rd_n   <= 1'b1; eng_wr_n   <= 1'b1;
                      eng_own    <= 1'b0;
                      q_valid    <= 1'b0;
                      eng_stat_last_op <= q_isio ? (q_rnw ? 4'd3 : 4'd4)
                                                : (q_rnw ? 4'd1 : 4'd2);
                      st <= 2'd0;
                  end
            endcase
        end
    end
    // Strobes match production T80s (mode=1, t2write=1, iowait=0) exactly:
    //   mem read : MREQ_n+RD_n low T2..T3      (data sampled at EoT2)
    //   mem write: MREQ_n+WR_n low T2..T3     (t2write: WR from T2 entry)
    //   io  read : IORQ_n low T2..T3, RD_n low T3 only (single-T)
    //   io  write: IORQ_n+WR_n low T2..T3
    // MRD_T1 for T1 of memory reads only (SDRAM speculative trigger, D-26);
    // M1_n never asserted by the engine (cycles are never opcode fetches).

    wire mem_data_out_is_rdcap = (eng_stat_last_op == 4'd1)
                              || (eng_stat_last_op == 4'd3);
    wire [7:0] mem_data_out = mem_data_out_is_rdcap ? rd_cap : mem_data_w;

    // ------------------------------------------------ IRQ ----------------
    reg  [11:0] irq_pending;
    reg  [11:0] irq_en;
    wire [11:0] irq_set = ({12{uart_esc_evt}} & 12'h040)      // ESC bit 6
                        | ({12{uart_rx_push}}  & 12'h020);      // RX  bit 5
    wire [11:0] w1c     = mem_wdata[11:0];
    wire [11:0] w1c_mask = { {4{mem_wmask[1]}}, {8{mem_wmask[0]}} };

    always @(posedge clk) begin
        if (!rst_n)                irq_pending <= 12'd0;
        else if (wr_fire && (widx == `SSP_RIDX_IRQ_PENDING))
            irq_pending <= (irq_pending & ~(w1c & w1c_mask)) | irq_set; // W1C
        else                       irq_pending <= irq_pending | irq_set;
    end
    assign ssp_irq = |(irq_pending & irq_en);

    // ------------------------------------------------ TICK_US ------------
    reg  [5:0]  presc;
    reg  [31:0] tick_us;
    always @(posedge clk) begin
        if (!rst_n) begin presc <= 6'd0; tick_us <= 32'd0; end
        else if (presc == CLK_HZ - 1) begin
            presc   <= 6'd0;
            tick_us <= tick_us + 32'd1;
        end else presc <= presc + 6'd1;
    end

    // ------------------------------------------------ register file ------
    reg  [15:0] tramp_addr;
    reg  [10:0] step_ctl;
    reg  [16:0] bp0, bp1, bp2, bp3;
    reg  [3:0]  bp_skip;
    reg  [2:0]  trap_ctl;
    reg  [7:0]  trap_addr_r;
    reg  [15:0] trap_data;
    reg  [27:0] mem_addr_r;
    reg  [7:0]  mem_data_w;
    reg  [27:0] sd_addr;
    reg  [7:0]  sd_wdata, sd_ctl;
    reg  [3:0]  conn_route;
    reg  [7:0]  mbx0, mbx1, mbx2, mbx3;
    reg  [3:0]  ssp_ctrl_r;
    reg  [7:0]  led_addr;
    reg  [9:0]  led_data0;
    reg  [23:0] led_data1;
    reg  [7:0]  dec_err;
    reg         uart_en_r;
    reg         uart_rx_clr_r, uart_tx_clr_r, uart_tx_wr_r;
    reg  [7:0]  uart_tx_wdata_r;
    reg  [7:0]  uart_rx_rdata_hold;      // RXDATA launch+1 presentation

    assign uart_en       = uart_en_r;
    assign uart_rx_clr   = uart_rx_clr_r;
    assign uart_tx_clr   = uart_tx_clr_r;
    assign uart_tx_wdata = uart_tx_wdata_r;
    assign uart_tx_wr    = uart_tx_wr_r;
    assign uart_rx_pop   = rd_fire && (widx == `SSP_RIDX_UART_RXDATA)
                           && uart_rx_avail;
    // R25/H5: present the popped byte at launch+1 (the pop happens at the
    // SAME launch edge, so muxing uart_rx_rdata through q_reg would return
    // the PREVIOUS byte).  Stub-proven shape (rr_rxbyte).
    always @(posedge clk)
        if (uart_rx_pop) uart_rx_rdata_hold <= uart_rx_rnext;

    // escape hand-over: park request + console taken (D-14 hardware, R24).
    // Ordered AFTER the CTRL write decode below => a same-cycle CTRL write
    // loses to the escape (operator sovereignty, G-8 spirit).
    wire esc_take = uart_esc_evt & ssp_active & rv_ctrl_ok;

    always @(posedge clk) begin
        if (!rst_n) begin
            ctr      <= `SSP_CTRL_RESET_10;
            tramp_addr <= 16'd0; step_ctl <= 11'd0;
            bp0 <= 17'd0; bp1 <= 17'd0; bp2 <= 17'd0; bp3 <= 17'd0;
            bp_skip <= 4'd0; trap_ctl <= 3'd0; trap_addr_r <= 8'd0;
            trap_data <= 16'd0;
            mem_addr_r <= 28'd0; mem_data_w <= 8'd0;
            ar_r <= 28'd0; dr_r <= 8'd0; pr_r <= 8'd0; md_phys <= 1'b0;
            sd_addr <= 28'd0; sd_wdata <= 8'd0; sd_ctl <= 8'd0;
            conn_route <= `SSP_CONN_ROUTE_RESET_4;
            mbx0 <= 8'd0; mbx1 <= 8'd0; mbx2 <= 8'd0; mbx3 <= 8'd0;
            ssp_ctrl_r <= 4'd0; led_addr <= 8'd0; led_data0 <= 10'd0;
            led_data1 <= 24'd0;
            esc_char <= `SSP_ESC_CHAR_RESET_8;
            dec_err  <= `SSP_DEC_ERR_COUNT_RESET_8;
            irq_en   <= `SSP_IRQ_EN_RESET_12;
            uart_en_r <= (`SSP_UART_CTRL_RESET & 32'h1) != 0;
            uart_rx_clr_r <= 1'b0; uart_tx_clr_r <= 1'b0;
            uart_tx_wr_r  <= 1'b0; uart_tx_wdata_r <= 8'd0;
            halt_reason <= 4'd0; pc_latch <= 16'd0; snap_q <= 212'd0;
            esc_pending <= 1'b0;
            wdg_run_kick <= 1'b0; wdg_park_kick <= 1'b0;
        end else begin
            uart_rx_clr_r <= 1'b0;               // self-clearing strobes
            uart_tx_clr_r <= 1'b0;
            uart_tx_wr_r  <= 1'b0;
            wdg_run_kick  <= 1'b0;
            wdg_park_kick <= 1'b0;

            if (rd_fire && (widx == `SSP_RIDX_HALT_REASON))
                halt_reason <= 4'd0;             // RC per CSV

            if (busrq_act & ~z_busack_n & ~park_act) begin   // park entry
                pc_latch    <= t80_reg[79:64];  // REG PC field (vector doc 1.1)
                snap_q      <= t80_reg;
                halt_reason <= esc_pending ? 4'd4 : 4'd1;  // escape | stop
                esc_pending <= 1'b0;
            end
            if (!rv_ctrl_ok && park_act)
                halt_reason <= 4'd9;             // wdg_park expiry (D-13)

            if (wr_fire) begin
                case (widx)
                `SSP_RIDX_CTRL: begin
                    // lane0 covers bits 0..7 (used: 0..5); lane1 8..9
                    if (mem_wmask[0]) ctr[5:0] <= w[5:0];  // CTRL lane 0
                    if (mem_wmask[1]) ctr[9:8] <= w[1:0];  // CTRL lane 1
                end
                `SSP_RIDX_TRAMP_ADDR: begin
                    if (mem_wmask[0]) tramp_addr[7:0]  <= w;
                    if (mem_wmask[1]) tramp_addr[15:8] <= w;
                end
                `SSP_RIDX_STEP_CTL:   step_ctl[7:0] <= w;   // P1b: mode bits
                `SSP_RIDX_BP0:      begin bp0[7:0] <= w;
                                      if (mem_wmask[2]) bp0[16] <= w[0]; end
                `SSP_RIDX_BP1:      begin bp1[7:0] <= w;
                                      if (mem_wmask[2]) bp1[16] <= w[0]; end
                `SSP_RIDX_BP2:      begin bp2[7:0] <= w;
                                      if (mem_wmask[2]) bp2[16] <= w[0]; end
                `SSP_RIDX_BP3:      begin bp3[7:0] <= w;
                                      if (mem_wmask[2]) bp3[16] <= w[0]; end
                `SSP_RIDX_BP_SKIP:    if (mem_wmask[0]) bp_skip   <= w[3:0];
                `SSP_RIDX_TRAP_CTL:   if (mem_wmask[0]) trap_ctl  <= w[2:0];
                `SSP_RIDX_TRAP_ADDR:  if (mem_wmask[0]) trap_addr_r <= w;
                `SSP_RIDX_TRAP_DATA: begin
                    if (mem_wmask[0]) trap_data[7:0]   <= w;
                    if (mem_wmask[1]) trap_data[15:8]  <= w;
                end
                `SSP_RIDX_MEM_ADDR: begin       // 28-bit: lanes 0..3
                    if (mem_wmask[0]) mem_addr_r[7:0]   <= w;
                    if (mem_wmask[1]) mem_addr_r[15:8]  <= w;
                    if (mem_wmask[2]) mem_addr_r[23:16] <= w;
                    if (mem_wmask[3]) mem_addr_r[27:24] <= w[3:0];
                end
                `SSP_RIDX_MEM_DATA:   if (mem_wmask[0]) mem_data_w <= w;
                `SSP_RIDX_MD:         if (mem_wmask[0]) md_phys    <= w[0];
                `SSP_RIDX_AR: begin
                    if (mem_wmask[0]) ar_r[7:0]   <= w;
                    if (mem_wmask[1]) ar_r[15:8]  <= w;
                    if (mem_wmask[2]) ar_r[23:16] <= w;
                    if (mem_wmask[3]) ar_r[27:24] <= w[3:0];
                end
                `SSP_RIDX_DR:         if (mem_wmask[0]) dr_r <= w;
                `SSP_RIDX_PR:         if (mem_wmask[0]) pr_r <= w;
                `SSP_RIDX_SD_ADDR: begin
                    if (mem_wmask[0]) sd_addr[7:0]   <= w;
                    if (mem_wmask[1]) sd_addr[15:8]  <= w;
                    if (mem_wmask[2]) sd_addr[23:16] <= w;
                    if (mem_wmask[3]) sd_addr[27:24] <= w[3:0];
                end
                `SSP_RIDX_SD_WDATA:   if (mem_wmask[0]) sd_wdata <= w;
                `SSP_RIDX_SD_CTL:     if (mem_wmask[0]) sd_ctl   <= w & 8'h01;
                `SSP_RIDX_WDG_RUN_KICK:  wdg_run_kick  <= 1'b1;
                `SSP_RIDX_WDG_PARK_KICK: wdg_park_kick <= 1'b1;
                `SSP_RIDX_IRQ_EN:   begin
                    if (mem_wmask[0]) irq_en[7:0]   <= w;
                    if (mem_wmask[1]) irq_en[11:8]  <= w[3:0];
                end
                `SSP_RIDX_CONN_ROUTE: if (mem_wmask[0]) conn_route <= w[3:0];
                `SSP_RIDX_MBX0:       if (mem_wmask[0]) mbx0 <= w;
                `SSP_RIDX_MBX1:       if (mem_wmask[0]) mbx1 <= w;
                `SSP_RIDX_MBX2:       if (mem_wmask[0]) mbx2 <= w;
                `SSP_RIDX_MBX3:       if (mem_wmask[0]) mbx3 <= w;
                `SSP_RIDX_SSP_CTRL:   if (mem_wmask[0]) ssp_ctrl_r <= w[3:0];
                `SSP_RIDX_LED_ADDR:   if (mem_wmask[0]) led_addr   <= w;
                `SSP_RIDX_LED_DATA0: begin
                    if (mem_wmask[0]) led_data0[7:0]  <= w;
                    if (mem_wmask[1]) led_data0[9:8]  <= w[1:0];
                end
                `SSP_RIDX_LED_DATA1: begin
                    if (mem_wmask[0]) led_data1[7:0]   <= w;
                    if (mem_wmask[1]) led_data1[15:8]  <= w;
                    if (mem_wmask[2]) led_data1[23:16] <= w;
                end
                `SSP_RIDX_ESC_CHAR:   if (mem_wmask[0]) esc_char <= w;
                `SSP_RIDX_UART_TXDATA: if (mem_wmask[0]) begin
                                          uart_tx_wdata_r <= w;
                                          uart_tx_wr_r    <= 1'b1;
                                      end
                `SSP_RIDX_UART_CTRL:  if (mem_wmask[0]) begin
                                          uart_en_r     <= w[0];
                                          uart_rx_clr_r <= w[1];
                                          uart_tx_clr_r <= w[2];
                                      end
                default: ;                     // RO/WO/counted below
                endcase
            end

            if ((rd_fire || wr_fire) && !offset_known(widx)
                && dec_err != 8'hFF)
                dec_err <= dec_err + 8'd1;     // saturating (CSV 0xFF0)

            // Escape hand-over LAST: a same-cycle CTRL write loses to the
            // escape (operator sovereignty; D-14 hardware hand-over, R25).
            if (esc_take) begin
                esc_pending                      <= 1'b1;
                ctr[`SSP_BIT_CTRL_Z_BUSRQ_N]    <= 1'b1;
                ctr[`SSP_BIT_CTRL_CONSOLE_OWN]  <= 1'b1;
            end
        end
    end

    // ------------------------------------------------ STATUS --------------
    wire [20:0] status_bits;
    assign status_bits[`SSP_BIT_STATUS_BUSACK]        = ~z_busack_n;
    assign status_bits[`SSP_BIT_STATUS_HALT_N]        = z_halt_n;
    assign status_bits[`SSP_BIT_STATUS_M1_N]          = z_m1_n;
    assign status_bits[`SSP_HI_STATUS_MC-:3]          = z_mc;
    assign status_bits[`SSP_HI_STATUS_TS-:3]          = z_ts;
    assign status_bits[`SSP_BIT_STATUS_ALT]           = z_alt;
    assign status_bits[`SSP_BIT_STATUS_CPU_RUNNING]   = z_reset_n & ~park_act;
    assign status_bits[`SSP_BIT_STATUS_SSP_ACTIVE]    = ssp_active;
    assign status_bits[`SSP_BIT_STATUS_S32]           = s32_disable;
    assign status_bits[`SSP_BIT_STATUS_FW_CONSOLE_OK] = console_own;
    assign status_bits[`SSP_BIT_STATUS_ENG_STOP_LATCH]= panel_stop;
    assign status_bits[`SSP_BIT_STATUS_SEQ_BUSY]      = seq_busy;
    assign status_bits[`SSP_BIT_STATUS_WDG_DEAD]      = ~park_dead_l;
    assign status_bits[`SSP_BIT_STATUS_AT_BOUNDARY]   = at_boundary_q;
    assign status_bits[`SSP_BIT_STATUS_OSD_ESC_EN]    = osd_esc_en;
    assign status_bits[`SSP_BIT_STATUS_RV_TRAP]       = 1'b0; // gracilis, D-37
    assign status_bits[`SSP_BIT_STATUS_RV_ALIVE]      = rv_alive;

    // ------------------------------------------------ read mux ------------
    reg  [31:0] q_reg;                 // combinational read at launch
    always @* begin
        case (widx)
        `SSP_RIDX_ID:            q_reg = `SSP_ID_RESET;
        `SSP_RIDX_CTRL:          q_reg = {22'd0, ctr};
        `SSP_RIDX_TRAMP_ADDR:    q_reg = {16'd0, tramp_addr};
        `SSP_RIDX_STATUS:        q_reg = {11'd0, status_bits};
        `SSP_RIDX_HALT_REASON:   q_reg = {28'd0, halt_reason};
        `SSP_RIDX_PC_LATCH:      q_reg = {16'd0, pc_latch};
        `SSP_RIDX_SNAP_REG0:     q_reg = snap_q[31:0];
        `SSP_RIDX_SNAP_REG1:     q_reg = snap_q[63:32];
        `SSP_RIDX_SNAP_REG2:     q_reg = snap_q[95:64];
        `SSP_RIDX_SNAP_REG3:     q_reg = snap_q[127:96];
        `SSP_RIDX_SNAP_REG4:     q_reg = snap_q[159:128];
        `SSP_RIDX_SNAP_REG5:     q_reg = snap_q[191:160];
        `SSP_RIDX_SNAP_REG6:     q_reg = {12'd0, snap_q[211:192]};
        `SSP_RIDX_LIVE_REG0:     q_reg = t80_reg[31:0];
        `SSP_RIDX_LIVE_REG1:     q_reg = t80_reg[63:32];
        `SSP_RIDX_LIVE_REG2:     q_reg = t80_reg[95:64];
        `SSP_RIDX_LIVE_REG3:     q_reg = t80_reg[127:96];
        `SSP_RIDX_LIVE_REG4:     q_reg = t80_reg[159:128];
        `SSP_RIDX_LIVE_REG5:     q_reg = t80_reg[191:160];
        `SSP_RIDX_LIVE_REG6:     q_reg = {12'd0, t80_reg[211:192]};
        `SSP_RIDX_STEP_CTL:      q_reg = {21'd0, step_ctl};
        `SSP_RIDX_BP0:           q_reg = {15'd0, bp0};
        `SSP_RIDX_BP1:           q_reg = {15'd0, bp1};
        `SSP_RIDX_BP2:           q_reg = {15'd0, bp2};
        `SSP_RIDX_BP3:           q_reg = {15'd0, bp3};
        `SSP_RIDX_BP_SKIP:       q_reg = {28'd0, bp_skip};
        `SSP_RIDX_TRAP_CTL:      q_reg = {29'd0, trap_ctl};
        `SSP_RIDX_TRAP_ADDR:     q_reg = {24'd0, trap_addr_r};
        `SSP_RIDX_TRAP_DATA:     q_reg = {16'd0, trap_data};
        `SSP_RIDX_MEM_CTL:       q_reg = {31'd0, seq_busy};
        `SSP_RIDX_MEM_ADDR:      q_reg = {4'd0, mem_addr_r};
        `SSP_RIDX_MEM_DATA:      q_reg = {24'd0, mem_data_out};
        `SSP_RIDX_MD:            q_reg = {31'd0, md_phys};
        `SSP_RIDX_AR:            q_reg = {4'd0, ar_r};
        `SSP_RIDX_DR:            q_reg = {24'd0, dr_r};
        `SSP_RIDX_PR:            q_reg = {24'd0, pr_r};
        `SSP_RIDX_ENG_STAT:      q_reg = {26'd0, eng_err, 1'b0, eng_stat_last_op};
        `SSP_RIDX_ENG_LOG_ADDR:  q_reg = {4'd0, ar_r};
        `SSP_RIDX_ENG_LOG_DATA:  q_reg = {24'd0, rd_cap};
        `SSP_RIDX_SD_CTL:        q_reg = {30'd0, sd_ctl[1:0]};
        `SSP_RIDX_WDG_STAT:      q_reg = {29'd0, wdg_park_arm,
                                          park_dead_l, run_expired_l};
        `SSP_RIDX_CONN_ROUTE:    q_reg = {28'd0, conn_route};
        `SSP_RIDX_MBX0:          q_reg = {24'd0, mbx0};
        `SSP_RIDX_MBX1:          q_reg = {24'd0, mbx1};
        `SSP_RIDX_MBX2:          q_reg = {24'd0, mbx2};
        `SSP_RIDX_MBX3:          q_reg = {24'd0, mbx3};
        `SSP_RIDX_SSP_CTRL:      q_reg = {28'd0, ssp_ctrl_r};
        `SSP_RIDX_LED_ADDR:      q_reg = {24'd0, led_addr};
        `SSP_RIDX_LED_DATA0:     q_reg = {22'd0, led_data0};
        `SSP_RIDX_LED_DATA1:     q_reg = {8'd0, led_data1};
        `SSP_RIDX_ESC_CHAR:      q_reg = {24'd0, esc_char};
        `SSP_RIDX_TICK_US:       q_reg = tick_us;
        `SSP_RIDX_UART_RXDATA:   q_reg = {24'd0, uart_rx_rdata_hold};
        `SSP_RIDX_UART_STAT:     q_reg = {29'd0, uart_rx_overrun,
                                         uart_rx_avail, uart_tx_ready};
        `SSP_RIDX_UART_CTRL:     q_reg = {31'd0, uart_en_r};
        `SSP_RIDX_DEC_ERR_COUNT: q_reg = {24'd0, dec_err};
        default:                 q_reg = 32'h0;    // phased regions read 0
        endcase
    end

    reg  [31:0] q_hold;               // launch+1 presentation (D-36)
    reg         rr_bridge;
    always @(posedge clk) begin
        rr_bridge <= mem_rstrb && is_bridge;
        q_hold    <= q_reg;
    end
    assign mem_rdata = rr_bridge ? q_hold : 32'h0;

endmodule

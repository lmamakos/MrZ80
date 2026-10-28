// ssp_top.v -- SSP subsystem wrapper (D-33: RV side, Verilog; the seam to
// the VHDL Z80/CPM world is this module's port list).
//
// Core: FemtoRV32-gracilis (D-37, R23 owner ruling), ADDR_WIDTH=30 (D-34).
// Memory map (SSP_DESIGN 5.2):
//   0x0000_0000  MROM 64K  (core-visible; writable only in the dictionary
//                            window 0x4400..0x10000 -- D-35 build/mount
//                            surface; illegal core writes counted, never land)
//   0x1000_0000  RV RAM 64K  byte-enable
//   0x2000_0000  ssp_bridge 4K
//   else         decoder error (reads 0, counted)
// Memories are explicit ssp_sdp_ram instances (D-36): synthesis resolves the
// VHDL altsyncram wrapper (bake-off proven shape, R21); Verilator picks up
// the behavioral twin sim/ssp/ssp_sdp_ram.v.  Launch+1 read latency is
// native to gracilis' rstrb protocol (mem_rbusy tied 0).
//
// Console mux (D-01/D-14/D-19, R24 OQ-22 byte-relay, R25/H6 fix):
//   snac_txd   = (console_own & CONN_ROUTE.out_snac) ? monitor_uart_tx
//                                                    : z80_serial_tx
//                [R26: owner rule R25 + D-19 sink policy.  An interim R26
//                edit dropped the Z80 path -- wrong: MrZ80.sv routes the
//                Z80's serial_tx to the SNAC, so it must pass through.]
//   z80_rxd  = !ssp_active ? raw pin           (P-B: monitor-disabled is
//                                                indistinguishable from
//                                                monitor-absent, R-43)
//              :  !osd_esc_en ? raw pin          (OM off: bit-transparent)
//              :  console_own ? idle high        (parked REPL: Z80 gets
//                                                no operator bytes)
//              :  relay_txd                      (OM on: filtered+re-timed
//                                                stream, ESC consumed)
// The relay path deserializes from the raw pin and re-emits, so with OM on
// the Z80 sees each byte exactly once.  Ownership = ssp_active &&
// rv_ctrl_ok && CTRL.CONSOLE_OWN; escape sets it in hardware (bridge).
//
// Boot sovereignty (owner ruling R25): the Z80 must boot and run with the
// RV core halted, absent, or hung.  CONSOLE_OWN resets 0 (Z80 owns the
// SNAC at power); all CTRL Z80-controls and park holds release on
// !ssp_active (P-B), on OSD rv_rst_n (host reset hatch), and via the
// bridge's WDG_RUN expiry (RV hung ~1.3 ms).  Monitor entry never depends
// on FW liveness: the hardware escape parks the Z80 by itself; a dead FW
// then auto-releases the park (WDG_PARK, D-13) after ~0.4 s.
//
// "G aaaa" (D-02, D-39): the bridge exports tramp_arm/tramp_target (CTRL.TRAMP_EN
// / TRAMP_ADDR) and takes tramp_done, which hardware-clears TRAMP_EN.  The reset
// vent and the reset-vector JP injection are Z80-side logic in ssp_tramp.vhd at
// the CPM boundary (verified against the real T80, sim/tb_tramp.vhd).  FW order:
// arm + vent while parked, then release reset and drop the park together.
//
// P1b mounts (OSD MROM/MPKG download write port) hook the spare ROM write
// port `dl_*` below (currently tied inactive at the integrator).

`timescale 1 ns / 1 ps
`include "ssp_regs.vh"

module ssp_top #(
    // Factory ROM image (D-38) for the MROM's altsyncram init_file; path relative
    // to the Quartus project directory.  Simulation ignores it (+ROM/$readmemh).
    parameter MROM_INIT = "ssp/fw/forth_rom.mif"
) (
    input  wire        clk,             // clk_sys 50 MHz (shared domain)
    input  wire        rst_n,         // subsystem reset (= Z80 reset now;
                                     //   monitor-only mount domain is P1b)

    // ---- OSD / panel policy ----------------------------------------------
    input  wire        osd_ok,        // OSD bit 20: monitor enable
    input  wire        osd_esc_en,    // OSD bit 22: Serial Escape (OM)
    input  wire        esc_disable,   // panel frame bit 32 toggle (P1b: fp)
    input  wire        panel_stop,    // panel STOP latch (P1b: fp_engine)
    input  wire [15:0] baud_increment,// O9B table value (shared SNAC truth)

    // ---- Z80 boundary (via z80_bus_mux at the CPM core, D-26) ----------
    input  wire        cpu_clk_en_raw,// cpu_cen UNGATED (engine clock, R25/M6;
                                      //   the gated copy is consumed by the T80
                                      //   at the CPM core, not here -- P1a)
    input  wire [7:0]  cpu_din,     // cpuDataIn
    input  wire        cpu_wait_n,
    input  wire        z_busack_n,
    input  wire        z_halt_n,
    input  wire        z_m1_n,
    input  wire [2:0]  z_mc,         // D-08 exports (T80s R25 mod)
    input  wire [2:0]  z_ts,
    input  wire        z_alt,
    input  wire        z_would_boundary,  // D-25 rev R25 boundary qualifier
    input  wire [211:0] t80_reg,
    output wire        z_busrq_n,    // = T80s FREEZE_req_n
    output wire        z_reset_n,
    output wire        z_wait_n,
    output wire        z_cen_gate,
    // trampoline / G aaaa (D-02, D-39): to ssp_tramp.vhd at the CPM boundary
    output wire        tramp_arm,
    output wire [15:0] tramp_target,
    input  wire        tramp_done,
    output wire        freeze_any,   // 0 in P1a (step modes P1b)
    // engine master (mux inputs)
    output wire        eng_own,
    output wire [15:0] eng_addr,
    output wire [7:0]  eng_dout,
    output wire        eng_mreq_n,
    output wire        eng_iorq_n,
    output wire        eng_rd_n,
    output wire        eng_wr_n,
    output wire        eng_m1_n,
    output wire        eng_mrd_t1,

    // ---- RV host control (R25 sovereignty hatch) -------------------------
    input  wire        rv_rst_n,     // OSD "Reset SSP" (integration holds a
                                     //   ~1 ms sticky pulse; plain level here)

    // ---- serial ----------------------------------------------------------
    input  wire        snac_rxd,     // SNAC io0 (pin level, async)
    output wire        snac_txd,     // SNAC io1
    output wire        z80_rxd,    // to Z80 ACIA RX wire
    input  wire        z80_txd,    // from Z80 ACIA TX wire

    // ---- misc -------------------------------------------------------------
    output wire        ssp_irq,      // to core (unused by v1 FW, D-27)
    output wire        rv_alive,     // RV seen fetching (liveness, R25)
    // OSD download mount path (P1b): held-reset ROM write port
    input  wire        dl_wr,
    input  wire [15:0] dl_addr,
    input  wire [31:0] dl_wdata,
    // diagnostics (sim / lamp chrome)
    output reg  [31:0] dbg_rom_illegal_writes,
    output reg  [31:0] dbg_bus_errs
);

    wire ssp_active = osd_ok & ~esc_disable;

    // ------------------------------------------------ core ----------------
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wmask;
    wire [31:0] mem_rdata;
    wire        mem_rstrb, mem_rbusy, mem_wbusy;

    assign mem_rbusy = 1'b0;                   // launch+1 native (D-36)
    assign mem_wbusy = 1'b0;

    // RV liveness (R25; synthesizable since R31).  The first version read the
    // gracilis FSM through a hierarchical reference inside `synthesis
    // translate_off` -- which Quartus skips, so on hardware both wires were
    // undriven (rv_alive stuck low, found by the standalone synthesis probe).
    // Derived from the bus protocol instead, identically in simulation and
    // synthesis:
    //   rv_stalled = 0   mem_rbusy/mem_wbusy are tied 0 (launch+1 is native,
    //                    D-36), so the core can never be held waiting on the
    //                    fabric; WDG_RUN therefore never arms.
    //   rv_alive         the core issued a read strobe within the last 65 535
    //                    clocks (1.3 ms).  Every instruction fetch is a read, so
    //                    a running core -- even a polling loop -- keeps it set;
    //                    a hung or reset core lets it decay.
    wire rv_stalled = 1'b0;
    reg [15:0] alive_cnt;
    always @(posedge clk) begin
        if (!rst_n || !rv_rst_n) alive_cnt <= 16'd0;
        else if (mem_rstrb)      alive_cnt <= 16'hFFFF;
        else if (alive_cnt != 16'd0)
                                 alive_cnt <= alive_cnt - 16'd1;
    end
    assign rv_alive = (alive_cnt != 16'd0);

    FemtoRV32 #(
        .ADDR_WIDTH (30),                      // D-34
        .RESET_ADDR (32'h0000_0000)
    ) core (
        .clk               (clk),
        .mem_addr          (mem_addr),
        .mem_wdata         (mem_wdata),
        .mem_wmask         (mem_wmask),
        .mem_rdata         (mem_rdata),
        .mem_rstrb         (mem_rstrb),
        .mem_rbusy         (mem_rbusy),
        .mem_wbusy         (mem_wbusy),
        .interrupt_request (1'b0),            // polled FW (D-27)
        .reset             (rst_n & rv_rst_n) // active-low ("set to 0");
                                             // OSD hatch R25 excludes only the
                                             // host -- fabric/CTRL keep state
    );

    // ------------------------------------------------ decode -------------
    wire is_rom    = (mem_addr[31:16] == 16'h0000);
    wire is_rram   = (mem_addr[31:16] == 16'h1000);
    wire [13:0] ram_ix = mem_addr[15:2];

    wire wr_fire = rst_n && (mem_wmask != 4'b0);
    wire dict_window = (mem_addr[15:0] >= 16'h4400);   // D-35

    wire rom_core_we  = wr_fire && is_rom && dict_window;
    wire rom_dl_we    = dl_wr;                            // P1b mount path
    wire rom_we       = rom_core_we | rom_dl_we;         // dl wins (rare)
    wire [13:0] rom_waddr = rom_dl_we ? dl_addr[15:2] : ram_ix;
    wire [31:0] rom_wdata = rom_dl_we ? dl_wdata : mem_wdata;
    wire [3:0]  rom_be    = rom_dl_we ? 4'b1111 : mem_wmask;
    wire rram_we   = wr_fire && is_rram;

    wire [31:0] q_rom, q_rram;
    ssp_sdp_ram #(.INIT_FILE (MROM_INIT)) u_mrom (
        .address_w (rom_waddr),
        .address_r (ram_ix),
        .clock     (clk),
        .data_w    (rom_wdata),
        .byteena   (rom_be),
        .wren      (rom_we),
        .q         (q_rom)
    );
    ssp_sdp_ram u_rram (
        .address_w (ram_ix),
        .address_r (ram_ix),
        .clock     (clk),
        .data_w    (mem_wdata),
        .byteena   (mem_wmask),
        .wren      (rram_we),
        .q         (q_rram)
    );

    // ------------------------------------------------ bridge + UART -------
    wire        is_bridge;
    wire [31:0] bridge_rdata;
    wire        uart_rx_pop;
    wire        uart_en, uart_rx_clr, uart_tx_clr, uart_tx_wr;
    wire [7:0]  uart_tx_wdata, uart_esc_char, uart_rx_rdata, uart_rx_rnext;
    wire        uart_tx_ready, uart_rx_avail, uart_rx_overrun, uart_rx_push;
    wire        uart_esc_evt, uart_esc_eff, uart_relay_en, conn_out_snac;
    wire        mon_txd, relay_txd;
    wire        console_own, parked;

    ssp_bridge u_bridge (
        .clk (clk), .rst_n (rst_n),
        .mem_addr (mem_addr), .mem_wdata (mem_wdata), .mem_wmask (mem_wmask),
        .mem_rstrb (mem_rstrb), .mem_rdata (bridge_rdata),
        .mem_rbusy (/*inert*/), .mem_wbusy (/*inert*/), .is_bridge (is_bridge),
        .cpu_clk_en (cpu_clk_en_raw), .cpu_din (cpu_din),
        .cpu_wait_n (cpu_wait_n),
        .z_busack_n (z_busack_n), .z_halt_n (z_halt_n), .z_m1_n (z_m1_n),
        .z_mc (z_mc), .z_ts (z_ts), .z_alt (z_alt),
        .z_would_boundary (z_would_boundary), .t80_reg (t80_reg),
        .ssp_active (ssp_active), .osd_esc_en (osd_esc_en),
        .s32_disable (esc_disable), .panel_stop (panel_stop),
        .rv_rst_n (rv_rst_n), .rv_stalled (rv_stalled), .rv_alive (rv_alive),
        .z_busrq_n (z_busrq_n), .z_reset_n (z_reset_n),
        .z_wait_n (z_wait_n), .z_cen_gate (z_cen_gate),
        .freeze_any (freeze_any),
        .eng_own (eng_own), .eng_addr (eng_addr), .eng_dout (eng_dout),
        .eng_mreq_n (eng_mreq_n), .eng_iorq_n (eng_iorq_n),
        .eng_rd_n (eng_rd_n), .eng_wr_n (eng_wr_n),
        .eng_m1_n (eng_m1_n), .eng_mrd_t1 (eng_mrd_t1),
        .baud_increment (baud_increment),
        .uart_en (uart_en), .uart_rx_clr (uart_rx_clr),
        .uart_tx_clr (uart_tx_clr), .uart_tx_wdata (uart_tx_wdata),
        .uart_tx_wr (uart_tx_wr), .uart_rx_pop (uart_rx_pop),
        .uart_rx_rdata (uart_rx_rdata), .uart_rx_rnext (uart_rx_rnext),
        .uart_tx_ready (uart_tx_ready), .uart_rx_avail (uart_rx_avail),
        .uart_rx_overrun (uart_rx_overrun), .uart_rx_push (uart_rx_push),
        .esc_char (uart_esc_char), .uart_esc_eff (uart_esc_eff),
        .uart_relay_en (uart_relay_en), .conn_out_snac (conn_out_snac),
        .tramp_arm (tramp_arm), .tramp_target (tramp_target),
        .tramp_done (tramp_done),
        .uart_esc_evt (uart_esc_evt),
        .console_own (console_own), .parked (parked),
        .ssp_irq (ssp_irq)
    );

    ssp_uart u_uart (
        .clk (clk), .rst_n (rst_n),
        .baud_increment (baud_increment),
        .en (uart_en), .rx_clr (uart_rx_clr), .tx_clr (uart_tx_clr),
        .tx_ready (uart_tx_ready), .rx_avail (uart_rx_avail),
        .rx_overrun (uart_rx_overrun),
        .rx_pop (uart_rx_pop), .rx_rdata (uart_rx_rdata),
        .rx_rnext (uart_rx_rnext),
        .tx_wdata (uart_tx_wdata), .tx_wr (uart_tx_wr),
        .esc_char (uart_esc_char), .esc_eff (uart_esc_eff),
        .relay_en (uart_relay_en), .parked (parked),
        .console_own (console_own),
        .snac_rxd (snac_rxd), .relay_txd (relay_txd), .mon_txd (mon_txd),
        .esc_evt (uart_esc_evt), .rx_push (uart_rx_push)
    );

    // ------------------------------------------------ read mux ------------
    // launch+1: q_* already registered by the RAM IP; the *select* is
    // captured at the rstrb launch edge (R21 proven shape).  Unknown
    // regions read 0 and are counted in dbg_bus_errs below.
    reg rr_rom, rr_rram, rr_bridge;
    always @(posedge clk) begin
        if (mem_rstrb) begin
            rr_rom    <= is_rom;
            rr_rram   <= is_rram;
            rr_bridge <= is_bridge;
        end
    end
    assign mem_rdata = rr_rom    ? q_rom        :
                      rr_rram   ? q_rram       :
                      rr_bridge ? bridge_rdata : 32'h0;

    // ------------------------------------------------ console mux ---------
    // TX: the console owner drives the pin (R25), and the monitor only when
    // CONN_ROUTE.out_snac routes its output to the SNAC (D-19 policy, HW
    // fail-safe default 1).  Otherwise the Z80 ACIA TX passes through:
    // in MrZ80.sv the Z80's serial_tx IS the SNAC TX (USER_OUT[1]), so
    // CP/M console output must reach the pin whenever the Z80 owns it.
    // The monitor is therefore silent until the operator escapes (R25 boot
    // sovereignty).  [R26 erratum: an interim R26 edit gated TX by out_snac
    // alone, which would have dropped all Z80 output once integrated.]
    // RX selection per header block (R25/H6):
    // relay and raw paths are mutually exclusive -- no byte duplication.
    assign snac_txd  = (console_own & conn_out_snac) ? mon_txd : z80_txd;
    assign z80_rxd = (!ssp_active || !osd_esc_en) ? snac_rxd :
                       console_own                  ? 1'b1       :
                                                    relay_txd;

    // ------------------------------------------------ diagnostics --------
    always @(posedge clk) begin
        if (!rst_n) begin
            dbg_rom_illegal_writes <= 32'd0;
            dbg_bus_errs           <= 32'd0;
        end else begin
            if (wr_fire && is_rom && !dict_window)
                dbg_rom_illegal_writes <= dbg_rom_illegal_writes + 32'd1;
            if ((mem_rstrb || wr_fire) && !(is_rom || is_rram || is_bridge))
                dbg_bus_errs <= dbg_bus_errs + 32'd1;
        end
    end

endmodule

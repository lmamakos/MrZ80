// p1a_sim_top.v -- P1a "first light" sim harness top (D-28 lane 1):
// real ssp_top (gracilis + bridge + uart) against the behavioural Z80 BFM,
// pin-level SNAC serial in/out via DPI (tb_putc / tb_rx_poll).
//
// Plusargs:  +ROM=file  MROM init (hex words, 16K)   [default
//            ssp/fw/build/mecrisp-ssp-p1a.hex]
//            +DUMP=file   dump MROM on dump_req (dict build)
//            +OSD_OK=0/1  OSD OK policy (default 1)
//            +OM=0/1      OSD Serial-Escape switch (default 0)
//            +WAIT        enable engine mem-read wait injection
//            +RVRST       OSD RV-reset hatch exercise: pulse rv_rst_n low
//                         for ~1 ms at +RVRST_AT cycles (default 3_000_000)
//            +NOGUEST     hold the guest in reset (SSP-alone debug)
//
// Console pins are electrical: snac_rxd is serialized at the real O9B
// 115200 rate (increment 2416 @ 50 MHz); snac_txd is deserialized at bit
// centres into tb_putc.  The guest ACIA RX model lives in the BFM.

`timescale 1 ns / 1 ps

module ssp_p1a_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        dump_req,         // 1-cycle: dump MROM -> +DUMP
    // diagnostics read by the C++ harness (left unconnected by the tb)
    output wire [31:0] dbg_rom_illegal_writes,
    output wire [31:0] dbg_bus_errs,
    output wire [31:0] dbg_guest_rx,         // bytes the guest ACIA model received
    output wire [31:0] dbg_freeze_acc        // park grants the guest CPU accepted
);

    import "DPI-C" function void tb_putc(int c);
    import "DPI-C" function int  tb_rx_poll();

    localparam [15:0] BAUD = 16'd2416;      // 115200 x16 @ 50 MHz (O9B)

    // ---- OSD policy --------------------------------------------------------
    logic osd_ok, om;
    initial begin
        int v;
        osd_ok = 1'b1;
        if ($value$plusargs("OSD_OK=%d", v)) osd_ok = v[0];
        om = 1'b0;
        if ($value$plusargs("OM=%d", v))    om = v[0];
    end
    wire inject_wait = $test$plusargs("WAIT");
    wire no_guest    = $test$plusargs("NOGUEST");

    // ---- rv_rst_n hatch exercise (+RVRST) ----------------------------------
    logic rv_rst_n;
    int   rvrst_at;
    int   rvrst_cnt;
    initial begin
        rv_rst_n = 1'b1;
        rvrst_at = 3_000_000;
        if ($value$plusargs("RVRST_AT=%d", rvrst_at)) ;
    end
    always @(posedge clk) begin
        if (rvrst_cnt > 0) begin
            rvrst_cnt <= rvrst_cnt - 1;
            if (rvrst_cnt == 1) rv_rst_n <= 1'b1;
        end
    end
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("RVRST") && tb_cycle == rvrst_at
            && rvrst_cnt == 0 && rv_rst_n == 1'b1) begin
            rv_rst_n  <= 1'b0;               // ~1 ms OSD-style pulse
            rvrst_cnt <= 50_000;
        end
    end
    int unsigned tb_cycle;
    always @(posedge clk) tb_cycle <= tb_cycle + 1;

    // ---- DUT + guest -------------------------------------------------------
    wire        snac_rxd, snac_txd, guest_rxd, guest_txd;
    wire        cpu_cen;
    wire        z_busrq_n, z_reset_n, z_wait_n, z_cen_gate, freeze_any;
    wire        z_busack_n, would_boundary, z_m1_n, z_halt_n;
    wire        tramp_arm, tramp_done;
    wire [15:0] tramp_target;
    wire [15:0] cpu_addr_bfm;
    wire [7:0]  cpu_din_bfm;
    wire        cpu_wait_n_bfm;
    wire [211:0] t80_reg;
    wire        eng_own;
    wire [15:0] eng_addr;
    wire [7:0]  eng_dout;
    wire        eng_mreq_n, eng_iorq_n, eng_rd_n, eng_wr_n, eng_m1_n;
    wire        eng_mrd_t1;
    wire        ssp_irq, rv_alive;


    // debug taps from the BFM
    wire [31:0] fetch_count, guest_rx_count, io_wr_count, freeze_accept_count;
    wire [7:0]  guest_rx_last, io_wr_port, io_wr_data;
    wire        parked_dbg;

    // guest sees its own reset stretched like the CPM stretcher
    wire guest_rst_n = rst_n & ~no_guest;

    // Guest ACIA TX wire: idle-high (no ACIA TX model in P1a; the BFM only
    // models the guest RX byte sink).  Without this the mux would expose an
    // undriven (0) line whenever the monitor does not own the console.
    assign guest_txd = 1'b1;

    ssp_top u_dut (
        .clk (clk), .rst_n (rst_n),
        .osd_ok (osd_ok), .osd_esc_en (om),
        .esc_disable (1'b0), .panel_stop (1'b0),
        .baud_increment (BAUD),
        .cpu_clk_en_raw (cpu_cen),
        .cpu_din (cpu_din_bfm), .cpu_wait_n (cpu_wait_n_bfm),
        .z_busack_n (z_busack_n), .z_halt_n (z_halt_n), .z_m1_n (z_m1_n),
        .z_mc (3'd1), .z_ts (3'd1), .z_alt (1'b0),
        .z_would_boundary (would_boundary), .t80_reg (t80_reg),
        .z_busrq_n (z_busrq_n), .z_reset_n (z_reset_n),
        .z_wait_n (z_wait_n), .z_cen_gate (z_cen_gate),
        .freeze_any (freeze_any),
        .tramp_arm (tramp_arm), .tramp_target (tramp_target),
        .tramp_done (tramp_done),
        .eng_own (eng_own), .eng_addr (eng_addr), .eng_dout (eng_dout),
        .eng_mreq_n (eng_mreq_n), .eng_iorq_n (eng_iorq_n),
        .eng_rd_n (eng_rd_n), .eng_wr_n (eng_wr_n),
        .eng_m1_n (eng_m1_n), .eng_mrd_t1 (eng_mrd_t1),
        .rv_rst_n (rv_rst_n),
        .snac_rxd (snac_rxd), .snac_txd (snac_txd),
        .guest_rxd (guest_rxd), .guest_txd (guest_txd),
        .ssp_irq (ssp_irq), .rv_alive (rv_alive),
        .dl_wr (1'b0), .dl_addr (16'd0), .dl_wdata (32'd0),
        .dbg_rom_illegal_writes (dbg_rom_illegal_writes),
        .dbg_bus_errs (dbg_bus_errs)
    );

    z80_bfm u_guest (
        .clk (clk), .rst_n (guest_rst_n),
        .cen_gate_n (z_cen_gate),
        .cpu_cen (cpu_cen),
        .freeze_req_n (z_busrq_n),
        .z_reset_n (z_reset_n),
        .tramp_arm (tramp_arm), .tramp_target (tramp_target),
        .tramp_done (tramp_done),
        .busack_n (z_busack_n),
        .would_boundary (would_boundary),
        .t80_reg (t80_reg),
        .m1_n (z_m1_n),
        .cpu_addr (cpu_addr_bfm), .cpu_din (cpu_din_bfm),
        .cpu_wait_n (cpu_wait_n_bfm),
        .eng_own (eng_own), .eng_addr (eng_addr), .eng_dout (eng_dout),
        .eng_mreq_n (eng_mreq_n), .eng_iorq_n (eng_iorq_n),
        .eng_rd_n (eng_rd_n), .eng_wr_n (eng_wr_n), .eng_m1_n (eng_m1_n),
        .guest_rxd (guest_rxd), .baud_increment (BAUD),
        .inject_wait (inject_wait),
        .fetch_count (fetch_count),
        .guest_rx_count (guest_rx_count), .guest_rx_last (guest_rx_last),
        .io_wr_port (io_wr_port), .io_wr_data (io_wr_data),
        .io_wr_count (io_wr_count),
        .parked_dbg (parked_dbg),
        .freeze_accept_count (freeze_accept_count)
    );

    // ------------------------------------------------------------- serial --
    // RX: tb chars -> real 8N1 waveforms on snac_rxd using the SAME O9B
    // fractional divider as the DUT (tick = overflow of a 16-bit accumulator
    // adding `baud_increment`; 16 ticks per bit => identical bit rate;
    // structural pacing: next byte loads only when the line is idle).
    reg [15:0] sb_acc;
    reg [3:0]  sb_edge;                   // tick within bit (0..15)
    reg [3:0]  sb_bit;                   // bit index 0(start)..9(stop)
    reg [9:0]  sb_frame;                // {stop,d7..d0,start}
    reg        sb_busy;
    int        rxchar;
    int        rx_gap;                    // +RXGAP=<cycles>: idle gap between
    int        sb_wait;                   // bytes.  A TX-busy Mecrisp kernel
    initial begin                       // (poll period ~4.3k cycles while it
        rx_gap = 0;                     // emits at 115200) can overrun the RX
        sb_wait = 0;                    // FIFO (128 bytes since R29) against a line-rate sender;
        if ($value$plusargs("RXGAP=%d", rx_gap)) ;  // pace the terminal
    end
    wire [16:0] sb_sum  = {1'b0, sb_acc} + {1'b0, BAUD};
    wire        sb_tick = sb_sum[16];

    assign snac_rxd = sb_busy ? sb_frame[0] : 1'b1;

    always @(posedge clk) begin
        sb_acc <= sb_sum[15:0];
        if (!rst_n) begin
            sb_busy <= 1'b0; sb_edge <= 4'd0; sb_bit <= 4'd0;
            sb_frame <= 10'h3FF;
        end else if (!sb_busy) begin
            if (sb_wait > 0) sb_wait <= sb_wait - 1;
            rxchar = (sb_wait == 0) ? tb_rx_poll() : -1;
            if (rxchar >= 0) begin
                sb_frame <= {1'b1, rxchar[7:0], 1'b0};
                sb_busy  <= 1'b1;        // start bit drives low NOW
                sb_edge  <= 4'd0;
                sb_bit   <= 4'd0;
                sb_acc   <= 16'd0;
                sb_wait  <= rx_gap;
            end
        end else if (sb_tick) begin
            if (sb_edge == 4'd15) begin
                sb_edge  <= 4'd0;
                sb_frame <= {1'b1, sb_frame[9:1]};
                if (sb_bit == 4'd9) sb_busy <= 1'b0;      // stop field done
                else                sb_bit  <= sb_bit + 4'd1;
            end else begin
                sb_edge <= sb_edge + 4'd1;
            end
        end
    end

    // TX: deserialize snac_txd at bit centres (start edge re-biases the
    // divider by half a bit, centres at ticks 7/23/../135, stop at 150 --
    // mirrors ssp_uart RX exactly).
    reg [1:0] tx_sync;
    always @(posedge clk) tx_sync <= {tx_sync[0], snac_txd};
    wire txd = tx_sync[1];
    reg txd_q;                            // edge detection (resync discipline:
    always @(posedge clk) txd_q <= txd;   // lock ONLY on a true h->l edge)

    reg [15:0] td_acc;
    reg [7:0]  td_tcnt;
    reg [7:0]  td_bits;
    reg        td_act;
    wire [16:0] td_sum  = {1'b0, td_acc} + {1'b0, BAUD};
    wire        td_tick = td_sum[16];

    always @(posedge clk) begin
        td_acc <= td_sum[15:0];
        if (!rst_n) begin
            td_act <= 1'b0; td_tcnt <= 8'd0; td_bits <= 8'hFF;
        end else if (td_act && td_tick) begin
            td_tcnt <= td_tcnt + 8'd1;
            if      (td_tcnt == 8'd7)   begin if (txd) begin td_act <= 1'b0;
                                                  if (sim_dbg) $display("[tb-tx @%0d] false start abort", tb_cycle);
                                              end
                  end else if (td_tcnt == 8'd23)  td_bits[0] <= txd;
            else if (td_tcnt == 8'd39)  td_bits[1] <= txd;
            else if (td_tcnt == 8'd55)  td_bits[2] <= txd;
            else if (td_tcnt == 8'd71)  td_bits[3] <= txd;
            else if (td_tcnt == 8'd87)  td_bits[4] <= txd;
            else if (td_tcnt == 8'd103) td_bits[5] <= txd;
            else if (td_tcnt == 8'd119) td_bits[6] <= txd;
            else if (td_tcnt == 8'd135) td_bits[7] <= txd;
            else if (td_tcnt == 8'd150) begin
                td_act <= 1'b0;
                if (sim_dbg) $display("[tb-tx @%0d] byte %02x stop=%b", tb_cycle,
                                      td_bits, txd);
                if (txd) tb_putc(int'({1'b0, td_bits}));   // valid stop
            end
        end else if (!td_act && txd == 1'b0 && txd_q) begin
            if (sim_dbg) $display("[tb-tx @%0d] lock start", tb_cycle);
            td_act  <= 1'b1;
            td_acc  <= 16'd32768;       // half-bit pre-bias to centre sampling
            td_tcnt <= 8'd0;
        end
    end

    // ------------------------------------------------ ROM init + dump -----
    string romfile, dumpfile;
    initial begin
        if (!$value$plusargs("ROM=%s",  romfile))  romfile  = "ssp/fw/build/mecrisp-ssp-p1a.hex";
        if (!$value$plusargs("DUMP=%s", dumpfile)) dumpfile = "";
        $display("[p1a] MROM <- %s", romfile);
        $readmemh(romfile, u_dut.u_mrom.mem);
    end

    always @(posedge clk) begin
        if (dump_req && (dumpfile != "")) begin
            $writememh(dumpfile, u_dut.u_mrom.mem);
            $display("[p1a] MROM dumped -> %s", dumpfile);
        end
    end

    // ------------------------------------------------ sim debug dump -----
  wire sim_dbg = $test$plusargs("DBG");
    // event traces: escape hand-over, console ownership, monitor TX bytes
    always @(posedge clk) begin
        if (sim_dbg && rst_n && u_dut.u_uart.byte_done)
            $display("[p1a-rx  @%0d] byte %02x (stop=%b eff=%b parked=%b own=%b)",
                     tb_cycle, u_dut.u_uart.rx_byte, u_dut.u_uart.rx_stop,
                     u_dut.u_uart.esc_eff, u_dut.parked, u_dut.console_own);
        if (sim_dbg && rst_n && u_dut.u_uart.esc_evt)
            $display("[p1a-evt @%0d] ESC matched -> park+console", tb_cycle);
        if (sim_dbg && rst_n && u_dut.u_uart.tx_wr)
            $display("[p1a-tx  @%0d] mon tx_wr %02x (own=%b)", tb_cycle,
                     u_dut.u_uart.tx_wdata, u_dut.console_own);
    end
    reg own_q;
    always @(posedge clk) begin
        own_q <= rst_n & u_dut.console_own;
        if (sim_dbg && rst_n && u_dut.console_own != own_q)
            $display("[p1a-evt @%0d] console_own -> %b (parked=%b)",
                     tb_cycle, u_dut.console_own, u_dut.parked);
    end
    // Protocol: the park request must be held until the engine's cycle is done
    // (R25: no truncated engine access under a released park).  Always on.
    always @(posedge clk)
        if (rst_n && z_busrq_n && eng_own)
            $display("[p1a-ERR @%0d] BUSRQ released during an engine cycle", tb_cycle);

    // R-42: engine data-cycle waveform, one vector per T-state sampled at the END
    // of the T-state (each cpu_cen edge, pre-edge values), the format of
    // sim/ssp/golden_cycles.txt:  MREQ IORQ RD WR M1 MRD_T1 (1 = asserted).
    // Printed as "[p1a-eng] v v v ..." when the engine releases the bus.
    // (+ENGLOG; the sampling edge is the BFM's cpu_cen, the one the bridge
    // engine FSM also advances on.)
    wire sim_englog = $test$plusargs("ENGLOG");
    string eng_line;
    reg    eng_in;
    initial begin eng_line = ""; eng_in = 1'b0; end
    always @(posedge clk) begin
        if (sim_englog && rst_n && cpu_cen) begin
            if (eng_own) begin
                eng_line = {eng_line, $sformatf(" %b%b%b%b%b%b",
                    ~eng_mreq_n, ~eng_iorq_n, ~eng_rd_n, ~eng_wr_n, ~eng_m1_n,
                    eng_mrd_t1)};
                eng_in = 1'b1;
            end else if (eng_in) begin
                $display("[p1a-eng]%s", eng_line);
                eng_line = "";  eng_in = 1'b0;
            end
        end
    end
    // R30: WDG_PARK expiry (park held ~0.4 s with no WDG_PARK_KICK from the FW)
    reg pdead_q;
    always @(posedge clk) begin
        pdead_q <= u_dut.u_bridge.park_dead_l;
        if (sim_dbg && rst_n && pdead_q && !u_dut.u_bridge.park_dead_l)
            $display("[p1a-evt @%0d] WDG_PARK expired (dead FW console)", tb_cycle);
    end
    // R27 trampoline / reset-vent trace: FW writes and the guest-side
    // handshake (CTRL, TRAMP_ADDR) -- widx 0x01 / 0x02 (SSP_RIDX_CTRL/TRAMP_ADDR)
    reg zrst_q, tarm_q, tdone_q;
    always @(posedge clk) begin
        zrst_q <= z_reset_n;  tarm_q <= tramp_arm;  tdone_q <= tramp_done;
        if (sim_dbg && rst_n) begin
            if (u_dut.u_bridge.wr_fire && u_dut.u_bridge.widx == 10'h001)
                $display("[p1a-ctrl @%0d] CTRL <= %03x (mask %b)", tb_cycle,
                         u_dut.u_bridge.mem_wdata[9:0], u_dut.u_bridge.mem_wmask);
            if (u_dut.u_bridge.wr_fire && u_dut.u_bridge.widx == 10'h002)
                $display("[p1a-ctrl @%0d] TRAMP_ADDR <= %04x", tb_cycle,
                         u_dut.u_bridge.mem_wdata[15:0]);
            if (z_reset_n !== zrst_q)
                $display("[p1a-go   @%0d] z_reset_n -> %b (guest pc=%04x)",
                         tb_cycle, z_reset_n, u_guest.pc);
            if (tramp_arm !== tarm_q)
                $display("[p1a-go   @%0d] tramp_arm -> %b target=%04x", tb_cycle,
                         tramp_arm, tramp_target);
            if (tramp_done)
                $display("[p1a-go   @%0d] tramp_done (guest pc=%04x)", tb_cycle,
                         u_guest.pc);
        end
    end
    // RX FIFO + kernel read probes
    reg popd1;
    always @(posedge clk) popd1 <= rst_n && u_dut.u_bridge.uart_rx_pop;
    always @(posedge clk) begin
        if (sim_dbg && rst_n && (tb_cycle == 830000 || tb_cycle == 900000))
            $display("[p1a-mt2 @%0d] pc=%08x st=%b act=%b holdv=%b txrdy=%b avail=%b ovf=%b wp=%0d rp=%0d rvctrl=%b runexp=%b rstb=%b t80rst=%b",
                     tb_cycle, u_dut.core.PC_new, u_dut.core.state,
                     u_dut.u_uart.mon_act, u_dut.u_uart.mon_hold_v,
                     u_dut.u_uart.tx_ready, u_dut.u_uart.rx_avail,
                     u_dut.u_uart.rx_overrun, u_dut.u_uart.wp, u_dut.u_uart.rp,
                     u_dut.u_bridge.rv_ctrl_ok, u_dut.u_bridge.run_expired_l,
                     u_dut.core.mem_rstrb, u_dut.core.reset);
        if (sim_dbg && rst_n && u_dut.u_uart.mon_act && u_dut.u_uart.mon_tcnt == 8'd159)
            $display("[p1a-mt3 @%0d] byte done, next=%02x q=%04b", tb_cycle,
                     u_dut.u_uart.mon_hold, u_dut.u_uart.mon_shift);
        if (sim_dbg && rst_n && u_dut.u_uart.rx_push)
        if (sim_dbg && rst_n && u_dut.u_uart.rx_push)
            $display("[p1a-q  @%0d] PUSH %02x wp=%0d rp=%0d ovf=%b", tb_cycle,
                     u_dut.u_uart.rx_byte, u_dut.u_uart.wp, u_dut.u_uart.rp,
                     u_dut.u_uart.rx_overrun);
        if (sim_dbg && rst_n && u_dut.u_bridge.uart_rx_pop)
            $display("[p1a-q  @%0d] POPK wp=%0d rp=%0d", tb_cycle,
                     u_dut.u_uart.wp, u_dut.u_uart.rp);
        // CPU-visible read data at launch+1 (what lbu actually receives)
        if (sim_dbg && rst_n && popd1)
            $display("[p1a-q  @%0d] POPD -> %02x", tb_cycle,
                     u_dut.mem_rdata[7:0]);
        if (sim_dbg && rst_n && u_dut.u_bridge.wr_fire
            && u_dut.u_bridge.widx == 10'h048)   // SSP_RIDX_UART_TXDATA
            $display("[p1a-txw @%0d] UART_TXDATA wr %02x", tb_cycle,
                     u_dut.u_bridge.mem_wdata[7:0]);
        if (sim_dbg && rst_n && u_dut.u_bridge.rd_fire && tb_cycle >= 818000
            && tb_cycle <= 818300)
            $display("[p1a-rd @%0d] widx=%03x q=%08x", tb_cycle,
                     u_dut.u_bridge.widx, u_dut.u_bridge.q_reg);
        if (sim_dbg && rst_n && u_dut.u_bridge.rd_fire &&
            (u_dut.u_bridge.widx == 10'h04A || u_dut.u_bridge.widx == 10'h049))
            $display("[p1a-q  @%0d] kern rd off=%03x q=%08x fifo_head=%02x avail=%b",
                     tb_cycle, u_dut.u_bridge.widx*4,
                     u_dut.u_bridge.q_reg, u_dut.u_uart.rx_rnext,
                     u_dut.u_uart.rx_avail);
    end
    always @(posedge clk) begin
        if (sim_dbg && rst_n && tb_cycle >= 253000 && tb_cycle <= 258000
            && (tb_cycle % 434) == 2)
            $display("[p1a-mt @%0d] act=%b holdv=%b tcnt=%0d shift=%b txrdy=%b",
                     tb_cycle, u_dut.u_uart.mon_act, u_dut.u_uart.mon_hold_v,
                     u_dut.u_uart.mon_tcnt, u_dut.u_uart.mon_shift,
                     u_dut.u_uart.tx_ready);
    end
    always @(posedge clk) begin
        if (sim_dbg && rst_n && (tb_cycle % 1000000) == 0) begin
            $display("[p1adbg] pc=0x%x st=%b maddr=0x%x rstrb=%b rdata=0x%x rrrom=%b qrom=0x%x txd=%b monact=%b holdv=%b",
                     u_dut.core.PC_new, u_dut.core.state,
                     u_dut.mem_addr, u_dut.mem_rstrb, u_dut.mem_rdata,
                     u_dut.rr_rom, u_dut.q_rom, snac_txd,
                     u_dut.u_uart.mon_act, u_dut.u_uart.mon_hold_v);
        end
    end

    wire [31:0] mem_rdata_mux_probe = 32'h0;

    // ------------------------------------------------ final info line -----
    assign dbg_guest_rx   = guest_rx_count;
    assign dbg_freeze_acc = freeze_accept_count;
    export "DPI-C" task tb_info;
    task tb_info;
        $display("[p1a-info] cycles=%0d fetches=%0d freeze_acc=%0d guest_rx=%0d last_rx=%02x io_wr=%0d(%02x,%02x) rom_illegal=%0d bus_errs=%0d parked=%0b alive=%0b",
                 tb_cycle, fetch_count, freeze_accept_count, guest_rx_count,
                 guest_rx_last, io_wr_count, io_wr_port, io_wr_data,
                 dbg_rom_illegal_writes, dbg_bus_errs, parked_dbg, rv_alive);
    endtask

endmodule

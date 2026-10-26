// ssp_stub_top.v -- P0 RV-side stub SoC for the MrZ80 SSP (Verilator).
//
// Minimal hardware-true system around picorv32 to boot the Mecrisp FW and
// run the D-35 dictionary-build pipeline at silicon addresses:
//
//   0x0000_0000-0x0000_FFFF  ROM 64 KiB ($readmemh image, WRITABLE here:
//                             the dict window stands in for the OSD download
//                             write-port; on real silicon MROM ignores RV
//                             writes -- see D-10/D-35)
//   0x1000_0000-0x1000_FFFF  DTCM 64 KiB, byte-enable
//   0x2000_0000-0x2000_0FFF  ssp_bridge -- STUB SUBSET only:
//                               0x000 ID (reset 4D525A03, matches CSV rev)
//                               0x120 UART_TXDATA  WO  (byte emitted immediately)
//                               0x124 UART_RXDATA  RC  (8-byte FIFO pop)
//                               0x128 UART_STAT    R   tx_ready/rx_avail/sticky overrun
//                               0x12C UART_CTRL    RW  en, rx_clr, tx_clr (self-clear)
//                             remaining bridge regs read 0, writes accepted.
//   else                      decoder error: reads 0, address counted and
//                             reported (real design: resp.error + FW trap word,
//                             picorv32 has no bus-error input so we log here)
//
// Console: DPI calls into tb_ssp_stub.cpp (stdin/stdout). RX pacing is
// structural: the core polls tb_rx_poll() only while the RX FIFO has room
// -- firmware-paced feed by construction (R17 lesson #2).
//
// Harness control (top-level ports, driven by tb_ssp_stub.cpp):
//   dump_req  one cycle at end of run -> $writememh of rom[] to +DUMP file
//   dbg_*     counters reported by the harness (illegal ROM writes below
//             the dictionary window, decoder errors, trap flag)
//
// Bake-off note (OQ-20): this top is picorv32-specific for now; the gracilis
// twin shares the same memory/UART fabric contract so the FW and build
// scripts run unchanged on either core.

`timescale 1 ns / 1 ps

module ssp_stub_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        dump_req,               // 1-cycle: dump rom[] -> +DUMP
    output wire        trap,
    output logic [7:0] rx_fifo_level,        // debug visibility
    output logic [7:0] rx_overrun,          // bytes dropped while FIFO full
    output logic [31:0] dbg_rom_core_writes, // ROM writes below 0x4400 (must be 0)
    output logic [31:0] dbg_bus_errs
);

    import "DPI-C" function void tb_putc(int c);
    import "DPI-C" function int  tb_rx_poll();
    import "DPI-C" function void tb_bus_err(int addr);

    // ---------------------------------------------------------------- config
    localparam WORDS      = 16384;           // 64 KiB / 4
    localparam DICT_FIRST = 16'h4400;       // FlashDictionaryAnfang (D-35)

    string romfile, dumpfile;
    logic [31:0] rom  [0:WORDS-1];
    logic [31:0] dtcm [0:WORDS-1];

    initial begin
        if (!$value$plusargs("ROM=%s",  romfile))  romfile  = "ssp/fw/build/mecrisp-ssp.hex";
        if (!$value$plusargs("DUMP=%s", dumpfile)) dumpfile = "";
        $display("[stub] ROM <- %s", romfile);
        $readmemh(romfile, rom);
    end

    // ------------------------------------------------------------- the core
    wire        mem_valid, mem_instr, mem_ready;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;
    wire        mem_la_read, mem_la_write;
    wire [31:0] mem_la_addr;

    picorv32 #(
        .COMPRESSED_ISA (1),
        .ENABLE_MUL     (1),
        .ENABLE_DIV     (1),
        .ENABLE_IRQ     (0),
        .PROGADDR_RESET (32'h0000_0000),
        .STACKADDR      (32'h1000_FFF0)     // FW re-seeds x2/x9 itself
    ) core (
        .clk        (clk),
        .resetn     (rst_n),
        .trap       (trap),
        .mem_valid  (mem_valid),
        .mem_instr  (mem_instr),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata),
        .mem_la_read  (mem_la_read),
        .mem_la_write (mem_la_write),
        .mem_la_addr  (mem_la_addr),
        .mem_la_wdata (),
        .mem_la_wstrb (),
        .pcpi_valid   (),
        .pcpi_insn    (),
        .pcpi_rs1     (),
        .pcpi_rs2     (),
        .pcpi_wr      (1'b0),
        .pcpi_rd      (32'h0),
        .pcpi_wait    (1'b0),
        .pcpi_ready   (1'b0),
        .irq          (32'h0),
        .eoi          (),
        .trace_valid  (),
        .trace_data   ()
    );

    assign mem_ready = rst_n;   // no wait states in the stub

    // ---------------------------------------------------------- UART model
    logic       uart_en;
    logic [7:0] rxfifo [0:7];
    logic [3:0] rx_wp, rx_rp;              // free-running mod-16 == FIFO depth 8
    wire  [3:0] rx_count = rx_wp - rx_rp;
    wire        rx_avail = (rx_count != 4'd0);
    logic       rx_overrun_sticky;

    // Poll the host only while the FIFO can accept -- firmware pacing.
    always @(posedge clk) begin
        if (!rst_n) begin
            uart_en          <= 1'b1;       // CTRL reset value: en
            rx_wp            <= 4'd0;
            rx_rp            <= 4'd0;
            rx_overrun_sticky<= 1'b0;
            rx_overrun       <= 8'd0;
        end
    end

    // pop on RXDATA read
    wire is_uart  = (mem_addr[31:12] == 20'h20000);    // page 0x2000_0xxx
    wire at_tx    = (mem_addr[11:0] == 12'h120);
    wire at_rx    = (mem_addr[11:0] == 12'h124);
    wire at_stat  = (mem_addr[11:0] == 12'h128);
    wire at_ctrl  = (mem_addr[11:0] == 12'h12C);
    // Read vs write discrimination: data-phase access (mem_instr=0) with no
    // byte strobes is a load. (mem_la_read is LOOK-AHEAD -- asserted before
    // mem_valid, so it must not be combined with mem_valid here.)
    wire rd_fire  = mem_valid && !mem_instr && (mem_wstrb == 4'b0) && rst_n;
    wire wr_fire  = mem_valid && !mem_instr && (mem_wstrb != 4'b0) && rst_n;

    always @(posedge clk) begin
        if (rst_n && rd_fire && is_uart && at_rx && rx_avail) begin
            rx_rp <= rx_rp + 4'd1;
            if (dbg_on) $display("[dbg %0t] pop  %02x lvl=%0d", $time, rxfifo[rx_rp[2:0]], rx_wp - rx_rp);
        end
    end

    // ------------------------------------------------------------- decoder
    wire is_rom  = (mem_addr[31:16] == 16'h0000);
    wire is_dtcm = (mem_addr[31:16] == 16'h1000);

    reg [31:0] err_addr_latched;

    always @(posedge clk) begin
        if (!rst_n) begin
            dbg_rom_core_writes <= 32'd0;
            dbg_bus_errs        <= 32'd0;
            err_addr_latched    <= 32'h0;
        end else begin
            if (wr_fire && is_rom && mem_addr[15:0] < DICT_FIRST) begin
                dbg_rom_core_writes <= dbg_rom_core_writes + 32'd1;
                if (dbg_on) $display("[dbg %0t] CORE-ROM WR %08x", $time, mem_addr);
            end
            if (mem_valid && !(is_rom || is_dtcm || is_uart)) begin
                dbg_bus_errs <= dbg_bus_errs + 32'd1;
                if (err_addr_latched == 32'h0) begin
                    err_addr_latched <= mem_addr;
                    tb_bus_err(int'(mem_addr));
                end
            end
        end
    end

    assign rx_fifo_level = {4'd0, rx_count};

    // ---------------------------------------------------- read (combinational)
    always @(*) begin
        if (is_rom)          mem_rdata = rom[mem_addr[15:2]];
        else if (is_dtcm)    mem_rdata = dtcm[mem_addr[15:2]];
        else if (is_uart) begin
            if (at_stat) mem_rdata = {29'd0, rx_overrun_sticky, rx_avail, 1'b1};
            else if (at_rx)   mem_rdata = {24'd0, rxfifo[rx_rp[2:0]]};
            else if (mem_addr[11:2] == 10'h000) mem_rdata = 32'h4D52_5A03; // ID
            else mem_rdata = 32'h0;         // stub subset: unimplemented regs read 0
        end
        else                 mem_rdata = 32'h0;   // decoder error payload
    end

    // -------------------------------------------------- write (byte strobes)
    wire [31:0] wmask = { {8{mem_wstrb[3]}}, {8{mem_wstrb[2]}},
                          {8{mem_wstrb[1]}}, {8{mem_wstrb[0]}} };

    integer rxchar;

    logic dbg_on;
    initial dbg_on = $test$plusargs("DBG");

    always @(posedge clk) begin
        if (rst_n && uart_en && rx_count < 4'd8) begin
            rxchar = tb_rx_poll();
            if (rxchar >= 0) begin
                rxfifo[rx_wp[2:0]] <= rxchar[7:0];
                rx_wp              <= rx_wp + 4'd1;
                if (dbg_on) $display("[dbg %0t] push %02x lvl=%0d", $time, rxchar[7:0], rx_wp);
            end
        end
    end

    always @(posedge clk) begin
        if (wr_fire) begin
            if (dbg_on && is_uart)
                $display("[dbg %0t] WR uart %03x data %08x strb %b", $time,
                       mem_addr[11:0], mem_wdata, mem_wstrb);
            if (is_rom)
                rom[mem_addr[15:2]]  <= (rom[mem_addr[15:2]]  & ~wmask)
                                      | (mem_wdata & wmask);
            else if (is_dtcm)
                dtcm[mem_addr[15:2]] <= (dtcm[mem_addr[15:2]] & ~wmask)
                                      | (mem_wdata & wmask);
            else if (is_uart) begin
                if (at_tx && mem_wstrb[0]) tb_putc(int'(mem_wdata[7:0]));
                if (at_ctrl && mem_wstrb[0]) begin
                    uart_en           <= mem_wdata[0];
                    if (mem_wdata[1]) begin          // rx_clr
                        rx_rp             <= rx_wp;
                        rx_overrun_sticky <= 1'b0;
                    end
                    // bit2 tx_clr: TX is immediate in this model -- no-op
                end
            end
            // decoder-error writes: silently dropped here (counted above)
        end
    end

    // --------------------------------------------------------- ROM dump
    always @(posedge clk) begin
        if (dump_req && (dumpfile != "")) begin
            $writememh(dumpfile, rom);
            $display("[stub] ROM dumped -> %s", dumpfile);
        end
    end

endmodule

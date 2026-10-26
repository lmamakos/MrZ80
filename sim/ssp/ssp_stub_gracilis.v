// ssp_stub_gracilis.v -- gracilis (FemtoRV32) twin of ssp_stub_top.v,
// for the OQ-20 bake-off (D-33 Verilog side; D-34 ADDR_WIDTH=30).
//
// Same fabric contract as the picorv32 lane: ROM 64 KiB @0 (dict window
// writable for the D-35 build harness), DTCM 64 KiB @0x1000_0000 byte
// enable, ssp_bridge stub subset @0x2000_0000 (ID + UART 0x120..0x12C,
// 8-byte RX FIFO, structural FIFO-room pacing), decoder-error slave.
//
// Bus protocol differences (FemtoRV vs picorv32):
//   * reads announced by mem_rstrb for one cycle; data expected the NEXT
//     cycle unless mem_rbusy held -> we register rdata (1-cycle latency,
//     rbusy tied 0: registered-output M10K model, handoff 4.1);
//   * writes signalled by non-zero mem_wmask; wbusy tied 0 (no stalls);
//   * no valid/instr qualifier exists: fetch and data reads share rstrb,
//     discriminated by address (fetch is always inside ROM < 0x10000);
//   * reset active-low, matching the top's rst_n.
// No `trap` port exists on gracilis; the top-level port ties 0 and the
// bake-off relies on idle-exit/WDG semantics instead (documented R20).

`timescale 1 ns / 1 ps

module ssp_stub_gracilis (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        dump_req,               // 1-cycle: dump rom[] -> +DUMP
    output wire        trap,                   // gracilis: none (see header)
    output logic [7:0] rx_fifo_level,
    output logic [7:0] rx_overrun,
    output logic [31:0] dbg_rom_core_writes,  // ROM writes below 0x4400 (must be 0)
    output logic [31:0] dbg_bus_errs
);

    import "DPI-C" function void tb_putc(int c);
    import "DPI-C" function int  tb_rx_poll();
    import "DPI-C" function void tb_bus_err(int addr);

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
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wmask;
    logic [31:0] mem_rdata;
    wire        mem_rstrb, mem_rbusy, mem_wbusy;

    assign mem_rbusy = 1'b0;                // 1-cycle reads always (M10K model)
    assign mem_wbusy = 1'b0;               // writes never stall
    assign trap      = 1'b0;              // gracilis has no trap output

    FemtoRV32 #(
        .ADDR_WIDTH (30),                   // D-34
        .RESET_ADDR (32'h0000_0000)
    ) core (
        .clk                (clk),
        .mem_addr           (mem_addr),
        .mem_wdata          (mem_wdata),
        .mem_wmask          (mem_wmask),
        .mem_rdata          (mem_rdata),
        .mem_rstrb          (mem_rstrb),
        .mem_rbusy          (mem_rbusy),
        .mem_wbusy          (mem_wbusy),
        .interrupt_request  (1'b0),       // polled FW (D-27)
        .reset              (rst_n)
    );

    // ---------------------------------------------------------- UART model
    logic       uart_en;
    logic [7:0] rxfifo [0:7];
    logic [3:0] rx_wp, rx_rp;              // free-running mod-16 == depth 8
    wire  [3:0] rx_count = rx_wp - rx_rp;
    wire        rx_avail = (rx_count != 4'd0);
    logic       rx_overrun_sticky;

    always @(posedge clk) begin
        if (!rst_n) begin
            uart_en           <= 1'b1;     // CTRL reset value: en
            rx_wp             <= 4'd0;
            rx_rp             <= 4'd0;
            rx_overrun_sticky <= 1'b0;
            rx_overrun        <= 8'd0;
        end
    end

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

    // ------------------------------------------------------------- decode
    wire is_rom  = (mem_addr[31:16] == 16'h0000);
    wire is_dtcm = (mem_addr[31:16] == 16'h1000);
    wire is_uart = (mem_addr[31:12] == 20'h20000);   // page 0x2000_0xxx
    wire at_tx    = (mem_addr[11:0] == 12'h120);
    wire at_rx    = (mem_addr[11:0] == 12'h124);
    wire at_stat  = (mem_addr[11:0] == 12'h128);
    wire at_ctrl  = (mem_addr[11:0] == 12'h12C);

    wire rd_fire = rst_n && mem_rstrb;                       // read launched
    wire wr_fire = rst_n && (mem_wmask != 4'b0);             // write issued

    // read data for the launch cycle, presented next cycle (rbusy=0 model)
    logic [31:0] rdata_nxt;
    always @(*) begin
        if (is_rom)          rdata_nxt = rom[mem_addr[15:2]];
        else if (is_dtcm)    rdata_nxt = dtcm[mem_addr[15:2]];
        else if (is_uart) begin
            if (at_stat)                rdata_nxt = {29'd0, rx_overrun_sticky, rx_avail, 1'b1};
            else if (at_rx)           rdata_nxt = {24'd0, rxfifo[rx_rp[2:0]]};
            else if (mem_addr[11:2] == 10'h000) rdata_nxt = 32'h4D52_5A03; // ID
            else                      rdata_nxt = 32'h0;     // stub subset
        end
        else                 rdata_nxt = 32'h0;              // decoder error payload
    end

    always @(posedge clk) begin
        mem_rdata <= rdata_nxt;
        // RX pop on RXDATA read launch (never a fetch: addr >= 0x10000)
        if (rd_fire && is_uart && at_rx && rx_avail) begin
            rx_rp <= rx_rp + 4'd1;
            if (dbg_on) $display("[dbg %0t] pop  %02x lvl=%0d", $time, rxfifo[rx_rp[2:0]], rx_wp - rx_rp);
        end
    end

    // counters / decoder-error reporting
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
            if ((rd_fire || wr_fire) && !(is_rom || is_dtcm || is_uart)) begin
                dbg_bus_errs <= dbg_bus_errs + 32'd1;
                if (err_addr_latched == 32'h0) begin
                    err_addr_latched <= mem_addr;
                    tb_bus_err(int'(mem_addr));
                end
            end
        end
    end

    assign rx_fifo_level = {4'd0, rx_count};

    // -------------------------------------------------- write (byte strobes)
    wire [31:0] wmask = { {8{mem_wmask[3]}}, {8{mem_wmask[2]}},
                          {8{mem_wmask[1]}}, {8{mem_wmask[0]}} };

    always @(posedge clk) begin
        if (wr_fire) begin
            if (is_rom)
                rom[mem_addr[15:2]]  <= (rom[mem_addr[15:2]]  & ~wmask)
                                      | (mem_wdata & wmask);
            else if (is_dtcm)
                dtcm[mem_addr[15:2]] <= (dtcm[mem_addr[15:2]] & ~wmask)
                                      | (mem_wdata & wmask);
            else if (is_uart) begin
                if (at_tx && mem_wmask[0]) tb_putc(int'(mem_wdata[7:0]));
                if (at_ctrl && mem_wmask[0]) begin
                    uart_en <= mem_wdata[0];
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

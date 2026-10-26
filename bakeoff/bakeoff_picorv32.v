// bakeoff_picorv32.v -- OQ-20 bake-off synthesis top, entrant A.
// Throwaway: measured, not booted (functional twin: sim/ssp/ssp_stub_top.v).
// Fabric = explicit ssp_sdp_ram IP (R21 owner ruling: no inference reliance);
// identical fabric to bakeoff_gracilis.v apart from the core instantiation and
// the inherent bus-protocol shim (see bakeoff/README.md).
//
// Protocol shim: picorv32 is a zero-latency valid/ready bus, but the IP
// delivers q one cycle after the address edge (M10K native).  A single
// wait-state FSM bridges the two: the request edge commits writes and
// launches the read; mem_ready asserts the following cycle with q valid.
// (gracilis needs no such shim -- its rstrb protocol is already launch+1.)

`timescale 1 ns / 1 ps

module bakeoff_picorv32 (
    input  wire        clk,
    input  wire        rst_n,
    output reg  [7:0]  tx_data,       // console TX latch (no host: synthesis)
    output reg         tx_strb,
    output wire        tx_ready,
    output wire        rx_avail,
    output wire        trap,
    output reg  [31:0] dbg_bus_errs,
    output reg  [31:0] dbg_rom_writes
);
    localparam DICT_FIRST = 16'h4400; // FlashDictionaryAnfang (D-35)

    // ------------------------------------------------------------ the core
    wire        mem_valid, mem_instr, mem_ready;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    picorv32 #(
        .COMPRESSED_ISA (1),
        .ENABLE_MUL     (1),
        .ENABLE_DIV     (1),
        .ENABLE_IRQ     (0),
        .PROGADDR_RESET (32'h0000_0000),
        .STACKADDR      (32'h1000_FFF0)
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
        .mem_la_read  (),
        .mem_la_write (),
        .mem_la_addr  (),
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
        .eoi          ()
    );

    // ------------------------------------------------- 1-cycle access FSM
    reg pend;                        // access launched, completing next cycle
    assign mem_ready = rst_n && pend;        // q valid on the complete cycle

    wire launch = mem_valid && !pend && rst_n;   // request edge

    // ------------------------------------------------------------- decode
    wire is_rom  = (mem_addr[31:16] == 16'h0000);
    wire is_dtcm = (mem_addr[31:16] == 16'h1000);
    wire is_uart = (mem_addr[31:12] == 20'h20000);
    wire at_tx    = (mem_addr[11:0] == 12'h120);
    wire at_ctrl  = (mem_addr[11:0] == 12'h12C);

    wire rd_fire = launch && !mem_instr && (mem_wstrb == 4'b0);
    wire wr_fire = launch && !mem_instr && (mem_wstrb != 4'b0);

    assign tx_ready = 1'b1;          // synth stand-in: no host drain
    assign rx_avail = 1'b0;          // synth stand-in: no host feed

    reg uart_en;

    // --------------------------------------------------- explicit RAM IP
    wire [31:0] q_rom, q_dtcm;

    ssp_sdp_ram u_rom (
        .address_w (mem_addr[15:2]), .address_r (mem_addr[15:2]),
        .clock     (clk),
        .data_w    (mem_wdata),     .byteena   (mem_wstrb),
        .wren      (wr_fire && is_rom),
        .q         (q_rom)
    );

    ssp_sdp_ram u_dtcm (
        .address_w (mem_addr[15:2]), .address_r (mem_addr[15:2]),
        .clock     (clk),
        .data_w    (mem_wdata),     .byteena   (mem_wstrb),
        .wren      (wr_fire && is_dtcm),
        .q         (q_dtcm)
    );

    // Peripheral-select capture at the request edge: rr_* and q land together
    // on the complete cycle (picorv32 samples mem_rdata there).
    reg rr_rom, rr_dtcm, rr_stat, rr_id;

    wire sel_stat = is_uart && (mem_addr[11:0] == 12'h128);
    wire sel_id   = is_uart && (mem_addr[11:2] == 10'h000);

    always @(posedge clk) begin
        if (rd_fire) begin
            rr_rom  <= is_rom;
            rr_dtcm <= is_dtcm;
            rr_stat <= sel_stat;
            rr_id   <= sel_id;
        end
    end

    assign mem_rdata =
        rr_rom  ? q_rom  :
        rr_dtcm ? q_dtcm :
        rr_stat ? {29'd0, 1'b0, rx_avail, tx_ready} :
        rr_id   ? 32'h4D52_5A03 :
                  32'h0;                       // uart regs + error payload

    always @(posedge clk) begin
        tx_strb <= 1'b0;
        if (wr_fire && is_uart) begin
            if (at_tx && mem_wstrb[0]) begin
                tx_data <= mem_wdata[7:0];
                tx_strb <= 1'b1;
            end
            if (at_ctrl && mem_wstrb[0]) uart_en <= mem_wdata[0];
        end
        // decoder-error writes: silently dropped here (counted below)
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            pend          <= 1'b0;
            dbg_bus_errs  <= 32'd0;
            dbg_rom_writes <= 32'd0;
        end else begin
            pend <= mem_valid && !pend;
            if (wr_fire && is_rom && mem_addr[15:0] < DICT_FIRST)
                dbg_rom_writes <= dbg_rom_writes + 32'd1;
            if ((rd_fire || wr_fire) && !(is_rom || is_dtcm || is_uart))
                dbg_bus_errs <= dbg_bus_errs + 32'd1;
        end
    end
endmodule

// bakeoff_gracilis.v -- OQ-20 bake-off synthesis top, entrant B.
// Throwaway: measured, not booted (functional twin: sim/ssp/ssp_stub_gracilis.v).
// Fabric = explicit ssp_sdp_ram IP (R21 owner ruling: no inference reliance);
// identical fabric to bakeoff_picorv32.v apart from the core instantiation and
// the inherent bus-protocol shim (see bakeoff/README.md).
//
// IP read latency: ssp_sdp_ram registers its read address (M10K native), so
// q arrives the cycle after the address edge -- a NATURAL match for FemtoRV,
// whose rstrb protocol already expects data at launch+1. No wait logic needed;
// mem_rbusy stays tied 0.

`timescale 1 ns / 1 ps

module bakeoff_gracilis (
    input  wire        clk,
    input  wire        rst_n,
    output reg  [7:0]  tx_data,       // console TX latch (no host: synthesis)
    output reg         tx_strb,
    output wire        tx_ready,
    output wire        rx_avail,
    output wire        trap,          // gracilis: no trap unit (README note)
    output reg  [31:0] dbg_bus_errs,
    output reg  [31:0] dbg_rom_writes
);
    localparam DICT_FIRST = 16'h4400; // FlashDictionaryAnfang (D-35)

    // ------------------------------------------------------------ the core
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wmask;
    wire [31:0] mem_rdata;
    wire        mem_rstrb, mem_rbusy, mem_wbusy;

    assign mem_rbusy = 1'b0;         // IP launch+1 latency == rstrb protocol
    assign mem_wbusy = 1'b0;         // writes commit at the EXECUTE edge
    assign trap      = 1'b0;

    FemtoRV32 #(
        .ADDR_WIDTH (30),            // D-34
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
        .interrupt_request (1'b0),
        .reset             (rst_n)
    );

    // ------------------------------------------------------------- decode
    wire is_rom  = (mem_addr[31:16] == 16'h0000);
    wire is_dtcm = (mem_addr[31:16] == 16'h1000);
    wire is_uart = (mem_addr[31:12] == 20'h20000);
    wire at_tx    = (mem_addr[11:0] == 12'h120);
    wire at_ctrl  = (mem_addr[11:0] == 12'h12C);

    wire rd_fire = rst_n && mem_rstrb;
    wire wr_fire = rst_n && (mem_wmask != 4'b0);

    assign tx_ready = 1'b1;          // synth stand-in: no host drain
    assign rx_avail = 1'b0;          // synth stand-in: no host feed

    reg uart_en;

    // --------------------------------------------------- explicit RAM IP
    wire [31:0] q_rom, q_dtcm;

    ssp_sdp_ram u_rom (
        .address_w (mem_addr[15:2]), .address_r (mem_addr[15:2]),
        .clock     (clk),
        .data_w    (mem_wdata),     .byteena   (mem_wmask),
        .wren      (wr_fire && is_rom),
        .q         (q_rom)
    );

    ssp_sdp_ram u_dtcm (
        .address_w (mem_addr[15:2]), .address_r (mem_addr[15:2]),
        .clock     (clk),
        .data_w    (mem_wdata),     .byteena   (mem_wmask),
        .wren      (wr_fire && is_dtcm),
        .q         (q_dtcm)
    );

    // Peripheral-select capture at the launch edge: q and the rr_* flags are
    // both valid in the launch+1 cycle -- exactly when FemtoRV samples.
    reg rr_rom, rr_dtcm, rr_stat, rr_id;

    wire sel_stat = is_uart && (mem_addr[11:0] == 12'h128);
    wire sel_id   = is_uart && (mem_addr[11:2] == 10'h000);

    always @(posedge clk) begin
        if (mem_rstrb) begin
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
            if (at_tx && mem_wmask[0]) begin
                tx_data <= mem_wdata[7:0];
                tx_strb <= 1'b1;
            end
            if (at_ctrl && mem_wmask[0]) uart_en <= mem_wdata[0];
        end
        // decoder-error writes: silently dropped here (counted below)
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            dbg_bus_errs    <= 32'd0;
            dbg_rom_writes  <= 32'd0;
        end else begin
            if (wr_fire && is_rom && mem_addr[15:0] < DICT_FIRST)
                dbg_rom_writes <= dbg_rom_writes + 32'd1;
            if ((rd_fire || wr_fire) && !(is_rom || is_dtcm || is_uart))
                dbg_bus_errs <= dbg_bus_errs + 32'd1;
        end
    end
endmodule

// ramprobe.v -- inference probe v4 (R21): femto-driven fabric, comparing
// B: combinational-address read path (current bakeoff_gracilis shape) vs
// X: same fabric with one-cycle REGISTERED address (r_addr shim).
// If X infers and B grinds, the M10K requirement at 16K depth is a
// REGISTERED READ ADDRESS -- FemtoRV's combinational mem_addr needs the
// fabric shim (and the real design asserts mem_rbusy for the extra cycle).

`timescale 1 ns / 1 ps

module ramprobe (
    input  wire        clk,
    input  wire        rst_n,
    output wire [31:0] dbg
);
    localparam WORDS = 16384;

    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wmask;
    wire [31:0] mem_rdata;
    wire        mem_rstrb;

    FemtoRV32 #(
        .ADDR_WIDTH (30),
        .RESET_ADDR (32'h0000_0000)
    ) coreB (
        .clk               (clk),
        .mem_addr          (mem_addr),
        .mem_wdata         (mem_wdata),
        .mem_wmask         (mem_wmask),
        .mem_rdata         (mem_rdata),
        .mem_rstrb         (mem_rstrb),
        .mem_rbusy         (1'b0),
        .mem_wbusy         (1'b0),
        .interrupt_request (1'b0),
        .reset             (rst_n)
    );

    wire is_rom  = (mem_addr[31:16] == 16'h0000);
    wire wr_fire = rst_n && (mem_wmask != 4'b0);

    // ---- B: combinational address (current bakeoff shape) --------------
    reg [31:0] romB [0:WORDS-1];
    reg [31:0] qB;
    always @(posedge clk) qB <= romB[mem_addr[15:2]];
    always @(posedge clk) begin
        if (wr_fire && is_rom) begin
            if (mem_wmask[0]) romB[mem_addr[15:2]][7:0]   <= mem_wdata[7:0];
            if (mem_wmask[1]) romB[mem_addr[15:2]][15:8]  <= mem_wdata[15:8];
            if (mem_wmask[2]) romB[mem_addr[15:2]][23:16] <= mem_wdata[23:16];
            if (mem_wmask[3]) romB[mem_addr[15:2]][31:24] <= mem_wdata[31:24];
        end
    end

    // ---- X: registered address shim ---------------------------------------
    reg [31:0] r_addr;
    reg [31:0] mem_rdata_x;
    always @(posedge clk) r_addr <= mem_addr;

    wire isX_rom = (r_addr[31:16] == 16'h0000);

    reg [31:0] romX [0:WORDS-1];
    reg [31:0] qX;
    always @(posedge clk) qX <= romX[r_addr[15:2]];
    always @(*) mem_rdata_x = isX_rom ? qX : 32'h0;

    always @(posedge clk) begin
        if (wr_fire && is_rom) begin
            if (mem_wmask[0]) romX[mem_addr[15:2]][7:0]   <= mem_wdata[7:0];
            if (mem_wmask[1]) romX[mem_addr[15:2]][15:8]  <= mem_wdata[15:8];
            if (mem_wmask[2]) romX[mem_addr[15:2]][23:16] <= mem_wdata[23:16];
            if (mem_wmask[3]) romX[mem_addr[15:2]][31:24] <= mem_wdata[31:24];
        end
    end

    wire keep = ^qB ^ ^qX ^ ^mem_rdata ^ ^mem_rdata_x;
    assign dbg = { 31'b0, keep };
endmodule

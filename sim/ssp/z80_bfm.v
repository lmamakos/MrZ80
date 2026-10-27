// z80_bfm.v -- behavioral Z80 + guest fabric for the P1a Verilator lane
// (D-28 lane 1).  NOT cycle-exact T80: the D-25 freeze-grant gate itself is
// verified on the GHDL integration bench with the real core (P2 process rec,
// R25).  This model implements the contract the bridge sees:
//   * cpu_cen 1-of-5 at 50 MHz (mirrors the production CEN generator);
//     guest instruction progress additionally honours z_cen_gate.
//   * FREEZE (BUSRQ) is accepted ONLY at instruction boundaries and BusAck
//     is confirmed within 3 clock cycles; release on request deassert.
//     (The real core may take up to a full instruction; that variance is
//     exactly what the bridge's request-level park controller tolerates.)
//   * 3T byte cycles for the built-in program: opcode fetch + operand
//     reads from a 64K image (pattern addr^0x5A, JP self-loops at 0x0100
//     and 0x4000).  0x76 HALT re-fetches PC (HALT+1) forever, matching
//     T80 HALT semantics ("HALT parks anywhere").
//   * Bus master mux local (sel = ~busack_n mirror of z80_bus_mux); the
//     engine sees its reads answered (mem = addr^0x5A, io = port^0x0F)
//     with launch-on-request data; io writes captured for inspection.
//   * WAIT injection (+WAIT): one extra wait-state cycle on engine memory
//     reads (mem rd held one cycle) -- engine must ride it (R25/H3).
//   * Guest ACIA RX model: deserializes the ssp_top guest_rxd wire at the
//     same O9B baud_increment, counts bytes (transparency proof R-43).
//   * t80_reg vector per doc/t80_reg_debug_vector.md 1.1: only PC/SP/R/A
//     meaningful (SP const FFFE, A = last opcode-fetch operand pattern,
//     R = fetch counter); snapshot words elsewhere are don't-care model
//     values -- boundary/PC behaviour is what this lane proves.

`timescale 1 ns / 1 ps

module z80_bfm (
    input  wire        clk,             // 50 MHz
    input  wire        rst_n,         // guest reset (active low)

    input  wire        cen_gate_n,    // z_cen_gate: 1 => CEN blocked
    output wire        cpu_cen,       // ungated 1-of-5 (to ssp_top)

    // freeze/park interface (to ssp_top)
    input  wire        freeze_req_n,  // z_busrq_n (assert-low park request)
    output reg         busack_n,
    output wire        would_boundary,
    output reg  [211:0] t80_reg,
    output reg         m1_n,

    // guest strobes (self-driven; engine muxed at this boundary)
    output wire [15:0] cpu_addr,
    output wire [7:0]  cpu_din,
    output wire        cpu_wait_n,

    // engine master (from ssp_top)
    input  wire        eng_own,
    input  wire [15:0] eng_addr,
    input  wire [7:0]  eng_dout,
    input  wire        eng_mreq_n,
    input  wire        eng_iorq_n,
    input  wire        eng_rd_n,
    input  wire        eng_wr_n,
    input  wire        eng_m1_n,

    // console-side wire tap (guest ACIA RX model)
    input  wire        guest_rxd,
    input  wire [15:0] baud_increment,

    // wait injection
    input  wire        inject_wait,   // +WAIT: stall engine mem reads 1 cen

    // debug counters (to tb)
    output reg  [31:0] fetch_count,
    output reg  [31:0] guest_rx_count,
    output reg  [7:0]  guest_rx_last,
    output reg  [7:0]  io_wr_port,
    output reg  [7:0]  io_wr_data,
    output reg  [31:0] io_wr_count,
    output reg         parked_dbg,
    output reg  [31:0] freeze_accept_count
);

    // ------------------------------------------------ CEN (1-of-5) -------
    reg [2:0] cen_ph;
    always @(posedge clk) begin
        if (!rst_n) cen_ph <= 3'd0;
        else        cen_ph <= (cen_ph == 3'd4) ? 3'd0 : cen_ph + 3'd1;
    end
    assign cpu_cen = (cen_ph == 3'd0);
    wire cen_run = cpu_cen & ~cen_gate_n;

    // ------------------------------------------------ program memory -----
    reg [7:0] pmem [0:65535];
    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1)
            pmem[i] = i[7:0] ^ i[15:8];          // pattern incl. page bits
        pmem[16'h0100] = 8'hC3;  pmem[16'h0101] = 8'h00; pmem[16'h0102] = 8'h01;
        pmem[16'h4000] = 8'hC3;  pmem[16'h4001] = 8'h00; pmem[16'h4002] = 8'h40;
    end
    function [7:0] pget; input [15:0] a; pget = pmem[a]; endfunction

    // ------------------------------------------------ CPU model ----------
    reg [15:0] pc;
    reg [1:0]  cyc;                         // 0 fetch, 1/2 operands of JP
    reg        halted;
    reg        boundary;                    // instr completes at next accept
    reg [1:0]  ack_dly;

    wire [7:0] opcode = pget(pc);
    wire       is_jp  = (opcode == 8'hC3) & ~halted;
    wire       is_hlt = (opcode == 8'h76) & ~halted;

    wire sel_eng = ~busack_n;             // engine drives the bus (D-26)

    always @(posedge clk) begin
        if (!rst_n) begin
            pc <= 16'h0100;              // boot into the self-loop
            cyc <= 2'd0;
            halted <= 1'b0;
            boundary <= 1'b0;
            busack_n <= 1'b1;
            ack_dly <= 2'd0;
            m1_n    <= 1'b1;
            fetch_count <= 32'd0;
            freeze_accept_count <= 32'd0;
            parked_dbg <= 1'b0;
        end else begin
            parked_dbg <= ~busack_n;
            if (sel_eng) begin
                // engine holds the bus: T80 model frozen, strobes idle
                m1_n <= 1'b1;
            end else if (cen_run) begin
                // one bus byte per cen_run
                m1_n <= (cyc == 2'd0) ? 1'b0 : 1'b1;
                fetch_count <= fetch_count + 32'd1;
                if (is_hlt) begin
                    halted   <= 1'b1;
                    boundary <= 1'b1;              // HALT parks anywhere
                end else if (cyc == 2'd0 && is_jp) begin
                    cyc <= 2'd1;
                    boundary <= 1'b0;
                end else if (cyc != 2'd0) begin
                    cyc <= (cyc == 2'd2) ? 2'd0 : cyc + 2'd1;
                    boundary <= (cyc == 2'd2);
                    pc <= pc + 16'd1;              // complete 3-byte insn
                end else begin
                    // single-byte opcode: boundary after this cycle
                    boundary <= 1'b1;
                    if (!halted) pc <= pc + 16'd1;
                end

                // freeze accept: only at instruction boundary, 2-cycle ack
                if (boundary && freeze_req_n == 1'b0 && busack_n == 1'b1) begin
                    ack_dly <= 2'd2;
                end
                if (ack_dly != 2'd0) begin
                    ack_dly <= ack_dly - 2'd1;
                    if (ack_dly == 2'd1) begin
                        busack_n <= 1'b0;
                        freeze_accept_count <= freeze_accept_count + 32'd1;
                    end
                end
            end
            if (freeze_req_n == 1'b1 && busack_n == 1'b0) begin
                busack_n <= 1'b1;                // release to the guest
                ack_dly  <= 2'd0;
            end
        end
    end

    assign would_boundary = boundary;

    // ------------------------------------------------ t80_reg vector -----
    // PC=79:64, SP=63:48 (const FFFE), R=47:40 (fetch low byte), rest 0.
    always @(posedge clk) begin
        t80_reg <= {4'd0,            // IFF2 IFF1 IM(2)
                   16'd0,            // IY
                   16'd0, 16'd0, 16'd0,   // HL' DE' BC'
                   16'd0,           // IX
                   16'd0,           // HL (model: zeros)
                   16'd0,           // DE
                   16'd0,           // BC
                   pc,              // PC  [79:64]
                   16'hFFFE,       // SP  [63:48]
                   fetch_count[7:0],// R   [47:40]
                   8'd0,           // I
                   8'h00,          // F'
                   8'hFF,          // A'
                   8'h5A,          // F
                   8'h00};         // A
    end

    // ------------------------------------------------ bus mux + answers --
    wire [15:0] addr_eff = sel_eng ? eng_addr : pc;
    wire        mem_rd   = sel_eng ? (eng_mreq_n == 1'b0 && eng_rd_n == 1'b0)
                                  : 1'b1;                    // guest fetches
    wire        io_rd    = sel_eng ? (eng_iorq_n == 1'b0 && eng_rd_n == 1'b0)
                                  : 1'b0;
    wire        io_wr    = sel_eng ? (eng_iorq_n == 1'b0 && eng_wr_n == 1'b0)
                                  : 1'b0;
    wire [7:0]  d_mem    = addr_eff[7:0] ^ 8'h5A;
    wire [7:0]  d_io     = addr_eff[7:0] ^ 8'h0F;

    assign cpu_addr = addr_eff;
    assign cpu_din  = io_rd ? d_io : d_mem;

    // WAIT injection: stall engine memory reads by one cen (release the
    // cycle AFTER rd asserted so the engine's EoT2 capture sees wait).
    reg rd_seen;
    always @(posedge clk) begin
        if (!rst_n) rd_seen <= 1'b0;
        else        rd_seen <= mem_rd;
    end
    wire wait_mem = inject_wait & sel_eng & (mem_rd | rd_seen) & ~eng_wr_n
                    & ~eng_mreq_n;
    assign cpu_wait_n = ~wait_mem;

    // io write capture (engine IO_WR primitive proof)
    always @(posedge clk) begin
        if (io_wr) begin
            io_wr_port <= eng_addr[7:0];
            io_wr_data <= eng_dout;
            io_wr_count <= io_wr_count + 32'd1;
        end
    end

    // ---------------------------------------------- guest ACIA RX model ----
    // Fractional-16x deserializer on the guest_rxd wire (bit-centre
    // sampling mirrors ssp_uart: start 7, D0..D7 at 23..135, stop 151).
    reg [1:0] grx_sync;
    always @(posedge clk) grx_sync <= {grx_sync[0], guest_rxd};
    wire grxd = grx_sync[1];
    reg grxd_q;                            // h->l edge lock discipline (R25)
    always @(posedge clk) grxd_q <= grxd;

    reg         grx_act;
    reg  [15:0] grx_acc;
    reg  [7:0]  grx_tcnt;
    reg  [7:0]  grx_bits;
    wire [16:0] grx_nsum = {1'b0, grx_acc} + {1'b0, baud_increment};
    wire        grx_tick = grx_nsum[16];

    always @(posedge clk) begin
        grx_acc <= grx_nsum[15:0];
        if (!rst_n) begin
            grx_act <= 1'b0; grx_tcnt <= 8'd0; grx_bits <= 8'hFF;
            guest_rx_count <= 32'd0; guest_rx_last <= 8'h00;
        end else begin
            if (grx_tick && grx_act) begin
                grx_tcnt <= grx_tcnt + 8'd1;
                if      (grx_tcnt == 8'd7)   begin if (grxd) grx_act <= 1'b0;
                      end else if (grx_tcnt == 8'd23)  grx_bits[0] <= grxd;
                else if (grx_tcnt == 8'd39)  grx_bits[1] <= grxd;
                else if (grx_tcnt == 8'd55)  grx_bits[2] <= grxd;
                else if (grx_tcnt == 8'd71)  grx_bits[3] <= grxd;
                else if (grx_tcnt == 8'd87)  grx_bits[4] <= grxd;
                else if (grx_tcnt == 8'd103) grx_bits[5] <= grxd;
                else if (grx_tcnt == 8'd119) grx_bits[6] <= grxd;
                else if (grx_tcnt == 8'd135) grx_bits[7] <= grxd;
                else if (grx_tcnt == 8'd150) begin
                    grx_act <= 1'b0;
                    if (grxd) begin
                        guest_rx_count <= guest_rx_count + 32'd1;
                        guest_rx_last  <= grx_bits;     // valid stop
                    end
                end
            end else if (!grx_act && grxd == 1'b0 && grxd_q) begin
                grx_act  <= 1'b1;
                grx_acc  <= 16'd32768;          // half-bit pre-bias (centres)
                grx_tcnt <= 8'd0;
            end
        end
    end

endmodule

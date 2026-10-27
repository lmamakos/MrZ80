// z80_bfm.v -- behavioral Z80 + guest fabric for the P1a Verilator lane
// (D-28 lane 1).  NOT cycle-exact T80: the D-25 freeze-grant gate itself is
// verified on the GHDL integration bench with the real core (P2 process rec,
// R25).  This model implements the contract the bridge sees:
//   * cpu_cen 1-of-5 at 50 MHz (mirrors the production CEN generator);
//     guest instruction progress additionally honours z_cen_gate.
//   * FREEZE (BUSRQ) is accepted ONLY at instruction boundaries; BusAck is
//     asserted at the boundary with no further instruction cycle (PC = next
//     instruction, as the real T80 freeze gate); release on request deassert.
//     (The real core may take up to a full instruction; that variance is
//     exactly what the bridge's request-level park controller tolerates.)
//   * 3T byte cycles for the built-in program: opcode fetch + operand
//     reads from a 64K image.  Reset vector $0000 = JP $0100; JP is real
//     (R27: operands are fetched and loaded into PC); self-loops at
//     $0100, $0200, $0300, $4000 give observable PCs.  0x76 HALT
//     re-fetches PC (HALT+1) forever, matching T80 HALT semantics
//     ("HALT parks anywhere").
//   * R27 reset vent + trampoline: behavioural twin of ssp/rtl/ssp_tramp.vhd
//     (which is verified against the REAL T80 in sim/tb_tramp.vhd).  A low
//     z_reset_n resets the guest CPU model (PC=0, BusAck dropped, as the
//     T80 does), held >= 8 cen after release; tramp_arm sampled during
//     that reset primes the injector, which substitutes C3,lo,hi for the
//     first three fetches, then pulses tramp_done.
//   * Bus master mux local (sel = ~busack_n mirror of z80_bus_mux); the
//     engine sees its reads answered with launch-on-request data.  R30:
//     engine MEMORY reads/writes hit the same writable 64K image the guest
//     fetches from (initial pattern addr[7:0]^addr[15:8]), so deposit /
//     examine round trips -- and code the operator pokes in -- work; io reads
//     return port^0x0F; io writes are captured for inspection.
//   * WAIT injection (+WAIT): one wait state in T2 of every engine data cycle
//     (cpu_wait_n low for the first cpu_cen period of the strobe) -- the
//     engine must ride it (R25/H3) and its waveform must match the T80's
//     (R-42, sim/ssp/p1a_engine_golden.sh).
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
    input  wire        z_reset_n,     // CTRL.Z_RST_N vent (low = reset guest CPU)
    input  wire        tramp_arm,     // CTRL.TRAMP_EN (effective)
    input  wire [15:0] tramp_target,  // TRAMP_ADDR
    output reg         tramp_done,    // 1 clk: 3 bytes injected
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
        pmem[16'h0000] = 8'hC3;  pmem[16'h0001] = 8'h00; pmem[16'h0002] = 8'h01;
        pmem[16'h0100] = 8'hC3;  pmem[16'h0101] = 8'h00; pmem[16'h0102] = 8'h01;
        pmem[16'h0200] = 8'hC3;  pmem[16'h0201] = 8'h00; pmem[16'h0202] = 8'h02;
        pmem[16'h0300] = 8'hC3;  pmem[16'h0301] = 8'h00; pmem[16'h0302] = 8'h03;
        pmem[16'h4000] = 8'hC3;  pmem[16'h4001] = 8'h00; pmem[16'h4002] = 8'h40;
    end
    function [7:0] pget; input [15:0] a; pget = pmem[a]; endfunction

    // ------------------------------------------------ CPU model ----------
    // SSP reset vent (twin of ssp_tramp.vhd): z_reset_n low resets the CPU
    // model; the release is held for >= 8 cen (D-30 RESET_VENT).  Only the
    // CPU model is reset -- counters, the ACIA model and memory persist.
    reg [3:0] vent_cnt;
    reg       vent_q;
    initial begin vent_cnt = 4'd0; vent_q = 1'b1; end
    always @(posedge clk) begin
        if (!z_reset_n) begin
            vent_cnt <= 4'd8;  vent_q <= 1'b0;
        end else if (vent_cnt != 4'd0) begin
            vent_q <= 1'b0;
            if (cpu_cen) vent_cnt <= vent_cnt - 4'd1;
        end else begin
            vent_q <= 1'b1;
        end
    end
    wire cpu_rst_n = rst_n & vent_q;

    reg [15:0] pc;
    reg [1:0]  cyc;                         // 0 fetch, 1/2 operands of JP
    reg        halted;
    reg        boundary;                    // instr completes at next accept
    reg [7:0]  jp_lo;
    reg        inj_armed;                   // trampoline window open

    // Byte on the data bus for this step: the injected JP while the window
    // is open (opcode, lo, hi == cyc 0, 1, 2), else the program memory.
    wire [7:0] inj_byte = (cyc == 2'd0) ? 8'hC3 :
                          (cyc == 2'd1) ? tramp_target[7:0] : tramp_target[15:8];
    wire [7:0] fbyte    = inj_armed ? inj_byte : pget(pc);
    wire       is_jp    = (cyc == 2'd0) & (fbyte == 8'hC3) & ~halted;
    wire       is_hlt   = (cyc == 2'd0) & (fbyte == 8'h76) & ~halted;

    wire sel_eng = ~busack_n;             // engine drives the bus (D-26)

    always @(posedge clk) begin
        tramp_done <= 1'b0;
        if (!cpu_rst_n) begin
            pc <= 16'h0000;              // Z80 reset vector
            cyc <= 2'd0;
            halted <= 1'b0;
            boundary <= 1'b0;
            busack_n <= 1'b1;            // T80 reset clears BusAck
            m1_n    <= 1'b1;
            parked_dbg <= 1'b0;
            inj_armed <= tramp_arm;      // armed only if set during reset
            if (!rst_n) begin
                fetch_count <= 32'd0;
                freeze_accept_count <= 32'd0;
            end
        end else begin
            parked_dbg <= ~busack_n;
            if (sel_eng) begin
                // engine holds the bus: T80 model frozen, strobes idle
                m1_n <= 1'b1;
            end else if (cen_run && boundary && freeze_req_n == 1'b0
                         && busack_n == 1'b1) begin
                // T80 freeze gate (D-25): grant at the instruction boundary;
                // NO further instruction cycle is started, so PC is the next
                // instruction (verified on the real T80, sim/tb_tramp.vhd).
                busack_n <= 1'b0;
                freeze_accept_count <= freeze_accept_count + 32'd1;
            end else if (cen_run) begin
                // one bus byte per cen_run
                m1_n <= (cyc == 2'd0) ? 1'b0 : 1'b1;
                fetch_count <= fetch_count + 32'd1;
                if (is_hlt) begin
                    halted   <= 1'b1;
                    boundary <= 1'b1;              // HALT parks anywhere
                end else if (is_jp) begin
                    cyc <= 2'd1;
                    boundary <= 1'b0;
                    pc <= pc + 16'd1;
                end else if (cyc == 2'd1) begin
                    jp_lo <= fbyte;
                    cyc <= 2'd2;
                    pc <= pc + 16'd1;
                end else if (cyc == 2'd2) begin
                    pc <= {fbyte, jp_lo};          // JP nn: PC <- nn
                    cyc <= 2'd0;
                    boundary <= 1'b1;
                    if (inj_armed) begin           // 3rd injected byte done
                        inj_armed  <= 1'b0;
                        tramp_done <= 1'b1;
                    end
                end else begin
                    // single-byte opcode: boundary after this cycle
                    boundary <= 1'b1;
                    if (!halted) pc <= pc + 16'd1;
                end
            end
            if (freeze_req_n == 1'b1 && busack_n == 1'b0) begin
                busack_n <= 1'b1;                // release to the guest
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
    wire        io_rd    = sel_eng ? (eng_iorq_n == 1'b0 && eng_rd_n == 1'b0)
                                  : 1'b0;
    wire        io_wr    = sel_eng ? (eng_iorq_n == 1'b0 && eng_wr_n == 1'b0)
                                  : 1'b0;
    wire [7:0]  d_mem    = pmem[addr_eff];
    wire [7:0]  d_io     = addr_eff[7:0] ^ 8'h0F;

    assign cpu_addr = addr_eff;
    assign cpu_din  = io_rd ? d_io : d_mem;

    // WAIT injection (+WAIT): hold cpu_wait_n low for the first cpu_cen period
    // (5 clk) of every engine data-cycle strobe, i.e. one wait state in T2 --
    // the same stimulus as sim/tb_cycle_golden.vhd (R-42), so the stretched
    // waveform can be compared with the real T80's.
    wire strobe_act = sel_eng & (~eng_mreq_n | ~eng_iorq_n) &
                      (~eng_rd_n | ~eng_wr_n);
    reg        strobe_q;
    reg  [2:0] wcnt;
    always @(posedge clk) begin
        strobe_q <= strobe_act;
        if (strobe_act && !strobe_q) wcnt <= 3'd5;
        else if (wcnt != 3'd0)       wcnt <= wcnt - 3'd1;
    end
    assign cpu_wait_n = ~(inject_wait & strobe_act & (wcnt != 3'd0));

    // engine memory write (T2..T3, WR_n low): store into the shared image
    // (gated by rst_n: before the first reset edge the engine strobes are
    //  uninitialised-zero, which would scribble pmem[0])
    wire eng_mem_wr = rst_n & sel_eng & ~eng_mreq_n & ~eng_wr_n;
    always @(posedge clk)
        if (eng_mem_wr) pmem[eng_addr] <= eng_dout;

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

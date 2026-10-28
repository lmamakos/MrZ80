// ssp_uart.v -- SSP console UART (D-33 RV side), ssp_bridge offsets
// 0x120..0x12C (ssp/regs/ssp_regs.csv canonical).
//
// * 8N1, fractional 16x baud from the shared O9B table index value
//   (baud_increment: 2416 => 115200 at 50 MHz, session R4 -- same table
//   the MrZ80 SNAC mux uses; single baud truth for the connector).
// * RX: FIFO of 2**FIFO_LOG2 bytes (default 128, D-41/R29; was 8), sticky
//   rx_overrun (byte dropped when full), self-clearing rx_clr/tx_clr
//   (UART_CTRL).  The depth is what lets an automated sender run at line
//   rate while the polled FW is busy: 128 bytes = ~11 ms of 115200-baud
//   input, i.e. several Mecrisp lines (~3.4 ms each).  No RTS/CTS (R4).  Sampling at BIT CENTRES
//   (R25/H7): start-bit mid at tick 7 (divider pre-biased half-tick),
//   data bits D0..D7 at ticks 23/39/../135, stop validated at 135 too.
// * Escape recognizer (D-14, rev R15) with byte-level relay consumption
//   (OQ-22 option (a), ratified R24): while OSD OM is On the incoming
//   SNAC stream is deserialized here, ESC-matched bytes are consumed, and
//   the remainder is RE-serialized toward the Z80 ACIA.  R25/H6: the
//   Z80 RX mux at ssp_top switches between the RAW pin (OM off -- bit-
//   transparent, R-43) and the RELAY line (OM on).  The relay idles high;
//   switching happens without duplication because in OM mode the raw wire
//   is NEVER routed -- the relay deserializes from the raw pin and
//   re-emits, so the Z80 sees each byte exactly once (worst case one
//   mid-byte torn frame at OM toggle, tolerable: OM is a config switch).
// * Relay TX has a 2-deep queue (R25/H8: survives an off-by-one fast
//   sender: at incr 2416 the relay line runs ~0.8% slow vs the sender, so
//   a one-tick inter-byte stretch is inserted after every 12 back-to-back
//   bytes instead of silently dropping the 13th).
// * RX FIFO is fed only while the monitor owns the console
//   (console_own = fw_console_ok): bytes routed to the Z80 are not
//   stolen from the Z80 by firmware.  While owned, ESC_CHAR is NOT
//   consumed (Z80 is parked -- the REPL sees the raw ^] byte).
//
// TX: 1-deep holding (tx_ready = holding empty); monitor TX reaches the
// SNAC pin through the top-level console mux when console_own.

`timescale 1 ns / 1 ps

module ssp_uart #(
    parameter FIFO_LOG2 = 7                 // RX FIFO depth = 2**FIFO_LOG2
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] baud_increment,      // 16x tick, O9B table

    // ---------------- control / status (bridge-forwarded) ----------------
    input  wire        en,                  // UART_CTRL.en (reset 1)
    input  wire        rx_clr,             // 1-cycle pulse (self-clearing bit)
    input  wire        tx_clr,
    output wire        tx_ready,
    output wire        rx_avail,
    output reg         rx_overrun,         // sticky until rx_clr
    input  wire        rx_pop,             // RXDATA read launched
    output reg  [7:0]  rx_rdata,          // popped byte (bridge presents launch+1)
    input  wire [7:0]  tx_wdata,
    input  wire        tx_wr,

    // ---------------- escape / console policy ----------------------------
    input  wire [7:0]  esc_char,
    input  wire        esc_eff,            // OM & CTRL.esc_break_en & ssp_active
    input  wire        relay_en,          // OM: RX->Z80 goes through relay
    input  wire        parked,            // Z80 bus-parked (bridge truth)
    input  wire        console_own,       // fw_console_ok

    // ---------------- serial lines -----------------------------------------
    input  wire        snac_rxd,          // raw SNAC RX pin (async)
    output wire        relay_txd,         // relay TX pin (Z80 RX wire, OM on)
    output wire        mon_txd,          // monitor TX (to console mux)

    // ---------------- events -----------------------------------------------
    output wire        esc_evt,          // 1-cycle: escape matched, Z80 ran
    output reg         rx_push,        // 1-cycle: byte pushed into RX FIFO
    output wire [7:0]  rx_rnext        // FIFO head valid at pop-launch time
);

    // ------------------------------------------------ RX path ------------
    // 2FF sync of the async pin (relay re-tx also re-synchronises: the
    // relay output is a synchronous, re-clocking copy -- legal because the
    // Z80 ACIA re-samples with its own identical-rate divider; +-0.8%
    // rate skew and the 2FF latency are within the 8N1 tolerance budget).
    reg [1:0] rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[0], snac_rxd};
    wire rxd = rx_sync[1];
    reg rxd_q;                            // start must be a true h->l edge:

    always @(posedge clk) rxd_q <= rxd;   // lock only after an idle-high bit
    reg         rx_act;
    reg  [15:0] rx_acc;
    reg  [7:0]  rx_tcnt;                 // ticks since start-bit edge
    reg  [7:0]  rx_bits;                 // per-centre captures D0..D7
    reg         rx_stop;                 // stop-bit centre sample
    reg         byte_done;               // 1-cycle pulse (valid stop at 151)
    wire [7:0]  rx_byte = rx_bits;
    wire [7:0]  nxt_tcnt = rx_tcnt + 8'd1;

    wire [16:0] rx_nsum  = {1'b0, rx_acc}  + {1'b0, baud_increment};
    wire        rx_tick  = rx_nsum[16];

    // Bit centres (ticks after the falling start edge, half-bit pre-biased
    // divider): start = 7, D0..D7 = 23/39/55/71/87/103/119/135, stop = 151.
    always @(posedge clk) begin
        byte_done <= 1'b0;                     // default: single-cycle pulse
        rx_acc    <= rx_nsum[15:0];          // free-running divider residue
        if (!rst_n) begin
            rx_act   <= 1'b0;
            rx_acc   <= 16'd0;
            rx_tcnt  <= 8'd0;
            rx_bits  <= 8'hFF;
            rx_stop  <= 1'b1;
        end else if (!en) begin
            rx_act <= 1'b0;
        end else if (rx_tick && rx_act) begin
            rx_tcnt <= nxt_tcnt;
            if      (rx_tcnt == 8'd7) begin
                if (rxd) rx_act <= 1'b0;      // false start at centre: abort
            end else if (rx_tcnt == 8'd23)  rx_bits[0] <= rxd;
            else if (rx_tcnt == 8'd39)  rx_bits[1] <= rxd;
            else if (rx_tcnt == 8'd55)  rx_bits[2] <= rxd;
            else if (rx_tcnt == 8'd71)  rx_bits[3] <= rxd;
            else if (rx_tcnt == 8'd87)  rx_bits[4] <= rxd;
            else if (rx_tcnt == 8'd103) rx_bits[5] <= rxd;
            else if (rx_tcnt == 8'd119) rx_bits[6] <= rxd;
            else if (rx_tcnt == 8'd135) rx_bits[7] <= rxd;
            else if (rx_tcnt == 8'd150) begin   // stop-bit centre next tick
                rx_act  <= 1'b0;
                rx_stop <= rxd;
                if (rxd) byte_done <= 1'b1;     // D7 arrived one tick earlier
            end
        end else if (en && !rx_act && rxd == 1'b0 && rxd_q) begin
            rx_act  <= 1'b1;                 // start edge (raw pin)
            rx_acc  <= 16'd32768;           // first tick ~ mid start bit
            rx_tcnt <= 8'd0;
        end
    end

    // ------------------------------------------------ RX FIFO ----------
    // Free-running pointers one bit wider than the index: empty when equal,
    // full when only the MSB differs.  The head is read ASYNCHRONOUSLY
    // (rx_rnext): the bridge captures it on the pop-launch edge (R26).  Async
    // read must map to MLAB (LUT RAM); the ramstyle hint below keeps Quartus
    // from building ~1k flip-flops plus a 128:1 read mux per bit.
    localparam DEPTH = 1 << FIFO_LOG2;
    (* ramstyle = "MLAB, no_rw_check" *) reg [7:0] fifo [0:DEPTH-1];
    reg [FIFO_LOG2:0] wp, rp;
    wire fifo_empty = (wp == rp);
    wire fifo_full  = (wp[FIFO_LOG2] != rp[FIFO_LOG2]) &&
                      (wp[FIFO_LOG2-1:0] == rp[FIFO_LOG2-1:0]);
    assign rx_avail = !fifo_empty;
    // R25: RXDATA must present the popped byte at launch+1.  A bridge flop
    // sampling rx_rdata (a register) in the SAME timestep as the pop sees
    // the PREVIOUS byte (both read the old value) -- one-byte skew.  The
    // bridge must instead capture this combinational head value.
    assign rx_rnext = fifo[rp[FIFO_LOG2-1:0]];

    // escape consumption (OQ-22a): match only while the Z80 runs
    wire esc_hit = byte_done && rx_stop && esc_eff && !parked
                   && (rx_byte == esc_char);
    assign esc_evt = esc_hit;

    always @(posedge clk) begin
        rx_push <= 1'b0;
        if (!rst_n) begin
            wp <= {(FIFO_LOG2+1){1'b0}}; rp <= {(FIFO_LOG2+1){1'b0}};
            rx_overrun <= 1'b0; rx_rdata <= 8'd0;
        end else begin
            if (rx_clr) begin
                rp         <= wp;                 // flush
                rx_overrun <= 1'b0;
            end
            if (byte_done && rx_stop && console_own && !rx_clr) begin
                if (!fifo_full) begin
                    fifo[wp[FIFO_LOG2-1:0]] <= rx_byte;
                    wp            <= wp + 1'b1;
                    rx_push       <= 1'b1;
                end else begin
                    rx_overrun    <= 1'b1;      // byte lost
                end
            end
            if (rx_pop && rx_avail && !rx_clr) begin
                rx_rdata <= rx_rnext;      // same read port: one RAM copy
                rp       <= rp + 1'b1;
            end
        end
    end

    // ------------------------------------------------ monitor TX ---------
    reg         mon_hold_v, mon_act;
    reg  [7:0]  mon_hold;
    reg  [9:0]  mon_shift;              // {stop,d7..d0,start}, bit0 first
    reg  [15:0] mon_acc;
    reg  [7:0]  mon_tcnt;
    wire [16:0] mon_nsum = {1'b0, mon_acc} + {1'b0, baud_increment};
    wire        mon_tick = mon_nsum[16];

    assign tx_ready = !mon_hold_v;
    assign mon_txd  = mon_act ? mon_shift[0] : 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            mon_hold_v <= 1'b0; mon_act <= 1'b0;
            mon_hold   <= 8'd0; mon_shift <= 10'h3FF; mon_acc <= 16'd0;
            mon_tcnt   <= 8'd0;
        end else if (en) begin
            mon_acc <= mon_nsum[15:0];         // free-running divider residue
            if (tx_clr) mon_hold_v <= 1'b0;
            if (tx_wr && !mon_hold_v) begin
                mon_hold   <= tx_wdata;
                mon_hold_v <= 1'b1;
            end
            if (!mon_act && mon_hold_v) begin
                mon_shift  <= {1'b1, mon_hold, 1'b0};  // stop+d7..d0+start
                mon_act    <= 1'b1;
                mon_hold_v <= 1'b0;
                mon_acc    <= 16'd0;
                mon_tcnt   <= 8'd0;
            end else if (mon_act && mon_tick) begin
                mon_tcnt <= mon_tcnt + 8'd1;
                if (mon_tcnt[3:0] == 4'd15)
                    mon_shift <= {1'b1, mon_shift[9:1]};   // bit edge d0..d7, stop
                if (mon_tcnt == 8'd159) mon_act <= 1'b0;   // stop done
            end
        end else begin
            mon_act <= 1'b0; mon_hold_v <= 1'b0;
        end
    end

    // ------------------------------------------------ relay TX -----------
    // Re-serializes filtered RX bytes toward the Z80 while OM On.
    // 2-deep queue + inter-byte stretch (R25/H8).
    reg         rel_hold_v, rel_hold2_v, rel_act;
    reg  [7:0]  rel_hold, rel_hold2;
    reg  [9:0]  rel_shift;              // {stop,d7..d0,start}, bit0 first
    reg  [15:0] rel_acc;
    reg  [7:0]  rel_tcnt;
    reg  [3:0]  rel_run;                     // back-to-back run counter
    reg         rel_stretch;                 // one-tick inter-byte pause active
    wire [16:0] rel_nsum = {1'b0, rel_acc} + {1'b0, baud_increment};
    wire        rel_tick = rel_nsum[16];
    wire        rel_q    = rel_hold_v | rel_hold2_v;

    assign relay_txd = rel_act ? rel_shift[0]
                     : rel_q    ? 1'b0        // queued: hold line low (stretch)
                     : 1'b1;                  // idle

    always @(posedge clk) begin
        if (!rst_n) begin
            rel_hold_v <= 1'b0; rel_hold2_v <= 1'b0; rel_act <= 1'b0;
            rel_hold <= 8'd0; rel_hold2 <= 8'd0;
            rel_shift <= 10'h3FF; rel_acc <= 16'd0;
            rel_tcnt <= 8'd0; rel_run <= 4'd0; rel_stretch <= 1'b0;
        end else if (en) begin
            rel_acc <= rel_nsum[15:0];
            // push completed, non-escaped bytes toward the Z80
            if (byte_done && rx_stop && relay_en && !console_own && !esc_hit) begin
                if (!rel_hold_v) begin
                    rel_hold   <= rx_byte;
                    rel_hold_v <= 1'b1;
                end else if (!rel_hold2_v) begin
                    rel_hold2   <= rx_byte;
                    rel_hold2_v <= 1'b1;
                end
                // 2-deep overrun: impossible at <=0.8%/8 skew -- ignore
            end
            if (!rel_act && rel_hold_v) begin
                rel_shift   <= {1'b1, rel_hold, 1'b0};  // stop+d7..d0+start
                rel_hold    <= rel_hold2;
                rel_hold_v  <= rel_hold2_v;
                rel_hold2_v <= 1'b0;
                rel_act     <= 1'b1;
                rel_acc     <= 16'd0;
                rel_tcnt    <= 8'd0;
            end else if (rel_act && rel_tick) begin
                rel_tcnt <= rel_tcnt + 8'd1;
                if (rel_tcnt[3:0] == 4'd15)
                    rel_shift <= {1'b1, rel_shift[9:1]};
                if (rel_tcnt == 8'd159) begin
                    if (rel_q) begin
                        if (rel_stretch) begin
                            rel_stretch <= 1'b0;
                            rel_act     <= 1'b0;   // pause done -> next start
                        end else begin
                            rel_run <= rel_run + 4'd1;
                            if (rel_run >= 4'd12) begin
                                rel_run     <= 4'd0;
                                rel_stretch <= 1'b1; // one extra low tick now
                            end
                        end
                    end else begin
                        rel_run <= 4'd0;
                        rel_act <= 1'b0;
                    end
                end
            end
        end else begin
            rel_act <= 1'b0; rel_hold_v <= 1'b0; rel_hold2_v <= 1'b0;
        end
    end

endmodule

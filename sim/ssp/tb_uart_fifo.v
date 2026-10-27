// tb_uart_fifo.v -- ssp_uart RX FIFO unit bench (R29, D-41).  iverilog.
//
// Drives real 8N1 frames at 115200 (baud_increment 2416 @ 50 MHz), BACK TO
// BACK (no idle bit: the maximum rate an automated sender can reach), into
// ssp_uart with console_own=1, and pops through the same interface the
// bridge uses (the combinational head rx_rnext captured on the pop edge).
//
// Cases: 1 fill to exactly DEPTH (no overrun, order intact) - 2 overrun
// (extras dropped, first DEPTH intact, sticky flag, rx_clr clears) - 2b exactly
// full from shifted read-pointer phases - 3
// pointer wraparound at partial occupancy (3*DEPTH bytes through a FIFO held
// ~half full, popping as bytes arrive) - 4 flush - 5 console_own gating.
//
// Run: sim/ssp/run_uart_fifo.sh  (depths 8 and 128)

`timescale 1ns / 1ps

module tb_uart_fifo;
    parameter L = 7;                       // FIFO_LOG2 under test
    localparam DEPTH = 1 << L;
    localparam BIT   = 434;                // clk per bit @ 115200, 50 MHz

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                 // 50 MHz

    reg        rxd = 1'b1;
    reg        rx_pop = 0, rx_clr = 0, own = 1;
    wire       rx_avail, rx_overrun, rx_push;
    wire [7:0] rx_rnext;

    ssp_uart #(.FIFO_LOG2(L)) dut (
        .clk(clk), .rst_n(rst_n), .baud_increment(16'd2416),
        .en(1'b1), .rx_clr(rx_clr), .tx_clr(1'b0),
        .tx_ready(), .rx_avail(rx_avail), .rx_overrun(rx_overrun),
        .rx_pop(rx_pop), .rx_rdata(), .tx_wdata(8'd0), .tx_wr(1'b0),
        .esc_char(8'h1d), .esc_eff(1'b0), .relay_en(1'b0),
        .parked(1'b0), .console_own(own),
        .snac_rxd(rxd), .relay_txd(), .mon_txd(),
        .esc_evt(), .rx_push(rx_push), .rx_rnext(rx_rnext));

    integer errors = 0, checks = 0;
    task check(input ok, input [255:0] what);
        begin
            checks = checks + 1;
            if (!ok) begin
                errors = errors + 1;
                $display("FAIL: %0s (t=%0t)", what, $time);
            end
        end
    endtask

    function [7:0] pat(input integer i);
        pat = (i * 131 + (i >> 7) * 29 + 7) & 255;
    endfunction

    // one 8N1 frame, no idle gap after the stop bit
    task send(input [7:0] b);
        integer k;
        begin
            rxd = 1'b0;                    repeat (BIT) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                rxd = b[k];                repeat (BIT) @(posedge clk);
            end
            rxd = 1'b1;                    repeat (BIT) @(posedge clk);
        end
    endtask

    // pop like the bridge: capture the combinational head at the launch edge
    reg [7:0] got;
    task pop;
        begin
            @(negedge clk);
            got = rx_rnext;
            rx_pop = 1'b1;
            @(negedge clk);
            rx_pop = 1'b0;
        end
    endtask

    task drain_expect(input integer first, input integer n, input [255:0] what);
        integer i;
        reg ok;
        begin
            ok = 1'b1;
            for (i = 0; i < n; i = i + 1) begin
                if (!rx_avail) ok = 1'b0;
                else begin
                    pop;
                    if (got !== pat(first + i)) ok = 1'b0;
                end
            end
            check(ok, what);
            check(!rx_avail, "FIFO empty after draining");
        end
    endtask

    integer i, j, n;

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (50) @(posedge clk);

        // ---- 1. fill to exactly DEPTH, back-to-back, no popping
        for (i = 0; i < DEPTH; i = i + 1) send(pat(i));
        repeat (BIT) @(posedge clk);
        check(rx_avail, "1: avail after fill");
        check(!rx_overrun, "1: no overrun at exactly DEPTH bytes");
        drain_expect(0, DEPTH, "1: all DEPTH bytes in order");

        // ---- 2. overrun: DEPTH+3 bytes; extras dropped, flag sticky
        for (i = 0; i < DEPTH + 3; i = i + 1) send(pat(1000 + i));
        repeat (BIT) @(posedge clk);
        check(rx_overrun, "2: overrun flagged");
        drain_expect(1000, DEPTH, "2: first DEPTH bytes intact, extras dropped");
        check(rx_overrun, "2: overrun is sticky until rx_clr");
        @(negedge clk); rx_clr = 1; @(negedge clk); rx_clr = 0;
        repeat (4) @(posedge clk);
        check(!rx_overrun, "2: rx_clr clears overrun");

        // ---- 2b. exactly-full from several read-pointer phases (odd, mid,
        //          DEPTH-1): the full/empty test must not depend on the phase
        for (n = 0; n < 4; n = n + 1) begin
            case (n)
                0: j = 1;
                1: j = 3;
                2: j = DEPTH / 2 + 1;
                default: j = DEPTH - 1;
            endcase
            for (i = 0; i < j; i = i + 1) send(pat(2000 + i));   // advance rp/wp
            drain_expect(2000, j, "2b: phase advance");
            for (i = 0; i < DEPTH; i = i + 1) send(pat(3000 + i));
            repeat (BIT) @(posedge clk);
            check(!rx_overrun, "2b: no overrun at exactly DEPTH from a shifted phase");
            send(pat(3999));                                       // one too many
            repeat (BIT) @(posedge clk);
            check(rx_overrun, "2b: overrun on DEPTH+1 from a shifted phase");
            drain_expect(3000, DEPTH, "2b: DEPTH bytes intact from a shifted phase");
            @(negedge clk); rx_clr = 1; @(negedge clk); rx_clr = 0;
            repeat (4) @(posedge clk);
        end

        // ---- 3. wraparound: hold ~half full, stream 3*DEPTH bytes through
        n = DEPTH / 2;
        for (i = 0; i < n; i = i + 1) send(pat(5000 + i));
        for (i = n; i < n + 3 * DEPTH + 17; i = i + 1) begin
            send(pat(5000 + i));
            repeat (3) @(posedge clk);
            if (rx_avail) begin
                pop;
                check(got === pat(5000 + i - n), "3: streaming order across wrap");
            end else
                check(1'b0, "3: FIFO unexpectedly empty while streaming");
        end
        check(!rx_overrun, "3: no overrun while streaming");
        drain_expect(5000 + 3 * DEPTH + 17, n, "3: residual bytes in order");

        // ---- 4. flush
        for (i = 0; i < 5; i = i + 1) send(pat(9000 + i));
        repeat (BIT) @(posedge clk);
        check(rx_avail, "4: bytes present before flush");
        @(negedge clk); rx_clr = 1; @(negedge clk); rx_clr = 0;
        repeat (4) @(posedge clk);
        check(!rx_avail, "4: flushed");
        for (i = 0; i < 2; i = i + 1) send(pat(9100 + i));
        repeat (BIT) @(posedge clk);
        drain_expect(9100, 2, "4: only post-flush bytes remain");

        // ---- 5. console_own=0: bytes belong to the guest, never queued
        own = 1'b0;
        for (i = 0; i < 3; i = i + 1) send(pat(9500 + i));
        repeat (BIT) @(posedge clk);
        check(!rx_avail, "5: nothing queued while the guest owns the console");
        own = 1'b1;

        if (errors == 0)
            $display("tb_uart_fifo: PASS (DEPTH=%0d, %0d checks)", DEPTH, checks);
        else
            $display("tb_uart_fifo: FAIL (DEPTH=%0d, %0d of %0d checks failed)",
                     DEPTH, errors, checks);
        $finish;
    end

    initial begin                           // watchdog
        #(64'd400_000_000);
        $display("tb_uart_fifo: FAIL (timeout)");
        $finish;
    end
endmodule

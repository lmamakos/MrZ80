// tb_psg.sv - unit bench for Components/PSG/MrZ80_PSG.sv (Verilator --binary).
// Drives Z-80-style I/O cycles at the four PSG ports and checks:
//   * silence from reset through the mute/settle window and after it
//   * the RomWBW ay.asm probe (R2 <- $55, read back via $51) and $50 readback
//   * device 2 ($68/$60) is independent of device 1, and readable at $68
//   * an out-of-range SELECT drops DATA writes and reads $FF
//   * AY read masks (R1 reads back 4 bits)
//   * the OSD stereo sequencer: ABC gains, ACB on an OSD change, and that an
//     OSD change keeps the software-set master volume
//   * a device-1 tone at the programmed frequency, left-heavy under ABC
//   * a device-2 tone, right-heavy under ABC (channel F = device 2 C)
// Prints PASS: tb_psg / FAIL lines; exit status non-zero on failure.
`timescale 1ns/1ps

module tb_psg;
    localparam int CLK_HZ = 50_000_000;

    logic clk = 0;
    always #10 clk = ~clk;                       // 50 MHz

    logic        reset_n = 0;
    logic  [1:0] stereo_mode = 2'd1;             // ABC
    logic  [7:0] port = 0;
    logic        io_active = 0, io_wr = 0;
    logic  [7:0] din = 0;
    wire   [7:0] dout;
    wire signed [15:0] audio_l, audio_r;

    wire cs_sel1 = io_active && port == 8'h50;
    wire cs_dat1 = io_active && port == 8'h51;
    wire cs_sel2 = io_active && port == 8'h68;
    wire cs_dat2 = io_active && port == 8'h60;

    MrZ80_PSG #(.CLK_HZ(CLK_HZ)) dut (
        .clk(clk), .reset_n(reset_n), .stereo_mode(stereo_mode),
        .cs_sel1(cs_sel1), .cs_dat1(cs_dat1), .cs_sel2(cs_sel2), .cs_dat2(cs_dat2),
        .io_wr(io_wr), .din(din), .dout(dout),
        .audio_l(audio_l), .audio_r(audio_r));

    int errors = 0;

    // A 10 MHz Z-80 I/O cycle: IORQ active for ~3 T-states = 15 clk.
    task automatic io_out(input [7:0] p, input [7:0] d);
        @(posedge clk); port <= p; din <= d; io_active <= 1; io_wr <= 1;
        repeat (15) @(posedge clk);
        io_active <= 0; io_wr <= 0;
        repeat (5) @(posedge clk);
    endtask

    task automatic io_in(input [7:0] p, output [7:0] d);
        @(posedge clk); port <= p; io_active <= 1;
        repeat (15) @(posedge clk);
        d = dout;
        io_active <= 0;
        repeat (5) @(posedge clk);
    endtask

    task automatic check(input string what, input [7:0] got, input [7:0] exp);
        if (got !== exp) begin
            $display("FAIL: %s: got $%02x expected $%02x", what, got, exp);
            errors++;
        end else
            $display("  ok  %s = $%02x", what, got);
    endtask

    task automatic reg_rd(input [7:0] selp, input [7:0] datp, input [7:0] r, output [7:0] v);
        io_out(selp, r);
        io_in(datp, v);
    endtask

    // Peak |audio| over n clocks.
    task automatic peak(input int n, output int pl, output int pr);
        int a, b;
        pl = 0; pr = 0;
        repeat (n) begin
            @(posedge clk);
            a = audio_l < 0 ? -audio_l : audio_l;
            b = audio_r < 0 ? -audio_r : audio_r;
            if (a > pl) pl = a;
            if (b > pr) pr = b;
        end
    endtask

    // Count rising zero crossings of audio_l (or audio_r) over n clocks.
    task automatic crossings(input bit right, input int n, output int c);
        logic signed [15:0] prev, cur;
        c = 0;
        prev = right ? audio_r : audio_l;
        repeat (n) begin
            @(posedge clk);
            cur = right ? audio_r : audio_l;
            if (prev < 0 && cur >= 0) c++;
            prev = cur;
        end
    endtask

    logic [7:0] v;
    int pl, pr, c, expc;

    initial begin
        repeat (20) @(posedge clk);
        reset_n <= 1;

        // ---- silence from reset ---------------------------------------------
        // Mute window: exactly zero.  After unmute the vendor DC filter leaves
        // a constant residual of a few LSB (its x>>>8 discharge term stops
        // below that resolution): a flat DC level, not sound.  Require no AC
        // at all and a step of at most 16 LSB (-66 dBFS).
        peak(CLK_HZ / 1000 * 195, pl, pr);       // 0..195 ms
        $display("  reset..195 ms (muted) peak L=%0d R=%0d", pl, pr);
        if (pl != 0 || pr != 0) begin
            $display("FAIL: output not zero during the post-reset mute"); errors++;
        end
        repeat (CLK_HZ / 1000 * 10) @(posedge clk);   // across the unmute at 200 ms
        begin
            logic signed [15:0] l0, r0;
            int acl = 0, acr = 0, d;
            l0 = audio_l; r0 = audio_r;
            repeat (CLK_HZ / 20) begin               // 205..255 ms
                @(posedge clk);
                d = audio_l - l0; if (d < 0) d = -d; if (d > acl) acl = d;
                d = audio_r - r0; if (d < 0) d = -d; if (d > acr) acr = d;
            end
            $display("  after unmute: DC L=%0d R=%0d, AC deviation L=%0d R=%0d", l0, r0, acl, acr);
            if (acl != 0 || acr != 0 || l0 > 16 || l0 < -16 || r0 > 16 || r0 < -16) begin
                $display("FAIL: output not silent after unmute"); errors++;
            end
        end
        check("mixer state after settle: L.mvol", 8'(dut.psg.FMIX_LEFT.cregs[6]), 8'd128);

        // ---- ay.asm probe ---------------------------------------------------
        io_out(8'h50, 8'h02);
        io_out(8'h51, 8'h55);
        io_in(8'h51, v);  check("dev1 R2 via $51", v, 8'h55);
        io_in(8'h50, v);  check("dev1 R2 via $50", v, 8'h55);

        // ---- device 2 independent ----------------------------------------
        io_out(8'h68, 8'h02);
        io_out(8'h60, 8'hAA);
        io_in(8'h68, v);  check("dev2 R2 via $68", v, 8'hAA);
        io_in(8'h60, v);  check("dev2 R2 via $60", v, 8'hAA);
        reg_rd(8'h50, 8'h51, 8'h02, v); check("dev1 R2 unchanged", v, 8'h55);

        // ---- out-of-range SELECT -----------------------------------------
        io_out(8'h50, 8'h22);
        io_in(8'h51, v);  check("dev1 SELECT $22 reads", v, 8'hFF);
        io_out(8'h51, 8'h12);                    // must be dropped
        io_out(8'h50, 8'h8A);                    // mixer reg 10 does not exist
        io_in(8'h51, v);  check("dev1 SELECT $8A reads", v, 8'hFF);
        io_out(8'h68, 8'h82);                    // device 2 has no mixer view
        io_in(8'h60, v);  check("dev2 SELECT $82 reads", v, 8'hFF);
        io_out(8'h60, 8'h33);                    // must be dropped
        reg_rd(8'h50, 8'h51, 8'h02, v); check("dev1 R2 after dropped writes", v, 8'h55);
        reg_rd(8'h68, 8'h60, 8'h02, v); check("dev2 R2 after dropped writes", v, 8'hAA);

        // ---- read mask ------------------------------------------------------
        io_out(8'h50, 8'h01); io_out(8'h51, 8'hFF);
        io_in(8'h51, v);  check("dev1 R1 masked", v, 8'h0F);

        // ---- stereo sequencer (ABC after reset) ----------------------------
        reg_rd(8'h50, 8'h51, 8'h80, v); check("ABC L.A", v, 8'd96);
        reg_rd(8'h50, 8'h51, 8'h81, v); check("ABC L.B", v, 8'd64);
        reg_rd(8'h50, 8'h51, 8'h82, v); check("ABC L.C", v, 8'd32);
        reg_rd(8'h50, 8'h51, 8'h85, v); check("ABC L.F", v, 8'd32);
        reg_rd(8'h50, 8'h51, 8'h90, v); check("ABC R.A", v, 8'd32);
        reg_rd(8'h50, 8'h51, 8'h95, v); check("ABC R.F", v, 8'd96);
        reg_rd(8'h50, 8'h51, 8'h86, v); check("L.mvol", v, 8'd128);

        // software master volume survives an OSD change; gains follow it
        io_out(8'h50, 8'h86); io_out(8'h51, 8'd100);
        stereo_mode <= 2'd2;                     // ACB
        repeat (100) @(posedge clk);
        reg_rd(8'h50, 8'h51, 8'h81, v); check("ACB L.B", v, 8'd32);
        reg_rd(8'h50, 8'h51, 8'h82, v); check("ACB L.C", v, 8'd64);
        reg_rd(8'h50, 8'h51, 8'h91, v); check("ACB R.B", v, 8'd96);
        reg_rd(8'h50, 8'h51, 8'h86, v); check("L.mvol kept after OSD change", v, 8'd100);
        stereo_mode <= 2'd0;                     // Mono
        repeat (100) @(posedge clk);
        reg_rd(8'h50, 8'h51, 8'h80, v); check("Mono L.A", v, 8'd64);
        reg_rd(8'h50, 8'h51, 8'h93, v); check("Mono R.D", v, 8'd64);
        io_out(8'h50, 8'h86); io_out(8'h51, 8'd128);
        stereo_mode <= 2'd1;                     // back to ABC
        repeat (100) @(posedge clk);

        // ---- device 1 tone A: period 256 -> 1789772/(16*256) = 437 Hz -------
        io_out(8'h50, 8'h00); io_out(8'h51, 8'h00);
        io_out(8'h50, 8'h01); io_out(8'h51, 8'h01);
        io_out(8'h50, 8'h07); io_out(8'h51, 8'hFE);   // tone A only, IO as input
        io_out(8'h50, 8'h08); io_out(8'h51, 8'h0F);   // A volume 15
        repeat (CLK_HZ / 20) @(posedge clk);          // 50 ms for the DC filter
        crossings(1'b0, CLK_HZ / 10, c);               // 100 ms
        expc = 44;
        $display("  dev1 tone: %0d rising crossings / 100 ms (expect ~%0d)", c, expc);
        if (c < expc - 3 || c > expc + 3) begin
            $display("FAIL: dev1 tone frequency"); errors++;
        end
        peak(CLK_HZ / 20, pl, pr);
        $display("  dev1 tone A under ABC: peak L=%0d R=%0d", pl, pr);
        if (!(pl > 2 * pr && pr > 0)) begin
            $display("FAIL: channel A not left-heavy under ABC"); errors++;
        end
        io_out(8'h50, 8'h08); io_out(8'h51, 8'h00);   // A off

        // ---- device 2 tone C (= mixer channel F): period 128 -> 874 Hz ------
        io_out(8'h68, 8'h04); io_out(8'h60, 8'h80);
        io_out(8'h68, 8'h05); io_out(8'h60, 8'h00);
        io_out(8'h68, 8'h07); io_out(8'h60, 8'hFB);   // tone C only
        io_out(8'h68, 8'h0A); io_out(8'h60, 8'h0F);   // C volume 15
        repeat (CLK_HZ / 20) @(posedge clk);
        crossings(1'b1, CLK_HZ / 10, c);
        expc = 87;
        $display("  dev2 tone: %0d rising crossings / 100 ms (expect ~%0d)", c, expc);
        if (c < expc - 4 || c > expc + 4) begin
            $display("FAIL: dev2 tone frequency"); errors++;
        end
        peak(CLK_HZ / 20, pl, pr);
        $display("  dev2 tone C under ABC: peak L=%0d R=%0d", pl, pr);
        if (!(pr > 2 * pl && pl > 0)) begin
            $display("FAIL: device-2 channel C not right-heavy under ABC"); errors++;
        end

        if (errors == 0) $display("PASS: tb_psg");
        else             $display("FAIL: tb_psg (%0d errors)", errors);
        $finish(errors != 0);
    end
endmodule

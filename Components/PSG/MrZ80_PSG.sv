// MrZ80_PSG.sv - two YM2149 / AY-3-8910 PSGs on Z-80 I/O port pairs, plus
// a power-on stereo-mix sequencer, around the vendored YM2149_PSG_system
// (Components/YM2149, unmodified).  The build must define the macros
// USE_STEREO and USE_DUAL_PSG (MrZ80.qsf VERILOG_MACRO, sim/run_psg.sh);
// without them YM2149_PSG_system has one mono PSG and no device 2.
//
// Z-80 programming model (see HARDWARE.md "PSG sound"):
//
//   $50  write: device 1 SELECT  read: selected register  (RomWBW AYMODE_COLECO)
//   $51  write: device 1 DATA    read: selected register  (ay.asm reads here)
//   $68  write: device 2 SELECT  read: selected register  (vibetune "EB" card)
//   $60  write: device 2 DATA    read: selected register
//
//   SELECT values:
//     device 1  $00-$0F  PSG A registers R0-R15
//               $80-$89  left  mixer registers 0-9  (MrZ80 extension)
//               $90-$99  right mixer registers 0-9  (MrZ80 extension)
//     device 2  $00-$0F  PSG B registers R0-R15
//   Any other SELECT value deselects the device, the way a real AY-3-8910
//   ignores a latched address whose upper nibble is not its chip code:
//   DATA writes are dropped and reads return $FF.
//
// YM2149_PSG_system has no latched address: it takes a flat 8-bit addr
// whose high nibble picks the target (0 = PSG A, 1 = PSG B, 8 = left mixer,
// 9 = right mixer) and level-sensitive writes.  This wrapper holds the two
// SELECT latches and steers addr/data/wr_n.  The CPU always has priority on
// that shared bus; the mix sequencer only writes in idle cycles.
//
// Mixers.  Each output side (L, R) has one BHG_audio_filter_mixer that sums
// all six PSG channels (A, B, C of device 1; D, E, F of device 2), each with
// its own gain, then applies a DC filter, bass/treble and a master volume.
// Register map of one mixer (offset within $80/$90):
//     0-5  channel gain A..F  (0 = off, 64 = vendor default, 255 = max;
//                              product is in/256, so 64 is 1/4 of full scale)
//     6    master volume      (0 = mute, 128 = 100%, 255 = 200% with limiter)
//     7    phase-invert bits  {x,x,F,E,D,C,B,A}
//     8    bass  (1 = most bass .. 63 = least; 0 lets DC through)
//     9    treble (0 = full bandwidth .. 255 = muffled)
//
// Stereo modes (OSD "PSG Stereo", input stereo_mode):
//     0 Mono  every channel at 64 on both sides (the vendor default).
//     1 ABC   A left, B centre, C right  (ZX Spectrum 128 / Amstrad CPC).
//     2 ACB   A left, C centre, B right  (Pentagon / many demoscene players).
//     3       treated as Mono.
//   Device 2 (D, E, F) is panned like device 1 (A, B, C).  Panning is
//   partial (96/64/32 of 256, i.e. a 3:1 side/opposite split) so a single
//   channel never vanishes from one ear, and every mode keeps the per-side
//   gain sum at 384, so switching modes does not change loudness.
//
// Reset.  The PSG registers reset to 0 (all volumes 0), so neither chip
// makes a tone.  The mixer, however, sees the DAC's constant level jump at
// reset and its DC filter takes ~12 ms per time constant to centre it,
// which would be an audible thump.  The sequencer therefore mutes both
// master volumes on the first idle cycles after reset, waits SETTLE_CYCLES
// (200 ms, ~17 time constants), and only then writes the selected panning,
// clears phase-invert and restores master volume to 128.  Changing the OSD
// option later rewrites only the six gains of each side, so software
// changes to master volume, invert, bass or treble survive it; an OSD
// change does overwrite gains that software has set.

module MrZ80_PSG #(
    parameter int CLK_HZ        = 50_000_000,
    parameter int PSG_HZ        = 1_789_772,     // MSX clock; RomWBW AY_CLK
    parameter int DAC_BITS      = 10,            // 10 = closest to a real YM2149
    parameter int SETTLE_CYCLES = CLK_HZ / 5     // 200 ms mute after reset
)(
    input  wire               clk,
    input  wire               reset_n,
    input  wire        [1:0]  stereo_mode,

    // Decoded port selects, each already qualified by an I/O cycle
    // (active high for the whole IORQ+RD or IORQ+WR).
    input  wire               cs_sel1,           // $50
    input  wire               cs_dat1,           // $51
    input  wire               cs_sel2,           // $68
    input  wire               cs_dat2,           // $60
    input  wire               io_wr,             // active-high write strobe
    input  wire        [7:0]  din,
    output wire        [7:0]  dout,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r
);

    // ------------------------------------------------------------------
    // SELECT latches
    // ------------------------------------------------------------------
    logic [7:0] sel1, sel2;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            sel1 <= 8'h00;
            sel2 <= 8'h00;
        end else if (io_wr) begin
            if (cs_sel1) sel1 <= din;
            if (cs_sel2) sel2 <= din;
        end
    end

    wire dev1_psg = (sel1[7:4] == 4'h0);
    wire dev1_mix = (sel1[7:4] == 4'h8 || sel1[7:4] == 4'h9) && (sel1[3:0] <= 4'd9);
    wire dev1_ok  = dev1_psg | dev1_mix;
    wire dev2_ok  = (sel2[7:4] == 4'h0);

    wire cpu_dev2 = cs_sel2 | cs_dat2;
    wire cpu_busy = cs_sel1 | cs_dat1 | cpu_dev2;

    wire [7:0] cpu_addr = cpu_dev2 ? {4'h1, sel2[3:0]} : sel1;
    wire       cpu_ok   = cpu_dev2 ? dev2_ok : dev1_ok;
    wire       cpu_wr   = io_wr & (cs_dat1 | cs_dat2) & cpu_ok;

    // ------------------------------------------------------------------
    // Stereo-mix sequencer
    // ------------------------------------------------------------------
    // Gain of PSG channel ch (0 = A/D, 1 = B/E, 2 = C/F) on one side.
    function automatic [7:0] pan_gain(input [1:0] mode, input right, input [1:0] ch);
        logic [1:0] pos;            // 0 = left-heavy, 1 = centre, 2 = right-heavy
        case (mode)
            2'd1:    pos = ch;                                       // ABC
            2'd2:    pos = (ch == 2'd0) ? 2'd0 : (ch == 2'd1) ? 2'd2 : 2'd1;  // ACB
            default: pos = 2'd3;                                     // Mono
        endcase
        case (pos)
            2'd0:    pan_gain = right ? 8'd32 : 8'd96;
            2'd1:    pan_gain = 8'd64;
            2'd2:    pan_gain = right ? 8'd96 : 8'd32;
            default: pan_gain = 8'd64;
        endcase
    endfunction

    typedef enum logic [1:0] { S_MUTE, S_SETTLE, S_APPLY, S_IDLE } seq_state_t;

    seq_state_t  st;
    logic  [4:0] idx;               // step within S_MUTE / S_APPLY
    logic        full;              // S_APPLY also writes invert + master volume
    logic  [1:0] mode;              // mode being applied / last applied
    logic [$clog2(SETTLE_CYCLES+1)-1:0] settle;

    logic  [7:0] seq_addr, seq_data;
    logic        seq_last;          // current step is the last of its state

    // Step tables.
    //   S_MUTE : 0 L.mvol=0, 1 R.mvol=0
    //   S_APPLY: 0-5 L.gain A..F, 6-11 R.gain A..F,
    //            then (full only) 12 L.inv=0, 13 R.inv=0, 14 L.mvol=128, 15 R.mvol=128
    always_comb begin
        seq_addr = 8'h00;
        seq_data = 8'h00;
        seq_last = 1'b0;
        if (st == S_MUTE) begin
            seq_addr = idx[0] ? 8'h96 : 8'h86;
            seq_data = 8'd0;
            seq_last = (idx == 5'd1);
        end else if (st == S_APPLY) begin
            if (idx < 5'd6) begin
                seq_addr = {4'h8, 1'b0, idx[2:0]};
                seq_data = pan_gain(mode, 1'b0, (idx[2:0] >= 3'd3) ? 2'(idx[2:0] - 3'd3) : idx[1:0]);
            end else if (idx < 5'd12) begin
                seq_addr = {4'h9, 1'b0, 3'(idx - 5'd6)};
                seq_data = pan_gain(mode, 1'b1, ((idx - 5'd6) >= 5'd3) ? 2'(idx - 5'd9) : 2'(idx - 5'd6));
            end else begin
                case (idx)
                    5'd12:   begin seq_addr = 8'h87; seq_data = 8'd0;   end
                    5'd13:   begin seq_addr = 8'h97; seq_data = 8'd0;   end
                    5'd14:   begin seq_addr = 8'h86; seq_data = 8'd128; end
                    default: begin seq_addr = 8'h96; seq_data = 8'd128; end
                endcase
            end
            seq_last = full ? (idx == 5'd15) : (idx == 5'd11);
        end
    end

    wire seq_wr = (st == S_MUTE || st == S_APPLY) && !cpu_busy;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            st     <= S_MUTE;
            idx    <= 5'd0;
            full   <= 1'b1;
            mode   <= stereo_mode;
            settle <= '0;
        end else begin
            case (st)
                S_MUTE:
                    if (seq_wr) begin
                        if (seq_last) begin
                            st     <= S_SETTLE;
                            settle <= '0;
                        end
                        idx <= seq_last ? 5'd0 : idx + 5'd1;
                    end
                S_SETTLE:
                    if (settle == SETTLE_CYCLES[$bits(settle)-1:0]) begin
                        st   <= S_APPLY;
                        idx  <= 5'd0;
                        full <= 1'b1;
                        mode <= stereo_mode;
                    end else begin
                        settle <= settle + 1'b1;
                    end
                S_APPLY:
                    if (seq_wr) begin
                        if (seq_last) st <= S_IDLE;
                        idx <= seq_last ? 5'd0 : idx + 5'd1;
                    end
                S_IDLE:
                    if (stereo_mode != mode) begin
                        st   <= S_APPLY;
                        idx  <= 5'd0;
                        full <= 1'b0;
                        mode <= stereo_mode;
                    end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Shared bus into YM2149_PSG_system
    // ------------------------------------------------------------------
    wire [7:0] sys_addr = cpu_busy ? cpu_addr : seq_addr;
    wire [7:0] sys_data = cpu_busy ? din      : seq_data;
    wire       sys_wr_n = cpu_busy ? ~cpu_wr  : ~seq_wr;
    wire [7:0] sys_dout;
    wire signed [15:0] snd_l, snd_r;

    YM2149_PSG_system #(
        .CLK_IN_HZ       ( CLK_HZ   ),
        .CLK_I2S_IN_HZ   ( CLK_HZ   ),   // I2S is compiled out (USE_I2S undefined)
        .CLK_PSG_HZ      ( PSG_HZ   ),
        .I2S_DAC_HZ      ( 48000    ),
        .YM2149_DAC_BITS ( DAC_BITS ),
        .MIXER_DAC_BITS  ( 16       )
    ) psg (
        .clk         ( clk      ),
        .clk_i2s     ( clk      ),
        .reset_n     ( reset_n  ),
        .addr        ( sys_addr ),
        .data        ( sys_data ),
        .wr_n        ( sys_wr_n ),
        .dout        ( sys_dout ),
        .i2s_sclk    (          ),
        .i2s_lrclk   (          ),
        .i2s_data    (          ),
        .sound       ( snd_l    ),
        .sound_right ( snd_r    )
    );

    // dout is registered inside the system (~2 clk after addr settles);
    // a Z-80 I/O read at 10 MHz holds the address for >= 10 clk.
    assign dout = cpu_ok ? sys_dout : 8'hFF;

    // One register stage before leaving clk's domain (sys/audio_out
    // re-synchronises into clk_audio).
    always_ff @(posedge clk) begin
        audio_l <= snd_l;
        audio_r <= snd_r;
    end

endmodule

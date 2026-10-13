//============================================================================
//  Grant�s multi computer
// 
//  Port to MiSTer.
//
//  Based on Grant�s multi computer
//  http://searle.hostei.com/grant/
//  http://searle.hostei.com/grant/Multicomp/index.html
//	 and WiSo's collector blog (MiST port)
//	 https://ws0.org/building-your-own-custom-computer-with-the-mist-fpga-board-part-1/
//	 https://ws0.org/building-your-own-custom-computer-with-the-mist-fpga-board-part-2/
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);


// User Port - extra USB 3.1A style connector on MiSTer
//
// USB	P7	Name PIN	Mister	emu wire     USB 3.0 signal
// 1	+5V	+5V					VBUS  (Red)
// 2	2	TX	SDA	AH9	USER_IO[1]	D-    (White)
// 3	1	RX	SCL	AG11	USER_IO[0]	D+    (Green)
// 4	GND	GND					GND   (Black)
// 5	8	DSR	IO10	AF15	USER_IO[5]	RX-   (Blue)
// 6	7	DTR	IO11	AG16	USER_IO[4]	RX+   (Yellow)
// 7	6	CTS	IO12	AH11	USER_IO[3]	GND_DRAIN?
// 8	5	RTS	IO13	AH12	USER_IO[2]	TX-   (Purple)
// 9	10	IO6	IO8	AF17	USER_IO[6]	TX+   (Orange)

//   Note: USB3 TX+/TX-/RX+/RX- from the perspective of the A connector;
//   the B connector has the TX/RX reversed.  The pins marked on the USB3
//   breakout board is from the perspective of the B connector signals.
   
// FT232 USB to serial cable
//          sig     usb io connector
// Red	 	5V
// Black 	GND		GND
// White	RXD		2
// Green	TXD		3
// Yellow	RTS		7
// Blue		CTS		8

// Define meaningful names for USER_IO signals
// Input pins (USER_IN)
wire user_rx      = USER_IN[0];    // Serial RX from USER_IO port
wire user_cts     = USER_IN[3];    // CTS from USER_IO port 
// USER_IN[1] unused
// USER_IN[2] unused
// USER_IN[4:6] unused

// Output pins (USER_OUT) 
// Active high enables for input pins
wire user_rx_en   = USER_OUT[0];    // Enable RX input
wire user_tx      = USER_OUT[1];    // Serial TX to USER_IO port
wire user_rts     = USER_OUT[2];    // RTS to USER_IO port
wire user_cts_en  = USER_OUT[3];    // Enable CTS input
// USER_OUT[4..5] unused
wire user_fpLED_serial = USER_OUT[6]; // front panel LED string

assign ADC_BUS  = 'Z;
//assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

// ===========================================================================
// 128 MB SDRAM (XSDS dual-AS4C32M16SB) controller instance.
//
// Uses the CoCo3 core's sdram_32r8w controller (Components/SDRAM/sdram2.sv),
// which is written for exactly this dual-AS4C32M16SB board and correctly
// handles byte-write masking (the bug that defeated the earlier
// sdram_simple / N64-derived controllers). It runs at ~112 MHz (clk_ram),
// whereas the Z-80 CPM core's SDRAM client FSM runs at 50 MHz (clk_sys),
// so an explicit clock-domain crossing is performed below.
//
// Upstream (50 MHz, clk_sys) interface from the CPM core:
//   sdram_addr_mux[26:0]  full 27-bit byte address (128 MB). bit 26 = device
//                         select, bits [25:1] = per-device word address,
//                         bit 0 = byte within the 16-bit word.
//   sdram_din_mux[7:0]    write data
//   sdram_we_mux          write strobe (held until ready)
//   sdram_rd_mux          read strobe  (held until ready)
//   sdram_dout_mux[7:0]   read data back to CPM core
//   sdram_ready_mux       1-cycle (clk_sys) completion pulse to CPM core
//
// CDC scheme: the CPM FSM asserts we/rd and holds it stable until it sees
// ready. We synchronize that level into clk_ram, edge-detect it to make a
// single sdram_cpu_req to the controller, wait for the controller's
// sdram_cpu_ready, capture+byte-select the 16-bit dout, then pulse a
// completion flag that is synchronized back into clk_sys as
// sdram_ready_mux. Because the request level is held stable across the
// whole transaction, simple 2-FF synchronizers are sufficient.
// ===========================================================================

// ---- clk_ram (112 MHz) domain signals ----
wire        sdram_busy;
wire        sdram_cpu_ack;
wire        sdram_cpu_ready;     // controller: dout valid / accepted
wire [15:0] sdram_dout16;        // controller 16-bit read data

// Request level from the 50 MHz domain, synchronized into clk_ram.
reg  [1:0]  req_sync = 2'b00;    // 2-FF synchronizer for (we|rd)
reg         req_seen = 1'b0;     // edge-detect: previous synced request
wire        cpu_req_level = sdram_we_mux | sdram_rd_mux;

reg         ram_req  = 1'b0;     // level to controller (sdram_cpu_req)
reg         ram_rnw  = 1'b1;     // 1=read, 0=write  (sdram_cpu_rnw)
reg  [7:0]  ram_byte = 8'h00;    // captured read byte
reg         ram_done = 1'b0;     // completion level toggled in clk_ram

// Latch the address/data/direction at request time so they are stable for
// the controller. These come from the 50 MHz domain but are guaranteed
// stable for the whole held-request window, so they need no synchronizer.
// The controller takes the full 27-bit byte address (128 MB): bit 0 selects
// the byte within the 16-bit word, bit 26 selects the device, and bits
// [25:1] are the per-device word address. Pass it straight through.
reg  [26:0] ram_addr = 27'd0;
reg  [7:0]  ram_din  = 8'h00;

always @(posedge clk_ram) begin
	req_sync <= {req_sync[0], cpu_req_level};
	req_seen <= req_sync[1];

	// Rising edge of the held request -> latch the transaction and raise
	// ram_req. Hold ram_req until the controller acks (it may be busy with
	// refresh when the request arrives), then drop it. The controller's
	// STATE_IDLE only accepts a request while (req & !ack), and clears ack
	// when req falls, so this level handshake is correct.
	if (req_sync[1] & ~req_seen) begin
		ram_req  <= 1'b1;
		ram_rnw  <= ~sdram_we_mux;            // read when not a write
		ram_addr <= sdram_addr_mux[26:0];     // full 27-bit byte address (128 MB)
		ram_din  <= sdram_din_mux;
	end else if (sdram_cpu_ack) begin
		ram_req  <= 1'b0;                     // controller accepted it
	end

	// Controller signalled completion: capture the selected byte and flag
	// the 50 MHz side. addr bit 0 selects high/low byte of the 16-bit word.
	if (sdram_cpu_ready) begin
		ram_byte <= ram_addr[0] ? sdram_dout16[15:8] : sdram_dout16[7:0];
		ram_done <= ~ram_done;                // toggle completion level
	end
end

// ---- back into clk_sys (50 MHz) ----
reg  [1:0]  done_sync = 2'b00;
reg         done_seen = 1'b0;
always @(posedge clk_sys) begin
	done_sync <= {done_sync[0], ram_done};
	done_seen <= done_sync[1];
end
// One clk_sys pulse when the completion level toggled.
assign sdram_ready_mux = (done_sync[1] ^ done_seen);
assign sdram_dout_mux  = ram_byte;

sdram_32r8w sdram_inst
(
	.init        (sdram_init_reset),
	.clk         (clk_ram),

	.SDRAM_DQ    (SDRAM_DQ),
	.SDRAM_A     (SDRAM_A),
	.SDRAM_DQML  (SDRAM_DQML),
	.SDRAM_DQMH  (SDRAM_DQMH),
	.SDRAM_BA    (SDRAM_BA),
	.SDRAM_nCS   (SDRAM_nCS),
	.SDRAM_nWE   (SDRAM_nWE),
	.SDRAM_nRAS  (SDRAM_nRAS),
	.SDRAM_nCAS  (SDRAM_nCAS),
	.SDRAM_CKE   (SDRAM_CKE),
	.SDRAM_CLK   (SDRAM_CLK),

	.sdram_cpu_addr  (ram_addr),
	.sdram_dout      (sdram_dout16),
	.sdram_cpu_din   (ram_din),
	.sdram_cpu_req   (ram_req),
	.sdram_cpu_rnw   (ram_rnw),
	.sdram_cpu_ack   (sdram_cpu_ack),
	.sdram_cpu_ready (sdram_cpu_ready),

	// Video read port unused.
	.sdram_vid_addr  (27'd0),
	.sdram_vid_req   (1'b0),
	.sdram_vid_ack   (),
	.sdram_vid_ready (),

	.sdram_busy      (sdram_busy)
);

assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;

//assign UART_RTS = UART_CTS;
assign UART_DTR = UART_DSR;

assign LED_POWER = 0;
assign BUTTONS = 0;

assign VIDEO_ARX = 4;
assign VIDEO_ARY = 3;
assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER = 1;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

`include "build_id.v"
parameter CONF_STR = {
	"MrZ80;;",
	"FC1,BINROM,Boot Rom Image;",                     // index 1: boot ROM image -> SDRAM @ 0x000000 (or block RAM if OD set)
	"FC2,DSK,8MB Disk Image;",                        // index 2: RAM-disk image -> SDRAM, top 8 MB first
	"OD,Boot Load Target,SDRAM,Block RAM;",          // status[13]: 0=BIN->SDRAM (default), 1=BIN->block RAM (debug, manual load only; NOT valid with "FC" auto-load)
	"-;",
	"S,IMG,SD card image;",
	"OF,Reset after Mount,No,Yes;", 
	"-;",
	"OC,Serial Port,Console Port,User IO (SNAC) Port;",
	"O9B,Baud Rate tty,115200,38400,19200,9600,4800,2400;",
	"OE,Flow Control,None,RTS/CTS;",  // New flow control option
	"-;",
	"R0,Reset;",                                     // status[0]: OSD Reset (CPU reset only; keeps loaded image)
	"V,v",`BUILD_DATE
};

// Status Bit Map:
//             Upper                             Lower              
// 0         1         2         3          4         5         6   
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// X     XXXXXXX XX     (bit 0 = Reset via "R0"; bit 14 = Flow Control only)
   
//////////////////   HPS I/O   ///////////////////
wire  [1:0] buttons;
wire [127:0] status;

wire PS2_CLK;
wire PS2_DAT;

wire forced_scandoubler;

wire [31:0] sd_lba[1];
wire        sd_rd;
wire        sd_wr;
wire        sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[1];
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;

// ARM -> FPGA download (OSD-loaded .BIN boot image / .DSK RAM-disk image).
// hps_io runs on clk_sys (the core's PLL clock), so every hps_io output
// (ioctl_*, status, buttons, the sd_* block interface, img_*) is already
// synchronous to the logic that consumes it. Running it from CLK_50M instead
// created an unsynchronised, untimed (async clock group) crossing into
// clk_sys that made the boot-source latch and the block-device buffer
// fit-dependent.
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

// Host time (BCD + toggle in bit 64) for the DS12887 RTC. Updated by the
// HPS at core load and once a minute; synchronised inside the RTC model.
wire [64:0] hps_rtc;

hps_io #(
	.CONF_STR(CONF_STR),
	.PS2DIV (2000)
	) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),

	.ps2_kbd_clk_out(PS2_CLK),
	.ps2_kbd_data_out(PS2_DAT),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.RTC(hps_rtc)
);

///////////////////////   CLOCKS   ///////////////////////////////
//
// SDRAM controller clock select.
//   - Default (this define commented out): clk_ram = outclk_1 ~112 MHz.
//   - Fallback (uncomment SDRAM_CLK_100): clk_ram = outclk_2 ~100 MHz, for
//     use if 112 MHz fails timing closure on the SDRAM paths. The CoCo3
//     sdram_32r8w controller runs correctly at either frequency (its
//     refresh interval constant is conservative at 100 MHz).
//
// EITHER WAY the PLL must be regenerated in MegaWizard so that the chosen
// output clock is actually emitted (the stock IP only emits outclk_0). The
// PLL's saved parameter set already describes outclk_1 = 112 MHz and a
// 100 MHz tap, so the multiply/divide is known-good. See REQUIREMENTS.md
// "SDRAM controller: CoCo3 sdram_32r8w port".
//
`define SDRAM_CLK_100
///////////////////////////////////////////////////////////////////
wire clk_sys, locked;
wire clk_ram;           // SDRAM controller clock (112 MHz, or 100 MHz fallback)
wire clk_ram_112;       // PLL outclk_1 ~112 MHz
wire clk_ram_100;       // PLL outclk_2 ~100 MHz (fallback)

`ifdef SDRAM_CLK_100
	// Fallback: 100 MHz from outclk_2. Regenerate the PLL with BOTH
	// outclk_1 (112) and outclk_2 (100), or set outclk_1 itself to 100 and
	// leave this define off. Here we route the dedicated 100 MHz tap.
	assign clk_ram = clk_ram_100;
	pll pll
	(
		.refclk(CLK_50M),
		.rst(0),
		.outclk_0(clk_sys),
		.outclk_1(clk_ram_112),
		.outclk_2(clk_ram_100),
		.locked(locked)
	);
`else
	// Default: 112 MHz from outclk_1. Only outclk_0 + outclk_1 are needed,
	// so the PLL can be regenerated with just two outputs.
	assign clk_ram     = clk_ram_112;
	assign clk_ram_100 = 1'b0;        // unused in this configuration
	pll pll
	(
		.refclk(CLK_50M),
		.rst(0),
		.outclk_0(clk_sys),
		.outclk_1(clk_ram_112),
		.locked(locked)
	);
`endif

/////////////////  RESET  /////////////////////////

// The framework RESET comes from another clock domain: synchronise it once
// and use only the synchronised copy below.
reg  [1:0] reset_s = 2'b11;
always @(posedge clk_sys) reset_s <= {reset_s[0], RESET};
wire       RESET_sync = reset_s[1];

reg reset_from_mount = 0;
reg [15:0] reset_counter = 0;

always @(posedge clk_sys) begin
    if(img_mounted & status[15]) begin
        reset_from_mount <= 1;
        reset_counter <= 0;
    end else if(reset_from_mount) begin
        if(reset_counter < 16'hffff)
            reset_counter <= reset_counter + 1;
        else
            reset_from_mount <= 0;
    end
end

// ---- OSD-download boot-source latch and post-download auto-reset ----
//
// bin_loaded persists the "boot from the loaded .BIN" decision: it is set
// when a .BIN download finishes and stays set until a deliberate hard reset
// (rising edge of RESET / user button buttons[1]). The OSD Reset item
// (status[0]) and the post-download auto-reset only reset the CPU, so the
// loaded image is restarted rather than discarded; its bytes are still in
// SDRAM because the SDRAM controller is not re-initialized by them.
//
// The clear is EDGE-triggered, and the download-complete set has priority,
// so a hard reset that is still held when a download completes cannot wipe
// the freshly set flag.
reg        bin_loaded = 1'b0;
reg        ioctl_download_d = 1'b0;
reg        hard_reset_d = 1'b0;
reg        dl_reset_stretch = 1'b0;
reg [15:0] dl_reset_counter = 16'd0;
wire       hard_reset_req = RESET_sync | buttons[1];   // NOT status[0]: OSD Reset restarts the loaded image
always @(posedge clk_sys) begin
    ioctl_download_d <= ioctl_download;
    hard_reset_d     <= hard_reset_req;

    if (ioctl_download_d & ~ioctl_download & dl_is_bin) begin
        // Falling edge of a .BIN download: latch boot-from-BIN.
        bin_loaded <= 1'b1;
    end else if (hard_reset_req & ~hard_reset_d) begin
        // Rising edge of a hard reset clears the boot-source latch
        // (return to built-in ROM). OSD Reset (status[0]) does not.
        bin_loaded <= 1'b0;
    end

    // On the falling edge of ANY download, hold the CPU in reset for a
    // short stretch so it restarts cleanly into the new memory image.
    if (ioctl_download_d & ~ioctl_download) begin
        dl_reset_stretch <= 1'b1;
        dl_reset_counter <= 16'd0;
    end else if (dl_reset_stretch) begin
        if (dl_reset_counter < 16'hffff)
            dl_reset_counter <= dl_reset_counter + 1'b1;
        else
            dl_reset_stretch <= 1'b0;
    end
end

// CPU is held in reset during a download and for the post-download stretch.
wire reset = RESET_sync | status[0] | buttons[1] | reset_from_mount
           | ioctl_download | dl_reset_stretch;

// The SDRAM controller must NOT be re-initialized during a download (that
// would wipe the bytes we are streaming in, and would stall the HPS forever
// waiting on ioctl_wait) or during the post-download CPU-reset stretch.
//
// In particular status[0] (OSD Reset) is deliberately NOT part of this
// term. The HPS holds status[0]=1 while it auto-loads "FC" config-string
// files at core start; if that kept the controller in its init state, the
// first download byte would never complete, ioctl_wait would stay asserted
// and the HPS would hang in its first transfer. The controller still
// initializes itself at configuration (power-up) and on a genuine hard
// RESET / user button / mount reset; an OSD Reset only resets the CPU.
wire sdram_init_reset = RESET_sync | buttons[1] | reset_from_mount;

/////////////////  SDCARD  ////////////////////////
//
// Two independent SD-style storage devices, active at the same time:
//
//  * sd_controller (inside MicrocomputerZ80CPM, I/O ports $88-$8F) speaks
//    SPI and is wired ONLY to the physical SD socket pins below. It never
//    touches the HPS image interface.
//  * hps_blockdev (inside MicrocomputerZ80CPM, I/O ports $90-$97) has the
//    same register layout but no SPI/SD protocol: it moves 512-byte blocks
//    to/from the image file mounted from the OSD ("S,IMG" entry) through
//    the hps_io block interface (sd_lba/sd_rd/sd_wr/sd_ack/sd_buff_*).
//
// (This replaces the earlier image_card SPI-card emulation and the vsd_sel
// switch that routed the single sd_controller either to the socket or to
// the image.)

wire sdclk;
wire sdmosi;
wire sdmiso = SD_MISO;
wire sdss;

assign SD_CS   = sdss;
assign SD_SCK  = sdclk;
assign SD_MOSI = sdmosi;

// hps_blockdev <-> hps_io (the block interface carries one device: VDNUM=1)
wire [31:0] bd_lba;
wire  [7:0] bd_buff_din;
wire        bd_activity;     // block device busy / recent activity
assign sd_lba[0]      = bd_lba;
assign sd_buff_din[0] = bd_buff_din;

reg sd_act;

always @(posedge clk_sys) begin
	reg old_mosi, old_miso;
	integer timeout = 0;

	old_mosi <= sdmosi;
	old_miso <= sdmiso;

	sd_act <= 0;
	if(timeout < 1000000) begin
		timeout <= timeout + 1;
		sd_act <= 1;
	end

	if((old_mosi ^ sdmosi) || (old_miso ^ sdmiso)) timeout <= 0;
end

// LED_USER: activity of EITHER storage device: the SD-socket SPI lines
// (sd_act) OR the HPS block device (bd_activity).
assign LED_USER  = sd_act | bd_activity;
// Disk LED: lit by activity of either device (driveLED is the active-low
// sd_controller activity). LED_DISK[1]=1 -> LED follows bit 0 only.
assign LED_DISK  = {1'b1, (~driveLED) | bd_activity};

// Serial port selection
wire serial_port_select = status[12];    // 0 = Console Port (UART), 1 = User IO Port

// Flow control enable
wire flow_control_enable = status[14];    // 0 = No flow control, 1 = RTS/CTS enabled

// Serial interface routing 
wire serial_rx = serial_port_select ? user_rx : UART_RXD;
wire serial_tx;
wire fpLED_serial;   // Front-panel WS2812 line, routed to USER_OUT[6]

localparam INIT_TIMEOUT = 24'd50000; // 1ms at 50MHz clock
reg [23:0] init_counter = 0;
reg init_complete = 0;

always @(posedge clk_sys) begin
    if (reset) begin
        init_complete <= 0;
        init_counter <= 0;
    end
    else if (!init_complete) begin
        if (init_counter == INIT_TIMEOUT) begin
            init_complete <= 1;
        end
        else begin
            init_counter <= init_counter + 1;
        end
    end
end

// CTS handling - active low when flow control enabled
wire serial_cts = flow_control_enable ? 
                (init_complete ? (serial_port_select ? user_cts : UART_CTS) : 1'b0) :
                1'b0;

// Serial interface output routing
wire serial_rts;  // RTS signal from CPUs

// Serial port output routing
assign UART_TXD = serial_port_select ? 1'b1 : serial_tx;
assign UART_RTS = (serial_port_select || !flow_control_enable) ? 1'b1 : serial_rts;


// USER_IO port control - single assignment for all outputs.
// USER_OUT[6] carries the front-panel WS2812 single-wire serial line

assign USER_OUT = {
    fpLED_serial,                                                      // [6] front-panel WS2812 data
    2'b0,                                                              // [5:4] unused
    serial_port_select && flow_control_enable,                         // [3] CTS input enable
    (serial_port_select && flow_control_enable) ? serial_rts : 1'b1,   // [2] RTS output
    serial_port_select ? serial_tx : 1'b1,                             // [1] TX output
    serial_port_select                                                 // [0] RX input enable
};

// Connect the read-only signals to the USER_OUT bits for monitoring
assign user_rx_en 	= USER_OUT[0];
assign user_tx 		= USER_OUT[1];
assign user_rts 	= USER_OUT[2];
assign user_cts_en 	= USER_OUT[3];
assign user_fpLED_serial = USER_OUT[6];
   
///////////////////////////////////////////////////

assign CLK_VIDEO = clk_sys;

typedef enum {baud115200='b000, baud38400='b001, baud19200='b010, baud9600='b011, baud4800='b100, baud2400='b101} baud_rate_enum;
wire [2:0] baud_rate = status[11:9];

wire hblank, vblank;
wire hs, vs;
wire [1:0] r,g,b;
wire driveLED;

// Z-80 core SDRAM client bus (overridden by the OSD download path below).
wire [26:0] z80_sdram_addr;
wire [7:0]  z80_sdram_din;
wire        z80_sdram_we;
wire        z80_sdram_rd;

// Final SDRAM client signals routed into sdram_z80_inst.
wire [26:0] sdram_addr_mux;
wire [7:0]  sdram_din_mux;
wire        sdram_we_mux;
wire        sdram_rd_mux;
wire [7:0]  sdram_dout_mux;
wire        sdram_ready_mux;


// Add baud rate selection logic
reg [15:0] baud_increment;
always @(*) begin
    case(baud_rate)
        baud115200: baud_increment = 16'd2416;  // 115200
        baud38400:  baud_increment = 16'd805;   // 38400
        baud19200:  baud_increment = 16'd403;   // 19200
        baud9600:   baud_increment = 16'd201;   // 9600
        baud4800:   baud_increment = 16'd101;   // 4800
        baud2400:   baud_increment = 16'd50;    // 2400
        default:    baud_increment = 16'd2416;  // Default to 115200
    endcase
end

//////////////  OSD FILE DOWNLOAD -> SDRAM  ///////////////
//
// .BIN boot images and .DSK RAM-disk images selected in the OSD are
// streamed in by hps_io as a byte stream (ioctl_wr pulses, ioctl_addr =
// byte offset within the file). We write each byte into SDRAM through the
// SAME CPU-port CDC adapter used by the Z-80 client: during a download the
// CPU is held in reset (see RESET section), so the adapter is otherwise
// idle and there is no contention.
//
// Target physical address:
//   .BIN (index 1): physical 0x000000 + ioctl_addr   (boots at 0x0000)
//   .DSK (index 2): physical base + ioctl_addr, where the first RAM-disk
//                   sits in the top 8 MB and each further image is placed
//                   8 MB lower. The extra-image slot number comes from the
//                   upper bits of ioctl_index (ioctl_index[15:6]); with a
//                   single "F2,DSK;" entry that field is 0, giving the
//                   top-8 MB base. Adding more "F,DSK;" config entries (or
//                   HPS multi-load) increments the slot automatically.

localparam [26:0] SDRAM_TOP      = 27'h8000000;          // 128 MB
localparam [26:0] DSK_IMAGE_SIZE = 27'h0800000;          //   8 MB

// ioctl_index from hps_io will be: 
//        ioctl_index[5:0] = index(explicit or auto)
//        ioctl_index[7:6] = extension index   

wire        dl_is_bin  = (ioctl_index[5:0] == 6'd1);
wire        dl_is_dsk  = (ioctl_index[5:0] == 6'd2);
wire [9:0]  dl_dsk_slot = ioctl_index[15:6];             // 0 = first DSK
// base = 128MB - (slot+1)*8MB  -> first DSK at 0x7800000 (top 8 MB)
wire [26:0] dl_dsk_base = SDRAM_TOP - ((dl_dsk_slot + 1'b1) * DSK_IMAGE_SIZE);
wire [26:0] dl_addr     = dl_is_dsk ? (dl_dsk_base + ioctl_addr) : ioctl_addr;

// Debug option (status[13]): SDRAM is the default (status[13]=0). When set,
// the first 64 KB of a .BIN is loaded
// into the on-chip 64 KB block RAM instead of SDRAM. Block RAM stays
// enabled, so this isolates a faulty SDRAM path from a faulty load. Any
// bytes beyond the first 64 KB (ioctl_addr >= 0x10000) do not fit in block
// RAM and are written to SDRAM at their file offset, so larger images no
// longer wrap around and overwrite the start of the block RAM. Only BIN
// images use this; DSK images are 8 MB and always go to SDRAM. A block-RAM
// write completes in one cycle, so it bypasses the SDRAM handshake below.
//
// LIMITATION: this option only works for a file loaded MANUALLY from the
// OSD. Files auto-loaded at core start by "FC" config-string entries are
// streamed by the HPS before it restores the saved status word, so
// status[13] always reads 0 at that point and the BIN goes to SDRAM
// regardless of the saved setting. Treat "FC" auto-load as SDRAM-only.
// The selection is evaluated per byte (ioctl_addr is stable while ioctl_wr
// is being synchronized, since HPS is held off by ioctl_wait / the slow SPI
// byte rate).
wire        dl_to_bram = ioctl_download & dl_is_bin & status[13]
                       & (ioctl_addr[26:16] == 11'd0);

// Edge-detect the ioctl_wr strobe. hps_io now runs on clk_sys, so this is
// no longer a clock-domain crossing; the shift register is kept only as a
// harmless pipeline (the strobe is one clk_sys cycle wide).
reg  [2:0]  iowr_sync = 3'b000;
always @(posedge clk_sys) iowr_sync <= {iowr_sync[1:0], ioctl_wr};
wire        dl_wr_edge = iowr_sync[1] & ~iowr_sync[2];

// Download write handshake (clk_sys). On each ioctl_wr, latch addr/data,
// raise dl_we and HOLD it high for the whole transaction. The CDC adapter
// sees dl_we (via sdram_we_mux) as a held request level: it 2-FF
// synchronizes it into clk_ram, edge-detects the rise, and drives the
// controller; it pulses sdram_ready_mux back when the write completes.
// dl_we must stay high until that completion (exactly like the Z-80
// client's sdram_we_reg), so a single-cycle pulse is NOT sufficient.
// ioctl_wait is asserted for the whole busy window so HPS pauses the
// byte stream until each byte is committed.
//
// SDRAM-BOOT FIX (streamed-write recovery cooldown).
// --------------------------------------------------
// The sdram_32r8w controller asserts its write completion (sdram_cpu_ready,
// from which sdram_ready_mux is derived) in STATE_RW1 -- at the moment the
// WRITE command is issued -- and only THEN walks through STATE_DLY1/DLY2
// back to STATE_IDLE. So "ready" is signalled before the write's
// auto-precharge / write-recovery (tWR/tRP) has elapsed and before the
// controller can accept another command. The Z-80 client never hit this
// because each CPU write is paced by a full instruction; but the OSD
// download streams bytes back-to-back, so dropping dl_we and immediately
// re-raising it on the next byte could launch the next ACTIVE before the
// previous write settled -- corrupting the loaded image (observed as the
// non-deterministic boot-from-SDRAM failure, while the CPU-paced memory
// test passed). Fix: after each write completes, hold dl_busy/ioctl_wait
// for a short fixed cooldown so the controller fully drains to IDLE before
// the next byte is launched. DL_WR_COOLDOWN clk_sys (50 MHz) cycles cover
// many clk_ram (~100 MHz) controller cycles, comfortably spanning the
// DLY1/DLY2 + recovery window with margin.
localparam [3:0] DL_WR_COOLDOWN = 4'd8;
reg         dl_we      = 1'b0;
reg  [26:0] dl_addr_r  = 27'd0;
reg  [7:0]  dl_din_r   = 8'h00;
reg         dl_busy    = 1'b0;
reg  [3:0]  dl_cool    = 4'd0;
always @(posedge clk_sys) begin
	if (!ioctl_download || dl_to_bram) begin
		// Idle the SDRAM download FSM during block-RAM-targeted loads.
		dl_we   <= 1'b0;
		dl_busy <= 1'b0;
		dl_cool <= 4'd0;
	end else if (!dl_busy) begin
		if (dl_wr_edge) begin
			dl_addr_r <= dl_addr;
			dl_din_r  <= ioctl_dout;
			dl_we     <= 1'b1;   // held until completion
			dl_busy   <= 1'b1;
		end
	end else if (dl_we) begin
		// in-flight: hold the request level until the controller reports
		// completion, then drop it so the adapter clears its edge-detect
		// and start the recovery cooldown (dl_busy stays high meanwhile).
		if (sdram_ready_mux) begin
			dl_we   <= 1'b0;
			dl_cool <= DL_WR_COOLDOWN;
		end
	end else begin
		// recovery cooldown: keep dl_busy/ioctl_wait asserted so HPS does
		// not present the next byte until the controller has fully drained.
		if (dl_cool != 4'd0)
			dl_cool <= dl_cool - 1'b1;
		else
			dl_busy <= 1'b0;
	end
end

// Block-RAM download write strobe: one clk_sys pulse per ioctl byte. Block
// RAM accepts a write every cycle, so no handshake/stall is needed; just
// register the byte+address aligned with the write enable.
reg         dl_bram_we_r   = 1'b0;
reg  [15:0] dl_bram_addr_r = 16'd0;
reg  [7:0]  dl_bram_data_r = 8'h00;
always @(posedge clk_sys) begin
	dl_bram_we_r <= 1'b0;
	if (dl_to_bram && dl_wr_edge) begin
		dl_bram_addr_r <= ioctl_addr[15:0];
		dl_bram_data_r <= ioctl_dout;
		dl_bram_we_r   <= 1'b1;
	end
end

// Hold HPS off until the byte is committed. SDRAM path uses the busy
// window; block-RAM path completes immediately (single-cycle write).
assign ioctl_wait = dl_busy;

// SDRAM client mux. During an OSD download the download path overrides
// the Z-80 client (CPU is in reset). Address/data pass through
// unconditionally; with we=rd=0 the controller stays idle.
assign sdram_addr_mux  = ioctl_download ? dl_addr_r : z80_sdram_addr;
assign sdram_din_mux   = ioctl_download ? dl_din_r  : z80_sdram_din;
assign sdram_we_mux    = ioctl_download ? dl_we     : z80_sdram_we;
assign sdram_rd_mux    = ioctl_download ? 1'b0      : z80_sdram_rd;


MicrocomputerZ80CPM MicrocomputerZ80CPM
(
    .N_RESET(~reset),
    .clk(clk_sys),
    .baud_increment(baud_increment),
    .R(r),
    .G(g), 
    .B(b),
    .HS(hs),
    .VS(vs),
    .hBlank(hblank),
    .vBlank(vblank),
    .cepix(CE_PIXEL),
    .ps2Clk(PS2_CLK),
    .ps2Data(PS2_DAT),
	.sdCS		(sdss),
	.sdMOSI		(sdmosi),
	.sdMISO		(sdmiso),
	.sdSCLK		(sdclk),
    .driveLED(driveLED),
    .rxd1(serial_rx),
    .txd1(serial_tx),
    .rts1(serial_rts),
    .cts1(serial_cts),
    .fpLED_serial(fpLED_serial),
    .sdram_addr (z80_sdram_addr),
    .sdram_din  (z80_sdram_din),
    .sdram_we   (z80_sdram_we),
    .sdram_rd   (z80_sdram_rd),
    .sdram_dout (sdram_dout_mux),
    .sdram_ready(sdram_ready_mux),
    .bin_loaded (bin_loaded),
    .boot_to_blockram(status[13]),
    .dl_bram_addr(dl_bram_addr_r),
    .dl_bram_data(dl_bram_data_r),
    .dl_bram_we  (dl_bram_we_r),
    .hps_rtc     (hps_rtc),

    // HPS image-backed block device ($90-$97)
    .bd_lba          (bd_lba),
    .bd_rd           (sd_rd),
    .bd_wr           (sd_wr),
    .bd_ack          (sd_ack),
    .bd_buff_addr    (sd_buff_addr),
    .bd_buff_dout    (sd_buff_dout),
    .bd_buff_din     (bd_buff_din),
    .bd_buff_wr      (sd_buff_wr),
    .bd_img_mounted  (img_mounted),
    .bd_img_readonly (img_readonly),
    .bd_img_size     (img_size),
    .bd_activity     (bd_activity)
);

video_cleaner video_cleaner
(
    .clk_vid(CLK_VIDEO),
    .ce_pix(CE_PIXEL),

    .R({4{r}}),
    .G({4{g}}),
    .B({4{b}}),
    .HSync(hs),
    .VSync(vs),
    .HBlank(hblank),
    .VBlank(vblank),

    .VGA_R(VGA_R),
    .VGA_G(VGA_G),
    .VGA_B(VGA_B),
    .VGA_VS(VGA_VS),
    .VGA_HS(VGA_HS),
    .VGA_DE(VGA_DE)
);


endmodule

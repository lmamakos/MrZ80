//
// sdram
// Copyright (c) 2015-2019 Sorgelig
// 
// Simplified version, for circular frame reading, without refresh.
//
// Modified by Stan Hodge Oct 2021.
// Refresh added back in.  8 Bit write and 32 bit reads.  Optionally 
// you may take the data from the 16 bit read port in 2 clock cycles.
//
// MISTer sdram Alliance AS4C32M16SB-7TIN (x2)
// https://www.mouser.com/datasheet/2/12/512M%20SDRAM_%20B%20die_AS4C32M16SB-7TCN-7TIN-6TIN_Rev%201-1265391.pdf
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ---------------------------------------------------------------------------
// Imported verbatim into RomWBW_MultiComp_MiSTer from the MiSTer CoCo3 core
// (MiSTer-devel/CoCo3_MiSTer rtl/sdram/sdram2.sv) to replace the local
// sdram_simple.sv / N64-derived controllers. This controller is written for
// exactly the dual-AS4C32M16SB 128 MB board we target and crucially fixes
// the byte-write masking that the earlier controllers could not get right:
// it drives {DQMH,DQML} from SDRAM_A[12:11] and loads those bits, in the
// same register write as the column address, with {~addr[0], addr[0]} on
// writes so the byte mask is always cycle-aligned with CAS.
//
// Runs at ~112 MHz (CAS_LATENCY=3). The Z-80 CPM core runs in the 50 MHz
// clk_sys domain; the MultiComp.sv adapter performs the clock-domain
// crossing between the two.
// ---------------------------------------------------------------------------

module sdram_32r8w
(
	input             init,        // reset to initialize RAM
	input             clk,         // clock ~100MHz

	inout  reg [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
	output            SDRAM_DQML,  // two byte masks
	output            SDRAM_DQMH,  // 
	output reg  [1:0] SDRAM_BA,    // two banks
	output            SDRAM_nCS,   // a single chip select
	output            SDRAM_nWE,   // write enable
	output            SDRAM_nRAS,  // row address select
	output            SDRAM_nCAS,  // columns address select
	output            SDRAM_CKE,   // clock enable
	output            SDRAM_CLK,   // clock for chip

//	CPU R/W port
	input      [26:0] sdram_cpu_addr,  // 27-bit byte address: 128 MB (dual device). 
//	output reg [31:0] sdram_ldout,     // data output to cpu
	output reg [15:0] sdram_dout,      // data output to cpu [for both ports]
	input      [7:0]  sdram_cpu_din,   // data input from cpu
	input             sdram_cpu_req,   // request
	input             sdram_cpu_rnw,   // 1 - read, 0 - write
	output reg		  sdram_cpu_ack,   // 1 = ack
	output reg        sdram_cpu_ready, // dout is valid. Ready to accept new read/write.

//	Video R port
	input      [26:0] sdram_vid_addr,  // 27-bit byte address, A0=0. 
	input             sdram_vid_req,   // request
	output reg		  sdram_vid_ack,   // 1 = ack
	output reg        sdram_vid_ready, // dout is valid. Ready to accept new read/write.

	output reg		  sdram_busy		// doing something...

);

// LOCAL MODIFICATION (RomWBW_MultiComp_MiSTer): full 128 MB support.
// The XSDS expansion board carries two AS4C32M16SB devices on a single
// shared 16-bit bus; device 1's chip-select is the inverted copy of
// device 0's, so this single SDRAM_nCS pin selects between the two
// devices (0 -> dev0, 1 -> dev1). Upstream hardcoded SDRAM_nCS = 0,
// reaching only one device. We drive it from a `chip` register loaded
// with the top byte-address bit (addr[26]) at command time. Init and
// refresh walk both devices (see STATE_STARTUP and the refresh logic).
//
// 27-bit byte address decomposition (per the AS4C32M16SB organisation,
// 4 banks x 8192 rows x 1024 cols x 16 bit = 64 MB/device):
//   addr[26]    = chip   (device 0 / 1, via SDRAM_nCS)
//   addr[25:13] = row    (13 bits)
//   addr[12:11] = bank   (2 bits)
//   addr[10:1]  = column (10 bits)
//   addr[0]     = byte within the 16-bit word (DQM select)
reg chip = 1'b0;            // current device select (drives SDRAM_nCS)
reg init_chip = 1'b0;      // which device the startup sequence is configuring
reg refresh_chip = 1'b0;   // device the NEXT auto-refresh goes to (alternates)
assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11]; // This works because A12 & A11 are unused.  This makes it convenient to assert only during CAS
assign sdram_dout = dq_reg;

// Burst length = 4
localparam BURST_LENGTH        = 2;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd3;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam startup_refresh_max = 14'b11111111111111;
//localparam cycles_per_refresh  = 14'd780;  // (64000*100)/8192-1 Calc'd as (64ms @ 100MHz)/8192 rose
//localparam cycles_per_refresh  = 14'd890;  // (64000*100)/8192-1 Calc'd as (64ms @ 114.560MHz)/8192 rose (act 895)
// LOCAL MOD: dual-device alternating refresh (see SDRAM-review-handoff.md
// section 7.1). Each AUTO_REFRESH goes to the device selected by a
// DEDICATED toggle (refresh_chip), independent of `chip`, which CPU
// accesses reload from addr[26]. (The previous version toggled `chip`
// itself, so whenever a device-0 access fell between two refreshes --
// i.e. always, while code runs from SDRAM -- every refresh went to
// device 1 and device 0 was never refreshed.)
//
// Each device needs 8192 refreshes / 64 ms = one per 7.8125 us; with the
// refreshes alternating between two devices, one must be issued at least
// every 3.906 us. 350 cycles = 3.62 us at the 96.667 MHz clk_ram in use
// (3.14 us at 111.5 MHz), leaving margin for a refresh to wait behind an
// in-flight access (< 20 cycles).
localparam REFRESH_INTERVAL    = 14'd350;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command;

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;
localparam STATE_WAIT1   = 2;
localparam STATE_RW1     = 3;
localparam STATE_IDLE    = 4;
localparam STATE_DLY1    = 5;
localparam STATE_DLY2    = 6;
localparam STATE_REFRESH = 7;   // LOCAL MOD: issue AUTO_REFRESH
localparam STATE_DLY3    = 8;   // LOCAL MOD: extra post-access recovery
localparam STATE_DLY4    = 9;   // LOCAL MOD: extra post-access recovery
localparam STATE_IDLE_7  = 17;
localparam STATE_IDLE_6  = 16;
localparam STATE_IDLE_5  = 15;
localparam STATE_IDLE_4  = 14;
localparam STATE_IDLE_3  = 13;
localparam STATE_IDLE_2  = 12;
localparam STATE_IDLE_1  = 11;

reg [15:0] dq_reg;

always @(posedge clk) begin
	reg [CAS_LATENCY+BURST_LENGTH:0] data_cpu_ready_delay;
	reg [CAS_LATENCY+BURST_LENGTH:0] data_vid_ready_delay;

	reg        saved_wr;
	reg        saved_vid;
	reg [12:0] cas_addr;
	reg [31:0] saved_data;
	reg  [4:0] state = STATE_STARTUP;

	refresh_count <= refresh_count + 1'b1;

	data_vid_ready_delay[CAS_LATENCY+BURST_LENGTH] <= 0;

	data_cpu_ready_delay[CAS_LATENCY+BURST_LENGTH] <= 0;

	data_cpu_ready_delay <= data_cpu_ready_delay>>1;
	data_vid_ready_delay <= data_vid_ready_delay>>1;

	dq_reg <= SDRAM_DQ;

//	if(data_ready_delay[1]) sdram_ldout[15:00] <= dq_reg;
//	if(data_ready_delay[0]) sdram_ldout[31:16] <= dq_reg;

	sdram_cpu_ready <= 1'b0;
	sdram_vid_ready <= 1'b0;
	
	if (data_cpu_ready_delay[2]) sdram_cpu_ready <= 1'b1; // Data valid for the first 16 bits
	if (data_cpu_ready_delay[1]) sdram_busy <= 1'b0; 

	if (data_vid_ready_delay[2]) sdram_vid_ready <= 1'b1; // Data valid for the first 16 bits
	if (data_vid_ready_delay[1]) sdram_vid_ready <= 1'b1; // Data valid for the second 16 bits

	if (data_vid_ready_delay[0]) sdram_busy <= 1'b0;


	SDRAM_DQ <= 16'bZ;

	command <= CMD_NOP;

	if (!sdram_cpu_req)
		sdram_cpu_ack <= 1'b0;

	if (!sdram_vid_req)
		sdram_vid_ack <= 1'b0;

	case (state)
		STATE_STARTUP: begin
			SDRAM_A    <= 0;
			SDRAM_BA   <= 0;
			sdram_cpu_ready <= 0; //not ready
			sdram_vid_ready <= 0; //not ready
			sdram_busy <= 1'b1;

			// LOCAL MOD: two-pass init. Drive SDRAM_nCS to the device being
			// configured (init_chip) while the sequence is still running.
			// The precharge / refresh / load-mode sequence runs once per
			// device. (On the final cycle the completion branch below sets
			// chip explicitly, so only update it here while counting down.)
			if (refresh_count != 0)
				chip <= init_chip;

			// All the commands during the startup are NOPS, except these
			if (refresh_count == startup_refresh_max-31) begin
				// ensure all rows are closed
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1;  // all banks
				SDRAM_BA    <= 2'b00;
			end
			if (refresh_count == startup_refresh_max-23) begin
				// these refreshes need to be at least tREF (66ns) apart
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-15) begin
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-7) begin
				// Now load the mode register
				command     <= CMD_LOAD_MODE;
				SDRAM_A     <= MODE;
			end

			if (!refresh_count) begin
				// LOCAL MOD: after configuring device 0, restart the whole
				// startup sequence for device 1. Only proceed to IDLE once
				// both devices have been initialised.
				if (init_chip == 1'b0) begin
					init_chip     <= 1'b1;
					refresh_count <= startup_refresh_max - sdram_startup_cycles;
					state         <= STATE_STARTUP;
				end
				else begin
					chip       <= 1'b0;   // leave dev0 selected as the default
					state      <= STATE_IDLE;
					sdram_busy <= 1'b0;
					refresh_count <= 0;
				end
			end
		end

		STATE_IDLE_7: state <= STATE_IDLE_6;
		STATE_IDLE_6: state <= STATE_IDLE_5;
		STATE_IDLE_5: state <= STATE_IDLE_4;
		STATE_IDLE_4: state <= STATE_IDLE_3;
		STATE_IDLE_3: state <= STATE_IDLE_2;
		STATE_IDLE_2: state <= STATE_IDLE_1;
		STATE_IDLE_1: begin
			// end of the post-refresh tRFC wait (IDLE_7..IDLE_1)
			state      <= STATE_IDLE;
			sdram_busy <= 1'b0;
		end

		// LOCAL MOD: issue one AUTO_REFRESH to the device selected by
		// refresh_chip, then alternate. `chip` is driven with the
		// command so SDRAM_nCS selects the right device in the same
		// cycle. All banks are idle here: every access uses auto-
		// precharge and is followed by DLY1..DLY4, and STATE_IDLE spent
		// one more cycle deciding to come here. The following
		// IDLE_7..IDLE_1 chain gives 8 cycles (>= 72 ns) before the next
		// command, covering tRFC/tRC.
		STATE_REFRESH: begin
			chip          <= refresh_chip;
			refresh_chip  <= ~refresh_chip;
			command       <= CMD_AUTO_REFRESH;
			refresh_count <= 0;
			state         <= STATE_IDLE_7;
			sdram_busy    <= 1'b1;
		end

		STATE_IDLE: begin
			saved_vid <= 1'b0;
			// LOCAL MOD: refresh has priority over a pending request.
			if(refresh_count >= REFRESH_INTERVAL)
			begin
				state <= STATE_REFRESH;
				sdram_busy <= 1'b1;
			end
			else
			begin
				if(sdram_cpu_req & !sdram_cpu_ack) // request has to go away after ready=0
				begin
//					fix byte writes [no new command until data is actually written]
//					LOCAL MOD: full-128MB decomposition. Each AS4C32M16SB
//					device is 64 MB (4 banks x 8192 rows x 1024 cols x 16 bit);
//					addr[26] picks the device (chip / SDRAM_nCS), the rest
//					decomposes per device as:
//					  addr[25:13]=row, addr[12:11]=bank, addr[10:1]=col(10 bit),
//					  addr[0]=byte (DQM select).
//					cas_addr holds the column-phase word: [12:11]=DQM,
//					[10]=auto-precharge (A10=1), [9:0]=column. SDRAM_BA=bank and
//					SDRAM_A=row are used at ACTIVE time.
					chip <= sdram_cpu_addr[26];   // select device for this access
					if (~sdram_cpu_rnw)
						{cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <=
							{~sdram_cpu_addr[0], sdram_cpu_addr[0], 1'b1, sdram_cpu_addr[10], // DQM, A10=1, col[9]
							 sdram_cpu_addr[12:11],   // bank
							 sdram_cpu_addr[25:13],   // row
							 sdram_cpu_addr[9:1]};    // col[8:0]
					else
						{cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <=
							{2'b00, 1'b1, sdram_cpu_addr[10],          // no DQM, A10=1, col[9]
							 sdram_cpu_addr[12:11],   // bank
							 sdram_cpu_addr[25:13],   // row
							 sdram_cpu_addr[9:1]};    // col[8:0]

					saved_data 	<= {sdram_cpu_din, sdram_cpu_din};
					saved_wr   	<= ~sdram_cpu_rnw;
					command    	<= CMD_ACTIVE;
					state      	<= STATE_WAIT;
					sdram_busy <= 1'b1;
				end
				else
				begin
					if (sdram_vid_req)
					begin
						// LOCAL MOD: same full-128MB decomposition as the CPU
						// read path above (read-only, no DQM).
						chip <= sdram_vid_addr[26];
						{cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <=
							{2'b00, 1'b1, sdram_vid_addr[10],
							 sdram_vid_addr[12:11],
							 sdram_vid_addr[25:13],
							 sdram_vid_addr[9:1]};
						command    	<= CMD_ACTIVE;
						saved_vid <= 1'b1;
						saved_wr <= 1'b0;
						sdram_busy <= 1'b1;
						state	<= STATE_WAIT;
					end
				end
			end
		end

		STATE_WAIT:  state <= STATE_WAIT1;
		STATE_WAIT1: begin
			if (saved_wr)
			begin
				if ((data_vid_ready_delay[5:1] == 5'b00000) && (data_cpu_ready_delay[5:1] == 5'b00000))
					state <= STATE_RW1; // added for clk > 100Mhz
			end	
			else
				state <= STATE_RW1; // added for clk > 100Mhz
		end
		
		STATE_RW1: begin
			SDRAM_A <= cas_addr;
			if (saved_vid)
				sdram_vid_ack <= 1'b1;
			else
				sdram_cpu_ack <= 1'b1;

			if(saved_wr) begin
				command  <= CMD_WRITE;
				SDRAM_DQ <= saved_data[15:0];
//				state <= STATE_IDLE;
				state   <= STATE_DLY1;
				sdram_cpu_ready <= 1'b1; // write done
				sdram_busy	<= 1'b0;
			end
			else begin
				command <= CMD_READ;
				state   <= STATE_IDLE;
				if (saved_vid)
				begin
					data_vid_ready_delay[CAS_LATENCY+BURST_LENGTH] <= 1;
					state   <= STATE_DLY1;
				end
				else
					data_cpu_ready_delay[CAS_LATENCY+BURST_LENGTH] <= 1;
					state   <= STATE_DLY1;
			end
		end
		STATE_DLY1:
			state   <= STATE_DLY2;
		// LOCAL MOD: two extra recovery cycles before IDLE. Upstream went
		// back to IDLE 3 cycles after a WRITE-with-auto-precharge, which
		// is shorter than tDAL (tWR + tRP, ~2 clk + 21 ns) -- the next
		// ACTIVE or AUTO_REFRESH could then be issued to a bank still
		// precharging. 5 cycles (>= 51 ns at 96.7 MHz) covers it. This
		// does not delay ready/data for the current access (those come
		// from data_cpu_ready_delay / STATE_RW1, not from this chain).
		STATE_DLY2:
			state   <= STATE_DLY3;
		STATE_DLY3:
			state   <= STATE_DLY4;
		STATE_DLY4:
			state   <= STATE_IDLE;
	endcase

	if (init) begin
		sdram_cpu_ack <= 1'b0;
		sdram_vid_ack <= 1'b0;
		state <= STATE_STARTUP;
		refresh_count <= startup_refresh_max - sdram_startup_cycles;
		init_chip <= 1'b0;   // LOCAL MOD: restart two-pass init from device 0
		chip      <= 1'b0;
	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule

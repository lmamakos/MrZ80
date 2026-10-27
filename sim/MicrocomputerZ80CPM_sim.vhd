-- This file is copyright by Grant Searle 2014
-- You are free to use this file in your own projects but must never charge for it nor use it without
-- acknowledgement.
-- Please ask permission from Grant Searle before republishing elsewhere.
-- If you use this file or any part of it, please add an acknowledgement to myself and
-- a link back to my main web site http://searle.hostei.com/grant/    
-- and to the "multicomp" page at http://searle.hostei.com/grant/Multicomp/index.html
--
-- Please check on the above web pages to see if there are any updates before using this file.
-- If for some reason the page is no longer available, please search for "Grant Searle"
-- on the internet to see if I have moved to another web hosting service.
--
-- Grant Searle
-- eMail address available on my main web page link above.

library ieee;
use ieee.std_logic_1164.all;
use  ieee.numeric_std.all;   -- SIM-ONLY redirect pair replaces the two
use  work.sim_compat_pkg.all; -- STD_LOGIC_ARITH/UNSIGNED lines; see sim/sim_compat_pkg.vhd

entity MicrocomputerZ80CPM is
	port(
		N_RESET	   		: in std_logic;
		clk				: in std_logic;
		baud_increment	: in std_logic_vector(15 downto 0);

		rxd1			: in std_logic;
		txd1			: out std_logic;
		rts1			: out std_logic;
		cts1			: in std_logic;  -- Added CTS input

		rxd2			: in std_logic;
		txd2			: out std_logic;
		rts2			: out std_logic;
		
		videoSync		: out std_logic;
		video			: out std_logic;

		R       		: out std_logic_vector(1 downto 0);
		G       		: out std_logic_vector(1 downto 0);
		B       		: out std_logic_vector(1 downto 0);
		HS		  		: out std_logic;
		VS 				: out std_logic;
		hBlank			: out std_logic;
		vBlank			: out std_logic;
		cepix  			: out std_logic;

		ps2Clk			: in std_logic;
		ps2Data			: in std_logic;

		sdCS			: out std_logic;
		sdMOSI			: out std_logic;
		sdMISO			: in std_logic;
		sdSCLK			: out std_logic;
		sdCD			: in std_logic := '0';
		driveLED		: out std_logic :='1';

		-- usbCS			: out std_logic;
		-- usbMOSI			: out std_logic;
		-- usbMISO			: in std_logic;
		-- usbSCLK			: out std_logic;

		-- Front-panel WS2812/SK6812 single-wire serial output. Initial
		-- integration: 8 bits latched from I/O port 0xFF drive an 8-bit
		-- transparent capture chain into the FrontPanel_Subsystem,
		-- which then shifts a single-wire colour stream out to the LED
		-- string.
		fpLED_serial	: out std_logic;

		-- Front-panel profile file download (MiSTer OSD "FC5" file).
		-- fp_dl_active is high for the whole download, fp_dl_we pulses
		-- once per byte (byte on fp_dl_data). fp_profile_clear is a
		-- one-clk pulse on a hard reset that discards the loaded file.
		fp_dl_active	: in  std_logic := '0';
		fp_dl_we		: in  std_logic := '0';
		fp_dl_data		: in  std_logic_vector(7 downto 0) := (others => '0');
		fp_profile_clear	: in  std_logic := '0';
		-- OSD front-panel profile override: 0..7 = force that profile,
		-- "1xxx" = none (Z-80 port $A7 selects). See FrontPanel_Subsystem.
		fp_osd_profile	: in  std_logic_vector(3 downto 0) := "1111";

		-- SDRAM client interface. The Z-80's logical address is
		-- translated by the on-core MMU; any physical address that
		-- does not fall inside the low 64 KB block-RAM region exits
		-- through these ports to the SDRAM controller in MrZ80.sv.
		sdram_addr		: out std_logic_vector(26 downto 0);
		sdram_din		: out std_logic_vector(7 downto 0);
		sdram_we		: out std_logic;
		sdram_rd		: out std_logic;
		sdram_dout		: in  std_logic_vector(7 downto 0);
		sdram_ready		: in  std_logic;

		-- High when a .BIN boot image has been downloaded from the MiSTer
		-- OSD / HPS. When set, the MMU reset map points logical frame 0 at
		-- SDRAM page 0 so the Z-80 boots the loaded image from 0x0000.
		-- There is no built-in boot ROM: the top level holds the CPU in
		-- reset until an image has been loaded.
		bin_loaded		: in  std_logic := '0';

		-- Debug aid: when high, the .BIN was loaded into the on-chip 64 KB
		-- block RAM rather than SDRAM. Lets us isolate whether unpredictable
		-- behaviour comes from the SDRAM path or the load itself. In this
		-- mode the MMU's frame 0 is kept pointing at the block RAM page (the
		-- bin_loaded -> SDRAM-page-0 remap is suppressed), so the Z-80 boots
		-- the image from 0x0000 out of block RAM. When low (default), a
		-- loaded .BIN lives in SDRAM and frame 0 maps to SDRAM page 0.
		boot_to_blockram	: in  std_logic := '0';

		-- Block-RAM download write port (MiSTer ioctl side). Active only
		-- while a .BIN download targeting block RAM is in progress; the
		-- Z-80 is held in reset then, so there is no contention with the
		-- CPU's own block-RAM accesses.
		dl_bram_addr	: in  std_logic_vector(15 downto 0) := (others => '0');
		dl_bram_data	: in  std_logic_vector(7 downto 0)  := (others => '0');
		dl_bram_we		: in  std_logic := '0';

		-- MiSTer hps_io real-time-clock bus (BCD time + toggle in bit 64),
		-- feeds the DS12887 RTC at I/O ports $70/$71.
		hps_rtc			: in  std_logic_vector(64 downto 0) := (others => '0');

		-- MiSTer hps_io block-storage interface, serving the image-backed
		-- block device (hps_blockdev) at I/O ports $90-$97. The SPI sd_controller
		-- at $88-$8F is NOT connected to this; it only drives the physical
		-- SD card pins (sdCS/sdMOSI/sdMISO/sdSCLK).
		bd_lba			: out std_logic_vector(31 downto 0);
		bd_rd			: out std_logic;
		bd_wr			: out std_logic;
		bd_ack			: in  std_logic := '0';
		bd_buff_addr	: in  std_logic_vector(8 downto 0) := (others => '0');
		bd_buff_dout	: in  std_logic_vector(7 downto 0) := (others => '0');
		bd_buff_din		: out std_logic_vector(7 downto 0);
		bd_buff_wr		: in  std_logic := '0';
		bd_img_mounted	: in  std_logic := '0';
		bd_img_readonly	: in  std_logic := '0';
		bd_img_size		: in  std_logic_vector(63 downto 0) := (others => '0');
		bd_activity		: out std_logic;

		-- SSP (System Support Processor) seam, D-26/D-33. ssp_top lives in
		-- MrZ80.sv (Verilog); everything Z80-side is in this core. Every
		-- input defaults to its idle value so a core without the SSP (and
		-- the GHDL benches) behaves exactly as before.
		ssp_busrq_n		: in  std_logic := '1';	-- park request to the T80
		ssp_z_reset_n	: in  std_logic := '1';	-- low = vent the guest CPU
		ssp_tramp_arm	: in  std_logic := '0';	-- G aaaa: arm reset-vector JP
		ssp_tramp_target	: in  std_logic_vector(15 downto 0) := (others => '0');
		ssp_freeze_any	: in  std_logic := '0';
		ssp_eng_own		: in  std_logic := '0';	-- engine master (mux B)
		ssp_eng_addr	: in  std_logic_vector(15 downto 0) := (others => '0');
		ssp_eng_dout	: in  std_logic_vector(7 downto 0) := (others => '0');
		ssp_eng_mreq_n	: in  std_logic := '1';
		ssp_eng_iorq_n	: in  std_logic := '1';
		ssp_eng_rd_n	: in  std_logic := '1';
		ssp_eng_wr_n	: in  std_logic := '1';
		ssp_eng_m1_n	: in  std_logic := '1';
		ssp_eng_mrd_t1	: in  std_logic := '0';
		ssp_tramp_done	: out std_logic;
		ssp_cpu_cen		: out std_logic;		-- ungated cpu_cen (engine clock)
		ssp_cpu_din		: out std_logic_vector(7 downto 0);	-- cpuDataIn (engine reads)
		ssp_cpu_wait_n	: out std_logic;
		ssp_busack_n	: out std_logic;
		ssp_halt_n		: out std_logic;
		ssp_m1_n		: out std_logic;		-- raw T80 M1
		ssp_mc			: out std_logic_vector(2 downto 0);
		ssp_ts			: out std_logic_vector(2 downto 0);
		ssp_alt			: out std_logic;
		ssp_would_boundary	: out std_logic;
		ssp_t80_reg		: out std_logic_vector(211 downto 0)
		);
end MicrocomputerZ80CPM;

architecture struct of MicrocomputerZ80CPM is

    signal reset_counter : unsigned(15 downto 0) := (others => '0');
    signal reset_n_internal : std_logic := '0';  -- Active low internal reset

	signal n_WR						: std_logic;
	signal n_RD						: std_logic;
	signal cpuAddress				: std_logic_vector(15 downto 0);
	signal cpuDataOut				: std_logic_vector(7 downto 0);
	signal cpuDataIn				: std_logic_vector(7 downto 0);
	signal cpuDbgRegisters			: std_logic_vector(211 downto 0);

	-- T80 pins before z80_bus_mux (the names above are the guest nets
	-- AFTER the mux: n_MREQ/n_IORQ/n_RD/n_WR/n_M1, cpuAddress, cpuDataOut,
	-- cpu_mrd_t1).
	signal t80_addr					: std_logic_vector(15 downto 0);
	signal t80_dout					: std_logic_vector(7 downto 0);
	signal t80_mreq_n				: std_logic;
	signal t80_iorq_n				: std_logic;
	signal t80_rd_n					: std_logic;
	signal t80_wr_n					: std_logic;
	signal t80_m1_n					: std_logic;
	signal t80_mrd_t1				: std_logic;
	signal t80_rst_n				: std_logic;
	signal t80_din					: std_logic_vector(7 downto 0);	-- cpuDataIn + trampoline
	signal t80_mc					: std_logic_vector(2 downto 0);
	signal t80_ts					: std_logic_vector(2 downto 0);
	signal t80_alt					: std_logic;
	signal t80_would_boundary		: std_logic;

	-- Define some T80 control signals that are hardwired for the moment, but
	-- future cleverness awaits.   This allows us to wire these up to the
	-- signal chain thing now.
	signal n_INT   : std_logic;
	signal n_NMI   : std_logic;
	signal n_BUSRQ : std_logic;
	signal n_M1    : std_logic;
	signal n_HALT  : std_logic;
	signal n_BUSAK : std_logic;

	-- Symbolic names for the CPU debug register vector (REG of T80s).
	-- Layout of cpuDbgRegisters (see T80.vhd), MSB first:
	--   [211] IFF2  [210] IFF1  [209:208] interrupt mode
	--   [207:192] IY   [191:176] HL'  [175:160] DE'  [159:144] BC'
	--   [143:128] IX   [127:112] HL   [111:96]  DE   [95:80]   BC
	--   [79:64]   PC   [63:48]   SP   [47:40] R  [39:32] I
	--   [31:24] F'  [23:16] A'  [15:8] F  [7:0] A
	-- (Primed = alternate register set; HL/DE/BC are always the CURRENT
	-- set, T80 swaps the slots when EXX is executed.)
	signal dbgReg_A					: std_logic_vector(7 downto 0);
	signal dbgReg_F					: std_logic_vector(7 downto 0);
	signal dbgReg_A_alt				: std_logic_vector(7 downto 0);
	signal dbgReg_F_alt				: std_logic_vector(7 downto 0);
	signal dbgReg_B					: std_logic_vector(7 downto 0);
	signal dbgReg_C					: std_logic_vector(7 downto 0);
	signal dbgReg_B_alt				: std_logic_vector(7 downto 0);
	signal dbgReg_C_alt				: std_logic_vector(7 downto 0);
	signal dbgReg_D					: std_logic_vector(7 downto 0);
	signal dbgReg_E					: std_logic_vector(7 downto 0);
	signal dbgReg_D_alt				: std_logic_vector(7 downto 0);
	signal dbgReg_E_alt				: std_logic_vector(7 downto 0);
	signal dbgReg_H					: std_logic_vector(7 downto 0);
	signal dbgReg_L					: std_logic_vector(7 downto 0);
	signal dbgReg_H_alt				: std_logic_vector(7 downto 0);
	signal dbgReg_L_alt				: std_logic_vector(7 downto 0);
	signal dbgReg_IX				: std_logic_vector(15 downto 0);
	signal dbgReg_IY				: std_logic_vector(15 downto 0);
	signal dbgReg_PC				: std_logic_vector(15 downto 0);
	signal dbgReg_SP				: std_logic_vector(15 downto 0);

	signal internalRam1DataOut		: std_logic_vector(7 downto 0);
	-- Block RAM port muxed between the CPU and the OSD download write path.
	signal bram_address				: std_logic_vector(15 downto 0);
	signal bram_data				: std_logic_vector(7 downto 0);
	signal bram_wren				: std_logic;
	signal interface1DataOut		: std_logic_vector(7 downto 0);
	signal interface2DataOut		: std_logic_vector(7 downto 0);
	signal sdCardDataOut			: std_logic_vector(7 downto 0);
	signal fpLatchDataOut			: std_logic_vector(7 downto 0);
	signal fpSubsysDataOut			: std_logic_vector(7 downto 0);
	signal timerDataOut				: std_logic_vector(7 downto 0);
	signal rtcDataOut				: std_logic_vector(7 downto 0);

	signal n_memWR					: std_logic :='1';
	signal n_memRD 					: std_logic :='1';

	signal n_ioWR					: std_logic :='1';
	signal n_ioRD 					: std_logic :='1';
	
	signal n_MREQ					: std_logic :='1';
	signal n_IORQ					: std_logic :='1';	

	signal n_int1					: std_logic :='1';	
	signal n_int2					: std_logic :='1';	
	
	signal n_internalRam1CS			: std_logic :='1';
	signal n_interface1CS			: std_logic :='1';
	signal n_interface2CS			: std_logic :='1';
	signal n_sdCardCS				: std_logic :='1';
	signal n_blockDevCS				: std_logic :='1';   -- hps_blockdev at $90-$97
	signal blockDevDataOut			: std_logic_vector(7 downto 0);
	signal n_fpLatchCS				: std_logic :='1';   -- I/O port 0xFF latch
	signal n_fpSubsysCS				: std_logic :='1';   -- FrontPanel_Subsystem 8-port window at 0xA0..0xA7
	signal n_mmuCS					: std_logic :='1';   -- MMU 16-port window at 0xB0..0xBF
	signal n_timerCS				: std_logic :='1';   -- BenchTimer 16-port window at 0xC0..0xCF
	signal n_rtcCS					: std_logic :='1';   -- DS12887 RTC index/data pair at 0x70/0x71

	-- DS12887 RTC plumbing (index/data port pair)
	signal rtc_idx					: std_logic_vector(6 downto 0) := (others => '0');
	signal rtc_stb_d1				: std_logic := '0';
	signal rtc_stb_d2				: std_logic := '0';
	signal rtc_pulse				: std_logic;
	signal rtc_req					: std_logic;
	signal rtc_wrt					: std_logic;
	signal rtc_dbi					: std_logic_vector(7 downto 0);
	signal rtc_rdata				: std_logic_vector(7 downto 0) := (others => '1');

	-- MMU plumbing. The MMU translates the Z-80's 16-bit logical address
	-- into a 28-bit physical address (physical_page_bits = 14), covering a
	-- 256 MB physical space (16384 pages x 16 KB). Physical pages 0..8191
	-- are the 128 MB of SDRAM; physical page 8192 (physical 0x8000000) is
	-- the relocated 64 KB on-chip block RAM, sitting just above the SDRAM.
	-- The same block exposes the four mapping registers, a direct-access
	-- pointer, and a direct-access data port, all through an external
	-- chip-select (mmu_io_cs) tied to the 0xB0..0xBF window.
	signal mmu_phys_addr			: std_logic_vector(27 downto 0);
	signal mmu_dataOut				: std_logic_vector(7 downto 0);
	signal mmu_io_cs				: std_logic;
	signal mmu_req_mem_in			: std_logic;
	signal mmu_req_io_in			: std_logic;
	signal mmu_req_read				: std_logic;
	signal mmu_req_write			: std_logic;
	signal mmu_req_mem_out			: std_logic;
	signal mmu_req_io_out			: std_logic;
	signal mmu_cpu_wait				: std_logic;
	signal mmu_reset				: std_logic;
	-- bin_loaded as seen by the MMU reset map. The frame-0 -> SDRAM-page-0
	-- remap is suppressed while booting a .BIN out of block RAM (debug
	-- path), so frame 0 stays pointed at the block RAM page in that mode.
	signal mmu_bin_loaded			: std_logic;

	-- Physical-memory decode. The block RAM has been relocated to physical
	-- page 8192 (physical 0x8000000, the 64 KB window at phys_addr(27:16) =
	-- "100000000000"), just above the 128 MB SDRAM. SDRAM occupies physical
	-- 0x0000000..0x7FFFFFF (phys_addr(27) = '0'). The two regions are now
	-- disjoint, so SDRAM is no longer shadowed and its full 128 MB is
	-- addressable.
	signal phys_in_blockram			: std_logic;
	signal phys_in_sdram			: std_logic;

	-- SDRAM client FSM. The CPU is stalled via wait_n until the SDRAM
	-- controller pulses `ready`. Read data comes straight from the CDC's
	-- ram_byte register (sdram_dout) into the cpuDataIn mux.
	type sdram_state_t is (S_IDLE, S_REQ, S_HOLD, S_DONE, S_WPOST, S_GAP);
	signal sdram_state				: sdram_state_t := S_IDLE;
	signal sdram_we_reg				: std_logic := '0';
	signal sdram_rd_reg				: std_logic := '0';
	signal sdram_wait_n				: std_logic := '1';
	-- Address/data latched when a request is raised (held for the CDC).
	signal sdram_addr_r				: std_logic_vector(26 downto 0) := (others => '0');
	signal sdram_din_r				: std_logic_vector(7 downto 0) := (others => '0');
	signal sdram_spec				: std_logic := '0';  -- current read is speculative
	signal sdram_wdone				: std_logic := '0';  -- posted write completed
	signal sdram_wgone				: std_logic := '0';  -- posted write's strobe gone
	signal sdram_cpu_acc			: std_logic;         -- CPU strobe cycle to SDRAM
	signal sdram_spec_go			: std_logic;         -- T1 of an SDRAM memory read
	signal sdram_match				: std_logic;         -- CPU reads sdram_addr_r
	signal cpu_mrd_t1				: std_logic;         -- T80s MRD_T1
	-- Combinational early release: high in the clk cycle in which the
	-- completion pulse (sdram_ready) arrives in S_REQ for a confirmed read
	-- (or a speculative read is confirmed in S_HOLD), one cycle before the
	-- registered sdram_wait_n goes high (REQUIREMENTS.md 4.1).
	signal sdram_release			: std_logic;
	-- Inter-request dead-time counter. After a transaction the request
	-- strobe (sdram_we/rd) must stay low long enough for the request-level
	-- 2-FF synchroniser in the 112 MHz clk_ram domain (MrZ80.sv) to
	-- register the deassertion, otherwise a tightly-spaced following request
	-- (e.g. consecutive M1 opcode fetches running out of SDRAM) is never
	-- seen as a fresh rising edge and the controller deadlocks. clk_ram is
	-- ~2.24x clk_sys, so 3 clk_sys cycles low guarantees >=2 clk_ram edges
	-- see the strobe low. See S_GAP below.
	signal sdram_gap_cnt			: unsigned(1 downto 0) := (others => '0');

	-- Combined wait_n into the t80s core: AND of MMU's wait request and
	-- the SDRAM FSM's stall.
	signal cpu_wait_n				: std_logic;

	-- Front-panel latch holding the 8 bits driven onto the capture chain.
	signal fpLatch					: std_logic_vector(7 downto 0) := (others => '0');

	-- Front-panel refresh tick: ~60 Hz pulse (one clk-wide) generated
	-- from the 50 MHz system clock to drive a frame of LED updates.
	-- 50_000_000 / 60 = 833_333 cycles per tick.
	signal fpRefreshCount			: unsigned(19 downto 0) := (others => '0');
	signal fpRefreshTick			: std_logic := '0';

	-- Capture-chain wiring between the front-panel chain segments. The
	-- segments are daisy-chained toward the FrontPanel_Subsystem, shifting
	-- MSB-first, so the signal that leaves one segment enters the next:
	--
	--   fpChainEnd     [260-291] --fpChainEndOut-->    fpChainCPUctl   [252-259]
	--   fpChainCPUctl  [252-259] --fpChainCPUctlOut--> fpChainPhysAddrBus [224-251]
	--   PhysAddrBus    [224-251] --fpChainPhysAddr-->   fpChainRegs     [32-223]
	--   fpChainRegs    [32-223]  --fpChainRegsOut-->    fpChainStaticTest [8-31]
	--   StaticTest     [8-31]    --fpChainStatic-->     fpChain         [0-7]
	--   fpChain        [0-7]     --fpChainSerial-->     FrontPanel_Subsystem
	--
	-- One signal per segment boundary (VHDL cannot wire two component
	-- ports together directly). Listed in chain order, lowest bits first.
	--
	-- NOTE: Any change to the chain segments below (add/remove/reorder,
	-- width or signal changes) MUST be reflected in SIGNAL-CAPTURES.md,
	-- the authoritative bit-allocation reference for this chain.
	signal fpChainSerial			: std_logic;  -- fpChain           -> FrontPanel_Subsystem
	signal fpChainStatic			: std_logic;  -- fpChainStaticTest -> fpChain
	signal fpChainRegsOut			: std_logic;  -- fpChainRegs     -> fpChainStaticTest
	signal fpChainPhysAddr			: std_logic;  -- PhysAddrBus     -> fpChainRegs
	signal fpChainCPUctlOut			: std_logic;  -- fpChainCPUctl   -> fpChainPhysAddrBus
	signal fpChainEndOut			: std_logic;  -- fpChainEnd      -> fpChainCPUctl
	-- Capture-chain control, fanned out to every segment:
	signal fpChainLatch				: std_logic;
	signal fpChainShiftEn			: std_logic;
	-- Chain 8-31 capture data: address bus plus the data bus seen by the
	-- CPU (bus contents during reads/idle, CPU-driven value during writes).
	-- Hoisted into a signal because VHDL does not allow when/else conditional
	-- expressions in port associations (same reason as mmu_reset above).
	signal fpStaticBusData			: std_logic_vector(23 downto 0);
	signal fpStaticDataBus			: std_logic_vector(7 downto 0);
	signal serialClkCount				: unsigned(15 downto 0);
	signal cpuClkCount				: std_logic_vector(5 downto 0) := (others => '0');
	signal sdClkCount				: std_logic_vector(5 downto 0); 	
	-- CPU clock enable. The T80 is clocked by clk (50 MHz) and advances
	-- one T-state on each clk edge at which cpu_cen = '1': one clk cycle in
	-- five (10 MHz). cpu_cen is high during the clk cycle in which
	-- cpuClkCount = 2, so the T80 updates on the same clk edges as the
	-- rising edge of the old fabric-derived cpuClock register did.
	signal cpu_cen					: std_logic := '0';
	signal serialClock				: std_logic;
	signal sdClock					: std_logic;

	
begin
process(clk)
begin
	if rising_edge(clk) then
		if N_RESET = '0' then
			reset_counter <= (others => '0');
			reset_n_internal <= '0';
		else
			if reset_counter /= unsigned'(X"FFFF") then
				reset_counter <= reset_counter + 1;
				reset_n_internal <= '0';
			else
				reset_n_internal <= '1';
			end if;
		end if;
	end if;
end process;

-- ____________________________________________________________________________________
-- CPU CHOICE GOES HERE

cpu1 : entity work.t80s
generic map(mode => 1, t2write => 1, iowait => 0)
port map(
	reset_n => t80_rst_n,
	clk_n => clk,
	cen => cpu_cen,
	wait_n => cpu_wait_n,
	int_n => n_INT,
	nmi_n => n_NMI,
	busrq_n => n_BUSRQ,
	mreq_n => t80_mreq_n,
	iorq_n => t80_iorq_n,
	rd_n => t80_rd_n,
	wr_n => t80_wr_n,
	m1_n => t80_m1_n,
	halt_n => n_HALT,
	busak_n => n_BUSAK,
	a => t80_addr,
	di => t80_din,
	do => t80_dout,
	mrd_t1 => t80_mrd_t1,
	mc => t80_mc,
	ts => t80_ts,
	alt => t80_alt,
	would_boundary => t80_would_boundary,
	-- LOCAL (D-25): FREEZE_req_n is a dead port in the T80 (R28 erratum);
	-- the park request is BUSRQ_n. FREEZE_any is the P1b step-mode hook.
	FREEZE_req_n => '1', FREEZE_any => ssp_freeze_any,
        REG => cpuDbgRegisters
);

-- SSP boundary (D-26, R25): the single Z80 bus master mux sits at the T80
-- output boundary. With the SSP idle (busrq_n high, eng_own low) it is a
-- pass-through of the T80 pins.
bus_mux : entity work.z80_bus_mux
port map (
	clk          => clk,
	rst_n        => reset_n_internal,
	t80_addr     => t80_addr,
	t80_dout     => t80_dout,
	t80_mreq_n   => t80_mreq_n,
	t80_iorq_n   => t80_iorq_n,
	t80_rd_n     => t80_rd_n,
	t80_wr_n     => t80_wr_n,
	t80_m1_n     => t80_m1_n,
	t80_mrd_t1   => t80_mrd_t1,
	t80_busack_n => n_BUSAK,
	busrq_n      => n_BUSRQ,
	eng_own      => ssp_eng_own,
	eng_addr     => ssp_eng_addr,
	eng_dout     => ssp_eng_dout,
	eng_mreq_n   => ssp_eng_mreq_n,
	eng_iorq_n   => ssp_eng_iorq_n,
	eng_rd_n     => ssp_eng_rd_n,
	eng_wr_n     => ssp_eng_wr_n,
	eng_m1_n     => ssp_eng_m1_n,
	eng_mrd_t1   => ssp_eng_mrd_t1,
	cpu_addr     => cpuAddress,
	cpu_dout     => cpuDataOut,
	cpu_mreq_n   => n_MREQ,
	cpu_iorq_n   => n_IORQ,
	cpu_rd_n     => n_RD,
	cpu_wr_n     => n_WR,
	cpu_m1_n     => n_M1,
	cpu_mrd_t1   => cpu_mrd_t1
);

-- Guest-CPU reset vent + reset-vector JP injector for "G aaaa" (D-02, R28).
-- Idle: t80_rst_n = reset_n_internal and t80_din = cpuDataIn.
tramp : entity work.ssp_tramp
port map (
	clk       => clk,
	cen       => cpu_cen,
	sys_rst_n => reset_n_internal,
	z_reset_n => ssp_z_reset_n,
	t80_rst_n => t80_rst_n,
	arm       => ssp_tramp_arm,
	target    => ssp_tramp_target,
	done      => ssp_tramp_done,
	active    => open,
	addr      => cpuAddress,
	mreq_n    => n_MREQ,
	rd_n      => n_RD,
	din_in    => cpuDataIn,
	din_out   => t80_din
);

ssp_cpu_cen        <= cpu_cen;
ssp_cpu_din        <= cpuDataIn;
ssp_cpu_wait_n     <= cpu_wait_n;
ssp_busack_n       <= n_BUSAK;
ssp_halt_n         <= n_HALT;
ssp_m1_n           <= t80_m1_n;
ssp_mc             <= t80_mc;
ssp_ts             <= t80_ts;
ssp_alt            <= t80_alt;
ssp_would_boundary <= t80_would_boundary;
ssp_t80_reg        <= cpuDbgRegisters;

-- The interrupt and bus-request inputs are tied inactive for the moment;
-- future cleverness awaits. n_int1/n_int2 (the io1/io2 interrupt outputs)
-- are currently unconnected and would be the natural source for n_INT.
n_INT   <= '1';
n_NMI   <= '1';
n_BUSRQ <= ssp_busrq_n;

-- ____________________________________________________________________________________
-- MMU GOES HERE

-- Active-high request signals for the MMU. The MMU uses synchronous,
-- active-high request semantics; the Z-80 native signals are active-low.
-- A separate `mmu_reset` signal is used because VHDL-93 (Quartus default)
-- does not allow expressions in port associations.
mmu_req_mem_in <= not n_MREQ;
mmu_req_io_in  <= not n_IORQ;
mmu_req_read   <= not n_RD;
mmu_req_write  <= not n_WR;
mmu_reset      <= not N_RESET;
mmu_bin_loaded <= bin_loaded and not boot_to_blockram;

-- physical_page_bits => 14 gives a 28-bit / 256 MB physical address space
-- (16384 pages x 16 KB). block_ram_page => 8192 places the relocated 64 KB
-- block RAM at physical 0x8000000, just above the 128 MB SDRAM (pages
-- 0..8191). bin_loaded steers the reset map of frame 0 (block RAM page by
-- default, SDRAM page 0 when a .BIN boot image is loaded).
mmu1 : entity work.MMU
generic map(physical_page_bits => 14, block_ram_page => 8192)
port map(
	clk            => clk,
	reset          => mmu_reset,
	address_in     => cpuAddress,
	address_out    => mmu_phys_addr,
	cpu_data_in    => cpuDataOut,
	cpu_data_out   => mmu_dataOut,
	cpu_wait       => mmu_cpu_wait,
	req_mem_in     => mmu_req_mem_in,
	req_mem_out    => mmu_req_mem_out,
	req_io_in      => mmu_req_io_in,
	req_io_out     => mmu_req_io_out,
	io_cs          => mmu_io_cs,
	req_read       => mmu_req_read,
	req_write      => mmu_req_write,
	bin_loaded     => mmu_bin_loaded
);

-- Physical-memory decode. The block RAM has been relocated to physical
-- page 8192 (physical 0x8000000): its 64 KB window is selected when
-- phys_addr(27:16) = "100000000000". SDRAM occupies the low 128 MB,
-- selected when phys_addr(27) = '0'. The regions are disjoint, so the
-- choice of whether logical 0x0000 sees block RAM or SDRAM is made purely
-- by the MMU's frame-0 mapping (driven by bin_loaded inside the MMU), not
-- by force-enabling/disabling the block RAM here.
phys_in_blockram <= '1' when mmu_phys_addr(27 downto 16) = "100000000000" else '0';
phys_in_sdram    <= '1' when mmu_phys_addr(27) = '0' else '0';

-- Combined wait_n into the CPU. cpu_wait_n = '0' stalls the Z-80.
-- sdram_release lets the T80 see the end of an SDRAM wait in the same clk
-- cycle as the completion pulse instead of one cycle later; the T80 only
-- samples WAIT_n on cpu_cen edges, and this is an ordinary single-cycle
-- clk path (done_sync/done_seen -> T80), so it is STA-checked.
sdram_release <= '1' when (sdram_state = S_REQ and sdram_ready = '1' and
                           (sdram_spec = '0' or sdram_match = '1')) or
                          (sdram_state = S_HOLD and sdram_match = '1') else '0';
cpu_wait_n <= (not mmu_cpu_wait) and (sdram_wait_n or sdram_release);
-- ____________________________________________________________________________________
-- RAM GOES HERE

-- Block RAM is addressed by the MMU's physical output (low 16 bits). It is
-- the backing store for the relocated block RAM page 8192..8195 (physical
-- 0x8000000..0x800FFFF). Writes are qualified by both the memory-write
-- strobe and the physical decode (phys_in_blockram).
-- During a block-RAM-targeted .BIN download the CPU is in reset, so the
-- download write port drives the block RAM's address/data/wren. Otherwise
-- the CPU's MMU-translated physical address and write strobe are used.
bram_address <= dl_bram_addr when dl_bram_we = '1' else mmu_phys_addr(15 downto 0);
bram_data    <= dl_bram_data when dl_bram_we = '1' else cpuDataOut;
-- The write strobe is the MMU's promoted memory write (req_mem_out AND
-- req_write), not n_memWR: n_memWR only covers ordinary memory cycles, so
-- writes through the MMU direct-access data port (+12, an I/O cycle that
-- the MMU turns into a physical memory cycle) were silently dropped when
-- the pointer addressed block RAM. Found by testing/sdramstress.asm, whose
-- block-RAM reference run does OTIR through the port. For ordinary memory
-- cycles this is identical to the old not(n_memWR) term.
bram_wren    <= '1' when dl_bram_we = '1' else
                (mmu_req_mem_out and mmu_req_write and not n_internalRam1CS);

ram1: entity work.InternalRam64K
port map
(
	address => bram_address,
	clock => clk,
	data => bram_data,
	wren => bram_wren,
	q => internalRam1DataOut
);

-- ____________________________________________________________________________________
-- INPUT/OUTPUT DEVICES GO HERE	


io1 : entity work.SBCTextDisplayRGB
port map (
	n_reset => N_RESET,
	clk => clk,

	-- RGB video signals
	hSync => HS,
	vSync => VS,
   	videoR0 => R(1),
   	videoR1 => R(0),
   	videoG0 => G(1),
   	videoG1 => G(0),
   	videoB0 => B(1),
   	videoB1 => B(0),
	hBlank => hBlank,
	vBlank => vBlank,
	cepix => cepix,

	-- Monochrome video signals (when using TV timings only)
	sync => videoSync,
	video => video,

	n_wr => n_interface1CS or n_ioWR,
	n_rd => n_interface1CS or n_ioRD,
	n_int => n_int1,
	regSel => cpuAddress(0),
	dataIn => cpuDataOut,
	dataOut => interface1DataOut,
	ps2Clk => ps2Clk,
	ps2Data => ps2Data
);

io2 : entity work.bufferedUART
port map(
	clk => clk,
	n_wr => n_interface2CS or n_ioWR,
	n_rd => n_interface2CS or n_ioRD,
	n_int => n_int2,
	regSel => cpuAddress(0),
	dataIn => cpuDataOut,
	dataOut => interface2DataOut,
	rxClock => serialClock,
	txClock => serialClock,
	rxd => rxd1,
	txd => txd1,
	n_cts => cts1,  -- Connect CTS signal
	n_dcd => '0',
	n_rts => rts1
);

    sd1 : entity work.sd_controller
    port map(
        sdCS => sdCS,
        sdMOSI => sdMOSI,
        sdMISO => sdMISO,
        sdSCLK => sdSCLK,
        sdCD => sdCD,
        n_wr => n_sdCardCS or n_ioWR,
        n_rd => n_sdCardCS or n_ioRD,
        n_reset => N_RESET,
        dataIn => cpuDataOut,
        dataOut => sdCardDataOut,
        regAddr => cpuAddress(2 downto 0),
        driveLED => driveLED,
        clk => clk
    );

    -- Image-backed block device (HPS file), same register layout as sd_controller.
    bd1 : entity work.hps_blockdev
    port map(
        clk => clk,
        n_reset => N_RESET,
        n_wr => n_blockDevCS or n_ioWR,
        n_rd => n_blockDevCS or n_ioRD,
        dataIn => cpuDataOut,
        dataOut => blockDevDataOut,
        regAddr => cpuAddress(2 downto 0),
        sd_lba => bd_lba,
        sd_rd => bd_rd,
        sd_wr => bd_wr,
        sd_ack => bd_ack,
        sd_buff_addr => bd_buff_addr,
        sd_buff_dout => bd_buff_dout,
        sd_buff_din => bd_buff_din,
        sd_buff_wr => bd_buff_wr,
        img_mounted => bd_img_mounted,
        img_readonly => bd_img_readonly,
        img_size => bd_img_size,
        activity => bd_activity
    );


-- ____________________________________________________________________________________
-- FRONT PANEL GOES HERE

-- Port 0xFF: 8-bit R/W latch. Software writes set the bit pattern
-- driven onto the front-panel transparent capture chain. Reads return
-- the last-written value.
process(clk)
begin
	if rising_edge(clk) then
		if N_RESET = '0' then
			fpLatch <= (others => '0');
		elsif n_fpLatchCS = '0' and n_ioWR = '0' then
			fpLatch <= cpuDataOut;
		end if;
	end if;
end process;
fpLatchDataOut <= fpLatch;

-- ~60 Hz refresh tick (one clk cycle wide) from the 50 MHz system
-- clock. 50_000_000 / 60 = 833_333. The fpRefreshCount comparison
-- against the integer literal works under the std_logic_arith
-- package family used throughout this wrapper.
-- updated: to 100Hz update rate - 50_000_000 / 100 = 500_00
process(clk)
begin
	if rising_edge(clk) then
		if N_RESET = '0' then
			fpRefreshCount <= (others => '0');
			fpRefreshTick  <= '0';
		elsif fpRefreshCount = 800000-1 then
			fpRefreshCount <= (others => '0');
			fpRefreshTick  <= '1';
		else
			fpRefreshCount <= fpRefreshCount + 1;
			fpRefreshTick  <= '0';
		end if;
	end if;
end process;

-- CPU debug registers, split out of the T80s REG vector (see the layout
-- at the cpuDbgRegisters declaration).
dbgReg_A      <= cpuDbgRegisters(7 downto 0);
dbgReg_F      <= cpuDbgRegisters(15 downto 8);
dbgReg_A_alt  <= cpuDbgRegisters(23 downto 16);
dbgReg_F_alt  <= cpuDbgRegisters(31 downto 24);
dbgReg_B      <= cpuDbgRegisters(95 downto 88);
dbgReg_C      <= cpuDbgRegisters(87 downto 80);
dbgReg_B_alt  <= cpuDbgRegisters(159 downto 152);
dbgReg_C_alt  <= cpuDbgRegisters(151 downto 144);
dbgReg_D      <= cpuDbgRegisters(111 downto 104);
dbgReg_E      <= cpuDbgRegisters(103 downto 96);
dbgReg_D_alt  <= cpuDbgRegisters(175 downto 168);
dbgReg_E_alt  <= cpuDbgRegisters(167 downto 160);
dbgReg_H      <= cpuDbgRegisters(127 downto 120);
dbgReg_L      <= cpuDbgRegisters(119 downto 112);
dbgReg_H_alt  <= cpuDbgRegisters(191 downto 184);
dbgReg_L_alt  <= cpuDbgRegisters(183 downto 176);
dbgReg_IX     <= cpuDbgRegisters(143 downto 128);
dbgReg_IY     <= cpuDbgRegisters(207 downto 192);
dbgReg_PC     <= cpuDbgRegisters(79 downto 64);
dbgReg_SP     <= cpuDbgRegisters(63 downto 48);

-- **** Signal Chain 0 - 7
-- 8-bit transparent capture chain sourced from the fpLatch register.
fpChain : entity work.Transparent_Capture_Chain
	generic map (
		TOTAL_WIDTH => 8
	)
	port map (
		clk           => clk,
		reset         => not N_RESET,
		latch         => fpChainLatch,
		shift_en      => fpChainShiftEn,

		combined_data => fpLatch,

		chain_in      => fpChainStatic,
		chain_out     => fpChainSerial    -- final output to FrontPanel_Subsystem
	);

-- **** Signal Chain 8 - 31
-- Bus data mux for chain 8-31: show what the CPU sees on the data bus
-- (reads/idle), or what it is driving during write cycles. Split into two
-- simple assignments: VHDL-93 has no parenthesised-expression production, so
-- a when/else clause cannot sit inline inside the concatenation below.
fpStaticDataBus <= t80_din when n_WR = '1' else cpuDataOut;
fpStaticBusData <= cpuAddress & fpStaticDataBus;

fpChainStaticTest : entity work.Transparent_Capture_Chain
	generic map (
		TOTAL_WIDTH => 24
	)
	port map (
		clk           => clk,
		reset         => not N_RESET,
		latch         => fpChainLatch,
		shift_en      => fpChainShiftEn,

		combined_data => fpStaticBusData,

		chain_in      => fpChainRegsOut,
		chain_out     => fpChainStatic
	);

-- **** Signal Chain 32 - 223
-- All CPU registers, in Signal Chain order: A F A' F' B C B' C' D E D' E' H L H' L'
-- IX IY PC SP (8-bit registers first, then the 16-bit ones; the first
-- listed is the MSB, i.e. the first Signal Chain bit).
fpChainRegs : entity work.Transparent_Capture_Chain
	generic map (
		TOTAL_WIDTH => 192
	)
	port map (
		clk           => clk,
		reset         => not N_RESET,
		latch         => fpChainLatch,
		shift_en      => fpChainShiftEn,

		combined_data => dbgReg_A & dbgReg_F & dbgReg_A_alt & dbgReg_F_alt &
			--       [32-39]    [40-47]    [48-55]        [56-63]
		                 dbgReg_B & dbgReg_C & dbgReg_B_alt & dbgReg_C_alt &
			--       [64-71]    [72-79]    [80-87]        [88-95]
		                 dbgReg_D & dbgReg_E & dbgReg_D_alt & dbgReg_E_alt &
			--       [96-103]   [104-111]  [112-119]      [120-127]
		                 dbgReg_H & dbgReg_L & dbgReg_H_alt & dbgReg_L_alt &
			--       [128-135]  [136-143]  [144-151]      [152-159]
		                 dbgReg_IX & dbgReg_IY & dbgReg_PC & dbgReg_SP,
			--       [160-175]  [176-191]  [192-207]      [208-223]

		chain_in      => fpChainPhysAddr,
		chain_out     => fpChainRegsOut
	);
  
-- **** Signal Chain 224 - 251
fpChainPhysAddrBus :  entity work.Transparent_Capture_Chain
	generic map (
		TOTAL_WIDTH => 28
	)
	port map (
		clk           => clk,
		reset         => not N_RESET,
		latch         => fpChainLatch,
		shift_en      => fpChainShiftEn,

		combined_data => mmu_phys_addr,

		chain_in      => fpChainCPUctlOut,
		chain_out     => fpChainPhysAddr
	);

-- **** Signal Chain 252 - 259
fpChainCPUctl :  entity work.Transparent_Capture_Chain
	generic map (
		TOTAL_WIDTH => 8
	)
	port map (
		clk           => clk,
		reset         => not N_RESET,
		latch         => fpChainLatch,
		shift_en      => fpChainShiftEn,

		combined_data => not n_WR    & not n_RD & not n_INT  & not n_NMI &
			--              [252]       [253]      [254]       [255]
		                     not n_BUSRQ & not n_M1 & not n_HALT & not n_BUSAK,
			--              [256]         [257]      [258]       [259]

		chain_in      => fpChainEndOut,
		chain_out     => fpChainCPUctlOut
	);


-- **** Signal Chain 260 - 291
fpChainEnd :  entity work.Universal_Capture_Chain
	generic map (
		TOTAL_WIDTH => 32,
                STRETCH_MASK => x"0000_0F00"
	)
	port map (
		clk           => clk,
		reset         => not N_RESET,
		latch         => fpChainLatch,
		shift_en      => fpChainShiftEn,

		combined_data => x"0000_0" &    -- 20 bits
                                 not n_WR & not n_RD & not n_MREQ & not n_IORQ &  -- 4 bits
                                 fpLatch,       -- 8 bits

		chain_in      => '0',
		chain_out     => fpChainEndOut
	);

-- Front-panel controller. The 8-port window lives at $A0..$A7 in the
-- Z-80 I/O space (n_fpSubsysCS). NUM_LEDS is set to 64 for the initial
-- bring-up so the entire string is reachable by the default identity
-- mapping while leaving headroom to test the software framebuffer
-- mode through ports +5/+6.
fpSubsys : entity work.FrontPanel_Subsystem
	generic map (
		NUM_LEDS   => 256,
		CHAIN_BITS => 384,	-- total capture-chain bits (1..1024); LED maps can address any of them
		SYS_CLK    => 50000000
	)
	port map (
		clk          => clk,
		reset        => not N_RESET,
		refresh_tick => fpRefreshTick,

		iorq_n       => n_IORQ,
		wr_n         => n_WR,
		rd_n         => n_RD,
		io_cs        => not n_fpSubsysCS,
		addr         => cpuAddress(7 downto 0),
		din          => cpuDataOut,
		dout         => fpSubsysDataOut,

		latch        => fpChainLatch,
		shift_en     => fpChainShiftEn,
		chain_in     => fpChainSerial,

		fp_dl_active  => fp_dl_active,
		fp_dl_we      => fp_dl_we,
		fp_dl_data    => fp_dl_data,
		profile_clear => fp_profile_clear,
		osd_profile   => fp_osd_profile,

		led_serial   => fpLED_serial
	);

-- ____________________________________________________________________________________
-- BENCHMARK TIMERS GO HERE

-- Ports $C0-$CF: four 32-bit snapshot channels over free-running counters
-- (channels 0,1 = 1 ms/tick at $C0-$C3/$C4-$C7; channels 2,3 = 1 us/tick
-- at $C8-$CB/$CC-$CF). OUT to any port of a channel latches it; IN reads
-- the latched bytes, little-endian. Counters are never reset after FPGA
-- configuration (monotonic across CPU resets). See BenchTimer.vhd.
timer1 : entity work.BenchTimer
	generic map (
		CLK_HZ => 50000000
	)
	port map (
		clk    => clk,
		io_cs  => not n_timerCS,
		wr_n   => n_ioWR,
		addr   => cpuAddress(3 downto 0),
		dout   => timerDataOut
	);

-- ____________________________________________________________________________________
-- DS12887 REAL-TIME CLOCK GOES HERE

-- Ports $70/$71, AT-style index/data pair:
--   $70  W: register index (bits 6..0; bit 7 ignored)   R: index (bit 7 = 0)
--   $71  R/W: DS12887 register selected by the index (0x00-0x7F)
-- The DS12887 model needs a 7-bit address (128 registers), which cannot be
-- decoded directly in the 8-bit I/O space, hence the index register.
--
-- The model's Register C read clears its flags on every clk cycle in which
-- req is asserted, and dbi is combinational. A Z-80 I/O strobe lasts several
-- clk cycles, so req/wrt are single-clk pulses generated on the 2nd clk of
-- the strobe (address and write data are stable by then), and read data is
-- captured into rtc_rdata on that same edge for the CPU to sample at the
-- end of the cycle.
rtc_pulse <= rtc_stb_d1 and not rtc_stb_d2;
rtc_req   <= rtc_pulse and cpuAddress(0);
rtc_wrt   <= rtc_req and (not n_ioWR);

process (clk)
begin
	if rising_edge(clk) then
		rtc_stb_d1 <= not n_rtcCS;
		rtc_stb_d2 <= rtc_stb_d1;
		if N_RESET = '0' then
			rtc_idx <= (others => '0');
		else
			if rtc_pulse = '1' then
				if n_ioWR = '0' then
					if cpuAddress(0) = '0' then
						rtc_idx <= cpuDataOut(6 downto 0);
					end if;
				else
					if cpuAddress(0) = '0' then
						rtc_rdata <= '0' & rtc_idx;
					else
						rtc_rdata <= rtc_dbi;
					end if;
				end if;
			end if;
		end if;
	end if;
end process;

rtcDataOut <= rtc_rdata;

-- irq (open-drain) is not routed: the Z-80 /INT input is tied inactive.
rtc1 : entity work.ds12887
	generic map (
		SYS_CLK => 50_000_000
	)
	port map (
		clk_sys   => clk,
		reset     => not N_RESET,
		req       => rtc_req,
		wrt       => rtc_wrt,
		adr       => rtc_idx,
		dbo       => cpuDataOut,
		dbi       => rtc_dbi,
		irq       => open,
		sqw       => open,
		rtc       => hps_rtc,
		pof_in    => '0'
	);

-- ____________________________________________________________________________________
-- MEMORY READ/WRITE LOGIC GOES HERE

n_ioWR 	<= n_WR or n_IORQ;
n_memWR <= n_WR or n_MREQ;
n_ioRD 	<= n_RD or n_IORQ;
n_memRD <= n_RD or n_MREQ;

-- ____________________________________________________________________________________
-- CHIP SELECTS GO HERE

-- There is no built-in boot ROM: all boot code arrives as a .BIN image
-- loaded by the HPS (OSD "Boot Rom Image"). Port $38 (the old ROM-disable
-- trigger) is now unmapped.
n_interface1CS <= '0' when cpuAddress(7 downto 1) = "1000000" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 2 Bytes $80-$81
n_interface2CS <= '0' when cpuAddress(7 downto 1) = "1000001" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 2 Bytes $82-$83
n_sdCardCS <= '0' when cpuAddress(7 downto 3) = "10001" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 8 Bytes $88-$8F
n_blockDevCS <= '0' when cpuAddress(7 downto 3) = "10010" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 8 Bytes $90-$97 (HPS image block device)
n_fpLatchCS <= '0' when cpuAddress(7 downto 0) = x"FF" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 1 Byte $FF (front-panel data latch)
n_fpSubsysCS <= '0' when cpuAddress(7 downto 3) = "10100" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 8 Bytes $A0-$A7 (front-panel subsystem)
n_mmuCS <= '0' when cpuAddress(7 downto 4) = "1011" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 16 Bytes $B0-$BF (MMU)
n_timerCS <= '0' when cpuAddress(7 downto 4) = "1100" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 16 Bytes $C0-$CF (benchmark timers)

n_rtcCS <= '0' when cpuAddress(7 downto 1) = "0111000" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 2 Bytes $70-$71 (DS12887 RTC index/data)

-- MMU.io_cs is active-high.
mmu_io_cs <= '1' when n_mmuCS = '0' else '0';

-- Block-RAM chip-select: assert whenever the MMU's physical address
-- lands in the low 64 KB region.
n_internalRam1CS <= '0' when phys_in_blockram = '1' else '1';

-- ____________________________________________________________________________________
-- BUS ISOLATION GOES HERE

    -- CPU data input mux. Order is significant:
    --   * Per-port I/O peripherals at the top (legacy entries).
    --   * MMU's own register file, only when the I/O cycle is NOT the
    --     direct-access data port at +12 (offset "1100"); on +12 the MMU
    --     promotes the cycle to a memory access and the data must come
    --     from the physical-memory path below.
    --   * Physical-memory path: block RAM for phys < 0x010000, SDRAM
    --     otherwise. Both legs are qualified by mmu_req_mem_out (a memory
    --     cycle, or the MMU's promoted direct-access port +12), because
    --     the MMU translates cpuAddress on I/O cycles too: without the
    --     qualifier an unclaimed I/O port would read back stale memory
    --     data instead of the floating-bus value.
    --   * Anything else (unclaimed I/O port): x"FF", the pulled-up bus.
    cpuDataIn <= interface1DataOut   when (n_interface1CS = '0') else
                 interface2DataOut   when (n_interface2CS = '0') else
                 sdCardDataOut       when (n_sdCardCS = '0') else
                 blockDevDataOut     when (n_blockDevCS = '0') else
                 fpLatchDataOut      when (n_fpLatchCS = '0') else
                 fpSubsysDataOut     when (n_fpSubsysCS = '0') else
                 timerDataOut        when (n_timerCS = '0') else
                 rtcDataOut          when (n_rtcCS = '0') else
                 mmu_dataOut         when (mmu_io_cs = '1' and cpuAddress(3 downto 0) /= "1100") else
                 internalRam1DataOut when (mmu_req_mem_out = '1' and phys_in_blockram = '1') else
                 sdram_dout          when (mmu_req_mem_out = '1' and phys_in_sdram = '1') else
                 x"FF";

-- ____________________________________________________________________________________
-- SDRAM CLIENT FSM
--
-- Hands SDRAM accesses to sdram_z80_inst (MrZ80.sv: clk_sys <->
-- clk_ram request/completion synchronisers + sdram_32r8w) and stalls the
-- Z-80 via WAIT_n only as long as needed (REQUIREMENTS.md item 4.1).
--
-- Reads:
--   * SPECULATIVE READ AT T1. The T80 loads A on the edge that starts T1
--     and only drives RD_n/MREQ_n low a full T-state later, at the end of
--     T1; T80s' MRD_T1 output says, during T1, that this bus cycle will be
--     a memory read (opcode fetch or memory read). When MRD_T1 = '1' and
--     A maps to SDRAM, S_IDLE starts the read immediately (sdram_spec =
--     '1'), so it completes before the T80 samples WAIT_n at the end of T2
--     and costs no wait state. When RD_n then falls, the access is checked
--     (sdram_match: memory read of exactly the latched physical address);
--     only then is the CPU released. A mismatch (not expected to happen:
--     A and the MMU mapping cannot change between T1 and T2) holds the CPU
--     and redoes the access normally, from the strobe (S_HOLD -> S_GAP ->
--     S_IDLE).
--   * Strobe-triggered read (fallback; I/O reads of the MMU direct-access
--     port +12, which the MMU promotes to a memory access only once IORQ_n
--     is low, and reads that the FSM was too busy to start in T1): started
--     on the first clk after RD_n falls; costs one wait state.
--   * The CPU is released combinationally (sdram_release) in the clk cycle
--     the completion pulse sdram_ready arrives, then by the registered
--     sdram_wait_n.
-- Writes (POSTED):
--   * On the first clk after WR_n falls, the physical address and data are
--     latched (sdram_addr_r / sdram_din_r) and the request raised WITHOUT
--     stalling the CPU (S_WPOST); the write completes in the background.
--   * Any SDRAM access the CPU starts while the write is still in flight
--     (or during the following dead time) is held off with WAIT_n until
--     the FSM is idle again, and then started normally, so SDRAM accesses
--     stay strictly ordered (a read after a write to the same address sees
--     the new data).
--
-- State graph:
--   S_IDLE : on a CPU SDRAM write strobe -> post it (S_WPOST); on a CPU
--            SDRAM read strobe -> strobe-triggered read (S_REQ); else on
--            MRD_T1 with an SDRAM address -> speculative read (S_REQ).
--   S_REQ  : read in flight, CPU held (WAIT_n only matters at the end of
--            T2). On sdram_ready: release the CPU and go to S_DONE if the
--            access is confirmed (non-speculative, or sdram_match), else
--            S_HOLD.
--   S_HOLD : speculative data ready but the CPU's strobe does not (yet)
--            match. On match release -> S_DONE; once T1 is over without a
--            match -> S_GAP (redo/abandon; the CPU stays held if it is
--            accessing SDRAM).
--   S_DONE : CPU released; wait for it to drop RD_n/WR_n -> S_GAP.
--   S_WPOST: posted write in flight. Once it completes, count the dead
--            time (as S_GAP does); go to S_IDLE when that has elapsed AND
--            the CPU's write strobe has gone.
--   S_GAP  : inter-request dead time (3 clk). The request level must be
--            low for >= 2 clk_ram edges between requests or the request-
--            level synchroniser in MrZ80.sv merges two requests into
--            one and the controller never re-triggers (the original "code
--            hangs as soon as it runs from SDRAM" bug). Never delays the
--            CPU for back-to-back reads (the next strobe is >= 1 T-state
--            away).
--
-- M1 / REFRESH HAZARD (why exits and triggers key off RD/WR, not MREQ):
--   On an M1 opcode fetch the T80 asserts MREQ in T2 (data phase, with RD)
--   AND in T3 (refresh phase, RD high, refresh address I:R on the bus). If
--   that refresh address also maps to SDRAM, mmu_req_mem_out stays high
--   from the data phase into the refresh phase with no reliable MREQ=0
--   gap, so triggers and the S_DONE exit use the read/write strobes
--   (mmu_req_read / mmu_req_write), which are low in T3. MRD_T1 is low in
--   T3/T4, so the refresh phase never starts a speculative read either.
--
-- ATTEMPTED FIX, REVERTED (kept as a warning): adding `phys_in_sdram = '0'
--   or` to the S_DONE exit made testing/backtoback.asm dramatically worse
--   (1 -> 1021 mismatches of 1024): phys_in_sdram is a combinational
--   decode of whatever the address bus shows, unrelated to whether the
--   current transaction is finished. Do not reintroduce it without
--   simulating first (see HISTORY.md, and the similarly-reverted
--   cpu_wait_n_sync attempt).
--
-- READ DATA PATH: the CPU reads sdram_dout (= ram_byte in MrZ80.sv, a
--   clk_ram register) directly. ram_byte is written on the clk_ram edge
--   that toggles ram_done, and that toggle needs the 2-FF done_sync
--   (>= 2 clk_sys edges) before sdram_ready can pulse, so ram_byte is
--   stable for more than a clk_sys period before the earliest cpu_cen edge
--   at which the T80 can capture it (MrZ80.sdc: false path from
--   ram_byte). It then only changes when the next SDRAM transaction
--   completes (a posted write also rewrites it, with a don't-care byte, but
--   no read can be released before then).
--
-- ADDRESS/DATA: sdram_addr/sdram_din come from clk_sys registers latched
--   when the request is raised and held until the next request, so they
--   are stable for the whole transaction as the CDC requires (it captures
--   them >= 2 clk_ram edges after the request), even though a posted
--   write lets the CPU move on and the MMU direct-access pointer
--   post-increments.
--
-- TIMING (sim/tb_sdram_perf.vhd, sdram_cdc_fake at 96.667 MHz; E = the
--   cpu_cen edge that ends T1): a speculative read is requested at E-80 ns
--   and sdram_ready arrives at about E+60..80, before the WAIT_n sample at
--   E+100: no wait state. A strobe-triggered read is requested at E+20 and
--   released for the E+200 sample: one wait state. A posted write costs
--   no wait state unless another SDRAM access follows within ~2 T-states.
--
-- SDRAM is phys_addr(27) = '0'; the block RAM page (bit 27 set) never
-- reaches the SDRAM controller, so the low 27 bits are the SDRAM address.
sdram_addr <= sdram_addr_r;
sdram_din  <= sdram_din_r;
sdram_we   <= sdram_we_reg;
sdram_rd   <= sdram_rd_reg;

-- A CPU bus cycle (strobe asserted) to SDRAM is in progress.
sdram_cpu_acc <= '1' when mmu_req_mem_out = '1' and phys_in_sdram = '1' and
                          (mmu_req_read = '1' or mmu_req_write = '1') else '0';
-- T1 of a memory read whose address maps to SDRAM (MREQ_n is not yet low,
-- so this uses the frame mapping; the I/O direct-access port can only be
-- recognised once IORQ_n is low and is never speculated).
sdram_spec_go <= cpu_mrd_t1 and phys_in_sdram;
-- The CPU is reading exactly the speculatively read physical address.
sdram_match <= '1' when mmu_req_mem_out = '1' and mmu_req_read = '1' and
                        phys_in_sdram = '1' and
                        mmu_phys_addr(26 downto 0) = sdram_addr_r else '0';

sdram_fsm: process(clk)
	-- S_IDLE behaviour: start whatever SDRAM access the CPU needs, else
	-- stay (or become) idle. Also used directly at the end of S_WPOST so an
	-- access following a posted write is not delayed by an extra S_IDLE
	-- cycle.
	procedure idle_or_start is
	begin
		sdram_we_reg <= '0';
		sdram_rd_reg <= '0';
		sdram_wait_n <= '1';
		sdram_spec   <= '0';
		sdram_wdone  <= '0';
		sdram_wgone  <= '0';
		sdram_state  <= S_IDLE;
		if sdram_cpu_acc = '1' then
			sdram_addr_r <= mmu_phys_addr(26 downto 0);
			sdram_din_r  <= cpuDataOut;
			if mmu_req_write = '1' then
				-- posted write: the CPU is not stalled
				sdram_we_reg <= '1';
				sdram_state  <= S_WPOST;
			else
				sdram_rd_reg <= '1';
				sdram_wait_n <= '0';
				sdram_state  <= S_REQ;
			end if;
		elsif sdram_spec_go = '1' then
			sdram_addr_r <= mmu_phys_addr(26 downto 0);
			sdram_rd_reg <= '1';
			sdram_wait_n <= '0';
			sdram_spec   <= '1';
			sdram_state  <= S_REQ;
		end if;
	end procedure;
begin
	if rising_edge(clk) then
		if N_RESET = '0' then
			sdram_state   <= S_IDLE;
			sdram_we_reg  <= '0';
			sdram_rd_reg  <= '0';
			sdram_wait_n  <= '1';
			sdram_spec    <= '0';
			sdram_wdone   <= '0';
			sdram_wgone   <= '0';
			sdram_gap_cnt <= (others => '0');
		else
			case sdram_state is
				when S_IDLE =>
					idle_or_start;

				when S_REQ =>
					if sdram_ready = '1' then
						sdram_rd_reg <= '0';
						if sdram_spec = '0' or sdram_match = '1' then
							sdram_wait_n <= '1';
							sdram_state  <= S_DONE;
						else
							sdram_state  <= S_HOLD;
						end if;
					end if;

				when S_HOLD =>
					if sdram_match = '1' then
						sdram_wait_n <= '1';
						sdram_state  <= S_DONE;
					elsif cpu_mrd_t1 = '0' then
						-- T1 is over and the CPU is not reading what was
						-- fetched: drop it and let S_IDLE start whatever the
						-- CPU is really doing (held meanwhile if it is an
						-- SDRAM access; see S_GAP).
						-- synthesis translate_off
						report "SDRAM FSM: speculative read not confirmed, redoing access"
							severity warning;
						-- synthesis translate_on
						sdram_wait_n  <= not sdram_cpu_acc;
						sdram_gap_cnt <= "10";
						sdram_state   <= S_GAP;
					end if;

				when S_DONE =>
					sdram_wait_n <= '1';
					if mmu_req_read = '0' and mmu_req_write = '0' then
						sdram_gap_cnt <= "10";        -- 3 clk_sys cycles of dead time
						sdram_state   <= S_GAP;
					end if;

				when S_WPOST =>
					-- The request level drops when the write completes; the
					-- inter-request dead time is counted from there (in this
					-- state, not in S_GAP), so that an opcode fetch right
					-- after the write can still be read speculatively.
					if sdram_wdone = '0' then
						if sdram_ready = '1' then
							sdram_we_reg  <= '0';
							sdram_wdone   <= '1';
							-- 2 clk_sys cycles of dead time (>= 3 clk_ram edges
							-- at 96.7 MHz; the synchroniser needs 2), counted
							-- from the request level dropping.
							sdram_gap_cnt <= "01";
						end if;
					elsif sdram_gap_cnt /= 0 then
						sdram_gap_cnt <= sdram_gap_cnt - 1;
					end if;
					if mmu_req_write = '0' then
						sdram_wgone <= '1';
					end if;
					-- Hold off any NEW SDRAM access (one that starts after
					-- the posted write's own strobe has gone).
					if sdram_wgone = '1' and sdram_cpu_acc = '1' then
						sdram_wait_n <= '0';
					else
						sdram_wait_n <= '1';
					end if;
					-- Done once the write has completed, the dead time has
					-- elapsed and the CPU's write strobe has gone (else
					-- S_IDLE would post the same write again).
					if sdram_wdone = '1' and sdram_gap_cnt = 0 and
					   (sdram_wgone = '1' or mmu_req_write = '0') then
						idle_or_start;
					end if;

				when S_GAP =>
					-- Request strobes held low for the dead time. Any CPU
					-- SDRAM bus cycle seen here is a new one (the previous
					-- one's strobe has gone, or it is the access being
					-- redone after S_HOLD): hold it until S_IDLE starts it.
					sdram_we_reg <= '0';
					sdram_rd_reg <= '0';
					sdram_wait_n <= not sdram_cpu_acc;
					if sdram_gap_cnt = 0 then
						sdram_state <= S_IDLE;
					else
						sdram_gap_cnt <= sdram_gap_cnt - 1;
					end if;
			end case;
		end if;
	end if;
end process;

-- ____________________________________________________________________________________
-- SYSTEM CLOCKS GO HERE


-- SUB-CIRCUIT CLOCK SIGNALS 
serialClock <= serialClkCount(15);
--sdClock <= clk;

process (clk)
begin
	if rising_edge(clk) then

		if cpuClkCount < 4 then -- 4 = 10MHz, 3 = 12.5MHz, 2=16.6MHz, 1=25MHz
			cpuClkCount <= cpuClkCount + 1;
		else
			cpuClkCount <= (others=>'0');
		end if;
		
		-- One-clk-in-five CPU clock enable, high while cpuClkCount = 2 (set
		-- on the edge at which the old count is 1). If the divider above is
		-- changed, cpu_cen must still be high for exactly one clk per
		-- count cycle.
		if cpuClkCount = 1 then
			cpu_cen <= '1';
		else
			cpu_cen <= '0';
		end if;

		if sdClkCount < 16 then -- 5MHz
			sdClkCount <= sdClkCount + 1;
		else
			sdClkCount <= (others=>'0');
		end if;

		sdClock <= sdClkCount (3); -- divide by 8 = 6.25 Mhz
		--usbCS <= sdClkCount (4);
		--usbMOSI <= sdClkCount (3);
		--usbSCLK <= sdClkCount (2);

		-- Serial clock DDS
		-- 50MHz master input clock:
		-- Baud Increment
		-- 115200 2416
		-- 38400 805
		-- 19200 403
		-- 9600 201
		-- 4800 101
		-- 2400 50
		serialClkCount <= serialClkCount + unsigned(baud_increment);
	end if;
end process;

end;

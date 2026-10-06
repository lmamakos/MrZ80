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
use  ieee.numeric_std.all;
use  work.sim_compat_pkg.all;

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

		-- SDRAM client interface. The Z-80's logical address is
		-- translated by the on-core MMU; any physical address that
		-- does not fall inside the low 64 KB block-RAM region exits
		-- through these ports to the SDRAM controller in MultiComp.sv.
		sdram_addr		: out std_logic_vector(26 downto 0);
		sdram_din		: out std_logic_vector(7 downto 0);
		sdram_we		: out std_logic;
		sdram_rd		: out std_logic;
		sdram_dout		: in  std_logic_vector(7 downto 0);
		sdram_ready		: in  std_logic;

		-- High when a .BIN boot image has been downloaded from the MiSTer
		-- OSD. When set, the built-in 8 KB boot ROM overlay is disabled so
		-- the Z-80 boots the loaded image from 0x0000 instead of the ROM.
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
		dl_bram_we		: in  std_logic := '0'
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

	signal basRomData				: std_logic_vector(7 downto 0);
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

	signal n_memWR					: std_logic :='1';
	signal n_memRD 					: std_logic :='1';

	signal n_ioWR					: std_logic :='1';
	signal n_ioRD 					: std_logic :='1';
	
	signal n_MREQ					: std_logic :='1';
	signal n_IORQ					: std_logic :='1';	

	signal n_int1					: std_logic :='1';	
	signal n_int2					: std_logic :='1';	
	
	signal n_internalRam1CS			: std_logic :='1';
	signal n_basRomCS				: std_logic :='1';
	signal n_interface1CS			: std_logic :='1';
	signal n_interface2CS			: std_logic :='1';
	signal n_sdCardCS				: std_logic :='1';
	signal n_fpLatchCS				: std_logic :='1';   -- I/O port 0xFF latch
	signal n_fpSubsysCS				: std_logic :='1';   -- FrontPanel_Subsystem 8-port window at 0xA0..0xA7
	signal n_mmuCS					: std_logic :='1';   -- MMU 16-port window at 0xB0..0xBF
	signal n_timerCS				: std_logic :='1';   -- BenchTimer 16-port window at 0xC0..0xCF

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
	-- 2-FF synchroniser in the 112 MHz clk_ram domain (MultiComp.sv) to
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

	-- Capture-chain wires from the Transparent_Capture_Chain back to
	-- the FrontPanel_Subsystem.
	signal fpChainSerial			: std_logic;
	signal fpChainLatch				: std_logic;
	signal fpChainShiftEn			: std_logic;
        signal fpChainEndOut : std_logic;
        signal fpChainStatic : std_logic;

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

	--CPM
	signal n_RomActive 				: std_logic := '0';

	
begin
	--CPM
	-- Disable ROM on any OUT to port $38; re-enable on reset. Sampled in
	-- the clk domain during the I/O write strobe (the address is stable
	-- throughout it), like fpLatch, rather than clocked by the n_ioWR
	-- strobe itself as in the original MultiComp. The ROM is disabled a
	-- few clk cycles earlier than before (start rather than end of the
	-- write strobe); no memory read can occur in between.
	process (clk) begin
		if rising_edge(clk) then
			if N_RESET = '0' then
				n_RomActive <= '0';
			elsif n_ioWR = '0' and cpuAddress(7 downto 0) = "00111000" then -- $38
				n_RomActive <= '1';
			end if;
		end if;
	end process;

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
	reset_n => reset_n_internal,
	clk_n => clk,
	cen => cpu_cen,
	wait_n => cpu_wait_n,
	int_n => '1',
	nmi_n => '1',
	busrq_n => '1',
	mreq_n => n_MREQ,
	iorq_n => n_IORQ,
	rd_n => n_RD,
	wr_n => n_WR,
	a => cpuAddress,
	di => cpuDataIn,
	do => cpuDataOut,
	mrd_t1 => cpu_mrd_t1,
        REG => cpuDbgRegisters
);

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
-- ROM GOES HERE	

rom1 : entity work.Z80_CPM_BASIC_ROM
port map(
	address => cpuAddress(12 downto 0),
	clock => clk,
	q => basRomData
);

-- ____________________________________________________________________________________
-- RAM GOES HERE

-- Block RAM is addressed by the MMU's physical output (low 16 bits). It is
-- the backing store for the relocated block RAM page 8192..8195 (physical
-- 0x8000000..0x800FFFF). Writes are qualified by both the memory-write
-- strobe and the physical decode (phys_in_blockram); the ROM overlay at
-- logical 0x0000-0x1FFF still wins on the cpuDataIn mux while
-- n_RomActive = '0'.
-- During a block-RAM-targeted .BIN download the CPU is in reset, so the
-- download write port drives the block RAM's address/data/wren. Otherwise
-- the CPU's MMU-translated physical address and write strobe are used.
bram_address <= dl_bram_addr when dl_bram_we = '1' else mmu_phys_addr(15 downto 0);
bram_data    <= dl_bram_data when dl_bram_we = '1' else cpuDataOut;
bram_wren    <= '1' when dl_bram_we = '1' else not(n_memWR or n_internalRam1CS);

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
        n_wr => n_sdCardCS or n_ioWR,
        n_rd => n_sdCardCS or n_ioRD,
        n_reset => N_RESET,
        dataIn => cpuDataOut,
        dataOut => sdCardDataOut,
        regAddr => cpuAddress(2 downto 0),
        driveLED => driveLED,
        clk => clk
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

-- **** LED 0 - 7
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
		chain_out     => fpChainSerial
	);

-- **** LED 8 - 31
fpChainStaticTest : entity work.Transparent_Capture_Chain
	generic map (
		TOTAL_WIDTH => 24
	)
	port map (
		clk           => clk,
		reset         => not N_RESET,
		latch         => fpChainLatch,
		shift_en      => fpChainShiftEn,
		combined_data => cpuAddress & cpuDataIn,
		chain_in      => fpChainEndOut,
		chain_out     => fpChainStatic
	);

-- **** LED 32 - 63
fpChainEnd :  entity work.Transparent_Capture_Chain
	generic map (
		TOTAL_WIDTH => 32
	)
	port map (
		clk           => clk,
		reset         => not N_RESET,
		latch         => fpChainLatch,
		shift_en      => fpChainShiftEn,
		combined_data => x"000000" & fpLatch,
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
		NUM_LEDS => 256,
		SYS_CLK  => 50000000
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
-- MEMORY READ/WRITE LOGIC GOES HERE

n_ioWR 	<= n_WR or n_IORQ;
n_memWR <= n_WR or n_MREQ;
n_ioRD 	<= n_RD or n_IORQ;
n_memRD <= n_RD or n_MREQ;

-- ____________________________________________________________________________________
-- CHIP SELECTS GO HERE

-- Boot ROM still overlays logical 0x0000-0x1FFF before MMU translation.
-- The ROM data wins on the cpuDataIn mux while n_RomActive = '0'; this is
-- how the bootloader runs before it has had a chance to set up the MMU
-- or copy code into RAM.
n_basRomCS <= '0' when cpuAddress(15 downto 13) = "000" and n_memRD='0' and n_RomActive = '0' and bin_loaded = '0' else '1'; --8K at bottom of memory (disabled when a BIN boot image is loaded)
n_interface1CS <= '0' when cpuAddress(7 downto 1) = "1000000" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 2 Bytes $80-$81
n_interface2CS <= '0' when cpuAddress(7 downto 1) = "1000001" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 2 Bytes $82-$83
n_sdCardCS <= '0' when cpuAddress(7 downto 3) = "10001" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 8 Bytes $88-$8F
n_fpLatchCS <= '0' when cpuAddress(7 downto 0) = x"FF" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 1 Byte $FF (front-panel data latch)
n_fpSubsysCS <= '0' when cpuAddress(7 downto 3) = "10100" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 8 Bytes $A0-$A7 (front-panel subsystem)
n_mmuCS <= '0' when cpuAddress(7 downto 4) = "1011" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 16 Bytes $B0-$BF (MMU)
n_timerCS <= '0' when cpuAddress(7 downto 4) = "1100" and (n_ioWR='0' or n_ioRD = '0') else '1'; -- 16 Bytes $C0-$CF (benchmark timers)

-- MMU.io_cs is active-high.
mmu_io_cs <= '1' when n_mmuCS = '0' else '0';

-- Block-RAM chip-select: assert whenever the MMU's physical address
-- lands in the low 64 KB region. The ROM overlay still wins on the
-- cpuDataIn mux for logical 0x0000-0x1FFF, but the underlying RAM
-- is kept selected so writes into the ROM region silently update
-- the backing RAM (matching legacy bootloader behaviour).
n_internalRam1CS <= '0' when phys_in_blockram = '1' else '1';

-- ____________________________________________________________________________________
-- BUS ISOLATION GOES HERE

    -- CPU data input mux. Order is significant:
    --   * Per-port I/O peripherals at the top (legacy entries).
    --   * MMU's own register file, only when the I/O cycle is NOT the
    --     direct-access data port at +12 (offset "1100"); on +12 the MMU
    --     promotes the cycle to a memory access and the data must come
    --     from the physical-memory path below.
    --   * ROM overlay at logical 0x0000-0x1FFF wins over RAM.
    --   * Physical-memory path: block RAM for phys < 0x010000, SDRAM
    --     otherwise.
    cpuDataIn <= interface1DataOut   when (n_interface1CS = '0') else
                 interface2DataOut   when (n_interface2CS = '0') else
                 sdCardDataOut       when (n_sdCardCS = '0') else
                 fpLatchDataOut      when (n_fpLatchCS = '0') else
                 fpSubsysDataOut     when (n_fpSubsysCS = '0') else
                 timerDataOut        when (n_timerCS = '0') else
                 mmu_dataOut         when (mmu_io_cs = '1' and cpuAddress(3 downto 0) /= "1100") else
                 basRomData          when (n_basRomCS = '0') else
                 internalRam1DataOut when (phys_in_blockram = '1') else
                 sdram_dout          when (phys_in_sdram = '1') else
                 x"FF";

-- ____________________________________________________________________________________
-- SDRAM CLIENT FSM
--
-- Hands SDRAM accesses to sdram_z80_inst (MultiComp.sv: clk_sys <->
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
--            level synchroniser in MultiComp.sv merges two requests into
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
-- READ DATA PATH: the CPU reads sdram_dout (= ram_byte in MultiComp.sv, a
--   clk_ram register) directly. ram_byte is written on the clk_ram edge
--   that toggles ram_done, and that toggle needs the 2-FF done_sync
--   (>= 2 clk_sys edges) before sdram_ready can pulse, so ram_byte is
--   stable for more than a clk_sys period before the earliest cpu_cen edge
--   at which the T80 can capture it (MultiComp.sdc: false path from
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

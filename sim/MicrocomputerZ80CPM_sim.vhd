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
	-- controller pulses `ready`. Reads latch dout into sdramReadData
	-- for the cpuDataIn mux.
	type sdram_state_t is (S_IDLE, S_REQ, S_DONE, S_GAP);
	signal sdram_state				: sdram_state_t := S_IDLE;
	signal sdram_we_reg				: std_logic := '0';
	signal sdram_rd_reg				: std_logic := '0';
	signal sdramReadData			: std_logic_vector(7 downto 0) := (others => '0');
	signal sdram_wait_n				: std_logic := '1';
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
	signal cpuClkCount				: std_logic_vector(5 downto 0); 
	signal sdClkCount				: std_logic_vector(5 downto 0); 	
	signal cpuClock					: std_logic;
	signal serialClock				: std_logic;
	signal sdClock					: std_logic;

	--CPM
	signal n_RomActive 				: std_logic := '0';

	
begin
	--CPM
	-- Disable ROM if out 38. Re-enable when (asynchronous) reset pressed
	process (n_ioWR, N_RESET) begin
		if (N_RESET = '0') then
			n_RomActive <= '0';
		elsif (rising_edge(n_ioWR)) then
			if cpuAddress(7 downto 0) = "00111000" then -- $38
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
	clk_n => cpuClock,
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
cpu_wait_n <= (not mmu_cpu_wait) and sdram_wait_n;
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
                 mmu_dataOut         when (mmu_io_cs = '1' and cpuAddress(3 downto 0) /= "1100") else
                 basRomData          when (n_basRomCS = '0') else
                 internalRam1DataOut when (phys_in_blockram = '1') else
                 sdramReadData       when (phys_in_sdram = '1') else
                 x"FF";

-- ____________________________________________________________________________________
-- SDRAM CLIENT FSM
--
-- When the MMU promotes the current cycle into a physical memory access
-- (req_mem_out = '1') and the physical address lives in SDRAM, we hand
-- the access to sdram_z80_inst (in MultiComp.sv) and stall the Z-80 via
-- wait_n until the controller pulses `ready`.
--
-- State graph:
--   S_IDLE: idle, sdram_wait_n='1'. On an SDRAM memory access, latch
--           the address/data/strobes and move to S_REQ.
--   S_REQ : drive sdram_we/rd asserted, stall the CPU. When the
--           controller pulses sdram_ready, latch sdramReadData (for
--           reads) and move to S_DONE.
--   S_DONE: deassert sdram_we/rd, release wait_n, hold one cycle so the
--           Z-80 captures the read data on the next clock edge. Once the
--           CPU drops its READ/WRITE strobe, move to S_GAP.
--   S_GAP : inter-request dead time. Hold the request strobes low for a
--           few clk_sys cycles so the 112 MHz request-level synchroniser
--           in MultiComp.sv registers the deassertion and will see the
--           NEXT request as a fresh rising edge. Without this, tightly
--           spaced SDRAM accesses (consecutive M1 opcode fetches running
--           out of SDRAM) merge into one held request level, the
--           controller never re-triggers, wait_n sticks low and the CPU
--           hangs. This is why a routine runs fine from block RAM but
--           hangs the instant it executes from SDRAM, while data-only
--           tests (LDIR) pass (their non-SDRAM cycles supply the gap).
--
-- M1 / REFRESH HAZARD (why the exit keys off RD/WR, not MREQ):
--   On a Z-80 M1 opcode fetch the T80 core asserts MREQ in BOTH T2 (the
--   data phase, with RD also asserted) AND T3 (the refresh phase, with RD
--   deasserted and the refresh address I:R on the bus). When frame 0 maps
--   to SDRAM (the boot-from-.BIN case) that refresh address ALSO decodes as
--   SDRAM, so mmu_req_mem_out stays high continuously from the data phase
--   into the refresh phase -- there is no clean MREQ=0 gap between them at
--   the 50 MHz FSM sampling rate (the CPU runs on the ~10 MHz cpuClock, so
--   whether the FSM catches the momentary MREQ deassert is alignment-
--   dependent -> non-deterministic). Keying the S_DONE exit and re-arm off
--   the actual read/write strobe (mmu_req_read / mmu_req_write), which is
--   deasserted in T3 (RD_n=1, WR_n=1), gives a deterministic boundary that
--   the T3 refresh MREQ cannot blur. This is the path instruction fetch
--   from SDRAM depends on, so it was invisible to data-only memory tests.
-- SDRAM access only occurs when phys_in_sdram = '1', i.e. mmu_phys_addr(27)
-- = '0', so the low 27 bits fully cover the SDRAM access. The block RAM
-- page (bit 27 set) never reaches the SDRAM controller.
sdram_addr <= mmu_phys_addr(26 downto 0);  -- 27-bit address spans all 128 MB of SDRAM
sdram_din  <= cpuDataOut;
sdram_we   <= sdram_we_reg;
sdram_rd   <= sdram_rd_reg;

sdram_fsm: process(clk)
begin
	if rising_edge(clk) then
		if N_RESET = '0' then
			sdram_state   <= S_IDLE;
			sdram_we_reg  <= '0';
			sdram_rd_reg  <= '0';
			sdram_wait_n  <= '1';
			sdramReadData <= (others => '0');
			sdram_gap_cnt <= (others => '0');
		else
			case sdram_state is
				when S_IDLE =>
					sdram_we_reg <= '0';
					sdram_rd_reg <= '0';
					sdram_wait_n <= '1';
					-- Kick off a request when the MMU has promoted the cycle
					-- to a physical memory access targeting SDRAM. The trigger
					-- keys off the actual READ/WRITE strobe AND req_mem_out so
					-- it is immune to the M1 T3 refresh MREQ pulse (which
					-- asserts req_mem_out with both RD_n and WR_n high, i.e.
					-- mmu_req_read = mmu_req_write = '0'); a refresh therefore
					-- never starts a spurious SDRAM cycle even when frame 0
					-- maps to SDRAM. See "M1 / REFRESH HAZARD" above.
					if mmu_req_mem_out = '1' and phys_in_sdram = '1' then
						if mmu_req_write = '1' then
							sdram_we_reg <= '1';
							sdram_wait_n <= '0';
							sdram_state  <= S_REQ;
						elsif mmu_req_read = '1' then
							sdram_rd_reg <= '1';
							sdram_wait_n <= '0';
							sdram_state  <= S_REQ;
						end if;
					end if;

				when S_REQ =>
					-- Hold strobes (and the CPU wait) until the controller
					-- acknowledges. When it does, latch the read data but
					-- KEEP sdram_wait_n low for one more cycle: sdramReadData
					-- is a registered assignment and does not present the new
					-- value until after this clock edge. Releasing wait here
					-- would let the Z-80 sample cpuDataIn -> sdramReadData on
					-- the same edge, capturing the PREVIOUS transaction's
					-- byte (observed as a stale "read-by-one" error). The
					-- wait is released in S_DONE instead.
					if sdram_ready = '1' then
						sdramReadData <= sdram_dout;
						sdram_we_reg  <= '0';
						sdram_rd_reg  <= '0';
						sdram_state   <= S_DONE;
					end if;

				when S_DONE =>
					-- sdramReadData is now stable. Release the CPU wait so
					-- the Z-80 captures the correct read byte, then wait for
					-- it to drop its READ/WRITE strobe before accepting a new
					-- request (this keeps the FSM from re-triggering on the
					-- same bus cycle). The strobe-based exit (rather than
					-- MREQ) is immune to the M1 T3 refresh MREQ pulse, which
					-- otherwise keeps mmu_req_mem_out high across the data->
					-- refresh boundary and makes the exit alignment-dependent
					-- (see "M1 / REFRESH HAZARD" above).
					--
					-- ATTEMPTED FIX, REVERTED: a prior version of this line
					-- added `phys_in_sdram = '0' or` to this condition,
					-- hypothesising that INI/INIR's hard-wired write-to-(HL)
					-- immediately after the port read (with no possible gap)
					-- was stalling this exit on an SDRAM-irrelevant write.
					-- On hardware this made things dramatically WORSE (1
					-- mismatch -> 1021 out of 1024 in testing/backtoback.asm
					-- Phase A2/A3), not better. Root cause of the failed
					-- fix: phys_in_sdram is a continuously-computed
					-- COMBINATIONAL signal off whatever mmu_phys_addr (i.e.
					-- whatever the CPU's raw address bus) shows at any given
					-- instant, with no qualification that a request is even
					-- active; since the CPU spends the vast majority of its
					-- time addressing block RAM (frame 0), phys_in_sdram
					-- reads '0' almost continuously for reasons unrelated to
					-- whether the CURRENT SDRAM transaction has genuinely
					-- finished, causing this exit to fire far too eagerly
					-- and unpredictably. Do NOT reintroduce this without
					-- simulating first (see HISTORY.md's note on the
					-- similarly-reverted cpu_wait_n_sync attempt). The
					-- original mmu_req_read/mmu_req_write-only condition
					-- below is restored.
					--
					-- WAIT-RELEASE PHASE GUARD (SDRAM-review-handoff.md,
					-- section 5 / step 3a). The T80 is clocked by the
					-- fabric-derived cpuClock, which RISES on the clk edge at
					-- which (old) cpuClkCount = 2. If sdram_wait_n changed on
					-- that same edge, individual T80 flip-flops (TState,
					-- IR/DI_Reg load enables, PC, RD_n/MREQ_n hold, ...)
					-- could capture a mixture of the old and new Wait_n value
					-- (STA: hold violations to -4.1 ns, fast corner), leaving
					-- the CPU in an inconsistent state -- an intermittently
					-- mis-executed instruction. So never release on that
					-- edge; release one clk later instead (sdram_wait_n is
					-- only ever low for SDRAM cycles, so non-SDRAM cycles are
					-- unaffected). The exit test below is still correct: the
					-- CPU cannot drop RD/WR until it has seen Wait_n = '1'.
					if cpuClkCount /= "000010" then
						sdram_wait_n <= '1';
					end if;
					if mmu_req_read = '0' and mmu_req_write = '0' then
						-- Enforce the inter-request dead time before another
						-- transaction may start. sdram_we/rd are already low
						-- here; hold them low through S_GAP so the 112 MHz
						-- request-level synchroniser in MultiComp.sv sees a
						-- clean falling edge and will detect the NEXT request
						-- as a fresh rising edge. Without this, back-to-back
						-- SDRAM accesses (e.g. consecutive M1 opcode fetches
						-- executing from SDRAM) can merge into one held level,
						-- the controller never re-triggers, wait_n sticks low
						-- and the CPU hangs -- exactly the symptom where code
						-- runs from block RAM but hangs the instant it is
						-- CALLed in SDRAM. Data-only tests (LDIR) never hit it
						-- because non-SDRAM cycles supply the gap for free.
						sdram_gap_cnt <= "10";        -- 3 clk_sys cycles of dead time
						sdram_state   <= S_GAP;
					end if;

				when S_GAP =>
					-- Strobes held low; just count down the dead time. Re-arm
					-- only after the request level has been low long enough
					-- for the clk_ram 2-FF synchroniser (>= 2 clk_ram edges).
					sdram_we_reg <= '0';
					sdram_rd_reg <= '0';
					sdram_wait_n <= '1';
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
		
		if cpuClkCount < 2 then -- 2 when 10MHz, 2 when 12.5MHz, 2 when 16.6MHz, 1 when 25MHz
			cpuClock <= '0';
		else
			cpuClock <= '1';
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

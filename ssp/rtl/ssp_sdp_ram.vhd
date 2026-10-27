-- ssp_sdp_ram.vhd -- explicit 16K x 32 dual-port (write port A / read port
-- B -- simple-dual-port usage) M10K RAM IP for the SSP fabric (D-36; proven
-- shape from the OQ-20 bake-off, R21, bakeoff/ssp_sdp_ram.vhd).  R31: promoted
-- to ssp/rtl with an INIT_FILE generic -- the MROM instance carries the factory
-- ROM image (D-38, ssp/fw/forth_rom.mif); the DTCM instance leaves it "UNUSED"
-- (power-up zero).  House style follows the wizard wrappers
-- already shipping here: Components/TERMINAL/DisplayRam1K.vhd (2-port 1Kx8)
-- and Components/INTERNALRAM/InternalRam64K.vhd (1-port 64Kx8, the general
-- memory system's RAM); written by hand with fixed parameters instead of
-- wizard output.
--
-- Why explicit IP (owner ruling R21): inference against FemtoRV's
-- combinational address bus defeated Quartus 17 M10K inference for the
-- inference-style fabric (see bakeoff/README.md); the IP path is exact,
-- reviewable, and vendor-sanctioned.
--
-- Port A = write (byte-enable), Port B = read with REGISTERED address
-- (ADDRESS_REG_B=CLOCK0) and unregistered output: q valid the cycle after
-- the address edge -- SSP fabric read timing truth for both bake-off cores.

LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY altera_mf;
USE altera_mf.altera_mf_components.all;

ENTITY ssp_sdp_ram IS
	GENERIC
	(
		INIT_FILE		: STRING := "UNUSED"	-- .mif / .hex, "UNUSED" = none
	);
	PORT
	(
		address_w		: IN STD_LOGIC_VECTOR (13 DOWNTO 0);
		address_r		: IN STD_LOGIC_VECTOR (13 DOWNTO 0);
		clock			: IN STD_LOGIC  := '1';
		data_w			: IN STD_LOGIC_VECTOR (31 DOWNTO 0);
		byteena			: IN STD_LOGIC_VECTOR (3 DOWNTO 0);
		wren			: IN STD_LOGIC  := '0';
		q				: OUT STD_LOGIC_VECTOR (31 DOWNTO 0)
	);
END ssp_sdp_ram;

ARCHITECTURE SYN OF ssp_sdp_ram IS

	SIGNAL sub_wire0	: STD_LOGIC_VECTOR (31 DOWNTO 0);

BEGIN
	q    <= sub_wire0(31 DOWNTO 0);

	altsyncram_component : altsyncram
	GENERIC MAP (
		address_reg_b => "CLOCK0",
		clock_enable_input_a => "BYPASS",
		clock_enable_input_b => "BYPASS",
		clock_enable_output_b => "BYPASS",
		init_file => INIT_FILE,
		intended_device_family => "Cyclone V",
		lpm_type => "altsyncram",
		numwords_a => 16384,
		numwords_b => 16384,
		operation_mode => "DUAL_PORT",
		outdata_aclr_b => "NONE",
		outdata_reg_b => "UNREGISTERED",
		power_up_uninitialized => "FALSE",
		read_during_write_mode_mixed_ports => "DONT_CARE",
		widthad_a => 14,
		widthad_b => 14,
		width_a => 32,
		width_b => 32,
		width_byteena_a => 4
	)
	PORT MAP (
		address_a => address_w,
		address_b => address_r,
		byteena_a => byteena,
		clock0 => clock,
		data_a => data_w,
		wren_a => wren,
		q_b => sub_wire0
	);

END SYN;

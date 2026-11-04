-- MrZ80_PSG_stub.vhd - SIMULATION-ONLY stand-in for Components/PSG/MrZ80_PSG.sv
-- so the GHDL lanes can elaborate MicrocomputerZ80CPM(_sim).vhd (GHDL cannot
-- analyse the SystemVerilog PSG). Behaves like an absent device: reads return
-- $FF (the floating bus), audio is silent. The real PSG is covered by the
-- Verilator lane `make -C sim psg` (sim/tb_psg.sv).
-- Keep the generics and ports in step with MrZ80_PSG.sv.

library ieee;
use ieee.std_logic_1164.all;

entity MrZ80_PSG is
	generic (
		CLK_HZ        : integer := 50000000;
		PSG_HZ        : integer := 1789772;
		DAC_BITS      : integer := 10;
		SETTLE_CYCLES : integer := 10000000
	);
	port (
		clk         : in  std_logic;
		reset_n     : in  std_logic;
		stereo_mode : in  std_logic_vector(1 downto 0);
		cs_sel1     : in  std_logic;
		cs_dat1     : in  std_logic;
		cs_sel2     : in  std_logic;
		cs_dat2     : in  std_logic;
		io_wr       : in  std_logic;
		din         : in  std_logic_vector(7 downto 0);
		dout        : out std_logic_vector(7 downto 0);
		audio_l     : out std_logic_vector(15 downto 0);
		audio_r     : out std_logic_vector(15 downto 0)
	);
end MrZ80_PSG;

architecture stub of MrZ80_PSG is
begin
	dout    <= x"FF";
	audio_l <= (others => '0');
	audio_r <= (others => '0');
end stub;

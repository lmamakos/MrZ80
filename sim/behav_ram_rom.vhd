-- ============================================================================
-- behav_ram_rom.vhd - SIMULATION-ONLY behavioral stand-ins for the two
-- Altera `altsyncram`-megafunction-backed entities MicrocomputerZ80CPM
-- instantiates for its ROM and 64K block RAM (Components/INTERNALRAM/
-- InternalRam64K.vhd and ROMS/Z80/Z80_CPM_BASIC_ROM.vhd). Those real files
-- need the Intel/Altera `altera_mf` simulation library, which is not
-- available in this project's GHDL-based simulation setup (see
-- sim/sim_compat_pkg.vhd's header for the parallel situation with
-- STD_LOGIC_ARITH/STD_LOGIC_UNSIGNED).
--
-- These behavioral replacements have IDENTICAL entity names and port lists
-- to the real megafunction wrappers, so `entity work.InternalRam64K` /
-- `entity work.Z80_CPM_BASIC_ROM` resolve to them when this file is
-- compiled into the simulation's `work` library instead of the real files.
--
-- InternalRam64K: matches the real altsyncram config (single port,
-- UNREGISTERED/combinational read, write-first on same address) closely
-- enough for functional (not gate-timing) simulation.
--
-- Z80_CPM_BASIC_ROM: content is irrelevant for this testbench.
-- MicrocomputerZ80CPM's ROM overlay is unconditionally disabled whenever
-- bin_loaded='1' (see n_basRomCS's decode condition), and this testbench's
-- top-level always drives bin_loaded='1', so this ROM is never selected
-- onto the CPU data bus; it just needs to exist and elaborate.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity InternalRam64K is
    port (
        address : in  std_logic_vector(15 downto 0);
        clock   : in  std_logic := '1';
        data    : in  std_logic_vector(7 downto 0);
        wren    : in  std_logic;
        q       : out std_logic_vector(7 downto 0)
    );
end entity InternalRam64K;

architecture sim of InternalRam64K is
    type ram_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    signal mem : ram_t := (others => (others => '0'));
begin
    process(clock)
    begin
        if rising_edge(clock) then
            if wren = '1' then
                mem(to_integer(unsigned(address))) <= data;
            end if;
        end if;
    end process;

    -- UNREGISTERED (combinational) read port, matching the real
    -- altsyncram's outdata_reg_a=>"UNREGISTERED" / read_during_write_
    -- mode_port_a=>"NEW_DATA_NO_NBE_READ" configuration closely enough for
    -- functional simulation.
    q <= mem(to_integer(unsigned(address)));
end architecture sim;

library ieee;
use ieee.std_logic_1164.all;

entity Z80_CPM_BASIC_ROM is
    port (
        address : in  std_logic_vector(12 downto 0);
        clock   : in  std_logic := '1';
        q       : out std_logic_vector(7 downto 0)
    );
end entity Z80_CPM_BASIC_ROM;

architecture sim of Z80_CPM_BASIC_ROM is
begin
    q <= (others => '0');
end architecture sim;

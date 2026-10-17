-- ============================================================================
-- behav_ram_rom.vhd - SIMULATION-ONLY behavioral stand-in for the Altera
-- `altsyncram`-megafunction-backed entity MicrocomputerZ80CPM instantiates
-- for its 64K block RAM (Components/INTERNALRAM/InternalRam64K.vhd). The
-- boot ROM has been removed from the design, so there is no ROM stand-in.
-- That real file needs the Intel/Altera `altera_mf` simulation library, which is not
-- available in this project's GHDL-based simulation setup (see
-- sim/sim_compat_pkg.vhd's header for the parallel situation with
-- STD_LOGIC_ARITH/STD_LOGIC_UNSIGNED).
--
-- This behavioral replacement has an IDENTICAL entity name and port list
-- to the real megafunction wrapper, so `entity work.InternalRam64K`
-- resolves to it when this file is compiled into the simulation's `work`
-- library instead of the real file.
--
-- InternalRam64K: matches the real altsyncram config (single port,
-- UNREGISTERED/combinational read, write-first on same address) closely
-- enough for functional (not gate-timing) simulation.
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

-- ============================================================================
-- behav_terminal_ram.vhd - SIMULATION-ONLY behavioral stand-ins for the
-- display RAM and font ROM of Components/TERMINAL/SBCTextDisplayRGB.vhd
-- (DisplayRam2K / CGABoldRomReduced are Quartus `altsyncram` wrappers that need
-- the altera_mf library, which the GHDL lanes do not have).  Same entity names
-- and ports, same read timing: registered address, unregistered output, so q
-- is valid the clock after the address edge.  The font ROM reads as zero (the
-- benches check terminal state, not pixels).  Used by sim/run_terminal.sh.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package behav_ram_pkg is
    type ram2k_t is array (0 to 2047) of std_logic_vector(7 downto 0);
end package behav_ram_pkg;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.behav_ram_pkg.all;

entity DisplayRam2K is
    port (
        address_a : in  std_logic_vector(10 downto 0);
        address_b : in  std_logic_vector(10 downto 0);
        clock     : in  std_logic := '1';
        data_a    : in  std_logic_vector(7 downto 0);
        data_b    : in  std_logic_vector(7 downto 0);
        wren_a    : in  std_logic := '0';
        wren_b    : in  std_logic := '0';
        q_a       : out std_logic_vector(7 downto 0);
        q_b       : out std_logic_vector(7 downto 0)
    );
end entity DisplayRam2K;

architecture behav of DisplayRam2K is
    signal ram : ram2k_t := (others => (others => '0'));
    signal ra, rb : integer range 0 to 2047 := 0;
begin
    process (clock)
    begin
        if rising_edge(clock) then
            if wren_a = '1' then ram(to_integer(unsigned(address_a))) <= data_a; end if;
            if wren_b = '1' then ram(to_integer(unsigned(address_b))) <= data_b; end if;
            ra <= to_integer(unsigned(address_a));
            rb <= to_integer(unsigned(address_b));
        end if;
    end process;
    q_a <= ram(ra);
    q_b <= ram(rb);
end architecture behav;

library ieee;
use ieee.std_logic_1164.all;

entity CGABoldRomReduced is
    port (
        address : in  std_logic_vector(9 downto 0);
        clock   : in  std_logic := '1';
        q       : out std_logic_vector(7 downto 0)
    );
end entity CGABoldRomReduced;

architecture behav of CGABoldRomReduced is
begin
    q <= (others => '0');
end architecture behav;

-- The 40-column and 256-character variants: present only so the terminal's
-- untaken generate branches elaborate.
library ieee;
use ieee.std_logic_1164.all;

entity DisplayRam1K is
    port (
        address_a : in  std_logic_vector(9 downto 0);
        address_b : in  std_logic_vector(9 downto 0);
        clock     : in  std_logic := '1';
        data_a    : in  std_logic_vector(7 downto 0);
        data_b    : in  std_logic_vector(7 downto 0);
        wren_a    : in  std_logic := '0';
        wren_b    : in  std_logic := '0';
        q_a       : out std_logic_vector(7 downto 0);
        q_b       : out std_logic_vector(7 downto 0)
    );
end entity DisplayRam1K;

architecture behav of DisplayRam1K is
begin
    q_a <= (others => '0');
    q_b <= (others => '0');
end architecture behav;

library ieee;
use ieee.std_logic_1164.all;

entity CGABoldRom is
    port (
        address : in  std_logic_vector(10 downto 0);
        clock   : in  std_logic := '1';
        q       : out std_logic_vector(7 downto 0)
    );
end entity CGABoldRom;

architecture behav of CGABoldRom is
begin
    q <= (others => '0');
end architecture behav;

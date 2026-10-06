-- ============================================================================
-- behav_display.vhd - SIMULATION-ONLY behavioral stand-in for
-- Components/TERMINAL/SBCTextDisplayRGB.vhd.
--
-- The real entity is pure behavioral itself, but its font-ROM and
-- display-RAM backing stores (CGABoldRomReduced / DisplayRam2K, selected
-- by the default generics MicrocomputerZ80CPM uses) are Quartus
-- MegaWizard `altsyncram` wrappers requiring the `altera_mf` simulation
-- library (see sim/behav_ram_rom.vhd's header for the same situation with
-- the block RAM / boot ROM).
--
-- This testbench never exercises the video/keyboard terminal, so no
-- internal logic is needed at all -- just the identical entity name/port
-- list (see Components/TERMINAL/SBCTextDisplayRGB.vhd:42-77) driving safe,
-- inactive constants, so `entity work.SBCTextDisplayRGB` elaborates
-- without pulling in any Altera megafunction.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity SBCTextDisplayRGB is
    port (
        n_reset       : in  std_logic;
        clk           : in  std_logic;
        n_wr          : in  std_logic;
        n_rd          : in  std_logic;
        regSel        : in  std_logic;
        dataIn        : in  std_logic_vector(7 downto 0);
        dataOut       : out std_logic_vector(7 downto 0);
        n_int         : out std_logic;
        n_rts         : out std_logic := '0';

        videoR0       : out std_logic;
        videoR1       : out std_logic;
        videoG0       : out std_logic;
        videoG1       : out std_logic;
        videoB0       : out std_logic;
        videoB1       : out std_logic;
        hSync         : buffer std_logic;
        vSync         : buffer std_logic;
        hBlank        : out std_logic;
        vBlank        : out std_logic;
        cepix         : out std_logic;

        video         : buffer std_logic;
        sync          : out std_logic;

        ps2Clk        : in std_logic;
        ps2Data       : in std_logic;

        FNkeys        : out std_logic_vector(12 downto 0);
        FNtoggledKeys : out std_logic_vector(12 downto 0)
    );
end entity SBCTextDisplayRGB;

architecture sim of SBCTextDisplayRGB is
begin
    dataOut       <= (others => '0');
    n_int         <= '1';
    n_rts         <= '1';
    videoR0       <= '0';
    videoR1       <= '0';
    videoG0       <= '0';
    videoG1       <= '0';
    videoB0       <= '0';
    videoB1       <= '0';
    hSync         <= '0';
    vSync         <= '0';
    hBlank        <= '0';
    vBlank        <= '0';
    cepix         <= '0';
    video         <= '0';
    sync          <= '0';
    FNkeys        <= (others => '0');
    FNtoggledKeys <= (others => '0');
end architecture sim;

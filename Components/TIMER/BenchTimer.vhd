-- ============================================================================
-- BenchTimer.vhd - free-running millisecond / microsecond timers with
--                  per-channel 32-bit snapshot latches (benchmark timing).
-- ----------------------------------------------------------------------------
-- Two 32-bit free-running counters are derived from the system clock:
--
--   us_count : increments once per microsecond (wraps after ~71.6 minutes)
--   ms_count : increments once per millisecond (wraps after ~49.7 days)
--
-- Four channels, each with its own 32-bit snapshot latch, occupy a window of
-- 16 consecutive I/O ports (base set by the external decoder driving io_cs;
-- the module looks only at addr(3 downto 0)):
--
--   offset  channel  time base   write (any value)      read
--   ------  -------  ---------   ---------------------  -------------------
--   +0..+3     0     1 ms/tick   latch channel 0        latched byte 0..3
--   +4..+7     1     1 ms/tick   latch channel 1        latched byte 0..3
--   +8..+11    2     1 us/tick   latch channel 2        latched byte 0..3
--   +12..+15   3     1 us/tick   latch channel 3        latched byte 0..3
--
-- Bytes are little-endian: offset +0 of a channel is bits 7:0, +3 is bits
-- 31:24. A write to ANY of a channel's four ports snapshots the current
-- counter into that channel's latch (the data written is ignored). Reads
-- have no side effects, so the bytes can be read in any order, any number
-- of times, and channels never interfere with each other.
--
-- Typical use (channel 0, ports base+0..base+3):
--     OUT (base+0),A       ; snapshot
--     IN  A,(base+0)       ; bits  7:0
--     IN  A,(base+1)       ; bits 15:8
--     IN  A,(base+2)       ; bits 23:16
--     IN  A,(base+3)       ; bits 31:24
-- Elapsed time = (end - start) modulo 2^32.
--
-- MONOTONIC: the counters and latches are initialised only at FPGA
-- configuration (power-up / core load). They deliberately have NO reset
-- input, so a CPU reset or software can never set them back.
--
-- The snapshot is taken once, on the first clk cycle of each write strobe
-- (rising edge of the decoded write), so the latch is stable for the whole
-- of any subsequent read cycle.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity BenchTimer is
    generic (
        CLK_HZ : integer := 50000000      -- clk frequency (multiple of 1 MHz)
    );
    port (
        clk    : in  std_logic;
        io_cs  : in  std_logic;           -- active high: port window selected
        wr_n   : in  std_logic;           -- CPU I/O write strobe (active low)
        addr   : in  std_logic_vector(3 downto 0);
        dout   : out std_logic_vector(7 downto 0)
    );
end BenchTimer;

architecture rtl of BenchTimer is

    constant US_DIV : integer := CLK_HZ / 1000000;

    -- Power-up initial values (no reset by design; see header).
    signal us_pre    : integer range 0 to US_DIV - 1 := 0;
    signal ms_pre    : integer range 0 to 999        := 0;
    signal us_count  : unsigned(31 downto 0) := (others => '0');
    signal ms_count  : unsigned(31 downto 0) := (others => '0');
    -- Snapshot latches. Four separate signals (not an array) so they stay
    -- plain registers with stable names (BenchTimer:timer1|snapN[*]) for
    -- the MultiComp.sdc hold constraint.
    signal snap0     : unsigned(31 downto 0) := (others => '0');
    signal snap1     : unsigned(31 downto 0) := (others => '0');
    signal snap2     : unsigned(31 downto 0) := (others => '0');
    signal snap3     : unsigned(31 downto 0) := (others => '0');

    signal wr_now    : std_logic;
    signal wr_prev   : std_logic := '0';

begin

    -- Time bases.
    timebase : process (clk)
    begin
        if rising_edge(clk) then
            if us_pre = US_DIV - 1 then
                us_pre   <= 0;
                us_count <= us_count + 1;
                if ms_pre = 999 then
                    ms_pre   <= 0;
                    ms_count <= ms_count + 1;
                else
                    ms_pre <= ms_pre + 1;
                end if;
            else
                us_pre <= us_pre + 1;
            end if;
        end if;
    end process;

    -- Snapshot latches: one capture per write strobe.
    wr_now <= io_cs and not wr_n;

    latches : process (clk)
    begin
        if rising_edge(clk) then
            wr_prev <= wr_now;
            if wr_now = '1' and wr_prev = '0' then
                case addr(3 downto 2) is
                    when "00"   => snap0 <= ms_count;
                    when "01"   => snap1 <= ms_count;
                    when "10"   => snap2 <= us_count;
                    when others => snap3 <= us_count;
                end case;
            end if;
        end if;
    end process;

    -- Read-back: byte addr(1:0) of channel addr(3:2). Purely combinational
    -- from the (stable) latches.
    read_mux : process (addr, snap0, snap1, snap2, snap3)
        variable v : unsigned(31 downto 0);
    begin
        case addr(3 downto 2) is
            when "00"   => v := snap0;
            when "01"   => v := snap1;
            when "10"   => v := snap2;
            when others => v := snap3;
        end case;
        case addr(1 downto 0) is
            when "00"   => dout <= std_logic_vector(v( 7 downto  0));
            when "01"   => dout <= std_logic_vector(v(15 downto  8));
            when "10"   => dout <= std_logic_vector(v(23 downto 16));
            when others => dout <= std_logic_vector(v(31 downto 24));
        end case;
    end process;

end rtl;

-- ============================================================================
-- IntervalTimer.vhd - programmable millisecond interval timer and Z80 INT
--                     source (REQUIREMENTS.md item 7).
-- ----------------------------------------------------------------------------
-- Counts milliseconds from the system clock and raises a level interrupt
-- request every INTERVAL milliseconds. Written for Z80 interrupt mode 1 (the
-- CPU takes RST 38h); software polls STATUS to tell this source from others.
-- It is independent of the CPU clock and of CPU wait states.
--
-- Four ports (base set by the external decoder driving io_cs; the module
-- looks only at addr(1 downto 0)):
--
--   port  write                         read
--   ----  ----------------------------  ----------------------------------
--   +0    INTERVAL low byte             INTERVAL low byte
--   +1    INTERVAL high byte            INTERVAL high byte
--   +2    CONTROL (levels)              STATUS
--   +3    COMMAND (strobes)             STATUS (same as +2)
--
-- INTERVAL (16 bits, milliseconds). The counter expires when it has counted
-- INTERVAL milliseconds, so 1 = every ms and 0 is treated as 1. It may be
-- changed while running; the new value is used at the next millisecond.
--
-- CONTROL (written; each write sets IE and AUTO, and acts on RUN):
--   bit 0 RUN   1 = start the counter from 0 if it is stopped (no effect when
--               already running); 0 = stop it and clear it to 0
--   bit 1 IE    1 = EXPIRED drives INT
--   bit 2 AUTO  1 = restart automatically on expiry (periodic, no drift);
--               0 = one-shot: the counter stops on expiry
--
-- COMMAND (written; every bit is a one-shot strobe, nothing is stored):
--   bit 0 RESET   clear the counter and the millisecond prescaler to 0 (a
--                 running counter keeps running and counts a full interval)
--   bit 1 ACK     clear EXPIRED, which releases the interrupt request
--   bit 2 CLROVF  clear OVERFLOW
--
-- STATUS (read):
--   bit 0 EXPIRED   set when the counter expires; stays set until ACK
--   bit 1 OVERFLOW  set when the counter expires again while EXPIRED is still
--                   set (a missed tick); stays set until CLROVF
--   bit 2 RUNNING   the counter is counting (a one-shot clears it on expiry)
--   bit 3 INTREQ    this timer is asserting INT (EXPIRED and IE)
--   bit 4 IE        as written to CONTROL
--   bit 5 AUTO      as written to CONTROL
--   bits 7:6        0
--
-- INT (int_n, active low) = not (EXPIRED and IE): a level, released by ACK or
-- by clearing IE. A write takes effect on the clk after its strobe ends (data
-- are captured during the strobe), so the Z80 sees it on its next instruction.
-- A coincident expiry and ACK leaves EXPIRED set and OVERFLOW unchanged: the
-- new expiry is not hidden, and the one just acknowledged is not a miss.
--
-- reset_n clears everything (EXPIRED, OVERFLOW, IE, AUTO, INTERVAL, counter);
-- a running timer therefore does not survive a Z80 reset.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity IntervalTimer is
    generic (
        CLK_HZ : integer := 50000000      -- clk frequency (multiple of 1 kHz)
    );
    port (
        clk     : in  std_logic;
        reset_n : in  std_logic;
        io_cs   : in  std_logic;          -- active high: port window selected
        wr_n    : in  std_logic;          -- CPU I/O write strobe (active low)
        addr    : in  std_logic_vector(1 downto 0);
        din     : in  std_logic_vector(7 downto 0);
        dout    : out std_logic_vector(7 downto 0);
        int_n   : out std_logic
    );
end IntervalTimer;

architecture rtl of IntervalTimer is

    constant MS_DIV : integer := CLK_HZ / 1000;

    signal interval : unsigned(15 downto 0) := (others => '0');
    signal cnt      : unsigned(15 downto 0) := (others => '0');
    signal pre      : integer range 0 to MS_DIV - 1 := 0;
    signal running  : std_logic := '0';
    signal ie       : std_logic := '0';
    signal auto     : std_logic := '0';
    signal expired  : std_logic := '0';
    signal ovf      : std_logic := '0';

    signal wr_now   : std_logic;
    signal wr_prev  : std_logic := '0';
    signal addr_q   : std_logic_vector(1 downto 0) := "00";
    signal din_q    : std_logic_vector(7 downto 0) := (others => '0');

    signal status   : std_logic_vector(7 downto 0);

begin

    wr_now <= io_cs and not wr_n;

    status <= "00" & auto & ie & (expired and ie) & running & ovf & expired;

    int_n <= not (expired and ie);

    read_mux : process (addr, interval, status)
    begin
        case addr is
            when "00"   => dout <= std_logic_vector(interval(7 downto 0));
            when "01"   => dout <= std_logic_vector(interval(15 downto 8));
            when others => dout <= status;
        end case;
    end process;

    main : process (clk)
        variable wr_done : boolean;
        variable expire  : boolean;
        variable exp_v   : std_logic;
    begin
        if rising_edge(clk) then
            wr_prev <= wr_now;
            if wr_now = '1' then
                addr_q <= addr;
                din_q  <= din;
            end if;
            wr_done := (wr_prev = '1' and wr_now = '0');

            if reset_n = '0' then
                interval <= (others => '0');
                cnt      <= (others => '0');
                pre      <= 0;
                running  <= '0';
                ie       <= '0';
                auto     <= '0';
                expired  <= '0';
                ovf      <= '0';
            else
                expire := false;
                exp_v  := expired;

                -- Millisecond prescaler and counter.
                if running = '1' then
                    if pre = MS_DIV - 1 then
                        pre <= 0;
                        if ('0' & cnt) + 1 >= '0' & interval then
                            expire := true;
                            cnt    <= (others => '0');
                            if auto = '0' then
                                running <= '0';
                            end if;
                        else
                            cnt <= cnt + 1;
                        end if;
                    else
                        pre <= pre + 1;
                    end if;
                else
                    pre <= 0;
                end if;

                -- Register writes, taken as the strobe ends.
                if wr_done then
                    case addr_q is
                        when "00" => interval(7 downto 0)  <= unsigned(din_q);
                        when "01" => interval(15 downto 8) <= unsigned(din_q);
                        when "10" =>
                            ie   <= din_q(1);
                            auto <= din_q(2);
                            if din_q(0) = '0' then
                                running <= '0';
                                cnt     <= (others => '0');
                                pre     <= 0;
                            elsif running = '0' then
                                running <= '1';
                                cnt     <= (others => '0');
                                pre     <= 0;
                            end if;
                        when others =>
                            if din_q(0) = '1' then
                                cnt <= (others => '0');
                                pre <= 0;
                            end if;
                            if din_q(1) = '1' then
                                exp_v := '0';
                            end if;
                            if din_q(2) = '1' then
                                ovf <= '0';
                            end if;
                    end case;
                end if;

                if expire then
                    if exp_v = '1' then
                        ovf <= '1';
                    end if;
                    exp_v := '1';
                end if;
                expired <= exp_v;
            end if;
        end if;
    end process;

end rtl;

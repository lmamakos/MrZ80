--============================================================================
-- tb_ds12887.vhd
--
-- Testbench for the ds12887 MiSTer RTC model.
--
-- The DUT is instantiated with TB_MODE = true, which shrinks the internal
-- counters so "one second" lasts P_TB = 25 clocks (TICK_MAX = 24):
--
--   P_TB = 25   tick period (clocks per second)
--
-- The test sequence mirrors the real MiSTer flow:
--   * the host (hps_io) pushes BCD time BEFORE the core reset releases
--   * a periodic refresh is pushed later and must be ignored once guest
--     software has written the time/calendar itself
--
-- Run with GHDL:
--   ghdl -a --std=08 ds12887.vhd tb_ds12887.vhd
--   ghdl -e --std=08 tb_ds12887
--   ghdl -r --std=08 tb_ds12887
--============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_ds12887 is
end entity tb_ds12887;

architecture sim of tb_ds12887 is

    signal clk    : std_logic := '0';
    signal reset  : std_logic := '0';
    signal req    : std_logic := '0';
    signal wrt    : std_logic := '0';
    signal adr    : std_logic_vector(6 downto 0) := (others => '0');
    signal dbo    : std_logic_vector(7 downto 0) := (others => '0');
    signal dbi    : std_logic_vector(7 downto 0) := (others => '0');
    signal irq    : std_logic := 'Z';
    signal sqw    : std_logic := '0';
    signal rtc    : std_logic_vector(64 downto 0) := (others => '0');
    signal pof_in : std_logic := '0';

    constant CLK_PER : time := 20 ns;    -- 50 MHz
    constant P_TB    : integer := 25;    -- TB tick period (TICK_MAX + 1)

    subtype nyb_t is std_logic_vector(3 downto 0);

    -- procedures drive the DUT bus signals through in/out formal
    -- parameters (a procedure may only assign to its signal parameters)

    function b2bc(v : integer) return nyb_t;
    function slv2str(s : std_logic_vector) return string;
    procedure io_r(a : integer; d : out std_logic_vector(7 downto 0);
                   signal req_s : inout std_logic; signal wrt_s : inout std_logic;
                   signal adr_s : inout std_logic_vector(6 downto 0);
                   signal dbi_s : std_logic_vector(7 downto 0));
    procedure io_w(a : integer; d : std_logic_vector(7 downto 0);
                   signal req_s : inout std_logic; signal wrt_s : inout std_logic;
                   signal adr_s : inout std_logic_vector(6 downto 0);
                   signal dbo_s : inout std_logic_vector(7 downto 0));
    procedure host_push(sec_i : integer; min_i : integer; hr_i : integer;
                        day_i : integer; mon_i : integer; yr_i : integer;
                        wday_i : integer;
                        signal rtc_s : inout std_logic_vector(64 downto 0));
    procedure check(name : string; got : std_logic_vector(7 downto 0);
                    exp : std_logic_vector(7 downto 0));
    procedure check_range(name : string; got : std_logic_vector(7 downto 0);
                          lo : integer; hi : integer);
    procedure checkb(name : string; got : std_logic; exp : std_logic);

    ------------------------------------------------------------------
    -- helper definitions
    ------------------------------------------------------------------
    function b2bc(v : integer) return nyb_t is
    begin
        return std_logic_vector(to_unsigned(v mod 10, 4));
    end function;

    function slv2str(s : std_logic_vector) return string is
        variable r : string(1 to s'length);
    begin
        for i in 0 to s'length - 1 loop
            r(s'length - i) := '1' when s(i) = '1' else '0';
        end loop;
        return r;
    end function;

    -- full-period strobes so at least one clk_sys edge is always covered
    procedure io_r(a : integer; d : out std_logic_vector(7 downto 0);
                   signal req_s : inout std_logic; signal wrt_s : inout std_logic;
                   signal adr_s : inout std_logic_vector(6 downto 0);
                   signal dbi_s : std_logic_vector(7 downto 0)) is
    begin
        req_s <= '1'; wrt_s <= '0';
        adr_s <= std_logic_vector(to_unsigned(a, 7));
        wait for CLK_PER;
        d := dbi_s;
        req_s <= '0';
        wait for CLK_PER;
    end procedure;

    procedure io_w(a : integer; d : std_logic_vector(7 downto 0);
                   signal req_s : inout std_logic; signal wrt_s : inout std_logic;
                   signal adr_s : inout std_logic_vector(6 downto 0);
                   signal dbo_s : inout std_logic_vector(7 downto 0)) is
    begin
        req_s <= '1'; wrt_s <= '1';
        adr_s <= std_logic_vector(to_unsigned(a, 7));
        dbo_s <= d;
        wait for CLK_PER;
        req_s <= '0'; wrt_s <= '0';
        dbo_s <= (others => '0');
        wait for CLK_PER;
    end procedure;

    -- MiSTer hps_io.RTC layout (MSM6242B BCD, little-endian word pairs);
    -- the toggle bit 64 flips on every push (static private state)
    procedure host_push(sec_i : integer; min_i : integer; hr_i : integer;
                        day_i : integer; mon_i : integer; yr_i : integer;
                        wday_i : integer;
                        signal rtc_s : inout std_logic_vector(64 downto 0)) is
        variable raw : std_logic_vector(63 downto 0);
        variable tog : std_logic := '0';
    begin
        raw(7 downto 0)    := b2bc(sec_i / 10) & b2bc(sec_i mod 10);
        raw(15 downto 8)   := b2bc(min_i / 10) & b2bc(min_i mod 10);
        raw(23 downto 16)  := b2bc(hr_i / 10) & b2bc(hr_i mod 10);
        raw(31 downto 24)  := b2bc(day_i / 10) & b2bc(day_i mod 10);
        raw(39 downto 32)  := b2bc(mon_i / 10) & b2bc(mon_i mod 10);
        raw(47 downto 40)  := b2bc(yr_i / 10) & b2bc(yr_i mod 10);
        raw(55 downto 48)  := std_logic_vector(to_unsigned(wday_i, 8));
        raw(63 downto 56)  := "01000000";
        tog := not tog;
        rtc_s <= tog & raw;
    end procedure;

    procedure check(name : string; got : std_logic_vector(7 downto 0);
                    exp : std_logic_vector(7 downto 0)) is
    begin
        if got = exp then
            report "PASS: " & name;
        else
            report "FAIL: " & name & " got " & slv2str(got) &
                   " exp " & slv2str(exp);
        end if;
    end procedure;

    procedure check_range(name : string; got : std_logic_vector(7 downto 0);
                          lo : integer; hi : integer) is
        variable g : integer;
    begin
        g := to_integer(unsigned(got));
        if g >= lo and g <= hi then
            report "PASS: " & name & " (" & integer'image(g) & ")";
        else
            report "FAIL: " & name & " got " & integer'image(g) &
                   " exp " & integer'image(lo) & ".." & integer'image(hi);
        end if;
    end procedure;

    procedure checkb(name : string; got : std_logic; exp : std_logic) is
    begin
        if got = exp then
            report "PASS: " & name;
        else
            report "FAIL: " & name & " got " & std_logic'image(got) &
                   " exp " & std_logic'image(exp);
        end if;
    end procedure;

begin

    dut : entity work.ds12887
        generic map (SYS_CLK => 50_000_000, TB_MODE => true)
        port map (
            clk_sys   => clk,
            reset     => reset,
            req       => req,
            wrt       => wrt,
            adr       => adr,
            dbo       => dbo,
            dbi       => dbi,
            irq       => irq,
            sqw       => sqw,
            rtc       => rtc,
            timestamp => (others => '0'),
            pof_in    => pof_in
        );

    clk <= not clk after CLK_PER / 2;

    stim : process
        variable v8 : std_logic_vector(7 downto 0);
        variable v1 : std_logic_vector(7 downto 0);
        variable s2 : std_logic_vector(7 downto 0);
        variable s3 : std_logic_vector(7 downto 0);
        variable d  : integer;
    begin
        report "=== ds12887 TB start ===";

        --------------------------------------------------------------
        -- power-up: the MiSTer host pushes BCD time while the core is
        -- still in reset (send_rtc(3) happens before reset release)
        --------------------------------------------------------------
        reset <= '1';
        wait for 100 ns;
        host_push(56, 34, 12, 8, 10, 26, 4, rtc);  -- 2026-10-08 12:34:56
        wait for 100 ns;
        reset <= '0';
        wait for 50 ns;

        --------------------------------------------------------------
        -- T1: registers follow the host BCD push
        --------------------------------------------------------------
        io_r(16#00#, v8, req, wrt, adr, dbi);
        check("T1 sec",  v8, x"56");
        io_r(16#02#, v8, req, wrt, adr, dbi);
        check("T1 min",  v8, x"34");
        io_r(16#04#, v8, req, wrt, adr, dbi);
        check("T1 hr",   v8, x"12");
        io_r(16#06#, v8, req, wrt, adr, dbi);
        check("T1 dow",  v8, x"05");   -- Thu, Sun=1
        io_r(16#07#, v8, req, wrt, adr, dbi);
        check("T1 date", v8, x"08");
        io_r(16#08#, v8, req, wrt, adr, dbi);
        check("T1 mon",  v8, x"10");
        io_r(16#09#, v8, req, wrt, adr, dbi);
        check("T1 yr",   v8, x"26");
        io_r(16#0A#, v8, req, wrt, adr, dbi);
        check("T1 regA", v8, x"20");   -- DV=010: clock started
        io_r(16#0B#, v8, req, wrt, adr, dbi);
        check("T1 regB", v8, x"02");   -- first sync: 24-h
        io_r(16#0D#, v8, req, wrt, adr, dbi);
        check("T1 regD", v8, x"00");   -- no power-fail

        --------------------------------------------------------------
        -- T2: local 1 Hz counting (10 TB-seconds window)
        --------------------------------------------------------------
        io_r(16#00#, v1, req, wrt, adr, dbi);
        wait for (10 * P_TB) * CLK_PER;
        io_r(16#00#, v8, req, wrt, adr, dbi);
        -- BCD decode (the seconds byte is BCD in this test, not binary)
        d := 10 * to_integer(unsigned(v8(7 downto 4))) +
             to_integer(unsigned(v8(3 downto 0))) -
             10 * to_integer(unsigned(v1(7 downto 4))) -
             to_integer(unsigned(v1(3 downto 0)));
        d := (d + 60) mod 60;
        check_range("T2 sec advanced ~10",
                    std_logic_vector(to_unsigned(d, 8)), 9, 11);

        --------------------------------------------------------------
        -- T3: alarm (don't-care s/min + exact hr) + UF + IRQ,
        --     Register C read clears
        --------------------------------------------------------------
        io_w(16#01#, x"FF", req, wrt, adr, dbo);  -- alarm sec: don't care
        io_w(16#03#, x"FF", req, wrt, adr, dbo);  -- alarm min: don't care
        io_w(16#05#, x"12", req, wrt, adr, dbo);  -- alarm hr: exact
        io_w(16#0B#, x"32", req, wrt, adr, dbo);  -- AIE + UIE + 24-h
        wait for (2 * P_TB + 30) * CLK_PER;
        checkb("T3 irq active", irq, '0');
        io_r(16#0C#, v8, req, wrt, adr, dbi);
        check("T3 regC IRQF+AF+UF", v8, x"B0");
        wait for 3 * CLK_PER;
        checkb("T3 irq tri after C read", irq, 'Z');

        --------------------------------------------------------------
        -- T4: guest writes the time -> host refreshes are ignored
        --------------------------------------------------------------
        io_w(16#00#, x"15", req, wrt, adr, dbo);
        io_w(16#02#, x"42", req, wrt, adr, dbo);
        io_w(16#04#, x"09", req, wrt, adr, dbo);
        io_w(16#07#, x"01", req, wrt, adr, dbo);
        io_w(16#08#, x"01", req, wrt, adr, dbo);
        io_w(16#09#, x"00", req, wrt, adr, dbo);
        wait for 10 * CLK_PER;
        host_push(0, 0, 13, 9, 10, 26, 5, rtc);   -- periodic host refresh
        wait for 20 * CLK_PER;
        io_r(16#00#, v8, req, wrt, adr, dbi);
        check_range("T4 sec guest-written", v8, 21, 24);
        io_r(16#04#, v8, req, wrt, adr, dbi);
        check("T4 hr guest-owned", v8, x"09");
        io_r(16#07#, v8, req, wrt, adr, dbi);
        check("T4 date guest-owned", v8, x"01");
        io_r(16#08#, v8, req, wrt, adr, dbi);
        check("T4 mon guest-owned", v8, x"01");
        io_r(16#09#, v8, req, wrt, adr, dbi);
        check("T4 yr guest-owned", v8, x"00");

        --------------------------------------------------------------
        -- T5: 23:59:59 -> 00:00:00 rollover via SET programming
        --------------------------------------------------------------
        io_w(16#0B#, x"82", req, wrt, adr, dbo);  -- SET=1, 24-h (frozen)
        io_w(16#04#, x"23", req, wrt, adr, dbo);
        io_w(16#02#, x"59", req, wrt, adr, dbo);
        io_w(16#00#, x"59", req, wrt, adr, dbo);
        io_w(16#0B#, x"02", req, wrt, adr, dbo);  -- SET=0, resume
        wait for (4 * P_TB + 30) * CLK_PER;
        io_r(16#00#, v8, req, wrt, adr, dbi);
        check_range("T5 sec after rollover", v8, 3, 4);
        io_r(16#02#, v8, req, wrt, adr, dbi);
        check("T5 min 00", v8, x"00");
        io_r(16#04#, v8, req, wrt, adr, dbi);
        check("T5 hr 00",  v8, x"00");
        io_r(16#07#, v8, req, wrt, adr, dbi);
        check("T5 date +1", v8, x"02");
        io_r(16#06#, v8, req, wrt, adr, dbi);
        check("T5 dow +1",  v8, x"06");
        io_r(16#08#, v8, req, wrt, adr, dbi);
        check("T5 mon same", v8, x"01");

        --------------------------------------------------------------
        -- T6: RAM 0x10-0x7F; unmapped 0x0E/0x0F read 0xFF
        --------------------------------------------------------------
        io_w(16#20#, x"AB", req, wrt, adr, dbo);
        io_r(16#20#, v8, req, wrt, adr, dbi);
        check("T6 ram 0x20", v8, x"AB");
        io_w(16#7F#, x"5A", req, wrt, adr, dbo);
        io_r(16#7F#, v8, req, wrt, adr, dbi);
        check("T6 ram 0x7F", v8, x"5A");
        io_r(16#0E#, v8, req, wrt, adr, dbi);
        check("T6 unmapped 0x0E", v8, x"FF");
        io_r(16#0F#, v8, req, wrt, adr, dbi);
        check("T6 unmapped 0x0F", v8, x"FF");

        --------------------------------------------------------------
        -- T7: binary mode (DM=1)
        --------------------------------------------------------------
        io_w(16#0B#, x"06", req, wrt, adr, dbo);   -- DM + 24-h
        io_w(16#00#, x"1E", req, wrt, adr, dbo);   -- seconds = 30 binary
        io_r(16#00#, v8, req, wrt, adr, dbi);
        check_range("T7 sec binary", v8, 30, 31);
        io_r(16#04#, v8, req, wrt, adr, dbi);
        check("T7 hr binary 00", v8, x"00");

        --------------------------------------------------------------
        -- T8: periodic interrupt (Reg A DV=010, RS=0011 -> top tap;
        --     in TB mode the top tap fires every 4 clocks)
        --------------------------------------------------------------
        io_w(16#0B#, x"46", req, wrt, adr, dbo);   -- PIE + DM + 24-h
        io_w(16#0A#, x"23", req, wrt, adr, dbo);   -- running, 8.192 kHz tap
        io_r(16#0C#, v8, req, wrt, adr, dbi);      -- discard: clear flags
        wait for (3 * P_TB + 20) * CLK_PER;
        checkb("T8 irq active", irq, '0');
        io_r(16#0C#, v8, req, wrt, adr, dbi);
        check("T8 regC IRQF+PF+UF", v8, x"D0");
        io_r(16#0C#, v8, req, wrt, adr, dbi);      -- discard for T9
        wait for 3 * CLK_PER;

        --------------------------------------------------------------
        -- T9: SET bit freezes the user copy
        --------------------------------------------------------------
        io_w(16#0B#, x"86", req, wrt, adr, dbo);   -- SET + PIE + DM + 24-h
        io_r(16#00#, v1, req, wrt, adr, dbi);
        wait for (2 * P_TB) * CLK_PER;
        io_r(16#00#, v1, req, wrt, adr, dbi);
        io_r(16#00#, s2, req, wrt, adr, dbi);
        check("T9 sec frozen while SET", s2, v1);
        io_w(16#0B#, x"46", req, wrt, adr, dbo);   -- SET=0
        wait for (2 * P_TB + 30) * CLK_PER;
        io_r(16#00#, s3, req, wrt, adr, dbi);
        check_range("T9 sec resumed", s3,
                    to_integer(unsigned(s2)) + 2,
                    to_integer(unsigned(s2)) + 3);

        --------------------------------------------------------------
        -- T10: Register D VRT from pof_in
        --------------------------------------------------------------
        pof_in <= '1';
        wait for 10 ns;
        io_r(16#0D#, v8, req, wrt, adr, dbi);
        check("T10 regD VRT", v8, x"80");
        pof_in <= '0';
        wait for 10 ns;
        io_r(16#0D#, v8, req, wrt, adr, dbi);
        check("T10 regD clear", v8, x"00");

        report "=== ALL TESTS DONE ===";
        wait for 100 ns;
        finish;
    end process stim;

end architecture sim;

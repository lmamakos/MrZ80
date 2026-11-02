-- tb_interval_timer.vhd -- unit bench for Components/TIMER/IntervalTimer.vhd.
--
-- CLK_HZ = 100 kHz gives 100 clocks per millisecond, so intervals of a few ms
-- are a few hundred clocks and every edge can be counted exactly.  Writes are
-- driven like a Z80 I/O write: the select and data are held for 8 clocks, and
-- the timer acts as the strobe ends.
--
-- Checks: reset state; interval byte order and read-back; exact period in
-- periodic mode; status bits; ACK releasing INT; OVERFLOW on a missed tick and
-- CLROVF; one-shot stop and re-arm; IE as a mask that holds the pending state;
-- RESET restarting the interval; RUN=0 stopping; interval 0 and live interval
-- change; an ACK swept across every phase against an expiry (no false
-- overflow, no lost expiry); reset_n clearing everything.
--
-- Run: sim/run_interval_timer.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_interval_timer is
end tb_interval_timer;

architecture sim of tb_interval_timer is

    constant CLK_HZ : integer := 100000;
    constant MS     : integer := CLK_HZ / 1000;     -- clocks per ms

    signal clk     : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal io_cs   : std_logic := '0';
    signal wr_n    : std_logic := '1';
    signal addr    : std_logic_vector(1 downto 0) := "00";
    signal din     : std_logic_vector(7 downto 0) := (others => '0');
    signal dout    : std_logic_vector(7 downto 0);
    signal int_n   : std_logic;

    signal cyc       : integer := 0;
    signal last_fall : integer := 0;
    signal prev_fall : integer := 0;
    signal errors  : natural := 0;
    signal checks  : natural := 0;

    constant P_IVL_LO : std_logic_vector(1 downto 0) := "00";
    constant P_IVL_HI : std_logic_vector(1 downto 0) := "01";
    constant P_CTRL   : std_logic_vector(1 downto 0) := "10";
    constant P_CMD    : std_logic_vector(1 downto 0) := "11";

    -- status bits
    constant S_EXP : integer := 0;
    constant S_OVF : integer := 1;
    constant S_RUN : integer := 2;
    constant S_REQ : integer := 3;
    constant S_IE  : integer := 4;
    constant S_AUT : integer := 5;

    -- CONTROL / COMMAND bit values
    constant C_RUN  : std_logic_vector(7 downto 0) := x"01";
    constant C_IE   : std_logic_vector(7 downto 0) := x"02";
    constant C_AUTO : std_logic_vector(7 downto 0) := x"04";
    constant K_RST  : std_logic_vector(7 downto 0) := x"01";
    constant K_ACK  : std_logic_vector(7 downto 0) := x"02";
    constant K_OVF  : std_logic_vector(7 downto 0) := x"04";

begin

    clk <= not clk after 5 ns;

    dut : entity work.IntervalTimer
        generic map (CLK_HZ => CLK_HZ)
        port map (clk => clk, reset_n => reset_n, io_cs => io_cs, wr_n => wr_n,
                  addr => addr, din => din, dout => dout, int_n => int_n);

    counter : process (clk)
    begin
        if rising_edge(clk) then
            cyc <= cyc + 1;
        end if;
    end process;

    falls : process (int_n)
    begin
        if falling_edge(int_n) then
            prev_fall <= last_fall;
            last_fall <= cyc;
        end if;
    end process;

    main : process

        procedure fail(what : string) is
        begin
            errors <= errors + 1;
            report "FAIL: " & what severity error;
        end procedure;

        procedure expect(cond : boolean; what : string) is
        begin
            checks <= checks + 1;
            if not cond then fail(what); end if;
        end procedure;

        procedure tick(n : natural := 1) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); end loop;
        end procedure;

        -- Z80-style I/O write: held 8 clocks; returns on the clock the
        -- timer acts (the strobe has just ended).
        procedure wr(a : std_logic_vector(1 downto 0); d : std_logic_vector(7 downto 0)) is
        begin
            addr <= a; din <= d; io_cs <= '1'; wr_n <= '0';
            tick(8);
            io_cs <= '0'; wr_n <= '1'; din <= (others => 'X');
            tick(1);
        end procedure;

        procedure rd(a : std_logic_vector(1 downto 0); v : out std_logic_vector(7 downto 0)) is
        begin
            addr <= a; io_cs <= '1';
            tick(2);
            v := dout;
            io_cs <= '0';
        end procedure;

        procedure status(v : out std_logic_vector(7 downto 0)) is
        begin
            rd(P_CTRL, v);
        end procedure;

        procedure expect_status(mask : std_logic_vector(7 downto 0);
                                val  : std_logic_vector(7 downto 0);
                                what : string) is
            variable s, s3 : std_logic_vector(7 downto 0);
        begin
            status(s);
            rd(P_CMD, s3);
            expect((s and mask) = (val and mask), what & ": status=" & to_hstring(s)
                   & " want " & to_hstring(val) & "/" & to_hstring(mask));
            expect(s3 = s, what & ": +3 reads differently from +2");
            expect(s(7 downto 6) = "00", what & ": status bits 7:6 not zero");
            expect((int_n = '0') = (s(S_REQ) = '1'), what & ": INTREQ disagrees with int_n");
        end procedure;

        -- Clocks (from the strobe-end clock) until int_n goes low; samples
        -- one clock behind the DUT, so a first expiry at ms*MS reads ms*MS+1.
        procedure wait_int(maxc : natural; k : out integer) is
        begin
            k := -1;
            for i in 1 to maxc loop
                tick(1);
                if int_n = '0' then k := i; exit; end if;
            end loop;
        end procedure;

        variable k, k2, t0, n_set : integer;
        variable s     : std_logic_vector(7 downto 0);
        variable ovf_seen : boolean;
        variable exp_last : std_logic;
    begin
        reset_n <= '0';
        tick(4);
        reset_n <= '1';
        tick(2);

        -- ---- reset state ----
        expect_status(x"FF", x"00", "after reset");
        rd(P_IVL_LO, s); expect(s = x"00", "interval low resets to 0");
        rd(P_IVL_HI, s); expect(s = x"00", "interval high resets to 0");
        expect(int_n = '1', "INT inactive after reset");

        -- ---- interval byte order and read-back ----
        wr(P_IVL_LO, x"34"); wr(P_IVL_HI, x"12");
        rd(P_IVL_LO, s); expect(s = x"34", "interval low read-back");
        rd(P_IVL_HI, s); expect(s = x"12", "interval high read-back");
        expect_status(x"FF", x"00", "interval writes do not start the timer");

        -- ---- periodic: exact first expiry and exact period ----
        wr(P_IVL_LO, x"03"); wr(P_IVL_HI, x"00");
        wr(P_CTRL, C_RUN or C_IE or C_AUTO);
        wait_int(10 * MS, k);
        expect(k = 3 * MS + 1, "first expiry after 3 ms, got " & integer'image(k));
        expect_status(x"3F", "00" & "111101", "periodic, expired");  -- AUTO IE REQ RUN -- EXP
        wr(P_CMD, K_ACK);
        expect_status(x"3F", "00" & "110100", "after ACK");          -- AUTO IE RUN
        expect(int_n = '1', "ACK releases INT");
        -- the period is exactly 3 ms from expiry to expiry, however late the ACK
        wait_int(10 * MS, k2);
        expect(k2 > 0 and last_fall - prev_fall = 3 * MS,
               "period 3 ms, got " & integer'image(last_fall - prev_fall));

        -- ---- overflow: a second expiry before the first is acknowledged ----
        expect_status(x"03", "00000001", "expired, no overflow yet");
        tick(3 * MS + 10);
        expect_status(x"03", "00000011", "second expiry sets OVERFLOW");
        wr(P_CMD, K_OVF);
        expect_status(x"03", "00000001", "CLROVF clears OVERFLOW, EXPIRED stays");
        expect(int_n = '0', "CLROVF leaves INT asserted");
        wr(P_CMD, K_ACK);
        expect_status(x"03", "00000000", "ACK clears EXPIRED");

        -- ---- RUN=0 stops and clears; the pending state is kept ----
        tick(3 * MS + 20);
        expect_status(x"01", "00000001", "expired again before stop");
        wr(P_CTRL, C_IE or C_AUTO);                       -- RUN = 0
        wr(P_CMD, K_ACK or K_OVF);
        expect_status(x"3F", "00110000", "stopped: IE AUTO only");
        tick(10 * MS);
        expect_status(x"3F", "00110000", "no expiry while stopped");

        -- ---- one-shot: stops on expiry, re-arm with RUN=1 ----
        wr(P_CTRL, C_RUN or C_IE);                        -- one-shot
        wait_int(10 * MS, k);
        expect(k = 3 * MS + 1, "one-shot expiry after 3 ms, got " & integer'image(k));
        expect_status(x"3F", "00011001", "one-shot expired, stopped");  -- IE REQ EXP, RUN=0
        tick(10 * MS);
        expect_status(x"03", "00000001", "one-shot: no second expiry");
        wr(P_CMD, K_ACK);
        wr(P_CTRL, C_RUN or C_IE);                        -- re-arm
        t0 := cyc;
        expect_status(x"07", "00000100", "re-armed: running, not expired");
        wait_int(10 * MS, k);
        expect(k > 0 and last_fall - t0 = 3 * MS + 1,
               "re-armed expiry after 3 ms, got " & integer'image(last_fall - t0));
        wr(P_CMD, K_ACK);

        -- ---- RUN=1 while already running does not restart ----
        wr(P_CTRL, C_RUN or C_IE or C_AUTO);
        tick(2 * MS);
        wr(P_CTRL, C_RUN or C_IE or C_AUTO);              -- must not restart
        wait_int(10 * MS, k);
        expect(k < 2 * MS, "rewriting RUN=1 did not restart the count, k=" & integer'image(k));
        wr(P_CMD, K_ACK);

        -- ---- RESET restarts the interval without stopping ----
        tick(2 * MS);
        wr(P_CMD, K_RST);
        t0 := cyc;
        expect_status(x"04", "00000100", "RESET keeps RUNNING");
        wait_int(10 * MS, k);
        expect(k > 0 and last_fall - t0 = 3 * MS + 1,
               "full interval after RESET, got " & integer'image(last_fall - t0));
        wr(P_CMD, K_ACK);

        -- ---- IE masks INT but not the pending state; unmasking is a level ----
        wr(P_CTRL, C_RUN or C_AUTO);                      -- IE = 0
        tick(4 * MS);
        expect_status(x"1F", "00000101", "IE=0: expired, running, no request");
        expect(int_n = '1', "IE=0 keeps INT inactive");
        wr(P_CTRL, C_RUN or C_AUTO or C_IE);
        tick(1);
        expect(int_n = '0', "setting IE asserts INT for the pending expiry");
        wr(P_CTRL, C_RUN or C_AUTO);
        tick(1);
        expect(int_n = '1', "clearing IE withdraws INT");
        wr(P_CMD, K_ACK or K_OVF);

        -- ---- interval 0 behaves as 1 ms; a live change takes effect ----
        wr(P_CTRL, x"00");
        wr(P_IVL_LO, x"00"); wr(P_IVL_HI, x"00");
        wr(P_CTRL, C_RUN or C_IE or C_AUTO);
        wait_int(3 * MS, k);
        expect(k = MS + 1, "interval 0 expires after 1 ms, got " & integer'image(k));
        wr(P_CMD, K_ACK or K_OVF);
        wr(P_IVL_LO, x"09");                              -- 9 ms, while running
        wr(P_CMD, K_RST);
        wait_int(20 * MS, k);
        expect(k >= 9 * MS - 2 and k <= 9 * MS + 2, "live change to 9 ms, k=" & integer'image(k));
        wr(P_CMD, K_ACK or K_OVF);
        wr(P_CTRL, x"00");

        -- ---- 16-bit interval: $0101 = 257 ms ----
        wr(P_IVL_LO, x"01"); wr(P_IVL_HI, x"01");
        wr(P_CTRL, C_RUN or C_IE);
        wait_int(300 * MS, k);
        expect(k = 257 * MS + 1, "interval $0101 = 257 ms, got " & integer'image(k));
        wr(P_CMD, K_ACK);
        wr(P_CTRL, x"00");

        -- ---- ACK against the expiry clock: before, with, and after ----
        -- Interval 2 ms, periodic. The timer is started by a CONTROL write whose
        -- action edge is E, so the first expiry takes place on edge E+2*MS and
        -- the second on E+4*MS. An ACK is timed to act on edge expiry+d.
        --   first expiry (nothing pending): an ACK before or with it leaves
        --     EXPIRED set (the new expiry is not hidden); after it clears it.
        --   second expiry (first still pending): an ACK before or with it
        --     leaves EXPIRED set and no OVERFLOW (the first was acknowledged);
        --     after it is a miss: OVERFLOW, and the late ACK clears EXPIRED.
        wr(P_IVL_LO, x"02"); wr(P_IVL_HI, x"00");
        for second in 0 to 1 loop
            for d in -4 to 4 loop
                wr(P_CTRL, x"00");
                wr(P_CMD, K_ACK or K_OVF);
                wr(P_CTRL, C_RUN or C_IE or C_AUTO);
                tick((second + 1) * 2 * MS + d - 9);
                wr(P_CMD, K_ACK);
                tick(MS / 2);
                status(s);
                if second = 0 then
                    expect((s(S_EXP) = '1') = (d <= 0) and s(S_OVF) = '0',
                           "first expiry, ACK at " & integer'image(d) & ": status=" & to_hstring(s));
                else
                    expect((s(S_EXP) = '1') = (d <= 0) and (s(S_OVF) = '1') = (d >= 1),
                           "second expiry, ACK at " & integer'image(d) & ": status=" & to_hstring(s));
                end if;
            end loop;
        end loop;
        wr(P_CTRL, x"00");
        wr(P_CMD, K_ACK or K_OVF);

        -- ---- reset_n clears everything ----
        wr(P_IVL_LO, x"05");
        wr(P_CTRL, C_RUN or C_IE or C_AUTO);
        tick(6 * MS);
        expect(int_n = '0', "expired before reset");
        reset_n <= '0'; tick(2); reset_n <= '1'; tick(2);
        expect_status(x"FF", x"00", "reset_n clears status");
        rd(P_IVL_LO, s); expect(s = x"00", "reset_n clears interval");
        tick(10 * MS);
        expect(int_n = '1', "no expiry after reset_n");

        report "tb_interval_timer: " & integer'image(checks) & " checks, "
               & integer'image(errors) & " errors";
        if errors = 0 then
            report "PASS: tb_interval_timer";
        else
            report "FAIL: tb_interval_timer" severity failure;
        end if;
        std.env.stop;
    end process;

end sim;

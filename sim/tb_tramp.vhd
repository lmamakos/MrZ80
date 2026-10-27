-- tb_tramp.vhd -- ssp_tramp (guest reset vent + reset-vector trampoline
-- injector, "G aaaa", D-02/D-39) against the REAL T80s in the production
-- configuration (Mode 1, T2Write 1, IOWait 0, cpu_cen 1-of-5).
--
-- The bench plays the bridge: busrq_n = CTRL hold (park request), z_reset_n
-- = CTRL.Z_RST_N vent, arm = CTRL.TRAMP_EN (cleared on `done`, as the
-- bridge does), target = TRAMP_ADDR.
--
-- Memory map (all addresses chosen so injected and real data differ):
--   0000: C3 00 01        JP 0100   boot vector (real bytes C3,00,01)
--   0100: loop: INC (8000); LD A,(0001); LD (8030),A    counter + data reads
--   0234: marker program: copies REAL (0001),(0002) to 8011/8012 (proves
--         the injector has disarmed -- injected would be 34/02), writes
--         5A to 8010, then JR $ at 0245
--
-- Cases: 1 idle transparency · 2 park -> G 0234 (BUSRQ dropped with reset
-- release) · 3 park-at-target (BUSRQ kept) · 4 plain Reset CPU (no arm) ·
-- 5 arm without reset never intercepts · 6 wait states · 7 reset re-asserted
-- mid-window · 8 odd targets (0000, FFFF, C3C3) · 9 vent minimum width.
--
-- Run from the project root:  sim/run_tramp.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_tramp is
end tb_tramp;

architecture sim of tb_tramp is

    -- ---------------------------------------------------- shared state ----
    type mem_pt is protected
        procedure wr(a : natural; d : std_logic_vector(7 downto 0));
        impure function rd(a : natural) return std_logic_vector;
    end protected;

    type mem_pt is protected body
        type arr_t is array (0 to 65535) of std_logic_vector(7 downto 0);
        variable m : arr_t := (others => x"00");
        procedure wr(a : natural; d : std_logic_vector(7 downto 0)) is
        begin
            m(a) := d;
        end procedure;
        impure function rd(a : natural) return std_logic_vector is
        begin
            return m(a);
        end function;
    end protected body;

    -- log of every read cycle the CPU completes (address, data it sampled)
    type log_pt is protected
        procedure clear;
        procedure push(a : std_logic_vector(15 downto 0);
                       d : std_logic_vector(7 downto 0));
        impure function count return natural;
        impure function la(i : natural) return std_logic_vector;
        impure function ld(i : natural) return std_logic_vector;
    end protected;

    type log_pt is protected body
        type la_t is array (0 to 15) of std_logic_vector(15 downto 0);
        type ld_t is array (0 to 15) of std_logic_vector(7 downto 0);
        variable a_l : la_t := (others => x"0000");
        variable d_l : ld_t := (others => x"00");
        variable n   : natural := 0;
        procedure clear is begin n := 0; end procedure;
        procedure push(a : std_logic_vector(15 downto 0);
                       d : std_logic_vector(7 downto 0)) is
        begin
            if n < 16 then a_l(n) := a; d_l(n) := d; n := n + 1; end if;
        end procedure;
        impure function count return natural is begin return n; end function;
        impure function la(i : natural) return std_logic_vector is
        begin return a_l(i); end function;
        impure function ld(i : natural) return std_logic_vector is
        begin return d_l(i); end function;
    end protected body;

    shared variable mem : mem_pt;
    shared variable rlog : log_pt;

    -- ---------------------------------------------------------- signals ----
    signal clk       : std_logic := '0';
    signal cen_ph    : natural range 0 to 4 := 0;
    signal cen       : std_logic;
    signal stop_sim  : boolean := false;

    signal sys_rst_n : std_logic := '0';
    signal z_reset_n : std_logic := '1';
    signal arm       : std_logic := '0';
    signal target    : std_logic_vector(15 downto 0) := x"0000";
    signal busrq_n   : std_logic := '1';
    signal wait_k    : natural := 0;          -- wait states per read (cen)

    signal t80_rst_n, done_p, active : std_logic;
    signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
    signal wait_n    : std_logic := '1';
    signal a         : std_logic_vector(15 downto 0);
    signal di_raw, din, dout : std_logic_vector(7 downto 0) := x"00";
    signal reg       : std_logic_vector(211 downto 0);
    signal done_cnt  : natural := 0;

    signal act, act_q : std_logic := '0';
    signal last_a    : std_logic_vector(15 downto 0) := x"0000";
    signal last_d    : std_logic_vector(7 downto 0)  := x"00";
    signal wcnt      : natural := 0;

begin

    clk <= not clk after 10 ns when not stop_sim else '0';      -- 50 MHz

    -- cpu_cen: one clk in five (production), high when phase = 2
    process (clk)
    begin
        if rising_edge(clk) then
            if cen_ph = 4 then cen_ph <= 0; else cen_ph <= cen_ph + 1; end if;
        end if;
    end process;
    cen <= '1' when cen_ph = 2 else '0';

    -- ------------------------------------------------------------- DUTs ----
    tramp : entity work.ssp_tramp
        generic map (VENT_CEN => 8)
        port map (
            clk => clk, cen => cen,
            sys_rst_n => sys_rst_n, z_reset_n => z_reset_n,
            t80_rst_n => t80_rst_n,
            arm => arm, target => target, done => done_p, active => active,
            addr => a, mreq_n => mreq_n, rd_n => rd_n,
            din_in => di_raw, din_out => din);

    cpu : entity work.T80s
        generic map (Mode => 1, T2Write => 1, IOWait => 0)
        port map (
            RESET_n => t80_rst_n, CLK_n => clk, CEN => cen,
            WAIT_n => wait_n, INT_n => '1', NMI_n => '1',
            BUSRQ_n => busrq_n,
            M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n, RD_n => rd_n,
            WR_n => wr_n, RFSH_n => rfsh_n, HALT_n => halt_n,
            BUSAK_n => busak_n, A => a, DI => din, DO => dout,
            REG => reg,
            FREEZE_req_n => '1', FREEZE_any => '0');  -- unused port in T80

    -- ----------------------------------------------------------- memory ----
    -- 1-clk registered read (production memory is BRAM/SDRAM behind waits);
    -- writes are idempotent while the strobes are low.
    process (clk)
    begin
        if rising_edge(clk) then
            di_raw <= mem.rd(to_integer(unsigned(a)));
            if mreq_n = '0' and wr_n = '0' then
                mem.wr(to_integer(unsigned(a)), dout);
            end if;
        end if;
    end process;

    -- wait states: hold WAIT_n low for wait_k cpu_cen periods from the
    -- start of every read cycle
    act <= '1' when (mreq_n = '0' and rd_n = '0') else '0';
    process (clk)
    begin
        if rising_edge(clk) then
            act_q <= act;
            if act = '1' and act_q = '0' then
                wcnt <= wait_k * 5;
            elsif wcnt > 0 then
                wcnt <= wcnt - 1;
            end if;
        end if;
    end process;
    wait_n <= '0' when (act = '1' and wcnt > 0) else '1';

    -- read log: (address, data sampled) at the end of each read cycle
    process (clk)
    begin
        if rising_edge(clk) then
            if act = '1' then
                last_a <= a;
                last_d <= din;
            end if;
            if act_q = '1' and act = '0' then
                rlog.push(last_a, last_d);
            end if;
            if done_p = '1' then
                done_cnt <= done_cnt + 1;
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------- stim ----
    stim : process
        variable errors : natural := 0;
        variable cases  : natural := 0;
        variable t0     : time;
        variable n0     : natural;
        variable c1, c2 : std_logic_vector(7 downto 0);

        procedure clks(n : natural) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure check(ok : boolean; what : string) is
        begin
            cases := cases + 1;
            if not ok then
                report "FAIL: " & what severity error;
                errors := errors + 1;
            end if;
        end procedure;

        procedure check_b(got, exp : std_logic_vector; what : string) is
        begin
            cases := cases + 1;
            if got /= exp then
                report "FAIL: " & what & " = " & to_hstring(got) &
                       ", expected " & to_hstring(exp) severity error;
                errors := errors + 1;
            end if;
        end procedure;

        function pc_of(r : std_logic_vector(211 downto 0))
            return std_logic_vector is
        begin
            return r(79 downto 64);
        end function;

        procedure poke(addr : natural; d : natural) is
        begin
            mem.wr(addr, std_logic_vector(to_unsigned(d, 8)));
        end procedure;

        procedure load(addr : natural; bytes : std_logic_vector) is
            -- hex string literals are ascending; normalise to n-1 downto 0
            variable v : std_logic_vector(bytes'length - 1 downto 0) := bytes;
            variable k : natural := 0;
        begin
            -- first (leftmost) byte of the literal goes to the lowest address
            for i in bytes'length / 8 - 1 downto 0 loop
                mem.wr(addr + k, v(i * 8 + 7 downto i * 8));
                k := k + 1;
            end loop;
        end procedure;

        procedure park(what : string) is
        begin
            busrq_n <= '0';
            wait until busak_n = '0' for 60 us;
            check(busak_n = '0', what & ": BusAck granted");
        end procedure;

        procedure clear_marks is
        begin
            poke(16#8010#, 0);  poke(16#8011#, 16#EE#);  poke(16#8012#, 16#EE#);
        end procedure;

        -- full "G aaaa" as the FW will do it: arm, vent, release reset and
        -- drop BUSRQ together.  CPU must be parked (busrq_n='0') on entry.
        procedure g_go(tgt : std_logic_vector(15 downto 0);
                       drop_hold : boolean; what : string) is
        begin
            target <= tgt;
            arm    <= '1';
            clks(2);
            z_reset_n <= '0';
            clks(6);
            check(t80_rst_n = '0', what & ": T80 in reset");
            check(busak_n = '1',   what & ": reset cleared BusAck");
            check(active = '1',    what & ": injector armed");
            clks(100);                         -- vent held by FW a while
            rlog.clear;
            t0 := now;
            z_reset_n <= '1';
            if drop_hold then busrq_n <= '1'; end if;
            wait until t80_rst_n = '1' for 5 us;
            check(now - t0 >= 700 ns, what & ": vent holds >= 7 cen after release");
        end procedure;

        procedure expect_done(what : string) is
        begin
            n0 := done_cnt;
            wait until done_p = '1' for 30 us;
            check(done_p = '1', what & ": done pulse");
            clks(3);
            arm <= '0';                        -- bridge auto-clears TRAMP_EN
            check(done_cnt = n0 + 1, what & ": exactly one done");
            check(active = '0', what & ": injector idle after done");
        end procedure;

        procedure check_inject_log(tgt : std_logic_vector(15 downto 0);
                                   what : string) is
        begin
            check(rlog.count >= 4, what & ": >= 4 reads logged");
            check_b(rlog.la(0), x"0000", what & ": read0 addr");
            check_b(rlog.ld(0), x"C3",   what & ": read0 = C3 (JP)");
            check_b(rlog.la(1), x"0001", what & ": read1 addr");
            check_b(rlog.ld(1), tgt(7 downto 0),  what & ": read1 = lo");
            check_b(rlog.la(2), x"0002", what & ": read2 addr");
            check_b(rlog.ld(2), tgt(15 downto 8), what & ": read2 = hi");
            check_b(rlog.la(3), tgt,     what & ": read3 = fetch at target");
        end procedure;

        procedure marks_ok(what : string) is
        begin
            check_b(mem.rd(16#8010#), x"5A", what & ": marker program ran");
            check_b(mem.rd(16#8011#), x"00", what & ": real (0001) read after done");
            check_b(mem.rd(16#8012#), x"01", what & ": real (0002) read after done");
        end procedure;

    begin
        -- boot vector + main loop + marker program
        load(16#0000#, x"C30001");
        load(16#0100#, x"210080" & x"34" & x"3A0100" & x"323080" & x"18F7");
        load(16#0234#, x"3A0100" & x"321180" & x"3A0200" & x"321280" &
                       x"3E5A" & x"321080" & x"18FE");
        poke(16#FFFF#, 16#76#);                 -- HALT at FFFF
        poke(16#C3C3#, 16#76#);                 -- HALT at C3C3
        clear_marks;
        poke(16#8030#, 16#FF#);

        -- ============ 1. power-up, idle: the injector is transparent ========
        report "case 1: idle transparency";
        sys_rst_n <= '0';
        clks(20);
        rlog.clear;
        sys_rst_n <= '1';
        clks(3000);
        c1 := mem.rd(16#8000#);
        check(c1 /= x"00", "1: boot ran (JP 0100 loop counting)");
        check(active = '0', "1: injector idle");
        check(done_cnt = 0, "1: no done pulse");
        check_b(rlog.ld(0), x"C3", "1: real read0");
        check_b(rlog.ld(1), x"00", "1: real read1");
        check_b(rlog.ld(2), x"01", "1: real read2");
        check_b(mem.rd(16#8030#), x"00", "1: loop data read (0001) is real");

        -- ============ 2. park, then G 0234 (hold dropped with release) ======
        report "case 2: park then G 0234";
        park("2");
        c1 := mem.rd(16#8000#);
        clks(500);
        c2 := mem.rd(16#8000#);
        check_b(c2, c1, "2: counter frozen while parked");
        clear_marks;
        g_go(x"0234", true, "2");
        expect_done("2");
        clks(3000);
        check_inject_log(x"0234", "2");
        marks_ok("2");

        -- ============ 3. park-at-target (hold kept through release) =========
        report "case 3: park-at-target";
        park("3");
        check_b(pc_of(reg), x"0245", "3: parked in the marker loop");
        clear_marks;
        g_go(x"0234", false, "3");
        expect_done("3");
        wait until busak_n = '0' for 30 us;
        check(busak_n = '0', "3: parked again after the JP");
        check_b(pc_of(reg), x"0234", "3: parked AT the target (PC = target)");
        check_b(mem.rd(16#8010#), x"00", "3: target code not yet executed");
        busrq_n <= '1';
        clks(3000);
        check_inject_log(x"0234", "3");
        marks_ok("3");

        -- ============ 4. plain Reset CPU: no arm => no injection ============
        report "case 4: reset without arm";
        park("4");
        arm <= '0';
        poke(16#8000#, 0);  clear_marks;
        z_reset_n <= '0';  clks(10);
        rlog.clear;
        n0 := done_cnt;
        z_reset_n <= '1';  busrq_n <= '1';
        clks(3000);
        check(done_cnt = n0, "4: no done pulse");
        check(active = '0', "4: injector idle");
        check_b(rlog.ld(1), x"00", "4: real read1 (no injection)");
        check_b(rlog.ld(2), x"01", "4: real read2 (no injection)");
        check(mem.rd(16#8000#) /= x"00", "4: restarted via real boot vector");
        check_b(mem.rd(16#8010#), x"00", "4: marker program not run");

        -- ============ 5. arm without a reset never intercepts ===============
        report "case 5: arm without reset";
        poke(16#8030#, 16#FF#);
        n0 := done_cnt;
        target <= x"0234";
        arm <= '1';
        clks(3000);
        check_b(mem.rd(16#8030#), x"00", "5: data read of (0001) not intercepted");
        check(active = '0', "5: stays idle without a reset");
        check(done_cnt = n0, "5: no done pulse");
        arm <= '0';

        -- ============ 6. wait states (3 cen on every read) ==================
        report "case 6: G 0234 with wait states";
        wait_k <= 3;
        park("6");
        clear_marks;
        g_go(x"0234", true, "6");
        expect_done("6");
        clks(6000);
        check_inject_log(x"0234", "6");
        marks_ok("6");
        wait_k <= 0;

        -- ============ 7. reset re-asserted inside the window ================
        -- Three restart points: before any byte completes, after byte 0, and
        -- after byte 1 (idx = 0/1/2 at the moment of the second reset).  Each
        -- must restart the whole three-byte sequence (idx and hit cleared).
        for k in 0 to 2 loop
            report "case 7." & integer'image(k) & ": reset re-asserted mid-window";
            park("7");
            clear_marks;
            target <= x"0234";
            arm <= '1';
            clks(2);
            z_reset_n <= '0';  clks(20);
            z_reset_n <= '1';  busrq_n <= '1';
            wait until t80_rst_n = '1' for 5 us;
            rlog.clear;
            case k is
                when 0 => clks(8);             -- inside the first fetch
                when 1 => clks(22);            -- after byte 0, inside byte 1
                when others => clks(40);       -- after byte 1, inside byte 2
            end case;
            if k > 0 then
                check(rlog.count >= k, "7." & integer'image(k) &
                      ": " & integer'image(k) & " injected byte(s) completed first");
            end if;
            z_reset_n <= '0';  clks(3);        -- second vent
            rlog.clear;
            n0 := done_cnt;
            z_reset_n <= '1';
            wait until done_p = '1' for 30 us;
            check(done_p = '1', "7." & integer'image(k) & ": done after restart");
            clks(3);
            arm <= '0';
            check(done_cnt = n0 + 1, "7." & integer'image(k) & ": exactly one done");
            clks(3000);
            check_inject_log(x"0234", "7." & integer'image(k));
            marks_ok("7." & integer'image(k));
        end loop;

        -- ============ 8. odd targets ========================================
        report "case 8: targets 0000, FFFF, C3C3";
        -- 8a: G 0000 -> JP 0000 -> real boot vector -> 0100 loop
        park("8a");
        poke(16#8000#, 0);
        g_go(x"0000", true, "8a");
        expect_done("8a");
        clks(3000);
        check_b(rlog.ld(0), x"C3", "8a: read0 injected");
        check_b(rlog.ld(1), x"00", "8a: read1 injected (lo=00)");
        check_b(rlog.ld(2), x"00", "8a: read2 injected (hi=00)");
        check_b(rlog.la(3), x"0000", "8a: read3 at 0000 (real, window closed)");
        check_b(rlog.ld(3), x"C3", "8a: read3 real C3");
        check_b(rlog.ld(4), x"00", "8a: read4 real");
        check(mem.rd(16#8000#) /= x"00", "8a: reached the real 0100 loop");

        -- 8b: G FFFF -> HALT
        park("8b");
        g_go(x"FFFF", true, "8b");
        expect_done("8b");
        clks(300);
        check(halt_n = '0', "8b: halted at FFFF");
        check_inject_log(x"FFFF", "8b");

        -- 8c: G C3C3 (target low byte equals the JP opcode) -> HALT
        park("8c");
        g_go(x"C3C3", true, "8c");
        expect_done("8c");
        clks(300);
        check(halt_n = '0', "8c: halted at C3C3");
        check_inject_log(x"C3C3", "8c");

        -- ============ 9. vent minimum width, short FW pulse =================
        report "case 9: minimum vent after a 1-clk pulse";
        park("9");
        arm <= '0';
        z_reset_n <= '0';  clks(1);
        t0 := now;
        z_reset_n <= '1';  busrq_n <= '1';
        wait until t80_rst_n = '1' for 5 us;
        check(now - t0 >= 700 ns, "9: >= 7 cen after a 1-clk request");
        check(now - t0 <= 1000 ns, "9: vent not stretched beyond ~8 cen");
        clks(2000);
        check(halt_n = '1', "9: CPU recovered (real boot) after HALT");

        -- ------------------------------------------------------ summary ----
        if errors = 0 then
            report "tb_tramp: ALL " & integer'image(cases) & " CHECKS PASSED";
        else
            report "tb_tramp: " & integer'image(errors) & " of " &
                   integer'image(cases) & " CHECKS FAILED" severity failure;
        end if;
        stop_sim <= true;
        wait;
    end process;

end architecture sim;

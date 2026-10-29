-- tb_mem_client.vhd -- M3 (R40): ssp_mem_client unit bench.
--
-- The client sits behind the CPM's 2:1 output mux, so the bench builds the same
-- mux (borrow ? client : primary) in front of a mock SDRAM controller and plays
-- the CPM primary FSM with a small model of its own (levels held until ready,
-- prim_idle low while it is busy).  The mock controller enforces the request
-- protocol the real one needs (MrZ80.sv request-level synchroniser):
--   * a request level is held until ready, with addr/data/direction stable;
--   * two requests are separated by >= 3 clk of low level (no merging);
--   * ready is a 1-clk pulse after a random / stretched latency; read data is
--     on dout >= 2 clk before it.
-- Memory oracle: sparse, unwritten bytes read as a hash of the address.
--
-- Checks (R-27 minus the BRAM legs):
--   1  parked byte fidelity, random SDRAM-window addresses incl. odd, vs oracle
--   2  parked = 0: every attempt answered done+err, ZERO client wire activity,
--      while a busy primary FSM keeps using the controller
--   3  primary FSM busy at admission: the client waits and then runs; stuck
--      busy longer than ADMIT_TO -> err with no wire activity
--   4  phys[27] = 1 (block-RAM page and above) -> err, no wire activity
--   5  refresh-style stalls (long latency) complete; a controller that never
--      answers -> OP_TO error, level dropped, recovery afterwards
--   6  back-to-back ops: gap honoured, one controller transaction per op;
--      a request level left high after done never replays
--   7  reset mid-wait: level drops at once, no done afterwards, re-admit works
--   8  mutual exclusion: never primary AND client strobes together; borrow
--      toggles only while all strobes are low
--   9  done/err are exactly 1 clk, err only together with done
--   10 parked dropping mid-op: the op finishes (cannot be recalled) and is
--      reported as an error
-- Run from the project root:  sim/run_mem_client.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_mem_client is
    generic (
        ADMIT_TO : natural := 300;
        OP_TO    : natural := 2000
    );
end tb_mem_client;

architecture sim of tb_mem_client is

    -- ------------------------------------------------------ memory model ----
    type mem_pt is protected
        procedure wr(a : natural; d : std_logic_vector(7 downto 0));
        impure function rd(a : natural) return std_logic_vector;
        impure function known(a : natural) return boolean;
    end protected;

    type mem_pt is protected body
        constant N : natural := 6000;
        type na_t is array (0 to N - 1) of natural;
        type nd_t is array (0 to N - 1) of std_logic_vector(7 downto 0);
        variable ka : na_t;
        variable kd : nd_t;
        variable cnt : natural := 0;
        impure function find(a : natural) return integer is
        begin
            for i in 0 to cnt - 1 loop
                if ka(i) = a then return i; end if;
            end loop;
            return -1;
        end function;
        procedure wr(a : natural; d : std_logic_vector(7 downto 0)) is
            variable i : integer;
        begin
            i := find(a);
            if i >= 0 then kd(i) := d;
            elsif cnt < N then ka(cnt) := a; kd(cnt) := d; cnt := cnt + 1;
            end if;
        end procedure;
        impure function rd(a : natural) return std_logic_vector is
            variable i : integer;
            variable v : unsigned(7 downto 0);
        begin
            i := find(a);
            if i >= 0 then return kd(i); end if;
            v := to_unsigned(a mod 256, 8) xor to_unsigned((a / 256) mod 256, 8)
                 xor to_unsigned((a / 65536) mod 256, 8) xor x"5A";
            return std_logic_vector(v);
        end function;
        impure function known(a : natural) return boolean is
        begin return find(a) >= 0; end function;
    end protected body;

    type cnt_pt is protected
        procedure err(what : string);
        procedure chk;
        impure function errors return natural;
        impure function checks return natural;
    end protected;
    type cnt_pt is protected body
        variable e, k : natural := 0;
        procedure err(what : string) is
        begin
            e := e + 1;
            if e <= 25 then report "FAIL: " & what severity error; end if;
        end procedure;
        procedure chk is begin k := k + 1; end procedure;
        impure function errors return natural is begin return e; end function;
        impure function checks return natural is begin return k; end function;
    end protected body;

    shared variable mem : mem_pt;
    shared variable cnt : cnt_pt;

    -- ----------------------------------------------------------- signals ----
    signal clk       : std_logic := '0';
    signal stop_sim  : boolean := false;
    signal rst_n     : std_logic := '0';

    signal ph_req    : std_logic := '0';
    signal ph_we     : std_logic := '0';
    signal ph_addr   : std_logic_vector(27 downto 0) := (others => '0');
    signal ph_wdata  : std_logic_vector(7 downto 0) := (others => '0');
    signal ph_done, ph_err : std_logic;
    signal ph_rdata  : std_logic_vector(7 downto 0);
    signal parked    : std_logic := '0';
    signal prim_idle : std_logic := '1';

    signal c_addr    : std_logic_vector(26 downto 0);
    signal c_din     : std_logic_vector(7 downto 0);
    signal c_we, c_rd : std_logic;
    signal borrow    : std_logic;

    -- primary FSM model
    signal p_addr    : std_logic_vector(26 downto 0) := (others => '0');
    signal p_din     : std_logic_vector(7 downto 0) := (others => '0');
    signal p_we, p_rd : std_logic := '0';
    signal p_go      : std_logic := '0';
    signal p_go_we   : std_logic := '0';
    signal p_stuck   : std_logic := '0';     -- hold the primary "busy" without strobes
    signal p_cnt     : natural := 0;         -- primary transactions completed

    -- the CPM output mux and the mock controller
    signal o_addr    : std_logic_vector(26 downto 0);
    signal o_din     : std_logic_vector(7 downto 0);
    signal o_we, o_rd : std_logic;
    signal dout      : std_logic_vector(7 downto 0) := x"00";
    signal ready     : std_logic := '0';

    -- controller knobs / statistics
    signal lat_min, lat_max : natural := 4;
    signal lat_force : natural := 0;         -- one-shot latency for the next transaction
    signal ctl_dead  : std_logic := '0';     -- never answer
    signal n_trans   : natural := 0;         -- transactions begun by the controller
    signal n_trans_c : natural := 0;         -- ... of which borrowed (borrow = 1)
    signal n_wr_cap  : natural := 0;
    signal c_act_cnt : natural := 0;         -- client strobe-clocks (any)
    signal c_act_en  : boolean := true;      -- counting enabled (checked by stim)
    signal n_abort   : natural := 0;

    -- done/err monitor
    signal n_done, n_dnerr : natural := 0;
    signal done_q    : std_logic := '0';

begin

    clk <= not clk after 10 ns when not stop_sim else '0';

    dut : entity work.ssp_mem_client
        generic map (ADMIT_TO => ADMIT_TO, OP_TO => OP_TO, GAP => 3)
        port map (clk => clk, rst_n => rst_n,
                  ph_req => ph_req, ph_we => ph_we, ph_addr => ph_addr,
                  ph_wdata => ph_wdata, ph_done => ph_done, ph_err => ph_err,
                  ph_rdata => ph_rdata, parked => parked, prim_idle => prim_idle,
                  c_addr => c_addr, c_din => c_din, c_we => c_we, c_rd => c_rd,
                  c_dout => dout, c_ready => ready, borrow => borrow);

    -- the CPM 2:1 select on the four output drivers
    o_addr <= c_addr when borrow = '1' else p_addr;
    o_din  <= c_din  when borrow = '1' else p_din;
    o_we   <= c_we   when borrow = '1' else p_we;
    o_rd   <= c_rd   when borrow = '1' else p_rd;

    -- --------------------------------------------- primary FSM stand-in ----
    -- p_go starts one transaction (levels held until ready, then 3 clk gap);
    -- prim_idle is low from the same edge until the gap has ended.
    prim : process (clk)
        variable st  : natural := 0;       -- 0 idle, 1 wait ready, 2 gap
        variable gap : natural := 0;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                st := 0; p_we <= '0'; p_rd <= '0'; prim_idle <= '1';
            else
                case st is
                    when 0 =>
                        if p_stuck = '1' then
                            prim_idle <= '0';
                        elsif p_go = '1' and borrow = '0' then
                            p_addr <= std_logic_vector(unsigned(p_addr) + 12345);
                            p_din  <= std_logic_vector(unsigned(p_din) + 7);
                            p_we   <= p_go_we;  p_rd <= not p_go_we;
                            prim_idle <= '0';  st := 1;
                        else
                            prim_idle <= '1';
                        end if;
                    when 1 =>
                        if ready = '1' then
                            p_we <= '0'; p_rd <= '0'; gap := 2; st := 2;
                            p_cnt <= p_cnt + 1;
                        end if;
                    when others =>
                        if gap = 0 then prim_idle <= '1'; st := 0;
                        else gap := gap - 1; end if;
                end case;
            end if;
        end if;
    end process;

    -- ------------------------------------------------ mock controller ----
    ctl : process (clk)
        variable cyc      : natural := 0;
        variable busy     : boolean := false;
        variable await_lo : boolean := false;
        variable last_fall : integer := -100;
        variable a        : std_logic_vector(26 downto 0);
        variable d        : std_logic_vector(7 downto 0);
        variable w        : boolean;
        variable ncl      : natural;
        variable lat      : natural;
        variable lvl      : boolean;
        variable seed1    : positive := 77;
        variable seed2    : positive := 5;
        variable r        : real;
        variable bor      : boolean;
    begin
        if rising_edge(clk) then
            cyc := cyc + 1;
            ready <= '0';
            lvl := (o_we = '1' or o_rd = '1');
            if rst_n = '0' then
                busy := false; await_lo := false; last_fall := -100;
            elsif busy then
                if not lvl then
                    busy := false; last_fall := cyc; n_abort <= n_abort + 1;
                else
                    if o_addr /= a or (o_we = '1') /= w then
                        cnt.err("controller: request changed while pending");
                    end if;
                    if w and o_din /= d then
                        cnt.err("controller: write data changed while pending");
                    end if;
                    ncl := ncl + 1;
                    if (not w) and ncl = lat - 2 then
                        dout <= mem.rd(to_integer(unsigned(a)));
                    end if;
                    if ncl >= lat and ctl_dead = '0' then
                        ready <= '1';
                        if w then
                            mem.wr(to_integer(unsigned(a)), d);
                            n_wr_cap <= n_wr_cap + 1;
                        end if;
                        busy := false; await_lo := true;
                    end if;
                end if;
            elsif await_lo then
                if not lvl then
                    await_lo := false; last_fall := cyc;
                end if;
            elsif lvl then
                if cyc - last_fall < 3 then
                    cnt.err("controller: requests merged (low gap " &
                            integer'image(cyc - last_fall) & " clk < 3)");
                end if;
                busy := true;
                a := o_addr; d := o_din; w := (o_we = '1');
                ncl := 0;
                if lat_force > 0 then
                    lat := lat_force;
                else
                    uniform(seed1, seed2, r);
                    lat := lat_min + natural(floor(r * real(lat_max - lat_min + 1)));
                    if lat > lat_max then lat := lat_max; end if;
                end if;
                if lat < 3 then lat := 3; end if;
                n_trans <= n_trans + 1;
                if borrow = '1' then n_trans_c <= n_trans_c + 1; end if;
            end if;
        end if;
    end process;

    -- ------------------------------------------------ continuous monitors ----
    mon : process (clk)
        variable b_q    : std_logic := '0';
        variable lv_q   : boolean := false;     -- any strobe, previous clk
        variable pl, cl : boolean;
    begin
        if rising_edge(clk) then
            pl := (p_we = '1' or p_rd = '1');
            cl := (c_we = '1' or c_rd = '1');
            -- 8: mutual exclusion
            cnt.chk;
            if pl and cl then cnt.err("mutual exclusion: primary and client strobes together"); end if;
            -- 8: borrow toggles only while every strobe was low the clk before
            if borrow /= b_q and rst_n = '1' then
                cnt.chk;
                if lv_q then cnt.err("borrow toggled while a strobe was high"); end if;
            end if;
            -- client wires quiet unless borrowed
            cnt.chk;
            if cl and borrow = '0' then cnt.err("client strobe without borrow"); end if;
            -- 2: a client strobe with parked low (a lost-park op is allowed to finish)
            if cl and c_act_en then c_act_cnt <= c_act_cnt + 1; end if;
            -- 9: pulse widths
            done_q <= ph_done;
            if ph_done = '1' then n_done <= n_done + 1; end if;
            if ph_err = '1' then
                cnt.chk;
                if ph_done = '0' then cnt.err("ph_err without ph_done"); end if;
                n_dnerr <= n_dnerr + 1;
            end if;
            if ph_done = '1' and done_q = '1' then cnt.err("ph_done wider than 1 clk"); end if;
            b_q := borrow;
            lv_q := pl or cl;
        end if;
    end process;

    -- --------------------------------------------------------------- stim ----
    stim : process
        variable seed1 : positive := 2026;
        variable seed2 : positive := 29;
        variable r     : real;
        variable base_t, base_c : natural;
        variable rd    : std_logic_vector(7 downto 0);
        variable got_done, got_err : boolean;
        variable a28   : std_logic_vector(27 downto 0);
        variable d8    : std_logic_vector(7 downto 0);
        variable ncl   : natural;
        variable act0  : natural := 0;

        procedure clks(n : natural) is
        begin for i in 1 to n loop wait until rising_edge(clk); end loop; end procedure;

        procedure check(ok : boolean; what : string) is
        begin cnt.chk; if not ok then cnt.err(what); end if; end procedure;

        procedure rnd(maxv : natural; v : out natural) is
        begin
            uniform(seed1, seed2, r);
            v := natural(floor(r * real(maxv + 1)));
            if v > maxv then v := maxv; end if;
        end procedure;

        -- one op: raise the level, wait for the done pulse, drop the level after
        -- `hold_after` clk (0 = the clk after done).  Returns done/err/rdata.
        procedure op(we : std_logic; a : std_logic_vector(27 downto 0);
                     d : std_logic_vector(7 downto 0);
                     hold_after : natural;
                     d_ok : out boolean; e_out : out boolean;
                     rdat : out std_logic_vector(7 downto 0);
                     tmo : natural := 20000) is
            variable t : natural := 0;
        begin
            ph_we <= we; ph_addr <= a; ph_wdata <= d;
            ph_req <= '1';
            d_ok := false; e_out := false; rdat := x"00";
            loop
                wait until rising_edge(clk);
                t := t + 1;
                if ph_done = '1' then
                    d_ok := true; e_out := (ph_err = '1'); rdat := ph_rdata;
                    exit;
                end if;
                if t > tmo then exit; end if;
            end loop;
            clks(hold_after);
            ph_req <= '0';
            clks(1);
        end procedure;

        -- parked, primary idle: do op, expect success; compare against the oracle
        procedure op_ok(we : std_logic; a : std_logic_vector(27 downto 0);
                        d : std_logic_vector(7 downto 0); hold_after : natural;
                        what : string) is
            variable dn, er : boolean;
            variable rv     : std_logic_vector(7 downto 0);
            variable exp    : std_logic_vector(7 downto 0);
        begin
            if we = '0' then exp := mem.rd(to_integer(unsigned(a(26 downto 0)))); end if;
            op(we, a, d, hold_after, dn, er, rv);
            check(dn, what & ": no done");
            check(not er, what & ": unexpected error");
            if we = '0' then
                check(rv = exp, what & ": read " & to_hstring(a) & " got " & to_hstring(rv) &
                      " expected " & to_hstring(exp));
            end if;
        end procedure;

        procedure rand_addr(w28 : boolean; a : out std_logic_vector(27 downto 0)) is
            variable v : natural;
            variable x : std_logic_vector(27 downto 0);
        begin
            -- 27-bit window, biased to a few hundred distinct bytes so that
            -- read-after-write really happens, odd addresses included
            rnd(255, v);
            x := (others => '0');
            x(26 downto 0) := std_logic_vector(to_unsigned(v * 524287 + (v mod 3) * 3, 27));
            if v mod 7 = 0 then x(26 downto 24) := "111"; end if;
            if w28 then x(27) := '1'; end if;
            a := x;
        end procedure;

        function bit1(v : natural) return std_logic is
        begin if v mod 2 = 1 then return '1'; else return '0'; end if; end function;

        procedure do_reset is
        begin
            rst_n <= '0'; clks(4); rst_n <= '1'; clks(4);
        end procedure;

        variable dn, er : boolean;
        variable v1, v2 : natural;
    begin
        rst_n <= '0';
        clks(5);
        rst_n <= '1';
        clks(5);

        -- ================= 1: parked fidelity ===================================
        report "1: parked byte fidelity";
        parked <= '1';
        lat_min <= 4; lat_max <= 14;
        clks(3);
        for i in 1 to 400 loop
            rand_addr(false, a28);
            rnd(255, v1);
            d8 := std_logic_vector(to_unsigned(v1, 8));
            rnd(2, v2);
            if i mod 2 = 0 then
                op_ok('1', a28, d8, v2, "write");
                op_ok('0', a28, x"00", v2, "readback");
            else
                op_ok('0', a28, x"00", v2, "read");
            end if;
        end loop;
        check(n_wr_cap = 200, "1: the controller captured 200 writes (got " & integer'image(n_wr_cap) & ")");
        -- every odd/even byte address pair independent
        op_ok('1', x"0012345", x"A5", 0, "odd write");
        op_ok('1', x"0012344", x"5A", 0, "even write");
        op_ok('0', x"0012345", x"00", 0, "odd read");
        check(mem.rd(16#12345#) = x"A5" and mem.rd(16#12344#) = x"5A", "1: odd/even bytes independent");
        -- last SDRAM byte
        op_ok('1', x"7FFFFFF", x"C3", 0, "top of the window");
        op_ok('0', x"7FFFFFF", x"00", 0, "top of the window read");
        check(n_trans_c = n_trans - p_cnt, "1: every controller transaction was borrowed or the model's");

        -- ================= 9/6: pulse widths and back-to-back ===================
        report "6: back-to-back, level left high";
        base_t := n_trans; base_c := n_trans_c;
        for i in 1 to 40 loop
            op_ok('1', std_logic_vector(to_unsigned(1000 + i, 28)), std_logic_vector(to_unsigned(i, 8)), 0, "b2b");
        end loop;
        check(n_trans - base_t = 40, "6: one controller transaction per op (40, got " &
              integer'image(n_trans - base_t) & ")");
        -- level held 100 clk after done: no replay
        base_t := n_trans;
        op('1', x"0000777", x"11", 100, dn, er, rd);
        check(dn and not er, "6: op with a long-held level completed");
        clks(20);
        check(n_trans - base_t = 1, "6: a level left high after done is not replayed (" &
              integer'image(n_trans - base_t) & " transactions)");
        -- dropped, raised again for the same op: a new transaction
        op_ok('0', x"0000777", x"00", 0, "re-read");
        check(mem.rd(16#777#) = x"11", "6: the held-high write landed once");

        -- ================= 2: parked = 0 =======================================
        report "2: not parked -> error, zero client wire activity";
        base_c := n_trans_c;
        parked <= '0';
        clks(3);
        act0 := c_act_cnt;
        base_t := n_trans;
        for i in 1 to 100 loop
            -- the primary FSM is busy using the controller meanwhile
            p_go_we <= '1'; p_go <= '1'; clks(1); p_go <= '0';
            rand_addr(false, a28);
            rnd(1, v1);
            op(bit1(v1), a28, x"77", 0, dn, er, rd);
            check(dn and er, "2: not parked -> done+err (attempt " & integer'image(i) & ")");
            clks(8);
        end loop;
        clks(40);
        check(c_act_cnt = act0, "2: ZERO client strobe activity while parked = 0 (saw " &
              integer'image(c_act_cnt - act0) & " clk)");
        check(n_trans_c = base_c and n_trans - base_t >= 50,
              "2: only the primary FSM used the controller (" & integer'image(n_trans - base_t) & ")");
        check(borrow = '0', "2: borrow low");
        parked <= '1';
        clks(3);

        -- ================= 4: window ===========================================
        report "4: phys[27] = 1 rejected";
        act0 := c_act_cnt; base_t := n_trans;
        for i in 1 to 40 loop
            rand_addr(true, a28);
            rnd(1, v1);
            op(bit1(v1), a28, x"99", 0, dn, er, rd);
            check(dn and er, "4: page >= 8192 -> done+err");
        end loop;
        op('0', x"8000000", x"00", 0, dn, er, rd);
        check(dn and er, "4: 0x0800_0000 (the BRAM page) -> err");
        op('1', x"FFFFFFF", x"00", 0, dn, er, rd);
        check(dn and er, "4: 0x0FFF_FFFF -> err");
        check(c_act_cnt = act0 and n_trans = base_t, "4: no wire activity for a rejected address");
        op_ok('0', x"7FFFFFF", x"00", 0, "4: last window byte still fine");

        -- ================= 3: primary FSM busy at admission ====================
        report "3: primary FSM busy -> wait, then run; stuck -> err";
        -- primary transaction in flight (latency 60) when the request arrives
        clks(8);
        lat_force <= 60;
        p_go_we <= '1'; p_go <= '1'; clks(1); p_go <= '0';
        clks(2);
        base_c := n_trans_c; act0 := c_act_cnt;
        ph_we <= '1'; ph_addr <= x"0000A01"; ph_wdata <= x"3C"; ph_req <= '1';
        clks(30);
        check(c_act_cnt = act0 and ph_done = '0', "3: no wire activity while the primary FSM is busy");
        lat_force <= 0;
        loop
            wait until rising_edge(clk);
            exit when ph_done = '1';
        end loop;
        check(ph_err = '0', "3: admitted and completed after the primary FSM idled");
        clks(1); ph_req <= '0'; clks(3);
        check(mem.rd(16#A01#) = x"3C", "3: the write landed");
        check(n_trans_c = base_c + 1, "3: exactly one borrowed transaction");
        -- stuck busy longer than ADMIT_TO
        p_stuck <= '1'; clks(4);
        act0 := c_act_cnt; base_t := n_trans;
        op('0', x"0000A02", x"00", 0, dn, er, rd);
        check(dn and er, "3: primary FSM stuck busy -> admission timeout error");
        check(c_act_cnt = act0 and n_trans = base_t, "3: no wire activity on an admission timeout");
        p_stuck <= '0'; clks(6);
        op_ok('0', x"0000A01", x"00", 0, "3: recovered after the primary FSM idled");

        -- ================= 5: stalls and a dead controller =====================
        report "5: stalls and OP_TO";
        lat_force <= 900;
        op_ok('1', x"0000B00", x"E7", 0, "stalled write (900 clk)");
        op_ok('0', x"0000B00", x"00", 0, "stalled read (900 clk)");
        lat_force <= 0;
        lat_min <= 4; lat_max <= 40;
        for i in 1 to 40 loop
            op_ok('0', std_logic_vector(to_unsigned(i * 977, 28)), x"00", 0, "jittery read");
        end loop;
        lat_min <= 4; lat_max <= 14;
        -- dead controller: OP_TO error, level dropped, then recovery
        ctl_dead <= '1';
        base_t := n_trans; v1 := n_abort;
        op('0', x"0000C00", x"00", 0, dn, er, rd, 100000);
        check(dn and er, "5: a controller that never answers -> OP_TO error");
        clks(10);
        check(n_abort = v1 + 1, "5: the request level was dropped on the timeout");
        ctl_dead <= '0';
        clks(5);
        op_ok('0', x"0000A01", x"00", 0, "5: recovered after the timeout");

        -- ================= 7: reset mid-wait ===================================
        report "7: reset mid-op";
        lat_force <= 500;
        ph_we <= '1'; ph_addr <= x"0000D00"; ph_wdata <= x"44"; ph_req <= '1';
        clks(100);
        check(borrow = '1' and c_we = '1', "7: write pending in the controller");
        v1 := n_done;
        rst_n <= '0';
        clks(2);
        check(c_we = '0' and c_rd = '0' and borrow = '0', "7: reset drops the level and the borrow");
        clks(4); rst_n <= '1';
        ph_req <= '0';
        clks(700);
        check(n_done = v1, "7: no done after the reset");
        check(mem.rd(16#D00#) /= x"44", "7: the aborted write never reached memory");
        lat_force <= 0;
        clks(5);
        op_ok('1', x"0000D00", x"45", 0, "7: re-admit after reset");
        op_ok('0', x"0000D00", x"00", 0, "7: and read back");

        -- ================= 10: parked drops mid-op =============================
        report "10: park lost mid-op";
        lat_force <= 100;
        ph_we <= '1'; ph_addr <= x"0000E00"; ph_wdata <= x"66"; ph_req <= '1';
        clks(40);
        parked <= '0';
        loop
            wait until rising_edge(clk);
            exit when ph_done = '1';
        end loop;
        check(ph_err = '1', "10: lost park reported as an error");
        check(mem.rd(16#E00#) = x"66", "10: the in-flight write was allowed to finish");
        clks(1); ph_req <= '0'; clks(6);
        lat_force <= 0;
        parked <= '1'; clks(3);

        -- ================= final ===============================================
        clks(20);
        if cnt.errors = 0 then
            report "tb_mem_client: ALL " & integer'image(cnt.checks) & " CHECKS PASSED";
        else
            report "tb_mem_client: " & integer'image(cnt.errors) & " of " &
                   integer'image(cnt.checks) & " CHECKS FAILED" severity failure;
        end if;
        stop_sim <= true;
        wait;
    end process;

end architecture sim;

-- tb_integ_mux.vhd -- R-42: z80_bus_mux (D-26) with the REAL T80s and an SSP-engine
-- model, behind a memory/I-O fabric model.
--
-- Checked every clock:
--   * running (no BusAck, engine idle): every guest net equals the T80's;
--   * parked, engine idle: MREQ/IORQ/RD/WR/M1 and MRD_T1 are idle -- the T80's
--     frozen strobes must not reach the fabric (R25/M1; a stuck MRD_T1 would
--     retrigger the SDRAM client every clock);
--   * engine cycle: every guest net equals the engine's;
--   * the select (hierarchical name z80_bus_mux.sel_eng) is never set without
--     BusAck.
-- And at the end: the T80's program result and every engine access are exact --
-- the engine writes memory/I-O through the mux and reads back what it wrote, the
-- T80 program (a 120-step running sum with memory writes, reads and OUTs) is
-- undisturbed (result, per-iteration memory, exact OUT and write-cycle counts),
-- i.e. no lost, doubled or glitched strobe at any select change.
--
-- The engine model is the bridge's cycle FSM (ssp_bridge.v, T-state per cpu_cen);
-- its pin waveform is compared against sim/ssp/golden_cycles.txt (captured from
-- the real T80 by sim/tb_cycle_golden.vhd), and the real bridge engine is held
-- to the same file by sim/ssp/p1a_engine_golden.sh -- so bridge == golden == T80.
--
-- Two phases: production parking (grant at an instruction boundary) and
-- FREEZE_any = 1 (grant at any T_Res: the off-boundary step-mode shape of P1b,
-- which freezes the T80 mid-instruction and so stresses the idle gate).
--
-- Mutation results on z80_bus_mux (MUX=<mutant> sim/run_integ_mux.sh), R31: CAUGHT --
-- engine never selected; select without BusAck (needs the directed premature-
-- request test); select stuck on the engine after its cycle; cpu_dout / MRD_T1
-- not switched.  SURVIVE, and understood: the idle-gating of MREQ/IORQ/RD/WR/M1
-- while parked -- a T80 grant (instruction boundary or FREEZE_any T_Res) always
-- finds the strobes already released, so the gate is defence in depth only.

-- Run from the project root:  sim/run_integ_mux.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_integ_mux is
    generic (GOLDEN : string := "sim/ssp/golden_cycles.txt");
end tb_integ_mux;

architecture sim of tb_integ_mux is

    -- ---------------------------------------------------- shared state ----
    type mem_pt is protected
        procedure init;
        procedure wr(a : natural; d : std_logic_vector(7 downto 0));
        impure function rd(a : natural) return std_logic_vector;
    end protected;

    type mem_pt is protected body
        type arr_t is array (0 to 65535) of std_logic_vector(7 downto 0);
        variable m : arr_t := (others => x"00");
        procedure init is
            -- LD SP,F000 ; LD HL,8300 ; XOR A ; LD B,120
            -- L: ADD A,B ; LD (HL),A ; LD E,(HL) ; INC HL ; OUT (AA),A ; DJNZ L
            -- LD (8200),A ; HALT
            constant prog : std_logic_vector(0 to 8 * 21 - 1) :=
                x"3100F0" & x"210083" & x"AF" & x"0678" & x"80" & x"775E" &
                x"23" & x"D3AA" & x"10F8" & x"320082" & x"76";
        begin
            m := (others => x"00");
            for i in 0 to 20 loop
                m(i) := prog(i * 8 to i * 8 + 7);
            end loop;
        end procedure;
        procedure wr(a : natural; d : std_logic_vector(7 downto 0)) is
        begin m(a) := d; end procedure;
        impure function rd(a : natural) return std_logic_vector is
        begin return m(a); end function;
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

    -- fabric-side cycle counters (written by the fabric process, cleared by stim)
    type fab_pt is protected
        procedure clear;
        procedure add_wr;
        procedure add_aa;
        procedure add_bb(d : std_logic_vector(7 downto 0));
        impure function wr_cycles return natural;
        impure function io_aa return natural;
        impure function io_bb return natural;
        impure function last_bb return std_logic_vector;
    end protected;
    type fab_pt is protected body
        variable w, aa, bb : natural := 0;
        variable lb : std_logic_vector(7 downto 0) := x"00";
        procedure clear is begin w := 0; aa := 0; bb := 0; end procedure;
        procedure add_wr is begin w := w + 1; end procedure;
        procedure add_aa is begin aa := aa + 1; end procedure;
        procedure add_bb(d : std_logic_vector(7 downto 0)) is
        begin bb := bb + 1; lb := d; end procedure;
        impure function wr_cycles return natural is begin return w; end function;
        impure function io_aa return natural is begin return aa; end function;
        impure function io_bb return natural is begin return bb; end function;
        impure function last_bb return std_logic_vector is begin return lb; end function;
    end protected body;

    shared variable mem : mem_pt;
    shared variable cnt : cnt_pt;
    shared variable fab : fab_pt;

    -- golden vectors by kind ("memrd", "memwr_w1", ...)
    type gold_pt is protected
        procedure load(fname : string);
        impure function get(kind : string) return string;
    end protected;
    type gold_pt is protected body
        type str_acc is access string;
        type entry is record
            k : str_acc;
            v : str_acc;
        end record;
        type tab_t is array (0 to 15) of entry;
        variable tab : tab_t;
        variable n : natural := 0;
        procedure load(fname : string) is
            file f : text;
            variable l : line;
            variable st : file_open_status;
            variable i : natural;
        begin
            file_open(st, f, fname, read_mode);
            assert st = open_ok report "cannot open " & fname severity failure;
            while not endfile(f) loop
                readline(f, l);
                if l.all'length > 0 and l.all(l.all'left) /= '#' then
                    i := l.all'left;
                    while l.all(i) /= ' ' loop i := i + 1; end loop;
                    tab(n).k := new string'(l.all(l.all'left to i - 1));
                    tab(n).v := new string'(l.all(i to l.all'right));
                    n := n + 1;
                end if;
            end loop;
            file_close(f);
        end procedure;
        impure function get(kind : string) return string is
        begin
            for j in 0 to n - 1 loop
                if tab(j).k.all = kind then return tab(j).v.all; end if;
            end loop;
            return "NOT FOUND";
        end function;
    end protected body;
    shared variable gold : gold_pt;

    -- ---------------------------------------------------------- signals ----
    signal clk      : std_logic := '0';
    signal cen_ph   : natural range 0 to 4 := 0;
    signal cen      : std_logic;
    signal stop_sim : boolean := false;

    signal rst_n    : std_logic := '0';
    signal busrq_n  : std_logic := '1';
    signal fz_any   : std_logic := '0';

    -- T80 side
    signal t_m1_n, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_rfsh_n, t_halt_n, t_busak_n, t_mrd_t1 : std_logic;
    signal t_a      : std_logic_vector(15 downto 0);
    signal t_do     : std_logic_vector(7 downto 0);
    signal wait_n   : std_logic := '1';

    -- engine side
    signal e_own    : std_logic := '0';
    signal force_own : std_logic := '0';      -- protocol-violating engine request (stim)
    signal e_own_m  : std_logic;
    signal e_addr   : std_logic_vector(15 downto 0) := x"FFFF";
    signal e_dout   : std_logic_vector(7 downto 0) := x"00";
    signal e_mreq_n, e_iorq_n, e_rd_n, e_wr_n, e_m1_n : std_logic := '1';
    signal e_mrd_t1 : std_logic := '0';

    -- guest nets (mux outputs)
    signal c_addr   : std_logic_vector(15 downto 0);
    signal c_dout   : std_logic_vector(7 downto 0);
    signal c_mreq_n, c_iorq_n, c_rd_n, c_wr_n, c_m1_n, c_mrd_t1 : std_logic;
    signal din, di_raw : std_logic_vector(7 downto 0) := x"00";

    -- engine command interface
    signal e_kick   : boolean := false;
    signal e_kind   : natural := 0;                    -- 0 memrd 1 memwr 2 iord 3 iowr
    signal e_kaddr  : std_logic_vector(15 downto 0) := x"0000";
    signal e_kdata  : std_logic_vector(7 downto 0) := x"00";
    signal e_wait1  : boolean := false;                -- one wait state in T2
    signal e_busy   : boolean := false;
    signal e_rdcap  : std_logic_vector(7 downto 0) := x"00";

    -- fabric counters
    signal run_chk  : boolean := false;
    signal wcnt     : natural := 0;
    signal act, act_q : std_logic := '0';
    signal wait_k   : natural := 0;
    signal wsel     : std_logic;

begin

    clk <= not clk after 10 ns when not stop_sim else '0';
    process (clk)
    begin
        if rising_edge(clk) then
            if cen_ph = 4 then cen_ph <= 0; else cen_ph <= cen_ph + 1; end if;
        end if;
    end process;
    cen <= '1' when cen_ph = 2 else '0';

    -- ------------------------------------------------------------- DUTs ----
    cpu : entity work.T80s
        generic map (Mode => 1, T2Write => 1, IOWait => 0)
        port map (
            RESET_n => rst_n, CLK_n => clk, CEN => cen,
            WAIT_n => wait_n, INT_n => '1', NMI_n => '1', BUSRQ_n => busrq_n,
            M1_n => t_m1_n, MREQ_n => t_mreq_n, IORQ_n => t_iorq_n,
            RD_n => t_rd_n, WR_n => t_wr_n, RFSH_n => t_rfsh_n,
            HALT_n => t_halt_n, BUSAK_n => t_busak_n,
            A => t_a, DI => din, DO => t_do, MRD_T1 => t_mrd_t1,
            FREEZE_req_n => '1', FREEZE_any => fz_any);

    mux : entity work.z80_bus_mux
        port map (
            clk => clk, rst_n => rst_n,
            t80_addr => t_a, t80_dout => t_do,
            t80_mreq_n => t_mreq_n, t80_iorq_n => t_iorq_n,
            t80_rd_n => t_rd_n, t80_wr_n => t_wr_n, t80_m1_n => t_m1_n,
            t80_mrd_t1 => t_mrd_t1, t80_busack_n => t_busak_n,
            busrq_n => busrq_n,
            eng_own => e_own_m, eng_addr => e_addr, eng_dout => e_dout,
            eng_mreq_n => e_mreq_n, eng_iorq_n => e_iorq_n,
            eng_rd_n => e_rd_n, eng_wr_n => e_wr_n, eng_m1_n => e_m1_n,
            eng_mrd_t1 => e_mrd_t1,
            cpu_addr => c_addr, cpu_dout => c_dout,
            cpu_mreq_n => c_mreq_n, cpu_iorq_n => c_iorq_n,
            cpu_rd_n => c_rd_n, cpu_wr_n => c_wr_n, cpu_m1_n => c_m1_n,
            cpu_mrd_t1 => c_mrd_t1);

    e_own_m <= e_own or force_own;
    wsel <= << signal .tb_integ_mux.mux.sel_eng : std_logic >>;

    -- ----------------------------------------------------- memory + I/O ----
    -- The fabric sees ONLY the guest nets (the mux outputs).  1-clk registered
    -- read; writes idempotent while the strobes are low; I/O read = port ^ 3C.
    process (clk)
        variable prev_wr, prev_iowr : std_logic := '0';
        variable cur_wr, cur_iowr : std_logic;
    begin
        if rising_edge(clk) then
            di_raw <= mem.rd(to_integer(unsigned(c_addr)));
            cur_wr   := '1' when (c_mreq_n = '0' and c_wr_n = '0') else '0';
            cur_iowr := '1' when (c_iorq_n = '0' and c_wr_n = '0') else '0';
            if cur_wr = '1' then
                mem.wr(to_integer(unsigned(c_addr)), c_dout);
                if prev_wr = '0' then fab.add_wr; end if;
            end if;
            if cur_iowr = '1' and prev_iowr = '0' then
                if c_addr(7 downto 0) = x"AA" then fab.add_aa; end if;
                if c_addr(7 downto 0) = x"BB" then fab.add_bb(c_dout); end if;
            end if;
            prev_wr := cur_wr;  prev_iowr := cur_iowr;
        end if;
    end process;
    din <= (c_addr(7 downto 0) xor x"3C") when c_iorq_n = '0' else di_raw;

    -- wait states on the guest strobes: wait_k cpu_cen periods from the start
    -- of every read strobe while the T80 owns the bus; for the engine, one wait
    -- state (first cen period of the strobe) when e_wait1
    act <= '1' when (c_mreq_n = '0' or c_iorq_n = '0') and (c_rd_n = '0' or c_wr_n = '0') else '0';
    process (clk)
    begin
        if rising_edge(clk) then
            act_q <= act;
            if act = '1' and act_q = '0' then
                if wsel = '1' then
                    if e_wait1 then wcnt <= 5; else wcnt <= 0; end if;
                else
                    wcnt <= wait_k * 5;
                end if;
            elsif wcnt > 0 then wcnt <= wcnt - 1; end if;
        end if;
    end process;
    wait_n <= '0' when (act = '1' and wcnt > 0) else '1';

    -- ------------------------------------------------------ engine model ----
    -- ssp_bridge.v engine FSM: one T-state per cpu_cen (D-26).
    engine : process (clk)
        variable st : natural range 0 to 3 := 0;
        variable kind : natural;
        variable t_rd, t_io : boolean;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                st := 0; e_own <= '0'; e_mreq_n <= '1'; e_iorq_n <= '1';
                e_rd_n <= '1'; e_wr_n <= '1'; e_m1_n <= '1'; e_mrd_t1 <= '0';
                e_busy <= false;
            else
                case st is
                when 0 =>
                    if e_kick and t_busak_n = '0' then
                        kind := e_kind;
                        t_rd := (kind = 0 or kind = 2);
                        t_io := (kind = 2 or kind = 3);
                        e_own <= '1'; e_addr <= e_kaddr; e_dout <= e_kdata;
                        e_m1_n <= '1';
                        if t_rd and not t_io then e_mrd_t1 <= '1'; else e_mrd_t1 <= '0'; end if;
                        e_mreq_n <= '1'; e_iorq_n <= '1'; e_rd_n <= '1'; e_wr_n <= '1';
                        e_busy <= true;
                        st := 1;
                    end if;
                when 1 =>
                    if cen = '1' then
                        e_mrd_t1 <= '0';
                        if t_io then e_iorq_n <= '0'; else e_mreq_n <= '0'; end if;
                        if t_rd then e_rd_n <= '0'; else e_wr_n <= '0'; end if;
                        st := 2;
                    end if;
                when 2 =>
                    if cen = '1' and wait_n = '1' then
                        if t_rd then e_rdcap <= din; end if;
                        e_mreq_n <= '1'; e_iorq_n <= '1'; e_rd_n <= '1'; e_wr_n <= '1';
                        st := 3;
                    end if;
                when 3 =>
                    if cen = '1' then
                        e_own <= '0'; e_busy <= false;
                        st := 0;
                    end if;
                end case;
            end if;
        end if;
    end process engine;

    -- --------------------------------------------------------- checkers ----
    chk : process (clk)
        variable idle_clks : natural := 0;
    begin
        if rising_edge(clk) and run_chk then
            cnt.chk;
            -- the select returns to the T80 once the engine's cycle is done
            if e_own_m = '0' then idle_clks := idle_clks + 1; else idle_clks := 0; end if;
            if wsel = '1' and idle_clks >= 3 then
                cnt.err("select still on the engine after its cycle ended");
            end if;
            -- the select never flips without BusAck
            if wsel = '1' and t_busak_n /= '0' then
                cnt.err("select on the engine without BusAck");
            end if;
            if wsel = '1' then
                if c_addr /= e_addr or c_dout /= e_dout or c_mreq_n /= e_mreq_n or
                   c_iorq_n /= e_iorq_n or c_rd_n /= e_rd_n or c_wr_n /= e_wr_n or
                   c_m1_n /= e_m1_n or c_mrd_t1 /= e_mrd_t1 then
                    cnt.err("engine cycle: guest nets differ from the engine's");
                end if;
            elsif t_busak_n = '0' then
                if c_mreq_n /= '1' or c_iorq_n /= '1' or c_rd_n /= '1' or
                   c_wr_n /= '1' or c_m1_n /= '1' then
                    cnt.err("parked: a strobe leaks to the fabric (mreq/iorq/rd/wr/m1)");
                end if;
                if c_mrd_t1 /= '0' then
                    cnt.err("parked: MRD_T1 leaks to the fabric (SDRAM speculative trigger)");
                end if;
            else
                if c_addr /= t_a or c_dout /= t_do or c_mreq_n /= t_mreq_n or
                   c_iorq_n /= t_iorq_n or c_rd_n /= t_rd_n or c_wr_n /= t_wr_n or
                   c_m1_n /= t_m1_n or c_mrd_t1 /= t_mrd_t1 then
                    cnt.err("running: guest nets differ from the T80's");
                end if;
            end if;
        end if;
    end process chk;

    -- ------------------------------------------------------------- stim ----
    stim : process
        variable seed1 : positive := 20261027;
        variable seed2 : positive := 7;
        variable r     : real;
        variable engine_writes, engine_ops, engine_iowr : natural := 0;

        procedure clks(n : natural) is
        begin for i in 1 to n loop wait until rising_edge(clk); end loop; end procedure;

        procedure rnd(maxv : natural; v : out natural) is
        begin
            uniform(seed1, seed2, r);
            v := natural(floor(r * real(maxv + 1)));
            if v > maxv then v := maxv; end if;
        end procedure;

        procedure check(ok : boolean; what : string) is
        begin cnt.chk; if not ok then cnt.err(what); end if; end procedure;

        function vec(mreq, iorq, rd, wr, m1, t1 : std_logic) return string is
            function c(b : std_logic; low : boolean) return character is
            begin
                if low then if b = '0' then return '1'; else return '0'; end if;
                else if b = '1' then return '1'; else return '0'; end if; end if;
            end function;
        begin
            return c(mreq, true) & c(iorq, true) & c(rd, true) & c(wr, true) &
                   c(m1, true) & c(t1, false);
        end function;

        -- one engine cycle through the mux; compares the engine's pin waveform
        -- with the golden T80 vectors
        procedure eng_cycle(kind : natural; a : std_logic_vector(15 downto 0);
                            d : std_logic_vector(7 downto 0); w1 : boolean;
                            rdback : out std_logic_vector(7 downto 0)) is
            variable l : line;
            variable gname : line;
            variable started : boolean := false;
        begin
            case kind is
                when 0 => write(gname, string'("memrd"));
                when 1 => write(gname, string'("memwr"));
                when 2 => write(gname, string'("iord"));
                when others => write(gname, string'("iowr"));
            end case;
            if w1 then write(gname, string'("_w1")); end if;
            e_kind <= kind; e_kaddr <= a; e_kdata <= d; e_wait1 <= w1;
            e_kick <= true;
            clks(1);
            e_kick <= false;
            -- sample the engine pins at every cen edge while it owns the bus
            l := new string'("");
            while true loop
                wait until rising_edge(clk);
                if cen = '1' and e_own = '1' then
                    write(l, string'(" ") & vec(e_mreq_n, e_iorq_n, e_rd_n, e_wr_n, e_m1_n, e_mrd_t1));
                    started := true;
                end if;
                exit when started and e_own = '0';
            end loop;
            check(l.all = gold.get(gname.all),
                  "engine " & gname.all & " waveform " & l.all & " /= T80 golden " & gold.get(gname.all));
            clks(2);
            rdback := e_rdcap;
        end procedure;

        procedure engine_burst(w1_allowed : boolean) is
            variable n, k, ad : natural;
            variable a16 : std_logic_vector(15 downto 0);
            variable rb : std_logic_vector(7 downto 0);
            variable w : boolean;
            variable dv : natural;
        begin
            rnd(3, n);
            for i in 0 to n loop
                rnd(5, k);
                rnd(255, ad);
                rnd(1, dv);
                w := w1_allowed and dv = 1;
                case k is
                    when 0 | 1 =>                      -- memory write 9000+ad
                        a16 := std_logic_vector(to_unsigned(16#9000# + ad, 16));
                        eng_cycle(1, a16, std_logic_vector(to_unsigned((ad * 7 + 3) mod 256, 8)), w, rb);
                        engine_writes := engine_writes + 1;
                    when 2 =>                          -- memory read back of an engine write
                        a16 := std_logic_vector(to_unsigned(16#9000# + ad, 16));
                        eng_cycle(0, a16, x"00", w, rb);
                        if mem.rd(16#9000# + ad) = std_logic_vector(to_unsigned((ad * 7 + 3) mod 256, 8)) then
                            check(rb = mem.rd(16#9000# + ad), "engine memory read returns the stored byte");
                        end if;
                    when 3 =>                          -- read of static program memory
                        a16 := std_logic_vector(to_unsigned(ad mod 4, 16));
                        eng_cycle(0, a16, x"00", w, rb);
                        check(rb = mem.rd(to_integer(unsigned(a16))), "engine read of program memory");
                    when 4 =>                          -- I/O write, port BB
                        eng_cycle(3, x"00BB", std_logic_vector(to_unsigned(ad, 8)), w, rb);
                        engine_iowr := engine_iowr + 1;
                        check(fab.last_bb = std_logic_vector(to_unsigned(ad, 8)),
                              "engine I/O write: data reached the port");
                    when others =>                     -- I/O read, port 66
                        eng_cycle(2, x"0066", x"00", w, rb);
                        check(rb = x"5A", "engine I/O read returns port ^ 3C");
                end case;
                engine_ops := engine_ops + 1;
            end loop;
        end procedure;

        procedure run_phase(name : string; any_boundary : boolean; w1 : boolean) is
            variable gap, hold : natural;
            variable exp_a : unsigned(7 downto 0);
            variable bad : boolean;
        begin
            report "phase: " & name;
            fz_any <= '1' when any_boundary else '0';
            engine_writes := 0;  engine_ops := 0;  engine_iowr := 0;
            -- reset the CPU and the program image
            rst_n <= '0';  busrq_n <= '1';  run_chk <= false;
            clks(10);
            mem.init;
            fab.clear;
            clks(2);
            rst_n <= '1';
            clks(2);
            run_chk <= true;
            -- protocol violation: the engine claims the bus while BUSRQ is pending
            -- but the T80 has NOT yet granted (mid-instruction).  The select must
            -- wait for BusAck.
            for k in 1 to 12 loop
                rnd(40, gap);
                clks(gap);
                busrq_n <= '0';
                clks(1);
                if t_busak_n = '1' then
                    force_own <= '1';
                    while t_busak_n = '1' and t_halt_n = '1' loop
                        clks(1);
                        cnt.chk;
                        if wsel = '1' and t_busak_n = '1' then
                            cnt.err("select flipped to a premature engine request before BusAck");
                        end if;
                    end loop;
                    force_own <= '0';
                end if;
                clks(2);
                busrq_n <= '1';
                wait until t_busak_n = '1' for 5 us;
                clks(3);
            end loop;
            while t_halt_n = '1' loop
                rnd(80, gap);
                clks(gap);
                exit when t_halt_n = '0';
                busrq_n <= '0';
                wait until t_busak_n = '0' for 100 us;
                if t_busak_n /= '0' then
                    if t_halt_n = '1' then cnt.err(name & ": no BusAck"); end if;
                    busrq_n <= '1';
                    exit;
                end if;
                clks(2);
                engine_burst(w1);
                rnd(10, hold);
                clks(hold);
                busrq_n <= '1';
                wait until t_busak_n = '1' for 5 us;
            end loop;
            clks(60);
            run_chk <= false;
            check(t_halt_n = '0', name & ": T80 reached HALT");
            -- T80 program: result, per-iteration memory, exact cycle counts
            exp_a := (others => '0');
            bad := false;
            for k in 0 to 119 loop
                exp_a := exp_a + to_unsigned(120 - k, 8);
                if mem.rd(16#8300# + k) /= std_logic_vector(exp_a) then bad := true; end if;
            end loop;
            check(not bad, name & ": T80 running-sum memory intact (no lost/duplicated cycle)");
            check(mem.rd(16#8200#) = std_logic_vector(exp_a), name & ": T80 final sum");
            check(fab.io_aa = 120, name & ": exactly 120 OUT (AA) cycles from the T80 (got " &
                  integer'image(fab.io_aa) & ")");
            check(fab.io_bb = engine_iowr, name & ": every engine I/O write is exactly one cycle (got " &
                  integer'image(fab.io_bb) & ", expected " & integer'image(engine_iowr) & ")");
            check(fab.wr_cycles = 121 + engine_writes,
                  name & ": memory write cycles = 121 (T80) + " & integer'image(engine_writes) &
                  " (engine), got " & integer'image(fab.wr_cycles));
            report "  " & integer'image(engine_ops) & " engine cycles";
            check(engine_ops > 40, name & ": a meaningful number of engine cycles");
        end procedure;

    begin
        gold.load(GOLDEN);
        check(gold.get("memrd") /= "NOT FOUND", "golden file loaded");
        wait_k <= 0;
        run_phase("production parking (instruction boundary), no waits", false, false);
        wait_k <= 2;
        run_phase("production parking, T80 reads with 2 wait states, engine with 1", false, true);
        wait_k <= 0;
        run_phase("FREEZE_any (off-boundary grants), no waits", true, false);
        wait_k <= 1;
        run_phase("FREEZE_any, 1 wait state, engine with 1", true, true);

        if cnt.errors = 0 then
            report "tb_integ_mux: ALL " & integer'image(cnt.checks) & " CHECKS PASSED";
        else
            report "tb_integ_mux: " & integer'image(cnt.errors) & " of " &
                   integer'image(cnt.checks) & " CHECKS FAILED" severity failure;
        end if;
        stop_sim <= true;
        wait;
    end process;

end architecture sim;

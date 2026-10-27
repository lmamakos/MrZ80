-- tb_integ_park.vhd -- R-40: every SSP park lands on an instruction boundary.
--
-- The real T80s in the production configuration (Mode 1, T2Write 1, IOWait 0,
-- cpu_cen 1-of-5) runs a directed instruction mix (sim/tb_integ_park.asm:
-- DD/FD-indexed, CB, DDCB/FDCB, ED incl. the custom PUSHIX/POPIX, block
-- LDIR/LDDR/CPIR/CPDR/INIR/OTIR, DJNZ, CALL/RET, RST, EX (SP), EXX, I/O, an
-- EI shadow, IM2 interrupts, HALT).  The bench plays the bridge's park
-- request (BUSRQ_n, a level) at random instants and with random hold times,
-- with and without wait states.
--
-- Oracle: an UNPARKED reference run.  It records the full 212-bit REG vector
-- at every instruction start, where an instruction start is an M1 fall seen
-- through a bus-level prefix state machine that knows nothing about the T80's
-- own freeze_ok (DD/FD/CB/ED prefixes; DDCB has no further M1; an interrupt
-- acknowledge M1 is a start of its own).  A park grant after n starts must
-- show REG == reference[n+1] -- the state before instruction n+1, i.e. PC =
-- the next instruction and every register architectural -- plus
-- would_boundary = 1, with REG and the bus idle for the whole hold.  Final
-- REG (except R, which counts HALT's repeated M1s) and a hash of the data
-- memory must equal the reference's, so parking is also transparent.
--
-- Interrupts are raised keyed on instruction-start PCs (generics, taken from
-- the assembler's symbol file) and dropped on the acknowledge, so the stream
-- is identical in every run whatever the park timing.
--
-- HALT is checked separately at the end (parks anywhere, PC = HALT + 1; INT
-- raised while parked wakes it on release).
--
-- Mutation results on the T80 freeze_ok gate (T80_DIR=<copy> sim/run_integ_park.sh),
-- R31: CAUGHT -- grant at any T_Res (vanilla T80); Prefix="00" term removed;
-- DJNZ term without the zero test; MCycle=MCycles replaced by "always";
-- an extra MCycle="001" boundary.  SURVIVE, and understood: No_BTR term removed
-- (only coarser: the park lands one instruction later); MCycle/="111" and
-- NextIs_XY_Fetch and the Mode-1 MCycle="110" exclusions removed (redundant with
-- the Prefix gate in the production configuration -- defence in depth).

-- Run from the project root:  sim/run_integ_park.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_integ_park is
    generic (
        BIN     : string  := "/tmp/sim_integ_park_build/integ_park.bin";
        TRG_EI  : natural := 16#0301#;
        TRG_BLK : natural := 16#0412#;
        TRG_DDC : natural := 16#033F#;
        END_PC  : natural := 16#0121#;
        INIT_PC : natural := 16#0113#
    );
end tb_integ_park;

architecture sim of tb_integ_park is

    -- ---------------------------------------------------- shared state ----
    type mem_pt is protected
        procedure load(fname : string);
        procedure restore;
        procedure wr(a : natural; d : std_logic_vector(7 downto 0));
        impure function rd(a : natural) return std_logic_vector;
        impure function hash(lo, hi : natural) return natural;
    end protected;

    type mem_pt is protected body
        type arr_t is array (0 to 65535) of std_logic_vector(7 downto 0);
        variable base, live : arr_t := (others => x"00");
        procedure load(fname : string) is
            type char_file_t is file of character;
            file f : char_file_t;
            variable c  : character;
            variable n  : natural := 0;
            variable st : file_open_status;
        begin
            file_open(st, f, fname, read_mode);
            assert st = open_ok report "cannot open " & fname severity failure;
            while not endfile(f) loop
                read(f, c);
                base(n) := std_logic_vector(to_unsigned(character'pos(c), 8));
                n := n + 1;
            end loop;
            file_close(f);
            report "loaded " & integer'image(n) & " bytes from " & fname;
            live := base;
        end procedure;
        procedure restore is begin live := base; end procedure;
        procedure wr(a : natural; d : std_logic_vector(7 downto 0)) is
        begin live(a) := d; end procedure;
        impure function rd(a : natural) return std_logic_vector is
        begin return live(a); end function;
        impure function hash(lo, hi : natural) return natural is
            variable h : natural := 5381;
        begin
            for i in lo to hi loop
                h := (h * 33 + to_integer(unsigned(live(i)))) mod 16#FFFFFF#;
            end loop;
            return h;
        end function;
    end protected body;

    -- reference trace: REG at every instruction start, its address and class
    type ref_pt is protected
        procedure clear;
        procedure add(r : std_logic_vector(211 downto 0);
                      a : std_logic_vector(15 downto 0); c : natural);
        procedure set_cls(i : natural; c : natural);
        impure function count return natural;
        impure function reg_at(i : natural) return std_logic_vector;
        impure function addr_at(i : natural) return std_logic_vector;
        impure function cls_at(i : natural) return natural;
    end protected;

    type ref_pt is protected body
        type r_t is array (1 to 12000) of std_logic_vector(211 downto 0);
        type a_t is array (1 to 12000) of std_logic_vector(15 downto 0);
        type c_t is array (1 to 12000) of natural;
        variable rr : r_t;
        variable aa : a_t;
        variable cc : c_t;
        variable n  : natural := 0;
        procedure clear is begin n := 0; end procedure;
        procedure add(r : std_logic_vector(211 downto 0);
                      a : std_logic_vector(15 downto 0); c : natural) is
        begin
            if n < 12000 then
                n := n + 1; rr(n) := r; aa(n) := a; cc(n) := c;
            end if;
        end procedure;
        procedure set_cls(i : natural; c : natural) is
        begin if i >= 1 and i <= n then cc(i) := c; end if; end procedure;
        impure function count return natural is begin return n; end function;
        impure function reg_at(i : natural) return std_logic_vector is
        begin return rr(i); end function;
        impure function addr_at(i : natural) return std_logic_vector is
        begin return aa(i); end function;
        impure function cls_at(i : natural) return natural is
        begin return cc(i); end function;
    end protected body;

    -- error / coverage counters
    constant NCLS : natural := 8;
    type cnt_pt is protected
        procedure err(what : string);
        procedure chk;
        procedure mark_cov(c : natural);
        impure function errors return natural;
        impure function checks return natural;
        impure function covered(c : natural) return natural;
    end protected;

    type cnt_pt is protected body
        type cov_t is array (0 to NCLS - 1) of natural;
        variable e, k : natural := 0;
        variable cv : cov_t := (others => 0);
        procedure err(what : string) is
        begin
            e := e + 1;
            if e <= 25 then report "FAIL: " & what severity error; end if;
        end procedure;
        procedure chk is begin k := k + 1; end procedure;
        procedure mark_cov(c : natural) is begin cv(c) := cv(c) + 1; end procedure;
        impure function errors return natural is begin return e; end function;
        impure function checks return natural is begin return k; end function;
        impure function covered(c : natural) return natural is
        begin return cv(c); end function;
    end protected body;

    shared variable mem  : mem_pt;
    shared variable refr : ref_pt;
    shared variable cnt  : cnt_pt;

    constant CLS_PLAIN : natural := 0;
    constant CLS_DD    : natural := 1;
    constant CLS_FD    : natural := 2;
    constant CLS_CB    : natural := 3;
    constant CLS_ED    : natural := 4;
    constant CLS_INT   : natural := 5;
    constant CLS_DDCB  : natural := 6;     -- DD/FD CB d op (no 4th M1)
    constant CLS_BLK   : natural := 7;     -- ED A0..BB block instruction

    -- ---------------------------------------------------------- signals ----
    signal clk       : std_logic := '0';
    signal cen_ph    : natural range 0 to 4 := 0;
    signal cen       : std_logic;
    signal stop_sim  : boolean := false;

    signal reset_n   : std_logic := '0';
    signal run_rst   : std_logic := '1';
    signal ref_mode  : boolean := true;
    signal busrq_n   : std_logic := '1';
    signal int_n     : std_logic := '1';
    signal int_req   : std_logic := '0';   -- stim: hold INT asserted (HALT section)
    signal wait_k    : natural := 0;

    signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
    signal wait_n    : std_logic := '1';
    signal a         : std_logic_vector(15 downto 0);
    signal di_raw, din, dout : std_logic_vector(7 downto 0) := x"00";
    signal reg       : std_logic_vector(211 downto 0);
    signal wbound    : std_logic;

    signal nstart    : natural := 0;
    signal grants    : natural := 0;
    signal act, act_q : std_logic := '0';
    signal wcnt      : natural := 0;

    signal m1_q, bak_q : std_logic := '1';

    signal cmp_en    : boolean := true;    -- false: HALT section (no trace compare)
    signal init_ns   : natural := 0;       -- reference start index of INITOK

begin

    clk <= not clk after 10 ns when not stop_sim else '0';      -- 50 MHz

    process (clk)
    begin
        if rising_edge(clk) then
            if cen_ph = 4 then cen_ph <= 0; else cen_ph <= cen_ph + 1; end if;
        end if;
    end process;
    cen <= '1' when cen_ph = 2 else '0';

    -- ------------------------------------------------------------- DUT ----
    cpu : entity work.T80s
        generic map (Mode => 1, T2Write => 1, IOWait => 0)
        port map (
            RESET_n => reset_n, CLK_n => clk, CEN => cen,
            WAIT_n => wait_n, INT_n => int_n, NMI_n => '1',
            BUSRQ_n => busrq_n,
            M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n, RD_n => rd_n,
            WR_n => wr_n, RFSH_n => rfsh_n, HALT_n => halt_n,
            BUSAK_n => busak_n, A => a, DI => din, DO => dout,
            REG => reg, FREEZE_req_n => '1', FREEZE_any => '0',
            would_boundary => wbound);

    -- ----------------------------------------------------- memory + I/O ----
    -- 1-clk registered read (production memory sits behind waits); writes are
    -- idempotent while the strobes are low.  I/O reads return port ^ 3C;
    -- the interrupt-acknowledge cycle returns the IM2 vector byte 00.
    process (clk)
    begin
        if rising_edge(clk) then
            di_raw <= mem.rd(to_integer(unsigned(a)));
            if mreq_n = '0' and wr_n = '0' then
                mem.wr(to_integer(unsigned(a)), dout);
            end if;
        end if;
    end process;
    din <= x"00" when (iorq_n = '0' and m1_n = '0') else
           (a(7 downto 0) xor x"3C") when iorq_n = '0' else
           di_raw;

    -- wait states: WAIT_n low for wait_k cpu_cen periods from the start of
    -- every memory read cycle
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

    -- ------------------------------------------------------------ monitor ----
    -- Instruction-start tracker, interrupt device, park-grant checker.  All
    -- sampling is one clk after the event: cpu_cen is 1-of-5, so REG is
    -- stable there and the T80's one-delta REG lag is irrelevant.
    mon : process (clk)
        variable pst      : natural range 0 to 2 := 0;   -- 0 start, 1 after DD/FD, 2 after CB/ED
        variable in_m1    : boolean := false;
        variable ack_seen : boolean := false;
        variable op, op2  : std_logic_vector(7 downto 0);
        variable ns       : natural := 0;
        variable fired_ei, fired_blk, fired_ddc : boolean := false;
        variable held     : boolean := false;
        variable snap     : std_logic_vector(211 downto 0);
        variable gcls     : natural;
        variable ng       : natural := 0;
        variable cls      : natural;
        variable pa       : natural;
        variable want, have : std_logic_vector(211 downto 0);
    begin
        if rising_edge(clk) then
            m1_q  <= m1_n;
            bak_q <= busak_n;
            if run_rst = '1' then
                pst := 0; in_m1 := false; ack_seen := false; ns := 0;
                fired_ei := false; fired_blk := false; fired_ddc := false;
                held := false; nstart <= 0; int_n <= '1';
            else
                -- ---- M1 fall: an instruction start if no prefix is pending
                if m1_q = '1' and m1_n = '0' then
                    in_m1 := true;  ack_seen := false;
                    pa  := to_integer(unsigned(a));
                    op  := mem.rd(pa);
                    op2 := mem.rd((pa + 1) mod 65536);
                    if pst = 0 then
                        ns := ns + 1;
                        nstart <= ns;
                        if ref_mode then
                            cls := CLS_PLAIN;
                            if    op = x"DD" and op2 = x"CB" then cls := CLS_DDCB;
                            elsif op = x"FD" and op2 = x"CB" then cls := CLS_DDCB;
                            elsif op = x"DD" then cls := CLS_DD;
                            elsif op = x"FD" then cls := CLS_FD;
                            elsif op = x"CB" then cls := CLS_CB;
                            elsif op = x"ED" and op2(7 downto 5) = "101" and
                                  op2(2) = '0' then
                                cls := CLS_BLK;                  -- LDI/CPI/INI/OUTI families
                            elsif op = x"ED" then cls := CLS_ED;
                            end if;
                            refr.add(reg, a, cls);
                            if pa = INIT_PC and init_ns = 0 then init_ns <= ns; end if;
                            if reg(79 downto 64) /= a then
                                cnt.err("ref start " & integer'image(ns) &
                                        ": REG.PC /= bus address at M1");
                            end if;
                        end if;
                        -- interrupt triggers, keyed on the start PC
                        if pa = TRG_EI and not fired_ei then
                            fired_ei := true;  int_n <= '0';
                        end if;
                        if pa = TRG_BLK and not fired_blk then
                            fired_blk := true;  int_n <= '0';
                        end if;
                        if pa = TRG_DDC and not fired_ddc then
                            fired_ddc := true;  int_n <= '0';
                        end if;
                    end if;
                end if;
                -- ---- interrupt acknowledge (M1 together with IORQ)
                if in_m1 and m1_n = '0' and iorq_n = '0' then
                    ack_seen := true;
                    int_n <= '1';
                    if ref_mode then refr.set_cls(ns, CLS_INT); end if;
                end if;
                -- ---- M1 rise: advance the prefix state machine
                if in_m1 and m1_q = '0' and m1_n = '1' then
                    in_m1 := false;
                    if ack_seen then
                        pst := 0;
                    else
                        case pst is
                            when 0 =>
                                if op = x"DD" or op = x"FD" then pst := 1;
                                elsif op = x"CB" or op = x"ED" then pst := 2;
                                else pst := 0; end if;
                            when 1 =>
                                if op = x"DD" or op = x"FD" then pst := 1;
                                elsif op = x"ED" then pst := 2;
                                else pst := 0; end if;     -- CB: DDCB has no further M1
                            when others =>
                                pst := 0;
                        end case;
                    end if;
                end if;

                if int_req = '1' then int_n <= '0'; end if;

                -- ---- park grant (BUSAK_n fall, seen one clk late)
                if bak_q = '1' and busak_n = '0' then
                    ng := ng + 1;  grants <= ng;
                    snap := reg;  held := true;
                    if not ref_mode and cmp_en and halt_n = '1' and ns + 1 >= init_ns then
                        cnt.chk;
                        if ns + 1 > refr.count then
                            cnt.err("grant after start " & integer'image(ns) &
                                    " is beyond the reference trace");
                        else
                            -- An interrupt acknowledge start has ALREADY cleared IFF1/IFF2
                            -- at its M1 fall (the T80 takes the interrupt at the same
                            -- T_Res edge), whereas a park there is before the acknowledge:
                            -- interrupts still enabled, INT pending.  Compare without the
                            -- IFF bits at those boundaries only.
                            want := refr.reg_at(ns + 1);
                            have := reg;
                            if refr.cls_at(ns + 1) = CLS_INT then
                                want(211 downto 210) := "00";
                                have(211 downto 210) := "00";
                                cnt.chk;
                                if reg(211 downto 210) /= "11" then
                                    cnt.err("grant before an interrupt acknowledge: IFF not still enabled");
                                end if;
                            end if;
                            if have /= want then
                                cnt.err("grant after start " & integer'image(ns) &
                                        ": REG PC=" & to_hstring(reg(79 downto 64)) &
                                        " expected PC=" & to_hstring(refr.reg_at(ns + 1)(79 downto 64)) &
                                        " (next start at " & to_hstring(refr.addr_at(ns + 1)) &
                                        "), REG xor expected = " &
                                        to_hstring(reg xor refr.reg_at(ns + 1)));
                            end if;
                            -- coverage: class of the instruction that just completed
                            if ns >= 1 and ns <= refr.count then
                                cnt.mark_cov(refr.cls_at(ns));
                            end if;
                        end if;
                        cnt.chk;
                        if wbound /= '1' then
                            cnt.err("grant after start " & integer'image(ns) &
                                    ": would_boundary = 0");
                        end if;
                    end if;
                elsif held then
                    if busak_n = '1' then
                        held := false;
                    else
                        if reg /= snap then
                            cnt.err("REG changed while parked");
                        end if;
                        if mreq_n = '0' and (rd_n = '0' or wr_n = '0') then
                            cnt.err("memory strobe active while parked");
                        end if;
                        if iorq_n = '0' then
                            cnt.err("IORQ active while parked");
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process mon;

    -- ------------------------------------------------------------- stim ----
    stim : process
        variable seed1, seed2 : positive;
        variable r            : real;
        variable ref_hash     : natural;
        variable ref_final    : std_logic_vector(211 downto 0);
        variable ref_isr      : natural;
        variable g0           : natural;
        variable gap, hold    : natural;
        variable dif          : std_logic_vector(211 downto 0);

        procedure clks(n : natural) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure check(ok : boolean; what : string) is
        begin
            cnt.chk;
            if not ok then cnt.err(what); end if;
        end procedure;

        procedure cpu_reset is
        begin
            run_rst <= '1';  reset_n <= '0';  busrq_n <= '1';
            clks(12);
            mem.restore;
            clks(2);
            run_rst <= '0';
            clks(2);
            reset_n <= '1';
        end procedure;

        procedure rnd(maxv : natural; v : out natural) is
        begin
            uniform(seed1, seed2, r);
            v := natural(floor(r * real(maxv + 1)));
            if v > maxv then v := maxv; end if;
        end procedure;

        procedure run_ref is
        begin
            report "reference run (no parks, no waits)";
            ref_mode <= true;  wait_k <= 0;
            refr.clear;
            cpu_reset;
            wait until halt_n = '0' for 20 ms;
            check(halt_n = '0', "ref: program reached HALT");
            clks(40);
            ref_final := reg;
            ref_hash  := mem.hash(16#8000#, 16#8FFF#);
            ref_isr   := to_integer(unsigned(mem.rd(16#8040#)));
            report "  reference: " & integer'image(refr.count) &
                   " instruction starts, ISR count " & integer'image(ref_isr) &
                   ", PC at halt " & to_hstring(reg(79 downto 64));
            check(to_integer(unsigned(reg(79 downto 64))) = END_PC + 1,
                  "ref: halted at HALT + 1");
            check(ref_isr = 3, "ref: three interrupts were taken (EI shadow, LDIR, DDCB)");
            check(refr.count > 400, "ref: a substantial instruction trace");
            check(init_ns > 10 and init_ns < 40, "ref: INITOK found among the first starts");
        end procedure;

        procedure run_parked(s1, s2 : positive; wk, gapmax, holdmax : natural;
                             what : string) is
        begin
            report "parked run: " & what;
            seed1 := s1;  seed2 := s2;
            ref_mode <= false;  wait_k <= wk;
            cpu_reset;
            g0 := grants;
            while halt_n = '1' loop
                rnd(gapmax, gap);
                clks(gap);
                exit when halt_n = '0';
                busrq_n <= '0';
                wait until busak_n = '0' for 100 us;
                if busak_n /= '0' then
                    if halt_n = '1' then
                        cnt.err(what & ": no BusAck within 100 us");
                    end if;
                    busrq_n <= '1';
                    exit;
                end if;
                rnd(holdmax, hold);
                clks(hold);
                busrq_n <= '1';
                wait until busak_n = '1' for 5 us;
                cnt.chk;
                if busak_n /= '1' then cnt.err(what & ": BusAck stuck after release"); end if;
            end loop;
            clks(40);
            check(halt_n = '0', what & ": reached HALT");
            dif := reg xor ref_final;
            dif(47 downto 40) := x"00";                  -- R counts HALT's repeated M1s
            check(dif = (211 downto 0 => '0'),
                  what & ": final REG (except R) equals the reference");
            check(mem.hash(16#8000#, 16#8FFF#) = ref_hash,
                  what & ": data-memory hash equals the reference");
            check(to_integer(unsigned(mem.rd(16#8040#))) = ref_isr,
                  what & ": same number of interrupts taken");
            report "  " & integer'image(grants - g0) & " grants";
            check(grants - g0 > 40, what & ": a meaningful number of parks");
        end procedure;

        procedure halt_checks is
            variable isr0 : natural;
        begin
            -- the CPU sits in HALT at END_PC (final state of the last run)
            report "HALT: park anywhere, PC = HALT + 1; INT while parked";
            cmp_en <= false;
            cpu_reset;
            ref_mode <= false;
            wait until halt_n = '0' for 20 ms;
            check(halt_n = '0', "halt: reached HALT");
            clks(7);                                   -- inside the repeated M1s
            busrq_n <= '0';
            wait until busak_n = '0' for 20 us;
            check(busak_n = '0', "halt: BusAck while halted");
            clks(3);
            check(to_integer(unsigned(reg(79 downto 64))) = END_PC + 1,
                  "halt: parked PC = HALT + 1");
            check(wbound = '1', "halt: would_boundary while halted");
            clks(200);
            busrq_n <= '1';
            clks(60);
            check(halt_n = '0', "halt: still halted after the release");
            check(to_integer(unsigned(reg(79 downto 64))) = END_PC + 1,
                  "halt: PC unchanged after the release");

            -- INT raised while parked wakes the CPU only after the release
            isr0 := to_integer(unsigned(mem.rd(16#8040#)));
            busrq_n <= '0';
            wait until busak_n = '0' for 20 us;
            check(busak_n = '0', "halt: second park");
            int_req <= '1';
            clks(300);
            check(to_integer(unsigned(mem.rd(16#8040#))) = isr0,
                  "halt: no interrupt serviced while parked");
            check(m1_n = '1' and iorq_n = '1', "halt: no acknowledge cycle while parked");
            busrq_n <= '1';
            wait until iorq_n = '0' and m1_n = '0' for 20 us;
            check(iorq_n = '0' and m1_n = '0', "halt: interrupt acknowledged after the release");
            int_req <= '0';
            clks(600);
            check(to_integer(unsigned(mem.rd(16#8040#))) = isr0 + 1,
                  "halt: ISR ran once");
            check(halt_n = '0', "halt: halted again after RETI");
        end procedure;

    begin
        mem.load(BIN);
        run_ref;

        -- dense: a request nearly every instruction, short holds
        run_parked(11, 7, 0, 3, 4, "dense parks, no waits");
        -- medium gaps, long holds
        run_parked(23, 5, 0, 60, 40, "sparse parks, long holds");
        -- wait-stalled cycles in the mix
        run_parked(37, 41, 2, 12, 10, "parks with 2 wait states per read");
        run_parked(53, 19, 3, 5, 6, "dense parks with 3 wait states");
        -- many different phases of the request relative to the CPU clock
        for k in 1 to 4 loop
            run_parked(100 + k * 17, 3 + k, 0, 25, 12, "random phases #" & integer'image(k));
        end loop;

        halt_checks;

        -- ---- coverage: the instruction classes parks landed after (dense runs)
        report "coverage (parks that followed each instruction class):";
        report "  plain " & integer'image(cnt.covered(CLS_PLAIN)) &
               "  DD " & integer'image(cnt.covered(CLS_DD)) &
               "  FD " & integer'image(cnt.covered(CLS_FD)) &
               "  CB " & integer'image(cnt.covered(CLS_CB)) &
               "  ED " & integer'image(cnt.covered(CLS_ED)) &
               "  DDCB/FDCB " & integer'image(cnt.covered(CLS_DDCB)) &
               "  block " & integer'image(cnt.covered(CLS_BLK)) &
               "  int-ack " & integer'image(cnt.covered(CLS_INT));
        check(cnt.covered(CLS_PLAIN) > 0, "coverage: plain instructions");
        check(cnt.covered(CLS_DD) > 0,    "coverage: DD-prefixed");
        check(cnt.covered(CLS_FD) > 0,    "coverage: FD-prefixed");
        check(cnt.covered(CLS_CB) > 0,    "coverage: CB-prefixed");
        check(cnt.covered(CLS_ED) > 0,    "coverage: ED-prefixed");
        check(cnt.covered(CLS_DDCB) > 0,  "coverage: DDCB/FDCB-indexed");
        check(cnt.covered(CLS_BLK) > 0,   "coverage: block instructions");

        if cnt.errors = 0 then
            report "tb_integ_park: ALL " & integer'image(cnt.checks) & " CHECKS PASSED";
        else
            report "tb_integ_park: " & integer'image(cnt.errors) & " of " &
                   integer'image(cnt.checks) & " CHECKS FAILED" severity failure;
        end if;
        stop_sim <= true;
        wait;
    end process;

end architecture sim;

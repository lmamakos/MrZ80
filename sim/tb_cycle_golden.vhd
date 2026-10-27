-- tb_cycle_golden.vhd -- golden bus-cycle waveforms of the REAL T80s in the
-- production configuration (Mode 1, T2Write 1, IOWait 0, cpu_cen 1-of-5).
--
-- R-42 asks that the SSP engine's reads/writes (D-26) "produce the same MRD_T1/
-- strobe/wait waveforms as T80 cycles".  GHDL cannot read the bridge (Verilog,
-- D-33), so the T80 side is captured here and written to a text file; the
-- Verilator p1a lane (sim/ssp/p1a_engine_golden.sh) replays the same four
-- cycle types through the REAL bridge engine and compares.  sim/run_cycle_golden.sh
-- checks this file against the committed sim/ssp/golden_cycles.txt, so a change
-- in T80 timing cannot go unnoticed.
--
-- Program:  LD A,(8000h) ; LD (8001h),A ; IN A,(55h) ; OUT (6966h),A ; HALT
-- (the IN leaves A = 55h ^ 3Ch = 69h, hence the OUT cycle address 6966h).
-- Each data cycle is sampled at the END of every T-state, i.e. at each cpu_cen
-- edge just before the T80 updates; one vector per T-state, columns
--     MREQ IORQ RD WR M1 MRD_T1        (1 = asserted; MRD_T1 is active-high)
-- Run twice: no wait states, and one wait state (WAIT_n low for the first
-- cpu_cen period of every data-cycle strobe, so T2 is stretched by one).
--
-- Output lines:   <kind>  <vec> <vec> ...
--   kinds: memrd memwr iord iowr  and  memrd_w1 memwr_w1 iord_w1 iowr_w1

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_cycle_golden is
    generic (OUT_FILE : string := "/tmp/golden_cycles.txt");
end tb_cycle_golden;

architecture sim of tb_cycle_golden is

    type mem_pt is protected
        procedure init;
        procedure wr(a : natural; d : std_logic_vector(7 downto 0));
        impure function rd(a : natural) return std_logic_vector;
    end protected;
    type mem_pt is protected body
        type arr_t is array (0 to 65535) of std_logic_vector(7 downto 0);
        variable m : arr_t := (others => x"00");
        procedure init is
            constant prog : std_logic_vector(0 to 8 * 11 - 1) :=
                x"3A0080" & x"320180" & x"DB55" & x"D366" & x"76";
        begin
            m := (others => x"00");
            for i in 0 to 10 loop
                m(i) := prog(i * 8 to i * 8 + 7);
            end loop;
        end procedure;
        procedure wr(a : natural; d : std_logic_vector(7 downto 0)) is
        begin m(a) := d; end procedure;
        impure function rd(a : natural) return std_logic_vector is
        begin return m(a); end function;
    end protected body;
    shared variable mem : mem_pt;

    signal clk      : std_logic := '0';
    signal ph       : natural range 0 to 4 := 0;
    signal cen      : std_logic;
    signal reset_n  : std_logic := '0';
    signal wait_en  : boolean := false;
    signal wait_n   : std_logic := '1';
    signal done     : boolean := false;

    signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n, mrd_t1 : std_logic;
    signal a        : std_logic_vector(15 downto 0);
    signal di, dout, di_raw : std_logic_vector(7 downto 0) := x"00";
    signal act, act_q : std_logic := '0';
    signal wcnt     : natural := 0;

    function is_data(x : std_logic_vector(15 downto 0)) return boolean is
    begin
        return x = x"8000" or x = x"8001" or x = x"0055" or x = x"6966";
    end function;

    function vec(mreq, iorq, rd, wr, m1, t1 : std_logic) return string is
        variable s : string(1 to 6);
        function c(b : std_logic; act_low : boolean) return character is
        begin
            if act_low then
                if b = '0' then return '1'; else return '0'; end if;
            else
                if b = '1' then return '1'; else return '0'; end if;
            end if;
        end function;
    begin
        s := c(mreq, true) & c(iorq, true) & c(rd, true) & c(wr, true) &
             c(m1, true) & c(t1, false);
        return s;
    end function;

begin

    clk <= not clk after 10 ns when not done else '0';
    process (clk)
    begin
        if rising_edge(clk) then
            if ph = 4 then ph <= 0; else ph <= ph + 1; end if;
        end if;
    end process;
    cen <= '1' when ph = 2 else '0';

    cpu : entity work.T80s
        generic map (Mode => 1, T2Write => 1, IOWait => 0)
        port map (
            RESET_n => reset_n, CLK_n => clk, CEN => cen,
            WAIT_n => wait_n, INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
            M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n, RD_n => rd_n,
            WR_n => wr_n, RFSH_n => rfsh_n, HALT_n => halt_n, BUSAK_n => busak_n,
            A => a, DI => di, DO => dout, MRD_T1 => mrd_t1,
            FREEZE_req_n => '1', FREEZE_any => '0');

    process (clk)
    begin
        if rising_edge(clk) then
            di_raw <= mem.rd(to_integer(unsigned(a)));
            if mreq_n = '0' and wr_n = '0' then
                mem.wr(to_integer(unsigned(a)), dout);
            end if;
        end if;
    end process;
    di <= (a(7 downto 0) xor x"3C") when iorq_n = '0' else di_raw;

    -- one wait state on DATA cycles only: WAIT_n low for the first cpu_cen
    -- period (5 clk) of the data-cycle strobe
    act <= '1' when (mreq_n = '0' or iorq_n = '0') and (rd_n = '0' or wr_n = '0')
                    and m1_n = '1' and is_data(a) else '0';
    process (clk)
    begin
        if rising_edge(clk) then
            act_q <= act;
            if act = '1' and act_q = '0' then wcnt <= 5;
            elsif wcnt > 0 then wcnt <= wcnt - 1; end if;
        end if;
    end process;
    wait_n <= '0' when (wait_en and act = '1' and wcnt > 0) else '1';

    -- --------------------------------------------------------------- capture ----
    stim : process
        file f : text;
        variable l  : line;
        variable st : file_open_status;
        type buf_t is array (0 to 3) of line;
        variable b  : buf_t;
        variable cyc_a : std_logic_vector(15 downto 0) := x"0000";

        procedure pass(suffix : string) is
            variable k : natural;
            variable prev_a : std_logic_vector(15 downto 0) := x"FFFF";
            variable prev_data : boolean := false;
            variable idx : integer := -1;
        begin
            mem.init;
            for i in 0 to 3 loop b(i) := null; end loop;
            reset_n <= '0';
            wait for 400 ns;
            reset_n <= '1';
            -- sample at every cen edge (pre-edge values) for 12 us
            for n in 1 to 12000 / 20 loop
                wait until rising_edge(clk);
                if cen = '1' then
                    if is_data(a) then
                        if a = x"8000" then idx := 0;
                        elsif a = x"8001" then idx := 1;
                        elsif a = x"0055" then idx := 2;
                        else idx := 3; end if;
                        if b(idx) = null then b(idx) := new string'(""); end if;
                        write(b(idx), string'(" ") & vec(mreq_n, iorq_n, rd_n, wr_n, m1_n, mrd_t1));
                    end if;
                end if;
            end loop;
            write(l, string'("memrd" & suffix)); write(l, b(0).all); writeline(f, l);
            write(l, string'("memwr" & suffix)); write(l, b(1).all); writeline(f, l);
            write(l, string'("iord"  & suffix)); write(l, b(2).all); writeline(f, l);
            write(l, string'("iowr"  & suffix)); write(l, b(3).all); writeline(f, l);
        end procedure;
    begin
        file_open(st, f, OUT_FILE, write_mode);
        assert st = open_ok report "cannot open " & OUT_FILE severity failure;
        write(l, string'("# golden_cycles.txt -- GENERATED by sim/tb_cycle_golden.vhd (sim/run_cycle_golden.sh --update)."));
        writeline(f, l);
        write(l, string'("# Real T80s, Mode 1 / T2Write 1 / IOWait 0, cpu_cen 1-of-5. One vector per T-state, sampled at the"));
        writeline(f, l);
        write(l, string'("# end of the T-state. Columns: MREQ IORQ RD WR M1 MRD_T1 (1 = asserted). _w1 = one wait state in T2."));
        writeline(f, l);
        wait_en <= false;
        pass("");
        wait_en <= true;
        pass("_w1");
        file_close(f);
        done <= true;
        wait;
    end process;

end architecture sim;

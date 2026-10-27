-- tb_integ_core.vhd -- R-42, SDRAM/BRAM/MMU half: the SSP engine through the REAL
-- fabric of MicrocomputerZ80CPM (z80_bus_mux + ssp_tramp + T80s + MMU + block RAM +
-- SDRAM client FSM + the clk_sys<->clk_ram CDC model).
--
-- tb_integ_mux proves the mux against a toy fabric; this bench proves the engine's
-- cycles do the right thing in the real one:
--   * engine memory writes/reads to BLOCK RAM and SDRAM land and read back (the SDRAM
--     path exercises the MRD_T1 speculative read and the wait-state stall);
--   * the engine honours the MMU: I/O reads of the MMU mapping registers, and a write
--     through the MMU direct-access pointer/data port (ports B8..BC, a promoted I/O
--     cycle) that lands in block RAM and is then read back as ordinary memory;
--   * the engine honours the fabric's WAIT_n (SDRAM) -- its data is sampled at the
--     wait-sensed T2 exit, exactly as the bridge FSM does;
--   * the guest program (tb_integ_core.asm: 120-step running sum, SDRAM + block-RAM
--     write/read-back per step, OUTs) is undisturbed by the parks and engine bursts;
--   * every clock: running => guest nets = T80's; parked, engine idle => strobes and
--     MRD_T1 idle; engine cycle => guest nets = engine's; select never without BusAck.
-- The engine model is the same transcription of the bridge FSM used by tb_integ_mux
-- (whose waveform is held to the T80 golden file).
--
-- Memory map of the model (MMU reset map, boot_to_blockram = 1): logical frame 0
-- (0000-3FFF) is the block RAM page, frames 1..3 are SDRAM pages 1..3; the guest
-- remaps frame 3 to SDRAM page 0.  The engine uses 2000+ad (block RAM), 2100+ad
-- (block RAM through the direct port), C800+ad / CC00+ad (SDRAM phys 0800+ / 0C00+).
--
-- Mutation results on z80_bus_mux (MUX=<mutant> sim/run_integ_core.sh), R32: CAUGHT --
-- cpu_dout not switched; MRD_T1 not switched (net-equality check).  SURVIVES, covered
-- by tb_integ_mux's directed test: select without BusAck (this engine never asks early).
--
-- Run from the project root:  sim/run_integ_core.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_integ_core is
    generic (BIN : string := "/tmp/integ_core.bin");
end tb_integ_core;

architecture sim of tb_integ_core is

    type char_file_t is file of character;

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
    shared variable cnt : cnt_pt;

    -- shadow of the block RAM, built from the DUT's own write bus (bram_*)
    type bram_pt is protected
        procedure wr(a : natural; d : std_logic_vector(7 downto 0));
        impure function rd(a : natural) return std_logic_vector;
        impure function nwr return natural;
    end protected;
    type bram_pt is protected body
        type arr_t is array (0 to 65535) of std_logic_vector(7 downto 0);
        variable m : arr_t := (others => x"00");
        variable n : natural := 0;
        procedure wr(a : natural; d : std_logic_vector(7 downto 0)) is
        begin m(a) := d; n := n + 1; end procedure;
        impure function rd(a : natural) return std_logic_vector is
        begin return m(a); end function;
        impure function nwr return natural is begin return n; end function;
    end protected body;
    shared variable bram : bram_pt;

    -- ---------------------------------------------------------- signals ----
    signal clk_sys : std_logic := '0';
    signal clk_ram : std_logic := '0';
    signal stop_sim : boolean := false;
    signal N_RESET : std_logic := '0';
    signal run_chk : boolean := false;

    signal dl_bram_addr : std_logic_vector(15 downto 0) := (others => '0');
    signal dl_bram_data : std_logic_vector(7 downto 0)  := (others => '0');
    signal dl_bram_we   : std_logic := '0';

    signal sdram_addr  : std_logic_vector(26 downto 0);
    signal sdram_din   : std_logic_vector(7 downto 0);
    signal sdram_we    : std_logic;
    signal sdram_rd    : std_logic;
    signal sdram_dout  : std_logic_vector(7 downto 0);
    signal sdram_ready : std_logic;

    signal txd1, rts1, txd2, rts2, videoSync, video : std_logic;
    signal R, G, B : std_logic_vector(1 downto 0);
    signal HS, VS, hBlank, vBlank, cepix : std_logic;
    signal sdCS, sdMOSI, sdSCLK, driveLED, fpLED_serial : std_logic;

    -- SSP seam
    signal busrq_n   : std_logic := '1';
    signal e_own     : std_logic := '0';
    signal e_addr    : std_logic_vector(15 downto 0) := x"FFFF";
    signal e_dout    : std_logic_vector(7 downto 0) := x"00";
    signal e_mreq_n, e_iorq_n, e_rd_n, e_wr_n, e_m1_n : std_logic := '1';
    signal e_mrd_t1  : std_logic := '0';
    signal s_cen, s_wait_n, s_busack_n, s_halt_n, s_m1_n : std_logic;
    signal s_din     : std_logic_vector(7 downto 0);

    -- engine command interface
    signal e_kick    : boolean := false;
    signal e_kind    : natural := 0;                  -- 0 memrd 1 memwr 2 iord 3 iowr
    signal e_kaddr   : std_logic_vector(15 downto 0) := x"0000";
    signal e_kdata   : std_logic_vector(7 downto 0) := x"00";
    signal e_rdcap   : std_logic_vector(7 downto 0) := x"00";

    -- guest-net probes (after the mux, inside the DUT)
    signal g_addr    : std_logic_vector(15 downto 0);
    signal g_dout    : std_logic_vector(7 downto 0);
    signal g_mreq_n, g_iorq_n, g_rd_n, g_wr_n, g_m1_n, g_mrd_t1 : std_logic;
    signal t_addr    : std_logic_vector(15 downto 0);
    signal t_dout    : std_logic_vector(7 downto 0);
    signal t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_m1_n, t_mrd_t1 : std_logic;
    signal wsel      : std_logic;
    signal p_bram_addr : std_logic_vector(15 downto 0);
    signal p_bram_data : std_logic_vector(7 downto 0);
    signal p_bram_wren : std_logic;

    signal done_flag : std_logic := '0';

begin

    clk_sys <= not clk_sys after 10 ns when not stop_sim else '0';
    clk_ram <= not clk_ram after 4.4643 ns when not stop_sim else '0';

    -- the DUT's clk dividers have no VHDL reset value (sim-only gap, see tb_inir_race)
    seed_counters : process
    begin
        << signal .tb_integ_core.dut.cpuClkCount : std_logic_vector(5 downto 0) >> <= force "000000";
        << signal .tb_integ_core.dut.sdClkCount  : std_logic_vector(5 downto 0) >> <= force "000000";
        wait for 100 ns;
        << signal .tb_integ_core.dut.cpuClkCount : std_logic_vector(5 downto 0) >> <= release;
        << signal .tb_integ_core.dut.sdClkCount  : std_logic_vector(5 downto 0) >> <= release;
        wait;
    end process;

    dut : entity work.MicrocomputerZ80CPM(struct)
        port map (
            N_RESET => N_RESET, clk => clk_sys, baud_increment => x"00C9",
            rxd1 => '1', txd1 => txd1, rts1 => rts1, cts1 => '0',
            rxd2 => '1', txd2 => txd2, rts2 => rts2,
            videoSync => videoSync, video => video,
            R => R, G => G, B => B, HS => HS, VS => VS, hBlank => hBlank,
            vBlank => vBlank, cepix => cepix,
            ps2Clk => '1', ps2Data => '1',
            sdCS => sdCS, sdMOSI => sdMOSI, sdMISO => '1', sdSCLK => sdSCLK,
            driveLED => driveLED, fpLED_serial => fpLED_serial,
            sdram_addr => sdram_addr, sdram_din => sdram_din, sdram_we => sdram_we,
            sdram_rd => sdram_rd, sdram_dout => sdram_dout, sdram_ready => sdram_ready,
            bin_loaded => '1', boot_to_blockram => '1',
            dl_bram_addr => dl_bram_addr, dl_bram_data => dl_bram_data,
            dl_bram_we => dl_bram_we,
            ssp_busrq_n => busrq_n,
            ssp_eng_own => e_own, ssp_eng_addr => e_addr, ssp_eng_dout => e_dout,
            ssp_eng_mreq_n => e_mreq_n, ssp_eng_iorq_n => e_iorq_n,
            ssp_eng_rd_n => e_rd_n, ssp_eng_wr_n => e_wr_n, ssp_eng_m1_n => e_m1_n,
            ssp_eng_mrd_t1 => e_mrd_t1,
            ssp_cpu_cen => s_cen, ssp_cpu_din => s_din, ssp_cpu_wait_n => s_wait_n,
            ssp_busack_n => s_busack_n, ssp_halt_n => s_halt_n, ssp_m1_n => s_m1_n);

    cdc : entity work.sdram_cdc_fake(sim)
        port map (clk_sys => clk_sys, clk_ram => clk_ram,
                  sdram_we_mux => sdram_we, sdram_rd_mux => sdram_rd,
                  sdram_addr_mux => sdram_addr, sdram_din_mux => sdram_din,
                  sdram_ready_mux => sdram_ready, sdram_dout_mux => sdram_dout);

    -- probes
    g_addr   <= << signal .tb_integ_core.dut.cpuAddress  : std_logic_vector(15 downto 0) >>;
    g_dout   <= << signal .tb_integ_core.dut.cpuDataOut  : std_logic_vector(7 downto 0) >>;
    g_mreq_n <= << signal .tb_integ_core.dut.n_MREQ : std_logic >>;
    g_iorq_n <= << signal .tb_integ_core.dut.n_IORQ : std_logic >>;
    g_rd_n   <= << signal .tb_integ_core.dut.n_RD   : std_logic >>;
    g_wr_n   <= << signal .tb_integ_core.dut.n_WR   : std_logic >>;
    g_m1_n   <= << signal .tb_integ_core.dut.n_M1   : std_logic >>;
    g_mrd_t1 <= << signal .tb_integ_core.dut.cpu_mrd_t1 : std_logic >>;
    t_addr   <= << signal .tb_integ_core.dut.t80_addr   : std_logic_vector(15 downto 0) >>;
    t_dout   <= << signal .tb_integ_core.dut.t80_dout   : std_logic_vector(7 downto 0) >>;
    t_mreq_n <= << signal .tb_integ_core.dut.t80_mreq_n : std_logic >>;
    t_iorq_n <= << signal .tb_integ_core.dut.t80_iorq_n : std_logic >>;
    t_rd_n   <= << signal .tb_integ_core.dut.t80_rd_n   : std_logic >>;
    t_wr_n   <= << signal .tb_integ_core.dut.t80_wr_n   : std_logic >>;
    t_m1_n   <= << signal .tb_integ_core.dut.t80_m1_n   : std_logic >>;
    t_mrd_t1 <= << signal .tb_integ_core.dut.t80_mrd_t1 : std_logic >>;
    wsel     <= << signal .tb_integ_core.dut.bus_mux.sel_eng : std_logic >>;
    p_bram_addr <= << signal .tb_integ_core.dut.bram_address : std_logic_vector(15 downto 0) >>;
    p_bram_data <= << signal .tb_integ_core.dut.bram_data    : std_logic_vector(7 downto 0)  >>;
    p_bram_wren <= << signal .tb_integ_core.dut.bram_wren    : std_logic >>;

    -- preload the guest program into block RAM while the CPU is in reset
    preload : process
        file f : char_file_t open read_mode is BIN;
        variable c : character;
        variable a : integer := 0;
    begin
        N_RESET <= '0';
        dl_bram_we <= '0';
        wait for 200 ns;
        while not endfile(f) loop
            read(f, c);
            dl_bram_addr <= std_logic_vector(to_unsigned(a, 16));
            dl_bram_data <= std_logic_vector(to_unsigned(character'pos(c), 8));
            dl_bram_we <= '1';
            wait until rising_edge(clk_sys);
            a := a + 1;
        end loop;
        file_close(f);
        dl_bram_we <= '0';
        wait for 200 ns;
        N_RESET <= '1';
        wait;
    end process;

    -- block-RAM write shadow (every write: T80, engine, and the direct-access port)
    shadow : process (clk_sys)
    begin
        if rising_edge(clk_sys) then
            if p_bram_wren = '1' and dl_bram_we = '0' then
                bram.wr(to_integer(unsigned(p_bram_addr)), p_bram_data);
                if p_bram_addr = x"0903" and p_bram_data = x"AA" then
                    done_flag <= '1';
                end if;
            end if;
        end if;
    end process;

    -- ------------------------------------------------------ engine model ----
    -- ssp_bridge.v engine FSM: one T-state per (ungated) cpu_cen, strobes in T2,
    -- data sampled at the wait-sensed T2 exit.
    engine : process (clk_sys)
        variable st : natural range 0 to 3 := 0;
        variable t_rd, t_io : boolean;
    begin
        if rising_edge(clk_sys) then
            if N_RESET = '0' then
                st := 0; e_own <= '0'; e_mreq_n <= '1'; e_iorq_n <= '1';
                e_rd_n <= '1'; e_wr_n <= '1'; e_m1_n <= '1'; e_mrd_t1 <= '0';
            else
                case st is
                when 0 =>
                    if e_kick and s_busack_n = '0' then
                        t_rd := (e_kind = 0 or e_kind = 2);
                        t_io := (e_kind = 2 or e_kind = 3);
                        e_own <= '1'; e_addr <= e_kaddr; e_dout <= e_kdata;
                        e_m1_n <= '1';
                        if t_rd and not t_io then e_mrd_t1 <= '1'; else e_mrd_t1 <= '0'; end if;
                        e_mreq_n <= '1'; e_iorq_n <= '1'; e_rd_n <= '1'; e_wr_n <= '1';
                        st := 1;
                    end if;
                when 1 =>
                    if s_cen = '1' then
                        e_mrd_t1 <= '0';
                        if t_io then e_iorq_n <= '0'; else e_mreq_n <= '0'; end if;
                        if t_rd then e_rd_n <= '0'; else e_wr_n <= '0'; end if;
                        st := 2;
                    end if;
                when 2 =>
                    if s_cen = '1' and s_wait_n = '1' then
                        if t_rd then e_rdcap <= s_din; end if;
                        e_mreq_n <= '1'; e_iorq_n <= '1'; e_rd_n <= '1'; e_wr_n <= '1';
                        st := 3;
                    end if;
                when 3 =>
                    if s_cen = '1' then
                        e_own <= '0';
                        st := 0;
                    end if;
                end case;
            end if;
        end if;
    end process engine;

    -- --------------------------------------------------------- checkers ----
    chk : process (clk_sys)
        variable idle_clks : natural := 0;
    begin
        if rising_edge(clk_sys) and run_chk then
            cnt.chk;
            if e_own = '0' then idle_clks := idle_clks + 1; else idle_clks := 0; end if;
            if wsel = '1' and idle_clks >= 3 then
                cnt.err("select still on the engine after its cycle ended");
            end if;
            if wsel = '1' and s_busack_n /= '0' then
                cnt.err("select on the engine without BusAck");
            end if;
            if wsel = '1' then
                if g_addr /= e_addr or g_dout /= e_dout or g_mreq_n /= e_mreq_n or
                   g_iorq_n /= e_iorq_n or g_rd_n /= e_rd_n or g_wr_n /= e_wr_n or
                   g_m1_n /= e_m1_n or g_mrd_t1 /= e_mrd_t1 then
                    cnt.err("engine cycle: guest nets differ from the engine's");
                end if;
            elsif s_busack_n = '0' then
                if g_mreq_n /= '1' or g_iorq_n /= '1' or g_rd_n /= '1' or
                   g_wr_n /= '1' or g_m1_n /= '1' then
                    cnt.err("parked: a strobe leaks to the fabric");
                end if;
                if g_mrd_t1 /= '0' then
                    cnt.err("parked: MRD_T1 leaks to the fabric (SDRAM speculative trigger)");
                end if;
            else
                if g_addr /= t_addr or g_dout /= t_dout or g_mreq_n /= t_mreq_n or
                   g_iorq_n /= t_iorq_n or g_rd_n /= t_rd_n or g_wr_n /= t_wr_n or
                   g_m1_n /= t_m1_n or g_mrd_t1 /= t_mrd_t1 then
                    cnt.err("running: guest nets differ from the T80's");
                end if;
            end if;
        end if;
    end process chk;

    -- ------------------------------------------------------------- stim ----
    stim : process
        variable seed1 : positive := 20261028;
        variable seed2 : positive := 11;
        variable r : real;
        variable ops, nbram_w, nsdr_w, nsdr_rd, nbram_rd, nmmu, ndirect : natural := 0;
        variable bw : std_logic_vector(0 to 255) := (others => '0');   -- BRAM 2000+ad written
        variable sw : std_logic_vector(0 to 255) := (others => '0');   -- SDRAM C800+ad written
        variable bval, sval : std_logic_vector(0 to 2047) := (others => '0');
        variable rb : std_logic_vector(7 downto 0);

        procedure clks(n : natural) is
        begin for i in 1 to n loop wait until rising_edge(clk_sys); end loop; end procedure;

        procedure rnd(maxv : natural; v : out natural) is
        begin
            uniform(seed1, seed2, r);
            v := natural(floor(r * real(maxv + 1)));
            if v > maxv then v := maxv; end if;
        end procedure;

        procedure check(ok : boolean; what : string) is
        begin cnt.chk; if not ok then cnt.err(what); end if; end procedure;

        function pat(ad : natural; salt : natural) return std_logic_vector is
        begin return std_logic_vector(to_unsigned((ad * 13 + salt) mod 256, 8)); end function;

        procedure eng_cycle(kind : natural; a : std_logic_vector(15 downto 0);
                            d : std_logic_vector(7 downto 0);
                            rdback : out std_logic_vector(7 downto 0)) is
            variable seen : boolean := false;
        begin
            e_kind <= kind; e_kaddr <= a; e_kdata <= d;
            e_kick <= true;
            clks(1);
            e_kick <= false;
            while true loop
                wait until rising_edge(clk_sys);
                if e_own = '1' then seen := true; end if;
                exit when seen and e_own = '0';
            end loop;
            clks(2);
            rdback := e_rdcap;
        end procedure;

        procedure engine_burst is
            variable n, k, ad : natural;
            variable a16 : std_logic_vector(15 downto 0);
        begin
            rnd(3, n);
            for i in 0 to n loop
                rnd(6, k);
                rnd(255, ad);
                ops := ops + 1;
                case k is
                    when 0 =>                          -- block RAM write 2000+ad (frame 0 is the block RAM page; frames 1..3 are SDRAM pages 1..3)
                        a16 := std_logic_vector(to_unsigned(16#2000# + ad, 16));
                        eng_cycle(1, a16, pat(ad, 1), rb);
                        bw(ad) := '1';
                        nbram_w := nbram_w + 1;
                        check(bram.rd(16#2000# + ad) = pat(ad, 1), "engine BRAM write landed (shadow) ad=" & integer'image(ad) & " got " & to_hstring(bram.rd(16#2000# + ad)));
                    when 1 =>                          -- block RAM read back
                        a16 := std_logic_vector(to_unsigned(16#2000# + ad, 16));
                        eng_cycle(0, a16, x"00", rb);
                        nbram_rd := nbram_rd + 1;
                        if bw(ad) = '1' then
                            check(rb = pat(ad, 1), "engine BRAM read returns what the engine wrote");
                        end if;
                    when 2 =>                          -- SDRAM write C800+ad (phys 0800+ad)
                        a16 := std_logic_vector(to_unsigned(16#C800# + ad, 16));
                        eng_cycle(1, a16, pat(ad, 7), rb);
                        sw(ad) := '1';
                        nsdr_w := nsdr_w + 1;
                    when 3 =>                          -- SDRAM read back
                        a16 := std_logic_vector(to_unsigned(16#C800# + ad, 16));
                        eng_cycle(0, a16, x"00", rb);
                        nsdr_rd := nsdr_rd + 1;
                        if sw(ad) = '1' then
                            check(rb = pat(ad, 7), "engine SDRAM read returns what the engine wrote");
                        end if;
                    when 4 =>                          -- SDRAM never written: the model's ramp
                        a16 := std_logic_vector(to_unsigned(16#CC00# + ad, 16));
                        eng_cycle(0, a16, x"00", rb);
                        nsdr_rd := nsdr_rd + 1;
                        check(rb = std_logic_vector(to_unsigned(ad, 8)),
                              "engine SDRAM read of untouched memory returns the ramp byte");
                    when 5 =>                          -- MMU mapping registers (I/O read)
                        nmmu := nmmu + 1;
                        eng_cycle(2, x"00B1", x"00", rb);      -- frame 1 low = 01
                        check(rb = x"01", "engine I/O read of MMU frame 1 low byte");
                        eng_cycle(2, x"00B4", x"00", rb);      -- frame 0 high = 20 (page 8192)
                        check(rb = x"20", "engine I/O read of MMU frame 0 high byte");
                        eng_cycle(2, x"00B3", x"00", rb);      -- frame 3 low = 00 (guest set it)
                        check(rb = x"00", "engine I/O read of MMU frame 3 low byte");
                    when others =>                     -- MMU direct-access port write -> BRAM 2100+ad
                        ndirect := ndirect + 1;
                        eng_cycle(3, x"00B8", std_logic_vector(to_unsigned(ad, 8)), rb);
                        eng_cycle(3, x"00B9", x"21", rb);
                        eng_cycle(3, x"00BA", x"00", rb);
                        eng_cycle(3, x"00BB", x"08", rb);          -- phys 0800_2100: block RAM
                        eng_cycle(3, x"00BC", pat(ad, 3), rb);
                        check(bram.rd(16#2100# + ad) = pat(ad, 3), "engine direct-port write landed in block RAM (ad=" & integer'image(ad) & " got " & to_hstring(bram.rd(16#2100# + ad)) & " exp " & to_hstring(pat(ad, 3)) & ")");
                        a16 := std_logic_vector(to_unsigned(16#2100# + ad, 16));
                        eng_cycle(0, a16, x"00", rb);
                        check(rb = pat(ad, 3), "memory read sees the direct-port write (ad=" & integer'image(ad) & " rb=" & to_hstring(rb) & " exp " & to_hstring(pat(ad, 3)) & ")");
                end case;
            end loop;
        end procedure;

        variable gap, hold : natural;
        variable exp_a : unsigned(7 downto 0);
        variable bad : boolean;
        variable nbursts : natural := 0;
    begin
        wait until << signal .tb_integ_core.dut.reset_n_internal : std_logic >> = '1';
        clks(400);                              -- let the guest set up its MMU frame
        run_chk <= true;
        while s_halt_n = '1' loop
            rnd(300, gap);
            clks(gap);
            exit when s_halt_n = '0';
            busrq_n <= '0';
            wait until s_busack_n = '0' for 200 us;
            if s_busack_n /= '0' then
                if s_halt_n = '1' then cnt.err("no BusAck"); end if;
                busrq_n <= '1';
                exit;
            end if;
            clks(2);
            engine_burst;
            nbursts := nbursts + 1;
            rnd(10, hold);
            clks(hold);
            busrq_n <= '1';
            wait until s_busack_n = '1' for 5 us;
        end loop;
        clks(100);
        run_chk <= false;
        check(s_halt_n = '0', "guest reached HALT");
        check(done_flag = '1', "guest wrote its done flag");
        -- guest result and memory images
        exp_a := (others => '0');
        bad := false;
        for k in 0 to 119 loop
            exp_a := exp_a + to_unsigned(120 - k, 8);
            if bram.rd(16#3000# + k) /= std_logic_vector(exp_a) then bad := true; end if;
        end loop;
        check(not bad, "guest block-RAM running-sum image intact");
        check(bram.rd(16#0902#) = std_logic_vector(exp_a), "guest final sum");
        check(bram.rd(16#0900#) = x"00", "guest SDRAM/BRAM read-back mismatch count is 0 (got " &
              integer'image(to_integer(unsigned(bram.rd(16#0900#)))) & ")");
        report "  " & integer'image(nbursts) & " parks, " & integer'image(ops) & " engine ops: " &
               integer'image(nbram_w) & " BRAM wr, " & integer'image(nbram_rd) & " BRAM rd, " &
               integer'image(nsdr_w) & " SDRAM wr, " & integer'image(nsdr_rd) & " SDRAM rd, " &
               integer'image(nmmu) & " MMU reg reads, " & integer'image(ndirect) & " direct-port writes";
        check(nbursts >= 20, "a meaningful number of parks");
        check(nsdr_w > 5 and nsdr_rd > 5 and nbram_w > 5 and ndirect > 2 and nmmu > 2,
              "every engine op class was exercised");

        if cnt.errors = 0 then
            report "tb_integ_core: ALL " & integer'image(cnt.checks) & " CHECKS PASSED";
        else
            report "tb_integ_core: " & integer'image(cnt.errors) & " of " &
                   integer'image(cnt.checks) & " CHECKS FAILED" severity failure;
        end if;
        stop_sim <= true;
        wait;
    end process;

end architecture sim;

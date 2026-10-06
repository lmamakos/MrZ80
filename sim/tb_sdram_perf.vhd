-- ============================================================================
-- tb_sdram_perf.vhd - SDRAM access-latency measurement testbench (GHDL).
--
-- Same system as tb_inir_race (the real MicrocomputerZ80CPM via its sim
-- copy, behavioural block RAM/ROM, sdram_cdc_fake modelling the
-- MultiComp.sv clk_sys <-> clk_ram synchronisers and the sdram_32r8w
-- CPU-port timing), but:
--   * clk_ram runs at the real 96.667 MHz (SDRAM_CLK_100) by default,
--   * the payload (sim/sdram_perf.asm, generic BIN) copies a routine into
--     SDRAM and runs it from there,
--   * a monitor counts, at every T80 clock-enable edge, whether the CPU
--     was held by WAIT_n (WAIT_n low with RD_n or WR_n low), and builds a histogram of wait T-states per
--     stalled bus cycle, split by cycle type (memory read, memory write,
--     I/O read/write),
--   * at the end it reports the number of T-states from reset release to
--     DONE_FLAG and the checksum the payload computed (expected E0h).
--
-- Run: sim/run_perf.sh [workdir] [ghdl -r options, e.g. -gCLK_RAM_KHZ=112000]
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sdram_perf is
    generic (
        BIN          : string := "sim/sdram_perf.bin";
        CLK_RAM_KHZ  : natural := 96667;    -- real core: SDRAM_CLK_100
        EXPECT_SUM   : natural := 16#E0#
    );
end entity tb_sdram_perf;

architecture sim of tb_sdram_perf is

    signal clk_sys : std_logic := '0';
    signal clk_ram : std_logic := '0';
    constant CLK_SYS_HALF : time := 10 ns;      -- 50 MHz
    constant CLK_RAM_HALF : time := (500000.0 / real(CLK_RAM_KHZ)) * 1 ns;

    signal N_RESET : std_logic := '0';

    signal dl_bram_addr : std_logic_vector(15 downto 0) := (others => '0');
    signal dl_bram_data : std_logic_vector(7 downto 0)  := (others => '0');
    signal dl_bram_we   : std_logic := '0';

    signal sdram_addr  : std_logic_vector(26 downto 0);
    signal sdram_din   : std_logic_vector(7 downto 0);
    signal sdram_we    : std_logic;
    signal sdram_rd    : std_logic;
    signal sdram_dout  : std_logic_vector(7 downto 0);
    signal sdram_ready : std_logic;

    signal txd1, rts1, txd2, rts2               : std_logic;
    signal videoSync, video                     : std_logic;
    signal R, G, B                              : std_logic_vector(1 downto 0);
    signal HS, VS, hBlank, vBlank, cepix        : std_logic;
    signal sdCS, sdMOSI, sdSCLK, driveLED       : std_logic;
    signal fpLED_serial                         : std_logic;

    signal p_bram_addr : std_logic_vector(15 downto 0);
    signal p_bram_data : std_logic_vector(7 downto 0);
    signal p_bram_wren : std_logic;
    signal p_cen, p_wait_n, p_rd, p_wr, p_iorq, p_rst : std_logic;
    signal p_addr : std_logic_vector(15 downto 0);

    signal result   : std_logic_vector(7 downto 0) := (others => '0');
    signal sim_done : boolean := false;

    type file_t is file of character;

    -- histogram: index = wait T-states of one stalled cycle (0..15+)
    type hist_t is array (0 to 15) of natural;

begin

    clk_sys <= not clk_sys after CLK_SYS_HALF;
    clk_ram <= not clk_ram after CLK_RAM_HALF;

    dut: entity work.MicrocomputerZ80CPM(struct)
        port map(
            N_RESET => N_RESET, clk => clk_sys, baud_increment => x"00C9",
            rxd1 => '1', txd1 => txd1, rts1 => rts1, cts1 => '0',
            rxd2 => '1', txd2 => txd2, rts2 => rts2,
            videoSync => videoSync, video => video,
            R => R, G => G, B => B,
            HS => HS, VS => VS, hBlank => hBlank, vBlank => vBlank, cepix => cepix,
            ps2Clk => '1', ps2Data => '1',
            sdCS => sdCS, sdMOSI => sdMOSI, sdMISO => '1', sdSCLK => sdSCLK,
            driveLED => driveLED,
            fpLED_serial => fpLED_serial,
            sdram_addr => sdram_addr, sdram_din => sdram_din,
            sdram_we => sdram_we, sdram_rd => sdram_rd,
            sdram_dout => sdram_dout, sdram_ready => sdram_ready,
            bin_loaded => '1', boot_to_blockram => '1',
            dl_bram_addr => dl_bram_addr, dl_bram_data => dl_bram_data,
            dl_bram_we => dl_bram_we
        );

    cdc: entity work.sdram_cdc_fake(sim)
        port map(
            clk_sys => clk_sys, clk_ram => clk_ram,
            sdram_we_mux => sdram_we, sdram_rd_mux => sdram_rd,
            sdram_addr_mux => sdram_addr, sdram_din_mux => sdram_din,
            sdram_ready_mux => sdram_ready, sdram_dout_mux => sdram_dout
        );

    p_bram_addr <= << signal .tb_sdram_perf.dut.bram_address : std_logic_vector(15 downto 0) >>;
    p_bram_data <= << signal .tb_sdram_perf.dut.bram_data    : std_logic_vector(7 downto 0)  >>;
    p_bram_wren <= << signal .tb_sdram_perf.dut.bram_wren    : std_logic >>;
    p_cen       <= << signal .tb_sdram_perf.dut.cpu_cen      : std_logic >>;
    p_wait_n    <= << signal .tb_sdram_perf.dut.cpu_wait_n   : std_logic >>;
    p_rd        <= << signal .tb_sdram_perf.dut.n_RD         : std_logic >>;
    p_wr        <= << signal .tb_sdram_perf.dut.n_WR         : std_logic >>;
    p_iorq      <= << signal .tb_sdram_perf.dut.n_IORQ       : std_logic >>;
    p_addr      <= << signal .tb_sdram_perf.dut.cpuAddress  : std_logic_vector(15 downto 0) >>;
    p_rst       <= << signal .tb_sdram_perf.dut.reset_n_internal : std_logic >>;

    -- sdClkCount has no initial value; seed it as tb_inir_race does.
    seed: process
    begin
        << signal .tb_sdram_perf.dut.sdClkCount : std_logic_vector(5 downto 0) >> <= force "000000";
        wait for 100 ns;
        << signal .tb_sdram_perf.dut.sdClkCount : std_logic_vector(5 downto 0) >> <= release;
        wait;
    end process;

    preload: process
        file f       : file_t open read_mode is BIN;
        variable c   : character;
        variable a   : integer := 0;
    begin
        wait for 200 ns;
        while not endfile(f) loop
            read(f, c);
            dl_bram_addr <= std_logic_vector(to_unsigned(a, 16));
            dl_bram_data <= std_logic_vector(to_unsigned(character'pos(c), 8));
            dl_bram_we   <= '1';
            wait until rising_edge(clk_sys);
            a := a + 1;
        end loop;
        dl_bram_we <= '0';
        wait for 200 ns;
        report "preload done: " & integer'image(a) & " bytes";
        N_RESET <= '1';
        wait;
    end process;

    watch: process(clk_sys)
    begin
        if rising_edge(clk_sys) and p_bram_wren = '1' then
            if unsigned(p_bram_addr) = 16#0900# then
                result <= p_bram_data;
            elsif unsigned(p_bram_addr) = 16#0908# and p_bram_data = x"AA" then
                sim_done <= true;
            end if;
        end if;
    end process;

    -- T80 edges are the clk_sys rising edges with cpu_cen = '1'.
    monitor: process(clk_sys)
        variable tstates   : natural := 0;
        variable run       : natural := 0;
        variable kind      : natural := 0;   -- 0 mem rd, 1 mem wr, 2 io
        variable h_rd, h_wr, h_io : hist_t := (others => 0);
        variable w_rd, w_wr, w_io : natural := 0;
        variable reported  : boolean := false;
        variable nshown    : natural := 0;

        procedure show(name : string; h : hist_t; total : natural) is
            variable n : natural := 0;
        begin
            for i in h'range loop
                n := n + h(i);
            end loop;
            report name & ": " & integer'image(n) & " stalled cycles, "
                 & integer'image(total) & " wait T-states";
            for i in h'range loop
                if h(i) /= 0 then
                    report "    " & integer'image(i) & " wait T-states: "
                         & integer'image(h(i));
                end if;
            end loop;
        end procedure;
    begin
        if rising_edge(clk_sys) then
            if p_rst = '1' and not sim_done and p_cen = '1' then
                tstates := tstates + 1;
                -- A T-state is a wait state only if WAIT_n is low while a
                -- read/write strobe is active (end of T2 or later); WAIT_n
                -- low at the end of T1 (speculative SDRAM read in flight)
                -- is ignored by the T80.
                if p_wait_n = '0' and (p_rd = '0' or p_wr = '0') then
                    if run = 0 then
                        if nshown < 8 then
                            nshown := nshown + 1;
                            report "stalled cycle at T-state " & integer'image(tstates)
                                 & ", address " & to_hstring(p_addr);
                        end if;
                        if p_iorq = '0' then kind := 2;
                        elsif p_wr = '0' then kind := 1;
                        else kind := 0;
                        end if;
                    end if;
                    run := run + 1;
                elsif run /= 0 then
                    if run > 15 then run := 15; end if;
                    case kind is
                        when 0 => h_rd(run) := h_rd(run) + 1; w_rd := w_rd + run;
                        when 1 => h_wr(run) := h_wr(run) + 1; w_wr := w_wr + run;
                        when others => h_io(run) := h_io(run) + 1; w_io := w_io + run;
                    end case;
                    run := 0;
                end if;
            end if;
            if sim_done and not reported then
                reported := true;
                report "=================================================";
                report "T-states from reset release to DONE: " & integer'image(tstates);
                show("memory reads (incl. opcode fetches)", h_rd, w_rd);
                show("memory writes", h_wr, w_wr);
                show("I/O cycles", h_io, w_io);
                if to_integer(unsigned(result)) = EXPECT_SUM then
                    report "checksum " & to_hstring(result) & " OK";
                else
                    report "checksum " & to_hstring(result) & " WRONG, expected "
                         & to_hstring(to_unsigned(EXPECT_SUM, 8)) severity error;
                end if;
                report "=================================================";
            end if;
        end if;
    end process;

    stopper: process
    begin
        wait until sim_done for 20 ms;
        wait for 1 us;
        if not sim_done then
            report "TIMEOUT: DONE_FLAG never written" severity error;
        end if;
        std.env.stop;
    end process;

end architecture sim;

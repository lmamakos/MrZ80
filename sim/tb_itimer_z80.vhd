-- tb_itimer_z80.vhd -- the IntervalTimer raising a Z80 interrupt through the
-- real MicrocomputerZ80CPM fabric (T80 + MMU + block RAM + the timer at
-- $D0-$D3), driven by sim/tb_itimer_z80.asm preloaded into block RAM.
--
-- The program checks itself (interrupt mode 0 and mode 1, wake from HALT,
-- level INT held while interrupts are disabled and released by ACK, EXPIRED /
-- OVERFLOW, one-shot, IE as a mask) and reports through fixed block-RAM
-- addresses that this bench watches on the DUT's block-RAM write bus:
--   0900h FAIL (0 = pass), 0901h DONE (0AAh), 0902h GOT, 0903h WANT.
-- Run from the project root:  sim/run_itimer_z80.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_itimer_z80 is
    generic (BIN : string := "/tmp/itimer_z80.bin");
end entity tb_itimer_z80;

architecture sim of tb_itimer_z80 is

    signal clk_sys : std_logic := '0';
    signal clk_ram : std_logic := '0';
    constant CLK_SYS_HALF_PERIOD : time := 10 ns;      -- 50 MHz
    constant CLK_RAM_HALF_PERIOD : time := 4.4643 ns;  -- ~112 MHz

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
    signal HS, VS, hBlank, vBlank, cepix         : std_logic;
    signal sdCS, sdMOSI, sdSCLK, driveLED        : std_logic;
    signal fpLED_serial                          : std_logic;

    signal probe_bram_addr : std_logic_vector(15 downto 0);
    signal probe_bram_data : std_logic_vector(7 downto 0);
    signal probe_bram_wren : std_logic;
    signal probe_n_int     : std_logic;

    signal sh_fail : std_logic_vector(7 downto 0) := x"FF";
    signal sh_got  : std_logic_vector(7 downto 0) := (others => '0');
    signal sh_want : std_logic_vector(7 downto 0) := (others => '0');
    signal sim_done : boolean := false;

    type char_file_t is file of character;

begin

    -- cpuClkCount / sdClkCount have no VHDL initial value; seed them as
    -- tb_inir_race does (simulation-only).
    seed_counters: process
    begin
        << signal .tb_itimer_z80.dut.cpuClkCount : std_logic_vector(5 downto 0) >> <= force "000000";
        << signal .tb_itimer_z80.dut.sdClkCount  : std_logic_vector(5 downto 0) >> <= force "000000";
        wait for 5 * (2 * CLK_SYS_HALF_PERIOD);
        << signal .tb_itimer_z80.dut.cpuClkCount : std_logic_vector(5 downto 0) >> <= release;
        << signal .tb_itimer_z80.dut.sdClkCount  : std_logic_vector(5 downto 0) >> <= release;
        wait;
    end process;

    clk_sys_gen: process
    begin
        clk_sys <= '0'; wait for CLK_SYS_HALF_PERIOD;
        clk_sys <= '1'; wait for CLK_SYS_HALF_PERIOD;
    end process;

    clk_ram_gen: process
    begin
        clk_ram <= '0'; wait for CLK_RAM_HALF_PERIOD;
        clk_ram <= '1'; wait for CLK_RAM_HALF_PERIOD;
    end process;

    dut: entity work.MicrocomputerZ80CPM(struct)
        port map(
            N_RESET        => N_RESET,
            clk            => clk_sys,
            baud_increment => x"00C9",

            rxd1 => '1', txd1 => txd1, rts1 => rts1, cts1 => '0',
            rxd2 => '1', txd2 => txd2, rts2 => rts2,

            videoSync => videoSync, video => video,
            R => R, G => G, B => B,
            HS => HS, VS => VS, hBlank => hBlank, vBlank => vBlank, cepix => cepix,

            ps2Clk => '1', ps2Data => '1',

            sdCS => sdCS, sdMOSI => sdMOSI, sdMISO => '1', sdSCLK => sdSCLK,
            driveLED => driveLED,

            fpLED_serial => fpLED_serial,

            sdram_addr  => sdram_addr,
            sdram_din   => sdram_din,
            sdram_we    => sdram_we,
            sdram_rd    => sdram_rd,
            sdram_dout  => sdram_dout,
            sdram_ready => sdram_ready,

            bin_loaded       => '1',
            boot_to_blockram => '1',

            dl_bram_addr => dl_bram_addr,
            dl_bram_data => dl_bram_data,
            dl_bram_we   => dl_bram_we
        );

    cdc: entity work.sdram_cdc_fake(sim)
        port map(
            clk_sys         => clk_sys,
            clk_ram         => clk_ram,
            sdram_we_mux    => sdram_we,
            sdram_rd_mux    => sdram_rd,
            sdram_addr_mux  => sdram_addr,
            sdram_din_mux   => sdram_din,
            sdram_ready_mux => sdram_ready,
            sdram_dout_mux  => sdram_dout
        );

    probe_bram_addr <= << signal .tb_itimer_z80.dut.bram_address : std_logic_vector(15 downto 0) >>;
    probe_bram_data <= << signal .tb_itimer_z80.dut.bram_data    : std_logic_vector(7 downto 0)  >>;
    probe_bram_wren <= << signal .tb_itimer_z80.dut.bram_wren    : std_logic >>;
    probe_n_int     <= << signal .tb_itimer_z80.dut.n_INT_ssp    : std_logic >>;

    preload: process
        file f       : char_file_t open read_mode is BIN;
        variable c   : character;
        variable addr: integer := 0;
    begin
        N_RESET    <= '0';
        dl_bram_we <= '0';
        wait for 200 ns;
        while not endfile(f) loop
            read(f, c);
            dl_bram_addr <= std_logic_vector(to_unsigned(addr, 16));
            dl_bram_data <= std_logic_vector(to_unsigned(character'pos(c), 8));
            dl_bram_we   <= '1';
            wait until rising_edge(clk_sys);
            addr := addr + 1;
        end loop;
        file_close(f);
        dl_bram_we <= '0';
        wait for 200 ns;
        report "preload done: " & integer'image(addr) & " bytes";
        N_RESET <= '1';
        wait;
    end process;

    monitor: process(clk_sys)
        variable a : integer;
    begin
        if rising_edge(clk_sys) then
            if probe_bram_wren = '1' then
                a := to_integer(unsigned(probe_bram_addr));
                case a is
                    when 16#0900# => sh_fail <= probe_bram_data;
                    when 16#0902# => sh_got  <= probe_bram_data;
                    when 16#0903# => sh_want <= probe_bram_data;
                    when 16#0901# =>
                        if probe_bram_data = x"AA" then sim_done <= true; end if;
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- INT must be an exact level: count the clocks it is asserted and the
    -- number of separate assertions seen over the run.
    int_watch: process(clk_sys)
        variable prev : std_logic := '1';
        variable n    : natural := 0;
    begin
        if rising_edge(clk_sys) then
            if probe_n_int = '0' and prev = '1' then n := n + 1; end if;
            prev := probe_n_int;
            if sim_done and n > 0 then
                report "INT asserted " & integer'image(n) & " times";
                n := 0;
            end if;
        end if;
    end process;

    report_proc: process
    begin
        wait until sim_done for 30 ms;
        wait for 500 ns;
        if not sim_done then
            report "FAIL: tb_itimer_z80: timeout, the program did not finish" severity failure;
        elsif sh_fail /= x"00" then
            report "FAIL: tb_itimer_z80: check " & integer'image(to_integer(unsigned(sh_fail)))
                 & " got " & to_hstring(sh_got) & " want " & to_hstring(sh_want) severity failure;
        else
            report "PASS: tb_itimer_z80 at " & time'image(now);
        end if;
        std.env.stop;
    end process;

end architecture sim;

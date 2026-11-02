-- tb_itimer_z80.vhd -- the IntervalTimer raising a Z80 interrupt through the
-- real MicrocomputerZ80CPM fabric (T80 + MMU + block RAM + the timer at
-- $D0-$D3), driven by sim/tb_itimer_z80.asm preloaded into block RAM.
--
-- The program checks itself (interrupt mode 0 and mode 1, wake from HALT,
-- level INT held while interrupts are disabled and released by ACK, EXPIRED /
-- OVERFLOW, one-shot, IE as a mask) and reports through fixed block-RAM
-- addresses that this bench watches on the DUT's block-RAM write bus:
--   0900h FAIL (0 = pass), 0901h DONE (0AAh), 0902h GOT, 0903h WANT.
-- It also watches the front-panel capture chain's last segment (fpChainEnd,
-- chain positions 260-291, see SIGNAL-CAPTURES.md): /WR dark right after reset,
-- the timer's interrupt request and the CPU INT pin lit by the interrupts,
-- the unwired ACIA interrupt bits and the reserved bits never lit.
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
    signal chain_end       : std_logic_vector(31 downto 0);
    signal chain_raw       : std_logic_vector(31 downto 0);

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
    -- fpChainEnd's per-bit (stretched / transparent) output, before the shifter.
    -- Bit 15 = timer INT request, 14/13 = ACIA INT outputs, 12 = INT at the CPU,
    -- 11:8 = /WR /RD /MREQ /IORQ, 7:0 = fpLatch; 31:16 are reserved zeros.
    chain_end       <= << signal .tb_itimer_z80.dut.fpChainEnd.captured_bits : std_logic_vector(31 downto 0) >>;
    -- ...and the raw inputs it is fed, to prove the stretched bits are HELD.
    chain_raw       <= << signal .tb_itimer_z80.dut.fpChainEnd.combined_data : std_logic_vector(31 downto 0) >>;

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

    -- Capture chain: the /WR bit is a stretched, active-high copy of the strobe,
    -- so it must be dark just after reset while the bus is idle (the CPU's
    -- first write is several microseconds away).  A missing inversion makes it
    -- light the moment reset ends.
    chain_wr_idle: process
    begin
        wait until N_RESET = '1';
        wait for 1 us;
        assert chain_end(11) = '0'
            report "FAIL: tb_itimer_z80: capture chain /WR lit while idle after reset"
            severity failure;
        wait;
    end process;

    chain_watch: process(clk_sys)
        variable seen_tmr, seen_cpu, seen_wr, seen_rd, seen_mreq, seen_iorq : boolean := false;
        variable bad_acia, bad_rsvd : boolean := false;
        -- Consecutive clocks each bit has been lit while its raw input is low:
        -- only a hold counter can do that (a registered copy lags by one clock).
        type cnt_t is array (15 downto 8) of natural;
        variable held   : cnt_t := (others => 0);
        variable stretched : std_logic_vector(15 downto 8) := (others => '0');
    begin
        if rising_edge(clk_sys) then
            for i in 15 downto 8 loop
                if chain_raw(i) = '0' and chain_end(i) = '1' then
                    held(i) := held(i) + 1;
                    if held(i) >= 100 then stretched(i) := '1'; end if;
                else
                    held(i) := 0;
                end if;
            end loop;
            if chain_end(15) = '1' then seen_tmr  := true; end if;
            if chain_end(12) = '1' then seen_cpu  := true; end if;
            if chain_end(11) = '1' then seen_wr   := true; end if;
            if chain_end(10) = '1' then seen_rd   := true; end if;
            if chain_end(9)  = '1' then seen_mreq := true; end if;
            if chain_end(8)  = '1' then seen_iorq := true; end if;
            if chain_end(14) = '1' or chain_end(13) = '1' then bad_acia := true; end if;
            if chain_end(31 downto 16) /= x"0000" then bad_rsvd := true; end if;
            if sim_done then
                assert seen_tmr  report "FAIL: tb_itimer_z80: capture chain 276 (timer INT) never lit" severity failure;
                assert seen_cpu  report "FAIL: tb_itimer_z80: capture chain 279 (CPU INT) never lit"   severity failure;
                assert seen_wr   report "FAIL: tb_itimer_z80: capture chain 280 (/WR) never lit"       severity failure;
                assert seen_rd   report "FAIL: tb_itimer_z80: capture chain 281 (/RD) never lit"       severity failure;
                assert seen_mreq report "FAIL: tb_itimer_z80: capture chain 282 (/MREQ) never lit"     severity failure;
                assert seen_iorq report "FAIL: tb_itimer_z80: capture chain 283 (/IORQ) never lit"     severity failure;
                -- Bits that go idle for >= 100 clocks must be HELD through the idle
                -- stretch: /IORQ (8), /WR (11), INT_CPU (12), INT_TMR (15).  /MREQ
                -- (9) and /RD (10) toggle every few clocks even while the CPU waits
                -- in HALT, so they have no idle gap long enough to show a hold;
                -- they share the same generate branch and only need to be seen.
                for i in 8 to 12 loop
                    if i /= 9 and i /= 10 then
                        assert stretched(i) = '1'
                            report "FAIL: tb_itimer_z80: capture chain bit " & integer'image(i)
                                 & " is not pulse-stretched" severity failure;
                    end if;
                end loop;
                assert stretched(15) = '1'
                    report "FAIL: tb_itimer_z80: capture chain bit 15 (timer INT) is not pulse-stretched"
                    severity failure;
                assert not bad_acia report "FAIL: tb_itimer_z80: capture chain 277/278 (ACIA INT, unwired) lit" severity failure;
                assert not bad_rsvd report "FAIL: tb_itimer_z80: capture chain 260-275 (reserved) lit" severity failure;
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

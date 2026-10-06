-- ============================================================================
-- tb_inir_race.vhd - reproduces (or refutes) the testing/backtoback.asm
-- Phase A2/A3 finding: the very first INIR-driven read of the MMU
-- direct-access port (0xBC), writing into a block-RAM destination,
-- intermittently/deterministically captures the WRONG byte.
--
-- Architecture: instantiates the real MicrocomputerZ80CPM logic (T80 CPU +
-- MMU + sdram_fsm, via the simulation copy sim/MicrocomputerZ80CPM_sim.vhd
-- -- see sim_compat_pkg.vhd for why a copy is needed at all) driven by a
-- free-running clk_sys, and drives its sdram_addr/din/we/rd/dout/ready
-- ports through sim/sdram_cdc_fake.vhd, a faithful VHDL translation of
-- MultiComp.sv's exact 2-FF request/done clock-domain-crossing
-- synchroniser (MultiComp.sv:260-320), running on an independent
-- free-running clk_ram, feeding a small behavioral stand-in for the real
-- SDRAM controller's CPU-port handshake timing.
--
-- The Z-80 program (sim/sim_inir_race.asm, preloaded directly into block
-- RAM via the dl_bram_* download port while the CPU is held in reset)
-- sweeps a variable-length NOP preamble before each of 200 outer
-- iterations' single INIR read, so that -- regardless of the exact
-- clk_sys/clk_ram frequency ratio used here -- many different relative
-- phases between the CPU's bus activity and the async clk_ram domain get
-- sampled across the run, mirroring how varying amounts of preceding
-- "unrelated" code on real hardware were shown (Phase A3) to still hit the
-- same bug.
--
-- Results are observed by monitoring writes to a set of fixed block-RAM
-- addresses live, via a VHDL-2008 external name probe on the DUT's
-- internal block-RAM write bus (bram_address/bram_data/bram_wren) --
-- avoids needing to implement a UART receiver just to read results back.
--
-- RUN: sim/run.sh (from anywhere; it cd's to the project root itself).
-- See sim/STATUS.md for current status, known simulation-only gotchas
-- already worked around, and the open blocker as of this writing.
-- A full 200-iteration sweep needs ~20-25ms of simulated time (see
-- run.sh's --stop-time=25ms); override with sim/run.sh <workdir> and
-- editing that value directly for quicker iteration while debugging.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_inir_race is
end entity tb_inir_race;

architecture sim of tb_inir_race is

    -- ---- clocks ----
    signal clk_sys : std_logic := '0';
    signal clk_ram : std_logic := '0';
    constant CLK_SYS_HALF_PERIOD : time := 10 ns;      -- 50 MHz
    constant CLK_RAM_HALF_PERIOD : time := 4.4643 ns;  -- ~112 MHz

    -- ---- DUT control ----
    signal N_RESET : std_logic := '0';

    signal dl_bram_addr : std_logic_vector(15 downto 0) := (others => '0');
    signal dl_bram_data : std_logic_vector(7 downto 0)  := (others => '0');
    signal dl_bram_we   : std_logic := '0';

    -- ---- SDRAM client interface between DUT and the fake CDC/controller ----
    signal sdram_addr  : std_logic_vector(26 downto 0);
    signal sdram_din   : std_logic_vector(7 downto 0);
    signal sdram_we    : std_logic;
    signal sdram_rd    : std_logic;
    signal sdram_dout  : std_logic_vector(7 downto 0);
    signal sdram_ready : std_logic;

    -- ---- unused DUT outputs (tied to open via intermediate signals where
    --      "open" isn't legal, i.e. never -- all of these are just probes
    --      we don't inspect) ----
    signal txd1, rts1, txd2, rts2               : std_logic;
    signal videoSync, video                     : std_logic;
    signal R, G, B                              : std_logic_vector(1 downto 0);
    signal HS, VS, hBlank, vBlank, cepix         : std_logic;
    signal sdCS, sdMOSI, sdSCLK, driveLED        : std_logic;
    signal fpLED_serial                          : std_logic;

    -- ---- external-name probe onto the DUT's internal block-RAM write bus ----
    signal probe_bram_addr : std_logic_vector(15 downto 0);
    signal probe_bram_data : std_logic_vector(7 downto 0);
    signal probe_bram_wren : std_logic;

    -- ---- shadow copies of the fixed result addresses, updated live as
    --      writes are observed (see sim/sim_inir_race.asm's memory map) ----
    signal shadow_miscnt_lo     : std_logic_vector(7 downto 0) := (others => '0');
    signal shadow_miscnt_hi     : std_logic_vector(7 downto 0) := (others => '0');
    signal shadow_fail_recorded : std_logic_vector(7 downto 0) := (others => '0');
    signal shadow_fail_delay    : std_logic_vector(7 downto 0) := (others => '0');
    signal shadow_fail_offset   : std_logic_vector(7 downto 0) := (others => '0');
    signal shadow_fail_exp      : std_logic_vector(7 downto 0) := (others => '0');
    signal shadow_fail_got      : std_logic_vector(7 downto 0) := (others => '0');
    signal shadow_iters_done    : std_logic_vector(7 downto 0) := (others => '0');
    signal shadow_done_flag     : std_logic_vector(7 downto 0) := (others => '0');

    signal sim_done : boolean := false;

    -- ---- temporary debug probes ----
    signal dbg_reset_n_internal : std_logic;
    signal dbg_mmu_phys_addr    : std_logic_vector(27 downto 0);
    signal dbg_cpuAddress       : std_logic_vector(15 downto 0);
    signal dbg_n_MREQ           : std_logic;
    signal dbg_n_RD             : std_logic;
    signal dbg_n_WR             : std_logic;
    signal dbg_cpu_wait_n       : std_logic;
    signal dbg_mmu_cpu_wait     : std_logic;
    signal dbg_sdram_wait_n     : std_logic;

    type char_file_t is file of character;

begin

    -- ================= seed uninitialized DUT counters =================
    -- MicrocomputerZ80CPM.vhd's cpuClkCount/sdClkCount (the clk-divider
    -- counters that generate cpu_cen/sdClock) have no VHDL initial value,
    -- so they start as 'U' ("UUUUUU") in simulation -- real FPGA registers
    -- always power up to a determinate 0/1, so this is a simulation-only
    -- gap, not a real hardware behaviour. Worse, cpuClkCount's own
    -- `if cpuClkCount < 4` guard (via sim_compat_pkg's "<" operator, a
    -- to_integer-based comparison) reads a metavalue as integer 0, which
    -- is ALWAYS < 4 -- so the counter never takes its `else` branch to
    -- reset to a defined value, and instead stays "UUUUUU" (arithmetic on
    -- an all-U unsigned stays all-U) forever, which means cpu_cen (gated
    -- by cpuClkCount) never toggles and the Z-80 core never runs at all.
    -- Force both counters to a defined 0 for the first few ns (a standard,
    -- simulation-only testbench technique for seeding otherwise-U
    -- registers), then release control back to the DUT's own logic.
    seed_counters: process
    begin
        << signal .tb_inir_race.dut.cpuClkCount : std_logic_vector(5 downto 0) >> <= force "000000";
        << signal .tb_inir_race.dut.sdClkCount  : std_logic_vector(5 downto 0) >> <= force "000000";
        -- Hold the force through several clk_sys edges so the DUT's own
        -- clocked process actually reads a determinate "000000" on a real
        -- rising edge and computes its OWN determinate next value
        -- underneath the force; releasing too early (before any edge)
        -- just reverts to the process's still-undriven 'U' output.
        wait for 5 * (2 * CLK_SYS_HALF_PERIOD);
        << signal .tb_inir_race.dut.cpuClkCount : std_logic_vector(5 downto 0) >> <= release;
        << signal .tb_inir_race.dut.sdClkCount  : std_logic_vector(5 downto 0) >> <= release;
        wait for 2 ns;
        report "SEED CHECK @" & time'image(now)
             & " cpuClkCount=" & to_hstring(<< signal .tb_inir_race.dut.cpuClkCount : std_logic_vector(5 downto 0) >>)
             & " cpu_cen=" & std_logic'image(<< signal .tb_inir_race.dut.cpu_cen : std_logic >>);
        wait for 100 ns;
        report "SEED CHECK @" & time'image(now)
             & " cpuClkCount=" & to_hstring(<< signal .tb_inir_race.dut.cpuClkCount : std_logic_vector(5 downto 0) >>)
             & " cpu_cen=" & std_logic'image(<< signal .tb_inir_race.dut.cpu_cen : std_logic >>);
        wait;
    end process;

    -- ================= clocks =================
    clk_sys_gen: process
    begin
        clk_sys <= '0';
        wait for CLK_SYS_HALF_PERIOD;
        clk_sys <= '1';
        wait for CLK_SYS_HALF_PERIOD;
    end process;

    clk_ram_gen: process
    begin
        clk_ram <= '0';
        wait for CLK_RAM_HALF_PERIOD;
        clk_ram <= '1';
        wait for CLK_RAM_HALF_PERIOD;
    end process;

    -- ================= DUT =================
    dut: entity work.MicrocomputerZ80CPM(struct)
        port map(
            N_RESET        => N_RESET,
            clk            => clk_sys,
            baud_increment => x"00C9",   -- 201 -> 9600 baud (unused, but must be valid)

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

    -- ================= fake SDRAM CDC + controller =================
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

    -- ================= block-RAM write-bus probe (VHDL-2008 external names) =========
    probe_bram_addr <= << signal .tb_inir_race.dut.bram_address : std_logic_vector(15 downto 0) >>;
    probe_bram_data <= << signal .tb_inir_race.dut.bram_data    : std_logic_vector(7 downto 0)  >>;
    probe_bram_wren <= << signal .tb_inir_race.dut.bram_wren    : std_logic >>;

    -- ================= preload sim_inir_race.bin into block RAM =================
    -- Run from the project root so this relative path resolves; see sim/run.sh.
    preload: process
        file f       : char_file_t open read_mode is "sim/sim_inir_race.bin";
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
        report "preload done: " & integer'image(addr) & " bytes loaded, releasing N_RESET";
        N_RESET <= '1';
        wait;
    end process;

    -- ================= live result monitor =================
    monitor: process(clk_sys)
        variable a : integer;
    begin
        if rising_edge(clk_sys) then
            if probe_bram_wren = '1' then
                a := to_integer(unsigned(probe_bram_addr));
                -- Uncomment to trace every write into the INIR scratch
                -- buffer (0x1000-0x1010), e.g. to check whether the
                -- destination address is actually incrementing (see
                -- sim/STATUS.md's "HL not incrementing during INIR" note):
                -- if a >= 16#1000# and a <= 16#1010# then
                --     report "BUF WRITE @" & time'image(now) & " addr=" & to_hstring(probe_bram_addr) & " data=" & to_hstring(probe_bram_data)
                --          & " cpuAddress=" & to_hstring(dbg_cpuAddress);
                -- end if;
                case a is
                    when 16#0900# => shadow_miscnt_lo     <= probe_bram_data;
                    when 16#0901# => shadow_miscnt_hi     <= probe_bram_data;
                    when 16#0902# => shadow_fail_recorded <= probe_bram_data;
                    when 16#0903# => shadow_fail_delay    <= probe_bram_data;
                    when 16#0904# => shadow_fail_offset   <= probe_bram_data;
                    when 16#0905# => shadow_fail_exp      <= probe_bram_data;
                    when 16#0906# => shadow_fail_got      <= probe_bram_data;
                    when 16#0907# => shadow_iters_done    <= probe_bram_data;
                    when 16#0908# =>
                        shadow_done_flag <= probe_bram_data;
                        if probe_bram_data = x"AA" then
                            sim_done <= true;
                        end if;
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- ================= DEBUG PROBES (temporary) =================
    dbg_reset_n_internal <= << signal .tb_inir_race.dut.reset_n_internal : std_logic >>;
    dbg_mmu_phys_addr    <= << signal .tb_inir_race.dut.mmu_phys_addr : std_logic_vector(27 downto 0) >>;
    dbg_cpuAddress       <= << signal .tb_inir_race.dut.cpuAddress : std_logic_vector(15 downto 0) >>;
    dbg_n_MREQ           <= << signal .tb_inir_race.dut.n_MREQ : std_logic >>;
    dbg_n_RD             <= << signal .tb_inir_race.dut.n_RD : std_logic >>;
    dbg_n_WR             <= << signal .tb_inir_race.dut.n_WR : std_logic >>;
    dbg_cpu_wait_n       <= << signal .tb_inir_race.dut.cpu_wait_n : std_logic >>;
    dbg_mmu_cpu_wait     <= << signal .tb_inir_race.dut.mmu_cpu_wait : std_logic >>;
    dbg_sdram_wait_n     <= << signal .tb_inir_race.dut.sdram_wait_n : std_logic >>;

    -- ================= final report / watchdog =================
    report_proc: process
    begin
        wait until sim_done for 20 ms;
        wait for 500 ns;  -- let shadow signals settle after the last write
        report "=================================================";
        if sim_done then
            report "sim_inir_race: TEST COMPLETED";
        else
            report "sim_inir_race: TIMEOUT waiting for DONE_FLAG -- results below are PARTIAL";
        end if;
        report "  iterations done : " & integer'image(to_integer(unsigned(shadow_iters_done)));
        report "  mismatch count  : " & integer'image(to_integer(unsigned(shadow_miscnt_hi & shadow_miscnt_lo)));
        report "  first mismatch recorded : " & integer'image(to_integer(unsigned(shadow_fail_recorded)));
        if shadow_fail_recorded /= x"00" then
            report "    preamble delay (D) : " & integer'image(to_integer(unsigned(shadow_fail_delay)));
            report "    byte offset        : " & integer'image(to_integer(unsigned(shadow_fail_offset)));
            report "    expected           : " & integer'image(to_integer(unsigned(shadow_fail_exp)));
            report "    got                : " & integer'image(to_integer(unsigned(shadow_fail_got)));
        end if;
        report "=================================================";
        std.env.stop;
    end process;

end architecture sim;

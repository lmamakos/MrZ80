-- ============================================================================
-- tb_blockdev_prog.vhd - runs testing/blockdevtest.asm (assembled -D SIM) on
-- the real MicrocomputerZ80CPM against a behavioural model of the HPS side of
-- hps_io's block interface, end to end:
--
--   Z-80 program -> I/O ports 90h-97h -> hps_blockdev -> sd_lba/sd_rd/sd_wr/
--   sd_ack/sd_buff_* -> "image file" array in this testbench.
--
-- Same system as tb_sdram_perf (T80s, MMU, sdram_cdc_fake, ...); the program
-- runs from block RAM. Console output (writes to port 83h) is captured and
-- echoed line by line. When the program writes DONE_FLAG (3FF8h = AAh), the
-- testbench checks the result byte (3FF0h) and that the image is again
-- identical to its initial contents (the program restores what it writes).
--
-- Generics (see sim/run_blockdev_prog.sh for the configurations run):
--   NBLK        image size in 512-byte blocks
--   READONLY    mount the image read-only
--   MOUNT_US    delay before the image is mounted (exercises T1 waiting)
--   FAULT       0 none, 1 HPS drops writes to the last block, 2 HPS stores
--               writes to (lba AND NOT 1): the program must report FAILURE
--   EXPECT_FAIL true if the program is expected to end with a failure
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_blockdev_prog is
    generic (
        BIN         : string  := "/tmp/sim_blockdev_prog_build/blockdevtest_sim.bin";
        NBLK        : natural := 16;
        READONLY    : boolean := false;
        MOUNT_US    : natural := 0;
        FAULT       : natural := 0;
        EXPECT_FAIL : boolean := false;
        MAX_MS      : natural := 2000
    );
end entity tb_blockdev_prog;

architecture sim of tb_blockdev_prog is

    signal clk_sys : std_logic := '0';
    signal clk_ram : std_logic := '0';
    constant CLK_SYS_HALF : time := 10 ns;
    constant CLK_RAM_HALF : time := 5.172 ns;

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

    -- hps_blockdev <-> HPS model
    signal bd_lba       : std_logic_vector(31 downto 0);
    signal bd_rd        : std_logic;
    signal bd_wr        : std_logic;
    signal bd_ack       : std_logic := '0';
    signal bd_buff_addr : std_logic_vector(8 downto 0) := (others => '0');
    signal bd_buff_dout : std_logic_vector(7 downto 0) := (others => '0');
    signal bd_buff_din  : std_logic_vector(7 downto 0);
    signal bd_buff_wr   : std_logic := '0';
    signal bd_mounted   : std_logic := '0';
    signal bd_readonly  : std_logic := '0';
    signal bd_size      : std_logic_vector(63 downto 0) := (others => '0');
    signal bd_activity  : std_logic;

    -- probes into the DUT
    signal p_bram_addr : std_logic_vector(15 downto 0);
    signal p_bram_data : std_logic_vector(7 downto 0);
    signal p_bram_wren : std_logic;
    signal p_iorq, p_wr : std_logic;
    signal p_addr      : std_logic_vector(15 downto 0);
    signal p_dout      : std_logic_vector(7 downto 0);

    type image_t is array (0 to NBLK*512-1) of std_logic_vector(7 downto 0);
    signal image   : image_t;
    signal image0  : image_t;                     -- initial contents
    signal hps_reads, hps_writes : natural := 0;

    signal result   : std_logic_vector(7 downto 0) := x"EE";
    signal sim_done : boolean := false;

    type file_t is file of character;

    function init_byte(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i * 13 + (i / 512) * 29 + 3) mod 256, 8));
    end function;

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
            dl_bram_we => dl_bram_we,
            bd_lba => bd_lba, bd_rd => bd_rd, bd_wr => bd_wr, bd_ack => bd_ack,
            bd_buff_addr => bd_buff_addr, bd_buff_dout => bd_buff_dout,
            bd_buff_din => bd_buff_din, bd_buff_wr => bd_buff_wr,
            bd_img_mounted => bd_mounted, bd_img_readonly => bd_readonly,
            bd_img_size => bd_size, bd_activity => bd_activity
        );

    cdc: entity work.sdram_cdc_fake(sim)
        port map(
            clk_sys => clk_sys, clk_ram => clk_ram,
            sdram_we_mux => sdram_we, sdram_rd_mux => sdram_rd,
            sdram_addr_mux => sdram_addr, sdram_din_mux => sdram_din,
            sdram_ready_mux => sdram_ready, sdram_dout_mux => sdram_dout
        );

    p_bram_addr <= << signal .tb_blockdev_prog.dut.bram_address : std_logic_vector(15 downto 0) >>;
    p_bram_data <= << signal .tb_blockdev_prog.dut.bram_data    : std_logic_vector(7 downto 0)  >>;
    p_bram_wren <= << signal .tb_blockdev_prog.dut.bram_wren    : std_logic >>;
    p_iorq      <= << signal .tb_blockdev_prog.dut.n_IORQ       : std_logic >>;
    p_wr        <= << signal .tb_blockdev_prog.dut.n_WR         : std_logic >>;
    p_addr      <= << signal .tb_blockdev_prog.dut.cpuAddress   : std_logic_vector(15 downto 0) >>;
    p_dout      <= << signal .tb_blockdev_prog.dut.cpuDataOut   : std_logic_vector(7 downto 0)  >>;

    seed: process
    begin
        << signal .tb_blockdev_prog.dut.sdClkCount : std_logic_vector(5 downto 0) >> <= force "000000";
        wait for 100 ns;
        << signal .tb_blockdev_prog.dut.sdClkCount : std_logic_vector(5 downto 0) >> <= release;
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

    -- ---------------------------------------------------------- HPS model
    -- Mounts the image after MOUNT_US, then services sd_rd / sd_wr requests
    -- the way hps_io does: ack goes high, the block is streamed through
    -- sd_buff_*, ack goes low.
    hps: process
        variable blk   : integer;
        variable wblk  : integer;
        variable first : boolean := true;
    begin
        if first then
            for i in 0 to NBLK*512-1 loop
                image(i)  <= init_byte(i);
                image0(i) <= init_byte(i);
            end loop;
            first := false;
            wait for 100 ns;
            if MOUNT_US > 0 then
                wait for MOUNT_US * 1 us;
            end if;
            bd_size     <= std_logic_vector(to_unsigned(NBLK*512, 64));
            if READONLY then bd_readonly <= '1'; end if;
            wait until rising_edge(clk_sys);
            bd_mounted <= '1';
            wait until rising_edge(clk_sys);
            wait until rising_edge(clk_sys);
            bd_mounted <= '0';
        end if;
        wait until rising_edge(clk_sys);
        if bd_rd = '1' or bd_wr = '1' then
            blk := to_integer(unsigned(bd_lba(23 downto 0)));
            for i in 1 to 30 loop wait until rising_edge(clk_sys); end loop;
            bd_ack <= '1';
            for i in 1 to 5 loop wait until rising_edge(clk_sys); end loop;
            if bd_rd = '1' then
                for i in 0 to 511 loop
                    bd_buff_addr <= std_logic_vector(to_unsigned(i, 9));
                    bd_buff_dout <= image(blk*512 + i);
                    for k in 1 to 6 loop wait until rising_edge(clk_sys); end loop;
                    bd_buff_wr <= '1';
                    wait until rising_edge(clk_sys);
                    bd_buff_wr <= '0';
                    for k in 1 to 4 loop wait until rising_edge(clk_sys); end loop;
                end loop;
                hps_reads <= hps_reads + 1;
            else
                wblk := blk;
                if FAULT = 2 then
                    wblk := (blk / 2) * 2;                -- address bit 0 stuck
                end if;
                for i in 0 to 511 loop
                    bd_buff_addr <= std_logic_vector(to_unsigned(i, 9));
                    for k in 1 to 8 loop wait until rising_edge(clk_sys); end loop;
                    if not (FAULT = 1 and blk = NBLK-1) then
                        image(wblk*512 + i) <= bd_buff_din;
                    end if;
                end loop;
                hps_writes <= hps_writes + 1;
            end if;
            for i in 1 to 10 loop wait until rising_edge(clk_sys); end loop;
            bd_ack <= '0';
            for i in 1 to 20 loop wait until rising_edge(clk_sys); end loop;
        end if;
    end process;

    -- ------------------------------------------------------ console capture
    console: process(clk_sys)
        variable line_buf : string(1 to 200);
        variable n        : natural := 0;
        variable was_wr   : boolean := false;
        variable ch       : integer;
        variable now_wr   : boolean;
    begin
        if rising_edge(clk_sys) then
            now_wr := (p_iorq = '0' and p_wr = '0' and p_addr(7 downto 0) = x"83");
            if now_wr and not was_wr then
                ch := to_integer(unsigned(p_dout));
                if ch = 10 then
                    report "| " & line_buf(1 to n);
                    n := 0;
                elsif ch /= 13 then
                    if n < 200 then
                        n := n + 1;
                        line_buf(n) := character'val(ch);
                    end if;
                end if;
            end if;
            was_wr := now_wr;
        end if;
    end process;

    -- ------------------------------------------------------ result watcher
    watch: process(clk_sys)
        variable last : std_logic_vector(15 downto 0) := (others => '1');
    begin
        if rising_edge(clk_sys) and p_bram_wren = '0' then
            last := (others => '1');
        end if;
        if rising_edge(clk_sys) and p_bram_wren = '1' and p_bram_addr /= last then
            last := p_bram_addr;
            if unsigned(p_bram_addr) = 16#3FF0# then
                result <= p_bram_data;
            elsif unsigned(p_bram_addr) = 16#3FF8# and p_bram_data = x"AA" then
                sim_done <= true;
            end if;
        end if;
    end process;

    checker: process
        variable diffs : natural := 0;
        variable ok    : boolean := true;
    begin
        wait until sim_done for MAX_MS * 1 ms;
        wait for 1 us;
        if not sim_done then
            report "FAIL: TIMEOUT, program never finished" severity error;
            std.env.stop;
        end if;
        for i in 0 to NBLK*512-1 loop
            if image(i) /= image0(i) then diffs := diffs + 1; end if;
        end loop;
        report "program result byte = " & to_hstring(result)
             & ", HPS reads " & integer'image(hps_reads)
             & ", HPS writes " & integer'image(hps_writes)
             & ", image bytes differing from initial: " & integer'image(diffs);
        if EXPECT_FAIL then
            if result = x"00" then
                report "FAIL: expected the program to report a failure" severity error;
                ok := false;
            end if;
        else
            if result /= x"00" then
                report "FAIL: program reported failures" severity error;
                ok := false;
            end if;
            if diffs /= 0 then
                report "FAIL: image not restored" severity error;
                ok := false;
            end if;
            if hps_writes = 0 and not READONLY then
                report "FAIL: no writes reached the image" severity error;
                ok := false;
            end if;
            if READONLY and hps_writes /= 0 then
                report "FAIL: writes to a read-only image" severity error;
                ok := false;
            end if;
        end if;
        if ok then
            report "PASS: tb_blockdev_prog";
        end if;
        std.env.stop;
    end process;

end architecture sim;

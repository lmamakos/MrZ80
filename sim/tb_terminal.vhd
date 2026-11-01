-- tb_terminal.vhd -- R44: the video terminal (Components/TERMINAL/
-- SBCTextDisplayRGB.vhd) and the SSP's own instance (ssp/rtl/ssp_vdu.vhd).
-- Run by sim/run_terminal.sh (`make -C sim terminal`).
--
--   A  register interface sampled on clk: status after power-up, display
--      writes (the cursor advances), Z80-length strobes
--   B  6850 master reset: status reads 0, data writes are ignored, the
--      keyboard buffer is emptied, the next control write ends it
--   C  keyboard: letters, ESC = 1B, Delete = 7F, arrows / Home / Ins / F1 / F5
--      as sequences, key releases send nothing
--   D  16-entry buffer: 20 keys unread -> the first 15 kept in order, no wrap
--   E  kbEnable: with the SSP screen shown the Z80's terminal keeps no keys and
--      ssp_vdu delivers them on its byte port; its tx port writes its screen
--   F  the serial ACIA (bufferedUART) honours a master reset the same way

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_terminal is
end entity tb_terminal;

architecture tb of tb_terminal is
    constant TCLK : time := 20 ns;                 -- 50 MHz
    constant PS2H : time := 2 us;                  -- PS/2 clock half period

    signal clk     : std_logic := '0';
    signal done    : boolean := false;
    signal n_wr, n_rd : std_logic := '1';
    signal regSel  : std_logic := '0';
    signal dataIn, dataOut : std_logic_vector(7 downto 0) := (others => '0');
    signal ps2Clk, ps2Data : std_logic := '1';
    signal show    : std_logic := '0';
    signal kb_en   : std_logic;

    signal tx_valid, tx_ready, rx_valid, rx_take : std_logic := '0';
    signal tx_data, rx_data : std_logic_vector(7 downto 0) := (others => '0');
    signal R, G, B : std_logic_vector(1 downto 0);

    signal checks, fails : natural := 0;
    signal u_n_wr, u_n_rd : std_logic := '1';
    signal u_dout : std_logic_vector(7 downto 0);
begin
    clk <= not clk after TCLK / 2 when not done;
    kb_en <= not show;

    z80term : entity work.SBCTextDisplayRGB
    port map (
        n_reset => '1', clk => clk, n_wr => n_wr, n_rd => n_rd, regSel => regSel,
        dataIn => dataIn, dataOut => dataOut, n_int => open, n_rts => open,
        videoR0 => open, videoR1 => open, videoG0 => open, videoG1 => open,
        videoB0 => open, videoB1 => open, hSync => open, vSync => open,
        hBlank => open, vBlank => open, cepix => open, video => open,
        sync => open, ps2Clk => ps2Clk, ps2Data => ps2Data,
        FNkeys => open, FNtoggledKeys => open,
        kbEnable => kb_en, txReady => open, kbAvail => open
    );

    uart : entity work.bufferedUART
    port map (
        clk => clk, n_wr => u_n_wr, n_rd => u_n_rd, n_int => open,
        regSel => regSel, dataIn => dataIn, dataOut => u_dout,
        rxClock => clk, txClock => clk, rxd => '1', txd => open,
        n_rts => open, n_cts => '0', n_dcd => '0'
    );

    vdu : entity work.ssp_vdu
    port map (
        clk => clk, n_reset => '1', show => show,
        tx_valid => tx_valid, tx_data => tx_data, tx_ready => tx_ready,
        rx_valid => rx_valid, rx_data => rx_data, rx_take => rx_take,
        ps2Clk => ps2Clk, ps2Data => ps2Data, R => R, G => G, B => B
    );

    stim : process
        alias z80_cursor is << signal .tb_terminal.z80term.cursorHoriz : integer range 0 to 79 >>;
        alias vdu_cursor is << signal .tb_terminal.vdu.term.cursorHoriz : integer range 0 to 79 >>;

        procedure check(ok : boolean; msg : string) is
        begin
            checks <= checks + 1;
            if not ok then
                fails <= fails + 1;
                report "FAIL: " & msg severity error;
            end if;
            wait for 0 ns;
        end procedure;

        -- a Z80-like I/O cycle: strobe low for 15 clocks (an I/O cycle with its
        -- wait state is ~4 T-states of 5 clocks)
        procedure cpu_wr(sel : std_logic; d : std_logic_vector(7 downto 0)) is
        begin
            wait until rising_edge(clk);
            regSel <= sel; dataIn <= d;
            wait until rising_edge(clk);
            n_wr <= '0';
            for i in 1 to 15 loop wait until rising_edge(clk); end loop;
            n_wr <= '1';
            for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure cpu_rd(sel : std_logic; d : out std_logic_vector(7 downto 0)) is
        begin
            wait until rising_edge(clk);
            regSel <= sel;
            wait until rising_edge(clk);
            n_rd <= '0';
            for i in 1 to 15 loop wait until rising_edge(clk); end loop;
            d := dataOut;                   -- sampled late in the strobe
            n_rd <= '1';
            for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure status(d : out std_logic_vector(7 downto 0)) is
        begin
            cpu_rd('0', d);
        end procedure;

        procedure ps2_byte(sc : std_logic_vector(7 downto 0)) is
            variable par : std_logic := '1';
            variable frame : std_logic_vector(10 downto 0);
        begin
            for i in 0 to 7 loop par := par xor sc(i); end loop;
            frame := '1' & par & sc & '0';
            for i in 0 to 10 loop
                ps2Data <= frame(i);
                wait for PS2H;
                ps2Clk <= '0';
                wait for PS2H;
                ps2Clk <= '1';
            end loop;
            wait for 4 * PS2H;
        end procedure;

        procedure key(sc : std_logic_vector(7 downto 0); ext : boolean := false) is
        begin
            if ext then ps2_byte(x"E0"); end if;
            ps2_byte(sc);
        end procedure;

        procedure key_up(sc : std_logic_vector(7 downto 0); ext : boolean := false) is
        begin
            if ext then ps2_byte(x"E0"); end if;
            ps2_byte(x"F0");
            ps2_byte(sc);
        end procedure;

        -- read one key from the Z80 terminal, expect it
        procedure expect_key(e : std_logic_vector(7 downto 0); msg : string) is
            variable st, d : std_logic_vector(7 downto 0);
        begin
            status(st);
            check(st(0) = '1', msg & ": RDRF set");
            cpu_rd('1', d);
            check(d = e, msg & ": got " & to_hstring(d) & " expected " & to_hstring(e));
        end procedure;

        procedure expect_seq(s : string; msg : string) is
        begin
            for i in s'range loop
                expect_key(std_logic_vector(to_unsigned(character'pos(s(i)), 8)),
                           msg & "[" & integer'image(i) & "]");
            end loop;
        end procedure;

        procedure expect_empty(msg : string) is
            variable st : std_logic_vector(7 downto 0);
        begin
            status(st);
            check(st(0) = '0', msg & ": no key waiting (status " & to_hstring(st) & ")");
        end procedure;

        variable st, d : std_logic_vector(7 downto 0);
        variable c0 : integer;
        constant ESC : character := character'val(27);
        constant RIGHT_SEQ : string(1 to 3) := ESC & "[C";
        constant SSP_STR   : string(1 to 3) := "SSP";
    begin
        for i in 1 to 20 loop wait until rising_edge(clk); end loop;

        -- A: register interface ------------------------------------------------
        status(st);
        check(st = x"02", "A: power-up status 02 (TDRE, no key), got " & to_hstring(st));
        c0 := z80_cursor;
        cpu_wr('1', x"48");
        for i in 1 to 50 loop wait until rising_edge(clk); end loop;
        cpu_wr('1', x"69");
        for i in 1 to 50 loop wait until rising_edge(clk); end loop;
        check(z80_cursor = c0 + 2, "A: two display writes move the cursor by 2 (got "
              & integer'image(z80_cursor - c0) & ")");
        status(st);
        check(st(1) = '1', "A: TDRE back after the writes");

        -- B: master reset ------------------------------------------------------
        key(x"1C");                                   -- a key is waiting
        status(st);
        check(st(0) = '1', "B: key waiting before the reset");
        cpu_wr('0', x"03");
        status(st);
        check(st = x"00", "B: status reads 00 in master reset, got " & to_hstring(st));
        c0 := z80_cursor;
        cpu_wr('1', x"58");
        for i in 1 to 50 loop wait until rising_edge(clk); end loop;
        check(z80_cursor = c0, "B: data write ignored in master reset");
        cpu_wr('0', x"02");                           -- RomWBW ACIA_DETECT2:
        status(st);                                   --   (status AND 0E) = 02
        check((st and x"0E") = x"02", "B: detect: clear reset -> TDRE, no DCD/CTS, got " & to_hstring(st));
        check(st(0) = '0', "B: buffer emptied by the reset");
        cpu_wr('0', x"15");                           -- the driver's 9600 8N1 /16
        status(st);
        check(st = x"02", "B: after the config write: TDRE only, got " & to_hstring(st));

        -- C: keyboard ----------------------------------------------------------
        key(x"1C"); key_up(x"1C");                   -- 'a' (caps lock starts on)
        expect_key(x"41", "C: a");
        expect_empty("C: release of a sends nothing");
        key(x"76"); key_up(x"76");                   -- ESC
        expect_key(x"1B", "C: ESC");
        key(x"71", true); key_up(x"71", true);       -- Delete
        expect_key(x"7F", "C: Delete");
        key(x"75", true); key_up(x"75", true);       -- up
        expect_seq(ESC & "[A", "C: up");
        key(x"6B", true);                             -- left
        expect_seq(ESC & "[D", "C: left");
        key(x"6C", true);                             -- home
        expect_seq(ESC & "[H", "C: home");
        key(x"70", true);                             -- insert
        expect_seq(ESC & "[2~", "C: insert");
        key(x"05"); key_up(x"05");                   -- F1
        expect_seq(ESC & "OP", "C: F1");
        key(x"03");                                   -- F5
        expect_seq(ESC & "[15~", "C: F5");
        key(x"07");                                   -- F12
        expect_seq(ESC & "[24~", "C: F12");
        expect_empty("C: nothing left over");

        -- D: buffer full -------------------------------------------------------
        for i in 1 to 20 loop
            key(x"16");                               -- '1'
        end loop;
        for i in 1 to 15 loop
            expect_key(x"31", "D: key " & integer'image(i));
        end loop;
        expect_empty("D: only 15 kept, the rest dropped (no wrap)");
        key(x"75", true);
        expect_seq(ESC & "[A", "D: a sequence after a full buffer");

        -- E: SSP screen ------------------------------------------------------
        show <= '1';
        wait for 1 us;
        key(x"32");                                   -- 'b'
        expect_empty("E: Z80 terminal keeps no keys while the SSP screen shows");
        wait until rising_edge(clk) and rx_valid = '1' for 100 us;
        check(rx_valid = '1', "E: ssp_vdu offers the key");
        check(rx_data = x"42", "E: ssp_vdu key = B, got " & to_hstring(rx_data));
        rx_take <= '1';
        wait until rising_edge(clk);
        rx_take <= '0';
        for i in 1 to 20 loop wait until rising_edge(clk); end loop;
        check(rx_valid = '0', "E: key consumed");
        key(x"74", true);                             -- right arrow
        for i in 0 to 2 loop
            wait until rising_edge(clk) and rx_valid = '1' for 100 us;
            check(rx_valid = '1' and rx_data = std_logic_vector(to_unsigned(
                  character'pos(RIGHT_SEQ(i + 1)), 8)),
                  "E: right arrow byte " & integer'image(i) & " = " & to_hstring(rx_data));
            rx_take <= '1';
            wait until rising_edge(clk);
            rx_take <= '0';
        end loop;
        c0 := vdu_cursor;
        for i in 0 to 2 loop
            tx_data <= std_logic_vector(to_unsigned(character'pos(SSP_STR(i + 1)), 8));
            tx_valid <= '1';
            wait until rising_edge(clk) and tx_ready = '1';
            tx_valid <= '0';
            wait until rising_edge(clk);
        end loop;
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;
        check(vdu_cursor = c0 + 3, "E: three bytes written to the SSP screen");
        show <= '0';
        wait for 1 us;
        key(x"1C");
        expect_key(x"41", "E: keys back to the Z80 terminal");
        check(rx_valid = '0', "E: and not to the SSP terminal");

        -- F: serial ACIA master reset ----------------------------------------
        regSel <= '0'; dataIn <= x"03";
        wait until rising_edge(clk); u_n_wr <= '0';
        for i in 1 to 15 loop wait until rising_edge(clk); end loop;
        u_n_wr <= '1';
        for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        u_n_rd <= '0'; wait until rising_edge(clk); u_n_rd <= '1';
        wait until rising_edge(clk);
        check(u_dout = x"00", "F: ACIA status 00 in master reset, got " & to_hstring(u_dout));
        dataIn <= x"02";
        wait until rising_edge(clk); u_n_wr <= '0';
        for i in 1 to 15 loop wait until rising_edge(clk); end loop;
        u_n_wr <= '1';
        for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        u_n_rd <= '0'; wait until rising_edge(clk); u_n_rd <= '1';
        wait until rising_edge(clk);
        check((u_dout and x"0E") = x"02", "F: ACIA detect: (status AND 0E) = 02 after clearing the reset, got " & to_hstring(u_dout));

        wait for 1 us;
        if fails = 0 then
            report "tb_terminal: ALL " & integer'image(checks) & " CHECKS PASSED" severity note;
        else
            report "tb_terminal: " & integer'image(fails) & " of " & integer'image(checks)
                   & " CHECKS FAILED" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end architecture tb;

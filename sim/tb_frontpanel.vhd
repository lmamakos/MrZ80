-- tb_frontpanel: self-checking testbench for the FrontPanel_Subsystem
-- profile feature (Components/FRONTPANEL/).
--
-- The DUT drives a real 256-bit Transparent_Capture_Chain holding a
-- pseudo-random pattern. The testbench decodes the WS2812 output line
-- (pulse widths -> bits -> GRB -> RGB) into complete 256-LED frames and
-- compares every LED of a frame against a behavioural model of what the
-- selected profile should show:
--      LED i colour = scale8( chain bit PAT(255 - map(i)) ? on : off )
--
-- Covered:
--   * profile 0 defaults after reset (identity map, red/blue) and the
--     other 7 profiles also defaulting; +7 resets to 0
--   * Z-80 modification (+3 colours, +5 map) of the active profile, which
--     persists across profile switches
--   * a profile switch in the middle of a frame does not affect that frame
--   * profile file download: all 8 profiles come up with the file's
--     content after reset; soft reset reloads the file (discarding Z-80
--     modifications); profile_clear (hard reset) reverts to defaults
--   * invalid files (bad magic, truncated, too long) are ignored
--
-- Run with sim/run_frontpanel.sh (takes a minute or so: each frame is
-- ~400k clk cycles of WS2812 shifting).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_frontpanel is
end tb_frontpanel;

architecture sim of tb_frontpanel is
    constant NL : integer := 256;

    signal clk          : std_logic := '0';
    signal reset        : std_logic := '1';
    signal refresh_tick : std_logic := '0';
    signal iorq_n       : std_logic := '1';
    signal wr_n         : std_logic := '1';
    signal rd_n         : std_logic := '1';
    signal io_cs        : std_logic := '0';
    signal addr         : std_logic_vector(7 downto 0) := (others => '0');
    signal din          : std_logic_vector(7 downto 0) := (others => '0');
    signal dout         : std_logic_vector(7 downto 0);
    signal latch        : std_logic;
    signal shift_en     : std_logic;
    signal chain_in     : std_logic;
    signal led_serial   : std_logic;
    signal fp_dl_active : std_logic := '0';
    signal fp_dl_we     : std_logic := '0';
    signal fp_dl_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal profile_clear : std_logic := '0';
    signal osd_profile  : std_logic_vector(3 downto 0) := "1111";
    signal done         : boolean := false;

    function mkpat return std_logic_vector is
        variable v : std_logic_vector(NL-1 downto 0);
        variable x : unsigned(31 downto 0) := x"1234ABCD";
    begin
        for i in 0 to NL-1 loop
            x := x(30 downto 0) & (x(31) xor x(21) xor x(1) xor x(0));
            v(i) := x(0);
        end loop;
        return v;
    end function;
    constant PAT : std_logic_vector(NL-1 downto 0) := mkpat;

    type frame_t is array (0 to NL-1) of std_logic_vector(23 downto 0); -- R,G,B
    signal last_frame    : frame_t;
    signal frames_done   : integer := 0;
    signal led_idx_prog  : integer := 0;

    type int_arr_t is array (0 to 8*NL-1) of integer;
    type rgb_arr_t is array (0 to 8*NL-1) of std_logic_vector(47 downto 0);
    type file_t    is array (0 to 16 + 8*NL*7) of integer;

begin
    clk <= not clk after 10 ns when not done else clk;   -- 50 MHz

    dut : entity work.FrontPanel_Subsystem
        generic map (NUM_LEDS => NL, SYS_CLK => 50000000)
        port map (
            clk => clk, reset => reset, refresh_tick => refresh_tick,
            iorq_n => iorq_n, wr_n => wr_n, rd_n => rd_n, io_cs => io_cs,
            addr => addr, din => din, dout => dout,
            latch => latch, shift_en => shift_en, chain_in => chain_in,
            fp_dl_active => fp_dl_active, fp_dl_we => fp_dl_we,
            fp_dl_data => fp_dl_data, profile_clear => profile_clear,
            osd_profile => osd_profile,
            led_serial => led_serial);

    chain : entity work.Transparent_Capture_Chain
        generic map (TOTAL_WIDTH => NL)
        port map (
            clk => clk, reset => reset, latch => latch, shift_en => shift_en,
            combined_data => PAT, chain_in => '0', chain_out => chain_in);

    -- ~8.9 ms refresh tick (a full frame takes ~7.7 ms)
    tick : process
    begin
        while not done loop
            for i in 1 to 450000 loop wait until rising_edge(clk); end loop;
            refresh_tick <= '1';
            wait until rising_edge(clk);
            refresh_tick <= '0';
        end loop;
        wait;
    end process;

    -- WS2812 decoder: pulse width -> bit, 24 bits -> LED, >200 clk low
    -- gap -> start of a new frame.
    decode : process(clk)
        variable prev : std_logic := '0';
        variable hi, lo : integer := 0;
        variable acc : std_logic_vector(23 downto 0) := (others => '0');
        variable nb, idx : integer := 0;
        variable cur : frame_t;
    begin
        if rising_edge(clk) then
            if led_serial = '1' then
                if prev = '0' then
                    if lo > 200 then
                        idx := 0; nb := 0; led_idx_prog <= 0;
                    end if;
                    hi := 1;
                else
                    hi := hi + 1;
                end if;
                lo := 0;
            else
                if prev = '1' then
                    if hi > 26 then acc := acc(22 downto 0) & '1';
                    else acc := acc(22 downto 0) & '0'; end if;
                    nb := nb + 1;
                    if nb = 24 then
                        nb := 0;
                        if idx < NL then
                            -- wire order is G,R,B
                            cur(idx) := acc(15 downto 8) & acc(23 downto 16) & acc(7 downto 0);
                        end if;
                        idx := idx + 1;
                        led_idx_prog <= idx;
                        if idx = NL then
                            last_frame  <= cur;
                            frames_done <= frames_done + 1;
                        end if;
                    end if;
                end if;
                lo := lo + 1;
            end if;
            prev := led_serial;
        end if;
    end process;

    main : process
        variable m_map  : int_arr_t;          -- model: current profile content
        variable m_col  : rgb_arr_t;          -- on(47:24) & off(23:0), R,G,B
        variable f_map  : int_arr_t;          -- model: profile file content
        variable f_col  : rgb_arr_t;
        variable loaded : boolean := false;
        variable bytes  : file_t;
        variable nbytes : integer;
        variable errors : integer := 0;
        variable tmp    : integer;

        procedure clks(n : integer) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure fail(msg : string) is
        begin
            report "FAIL: " & msg severity failure;
        end procedure;

        procedure io_wr(off : integer; d : integer) is
        begin
            addr <= std_logic_vector(to_unsigned(16#A0# + off, 8));
            din  <= std_logic_vector(to_unsigned(d, 8));
            io_cs <= '1'; iorq_n <= '0';
            clks(2);
            wr_n <= '0';
            clks(6);
            wr_n <= '1'; iorq_n <= '1'; io_cs <= '0';
            clks(6);
        end procedure;

        procedure io_rd(off : integer; d : out integer) is
        begin
            addr <= std_logic_vector(to_unsigned(16#A0# + off, 8));
            io_cs <= '1'; iorq_n <= '0';
            clks(2);
            rd_n <= '0';
            clks(5);
            d := to_integer(unsigned(dout));
            clks(1);
            rd_n <= '1'; iorq_n <= '1'; io_cs <= '0';
            clks(6);
        end procedure;

        procedure wait_frames(n : integer) is
            variable target : integer;
        begin
            target := frames_done + n;
            while frames_done < target loop wait until rising_edge(clk); end loop;
        end procedure;

        function rgb(r, g, b : integer) return std_logic_vector is
        begin
            return std_logic_vector(to_unsigned(r, 8)) & std_logic_vector(to_unsigned(g, 8))
                 & std_logic_vector(to_unsigned(b, 8));
        end function;

        procedure model_defaults is
        begin
            for p in 0 to 7 loop
                for i in 0 to NL-1 loop
                    m_map(p*NL+i) := i;
                    m_col(p*NL+i) := rgb(16#FF#, 0, 1) & rgb(0, 0, 9);
                end loop;
            end loop;
        end procedure;

        -- Model of what hardware does on reset.
        procedure model_reset is
        begin
            if loaded then
                m_map := f_map; m_col := f_col;
            else
                model_defaults;
            end if;
        end procedure;

        -- Apply a reset pulse and bring brightness to 0xFF (scale8 -> c-1)
        procedure do_reset is
            variable d : integer;
        begin
            reset <= '1';
            clks(10);
            reset <= '0';
            clks(2300);          -- RAM init takes ~2050 clk
            model_reset;
            io_rd(7, d);
            if d /= 0 then fail("profile select not 0 after reset"); end if;
            io_wr(0, 255);
        end procedure;

        procedure set_color(p, led, onr, ong, onb, offr, offg, offb : integer) is
        begin
            io_wr(2, led);
            io_wr(3, onr); io_wr(3, ong); io_wr(3, onb);
            io_wr(3, offr); io_wr(3, offg); io_wr(3, offb);
            m_col(p*NL+led) := rgb(onr, ong, onb) & rgb(offr, offg, offb);
        end procedure;

        procedure set_map(p, led, m : integer) is
        begin
            io_wr(2, led);
            io_wr(5, m);
            m_map(p*NL+led) := m;
        end procedure;

        procedure select_profile(p : integer) is
            variable d : integer;
        begin
            io_wr(7, p);
            io_rd(7, d);
            if d /= p then fail("profile select readback " & integer'image(d) & " /= " & integer'image(p)); end if;
        end procedure;

        function sc(c : integer) return integer is
        begin
            return (c * 255) / 256;
        end function;

        -- Compare a decoded frame with the model for profile p.
        procedure compare_frame(p : integer; tag : string) is
            variable want_on : std_logic;
            variable c : std_logic_vector(23 downto 0);
            variable e : std_logic_vector(23 downto 0);
        begin
            for i in 0 to NL-1 loop
                want_on := PAT(NL-1 - m_map(p*NL+i));
                if want_on = '1' then c := m_col(p*NL+i)(47 downto 24);
                else c := m_col(p*NL+i)(23 downto 0); end if;
                e := std_logic_vector(to_unsigned(sc(to_integer(unsigned(c(23 downto 16)))), 8))
                   & std_logic_vector(to_unsigned(sc(to_integer(unsigned(c(15 downto 8)))), 8))
                   & std_logic_vector(to_unsigned(sc(to_integer(unsigned(c(7 downto 0)))), 8));
                if last_frame(i) /= e then
                    report "LED " & integer'image(i) & " profile " & integer'image(p)
                         & " got " & to_hstring(last_frame(i)) & " want " & to_hstring(e)
                         & " (on=" & std_logic'image(want_on) & ", map="
                         & integer'image(m_map(p*NL+i)) & ") in " & tag severity error;
                    errors := errors + 1;
                    if errors > 10 then fail("too many mismatches in " & tag); end if;
                end if;
            end loop;
        end procedure;

        procedure check_profile(p : integer; tag : string) is
        begin
            select_profile(p);
            wait_frames(2);
            compare_frame(p, tag);
            report "ok: " & tag & " profile " & integer'image(p);
        end procedure;

        -- Profile file content model + byte image. kind: 0 = good.
        procedure build_file is
            variable o : integer := 0;
            variable r, g, b, orr, og, ob, mp : integer;
        begin
            bytes(0) := 16#46#; bytes(1) := 16#50#; bytes(2) := 16#50#; bytes(3) := 16#46#;
            bytes(4) := 1; bytes(5) := 8; bytes(6) := 0; bytes(7) := 1;
            for k in 8 to 15 loop bytes(k) := 0; end loop;
            for p in 0 to 7 loop
                for i in 0 to NL-1 loop
                    mp  := (i*7 + p*13) mod 256;
                    r   := (p*30 + i) mod 256;
                    g   := (i*3) mod 256;
                    b   := 255 - i;
                    orr := (i/2 + p) mod 256;
                    og  := p*5;
                    ob  := 9 + (i mod 4);
                    o := 16 + (p*NL+i)*7;
                    bytes(o) := mp; bytes(o+1) := r; bytes(o+2) := g; bytes(o+3) := b;
                    bytes(o+4) := orr; bytes(o+5) := og; bytes(o+6) := ob;
                    f_map(p*NL+i) := mp;
                    f_col(p*NL+i) := rgb(r, g, b) & rgb(orr, og, ob);
                end loop;
            end loop;
            nbytes := 16 + 8*NL*7;
        end procedure;

        -- Stream bytes(0..n-1) into the DUT like hps_io: download active,
        -- core held in reset, one ioctl_wr pulse per byte.
        procedure download(n : integer) is
        begin
            reset <= '1';
            clks(10);
            fp_dl_active <= '1';
            clks(3);
            for k in 0 to n-1 loop
                fp_dl_data <= std_logic_vector(to_unsigned(bytes(k), 8));
                fp_dl_we <= '1';
                clks(1);
                fp_dl_we <= '0';
                clks(2);
            end loop;
            clks(3);
            fp_dl_active <= '0';
            clks(20);
        end procedure;

        variable d : integer;
    begin
        build_file;

        ---------------------------------------------------------------
        report "T0: defaults after power-up reset";
        loaded := false;
        do_reset;
        check_profile(0, "T0 defaults");
        check_profile(7, "T0 defaults");

        ---------------------------------------------------------------
        report "T1: Z-80 modification persists across profile switches";
        select_profile(0);
        set_color(0, 5, 200, 100, 50, 20, 10, 5);
        set_map(0, 7, 100);
        set_map(0, 8, 255);
        check_profile(0, "T1 p0 modified");
        select_profile(3);
        set_color(3, 5, 1, 2, 3, 4, 5, 6);
        set_map(3, 5, 0);
        check_profile(3, "T1 p3 modified");
        check_profile(1, "T1 p1 untouched");
        check_profile(0, "T1 p0 persisted");
        check_profile(3, "T1 p3 persisted");

        ---------------------------------------------------------------
        report "T2: profile switch mid-frame does not tear the frame";
        select_profile(0);
        set_color(0, 200, 10, 20, 30, 40, 50, 60);
        select_profile(1);
        set_color(1, 200, 70, 80, 90, 100, 110, 120);
        select_profile(0);
        wait_frames(2);
        wait until led_idx_prog >= 20 and led_idx_prog < 100;
        io_wr(7, 1);
        wait_frames(1);
        compare_frame(0, "T2 in-flight frame (profile 0)");
        wait_frames(1);
        compare_frame(1, "T2 next frame (profile 1)");
        report "ok: T2";

        ---------------------------------------------------------------
        report "T3: reset discards Z-80 modifications, profile -> 0";
        do_reset;
        check_profile(0, "T3 p0 after reset");
        check_profile(3, "T3 p3 after reset");

        ---------------------------------------------------------------
        report "T4: valid profile file";
        build_file;
        download(nbytes);
        loaded := true;
        do_reset;
        for p in 0 to 7 loop
            check_profile(p, "T4 file");
        end loop;

        report "T4b: Z-80 modification on top of file";
        select_profile(2);
        set_color(2, 17, 111, 122, 133, 144, 155, 166);
        set_map(2, 17, 99);
        check_profile(2, "T4b p2 modified");

        report "T4c: soft reset reloads the file, not defaults";
        do_reset;
        check_profile(2, "T4c p2 reloaded");
        check_profile(0, "T4c p0 from file");

        ---------------------------------------------------------------
        report "T5: hard reset (profile_clear) reverts to defaults";
        profile_clear <= '1'; clks(1); profile_clear <= '0'; clks(2);
        loaded := false;
        do_reset;
        check_profile(0, "T5 p0 defaults");
        check_profile(5, "T5 p5 defaults");

        ---------------------------------------------------------------
        report "T6: invalid files are ignored";
        build_file;
        bytes(0) := 16#47#;                       -- bad magic
        download(nbytes);
        do_reset;
        check_profile(0, "T6 bad magic");

        build_file;
        download(nbytes - 7);                     -- truncated
        do_reset;
        check_profile(0, "T6 truncated");

        build_file;
        bytes(nbytes) := 0;
        download(nbytes + 1);                     -- one byte too long
        do_reset;
        check_profile(0, "T6 too long");

        build_file;
        bytes(5) := 4;                            -- wrong profile count
        download(nbytes);
        do_reset;
        check_profile(1, "T6 bad count");

        report "T6b: valid file accepted again after invalid ones";
        build_file;
        download(nbytes);
        loaded := true;
        do_reset;
        check_profile(6, "T6b file");
        check_profile(0, "T6b file");

        ---------------------------------------------------------------
        report "T7: OSD profile override on the fly (no reset)";
        -- file is loaded (T6b). Z-80 selects profile 2 and edits it.
        select_profile(2);
        set_color(2, 40, 91, 92, 93, 94, 95, 96);
        wait_frames(2);
        compare_frame(2, "T7 baseline");
        osd_profile <= "0101";                    -- OSD forces profile 5
        wait_frames(2);
        compare_frame(5, "T7 OSD forces p5");
        io_rd(7, d);
        if d /= 2 then fail("T7: port +7 changed by OSD override"); end if;
        -- Z-80 edits still land in ITS profile (2), not the displayed one
        set_color(2, 41, 1, 2, 3, 4, 5, 6);
        wait_frames(2);
        compare_frame(5, "T7 p5 unaffected by Z-80 edit of p2");
        -- Z-80 profile switches don't change the display while overridden
        io_wr(7, 6);
        wait_frames(2);
        compare_frame(5, "T7 override wins over Z-80 select");
        osd_profile <= "0011";                    -- retarget on the fly
        wait_frames(2);
        compare_frame(3, "T7 OSD retarget p3");
        osd_profile <= "1111";                    -- back to software (Z-80 = 6)
        wait_frames(2);
        compare_frame(6, "T7 back to Z-80 selection");
        select_profile(2);
        wait_frames(2);
        compare_frame(2, "T7 Z-80 edits of p2 retained");
        report "ok: T7";

        report "PASS";
        done <= true;
        wait;
    end process;
end architecture;

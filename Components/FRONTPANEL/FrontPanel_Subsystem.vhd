-- =====================================================================
-- FrontPanel_Subsystem
--
-- Top level of the front-panel LED subsystem. Owns the Z-80 I/O port
-- decoder, the dual-port LED-state RAMs (colour, chain-bit mapping,
-- framebuffer), and the WS2812/SK6812 PHY that shifts the final pixel
-- data out on a single GPIO pin.
--
-- SIMPLIFIED FOR INITIAL BRING-UP: each LED shows its RAM-stored "on"
-- colour or "off" colour, scaled by the global brightness register,
-- selected by the mapped chain bit (or framebuffer bit) for that LED
-- -- an instant on/off switch, with no gradual fade *between* the two
-- colours (the former fade-rate register at +1 has been repurposed as
-- the map-high register, so there is currently no fade). The
-- mapping table (+5) and framebuffer (+4/+6) are unchanged and fully
-- functional, and the global-brightness (+0) register is fully active
-- (see the SCALE_BRIGHT state below). See REQUIREMENTS.md / HISTORY.md
-- for context.
--
-- Clocking: a single clk (frequency = SYS_CLK Hz) clocks everything.
-- The PHY bit-time constants are derived from SYS_CLK so the WS2812
-- 1.25 us bit period is preserved regardless of clock frequency.
--
-- Colour storage/interface: colours are stored in FP_RAM_Store, and
-- streamed in/out over the +3 port, in plain R,G,B byte order. The
-- WS2812/SK6812 wire protocol actually wants G,R,B order; that
-- reorder happens only right before the PHY (see SCALE_BRIGHT below),
-- so software never has to deal with the LEDs' GRB quirk.
--
-- Profiles: there are 8 profiles (selected through port +7). Each
-- holds, for every physical LED, an ON colour, an OFF colour and the
-- capture-chain bit index that drives it (the "map"). Brightness (+0),
-- mode (+4) and the framebuffer (+6) are global, not per-profile. The
-- Z-80 can modify the active profile's colours/map through +3/+5; the
-- changes stay in that profile when another one is selected, and are
-- discarded by the next reset (see below).
--
-- Capture chain length: CHAIN_BITS (1..1024, default 256) is the total
-- number of bits in the capture chain. Only NUM_LEDS (256) LEDs exist,
-- so a profile's per-LED map selects which of the CHAIN_BITS chain bits
-- each LED displays; different profiles can show different parts of a
-- chain longer than the LED string. A map value >= CHAIN_BITS shows the
-- LED's OFF colour. Chain position 0 is the first bit shifted out of the
-- chain. The framebuffer mode (+4 bit 0 = 1) is still one bit per LED
-- (max NUM_LEDS).
--
-- Map entries are 8 bits for CHAIN_BITS <= 256 and up to 10 bits above
-- that. Port +5 carries the low 8 bits; the Z-80 reaches bits 9:8 through
-- port +1 (see the register map).
--
-- OSD override: the osd_profile input can force the displayed profile
-- independently of the Z-80 (see its port comment); the Z-80's own
-- selection (+7) and its colour/map edits are unaffected.
--
-- Profile file: a file chosen from the MiSTer OSD (see the fp_dl_*
-- ports) holds the initial content of all 8 profiles; its format is
-- documented in README.md (16-byte header "FPPF" ... then 8 x 256
-- records of 8 bytes: map lo, map hi, onR, onG, onB, offR, offG, offB). A file
-- with a bad header or wrong length is ignored. With no valid file,
-- every profile is initialised to the defaults (identity map, red ON,
-- dim blue OFF). profile_loaded is sticky across Z-80 resets and is
-- cleared only by the profile_clear pulse (hard reset) or by the start
-- of another download.
--
-- Reset behaviour: FP_RAM_Store re-initializes color_ram/map_ram/
-- fb_ram (all 8 profiles, from the profile file or the defaults;
-- framebuffer all off) every time reset is asserted, not just
-- once at FPGA power-up, so the front panel comes up in a reproducible
-- state after every Z-80 reset, with profile 0 selected. This takes
-- ~2050 clk cycles; the Master Controller (see IDLE state below) waits
-- for it to finish before starting the first refresh.
--
-- I/O register map (8 consecutive ports, aligned on a multiple-of-8
-- boundary, decoded relative to the io_cs chip-select input that the
-- external decoder drives):
--   +0   R/W  global brightness (0..255, 8-bit linear scale applied to
--              every channel of whichever colour -- on or off -- is
--              selected for display; see SCALE_BRIGHT below).
--   +1   R/W  write: "map high" -- bits 1:0 are map bits 9:8 for
--              subsequent +5 writes (sticky; reset to 0; ignored if
--              CHAIN_BITS <= 256). read: map bits 9:8 of the entry at
--              global_ptr (read it BEFORE the +5 read, which advances
--              the pointer). Replaces the old, inert fade-rate register.
--   +2   R/W  global pointer (LED index for +3, +5, +6)
--   +3   W    colour stream: 6 bytes per LED (on-R, on-G, on-B,
--                    off-R, off-G, off-B); auto-advances pointer.
--   +4   R/W  mode register (bit 0: 0 = mirror chain, 1 = framebuffer)
--   +5   R/W  mapping table entry at global_ptr (read or write
--              auto-advances the pointer).
--   +6   R/W  framebuffer bit at global_ptr (read or write
--              auto-advances the pointer).
--   +7   R/W  active profile number (low 3 bits; reads back 0..7; resets
--              to 0). Selects which profile's colours/map +3/+5 access
--              and (latched at the start of each refresh frame) which
--              profile drives the LEDs.
--
-- The pointer auto-advance on +3/+5/+6 wraps at NUM_LEDS back to 0
-- (rather than growing past it), so streaming exactly NUM_LEDS (or an
-- exact multiple of NUM_LEDS) accesses through any of those ports is
-- always well-defined and lands back at LED 0.
--
-- This module looks only at the low 3 bits of addr to pick a register
-- within the 8-port window. The integrator decides where the window
-- lives in the Z-80 I/O space via io_cs (same pattern as the MMU's I/O
-- decoder).
-- =====================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity FrontPanel_Subsystem is
    generic (
        NUM_LEDS   : integer := 256;
        CHAIN_BITS : integer range 1 to 1024 := 256;  -- capture chain length
        SYS_CLK    : integer := 50000000 -- 50MHz default
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;
        refresh_tick : in  std_logic; -- ~60Hz Pulse, kicks off a frame

        -- Z80 Bus Interface. io_cs is asserted by the external I/O
        -- decoder when an I/O cycle targets this block's 8-port
        -- window; this module then uses addr(2 downto 0) as the
        -- in-window offset.
        iorq_n       : in  std_logic;
        wr_n         : in  std_logic;
        rd_n         : in  std_logic;
        io_cs        : in  std_logic;
        addr         : in  std_logic_vector(7 downto 0);
        din          : in  std_logic_vector(7 downto 0);
        dout         : out std_logic_vector(7 downto 0);

        -- Z80 PISO Chain Interface (to Universal_Capture_Chain instances)
        latch        : out std_logic;
        shift_en     : out std_logic;
        chain_in     : in  std_logic;

        -- Profile file download (from the MiSTer OSD "FC5" file).
        -- fp_dl_active is high for the whole download; fp_dl_we pulses
        -- for each byte, with the byte on fp_dl_data (same cycle).
        -- These are independent of `reset` (the core is held in reset
        -- while a download runs).
        fp_dl_active : in  std_logic := '0';
        fp_dl_we     : in  std_logic := '0';
        fp_dl_data   : in  std_logic_vector(7 downto 0) := (others => '0');
        -- One-clk pulse on a hard reset: forget the loaded profile file
        -- (revert to the built-in defaults). Not part of `reset`, so an
        -- ordinary Z-80 reset keeps the loaded profiles.
        profile_clear : in std_logic := '0';

        -- OSD profile override. Values 0..7 force that profile onto the
        -- LEDs; any value with bit 3 set ("1xxx", default) means "no
        -- override": the Z-80's port +7 selection is displayed. Sampled
        -- once per refresh frame, so changing it on the fly never stalls
        -- or resets anything (at worst one frame is shown with the old
        -- profile). It does not alter port +7 or where Z-80 colour/map
        -- writes land (those always use the Z-80's own selection).
        osd_profile  : in  std_logic_vector(3 downto 0) := "1111";

        -- Physical LED Output (WS2812/SK6812 single-wire)
        led_serial   : out std_logic
    );
end entity;

architecture rtl of FrontPanel_Subsystem is
    -- Width of a map entry: 8 bits up to a 256-bit chain, else 9/10.
    function map_width(n : integer) return integer is
    begin
        if n <= 256 then return 8;
        elsif n <= 512 then return 9;
        else return 10;
        end if;
    end function;
    constant MAP_W : integer := map_width(CHAIN_BITS);

    -- -----------------------------------------------------------------
    -- PHY timing constants derived from SYS_CLK. WS2812/SK6812 use a
    -- 1.25 us bit period (800 kHz); within each bit period the line is
    -- held high for either ~340 ns (T0H, encodes a '0') or ~700 ns
    -- (T1H, encodes a '1') and low for the remainder. Rounding to the
    -- nearest integer count of clk cycles is more than precise enough
    -- for the WS2812's >150 ns timing tolerance.
    -- -----------------------------------------------------------------
    constant T_BIT : integer := SYS_CLK / 800000;   -- ~1.25 us
    constant T_T0H : integer := SYS_CLK / 2941176;  -- ~340 ns
    constant T_T1H : integer := SYS_CLK / 1428571;  -- ~700 ns

    -- I/O Streaming Registers
    signal global_ptr    : unsigned(7 downto 0) := (others => '0');
    -- Wraps global_ptr's auto-increment at NUM_LEDS instead of letting
    -- it grow up to 255: without this, streaming exactly NUM_LEDS (or
    -- more) accesses through +3/+5/+6 would push global_ptr past the
    -- RAMs' valid 0..NUM_LEDS-1 index range -- undefined in synthesis
    -- (address truncation behaviour depends on how many bits Quartus
    -- actually implements) and a hard simulation failure under GHDL
    -- (out-of-bounds array index). Wrapping here keeps pointer
    -- behaviour well-defined and reproducible in both worlds.
    signal global_ptr_next : unsigned(7 downto 0);
    signal sub_ptr       : integer range 0 to 5 := 0;
    signal global_bright : unsigned(7 downto 0) := x"80";
    signal map_hi_wr     : unsigned(1 downto 0) := (others => '0');
    signal map_wr10      : unsigned(9 downto 0);
    signal dout_map_pad  : unsigned(9 downto 0);
    signal mode_reg      : std_logic := '0';
    -- Profile selected by the Z-80 (port +7) and the profile latched
    -- for the refresh frame currently being sent to the LEDs.
    signal profile_sel   : unsigned(2 downto 0) := (others => '0');
    signal ctrl_profile  : unsigned(2 downto 0) := (others => '0');
    signal color_buf     : std_logic_vector(47 downto 0);

    -- Edge detection for the Z-80 bus strobes. `clk` runs far faster
    -- than the (divided-down) Z-80 clock, so io_cs/iorq_n/wr_n/rd_n
    -- are level signals that stay asserted for several `clk` edges per
    -- Z-80 bus cycle. Side effects (pointer auto-increment, colour-
    -- stream byte collection, register writes) must fire exactly once
    -- per access, so they are gated on one-shot pulses derived here
    -- rather than on the raw signal levels.
    signal write_active, write_active_d : std_logic := '0';
    signal read_active,  read_active_d  : std_logic := '0';
    signal wr_pulse, rd_done_pulse       : std_logic;

    -- RAM Wrapper Interface
    signal we_col, we_map, we_fb : std_logic := '0';
    -- Deferred write-side pointer increment (see the write-path case
    -- statement below for why this can't just do
    -- "global_ptr <= global_ptr_next" directly).
    signal pending_incr : std_logic := '0';
    signal dout_map : unsigned(MAP_W-1 downto 0);
    signal dout_fb  : std_logic;
    signal ctrl_idx : unsigned(7 downto 0) := (others => '0');
    signal r_col_b  : std_logic_vector(47 downto 0);
    signal r_map_b  : unsigned(MAP_W-1 downto 0);
    signal r_fb_b   : std_logic;
    -- '0' while FP_RAM_Store's post-reset RAM initialization sequence
    -- is still running; the Master Controller waits for this before
    -- starting the first refresh (see IDLE state below).
    signal ram_init_done : std_logic;

    -- Profile file download state (see download process below).
    signal profile_loaded : std_logic := '0';
    signal dl_active_d    : std_logic := '0';
    signal dl_cnt         : integer range 0 to 16 := 0;   -- header bytes seen (saturates at 16)
    signal dl_k           : integer range 0 to 7 := 0;    -- byte within the 8-byte record
    signal dl_entry       : integer range 0 to 2048 := 0; -- records completed
    signal dl_shift       : std_logic_vector(55 downto 0) := (others => '0');
    signal dl_hdr_ok      : std_logic := '1';
    signal dl_over        : std_logic := '0';
    signal pri_we         : std_logic := '0';
    signal pri_addr       : unsigned(10 downto 0) := (others => '0');
    signal pri_data       : std_logic_vector(63 downto 0) := (others => '0');

    -- Master Controller State Machine
    type state_t is (IDLE, LATCH_ST, LATCH_WAIT, SHADOW_SHIFT, FETCH_MEM, WAIT_MEM, WAIT_MEM2, SCALE_BRIGHT, SEND_PHY);
    signal state : state_t := IDLE;

    signal bit_counter : integer range 0 to CHAIN_BITS-1 := 0;
    signal shadow_reg  : std_logic_vector(CHAIN_BITS-1 downto 0);

    -- Colour selected for the LED currently at ctrl_idx: r_col_b's
    -- "on" half or "off" half, verbatim, in the R,G,B byte order it's
    -- stored in (see FP_RAM_Store.vhd). Brightness-scaled and
    -- reordered into the PHY's G,R,B wire order in SCALE_BRIGHT below.
    signal sel_rgb : std_logic_vector(23 downto 0);

    -- Final G,R,B value latched into the PHY shift register -- already
    -- brightness-scaled and byte-reordered by SCALE_BRIGHT.
    signal final_rgb : std_logic_vector(23 downto 0);

    -- PHY Signals
    signal phy_start, phy_busy : std_logic := '0';
    signal phy_timer   : integer range 0 to T_BIT := 0;
    signal phy_bit_idx : integer range 0 to 23 := 23;
    signal phy_shift   : std_logic_vector(23 downto 0);

begin
    -- 1. RAM Store Instance
    U_RAM : entity work.FP_RAM_Store
        generic map (NUM_LEDS => NUM_LEDS, MAP_W => MAP_W)
        port map (
            clk => clk,
            reset => reset,
            init_done => ram_init_done,
            profile_loaded => profile_loaded,
            pri_we => pri_we, pri_addr => pri_addr, pri_data => pri_data,
            profile_a => profile_sel,
            addr_a => global_ptr,
            we_color => we_col, we_map => we_map, we_fb => we_fb,
            din_color => color_buf, din_map => map_wr10(MAP_W-1 downto 0), din_fb => din(0),
            dout_map => dout_map, dout_fb => dout_fb,
            profile_b => ctrl_profile,
            addr_b => ctrl_idx,
            dout_color_b => r_col_b, dout_map_b => r_map_b, dout_fb_b => r_fb_b
        );

    -- Bus-cycle-active levels, sampled combinationally every clk edge.
    write_active <= '1' when (io_cs = '1' and iorq_n = '0' and wr_n = '0') else '0';
    read_active  <= '1' when (io_cs = '1' and iorq_n = '0' and rd_n = '0') else '0';

    -- Map entry being written through +5: {map_hi_wr, din}, truncated to
    -- MAP_W bits at the RAM. Map entry read back as 10 bits (zero padded).
    map_wr10     <= map_hi_wr & unsigned(din);
    dout_map_pad <= resize(dout_map, 10);

    -- global_ptr's auto-increment target, wrapped at NUM_LEDS (see
    -- signal declaration above for why).
    global_ptr_next <= (others => '0') when global_ptr = NUM_LEDS-1 else global_ptr + 1;

    -- One-cycle-delayed copies used for edge detection below.
    process(clk, reset)
    begin
        if reset = '1' then
            write_active_d <= '0';
            read_active_d  <= '0';
        elsif rising_edge(clk) then
            write_active_d <= write_active;
            read_active_d  <= read_active;
        end if;
    end process;

    -- wr_pulse: one clk-wide pulse at the START of a write cycle (din
    -- is already stable by then, so side effects can commit safely).
    -- rd_done_pulse: one clk-wide pulse at the END of a read cycle
    -- (deferring the pointer bump until after the CPU has sampled dout
    -- avoids advancing the RAM read address mid-cycle).
    wr_pulse      <= '1' when (write_active = '1' and write_active_d = '0') else '0';
    rd_done_pulse <= '1' when (read_active = '0' and read_active_d = '1') else '0';

    -- 2. Z80 I/O Streaming Port Decoder
    --
    -- NOTE: clk runs far faster than the (divided-down) Z-80 clock, so
    -- io_cs/iorq_n/wr_n/rd_n stay asserted for several clk edges per
    -- Z-80 bus cycle. All side effects below are gated on wr_pulse /
    -- rd_done_pulse (single-cycle strobes, see above) rather than on
    -- the raw signal levels, so each Z-80 access takes effect exactly
    -- once -- an earlier revision that gated directly on the levels
    -- caused every write and every pointer auto-increment to fire
    -- multiple times per access.
    process(clk, reset)
    begin
        if reset = '1' then
            global_ptr <= (others => '0');
            sub_ptr <= 0;
            global_bright <= x"40"; -- need to revisit this with real hardware
            map_hi_wr <= (others => '0');
            mode_reg <= '0';
            profile_sel <= (others => '0');
            color_buf <= (others => '0');
            we_col <= '0';
            we_map <= '0';
            we_fb <= '0';
            pending_incr <= '0';
            dout <= (others => '0');
        elsif rising_edge(clk) then
            we_col <= '0'; we_map <= '0'; we_fb <= '0';

            -- Always-defined dout default: outside of an I/O read cycle
            -- we drive zero so the bus consumer never sees stale data.
            dout <= x"00";

            -- Apply a pointer increment requested by a write on the
            -- *previous* cycle (see "pending_incr" below for why this
            -- has to be deferred by one cycle rather than happening
            -- in the same case statement that raises we_col/we_map/
            -- we_fb).
            pending_incr <= '0';
            if pending_incr = '1' then
                global_ptr <= global_ptr_next;
            end if;

            -- Write path (single-shot, see wr_pulse above). Offsets
            -- within the 8-port window:
            --   +3 collects 6 colour bytes per LED before committing
            --      and advancing the pointer.
            --   +5 / +6 auto-advance the pointer on every write.
            --
            -- IMPORTANT: the pointer increment for +3/+5/+6 is
            -- deferred by one cycle (via pending_incr, applied above)
            -- rather than updating global_ptr directly here. addr_a on
            -- FP_RAM_Store is wired straight to global_ptr, and
            -- FP_RAM_Store's actual RAM write happens one clk edge
            -- *after* we_col/we_map/we_fb become visible to it (the
            -- usual cross-entity registered-signal handoff latency).
            -- If global_ptr also advanced on this same edge, by the
            -- time FP_RAM_Store's write fires it would see the
            -- *already-incremented* address and write to the wrong
            -- slot. Deferring the increment by one extra cycle keeps
            -- global_ptr at its original value for the one cycle
            -- FP_RAM_Store needs to see it, and still advances the
            -- pointer in time for the next access.
            if wr_pulse = '1' then
                case addr(2 downto 0) is
                    when "000" => global_bright <= unsigned(din);
                    when "001" => map_hi_wr <= unsigned(din(1 downto 0));
                    when "010" => global_ptr <= unsigned(din); sub_ptr <= 0;
                    when "011" =>
                        color_buf <= color_buf(39 downto 0) & din;
                        if sub_ptr = 5 then
                            we_col <= '1'; sub_ptr <= 0; pending_incr <= '1';
                        else sub_ptr <= sub_ptr + 1; end if;
                    when "100" => mode_reg <= din(0);
                    when "101" => we_map <= '1'; pending_incr <= '1';
                    when "110" => we_fb  <= '1'; pending_incr <= '1';
                    when others => profile_sel <= unsigned(din(2 downto 0)); -- +7
                end case;
            end if;

            -- Read data path: level-sensitive and unchanged for as
            -- long as the read cycle lasts, so dout stays valid no
            -- matter how many clk edges rd_n remains low.
            if read_active = '1' then
                case addr(2 downto 0) is
                    when "000" => dout <= std_logic_vector(global_bright);
                    when "001" => dout <= "000000" & std_logic_vector(dout_map_pad(9 downto 8));
                    when "010" => dout <= std_logic_vector(global_ptr);
                    when "100" => dout <= (0 => mode_reg, others => '0');
                    when "101" => dout <= std_logic_vector(dout_map_pad(7 downto 0));
                    when "110" => dout <= (0 => dout_fb, others => '0');
                    when "111" => dout <= "00000" & std_logic_vector(profile_sel);
                    when others => null; -- +3 (write-only) reads 0
                end case;
            end if;

            -- Read side effect (single-shot, see rd_done_pulse above):
            -- +5 and +6 auto-increment global_ptr once per read access
            -- (after the CPU has sampled dout) so software can stream
            -- contents out without managing the pointer manually.
            if rd_done_pulse = '1' then
                case addr(2 downto 0) is
                    when "101" => global_ptr <= global_ptr_next;
                    when "110" => global_ptr <= global_ptr_next;
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- 2b. Profile file download. Collects the 8-byte records of the
    -- profile file into 64-bit words for FP_RAM_Store's pristine RAM
    -- and validates the file. Deliberately has NO reset: the core is
    -- held in reset while a download runs, and profile_loaded must
    -- survive ordinary (soft) resets.
    --
    -- File: 16-byte header, then 2048 records (8 profiles x 256 LEDs)
    -- of 8 bytes each: map lo, map hi, onR, onG, onB, offR, offG, offB.
    --   header bytes 0..7 = 'F','P','P','F', 0x02 (version),
    --   0x08 (profiles), 0x00,0x01 (LEDs per profile = 256, little
    --   endian); bytes 8..15 reserved (ignored). The file is accepted
    --   (profile_loaded <= '1') at the end of the download only if the
    --   header matches and exactly 16 + 2048*8 bytes were received.
    process(clk)
        variable hdr_expect : std_logic_vector(7 downto 0);
        variable rec        : std_logic_vector(63 downto 0);
    begin
        if rising_edge(clk) then
            pri_we      <= '0';
            dl_active_d <= fp_dl_active;

            if fp_dl_active = '1' and dl_active_d = '0' then
                -- Start of a download: forget any previously loaded file.
                dl_cnt <= 0; dl_k <= 0; dl_entry <= 0;
                dl_hdr_ok <= '1'; dl_over <= '0';
                profile_loaded <= '0';
            elsif fp_dl_active = '1' then
                if fp_dl_we = '1' then
                    if dl_cnt < 16 then
                        case dl_cnt is
                            when 0 | 3  => hdr_expect := x"46"; -- 'F'
                            when 1 | 2  => hdr_expect := x"50"; -- 'P'
                            when 4      => hdr_expect := x"02"; -- version
                            when 5      => hdr_expect := x"08"; -- profiles
                            when 6      => hdr_expect := x"00"; -- LEDs lo
                            when 7      => hdr_expect := x"01"; -- LEDs hi
                            when others => hdr_expect := fp_dl_data; -- reserved
                        end case;
                        if fp_dl_data /= hdr_expect then dl_hdr_ok <= '0'; end if;
                        dl_cnt <= dl_cnt + 1;
                    elsif dl_entry >= 2048 then
                        dl_over <= '1';
                    else
                        rec := dl_shift & fp_dl_data;
                        dl_shift <= rec(55 downto 0);
                        if dl_k = 7 then
                            pri_we   <= '1';
                            pri_addr <= to_unsigned(dl_entry, 11);
                            pri_data <= rec;
                            dl_k     <= 0;
                            dl_entry <= dl_entry + 1;
                        else
                            dl_k <= dl_k + 1;
                        end if;
                    end if;
                end if;
            elsif dl_active_d = '1' then
                -- End of download: accept only a complete, valid file.
                if dl_hdr_ok = '1' and dl_over = '0' and dl_cnt = 16
                   and dl_k = 0 and dl_entry = 2048 then
                    profile_loaded <= '1';
                else
                    profile_loaded <= '0';
                end if;
            elsif profile_clear = '1' then
                profile_loaded <= '0';
            end if;
        end if;
    end process;

    -- 3. Master Controller
    process(clk, reset)
        -- Mirror-chain vs framebuffer select, computed locally so it's
        -- available combinationally within the same cycle it's used
        -- (avoids an extra state/cycle per LED).
        variable want_on : std_logic;
        -- 8x8 -> 16-bit products for the SCALE_BRIGHT state below.
        variable prod_r, prod_g, prod_b : unsigned(15 downto 0);
    begin
        if reset = '1' then
            state       <= IDLE;
            bit_counter <= 0;
            ctrl_idx    <= (others => '0');
            ctrl_profile <= (others => '0');
            shadow_reg  <= (others => '0');
            final_rgb   <= (others => '0');
            latch       <= '0';
            shift_en    <= '0';
            phy_start   <= '0';
        elsif rising_edge(clk) then
            latch <= '0'; shift_en <= '0'; phy_start <= '0';

            case state is
                when IDLE =>
                    -- Wait for FP_RAM_Store's post-reset init sequence
                    -- to finish before ever reading it via addr_b, so
                    -- the very first refresh after reset only ever
                    -- sees fully-initialized RAM content.
                    if refresh_tick = '1' and ram_init_done = '1' then
                        -- Freeze the profile for this whole frame so a
                        -- Z-80 profile switch can't mix two profiles.
                        if osd_profile(3) = '0' then
                            ctrl_profile <= unsigned(osd_profile(2 downto 0));
                        else
                            ctrl_profile <= profile_sel;
                        end if;
                        state <= LATCH_ST; bit_counter <= 0;
                    end if;

                when LATCH_ST =>
                    latch <= '1'; state <= LATCH_WAIT;

                when LATCH_WAIT =>
                    -- The capture chains' parallel load only commits to
                    -- their shift_reg one clk edge after `latch` is
                    -- presented to them (chain_out is combinational off
                    -- shift_reg, but shift_reg itself is an ordinary
                    -- registered update) -- the same cross-entity
                    -- registered-signal handoff latency documented for
                    -- FETCH_MEM/WAIT_MEM below. Without this settle
                    -- cycle, SHADOW_SHIFT's first sample would capture
                    -- stale leftover chain data instead of the true,
                    -- freshly-latched MSB: every real bit would land one
                    -- shadow_reg slot later than intended, and the very
                    -- last real bit would never be sampled at all.
                    --
                    -- shift_en is also raised here, a full state ahead
                    -- of SHADOW_SHIFT's own first iteration, for the
                    -- same reason: a shift committed to the chains'
                    -- shift_reg only shows up on chain_out one clk edge
                    -- later. latch still wins this cycle (the chains'
                    -- own load-vs-shift priority), so this doesn't
                    -- disturb the pending parallel load; it just means
                    -- the chain's *first real shift* (exposing bit 1)
                    -- has already committed by the time SHADOW_SHIFT
                    -- samples it, instead of arriving one cycle late and
                    -- producing a duplicated bit 0.
                    shift_en <= '1';
                    state <= SHADOW_SHIFT;

                when SHADOW_SHIFT =>
                    shift_en <= '1';
                    shadow_reg <= chain_in & shadow_reg(CHAIN_BITS-1 downto 1);
                    if bit_counter = CHAIN_BITS-1 then
                        ctrl_idx <= (others => '0'); state <= FETCH_MEM;
                    else bit_counter <= bit_counter + 1; end if;

                when FETCH_MEM =>
                    -- Address was driven into the RAM in the previous
                    -- state via ctrl_idx; the synchronous RAM presents
                    -- valid r_col_b/r_map_b/r_fb_b on the next clock.
                    state <= WAIT_MEM;

                when WAIT_MEM =>
                    -- wait another tick
                    state <= WAIT_MEM2;

                when WAIT_MEM2 =>
                    -- r_col_b/r_map_b/r_fb_b are now valid. Pick this
                    -- LED's target state (mirror captured chain bit,
                    -- via the mapping table, or framebuffer bit) and
                    -- select its stored on/off colour (R,G,B order, as
                    -- stored -- see FP_RAM_Store.vhd) for brightness
                    -- scaling and GRB reordering in SCALE_BRIGHT below.
                    -- No fade ramp/interpolation between on and off.
                    if mode_reg = '0' then
                      -- A map value beyond the chain shows OFF.
                      if to_integer(r_map_b) < CHAIN_BITS then
                        want_on := shadow_reg(to_integer(r_map_b));
                      else
                        want_on := '0';
                      end if;
                    else
                      want_on := r_fb_b;
                    end if;

                    if want_on = '1' then
                      sel_rgb <= r_col_b(47 downto 24); -- on colour (R,G,B)
                    else
                      sel_rgb <= r_col_b(23 downto 0);  -- off colour (R,G,B)
                    end if;

                    state <= SCALE_BRIGHT;

                when SCALE_BRIGHT =>
                    -- Apply global brightness (0..255) to each channel
                    -- independently: scaled = (channel * global_bright)
                    -- / 256 -- the common 8-bit "scale8" convention
                    -- (e.g. FastLED's scale8()); global_bright=0xFF is
                    -- ~full brightness (off by <1 count vs true /255),
                    -- global_bright=0 is fully off. Also reorders
                    -- sel_rgb's stored R,G,B order into the G,R,B order
                    -- the WS2812/SK6812 wire protocol expects -- the
                    -- only place this reorder happens, so it's hidden
                    -- from software entirely.
                    prod_r := unsigned(sel_rgb(23 downto 16)) * global_bright;
                    prod_g := unsigned(sel_rgb(15 downto 8))  * global_bright;
                    prod_b := unsigned(sel_rgb(7 downto 0))   * global_bright;
                    final_rgb(23 downto 16) <= std_logic_vector(prod_g(15 downto 8)); -- G
                    final_rgb(15 downto 8)  <= std_logic_vector(prod_r(15 downto 8)); -- R
                    final_rgb(7 downto 0)   <= std_logic_vector(prod_b(15 downto 8)); -- B

                    state <= SEND_PHY;

                when SEND_PHY =>
                    if phy_busy = '0' then
                        phy_start <= '1';
                        if ctrl_idx = NUM_LEDS-1 then
                          state <= IDLE;
                        else
                          ctrl_idx <= ctrl_idx + 1;
                          state <= FETCH_MEM;
                        end if;
                    end if;
            end case;
        end if;
    end process;

    -- 4. WS2812/SK6812 PHY. Counts in clk cycles using SYS_CLK-derived
    -- constants T_T0H, T_T1H, T_BIT so the protocol timing holds at
    -- any clock frequency >= ~10 MHz.
    process(clk, reset)
    begin
        if reset = '1' then
            led_serial  <= '0';
            phy_busy    <= '0';
            phy_timer   <= 0;
            phy_bit_idx <= 23;
            phy_shift   <= (others => '0');
        elsif rising_edge(clk) then
            if phy_busy = '0' then
                led_serial <= '0';
                if phy_start = '1' then
                    phy_shift <= final_rgb; phy_bit_idx <= 23;
                    phy_timer <= 0; phy_busy <= '1';
                end if;
            else
                phy_timer <= phy_timer + 1;
                if phy_shift(phy_bit_idx) = '1' then
                    -- "1" bit: high for T_T1H, low for the remainder
                    if phy_timer < T_T1H then led_serial <= '1';
                    else led_serial <= '0'; end if;
                else
                    -- "0" bit: high for T_T0H, low for the remainder
                    if phy_timer < T_T0H then led_serial <= '1';
                    else led_serial <= '0'; end if;
                end if;

                if phy_timer >= T_BIT - 1 then
                    phy_timer <= 0;
                    if phy_bit_idx = 0 then phy_busy <= '0';
                    else phy_bit_idx <= phy_bit_idx - 1; end if;
                end if;
            end if;
        end if;
    end process;
end architecture;

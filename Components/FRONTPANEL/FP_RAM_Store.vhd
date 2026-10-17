-- =====================================================================
-- FP_RAM_Store
--
-- Dual-port storage for the front-panel LED state. Holds NUM_PROFILES
-- (8) *profiles*; each profile is, per physical LED:
--   * color_ram : 48 bits = ON colour (R,G,B) & OFF colour (R,G,B)
--   * map_ram   : 8 bits  = capture-chain bit index feeding that LED
-- plus one GLOBAL (not per-profile) framebuffer bit per LED (fb_ram).
-- The map is MAP_W bits wide (8 for a <=256-bit capture chain, up to 10
-- for a 1024-bit one); the colour RAM and everything else is unchanged.
--
-- color_ram/map_ram are addressed by {profile(3), led(8)} (2048
-- entries); fb_ram by led(8) only.
--
-- Profile ROM image ("pristine" store)
-- ------------------------------------
-- A profile file loaded from the MiSTer OSD is written (by
-- FrontPanel_Subsystem, which assembles the file's 7-byte records into
-- 56-bit words) into pri_ram, a write-only-from-outside shadow copy.
-- Every time reset is asserted, an init sequencer copies ALL 2048
-- entries from pri_ram into color_ram/map_ram when profile_loaded = '1',
-- or writes the built-in defaults (identity map, DEFAULT_COLOR) when it
-- is '0'. The Z-80 may then modify the working RAMs freely; those
-- modifications persist across profile switches but are discarded by
-- the next reset (which re-copies from pri_ram / the defaults).
--
-- The init sequence takes ~2050 clk cycles. init_done is low while it
-- runs; Z-80 writes are ignored in that window and consumers must not
-- read Port B until init_done is high.
--
-- Colours are stored in R,G,B byte order (matching the software-facing
-- +3 colour-stream port); the GRB reorder needed for the WS2812/SK6812
-- wire protocol happens in FrontPanel_Subsystem right before the PHY.
--
-- pri_ram word layout (64 bits): map low byte(63:56) & map high byte(55:48)
-- & on RGB(47:24) & off RGB(23:0) -- the same byte order as one 8-byte
-- record of the profile file (version 2). Only the low MAP_W bits of the
-- 16-bit map are kept in map_ram.
-- =====================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity FP_RAM_Store is
    generic (
        NUM_LEDS : integer := 256;  -- RAM is always 256 LEDs/profile deep
        MAP_W    : integer := 8     -- width of a map entry (8..10)
    );
    port (
        clk           : in  std_logic;
        -- Synchronous reset. Also (re-)triggers the init sequence.
        reset         : in  std_logic;
        -- '0' while the init sequence is running.
        init_done     : out std_logic;

        -- '1' if pri_ram holds a valid profile file, '0' to use the
        -- built-in defaults. Must be stable while reset is asserted.
        profile_loaded : in std_logic;

        -- Pristine (profile file) write port. Independent of reset.
        pri_we        : in  std_logic;
        pri_addr      : in  unsigned(10 downto 0);   -- {profile, led}
        pri_data      : in  std_logic_vector(63 downto 0);

        -- Port A: Z80 Access (Read/Write)
        profile_a     : in  unsigned(2 downto 0);
        addr_a        : in  unsigned(7 downto 0);
        we_color      : in  std_logic;
        we_map        : in  std_logic;
        we_fb         : in  std_logic;
        din_color     : in  std_logic_vector(47 downto 0);
        din_map       : in  unsigned(MAP_W-1 downto 0);
        din_fb        : in  std_logic;
        dout_map      : out unsigned(MAP_W-1 downto 0);
        dout_fb       : out std_logic;

        -- Port B: Controller Access (Read Only)
        profile_b     : in  unsigned(2 downto 0);
        addr_b        : in  unsigned(7 downto 0);
        dout_color_b  : out std_logic_vector(47 downto 0);
        dout_map_b    : out unsigned(MAP_W-1 downto 0);
        dout_fb_b     : out std_logic
    );
end entity;

architecture rtl of FP_RAM_Store is
    attribute ramstyle : string;

    -- Default content of profile 0 (and of every other profile when no
    -- profile file is loaded): on = bright red (R=0xFF,G=0x00,B=0x01),
    -- off = dim blue (R=0x00,G=0x00,B=0x09), identity mapping.
    constant DEFAULT_COLOR : std_logic_vector(47 downto 0) := x"FF0001000009";

    constant NUM_ENTRIES : integer := 2048;   -- 8 profiles x 256 LEDs

    type color_mem_t is array (0 to NUM_ENTRIES-1) of std_logic_vector(47 downto 0);
    signal color_ram : color_mem_t;
    attribute ramstyle of color_ram : signal is "M10K";

    type map_mem_t is array (0 to NUM_ENTRIES-1) of unsigned(MAP_W-1 downto 0);
    signal map_ram : map_mem_t;
    attribute ramstyle of map_ram : signal is "M10K";

    type fb_mem_t is array (0 to 255) of std_logic;
    signal fb_ram : fb_mem_t;
    attribute ramstyle of fb_ram : signal is "MLAB";

    type pri_mem_t is array (0 to NUM_ENTRIES-1) of std_logic_vector(63 downto 0);
    signal pri_ram : pri_mem_t;
    attribute ramstyle of pri_ram : signal is "M10K";
    signal pri_q : std_logic_vector(63 downto 0);
    signal pri_map16 : unsigned(15 downto 0);

    -- Init sequencer. Issue stage steps init_addr over all entries
    -- (pri_ram read data appears one clk later in pri_q); the write
    -- stage (init_wr_v/init_wr_addr) commits it one clk after that.
    signal init_active  : std_logic := '1';
    signal init_issue   : std_logic := '1';
    signal init_addr    : unsigned(10 downto 0) := (others => '0');
    signal init_wr_v    : std_logic := '0';
    signal init_wr_addr : unsigned(10 downto 0) := (others => '0');

    signal idx_a, idx_b : unsigned(10 downto 0);
begin
    init_done <= not init_active;

    pri_map16 <= unsigned(pri_q(55 downto 48)) & unsigned(pri_q(63 downto 56));  -- hi & lo
    idx_a <= profile_a & addr_a;
    idx_b <= profile_b & addr_b;

    -- Pristine profile image. Written by the download path (any time),
    -- read by the init sequencer.
    process(clk)
    begin
        if rising_edge(clk) then
            if pri_we = '1' then
                pri_ram(to_integer(pri_addr)) <= pri_data;
            end if;
            pri_q <= pri_ram(to_integer(init_addr));
        end if;
    end process;

    -- Init sequencer control.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                init_active <= '1';
                init_issue  <= '1';
                init_addr   <= (others => '0');
                init_wr_v   <= '0';
            else
                init_wr_v <= '0';
                if init_active = '1' then
                    if init_issue = '1' then
                        init_wr_v    <= '1';
                        init_wr_addr <= init_addr;
                        if init_addr = NUM_ENTRIES-1 then
                            init_issue <= '0';
                        else
                            init_addr <= init_addr + 1;
                        end if;
                    elsif init_wr_v = '0' then
                        init_active <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Port A: Z-80 interface and init writes (the only writer of the
    -- working arrays).
    process(clk)
    begin
        if rising_edge(clk) then
            if init_wr_v = '1' then
                if profile_loaded = '1' then
                    color_ram(to_integer(init_wr_addr)) <= pri_q(47 downto 0);
                    map_ram(to_integer(init_wr_addr))   <= pri_map16(MAP_W-1 downto 0);
                else
                    color_ram(to_integer(init_wr_addr)) <= DEFAULT_COLOR;
                    map_ram(to_integer(init_wr_addr))   <= resize(init_wr_addr(7 downto 0), MAP_W);
                end if;
                fb_ram(to_integer(init_wr_addr(7 downto 0))) <= '0';
            elsif init_active = '0' then
                if we_color = '1' then color_ram(to_integer(idx_a)) <= din_color; end if;
                if we_map = '1'   then map_ram(to_integer(idx_a))   <= din_map;   end if;
                if we_fb = '1'    then fb_ram(to_integer(addr_a))   <= din_fb;    end if;
            end if;

            dout_map <= map_ram(to_integer(idx_a));
            dout_fb  <= fb_ram(to_integer(addr_a));
        end if;
    end process;

    -- Port B: Front Panel Controller Interface
    process(clk)
    begin
        if rising_edge(clk) then
            dout_color_b <= color_ram(to_integer(idx_b));
            dout_map_b   <= map_ram(to_integer(idx_b));
            dout_fb_b    <= fb_ram(to_integer(addr_b));
        end if;
    end process;
end architecture;

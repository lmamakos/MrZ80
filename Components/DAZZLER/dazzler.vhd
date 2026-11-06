-- ============================================================================
-- dazzler.vhd -- Cromemco "TV Dazzler" colour graphics for MrZ80 (R48)
--
-- Functional specification: doc/DAZZLER.md.
--
-- * Z80 side keeps the original port contract: OUT $0E = enable + picture
--   base (A15..A9), OUT $0F = format, IN $0E = sync status.
-- * Instead of the original's DMA, every qualifying Z80 memory write into
--   the enabled picture window is snooped into a 2 KB internal buffer;
--   memory itself still receives the write as usual, and reads are never
--   disturbed (doc/DAZZLER.md §5, §15).
-- * The renderer draws the buffer as an alternate video "page" on the same
--   free-running raster as the video terminal: 1600 clk x 526 lines at
--   50 MHz = 800 px x 526 lines @ ~59.41 Hz.  The terminal's vertical
--   counter wraps with `> VERT_SCANLINES-1`, i.e. 526 lines, not 525 --
--   the Dazzler must mirror that exact wrap (identical constants,
--   never-reset counters -- the R44 lock trick), else the page creeps
--   ~1 line/s against the syncs. The final
--   8-bit page mux lives in MrZ80.sv after video_cleaner, with the SSP
--   monitor taking precedence (doc/DAZZLER.md §17).
--
-- Single clock domain (clk = clk_sys, 50 MHz). Port and frame-buffer
-- writes are idempotent at the CPU's write rate; no wait states are ever
-- requested, so the guest CPU pays nothing (vs the ~15 % DMA slow-down of
-- the original board).
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity dazzler is
  generic (
    -- V-1 flip candidate (doc/DAZZLER.md §6): which nybble of a byte is
    -- the LEFT cell in normal-resolution mode. The manual's diagram reads
    -- LSB leftmost ("one picture element"), so default: low nybble left.
    NYBBLE_LEFT_IS_LOW : boolean := true;
    -- V-2 flip candidate (doc/DAZZLER.md §8): 2K quadrant ordering for
    -- ascending byte offsets. true = TL, TR, BL, BR.
    QUADS_ASCEND_LR_TB : boolean := true
  );
  port (
    clk       : in  std_logic;                      -- clk_sys 50 MHz
    n_reset   : in  std_logic;                      -- SYSTEM reset domain
      -- (N_RESET at the top: OSD Reset / RESET SYSTEM clears the Dazzler;
      --  RESET CPU leaves it running, as on the original board)

    -- Z80 I/O port interface, $0E/$0F. n_wr is already qualified by the
    -- core's chip-select (active-low). IN $0E readback is combinational.
    addr      : in  std_logic_vector(7 downto 0);   -- cpuAddress(7:0)
    wdata     : in  std_logic_vector(7 downto 0);   -- cpuDataOut
    n_wr      : in  std_logic;
    rdata     : out std_logic_vector(7 downto 0);   -- status ($0E reads)

    -- Z80 memory-write snoop: raw CPU memory cycle, active-high
    mem_wr    : in  std_logic;                      -- n_WR='0' and n_MREQ='0'
    mem_addr  : in  std_logic_vector(15 downto 0);   -- logical address
    mem_wdata : in  std_logic_vector(7 downto 0);

    -- video page: show gates the top-level mux (SSP precedence applied
    -- there); r/g/b are 8-bit per gun, valid whenever show='1'
    show      : out std_logic;
    r, g, b   : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of dazzler is

  -- ------------------------------------------------------------------
  -- Raster constants: identical to the SBCTextDisplayRGB instance in the
  -- core (50 MHz clocks). Counters never reset; both start at 0 at FPGA
  -- configuration, which keeps them locked forever.
  -- ------------------------------------------------------------------
  constant CPS      : natural := 1600;   -- clocks per scanline
  constant VSL      : natural := 525;   -- last line index; frame = 526 lines
                                        -- (mirrors the terminal's `> VSL-1`)

  -- Picture box: fixed 384 px x 384 lines centred in the terminal's
  -- 640x400 active area (which starts at clock 320 / scanline 75).
  constant BOX_X0_CLK : natural := 320 + 2*(640-384)/2;  -- 576
  constant BOX_X1_CLK : natural := BOX_X0_CLK + 2*384;    -- 1344
  constant BOX_Y0     : natural := 75  + (400-384)/2;     -- 83
  constant BOX_Y1     : natural := BOX_Y0 + 384 - 1;      -- 466

  -- End-of-frame window (IN $0E bit 6 low): first 60 scanlines of the
  -- vertical blank, approx. the original's 4 ms (57 lines @ 15.6 kHz).
  constant EOF_LINES  : natural := 60;

  -- ------------------------------------------------------------------
  -- Port registers (reset by n_reset = system reset)
  -- ------------------------------------------------------------------
  signal reg_en   : std_logic := '0';                       -- $0E bit 7
  signal reg_base : std_logic_vector(6 downto 0) := (others => '0'); -- A15..A9
  signal reg_fmt  : std_logic_vector(7 downto 0) := (others => '0'); -- $0F

  signal fmt_x4     : std_logic;   -- D6: resolution x4
  signal fmt_big    : std_logic;   -- D5: 2K (else 512B)
  signal fmt_colour : std_logic;   -- D4: colour (else B&W)
  signal fmt_word   : std_logic_vector(3 downto 0); -- D3..D0 int/B/G/R

  -- Cells per side and cell size in pixels (== lines, square cells):
  -- 32/64/128 cells -> 12/6/3 px (doc/DAZZLER.md §9/§11)
  signal ncells : natural range 32 to 128;
  signal cpx    : natural range 3 to 12;

  -- ------------------------------------------------------------------
  -- Free-running raster counters (never reset)
  -- ------------------------------------------------------------------
  signal hz     : unsigned(10 downto 0) := (others => '0');
  signal vln    : unsigned(9 downto 0)  := (others => '0');

  -- Cell scan position (self-aligning: reset at every line / frame edge)
  signal cellX  : unsigned(6 downto 0) := (others => '0');
  signal cellY  : unsigned(6 downto 0) := (others => '0');
  signal cx_clk : natural range 0 to 23 := 0;  -- clocks into current cell
  signal cy_ln  : natural range 0 to 11 := 0;  -- lines into current cell

  signal in_box : std_logic;

  -- ------------------------------------------------------------------
  -- Frame buffer: mirror of the picture-window bytes (doc/DAZZLER.md §5)
  -- ------------------------------------------------------------------
  type t_fb is array (0 to 2047) of std_logic_vector(7 downto 0);
  signal fb : t_fb := (others => (others => '0'));

  -- ------------------------------------------------------------------
  -- Byte address + sub-cell selects for the current pixel, then a
  -- one-clock pipeline. The frame buffer is read with an address derived
  -- from the current counters, and everything the colour decode needs
  -- (sub-cell select, mode, in-window) is registered alongside the read
  -- data, so all stay bit-aligned. The whole page therefore appears
  -- exactly one clk (20 ns) behind the terminal's own colour outputs --
  -- invisible, and constant (doc/DAZZLER.md §15/§17).
  -- ------------------------------------------------------------------
  signal fb_rd  : natural range 0 to 2047 := 0;
  signal sel_nib: std_logic := '0';                    -- 1 = high nybble
  signal sel_idx: natural range 0 to 7 := 0;          -- x4 bit in byte

  signal fb_q     : std_logic_vector(7 downto 0) := (others => '0');
  signal q_nib    : std_logic := '0';
  signal q_idx    : natural range 0 to 7 := 0;
  signal q_x4     : std_logic := '0';
  signal q_colour : std_logic := '0';
  signal q_fg     : std_logic_vector(3 downto 0) := (others => '0');
  signal q_in     : std_logic := '0';

  -- status: IN $0E bit 7 = even cell-row parity (held after the box),
  -- bit 6 = ~end-of-frame window (doc/DAZZLER.md §3)
  signal st_row_even : std_logic := '1';
  signal st_eof      : std_logic := '0';

  -- RGBI gun level: off $00, low-intensity $55, high-intensity $FF
  -- (matches the video terminal's shades)
  function gun(colour_bit : std_logic; bright : std_logic)
    return std_logic_vector is
  begin
    if colour_bit = '0' then return x"00";
    elsif bright = '1'  then return x"FF";
    else                     return x"55";
    end if;
  end function;

begin

  fmt_x4     <= reg_fmt(6);
  fmt_big    <= reg_fmt(5);
  fmt_colour <= reg_fmt(4);
  fmt_word   <= reg_fmt(3 downto 0);

  ncells <= 128 when (fmt_x4 = '1' and fmt_big = '1') else
             64 when (fmt_x4 = '1' or  fmt_big = '1') else
             32;

  cpx <= 12 when ncells = 32 else
          6  when ncells = 64 else
          3;

  show <= reg_en;

  -- ==================================================================
  -- Port writes (OUT $0E / OUT $0F). The strobe is active for several
  -- 50 MHz clocks per CPU I/O cycle; re-latching the same value is
  -- idempotent.
  -- ==================================================================
  ports : process (clk)
  begin
    if rising_edge(clk) then
      if n_reset = '0' then
        reg_en   <= '0';
        reg_base <= (others => '0');
        reg_fmt  <= (others => '0');
      elsif n_wr = '0' then
        if addr = x"0E" then
          reg_en   <= wdata(7);
          reg_base <= wdata(6 downto 0);
        elsif addr = x"0F" then
          reg_fmt  <= wdata;
        end if;
      end if;
    end if;
  end process;

  -- ==================================================================
  -- Memory-write snoop -> frame buffer.
  -- off = (logical addr - base) in 16-bit arithmetic (a window running
  -- off $FFFF wraps); captured while enabled and off < size.
  -- ==================================================================
  snoop : process (clk)
    variable off16 : unsigned(15 downto 0);
    variable ok    : boolean;
  begin
    if rising_edge(clk) then
      off16 := unsigned(mem_addr) -
               shift_left(resize(unsigned(reg_base), 16), 9);
      ok := (fmt_big = '1' and off16 < 2048) or
            (fmt_big = '0' and off16 < 512);
      if reg_en = '1' and mem_wr = '1' and ok then
        fb(to_integer(off16(10 downto 0))) <= mem_wdata;
      end if;
    end if;
  end process;

  -- ==================================================================
  -- Raster timing (free-running) + cell scan
  -- ==================================================================
  raster : process (clk)
    variable line_end : boolean;
  begin
    if rising_edge(clk) then
      -- hz is in 50 MHz clock units, exactly like the terminal's own
      -- horizCount: 1600 clocks per line, pixel = hz/2.
      line_end := false;
      if hz = CPS-1 then
        hz <= (others => '0');
        line_end := true;
      else
        hz <= hz + 1;
      end if;

      -- horizontal cell tracking (2*cpx clocks per cell: cpx pixels)
      if line_end then
        cellX  <= (others => '0');
        cx_clk <= 0;
      elsif in_box = '1' then
        if cx_clk = 2*cpx-1 then
          cx_clk <= 0;
          if cellX = ncells-1 then cellX <= (others => '0');
          else cellX <= cellX + 1;
          end if;
        else
          cx_clk <= cx_clk + 1;
        end if;
      end if;

      -- vertical cell tracking (advance at line-ends).  The gate must be the
      -- line index, NOT in_box: in_box includes the hz window, and a
      -- line-end is by definition at hz = CPS-1, outside it.
      if line_end then
        -- Match the terminal's wrap arithmetic exactly: SBCTextDisplayRGB
        -- counts 0..VERT_SCANLINES (`> VSL-1`), i.e. 526 lines per frame,
        -- not 525.  A 525-line frame here would restart one scanline early
        -- every frame -- the page creeps upward ~1 line/s against the
        -- syncs while terminal text stays put (hardware observation R48).
        if vln >= VSL then
          vln   <= (others => '0');
          cellY <= (others => '0');
          cy_ln <= 0;
        else
          vln <= vln + 1;
          if vln >= BOX_Y0 and vln <= BOX_Y1 then  -- the line just completed was in-box
            if cy_ln = cpx-1 then
              cy_ln <= 0;
              if cellY = ncells-1 then cellY <= (others => '0');
              else cellY <= cellY + 1;
              end if;
            else
              cy_ln <= cy_ln + 1;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  in_box <= '1' when (hz >= BOX_X0_CLK and hz < BOX_X1_CLK and
                      vln >= BOX_Y0    and vln <= BOX_Y1) else '0';

  -- ==================================================================
  -- Byte address + sub-cell select for the current pixel
  -- (inverse cell-map, doc/DAZZLER.md §16)
  -- ==================================================================
  address : process (cellX, cellY, fmt_x4, fmt_big)
    variable qn    : natural range 0 to 3;
    variable rown  : natural range 0 to 31;
    variable coln  : natural range 0 to 15;
    variable idxn  : natural range 0 to 7;
    variable xq    : natural range 0 to 63;   -- cell x, quadrant-local
    variable yq    : natural range 0 to 63;   -- cell y, quadrant-local
    variable bit_h : std_logic;
    variable bit_v : std_logic;
    variable xc    : natural range 0 to 127;
    variable yc    : natural range 0 to 127;
  begin
    xc := to_integer(cellX);
    yc := to_integer(cellY);

    -- quadrant number (2K modes; the quadrant bits sit at the cell-size
    -- boundary: 2K-normal halves at 32, 2K-x4 halves at 64)
    bit_h := '0';
    bit_v := '0';
    if fmt_big = '1' then
      if fmt_x4 = '1' then bit_h := cellX(6); bit_v := cellY(6);
      else                   bit_h := cellX(5); bit_v := cellY(5);
      end if;
    end if;
    qn := 0;
    if fmt_big = '1' then
      if QUADS_ASCEND_LR_TB then            -- TL, TR, BL, BR
        if bit_h = '1' then qn := qn + 1; end if;
        if bit_v = '1' then qn := qn + 2; end if;
      else                                  -- TL, BL, TR, BR
        if bit_v = '1' then qn := qn + 1; end if;
        if bit_h = '1' then qn := qn + 2; end if;
      end if;
    end if;

    if fmt_x4 = '1' then          -- 64-cell pages / quadrants
      xq := xc mod 64;
      yq := yc mod 64;
      rown := yq / 2;             -- row-pair: byte spans 2 cell rows
      coln := xq / 4;            -- byte spans 4 cells
    else                          -- 32-cell pages / quadrants
      xq := xc mod 32;
      yq := yc mod 32;
      rown := yq;
      coln := xq / 2;
    end if;

    fb_rd <= qn*512 + rown*16 + coln;

    -- normal-mode sub-cell: which nybble is the left cell (V-1)
    if fmt_x4 = '0' then
      if xq mod 2 = 1 then
        if NYBBLE_LEFT_IS_LOW then sel_nib <= '1'; else sel_nib <= '0'; end if;
      else
        if NYBBLE_LEFT_IS_LOW then sel_nib <= '0'; else sel_nib <= '1'; end if;
      end if;
    else
      sel_nib <= '0';
    end if;

    -- x4 bit-in-byte index, per the 4x2 patch (manual p. 4):
    --   top row:    D0 D1 D4 D5
    --   bottom row: D2 D3 D6 D7
    idxn := xq mod 4;
    if (xq mod 4) >= 2 then idxn := idxn + 2; end if;
    if (yq mod 2) = 1   then idxn := idxn + 2; end if;
    sel_idx <= idxn;
  end process;

  render : process (clk)
  begin
    if rising_edge(clk) then
      fb_q    <= fb(fb_rd);
      q_nib   <= sel_nib;
      q_idx   <= sel_idx;
      q_x4    <= fmt_x4;
      q_colour <= fmt_colour;
      q_fg    <= fmt_word;
      q_in    <= in_box;
    end if;
  end process;

  -- ==================================================================
  -- Colour decode (doc/DAZZLER.md §10). RGBI gun levels match the
  -- terminal: off $00, low $55, high $FF; B&W = 16 grey via g & g.
  -- ==================================================================
  decode : process (fb_q, q_nib, q_idx, q_x4, q_colour, q_fg, q_in)
    variable nib : std_logic_vector(3 downto 0);
    variable c4  : std_logic_vector(3 downto 0);
    variable lit : std_logic;
    variable ro  : std_logic_vector(7 downto 0);
    variable go  : std_logic_vector(7 downto 0);
    variable bo  : std_logic_vector(7 downto 0);
  begin
    nib := fb_q(3 downto 0);
    if q_nib = '1' then nib := fb_q(7 downto 4); end if;
    lit := fb_q(q_idx);

    if q_x4 = '1' then
      c4 := (others => '0');
      if lit = '1' then c4 := q_fg; end if;
    else
      c4 := nib;
    end if;

    if q_in = '0' then
      ro := x"00"; go := x"00"; bo := x"00";
    elsif q_colour = '0' then          -- B&W: 16-level grey
      ro := c4 & c4; go := c4 & c4; bo := c4 & c4;
    else                              -- RGBI
      ro := gun(c4(0), c4(3));
      go := gun(c4(1), c4(3));
      bo := gun(c4(2), c4(3));
    end if;

    r <= ro; g <= go; b <= bo;
  end process;

  -- ==================================================================
  -- IN $0E status bits
  -- ==================================================================
  status : process (clk)
  begin
    if rising_edge(clk) then
      if n_reset = '0' then
        st_row_even <= '1';
      elsif in_box = '1' then
        st_row_even <= not cellY(0);
      end if;
    end if;
  end process;

  st_eof <= '1' when vln >= EOF_LINES else '0';

  rdata <= (7 => st_row_even, 6 => st_eof, others => '1');

end architecture;

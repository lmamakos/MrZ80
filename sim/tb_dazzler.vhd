-- tb_dazzler.vhd -- GHDL smoke bench for Components/DAZZLER/dazzler.vhd (R48).
-- Lane: sim/run_dazzler.sh (make -C sim dazzler).
-- Colour expectations per doc/DAZZLER.md §10: nybble bits D0=R D1=G D2=B D3=I,
-- guns off $00 / low $55 / high $FF.  Geometry: normal-res 64-cell page in a
-- 2K buffer, cells 6x6 px in the 384-px box.
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity tb_dazzler is end entity;

architecture sim of tb_dazzler is
  signal clk        : std_logic := '0';
  signal n_reset    : std_logic := '0';
  signal addr       : std_logic_vector(7 downto 0) := (others => '0');
  signal wdata      : std_logic_vector(7 downto 0) := (others => '0');
  signal n_wr       : std_logic := '1';
  signal rdata      : std_logic_vector(7 downto 0);
  signal mem_wr     : std_logic := '0';
  signal mem_addr   : std_logic_vector(15 downto 0) := (others => '0');
  signal mem_wdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal show       : std_logic;
  signal rr, gg, bb : std_logic_vector(7 downto 0);
  constant T : time := 20 ns;
begin
  uut : entity work.dazzler(rtl)
    port map (clk, n_reset, addr, wdata, n_wr, rdata,
              mem_wr, mem_addr, mem_wdata, show, rr, gg, bb);

  clk <= not clk after T/2;

  stim : process
    procedure outp(a, d : std_logic_vector(7 downto 0)) is
    begin
      addr <= a; wdata <= d; n_wr <= '0';
      wait for 100 ns; n_wr <= '1'; wait for 20 ns;
    end procedure;
    procedure mw(a : std_logic_vector(15 downto 0); d : std_logic_vector(7 downto 0)) is
    begin
      mem_addr <= a; mem_wdata <= d; mem_wr <= '1';
      wait for 100 ns; mem_wr <= '0'; wait for 20 ns;
    end procedure;
    procedure wait_px(n : natural) is   -- n picture pixels = 2n clks
    begin
      for i in 0 to n*2-1 loop wait until rising_edge(clk); end loop;
    end procedure;
    impure function magenta return boolean is
    begin return rr = x"55" and gg = x"00" and bb = x"55"; end function;
    impure function redok return boolean is
    begin return rr = x"55" and gg = x"00" and bb = x"00"; end function;
    impure function blk return boolean is
    begin return rr = x"00" and gg = x"00" and bb = x"00"; end function;
    impure function white return boolean is
    begin return rr = x"FF" and gg = x"FF" and bb = x"FF"; end function;
    impure function cyanb return boolean is
    begin return rr = x"00" and gg = x"FF" and bb = x"FF"; end function;
    procedure chk(c : boolean; msg : string) is
    begin
        assert c report msg severity error;
    end procedure;
    variable ok         : boolean;
    variable gap, best  : integer;
    variable pm         : boolean;
    variable first      : boolean;
  begin
    n_reset <= '0'; wait for 200 ns; n_reset <= '1'; wait for 40 ns;

    -- enable, base $0200; normal resolution, colour, 2K buffer
    outp(x"0E", x"81");
    outp(x"0F", x"30");
    chk(show = '1', "show not asserted after enable");

    -- TL quadrant row 0: byte0 $15 -> cell0 low nibble 5 (R+B) dark
    -- magenta, cell1 high nibble 1 (R) dark red; byte1 $F0 -> cell2 black,
    -- cell3 white.
    mw(x"0200", x"15");
    mw(x"0201", x"F0");
    -- TR quadrant (offset 512) row 0 byte $0E -> cell32 low nibble E
    -- (G+B+I) bright cyan, cell33 high nibble 0 black.
    mw(x"0400", x"0E");
    -- offset 16 = byte row 1, col 0: cell(0,1) black, cell(1,1) bright
    -- cyan -- regression for the vertical cell scan (cellY must advance
    -- once every cpx lines; a horizontal-only probe cannot see this).
    mw(x"0210", x"E0");
    -- beyond the 2K window (offset 2560): must NOT alias onto offset 512
    -- (0x2F low nibble F would make cell32 white instead of cyan)
    mw(x"0C00", x"2F");

    -- The box's first non-black pixel is cell(0,0): dark magenta at px 0
    ok := false;
    while now < 40 ms loop
      wait until rising_edge(clk);
      if magenta then ok := true; exit; end if;
    end loop;
    chk(ok, "cell(0,0) dark magenta never appeared");

    -- cells are 6 px wide: magenta persists to px5, dark red from px6,
    -- black px12 (cell2), white px18 (cell3)
    wait_px(5);
    chk(magenta, "dark magenta did not persist across cell(0,0)");
    wait_px(1);
    chk(redok,  "cell(1,0) not dark red");
    wait_px(6);
    chk(blk,    "cell(2,0) not black");
    wait_px(6);
    chk(white,  "cell(3,0) not white");

    -- TR cell (32,0): px192, i.e. 174 px after cell(3,0) at px18
    wait_px(174);
    chk(cyanb,  "TR cell(32,0) not bright cyan");
    wait_px(3);
    chk(cyanb,  "TR cell did not persist");

    -- writes while disabled must not capture: disable, scribble at the
    -- window start, re-enable; next frame's cell(0,0) must STILL be dark
    -- magenta (byte still $15, not the scribbled $F0)
    outp(x"0E", x"00");
    chk(show = '0', "show still high after disable");
    mw(x"0200", x"F0");
    outp(x"0E", x"81");
    ok := false;
    while now < 80 ms loop
      wait until rising_edge(clk);
      if magenta then ok := true; exit; end if;
    end loop;
    chk(ok, "disabled-window write leaked / cell lost");

    -- wrap sanity: byte just below base ($01FF, offset 0xFFFF) must not
    -- capture anywhere; cell(63,0) (px 378, TR-column 31 -> fb offset 543,
    -- never written) stays black
    outp(x"0E", x"00"); mw(x"01FF", x"FF"); outp(x"0E", x"81");
    ok := false;
    while now < 120 ms loop
      wait until rising_edge(clk);
      if magenta then ok := true; exit; end if;
    end loop;
    chk(ok, "no magenta after re-enable (wrap test prep lost)");
    wait_px(378);
    chk(blk, "out-of-window write appeared at cell(63,0)");

    -- Vertical cell-scan regression: byte $0210 (byte row 1 = cell row 1,
    -- cpx=6) places bright cyan at cell(1,1).  Lock onto the dark-magenta
    -- pixel at cell(0,0) -- which only exists on cell-row-0 lines -- skip
    -- exactly one cell row (6 lines x 1600 clk), and expect cyan at cell
    -- x-pixel 6 on the first line of cell row 1.  If cellY were frozen at 0
    -- (in_box gating bug), this line would replay row 0 and pixel 6 would
    -- still be dark red, so the cyan check fails.
    ok := false;
    for i in 0 to 54000 loop           -- > one full frame
      wait until rising_edge(clk);
      if magenta then ok := true; exit; end if;
    end loop;
    chk(ok, "no cell-row-0 line start for vertical test");
    for i in 0 to 6*1600-1 loop wait until rising_edge(clk); end loop;
    wait_px(6);
    chk(cyanb, "cell(1,1) bright cyan absent -- vertical cell scan broken");
    wait_px(4);
    chk(cyanb, "cell(1,1) cyan did not persist across the cell");
    wait_px(2);
    chk(blk, "cell(2,1) not black after cell(1,1)");

    -- Frame-period lock: SBCTextDisplayRGB wraps its vertical counter with
    -- `> VERT_SCANLINES-1`, i.e. 526 lines per frame (off-by-one in the
    -- reference design, but it is the authority: the syncs come from it).
    -- The Dazzler must wrap identically or its page creeps ~1 line/frame
    -- upward against the syncs while text stays put (hardware R48).
    -- Observable: cell(0,0) magenta marks lines 83..88; the gap from the
    -- last burst line (88) to the next frame's first (83) spans
    -- (526-88)+83 = 521 lines = 833600 clks.  A 525-line frame gives
    -- 520 lines = 832000.  The first edge is skipped (arbitrary scan phase).
    gap := 0; best := 0; pm := false; first := true;
    for i in 0 to 2_000_000 loop
      wait until rising_edge(clk);
      gap := gap + 1;
      if magenta and not pm then
        if first then first := false;
        elsif best < gap then best := gap;
        end if;
        gap := 0;
      end if;
      pm := magenta;
    end loop;
    report "frame lock: longest burst gap =" & integer'image(best)
      & " clk (expect 833600 = 521 lines on a 526-line frame;"
      & " 525-line frame gives 832000)" severity note;
    chk(best >= 833_596 and best <= 833_604,
        "Dazzler frame period != terminal 526-line frame (page will creep)");

    -- status bits: low six always 1
    chk(rdata(5 downto 0) = "111111", "IN $0E low bits");

    report "PASS: tb_dazzler";
    wait;
  end process;
end architecture;

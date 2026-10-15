-- tb_sd_controller.vhd - self-checking testbench for sd_controller
-- (Components/SDCARD/sd_controller.vhd, the SPI SD card controller at I/O
-- ports $88-$8F) against a bit-level behavioural SPI SD card model.
--
-- The model implements mode 0 SPI, start-bit hunting for commands, CMD0, CMD8,
-- CMD55/ACMD41 (idle for POLLS polls), CMD58 (SDHC), CMD17 (read block) and
-- CMD24 (write block with data response and busy).  The host process drives
-- the register interface exactly like the Z-80 test programs do (poll STATUS
-- before every byte).
--
-- Generics (see sim/run_sd_controller.sh for the configurations run):
--   NCR_BITS      idle bits before the response (card access time)
--   POLLS         ACMD41 polls answered "idle" before the card is ready
--   V1            card is SDSC v1 (CMD8 is an illegal command)
--   INSERT_US     the card is "inserted" (starts responding) at this time
--   PROBE_US      if non-zero, print status and the diagnostic registers at this time
--   HS_DIV        sd_controller HS_DIVIDER (SPI clock after init = 50 MHz / (2*HS_DIV))
--   MISO_NS       delay of the card output plus board wiring (round trip), in ns
--   EXPECT_NOCARD the card never appears: check that the controller stays in
--                 init, keeps retrying and reports where it waits
--   DBG           print every command the card sees

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sd_controller is
  generic (HS_DIV : integer := 4; MISO_NS : integer := 0; EXPECT_NOCARD : boolean := false; INSERT_US : integer := 0; PROBE_US : integer := 0; NCR_BITS : integer := 8; POLLS : integer := 4; V1 : boolean := false; DBG : boolean := true; HOLD_MISO_HIGH : boolean := false);
end entity;

architecture sim of tb_sd_controller is
  signal clk      : std_logic := '0';
  signal n_reset  : std_logic := '0';
  signal n_rd, n_wr : std_logic := '1';
  signal dataIn   : std_logic_vector(7 downto 0) := (others=>'0');
  signal dataOut  : std_logic_vector(7 downto 0);
  signal regAddr  : std_logic_vector(2 downto 0) := "000";
  signal sdCS, sdMOSI, sdSCLK, driveLED : std_logic;
  signal sdMISO   : std_logic := '1';
  signal done     : boolean := false;
  signal sdhc_card : boolean := true;
begin
  clk <= not clk after 10 ns when not done;

  initcnt: process
  begin
    << signal .tb_sd_controller.dut.clkCount : std_logic_vector(6 downto 0) >> <= force "0000000";
    wait for 15 ns;
    << signal .tb_sd_controller.dut.clkCount : std_logic_vector(6 downto 0) >> <= release;
    wait;
  end process;

  dut: entity work.sd_controller
    generic map (HS_DIVIDER => HS_DIV)
    port map (sdCS=>sdCS, sdMOSI=>sdMOSI, sdMISO=>sdMISO, sdSCLK=>sdSCLK,
              n_reset=>n_reset, n_rd=>n_rd, n_wr=>n_wr, dataIn=>dataIn,
              dataOut=>dataOut, regAddr=>regAddr, clk=>clk, driveLED=>driveLED);

  ---------------------------------------------------------------------------
  -- SPI SD card model (mode 0, bit level)
  ---------------------------------------------------------------------------
  card: process(sdSCLK, sdCS)
    type bitq_t is array (0 to 8191) of std_logic;
    variable q : bitq_t;
    variable qlen, qpos : integer := 0;
    variable cnt : integer := 0;          -- bits collected of a command
    variable sh  : std_logic_vector(47 downto 0);
    variable mode : integer := 0;         -- 0 cmd hunt, 1 wait write token, 2 collect write data
    variable wcnt : integer := 0;
    variable wdata : std_logic_vector(7 downto 0);
    variable wk : integer := 0;
    type store_t is array (0 to 511) of integer;
    variable wr_store : store_t;
    variable wr_arg : unsigned(31 downto 0);
    variable have_wr : boolean := false;
    variable init_ok : boolean := false;
    variable acmd : boolean := false;
    variable idle_polls : integer := 0;
    variable cmd : integer; variable arg : unsigned(31 downto 0);
    variable lba_addr : unsigned(31 downto 0);
    procedure push(b : std_logic) is begin q(qlen) := b; qlen := qlen+1; end;
    procedure push_byte(v : integer) is
      variable u : unsigned(7 downto 0) := to_unsigned(v,8);
    begin for i in 7 downto 0 loop push(u(i)); end loop; end;
    procedure start_resp is
    begin qlen := 0; qpos := 0; for i in 1 to NCR_BITS loop push('1'); end loop; end;
  begin
    if now < INSERT_US * 1 us then
      sdMISO <= transport '1' after MISO_NS * 1 ns;
      cnt := 0; mode := 0; qlen := 0; qpos := 0;
    elsif sdCS = '1' then
      cnt := 0; mode := 0; qlen := 0; qpos := 0;
      sdMISO <= transport '1' after MISO_NS * 1 ns;
    elsif rising_edge(sdSCLK) then
      -- sample MOSI
      if mode = 0 then
        if cnt = 0 then
          if sdMOSI = '0' then sh(47) := '0'; cnt := 1; end if;
        elsif cnt = 1 then
          if sdMOSI = '1' then sh(46) := '1'; cnt := 2; else cnt := 1; end if;
        else
          sh(47-cnt) := sdMOSI; cnt := cnt + 1;
          if cnt = 48 then
            cnt := 0;
            cmd := to_integer(unsigned(sh(45 downto 40)));
            arg := unsigned(sh(39 downto 8));
            start_resp;
            if DBG then report "card: CMD" & integer'image(cmd) & " arg=" & integer'image(to_integer(arg(30 downto 0))); end if;
            case cmd is
              when 0 => push_byte(16#01#); init_ok := false; acmd := false; idle_polls := 0;
              when 8 => if V1 then push_byte(16#05#); else push_byte(16#01#); push_byte(0); push_byte(0); push_byte(1); push_byte(16#AA#); end if;
              when 55 => if init_ok then push_byte(0); else push_byte(1); end if; acmd := true;
              when 41 =>
                if acmd then
                  idle_polls := idle_polls + 1;
                  if idle_polls >= POLLS then init_ok := true; push_byte(0); else push_byte(1); end if;
                else push_byte(16#05#); end if;
                acmd := false;
              when 58 => push_byte(0); if V1 then push_byte(16#80#); else push_byte(16#C0#); end if; push_byte(16#FF#); push_byte(16#80#); push_byte(0);
              when 17 =>
                push_byte(0);
                for i in 1 to 16 loop push('1'); end loop;
                push_byte(16#FE#);
                for i in 0 to 511 loop
                  if have_wr and arg = wr_arg then
                    push_byte(wr_store(i));
                  elsif V1 then
                    push_byte((i + to_integer(arg(16 downto 9))*3) mod 256);
                  else
                    push_byte((i + to_integer(arg(7 downto 0))*3) mod 256);
                  end if;
                end loop;
                push_byte(16#FF#); push_byte(16#FF#);
              when 24 =>
                push_byte(0);
                lba_addr := arg;
                mode := 1; wcnt := 0;
              when others => push_byte(16#04#);
            end case;
            if cmd /= 55 then acmd := (cmd = 55); end if;
          end if;
        end if;
      elsif mode = 1 then   -- wait for start token (first 0 bit)
        if sdMOSI = '0' then mode := 2; wk := 0; end if;   -- hunting FE: last bit
      elsif mode = 2 then
        wk := wk + 1;
        if wk <= 4096 then
          wdata := wdata(6 downto 0) & sdMOSI;
          if wk mod 8 = 0 then wr_store(wk/8 - 1) := to_integer(unsigned(wdata)); end if;
        end if;
        if wk = 4096 + 16 then
          wr_arg := lba_addr; have_wr := true;
          -- data response then busy
          qlen := 0; qpos := 0;
          push_byte(16#E5#);
          for i in 1 to 2000 loop push('0'); end loop;
          mode := 0; cnt := 0;
          if DBG then report "card: write data received"; end if;
        end if;
      end if;
    elsif falling_edge(sdSCLK) then
      if HOLD_MISO_HIGH then sdMISO <= transport '1' after MISO_NS * 1 ns;
      elsif qpos < qlen then sdMISO <= transport q(qpos) after MISO_NS * 1 ns; qpos := qpos + 1;
      else sdMISO <= transport '1' after MISO_NS * 1 ns; end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- host
  ---------------------------------------------------------------------------
  meas: process(sdSCLK)
    variable last : time := 0 ns; variable n : integer := 0;
  begin
    if rising_edge(sdSCLK) then
      if n < 3 or n = 150 then report "sclk period " & time'image(now-last) & " (edge " & integer'image(n) & ")"; end if;
      n := n + 1; last := now;
    end if;
  end process;

  host: process
    variable s : std_logic_vector(7 downto 0);
    variable d : std_logic_vector(7 downto 0);
    variable t : integer;
    procedure wr(r : integer; v : integer) is
    begin
      regAddr <= std_logic_vector(to_unsigned(r,3));
      dataIn  <= std_logic_vector(to_unsigned(v,8));
      wait for 100 ns; n_wr <= '0'; wait for 200 ns; n_wr <= '1'; wait for 100 ns;
    end;
    procedure rd(r : integer; v : out std_logic_vector(7 downto 0)) is
    begin
      regAddr <= std_logic_vector(to_unsigned(r,3));
      wait for 100 ns; n_rd <= '0'; wait for 150 ns;
      v := dataOut;
      wait for 50 ns; n_rd <= '1'; wait for 100 ns;
    end;
    procedure wait_status(mask : std_logic_vector(7 downto 0); val : std_logic_vector(7 downto 0);
                          limit_us : integer; ok : out boolean) is
      variable st : std_logic_vector(7 downto 0);
      variable n : integer := 0;
    begin
      ok := false;
      while n < limit_us*3 loop
        rd(1, st);
        if (st and mask) = val then ok := true; return; end if;
        n := n + 1;
      end loop;
    end;
    variable ok : boolean;
    variable b : std_logic_vector(7 downto 0);
    variable mism : integer;
    variable vi : integer := 0;
    variable tp : time;
  begin
    wait for 200 ns;
    n_reset <= '1';
    report "reset released";
    rd(1, s); report "status after reset: " & integer'image(to_integer(unsigned(s)));
    if PROBE_US > 0 then
      wait for PROBE_US * 1 us;
      rd(1,s); report "probe: status=" & integer'image(to_integer(unsigned(s)));
      rd(5,s); report "probe: reg5 state=" & integer'image(to_integer(unsigned(s)));
      rd(6,s); report "probe: reg6 step=" & integer'image(to_integer(unsigned(s)));
      rd(7,s); report "probe: reg7 pins=0x" & to_hstring(s);
    end if;
    if EXPECT_NOCARD then
      rd(1, s);
      assert s = x"90" report "no card: status should stay 90h" severity failure;
      rd(5, s); assert s = x"10" report "no card: reg5 should be 10h (receive_byte_wait)" severity failure;
      rd(6, s); assert s = x"03" report "no card: reg6 should be 03h (waiting for CMD0 response)" severity failure;
      rd(7, s); assert unsigned(s(2 downto 0)) >= 1 report "no card: retries should be >= 1" severity failure;
      assert s(3) = '0' report "sdCD input" severity failure;
      report "PASS: tb_sd_controller (no card: stays in init, retries, reports where)";
      done <= true; wait;
    end if;
    wait_status(x"F0", x"80", 1000000, ok);
    if not ok then
      rd(1, s);
      report "INIT NEVER COMPLETED, status=" & integer'image(to_integer(unsigned(s))) severity failure;
    end if;
    report "init done at " & time'image(now);
    rd(5,s); report "reg5 state=" & integer'image(to_integer(unsigned(s)));
    rd(6,s); report "reg6 step=" & integer'image(to_integer(unsigned(s)));
    rd(7,s); report "reg7 pins=0x" & to_hstring(s);
    -- read block 5
    wr(2, 5); wr(3, 0); wr(4, 0); wr(1, 0);
    -- the SPI clock after init is 50 MHz / (2 * HS_DIV)
    wait until rising_edge(sdSCLK); tp := now;
    wait until rising_edge(sdSCLK);
    report "data phase sclk period " & time'image(now - tp);
    assert now - tp = HS_DIV * 40 ns report "wrong SPI clock period after init" severity failure;
    mism := 0;
    if V1 then vi := 1; end if;
    for i in 0 to 511 loop
      wait_status(x"E0", x"E0", 1000, ok);
      if not ok then report "read byte timeout at " & integer'image(i) severity failure; end if;
      rd(0, b);
      if to_integer(unsigned(b)) /= (i + 15) mod 256 then mism := mism + 1;
        if mism < 5 then report "mismatch at " & integer'image(i) & " got " & integer'image(to_integer(unsigned(b))); end if;
      end if;
    end loop;
    wait_status(x"F0", x"80", 1000, ok);
    report "read block done ok=" & boolean'image(ok) & " mismatches=" & integer'image(mism);
    -- write block 7
    wr(2, 7); wr(3, 0); wr(4, 0); wr(1, 1);
    for i in 0 to 511 loop
      wait_status(x"E0", x"A0", 5000, ok);
      if not ok then report "write byte timeout at " & integer'image(i) severity failure; end if;
      wr(0, i mod 256);
    end loop;
    wait_status(x"F0", x"80", 5000, ok);
    report "write block done ok=" & boolean'image(ok);
    assert ok report "write did not return to idle" severity failure;
    -- read the written block back
    wr(2, 7); wr(3, 0); wr(4, 0); wr(1, 0);
    mism := 0;
    for i in 0 to 511 loop
      wait_status(x"E0", x"E0", 1000, ok);
      if not ok then report "readback byte timeout at " & integer'image(i) severity failure; end if;
      rd(0, b);
      if to_integer(unsigned(b)) /= i mod 256 then mism := mism + 1; end if;
    end loop;
    wait_status(x"F0", x"80", 1000, ok);
    assert ok report "readback did not return to idle" severity failure;
    assert mism = 0 report "write/readback mismatch" severity failure;
    assert mism = 0 report "read data mismatch" severity failure;
    report "PASS: tb_sd_controller";
    done <= true;
    wait;
  end process;
end architecture;

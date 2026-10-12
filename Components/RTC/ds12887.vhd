--============================================================================
-- ds12887.vhd
--
-- DS12887 (DS1288X) battery-backed RTC+RAM peripheral model for MiSTer
-- FPGA cores (Z80 or otherwise).
--
-- The canonical DS12887 register map (128 bytes, A0-A6) is emulated:
--
--   0x00  seconds          0x06  day of week (1-7, Sunday=1)
--   0x01  alarm seconds    0x07  date (1-31)
--   0x02  minutes          0x08  month (1-12)
--   0x03  alarm minutes    0x09  year (00-99)
--   0x04  hours            0x0A  Register A  (UIP, DV2, DV1, DV0, RS3-0)
--   0x05  alarm hours      0x0B  Register B  (SET,PIE,AIE,UIE,SQWE,DM,24/12,DSE)
--   0x0C  Register C (read clears flags)   0x0D  Register D (read-only)
--   0x10-0x7F  112 bytes general purpose RAM
--
-- Time source: the MiSTer host supplies BCD time on the 65-bit `rtc` bus
-- (hps_io.RTC).  The host pushes it at core load (before reset release) and
-- again once every 60 s for any generic 0xA4 core; rtc(64) toggles on each
-- push.  This model:
--   * follows the host data while in reset (the load-time push), and
--   * resyncs on rtc(64) edges afterwards -- unless guest software has
--     written the time/calendar/alarm itself (guest then owns the clock,
--     like the NeXT core's policy), and
--   * counts locally between host updates (1 Hz from clk_sys, with the
--     244 us update transfer and UIP pulse).
--
-- Behaviour:
--   * BCD (DM=0) and binary (DM=1) time/calendar; 12/24-hour mode
--     (12-h BCD: 01-12 AM / 81-92 PM, bit7=PM; 12-h binary: 01-0C/81-8C)
--   * calendar with leap years (day-of-week, date, month, year 00-99)
--   * once-per-second update cycle: UIP pulse + 244 us transfer of the
--     internal copy to the user copy; SET bit freezes the user copy
--   * time/calendar writes update both copies (the documented
--     SET=1 write / SET=0 programming procedure)
--   * alarm compare at the update transfer with 11XXXXXX don't-care codes
--     (alarm every s/min/hr/day); alarm registers read back exactly as
--     written
--   * Register A oscillator control: DV2/DV1/DV0 = 010 counts; 11X holds
--     the chain (frozen); any other pattern stops the chain (frozen)
--   * Register A RS3-0 periodic tap, 2 Hz .. 8192 Hz, sets the PF flag
--   * three maskable interrupts PF/AF/UF, IRQF = PF*PIE + AF*AIE + UF*UIE
--     (latched), /IRQ open-drain (tristate when idle, like the real part),
--     Register C read clears all flags
--   * Register D VRT from the `pof_in` simulation input
--   * 112-byte RAM at 0x10-0x7F
--
-- Not implemented (documented deviations):
--   * SQW pin output (the `sqw` port exists and is held low)
--   * daylight savings (DSE is stored, no effect)
--   * tap frequencies above 128 Hz carry a <0.1% rate approximation from
--     the 50/100 MHz system clock (no 32768 Hz reference on MiSTer)
--
-- Bus interface (MSX-style, asserted during the Z80 I/O cycle):
--   req  - chip select (address decode hit), level
--   wrt  - write cycle (timed to /IOWR)
--   adr  - A0-A6 of the DS12887 address space
--   dbo  - data in from the CPU
--   dbi  - data out to the CPU (combinational during req & !wrt)
--
--============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ds12887 is
    generic (
        SYS_CLK : integer := 50_000_000;  -- clk_sys frequency (50/100 MHz)
        TB_MODE : boolean := false        -- shrink counters for simulation
    );
    port (
        clk_sys   : in  std_logic;
        reset     : in  std_logic;          -- core cold reset (active high)

        -- Z80 bus side
        req       : in  std_logic;
        wrt       : in  std_logic;
        adr       : in  std_logic_vector(6 downto 0);
        dbo       : in  std_logic_vector(7 downto 0);
        dbi       : out std_logic_vector(7 downto 0);
        irq       : out std_logic;          -- open-drain /IRQ (tri when idle)
        sqw       : out std_logic;          -- held low (see header note)

        -- MiSTer hps_io time source
        rtc       : in  std_logic_vector(64 downto 0);  -- BCD + toggle(64)
        timestamp : in  std_logic_vector(32 downto 0) := (others => '0');

        pof_in    : in  std_logic := '0'    -- power-fail sim (Reg D VRT)
    );
end entity ds12887;

architecture rtl of ds12887 is

    ------------------------------------------------------------------------
    -- timing constants
    -- (a conditional-value expression is not allowed in a constant
    --  initializer, so the generic selects go through a function)
    ------------------------------------------------------------------------
    function sel_i(tb : boolean; t : integer; r : integer)
        return integer is
    begin
        if tb then
            return t;
        end if;
        return r;
    end function;

    constant CLK_50M  : boolean := (SYS_CLK = 50_000_000);
    constant TICK_MAX : integer := sel_i(TB_MODE, 24, SYS_CLK - 1);
    constant UIP_TMO  : integer := sel_i(TB_MODE, 0,
                           sel_i(CLK_50M, 12_200_000, 24_400_000));
    constant UIP_HI   : integer := sel_i(TB_MODE, 10,
                           sel_i(CLK_50M, 16_800_000, 33_600_000));
    -- top periodic-tap event period (16384 Hz target)
    constant TAP_T    : integer := sel_i(TB_MODE, 1,
                           sel_i(CLK_50M, 3051, 6103));

    -- Register B bit positions
    constant B_SET  : integer := 7;
    constant B_PIE  : integer := 6;
    constant B_AIE  : integer := 5;
    constant B_UIE  : integer := 4;
    constant B_SQWE : integer := 3;
    constant B_DM   : integer := 2;
    constant B_2412 : integer := 1;
    constant B_DSE  : integer := 0;

    ------------------------------------------------------------------------
    -- time representation
    ------------------------------------------------------------------------
    subtype nybble_t is std_logic_vector(3 downto 0);
    subtype byte_t   is std_logic_vector(7 downto 0);
    type ttime is record
        sec, min        : integer range 0 to 59;
        hour            : integer range 0 to 23;  -- always 24-h internally
        dow, date, mon, year : integer range 0 to 99;  -- dow 0=Sunday
    end record;

    ------------------------------------------------------------------------
    -- 1 Hz tick, UIP window
    ------------------------------------------------------------------------
    signal tick_cnt : unsigned(26 downto 0) := (others => '0');
    signal tick_ev  : std_logic := '0';

    signal uip_cnt  : unsigned(26 downto 0) := (others => '0');
    signal uip_raw  : std_logic := '0';
    signal uip      : std_logic := '0';
    signal xfer_ev  : std_logic := '0';

    ------------------------------------------------------------------------
    -- periodic interrupt taps (Register A RS3-0)
    ------------------------------------------------------------------------
    signal tap_cnt : unsigned(13 downto 0) := (others => '0');
    signal taps    : std_logic_vector(12 downto 0) := (others => '0');
    -- taps(0) ~ 2 Hz ... taps(12) ~ 8192 Hz
    signal pf_ev   : std_logic := '0';

    ------------------------------------------------------------------------
    -- host sync
    ------------------------------------------------------------------------
    signal tog_r1    : std_logic := '0';
    signal tog_r2    : std_logic := '0';
    signal host_ev   : std_logic := '0';
    signal host_raw  : std_logic_vector(63 downto 0) := (others => '0');
    -- pending host sync: handshake between the host-sync process (sync_req)
    -- and the core process (sync_ack) so each signal has a single driver
    signal sync_req  : std_logic := '0';
    signal sync_ack  : std_logic := '0';
    signal synced    : std_logic := '0';   -- host data applied at least once
    signal guest_owned : std_logic := '0'; -- guest wrote time/calendar/alarm

    ------------------------------------------------------------------------
    -- time / alarm storage
    ------------------------------------------------------------------------
    signal it : ttime;                 -- internal (counting / shadow) copy
    signal ut : ttime;                 -- user copy (what the CPU sees)

    signal alr_s : std_logic_vector(7 downto 0) := (others => '0');
    signal alr_m : std_logic_vector(7 downto 0) := (others => '0');
    signal alr_h : std_logic_vector(7 downto 0) := (others => '0');

    ------------------------------------------------------------------------
    -- control registers, flags, RAM
    ------------------------------------------------------------------------
    signal a_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal b_reg  : std_logic_vector(7 downto 0) := (others => '0');

    signal c_pf   : std_logic := '0';
    signal c_af   : std_logic := '0';
    signal c_uf   : std_logic := '0';
    signal c_irqf : std_logic := '0';

    type ram_t is array (0 to 111) of std_logic_vector(7 downto 0);
    signal ram    : ram_t := (others => (others => '0'));
    signal ram_idx : integer range 0 to 111 := 0;
    signal ram_dq : std_logic_vector(7 downto 0) := (others => '0');

    -- helpers
    function bc2b(s : std_logic_vector(3 downto 0)) return integer;
    function b2bc(v : integer) return nybble_t;
    function v2bcd(v : integer) return byte_t;
    function dec_byte(d : std_logic_vector(7 downto 0); bcd : boolean)
        return integer;
    function enc_sec(v : integer; bcd : boolean)
        return byte_t;
    function enc_hour(v : integer; bcd : boolean; h24 : boolean)
        return byte_t;
    function host_valid(r : std_logic_vector(63 downto 0)) return boolean;
    procedure host_decode(r : in std_logic_vector(63 downto 0);
                          ht : out ttime);

    ------------------------------------------------------------------------
    -- helper definitions (must precede the concurrent statements)
    ------------------------------------------------------------------------
    function bc2b(s : std_logic_vector(3 downto 0)) return integer is
    begin
        return to_integer(unsigned(s));
    end function;

    function b2bc(v : integer) return nybble_t is
    begin
        return std_logic_vector(to_unsigned(v mod 10, 4));
    end function;

    function v2bcd(v : integer) return byte_t is
    begin
        return b2bc(v / 10) & b2bc(v mod 10);
    end function;

    -- BCD: byte holds tens (7:4) and units (3:0); binary: raw value
    function dec_byte(d : std_logic_vector(7 downto 0); bcd : boolean)
        return integer is
        variable v : integer;
    begin
        if bcd then
            v := 10 * bc2b(d(7 downto 4)) + bc2b(d(3 downto 0));
        else
            v := to_integer(unsigned(d));
        end if;
        return v;
    end function;

    function enc_sec(v : integer; bcd : boolean)
        return byte_t is
    begin
        if bcd then
            return v2bcd(v);
        else
            return std_logic_vector(to_unsigned(v, 8));
        end if;
    end function;

    -- 24-h: BCD 00-23 / binary 0-23
    -- 12-h: BCD 01-12 AM, 81-92 PM (bit7=PM, 12 = 0x12/0x92)
    --       binary 01-0C / 81-8C (bit7=PM, hour 1-12)
    function enc_hour(v : integer; bcd : boolean; h24 : boolean)
        return byte_t is
        variable h12 : integer;
        variable pmb, tens : std_logic;
    begin
        if h24 then
            return enc_sec(v, bcd);
        end if;
        if v >= 12 then
            pmb := '1';
        else
            pmb := '0';
        end if;
        h12 := v mod 12;
        if h12 = 0 then
            h12 := 12;
        end if;
        if bcd then
            -- {PM, tens(0|1), 00, units}
            if h12 >= 10 then
                tens := '1';
            else
                tens := '0';
            end if;
            return pmb & tens & "00" & b2bc(h12 mod 10);
        else
            -- {PM, 000, hour 1-12}
            return pmb & "000" & std_logic_vector(to_unsigned(h12, 4));
        end if;
    end function;

    function host_valid(r : std_logic_vector(63 downto 0)) return boolean is
        variable v : integer;
    begin
        v := 10 * bc2b(r(7 downto 4)) + bc2b(r(3 downto 0));
        if v > 59 then return false; end if;            -- seconds
        v := 10 * bc2b(r(15 downto 12)) + bc2b(r(11 downto 8));
        if v > 59 then return false; end if;            -- minutes
        v := 10 * bc2b(r(23 downto 20)) + bc2b(r(19 downto 16));
        if v > 23 then return false; end if;            -- hours (24-h)
        if to_integer(unsigned(r(55 downto 48))) > 6 then return false; end if;
        v := 10 * bc2b(r(39 downto 36)) + bc2b(r(35 downto 32));
        if v < 1 or v > 12 then return false; end if;   -- month
        v := 10 * bc2b(r(31 downto 28)) + bc2b(r(27 downto 24));
        if v < 1 or v > 31 then return false; end if;   -- date
        return true;
    end function;

    procedure host_decode(r : in std_logic_vector(63 downto 0);
                          ht : out ttime) is
        variable v : integer;
    begin
        ht.sec  := 10 * bc2b(r(7 downto 4)) + bc2b(r(3 downto 0));
        ht.min  := 10 * bc2b(r(15 downto 12)) + bc2b(r(11 downto 8));
        ht.hour := 10 * bc2b(r(23 downto 20)) + bc2b(r(19 downto 16));
        ht.dow  := to_integer(unsigned(r(55 downto 48)));
        ht.date := 10 * bc2b(r(31 downto 28)) + bc2b(r(27 downto 24));
        ht.mon  := 10 * bc2b(r(39 downto 36)) + bc2b(r(35 downto 32));
        ht.year := 10 * bc2b(r(47 downto 44)) + bc2b(r(43 downto 40));
    end procedure;

begin

    ------------------------------------------------------------------------
    -- 1 Hz tick
    ------------------------------------------------------------------------
    process (clk_sys)
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                tick_cnt <= (others => '0');
                tick_ev  <= '0';
            else
                tick_ev <= '0';
                if tick_cnt = to_unsigned(TICK_MAX, tick_cnt'length) then
                    tick_cnt <= (others => '0');
                    tick_ev  <= '1';
                else
                    tick_cnt <= unsigned(tick_cnt) + 1;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- UIP window: pulses on each tick, transfer at 244 us
    ------------------------------------------------------------------------
    process (clk_sys)
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                uip_cnt <= (others => '0');
                uip_raw <= '0';
            elsif tick_ev = '1' then
                uip_cnt <= (others => '0');
                uip_raw <= '1';
            elsif uip_raw = '1' and uip_cnt = to_unsigned(UIP_HI, uip_cnt'length) then
                uip_raw <= '0';
            elsif uip_raw = '1' then
                uip_cnt <= unsigned(uip_cnt) + 1;
            end if;
        end if;
    end process;

    uip     <= uip_raw when b_reg(B_SET) = '0' else '0';
    xfer_ev <= '1' when uip_raw = '1' and
               uip_cnt = to_unsigned(UIP_TMO, uip_cnt'length) else '0';

    ------------------------------------------------------------------------
    -- periodic tap chain: top event ~16384 Hz, halving FF stages
    ------------------------------------------------------------------------
    process (clk_sys)
        variable tv  : std_logic_vector(13 downto 0);
        variable up  : std_logic_vector(13 downto 0);
        variable sel : std_logic;
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                tap_cnt <= (others => '0');
                taps    <= (others => '0');
                pf_ev   <= '0';
            else
                pf_ev <= '0';

                if tap_cnt = to_unsigned(TAP_T, tap_cnt'length) then
                    tap_cnt <= (others => '0');
                    tv(13)  := '1';
                else
                    tap_cnt <= unsigned(tap_cnt) + 1;
                    tv(13)  := '0';
                end if;

                tv(12) := taps(12) xnor tv(13);
                up(12) := tv(12) and not taps(12);
                for i in 11 downto 0 loop
                    tv(i) := taps(i) xnor up(i + 1);
                    up(i) := tv(i) and not taps(i);
                end loop;
                taps <= tv(12 downto 0);

                sel := '0';
                -- oscillator must be running (DV2 DV1 DV0 = 010)
                if a_reg(6) = '0' and a_reg(5) = '1' and a_reg(4) = '0' then
                    case a_reg(3 downto 0) is
                        when "1111" => sel := up(0);   -- 2 Hz
                        when "1110" => sel := up(1);   -- 4 Hz
                        when "1101" => sel := up(2);   -- 8 Hz
                        when "1100" => sel := up(3);   -- 16 Hz
                        when "1011" => sel := up(4);   -- 32 Hz
                        when "1010" => sel := up(5);   -- 64 Hz
                        when "1001" => sel := up(6);   -- 128 Hz
                        when "0010" => sel := up(6);   -- 128 Hz
                        when "1000" => sel := up(7);   -- 256 Hz
                        when "0001" => sel := up(7);   -- 256 Hz
                        when "0111" => sel := up(8);   -- 512 Hz
                        when "0110" => sel := up(9);   -- 1.024 kHz
                        when "0101" => sel := up(10);  -- 2.048 kHz
                        when "0100" => sel := up(11);  -- 4.096 kHz
                        when "0011" => sel := up(12);  -- 8.192 kHz
                        when others => sel := '0';     -- 0000: none
                    end case;
                end if;
                pf_ev <= sel;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- host sync detection: runs even in reset so the load-time push is
    -- captured (hps_io latches the data before the core reset releases)
    ------------------------------------------------------------------------
    process (clk_sys)
    begin
        if rising_edge(clk_sys) then
            tog_r1 <= rtc(64);
            tog_r2 <= tog_r1;
            if tog_r1 /= tog_r2 then
                host_raw <= rtc(63 downto 0);
                host_ev  <= '1';
            else
                host_ev  <= '0';
            end if;
            if reset = '1' then
                sync_req <= sync_ack;           -- clear pending
            elsif host_ev = '1' then
                sync_req <= not sync_ack;       -- set pending
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- core: storage, calendar, alarm, flags, bus
    ------------------------------------------------------------------------
    process (clk_sys)
        variable n_it, n_ut   : ttime;
        variable n_as, n_am, n_ah : std_logic_vector(7 downto 0);
        variable n_a, n_b     : std_logic_vector(7 downto 0);
        variable n_pf, n_af, n_uf, n_irqf : std_logic;
        variable bcd_m, h24_m : boolean;
        variable val : integer;
        variable es, em, eh   : std_logic_vector(7 downto 0);
        variable ht           : ttime;
        variable day_carry    : boolean;
        variable m_days       : integer;
        variable wr_reg, wr_time : boolean;
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                -- sane defaults; the host data is applied while in reset
                it <= (sec => 0, min => 0, hour => 0,
                       dow => 0, date => 1, mon => 1, year => 80);
                ut <= (sec => 0, min => 0, hour => 0,
                       dow => 0, date => 1, mon => 1, year => 80);
                alr_s <= (others => '0');
                alr_m <= (others => '0');
                alr_h <= (others => '0');
                a_reg <= (others => '0');
                c_pf  <= '0'; c_af <= '0'; c_uf <= '0'; c_irqf <= '0';
                synced      <= '0';
                guest_owned <= '0';
                if host_valid(host_raw) then
                    host_decode(host_raw, ht);
                    it <= ht;
                    ut <= ht;
                    a_reg <= "00100000";   -- DV=010: osc running, clock live
                    b_reg <= "00000010";   -- 24-h BCD (host sends 24-h)
                    synced <= '1';
                else
                    b_reg <= (others => '0');
                end if;
            else
                n_it := it; n_ut := ut;
                n_as := alr_s; n_am := alr_m; n_ah := alr_h;
                n_a  := a_reg; n_b := b_reg;
                n_pf := c_pf; n_af := c_af; n_uf := c_uf; n_irqf := c_irqf;
                bcd_m := (b_reg(B_DM) = '0');
                h24_m := (b_reg(B_2412) = '1');

                ------------------------------------------------------------
                -- (a) calendar tick (internal copy)
                --     Reg A DV2/DV1/DV0: 010 = count, otherwise frozen
                --     (11X "hold in reset" is observable only via SQW,
                --      which is not generated, so it is treated as frozen)
                --     SET=1 pauses the calendar so the documented
                --     SET=1 write / SET=0 programming procedure is race-free
                --     (the tick/UIP/periodic-tap pulse trains keep running)
                ------------------------------------------------------------
                if a_reg(6) = '0' and a_reg(5) = '1' and a_reg(4) = '0'
                   and b_reg(B_SET) = '0' and tick_ev = '1' then
                    day_carry := false;
                    if n_it.sec < 59 then
                        n_it.sec := n_it.sec + 1;
                    else
                        n_it.sec := 0;
                        if n_it.min < 59 then
                            n_it.min := n_it.min + 1;
                        else
                            n_it.min := 0;
                            -- always counted in 24-h internally
                            if n_it.hour < 23 then
                                n_it.hour := n_it.hour + 1;
                            else
                                n_it.hour := 0;
                                day_carry := true;
                            end if;
                        end if;
                    end if;
                    if day_carry then
                        if n_it.dow = 6 then
                            n_it.dow := 0;
                        else
                            n_it.dow := n_it.dow + 1;
                        end if;
                        m_days := 31;
                        case n_it.mon is
                            when 4 | 6 | 9 | 11 => m_days := 30;
                            when 2 =>
                                m_days := 28;
                                if (n_it.year mod 4 = 0 and
                                    n_it.year mod 100 /= 0) or
                                   (n_it.year mod 400 = 0) then
                                    m_days := 29;
                                end if;
                            when others => null;
                        end case;
                        if n_it.date < m_days then
                            n_it.date := n_it.date + 1;
                        else
                            n_it.date := 1;
                            if n_it.mon < 12 then
                                n_it.mon := n_it.mon + 1;
                            else
                                n_it.mon := 1;
                                n_it.year := (n_it.year + 1) mod 100;
                            end if;
                        end if;
                    end if;
                end if;

                ------------------------------------------------------------
                -- (b) update transfer: user copy <- internal copy, UF set,
                --     alarm compared at this instant
                ------------------------------------------------------------
                if xfer_ev = '1' then
                    if b_reg(B_SET) = '0' then
                        n_ut := n_it;
                    end if;
                    n_uf := '1';

                    es := enc_sec(n_it.sec, bcd_m);
                    em := enc_sec(n_it.min, bcd_m);
                    eh := enc_hour(n_it.hour, bcd_m, h24_m);
                    if ((alr_s(7) = '1' and alr_s(6) = '1') or es = alr_s)
                       and ((alr_m(7) = '1' and alr_m(6) = '1') or em = alr_m)
                       and ((alr_h(7) = '1' and alr_h(6) = '1') or eh = alr_h) then
                        n_af := '1';
                    end if;
                end if;

                ------------------------------------------------------------
                -- (c) PF flag on the selected periodic tap
                ------------------------------------------------------------
                if pf_ev = '1' then
                    n_pf := '1';
                end if;

                ------------------------------------------------------------
                -- (d) IRQF latches while any enabled flag is set
                ------------------------------------------------------------
                if (c_pf = '1' and b_reg(B_PIE) = '1') or
                   (c_af = '1' and b_reg(B_AIE) = '1') or
                   (c_uf = '1' and b_reg(B_UIE) = '1') then
                    n_irqf := '1';
                end if;

                ------------------------------------------------------------
                -- (e) host sync (load-time pushes are applied in the reset
                --     branch; this handles the periodic 60 s refreshes)
                ------------------------------------------------------------
                if sync_req /= sync_ack then
                    sync_ack <= sync_req;
                    -- guest software has written the time/calendar: the
                    -- periodic host refreshes must not override it
                    if guest_owned = '0' and host_valid(host_raw) then
                        host_decode(host_raw, ht);
                        if synced = '0' then
                            n_b(B_2412) := '1';
                            n_b(B_DM)   := '0';
                            -- start the oscillator chain (DV = 010)
                            n_a(6) := '0';
                            n_a(5) := '1';
                            n_a(4) := '0';
                        end if;
                        if n_it /= ht then
                            n_it := ht;
                            if b_reg(B_SET) = '0' then
                                n_ut := ht;
                            end if;
                        end if;
                        synced      <= '1';
                        guest_owned <= '0';
                    end if;
                end if;

                ------------------------------------------------------------
                -- (f) CPU bus access
                ------------------------------------------------------------
                if req = '1' then
                    if wrt = '0' then
                        -- Register C read clears all flags (the read mux
                        -- still returns the pre-clear values this cycle)
                        if adr = "0001100" then
                            n_pf := '0'; n_af := '0';
                            n_uf := '0'; n_irqf := '0';
                        end if;
                    else
                        wr_reg  := (adr(6) = '0' and adr(5) = '0'
                                    and adr(4) = '0');
                        wr_time := wr_reg and (adr(3) = '0');
                        if wr_time then
                            guest_owned <= '1';
                        end if;
                        if wr_reg then
                            case adr(6 downto 0) is
                                when "0000000" =>  -- seconds
                                    val := dec_byte(dbo, bcd_m);
                                    if val <= 59 then
                                        n_it.sec := val;
                                        n_ut.sec := val;
                                    end if;
                                when "0000001" =>  -- alarm seconds
                                    n_as := dbo;
                                when "0000010" =>  -- minutes
                                    val := dec_byte(dbo, bcd_m);
                                    if val <= 59 then
                                        n_it.min := val;
                                        n_ut.min := val;
                                    end if;
                                when "0000011" =>  -- alarm minutes
                                    n_am := dbo;
                                when "0000100" =>  -- hours
                                    if h24_m then
                                        val := dec_byte(dbo, bcd_m);
                                        if val <= 23 then
                                            n_it.hour := val;
                                            n_ut.hour := val;
                                        end if;
                                    else
                                        if bcd_m then
                                            -- {PM, tens, 00, units}; 12 = 0x12
                                            val := bc2b(dbo(3 downto 0));
                                            if dbo(6) = '1' then
                                                val := val + 10;
                                            end if;
                                        else
                                            -- {PM, 000, 1-12}
                                            val := to_integer(unsigned(dbo(3 downto 0)));
                                        end if;
                                        if val <= 12 then
                                            -- {PM, hour 1-12} -> 24-h storage
                                            n_it.hour := val mod 12;
                                            if dbo(7) = '1' then
                                                n_it.hour := n_it.hour + 12;
                                            end if;
                                            n_ut.hour := n_it.hour;
                                        end if;
                                    end if;
                                when "0000101" =>  -- alarm hours
                                    n_ah := dbo;
                                when "0000110" =>  -- day of week (1-7)
                                    val := dec_byte(dbo, bcd_m);
                                    if val >= 1 and val <= 7 then
                                        n_it.dow := val - 1;
                                        n_ut.dow := val - 1;
                                    end if;
                                when "0000111" =>  -- date
                                    val := dec_byte(dbo, bcd_m);
                                    if val >= 1 and val <= 31 then
                                        n_it.date := val;
                                        n_ut.date := val;
                                    end if;
                                when "0001000" =>  -- month
                                    val := dec_byte(dbo, bcd_m);
                                    if val >= 1 and val <= 12 then
                                        n_it.mon := val;
                                        n_ut.mon := val;
                                    end if;
                                when "0001001" =>  -- year
                                    val := dec_byte(dbo, bcd_m);
                                    if val <= 99 then
                                        n_it.year := val;
                                        n_ut.year := val;
                                    end if;
                                when "0001010" =>  -- Register A
                                    n_a := dbo;
                                when "0001011" =>  -- Register B
                                    n_b := dbo;
                                when others =>
                                    null;  -- 0x0C/0x0D are read-only
                            end case;
                        end if;
                    end if;
                end if;

                ------------------------------------------------------------
                -- commit
                ------------------------------------------------------------
                it <= n_it; ut <= n_ut;
                alr_s <= n_as; alr_m <= n_am; alr_h <= n_ah;
                a_reg <= n_a; b_reg <= n_b;
                c_pf <= n_pf; c_af <= n_af; c_uf <= n_uf; c_irqf <= n_irqf;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- RAM 0x10-0x7F
    ------------------------------------------------------------------------
    process (clk_sys)
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                ram <= (others => (others => '0'));
            elsif req = '1' and wrt = '1' and
                  not (adr(6) = '0' and adr(5) = '0' and adr(4) = '0') then
                ram(to_integer(unsigned(adr)) - 16) <= dbo;
            end if;
        end if;
    end process;

    -- RAM 0x10-0x7F (the register block is the lower 16 bytes)
    ram_idx <= (to_integer(unsigned(adr)) - 16)
               when not (adr(6) = '0' and adr(5) = '0' and adr(4) = '0')
               else 0;
    ram_dq  <= ram(ram_idx);

    ------------------------------------------------------------------------
    -- read mux
    ------------------------------------------------------------------------
    process (adr, req, wrt, b_reg, ut, alr_s, alr_m, alr_h, a_reg,
             c_irqf, c_pf, c_af, c_uf, ram_dq, pof_in, uip)
        variable bcd_m, h24_m : boolean;
        variable v : std_logic_vector(7 downto 0);
    begin
        v := (others => '1');
        bcd_m := (b_reg(B_DM) = '0');
        h24_m := (b_reg(B_2412) = '1');
        if req = '1' and wrt = '0' then
            case adr(6 downto 0) is
                when "0000000" =>  v := enc_sec(ut.sec, bcd_m);      -- seconds
                when "0000001" =>  v := alr_s;                       -- alarm sec
                when "0000010" =>  v := enc_sec(ut.min, bcd_m);      -- minutes
                when "0000011" =>  v := alr_m;                       -- alarm min
                when "0000100" =>  v := enc_hour(ut.hour, bcd_m, h24_m);
                when "0000101" =>  v := alr_h;                       -- alarm hr
                when "0000110" =>  v := std_logic_vector(to_unsigned(ut.dow + 1, 8));
                when "0000111" =>  v := enc_sec(ut.date, bcd_m);     -- date
                when "0001000" =>  v := enc_sec(ut.mon, bcd_m);      -- month
                when "0001001" =>  v := enc_sec(ut.year, bcd_m);     -- year
                when "0001010" =>  v := uip & a_reg(6 downto 0);
                when "0001011" =>  v := b_reg;
                when "0001100" =>  v := c_irqf & c_pf & c_af & c_uf & "0000";
                when "0001101" =>  v := pof_in & "0000000";
                when others =>
                    if not (adr(6) = '0' and adr(5) = '0' and adr(4) = '0') then
                        v := ram_dq;   -- RAM 0x10-0x7F
                    end if;            -- 0x0E/0x0F: v stays 0xFF
            end case;
        end if;
        dbi <= v;
    end process;

    ------------------------------------------------------------------------
    -- IRQ / SQW outputs
    ------------------------------------------------------------------------
    irq <= '0' when c_irqf = '1' else 'Z';
    sqw <= '0';

end architecture rtl;

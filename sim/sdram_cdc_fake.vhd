-- ============================================================================
-- sdram_cdc_fake.vhd - SIMULATION-ONLY model of the exact CDC mechanism
-- under suspicion: MultiComp.sv's clk_sys<->clk_ram request/done
-- synchronizer (MultiComp.sv:260-320), driving a small behavioral stand-in
-- for the real sdram_32r8w controller's CPU-port handshake timing
-- (Components/SDRAM/sdram2.sv), instead of the real (gate-level,
-- altddio_out-based) SDRAM controller, which isn't needed since this
-- testbench targets the CDC/FSM race, not the SDRAM array's own data
-- integrity (already proven correct by testing/sdramtest.asm on real
-- hardware).
--
-- The synchronizer logic below (req_sync/req_seen/ram_req/ram_rnw/
-- ram_addr/ram_din/ram_byte/ram_done, done_sync/done_seen) is a
-- byte-for-byte translation of MultiComp.sv:266-320 -- KEEP IN SYNC with
-- that file if it is ever changed; this is not a sync-checked copy (unlike
-- the sim/*_sim.vhd files) because it is Verilog-to-VHDL, not a
-- language-identical copy, so no automated diff check is possible. Re-read
-- MultiComp.sv:260-320 by hand after any change there and mirror it here.
--
-- Fake controller timing (see the research behind this testbench): real
-- sdram_32r8w samples req in STATE_IDLE, asserts ack ~3 clk_ram cycles
-- later (held while req stays high), and for READS pulses ready/dout a
-- further ~4 cycles after that (~7 cycles total); for WRITES, ready pulses
-- in the same cycle as ack (~3 cycles total). Modelled with a simple
-- counter below.
--
-- Fake memory content: a 64 KB array indexed by byte address bits 15:0
-- (aliased every 64 KB), initialised to (byte address) mod 256 -- an
-- address-derived ramp, matching the pattern testing/backtoback.asm
-- already uses, so mismatches (a captured byte that does NOT equal the
-- byte address requested, mod 256) are trivially recognisable as
-- "captured a stale/wrong transaction's data". Writes are stored, so code
-- can also be copied into and executed from the fake SDRAM
-- (sim/tb_sdram_perf.vhd); tb_inir_race only reads, so it still sees the
-- ramp.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_cdc_fake is
    port(
        clk_sys       : in  std_logic;
        clk_ram       : in  std_logic;

        -- clk_sys-domain interface (matches MicrocomputerZ80CPM's
        -- sdram_addr/din/we/rd/dout/ready ports exactly)
        sdram_we_mux  : in  std_logic;
        sdram_rd_mux  : in  std_logic;
        sdram_addr_mux: in  std_logic_vector(26 downto 0);
        sdram_din_mux : in  std_logic_vector(7 downto 0);
        sdram_ready_mux : out std_logic;
        sdram_dout_mux  : out std_logic_vector(7 downto 0)
    );
    -- (clk_ram is supplied by the testbench; the real core runs it at
    -- 96.667 MHz with SDRAM_CLK_100 defined in MultiComp.sv.)
end entity sdram_cdc_fake;

architecture sim of sdram_cdc_fake is

    -- ---- clk_ram domain signals (mirrors MultiComp.sv:261-282) ----
    signal req_sync   : std_logic_vector(1 downto 0) := "00";
    signal req_seen   : std_logic := '0';
    signal cpu_req_level : std_logic;

    signal ram_req    : std_logic := '0';
    signal ram_rnw    : std_logic := '1';
    signal ram_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal ram_done   : std_logic := '0';

    signal ram_addr   : std_logic_vector(26 downto 0) := (others => '0');
    signal ram_din    : std_logic_vector(7 downto 0)  := (others => '0');

    -- ---- fake controller state (clk_ram domain) ----
    signal ctrl_busy    : std_logic := '0';
    signal ctrl_is_read : std_logic := '0';
    signal ctrl_cnt     : integer range 0 to 15 := 0;
    signal sdram_cpu_ack   : std_logic := '0';
    signal sdram_cpu_ready : std_logic := '0';
    signal sdram_dout16    : std_logic_vector(15 downto 0) := (others => '0');

    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    function ramp return mem_t is
        variable m : mem_t;
    begin
        for i in m'range loop
            m(i) := std_logic_vector(to_unsigned(i mod 256, 8));
        end loop;
        return m;
    end function;

    -- ---- back into clk_sys (mirrors MultiComp.sv:311-320) ----
    signal done_sync : std_logic_vector(1 downto 0) := "00";
    signal done_seen : std_logic := '0';

    constant ACK_DELAY   : integer := 3;  -- cycles from req-seen to ack
    constant READ_DELAY  : integer := 7;  -- cycles from req-seen to ready (read)
    constant WRITE_DELAY : integer := 3;  -- cycles from req-seen to ready (write)

begin

    cpu_req_level <= sdram_we_mux or sdram_rd_mux;

    -- ================= clk_ram domain =================
    process(clk_ram)
    begin
        if rising_edge(clk_ram) then
            req_sync <= req_sync(0) & cpu_req_level;
            req_seen <= req_sync(1);

            if (req_sync(1) = '1') and (req_seen = '0') then
                ram_req  <= '1';
                ram_rnw  <= not sdram_we_mux;
                ram_addr <= sdram_addr_mux;
                ram_din  <= sdram_din_mux;
                -- Uncomment for per-transaction tracing:
                -- report "CDC: new request latched addr=" & to_hstring(sdram_addr_mux) & " rnw=" & std_logic'image(not sdram_we_mux);
            elsif sdram_cpu_ack = '1' then
                ram_req <= '0';
            end if;

            if sdram_cpu_ready = '1' then
                if ram_addr(0) = '1' then
                    ram_byte <= sdram_dout16(15 downto 8);
                else
                    ram_byte <= sdram_dout16(7 downto 0);
                end if;
                ram_done <= not ram_done;
                -- report "CDC: ready seen ram_addr=" & to_hstring(ram_addr) & " dout16=" & to_hstring(sdram_dout16);
            end if;
        end if;
    end process;

    -- ---- fake sdram_32r8w CPU-port handshake (clk_ram domain) ----
    process(clk_ram)
        variable mem : mem_t := ramp;
        variable wa  : integer;
    begin
        if rising_edge(clk_ram) then
            sdram_cpu_ack   <= '0';
            sdram_cpu_ready <= '0';

            if ctrl_busy = '0' then
                if ram_req = '1' then
                    ctrl_busy    <= '1';
                    ctrl_cnt     <= 0;
                    ctrl_is_read <= ram_rnw;
                end if;
            else
                ctrl_cnt <= ctrl_cnt + 1;

                if ctrl_cnt = ACK_DELAY - 1 then
                    sdram_cpu_ack <= '1';
                    if ctrl_is_read = '0' then
                        sdram_cpu_ready <= '1';  -- write completes with ack
                        mem(to_integer(unsigned(ram_addr(15 downto 0)))) := ram_din;
                    end if;
                end if;

                if ctrl_is_read = '1' and ctrl_cnt = READ_DELAY - 1 then
                    sdram_cpu_ready <= '1';
                    wa := to_integer(unsigned(ram_addr(15 downto 1))) * 2;
                    sdram_dout16 <= mem(wa + 1) & mem(wa);
                end if;

                -- Return to idle once the transaction's total delay has
                -- elapsed (read: READ_DELAY cycles; write: WRITE_DELAY).
                if (ctrl_is_read = '1' and ctrl_cnt = READ_DELAY - 1) or
                   (ctrl_is_read = '0' and ctrl_cnt = WRITE_DELAY - 1) then
                    ctrl_busy <= '0';
                end if;
            end if;
        end if;
    end process;

    -- ================= back into clk_sys =================
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            done_sync <= done_sync(0) & ram_done;
            done_seen <= done_sync(1);
        end if;
    end process;

    sdram_ready_mux <= done_sync(1) xor done_seen;
    sdram_dout_mux  <= ram_byte;

end architecture sim;

-- ssp_mem_client.vhd -- parked PHYSICAL memory client (M3, R40; D-15-P, SSP_DESIGN 9.2).
--
-- Lets the SSP monitor examine/deposit one byte at a 28-bit PHYSICAL address
-- (page << 14 | offset) while the Z80 is parked, without going through the Z80
-- bus mux or the MMU: it borrows the CPM core's SDRAM client port (sdram_addr/
-- din/we/rd out, sdram_dout/ready in) for the duration of one transaction.
-- SDRAM window only (owner ruling R35-rev): phys[27]=1 (page >= 8192, the block
-- RAM page) is rejected with no wire activity.  z80_bus_mux is not involved
-- (two masters, T80 + cycle-faithful engine, stay exactly as proven).
--
-- Seam to the bridge (clk domain = clk_sys), a request LEVEL:
--   ph_req   raised with ph_we/ph_addr/ph_wdata stable; held until ph_done is
--            seen; dropped no later than 1 clk after it.  A request is only
--            admitted after ph_req has been seen LOW since the last one, so a
--            level that is simply left high never replays an operation.
--   ph_done  1-clk pulse: the operation finished (or was rejected).
--   ph_err   1-clk pulse, same clk as ph_done: rejected or failed
--            (not parked, window, admission timeout, op timeout, lost park).
--   ph_rdata read byte, captured on the SDRAM completion pulse; valid with
--            ph_done (and held after) when ph_err is low.
--
-- Admission needs: parked (the Z80 owns no bus and cannot start an access) and
-- prim_idle (the CPM primary SDRAM FSM is in S_IDLE: a posted write issued by
-- the last instruction before the grant may still be in flight, so a busy
-- primary FSM is WAITED for, up to ADMIT_TO clocks, then ph_err).  Not parked
-- is an immediate error: while the Z80 runs there is zero bus activity from
-- this block, ever (the R-27 headline; the borrow mux never selects us).
--
-- Borrow protocol (mirrors the primary client, MicrocomputerZ80CPM SDRAM FSM):
-- the request level (c_we/c_rd) rises with c_addr/c_din in the same clk and is
-- held until c_ready (stall-tolerant: refresh); then it falls and stays low for
-- GAP clk so the request-level synchroniser in MrZ80.sv cannot merge two
-- requests.  `borrow` (the CPM output-mux select) rises with the request and
-- falls only after the gap, so it toggles only while both sides' levels are 0.
--
-- Failure modes, all ending in done+err and a clean return to IDLE:
--   * c_ready never comes (OP_TO clk): the level is dropped.  A very late
--     completion pulse after that is ignored (nothing is waiting); it could
--     only be mistaken for the next op's if it landed inside that op's wait --
--     accepted for a controller that is already broken.
--   * parked drops mid-op (sovereignty loss): the in-flight transaction cannot
--     be recalled, so it is allowed to finish, then reported as an error.
--   * rst_n: everything drops at once; the level falls, no ph_done follows.
--     (System reset also resets the controller side, so no stale completion.)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ssp_mem_client is
    generic (
        ADMIT_TO : natural := 4095;        -- clk waiting for the primary FSM to idle
        OP_TO    : natural := 1000000;     -- clk waiting for c_ready (20 ms)
        GAP      : natural := 3            -- request-low dead time (clk)
    );
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -- bridge seam
        ph_req    : in  std_logic;
        ph_we     : in  std_logic;
        ph_addr   : in  std_logic_vector(27 downto 0);
        ph_wdata  : in  std_logic_vector(7 downto 0);
        ph_done   : out std_logic;
        ph_err    : out std_logic;
        ph_rdata  : out std_logic_vector(7 downto 0);

        -- gates from the CPM fabric
        parked    : in  std_logic;         -- BusAck confirmed and BUSRQ still asserted
        prim_idle : in  std_logic;         -- primary SDRAM FSM in S_IDLE

        -- borrowed SDRAM client port
        c_addr    : out std_logic_vector(26 downto 0);
        c_din     : out std_logic_vector(7 downto 0);
        c_we      : out std_logic;
        c_rd      : out std_logic;
        c_dout    : in  std_logic_vector(7 downto 0);
        c_ready   : in  std_logic;
        borrow    : out std_logic          -- CPM output-mux select (1 = this block)
    );
end ssp_mem_client;

architecture rtl of ssp_mem_client is

    type st_t is (ST_IDLE, ST_WAIT, ST_GAP);
    signal st        : st_t := ST_IDLE;
    signal armed     : std_logic := '0';          -- ph_req seen low since the last op
    signal we_r      : std_logic := '0';
    signal cnt       : natural range 0 to 2**21 - 1 := 0;
    signal lost      : std_logic := '0';          -- parked dropped mid-op
    signal addr_r    : std_logic_vector(26 downto 0) := (others => '0');
    signal din_r     : std_logic_vector(7 downto 0)  := (others => '0');
    signal we_l      : std_logic := '0';
    signal rd_l      : std_logic := '0';
    signal rdata_r   : std_logic_vector(7 downto 0)  := (others => '0');
    signal borrow_r  : std_logic := '0';
    signal done_r    : std_logic := '0';
    signal err_r     : std_logic := '0';

begin

    c_addr   <= addr_r;
    c_din    <= din_r;
    c_we     <= we_l;
    c_rd     <= rd_l;
    borrow   <= borrow_r;
    ph_done  <= done_r;
    ph_err   <= err_r;
    ph_rdata <= rdata_r;

    process (clk)
    begin
        if rising_edge(clk) then
            done_r <= '0';
            err_r  <= '0';
            if rst_n = '0' then
                st <= ST_IDLE;  armed <= '0';  cnt <= 0;  lost <= '0';
                we_l <= '0';  rd_l <= '0';  borrow_r <= '0';
            else
                case st is
                    when ST_IDLE =>
                        we_l <= '0';  rd_l <= '0';  borrow_r <= '0';
                        if ph_req = '0' then
                            armed <= '1';
                            cnt   <= 0;
                        elsif armed = '1' then
                            if parked = '0' or ph_addr(27) = '1' then
                                done_r <= '1';  err_r <= '1';  armed <= '0';
                            elsif prim_idle = '1' then
                                addr_r   <= ph_addr(26 downto 0);
                                din_r    <= ph_wdata;
                                we_r     <= ph_we;
                                we_l     <= ph_we;
                                rd_l     <= not ph_we;
                                borrow_r <= '1';
                                armed    <= '0';
                                lost     <= '0';
                                cnt      <= 0;
                                st       <= ST_WAIT;
                            elsif cnt >= ADMIT_TO then
                                done_r <= '1';  err_r <= '1';  armed <= '0';
                            else
                                cnt <= cnt + 1;
                            end if;
                        end if;

                    when ST_WAIT =>
                        if parked = '0' then
                            lost <= '1';
                        end if;
                        if c_ready = '1' then
                            we_l <= '0';  rd_l <= '0';
                            if we_r = '0' then
                                rdata_r <= c_dout;
                            end if;
                            done_r <= '1';
                            if lost = '1' or parked = '0' then
                                err_r <= '1';
                            end if;
                            cnt <= 0;
                            st  <= ST_GAP;
                        elsif cnt >= OP_TO then
                            we_l <= '0';  rd_l <= '0';
                            done_r <= '1';  err_r <= '1';
                            cnt <= 0;
                            st  <= ST_GAP;
                        else
                            cnt <= cnt + 1;
                        end if;

                    when ST_GAP =>
                        we_l <= '0';  rd_l <= '0';
                        if ph_req = '0' then
                            armed <= '1';
                        end if;
                        if cnt >= GAP - 1 then
                            borrow_r <= '0';
                            st       <= ST_IDLE;
                        else
                            cnt <= cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

end rtl;

-- ssp_tramp.vhd -- Z80 CPU reset vent + reset-vector trampoline injector
-- (D-02, SSP_DESIGN 7.4; moved into P1a by D-39, R27).  Z80-side logic, so
-- VHDL (D-33) and verified against the real T80 in sim/tb_tramp.vhd.
-- Lives at the CPM boundary beside z80_bus_mux.
--
-- "G aaaa" = reset the Z80 CPU, make it execute JP aaaa as its first
-- instruction, let it run.  A Z80 starts at $0000 after reset, and a JP is
-- three bus reads (opcode, lo, hi) at $0000, $0001, $0002; this module
-- substitutes C3, lo(aaaa), hi(aaaa) on the CPU's data input for exactly
-- those three reads and then steps aside.  No T80 datapath is touched
-- (D-02: registers stay read-only in v1; context is lost on reset).
--
-- Two functions:
--
--  1. RESET VENT.  z_reset_n (bridge CTRL.Z_RST_N, low = vent) is turned
--     into the T80's reset: t80_rst_n = sys_rst_n AND vent_q.  Once z_reset_n
--     is released, the reset is held for VENT_CEN more cpu_cen pulses, so a
--     short FW pulse is still a clean reset (D-30 RESET_VENT).  Only the T80
--     is reset -- peripherals and the MMU hang off the system reset, so the
--     Z80's machine state persists (7.3: "monitor state persists").
--     vent_q is a register and is constant 1 unless the bridge requests a
--     vent, so with the SSP idle t80_rst_n is exactly sys_rst_n.
--
--  2. INJECTOR.  Armed (st = ARMED) only if `arm` is high while the T80 is
--     in reset (rst_n_i low).  A read of $0000 with no reset in progress is
--     NEVER intercepted, so a stale arm bit cannot corrupt normal operation.
--     After reset release, a read cycle (MREQ_n and RD_n low) whose address
--     equals the next expected index {0,1,2} gets the injected byte; the
--     cycle's end (strobes release) advances the index.  After the third
--     byte `done` pulses for one clk (the bridge then clears CTRL.TRAMP_EN)
--     and the module returns to IDLE.  Refresh cycles (MREQ low, RD high) and
--     wait states are transparent: the override is combinational on the
--     strobes, so it is present whenever T80 samples DI (end of T2, Wait_n
--     high).  If reset is re-asserted mid-window the sequence restarts.
--
-- Ordering rule for the FW sequence (see SSP_DESIGN 7.4): drop the park
-- request (CTRL.Z_BUSRQ_N) no later than the reset release.  A T80 that
-- still sees BUSRQ when it comes out of reset will complete the injected JP
-- and then park AT the target (freeze grant needs an instruction boundary),
-- which is a deliberate "set PC and stay parked" mode.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ssp_tramp is
    generic (
        VENT_CEN : natural := 8             -- min reset hold after release
    );
    port (
        clk        : in  std_logic;         -- clk_sys (50 MHz)
        cen        : in  std_logic;         -- cpu_cen, UNGATED (vent timing)

        -- reset
        sys_rst_n  : in  std_logic;         -- existing reset_n_internal
        z_reset_n  : in  std_logic;         -- bridge: low = vent the Z80 CPU
        t80_rst_n  : out std_logic;         -- to T80s RESET_n

        -- bridge handshake (clk domain)
        arm        : in  std_logic;         -- CTRL.TRAMP_EN (effective)
        target     : in  std_logic_vector(15 downto 0);
        done       : out std_logic;         -- 1-clk pulse: 3 bytes delivered
        active     : out std_logic;         -- armed / injecting

        -- Z80 bus as seen by the CPU (after z80_bus_mux)
        addr       : in  std_logic_vector(15 downto 0);
        mreq_n     : in  std_logic;
        rd_n       : in  std_logic;

        -- CPU data input: cpuDataIn in, override out (to T80s DI)
        din_in     : in  std_logic_vector(7 downto 0);
        din_out    : out std_logic_vector(7 downto 0)
    );
end entity ssp_tramp;

architecture rtl of ssp_tramp is

    signal vent_q   : std_logic := '1';
    signal vent_cnt : natural range 0 to VENT_CEN := 0;

    type st_t is (S_IDLE, S_ARMED);
    signal st       : st_t := S_IDLE;
    signal idx      : unsigned(1 downto 0) := (others => '0');
    signal hit      : std_logic := '0';     -- an injected read is in flight
    signal act_q    : std_logic := '0';
    signal done_r   : std_logic := '0';

    signal rst_n_i  : std_logic;
    signal act      : std_logic;
    signal match    : std_logic;
    signal sel      : std_logic;
    signal inj      : std_logic_vector(7 downto 0);

begin

    -- ---------------------------------------------------------- vent ------
    rst_n_i   <= sys_rst_n and vent_q;
    t80_rst_n <= rst_n_i;

    proc_vent : process (clk)
    begin
        if rising_edge(clk) then
            if z_reset_n = '0' then
                vent_cnt <= VENT_CEN;
                vent_q   <= '0';
            elsif vent_cnt /= 0 then
                vent_q <= '0';
                if cen = '1' then
                    vent_cnt <= vent_cnt - 1;
                end if;
            else
                vent_q <= '1';
            end if;
        end if;
    end process proc_vent;

    -- ------------------------------------------------------- injector -----
    act   <= '1' when (mreq_n = '0' and rd_n = '0') else '0';
    match <= '1' when (unsigned(addr(15 downto 2)) = 0 and
                       unsigned(addr(1 downto 0)) = idx) else '0';
    sel   <= '1' when (st = S_ARMED and rst_n_i = '1' and
                       act = '1' and match = '1') else '0';

    inj <= x"C3"                   when idx = "00" else
           target(7 downto 0)      when idx = "01" else
           target(15 downto 8);

    din_out <= inj when sel = '1' else din_in;

    done   <= done_r;
    active <= '1' when st = S_ARMED else '0';

    proc_inj : process (clk)
    begin
        if rising_edge(clk) then
            done_r <= '0';
            act_q  <= act;
            if rst_n_i = '0' then
                -- T80 in reset: (re)start the window; arm is sampled here
                -- only, so arming outside a reset never intercepts a read.
                idx <= (others => '0');
                hit <= '0';
                if arm = '1' then
                    st <= S_ARMED;
                else
                    st <= S_IDLE;
                end if;
            elsif st = S_ARMED then
                if sel = '1' then
                    hit <= '1';
                end if;
                if act_q = '1' and act = '0' and hit = '1' then
                    hit <= '0';                -- injected read has ended
                    if idx = "10" then
                        st     <= S_IDLE;
                        done_r <= '1';
                    else
                        idx <= idx + 1;
                    end if;
                end if;
            end if;
        end if;
    end process proc_inj;

end architecture rtl;

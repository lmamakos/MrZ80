-- z80_bus_mux.vhd -- single Z80 bus master mux at the T80 output boundary
-- (D-26, R15; D-33 VHDL side -- lives at the CPM core, beside the T80).
--
-- One registered select, `sel_eng`.  It flips to the engine ONLY with BusAck
-- confirmed (P-A: T80 has released the bus) and back to the T80 only when
-- the engine has finished its cycle (eng_own low) and BUSRQ is released.
-- This is the single place that decides who drives the guest nets --
-- address, data-out, MREQ/IORQ/RD/WR, MRD_T1 (the SDRAM speculative-read
-- trigger), M1_n (the capture chain) -- so every peripheral, the MMU and
-- the SDRAM client FSM see "a Z80" in both cases.  cpu_wait_n is sensed by
-- whichever master is live (the parked T80 no longer consumes it; the
-- engine samples it, D-26).
--
-- R25/M1 (latch + frozen-strobe fixes):
--   * sel_eng is a proper SYNCHRONOUS process (was an incomplete
--     combinational process => inferred latch).
--   * While the T80 is parked (busack_n = 0) and the engine is not
--     selected, the frozen T80 strobe state must NOT leak: a halt
--     mid-MREF (e.g. refresh MREQ_n low in M1 T3) would otherwise sit on
--     the guest nets indefinitely.  All five strobes are idle-gated high
--     in exactly that window.  The guest fabric already tolerates the
--     STOP-style idle gap (panel STOP exercises the same shape).
--   * Release semantics: busrq_n high (bridge released) or engine cycle
--     complete; the T80 resumes at its frozen state with strobes restored.
--
-- R-42 golden-compare at integration level (tb_integ_mux, P1a GHDL lane).

library IEEE;
use IEEE.std_logic_1164.all;

entity z80_bus_mux is
    port(
        clk           : in  std_logic;          -- clk_sys (select domain)
        rst_n         : in  std_logic;

        -- master A: T80 outputs (freeze, do not tri-state, while held --
        -- G-2: this is precisely why explicit muxing is required)
        t80_addr      : in  std_logic_vector(15 downto 0);
        t80_dout      : in  std_logic_vector(7  downto 0);
        t80_mreq_n    : in  std_logic;
        t80_iorq_n    : in  std_logic;
        t80_rd_n      : in  std_logic;
        t80_wr_n      : in  std_logic;
        t80_m1_n      : in  std_logic;
        t80_mrd_t1    : in  std_logic;
        t80_busack_n  : in  std_logic;
        busrq_n       : in  std_logic;         -- to T80 (bridge park/hold)

        -- master B: SSP engine (cycle-faithful Z80, D-26)
        eng_own       : in  std_logic;
        eng_addr      : in  std_logic_vector(15 downto 0);
        eng_dout      : in  std_logic_vector(7  downto 0);
        eng_mreq_n    : in  std_logic;
        eng_iorq_n    : in  std_logic;
        eng_rd_n      : in  std_logic;
        eng_wr_n      : in  std_logic;
        eng_m1_n      : in  std_logic;
        eng_mrd_t1    : in  std_logic;

        -- guest nets (drive the existing CPM fabric unchanged)
        cpu_addr      : out std_logic_vector(15 downto 0);
        cpu_dout      : out std_logic_vector(7  downto 0);
        cpu_mreq_n    : out std_logic;
        cpu_iorq_n    : out std_logic;
        cpu_rd_n      : out std_logic;
        cpu_wr_n      : out std_logic;
        cpu_m1_n      : out std_logic;
        cpu_mrd_t1    : out std_logic
    );
end entity z80_bus_mux;

architecture rtl of z80_bus_mux is

    signal sel_eng : std_logic := '0';

begin

    -- Select discipline (P-A, R25): synchronous; engage only on confirmed
    -- BusAck with the engine in-cycle; release when the engine's cycle is
    -- done or the park/hold is let go.
    proc_sel: process (clk, rst_n)
    begin
        if rst_n = '0' then
            sel_eng <= '0';
        elsif rising_edge(clk) then
            if t80_busack_n = '0' and eng_own = '1' and busrq_n = '0' then
                sel_eng <= '1';
            elsif eng_own = '0' or busrq_n = '1' then
                sel_eng <= '0';
            end if;
        end if;
    end process proc_sel;

    cpu_addr <= eng_addr when sel_eng = '1' else t80_addr;
    cpu_dout <= eng_dout when sel_eng = '1' else t80_dout;

    -- strobes: engine when selected; parked-and-idle window forces all
    -- inactive (frozen T80 state suppressed, R25/M1); else live T80.
    cpu_mreq_n <= eng_mreq_n when sel_eng = '1'
                 else '1'     when t80_busack_n = '0'
                 else t80_mreq_n;
    cpu_iorq_n <= eng_iorq_n when sel_eng = '1'
                 else '1'     when t80_busack_n = '0'
                 else t80_iorq_n;
    cpu_rd_n   <= eng_rd_n   when sel_eng = '1'
                 else '1'     when t80_busack_n = '0'
                 else t80_rd_n;
    cpu_wr_n   <= eng_wr_n   when sel_eng = '1'
                 else '1'     when t80_busack_n = '0'
                 else t80_wr_n;
    cpu_m1_n   <= eng_m1_n   when sel_eng = '1'
                 else '1'     when t80_busack_n = '0'
                 else t80_m1_n;
    cpu_mrd_t1 <= eng_mrd_t1 when sel_eng = '1' else t80_mrd_t1;

    -- back to the masters: din is shared; wait is sensed live by whoever
    -- is driving (the engine samples it in its own FSM; the T80 by its
    -- WAIT_n input).
    -- (cpu_din / cpu_wait_n pass through to the masters via CPM wiring --
    --  listed in the seam contract; top level connects both.)

end architecture rtl;

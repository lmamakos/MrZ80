-- ssp_vdu.vhd -- the SSP monitor's own video terminal (R44, D-19 "HDMI
-- console").  A second SBCTextDisplayRGB instance, private to the SSP: the
-- monitor's console bytes are written to it and its keyboard bytes read back
-- through a byte-stream port, so the Z80's terminal (screen contents, cursor,
-- ANSI parser state, unread keys) is never touched.  MrZ80.sv shows this
-- instance's RGB instead of the Z80's while `show` is high; both instances run
-- the same video timing from the same clock (their counters have no reset and
-- start together at configuration), so only the colour signals are switched.
-- Both decode every PS/2 byte (modifier state stays consistent); only the
-- shown one keeps keys (kbEnable).
--
-- Byte port (clk_sys):
--   tx_valid/tx_data/tx_ready  monitor output; a byte moves on a clock where
--                              tx_valid and tx_ready are both high
--   rx_valid/rx_data/rx_take   keyboard input; rx_take (one clock, only while
--                              rx_valid) consumes rx_data
-- The adapter drives the terminal's 6850-style register port with clean
-- one-clock strobes, data register only (the control register is never
-- written).

library ieee;
use ieee.std_logic_1164.all;

entity ssp_vdu is
    port (
        clk      : in  std_logic;
        n_reset  : in  std_logic;
        show     : in  std_logic;   -- SSP screen displayed, keys kept here
        tx_valid : in  std_logic;
        tx_data  : in  std_logic_vector(7 downto 0);
        tx_ready : out std_logic;
        rx_valid : out std_logic;
        rx_data  : out std_logic_vector(7 downto 0);
        rx_take  : in  std_logic;
        ps2Clk   : in  std_logic;
        ps2Data  : in  std_logic;
        R        : out std_logic_vector(1 downto 0);  -- as the CPM core maps
        G        : out std_logic_vector(1 downto 0);  -- videoX0 -> X(1),
        B        : out std_logic_vector(1 downto 0)   -- videoX1 -> X(0)
    );
end entity ssp_vdu;

architecture rtl of ssp_vdu is
    signal n_wr_r, n_rd_r : std_logic := '1';
    signal wdata          : std_logic_vector(7 downto 0) := (others => '0');
    signal dout           : std_logic_vector(7 downto 0);
    signal term_tx_ready  : std_logic;
    signal term_kb_avail  : std_logic;
    signal wcnt           : integer range 0 to 3 := 0;
    signal rst            : integer range 0 to 7 := 0;
    signal tx_ready_i     : std_logic;
begin
    term : entity work.SBCTextDisplayRGB
    generic map (
        DEFAULT_ATT      => "00001010",     -- bright green on black: the
        ANSI_DEFAULT_ATT => "00000010"      -- monitor's screen is recognisable
    )
    port map (
        n_reset  => n_reset,
        clk      => clk,
        n_wr     => n_wr_r,
        n_rd     => n_rd_r,
        regSel   => '1',
        dataIn   => wdata,
        dataOut  => dout,
        n_int    => open,
        n_rts    => open,
        videoR0  => R(1),
        videoR1  => R(0),
        videoG0  => G(1),
        videoG1  => G(0),
        videoB0  => B(1),
        videoB1  => B(0),
        hSync    => open,
        vSync    => open,
        hBlank   => open,
        vBlank   => open,
        cepix    => open,
        video    => open,
        sync     => open,
        ps2Clk   => ps2Clk,
        ps2Data  => ps2Data,
        FNkeys   => open,
        FNtoggledKeys => open,
        kbEnable => show,
        txReady  => term_tx_ready,
        kbAvail  => term_kb_avail
    );

    -- write: a one-clock n_wr pulse; the terminal commits at its trailing edge,
    -- so hold off for three clocks before looking at its ready again
    tx_ready_i <= '1' when wcnt = 0 and term_tx_ready = '1' else '0';
    tx_ready   <= tx_ready_i;

    -- read: wait two clocks after a key appears (the terminal registers its
    -- read data every clock), offer it, pop it with a one-clock n_rd pulse,
    -- then wait for the read pointer and the read data to move on
    rx_valid <= '1' when rst = 2 else '0';
    rx_data  <= dout;

    process (clk)
    begin
        if rising_edge(clk) then
            n_wr_r <= '1';
            if wcnt /= 0 then
                wcnt <= wcnt - 1;
            elsif tx_valid = '1' and term_tx_ready = '1' then
                wdata  <= tx_data;
                n_wr_r <= '0';
                wcnt   <= 3;
            end if;

            n_rd_r <= '1';
            case rst is
                when 0 => if term_kb_avail = '1' then rst <= 1; end if;
                when 1 => rst <= 2;
                when 2 => if rx_take = '1' then n_rd_r <= '0'; rst <= 3; end if;
                when 6 => rst <= 0;
                when others => rst <= rst + 1;
            end case;
        end if;
    end process;
end architecture rtl;

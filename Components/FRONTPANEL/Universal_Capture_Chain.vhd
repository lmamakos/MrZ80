-- =====================================================================
-- Universal_Capture_Chain
--
-- Per-signal pulse stretcher + parallel-in / serial-out (PISO) shift
-- register intended for the front-panel LED chain. Multiple instances
-- can be daisy-chained via chain_in / chain_out to form one long
-- serial stream of captured front-panel state, which the
-- FrontPanel_Subsystem then samples to drive the WS2812/SK6812 LEDs.
--
-- For each bit in combined_data the STRETCH_MASK selects between:
--   '0' = transparent  -- captured_bits(i) follows combined_data(i)
--                         immediately (e.g. address / data bus signals).
--   '1' = stretched    -- a brief one-cycle pulse on combined_data(i)
--                         loads the per-bit hold counter to HOLD_CYCLES
--                         and captured_bits(i) is forced high until the
--                         counter expires (e.g. INT/IACK pulses).
--
-- Resource efficiency: per-bit hold counters are instantiated using a
-- VHDL-2008 if-generate construct. Only the bits for which
-- STRETCH_MASK(i) = '1' allocate a counter register; transparent bits
-- have no counter logic at all. This is more reliable than depending on
-- synthesizer dead-code elimination across an array initialized with
-- (others => 0). For chains where only a handful of bits need
-- stretching, see Transparent_Capture_Chain for a variant with no
-- per-bit conditional structure at all.
--
-- Handshake:
--   * latch = '1'      Snap captured_bits into shift_reg.
--   * shift_en = '1'   Advance shift_reg one bit, importing chain_in
--                      into the low end and exporting the current
--                      MSB (bit TOTAL_WIDTH-1) as chain_out.
-- latch and shift_en are not expected to be asserted simultaneously
-- by the controller; if they are, latch takes priority.
--
-- Bit order: combined_data's MSB (bit TOTAL_WIDTH-1) is captured and
-- output FIRST, immediately after latch, followed by TOTAL_WIDTH-2,
-- TOTAL_WIDTH-3, ... down to bit 0 last -- matching
-- Transparent_Capture_Chain so the two interleave consistently in one
-- logical chain.
--
-- The STRETCH_MASK generic is declared unconstrained but an
-- elaboration-time assertion enforces that its length equals
-- TOTAL_WIDTH. Its direction does not matter: the mask is copied into a
-- (TOTAL_WIDTH-1 downto 0) constant by position, so the LEFTMOST element
-- (the first character of a literal such as b"0000_1111_...") is the mask for
-- combined_data's MSB and the rightmost is bit 0, however the caller declared
-- it. (A bit-string literal given to an unconstrained generic is ascending,
-- 0 to N-1, so indexing the generic directly would read it backwards.)
-- =====================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity Universal_Capture_Chain is
    generic (
        TOTAL_WIDTH  : integer := 64;
        HOLD_CYCLES  : integer := 2500000; -- Default ~50ms @ 50MHz
        -- Mask: '1' enables stretching for that bit index, '0' is transparent.
        -- No default value is supplied so the caller must explicitly state
        -- which bits are stretched. Must be exactly TOTAL_WIDTH bits wide,
        -- downto-direction (bit 0 is the lowest combined_data bit).
        STRETCH_MASK : std_logic_vector
    );
    port (
        clk           : in  std_logic;
        reset         : in  std_logic;
        latch         : in  std_logic;
        shift_en      : in  std_logic;
        combined_data : in  std_logic_vector(TOTAL_WIDTH-1 downto 0);
        chain_in      : in  std_logic;
        chain_out     : out std_logic
    );
end entity;

architecture rtl of Universal_Capture_Chain is
    -- STRETCH_MASK re-based to (TOTAL_WIDTH-1 downto 0), MSB first. Always
    -- index this, never the generic, so bit i of the mask is bit i of the data.
    constant MASK_N      : std_logic_vector(TOTAL_WIDTH-1 downto 0) := STRETCH_MASK;
    signal shift_reg     : std_logic_vector(TOTAL_WIDTH-1 downto 0);
    signal captured_bits : std_logic_vector(TOTAL_WIDTH-1 downto 0);

begin

    -- Elaboration-time sanity check on the mask width. If the caller
    -- supplies a STRETCH_MASK of the wrong length, fail loudly during
    -- elaboration rather than silently mis-indexing at run time.
    -- (Must live in the statement part of the architecture, not the
    -- declarative part, per VHDL LRM.)
    assert STRETCH_MASK'length = TOTAL_WIDTH
        report "Universal_Capture_Chain: STRETCH_MASK width must equal TOTAL_WIDTH"
        severity failure;

    ---------------------------------------------------------------------
    -- Per-bit capture logic, emitted by a VHDL-2008 if-generate so that
    -- only the bits with MASK_N(i) = '1' synthesize a counter.
    -- Transparent bits collapse to a single FF (or even a wire, after
    -- output-register optimization) feeding captured_bits(i).
    ---------------------------------------------------------------------
    gen_capture : for i in 0 to TOTAL_WIDTH-1 generate

        -- Stretched bit: per-bit hold counter and sticky high output
        -- until the counter expires.
        gen_stretched : if MASK_N(i) = '1' generate
            signal hold_count : integer range 0 to HOLD_CYCLES := 0;
        begin
            process(clk, reset)
            begin
                if reset = '1' then
                    hold_count       <= 0;
                    captured_bits(i) <= '0';
                elsif rising_edge(clk) then
                    if combined_data(i) = '1' then
                        -- Trigger / refresh the hold timer
                        hold_count       <= HOLD_CYCLES;
                        captured_bits(i) <= '1';
                    elsif hold_count > 0 then
                        -- Currently holding
                        hold_count       <= hold_count - 1;
                        captured_bits(i) <= '1';
                    else
                        -- Timeout reached
                        captured_bits(i) <= '0';
                    end if;
                end if;
            end process;
        end generate gen_stretched;

        -- Transparent bit: captured_bits(i) follows combined_data(i)
        -- through one register (so the timing matches the stretched
        -- path and shift_reg sees consistent data on latch).
        gen_transparent : if MASK_N(i) = '0' generate
        begin
            process(clk, reset)
            begin
                if reset = '1' then
                    captured_bits(i) <= '0';
                elsif rising_edge(clk) then
                    captured_bits(i) <= combined_data(i);
                end if;
            end process;
        end generate gen_transparent;

    end generate gen_capture;

    ---------------------------------------------------------------------
    -- Shift Register Logic. latch takes priority over shift_en in the
    -- event that both are asserted in the same cycle.
    ---------------------------------------------------------------------
    process(clk, reset)
    begin
        if reset = '1' then
            shift_reg <= (others => '0');
        elsif rising_edge(clk) then
            if latch = '1' then
                -- Snap the current state of captured_bits (raw or stretched)
                shift_reg <= captured_bits;
            elsif shift_en = '1' then
                -- Shift left: the MSB (already exported via chain_out)
                -- drops off the top, everything else moves up one
                -- position, and chain_in enters at the bottom.
                shift_reg <= shift_reg(TOTAL_WIDTH-2 downto 0) & chain_in;
            end if;
        end if;
    end process;

    chain_out <= shift_reg(TOTAL_WIDTH-1);

end architecture;

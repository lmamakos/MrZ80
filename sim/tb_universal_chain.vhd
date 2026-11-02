-- tb_universal_chain.vhd -- unit bench for Components/FRONTPANEL/
-- Universal_Capture_Chain.vhd (run with sim/run_universal_chain.sh).
--
-- Regression for the STRETCH_MASK bug: a bit-string literal given to the
-- unconstrained generic is ASCENDING (0 to N-1), so indexing the generic
-- directly read the mask backwards and stretched the wrong bits (the front-panel
-- strobe and interrupt lamps were never held).  The entity now re-bases the mask
-- to (N-1 downto 0), MSB first.  This bench checks, for an ascending literal, a
-- downto constant and the 8-bit example in Components/FRONTPANEL/README.md:
--   * a one-clock pulse on a masked bit is still captured many clocks later;
--   * the hold expires after HOLD_CYCLES;
--   * a one-clock pulse on any unmasked bit (including the mirror-image index
--     the old bug stretched) is NOT held;
--   * a level on a transparent bit is captured as is.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_universal_chain is
end entity tb_universal_chain;

architecture sim of tb_universal_chain is
    constant HOLD : integer := 300;      -- clocks (>> the ~35 clocks a snapshot takes)

    -- mask given as an ascending literal (what a caller naturally writes) ...
    constant MASK_LIT : std_logic_vector := b"0000_0000_0000_0000_1111_1111_0000_0000";
    -- ... and as a downto constant (must give the same result)
    constant MASK_DN  : std_logic_vector(31 downto 0) := x"0000_FF00";

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';
    signal latch    : std_logic := '0';
    signal shift_en : std_logic := '0';
    signal d_a, d_b : std_logic_vector(31 downto 0) := (others => '0');
    signal d_c      : std_logic_vector(7 downto 0)  := (others => '0');
    signal co_a, co_b, co_c : std_logic;
begin
    clk <= not clk after 10 ns;

    dut_a : entity work.Universal_Capture_Chain
        generic map (TOTAL_WIDTH => 32, HOLD_CYCLES => HOLD, STRETCH_MASK => MASK_LIT)
        port map (clk => clk, reset => reset, latch => latch, shift_en => shift_en,
                  combined_data => d_a, chain_in => '0', chain_out => co_a);

    dut_b : entity work.Universal_Capture_Chain
        generic map (TOTAL_WIDTH => 32, HOLD_CYCLES => HOLD, STRETCH_MASK => MASK_DN)
        port map (clk => clk, reset => reset, latch => latch, shift_en => shift_en,
                  combined_data => d_b, chain_in => '0', chain_out => co_b);

    -- README example: only bits 1 and 0 stretch
    dut_c : entity work.Universal_Capture_Chain
        generic map (TOTAL_WIDTH => 8, HOLD_CYCLES => HOLD, STRETCH_MASK => "00000011")
        port map (clk => clk, reset => reset, latch => latch, shift_en => shift_en,
                  combined_data => d_c, chain_in => '0', chain_out => co_c);

    stim : process
        variable va, vb : std_logic_vector(31 downto 0);
        variable vc     : std_logic_vector(7 downto 0);
        variable checks : natural := 0;

        procedure ck(cond : boolean; msg : string) is
        begin
            checks := checks + 1;
            assert cond report "FAIL: tb_universal_chain: " & msg severity failure;
        end procedure;

        procedure clks(n : natural) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); end loop;
        end procedure;

        -- Snapshot, then shift every chain out MSB first.
        procedure snap is
        begin
            wait until rising_edge(clk);
            latch <= '1';
            wait until rising_edge(clk);
            latch <= '0';
            wait for 1 ns;                       -- shift registers now hold the snapshot
            for n in 31 downto 0 loop
                va(n) := co_a;
                vb(n) := co_b;
                if n >= 24 then vc(n - 24) := co_c; end if;   -- 8-bit chain: first 8 shifts
                shift_en <= '1';
                wait until rising_edge(clk);
                wait for 1 ns;
            end loop;
            shift_en <= '0';
        end procedure;
    begin
        clks(5);
        reset <= '0';
        clks(3);

        -- 1. one-clock pulses on masked bits 8, 11, 15 and unmasked 0, 7, 16, 20, 23, 24
        wait until rising_edge(clk);
        d_a <= (8 | 11 | 15 | 0 | 7 | 16 | 20 | 23 | 24 => '1', others => '0');
        d_b <= (8 | 11 | 15 | 0 | 7 | 16 | 20 | 23 | 24 => '1', others => '0');
        d_c <= (1 | 0 | 2 | 7 => '1', others => '0');
        wait until rising_edge(clk);
        d_a <= (others => '0'); d_b <= (others => '0'); d_c <= (others => '0');
        clks(4);
        snap;
        for n in 0 to 31 loop
            if n = 8 or n = 11 or n = 15 then
                ck(va(n) = '1', "ascending-literal mask: masked bit " & integer'image(n) & " not held");
                ck(vb(n) = '1', "downto-constant mask: masked bit " & integer'image(n) & " not held");
            else
                ck(va(n) = '0', "ascending-literal mask: unmasked bit " & integer'image(n) & " was stretched");
                ck(vb(n) = '0', "downto-constant mask: unmasked bit " & integer'image(n) & " was stretched");
            end if;
        end loop;
        for n in 0 to 7 loop
            if n = 0 or n = 1 then
                ck(vc(n) = '1', "8-bit mask 00000011: bit " & integer'image(n) & " not held");
            else
                ck(vc(n) = '0', "8-bit mask 00000011: bit " & integer'image(n) & " was stretched");
            end if;
        end loop;

        -- 2. the hold expires
        clks(HOLD + 50);
        snap;
        ck(va = x"00000000", "ascending-literal mask: bits still lit after the hold");
        ck(vb = x"00000000", "downto-constant mask: bits still lit after the hold");
        ck(vc = x"00",       "8-bit mask: bits still lit after the hold");

        -- 3. a level on a transparent bit and a masked bit is captured as is
        wait until rising_edge(clk);
        d_a(4) <= '1'; d_a(9) <= '1'; d_b(4) <= '1'; d_b(9) <= '1'; d_c(5) <= '1'; d_c(0) <= '1';
        clks(4);
        snap;
        ck(va(4) = '1' and va(9) = '1', "ascending-literal mask: level not captured");
        ck(vb(4) = '1' and vb(9) = '1', "downto-constant mask: level not captured");
        ck(vc(5) = '1' and vc(0) = '1', "8-bit mask: level not captured");
        d_a <= (others => '0'); d_b <= (others => '0'); d_c <= (others => '0');
        clks(2);
        snap;                                     -- transparent bit 4 / 5 drops at once; 9 / 0 are held
        ck(va(4) = '0' and va(9) = '1', "ascending-literal mask: transparent bit held / stretched bit dropped");
        ck(vb(4) = '0' and vb(9) = '1', "downto-constant mask: transparent bit held / stretched bit dropped");
        ck(vc(5) = '0' and vc(0) = '1', "8-bit mask: transparent bit held / stretched bit dropped");

        report "PASS: tb_universal_chain (" & integer'image(checks) & " checks)";
        std.env.stop;
        wait;
    end process;
end architecture sim;

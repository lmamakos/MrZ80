-- tb_ixstack.vhd - self-checking GHDL testbench for the custom PUSHIX/POPIX
-- instructions (ED C5/D5/E5 and ED C1/D1/E1) in Components/Z80/T80_MCode.vhd.
--
-- A bare T80s core (Mode 0) runs sim/tb_ixstack.bin out of a flat 64 KB
-- behavioural RAM.  The payload stores what it observes into a results area
-- at 8000h and HALTs; this testbench then compares that area against the
-- table below.  It also timestamps every opcode fetch and checks the
-- M1-to-M1 spacing of the instructions in the payload's timing probe at
-- 0200h, so a change in T-state count is caught too.
--
-- Run from the project root:  sim/run_ixstack.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.T80_Pack.all;

entity tb_ixstack is
	generic (
		-- 0: no wait states (timing checks active).  N>0: pull WAIT_n low
		-- in a pseudo-random pattern (~1 in N clocks, 1-3 clocks long);
		-- T-state timing checks are skipped in this mode.
		WAITS : natural := 0
	);
end tb_ixstack;

architecture sim of tb_ixstack is

	type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);
	signal mem : mem_t := (others => x"00");

	signal clk     : std_logic := '0';
	signal reset_n : std_logic := '0';
	signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
	signal a       : std_logic_vector(15 downto 0);
	signal di, do  : std_logic_vector(7 downto 0);
	signal loaded  : boolean := false;
	signal done    : boolean := false;
	signal wait_n  : std_logic := '1';

	constant RSLT : natural := 16#8000#;

	type exp_t is record
		offs : natural;
		val  : std_logic_vector(7 downto 0);
		what : string(1 to 23);
	end record;
	type exp_arr is array (natural range <>) of exp_t;
	constant EXPECTED : exp_arr := (
		(16#00#, x"FE", "T1 IX after PUSHIX DE L"), (16#01#, x"DF", "T1 IX after PUSHIX DE H"),
		(16#02#, x"12", "T1 (IX_old-1)=D        "), (16#03#, x"34", "T1 (IX_old-2)=E        "),
		(16#04#, x"FA", "T2 IX after 2 pushes  L"), (16#05#, x"DF", "T2 IX after 2 pushes  H"),
		(16#06#, x"BC", "T2 POPIX BC           L"), (16#07#, x"9A", "T2 POPIX BC           H"),
		(16#08#, x"78", "T2 POPIX HL           L"), (16#09#, x"56", "T2 POPIX HL           H"),
		(16#0A#, x"34", "T2 POPIX DE           L"), (16#0B#, x"12", "T2 POPIX DE           H"),
		(16#0C#, x"00", "T2 IX restored        L"), (16#0D#, x"E0", "T2 IX restored        H"),
		(16#0E#, x"FF", "T3 F preserved (ones)  "), (16#0F#, x"FF", "T3 A preserved (ones)  "),
		(16#10#, x"00", "T3 F preserved (zeros) "), (16#11#, x"00", "T3 A preserved (zeros) "),
		(16#12#, x"FE", "T4 b2b push/pop BC    L"), (16#13#, x"CA", "T4 b2b push/pop BC    H"),
		(16#14#, x"00", "T4 IX                 L"), (16#15#, x"E0", "T4 IX                 H"),
		(16#16#, x"5A", "T5 EXX alt HL         L"), (16#17#, x"A5", "T5 EXX alt HL         H"),
		(16#18#, x"00", "T5 IX                 L"), (16#19#, x"E0", "T5 IX                 H"),
		(16#1A#, x"11", "T5 main DE untouched  L"), (16#1B#, x"11", "T5 main DE untouched  H"),
		(16#1C#, x"00", "T6 DE-(thread+2)=0    L"), (16#1D#, x"00", "T6 DE-(thread+2)=0    H"),
		(16#1E#, x"00", "T6 IX                 L"), (16#1F#, x"E0", "T6 IX                 H"),
		(16#20#, x"FE", "T7 IX wrap            L"), (16#21#, x"FF", "T7 IX wrap            H"),
		(16#22#, x"BE", "T7 (FFFF)=B            "), (16#23#, x"EF", "T7 (FFFE)=C            "),
		(16#24#, x"EF", "T7 POPIX HL wrap      L"), (16#25#, x"BE", "T7 POPIX HL wrap      H"),
		(16#26#, x"00", "T7 IX back to 0000    L"), (16#27#, x"00", "T7 IX back to 0000    H"),
		(16#28#, x"21", "T8 (IX+0/1) read      L"), (16#29#, x"43", "T8 (IX+0/1) read      H"),
		(16#2A#, x"56", "T8 POPIX after (IX+d) L"), (16#2B#, x"43", "T8 POPIX after (IX+d) H"),
		(16#2C#, x"0D", "T8 stock PUSH/POP     L"), (16#2D#, x"F0", "T8 stock PUSH/POP     H"),
		(16#2E#, x"77", "T8 IY untouched       L"), (16#2F#, x"77", "T8 IY untouched       H"),
		(16#30#, x"00", "T8 SP untouched       L"), (16#31#, x"F0", "T8 SP untouched       H"),
		(16#32#, x"00", "T9 ED F5/F1 NOP: IX   L"), (16#33#, x"E0", "T9 ED F5/F1 NOP: IX   H"),
		(16#34#, x"89", "T9 ED F5/F1 NOP: HL   L"), (16#35#, x"67", "T9 ED F5/F1 NOP: HL   H"),
		(16#36#, x"68", "T10 HL->DE via IX stk L"), (16#37#, x"24", "T10 HL->DE via IX stk H"),
		(16#38#, x"A5", "T5 EXX (IX-1) via IX   "), (16#39#, x"5A", "T5 EXX (IX-2) via IX   "),
		(16#3F#, x"A5", "completion marker      ")
	);

	-- expected clocks from one opcode-fetch M1 to the next, in the
	-- timing probe at 0200h (ED prefix M1 + opcode M1 + 2x3T memory cycles)
	type timing_t is record
		addr   : natural;
		clocks : natural;
		what   : string(1 to 10);
	end record;
	type timing_arr is array (natural range <>) of timing_t;
	constant TIMING : timing_arr := (
		(16#0204#, 14, "PUSHIX DE "),
		(16#0206#, 14, "POPIX DE  "),
		(16#0208#, 14, "PUSHIX HL "),
		(16#020A#, 14, "POPIX BC  ")
	);

begin

	clk <= not clk after 50 ns when not done else '0';

	cpu : entity work.T80s
		generic map (Mode => 0, T2Write => 0, IOWait => 1)
		port map (
			RESET_n => reset_n, CLK_n => clk, WAIT_n => wait_n, INT_n => '1',
			NMI_n => '1', BUSRQ_n => '1', M1_n => m1_n, MREQ_n => mreq_n,
			IORQ_n => iorq_n, RD_n => rd_n, WR_n => wr_n, RFSH_n => rfsh_n,
			HALT_n => halt_n, BUSAK_n => busak_n, A => a, DI => di, DO => do,
			REG => open);

	di <= mem(to_integer(unsigned(a)));

	-- pseudo-random wait-state generator (LFSR), changes on falling edges
	waitgen : process (clk)
		variable lfsr : std_logic_vector(15 downto 0) := x"ACE1";
		variable hold : natural := 0;
	begin
		if falling_edge(clk) and WAITS > 0 then
			lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
			if hold > 0 then
				hold := hold - 1;
				wait_n <= '0';
			elsif to_integer(unsigned(lfsr(7 downto 0))) mod WAITS = 0 then
				hold := to_integer(unsigned(lfsr(9 downto 8)));	-- 0..3 extra
				wait_n <= '0';
			else
				wait_n <= '1';
			end if;
		end if;
	end process;

	-- load payload, then write cycles
	ram : process (clk)
		type char_file_t is file of character;
		file f : char_file_t;
		variable c : character;
		variable n : natural;
		variable st : file_open_status;
	begin
		if not loaded then
			file_open(st, f, "sim/tb_ixstack.bin", read_mode);
			assert st = open_ok report "cannot open sim/tb_ixstack.bin" severity failure;
			n := 0;
			while not endfile(f) loop
				read(f, c);
				mem(n) <= std_logic_vector(to_unsigned(character'pos(c), 8));
				n := n + 1;
			end loop;
			file_close(f);
			report "loaded " & integer'image(n) & " bytes";
			loaded <= true;
		elsif rising_edge(clk) then
			if mreq_n = '0' and wr_n = '0' then
				mem(to_integer(unsigned(a))) <= do;
			end if;
		end if;
	end process;

	stim : process
		variable cyc : natural := 0;
		variable last_m1_cyc : natural := 0;
		variable last_m1_addr : natural := 0;
		variable prev_m1_n : std_logic := '1';
		variable errors : natural := 0;
		variable timing_seen : natural := 0;
		variable got : std_logic_vector(7 downto 0);
		variable addr : natural;
	begin
		wait until loaded;
		for i in 1 to 5 loop
			wait until rising_edge(clk);
		end loop;
		reset_n <= '1';

		loop
			wait until rising_edge(clk);
			cyc := cyc + 1;
			-- opcode fetch: falling edge of M1_n (A already holds the PC)
			if m1_n = '0' and prev_m1_n = '1' then
				addr := to_integer(unsigned(a));
				-- the second M1 of an ED-prefixed instruction is not a new
				-- instruction; only timestamp/check at instruction starts
				if not (addr = last_m1_addr + 1 and mem(last_m1_addr) = x"ED") then
					for i in TIMING'range loop
						if last_m1_addr = TIMING(i).addr and WAITS = 0 then
							timing_seen := timing_seen + 1;
							if cyc - last_m1_cyc /= TIMING(i).clocks then
								report "TIMING FAIL " & TIMING(i).what & ": " &
									integer'image(cyc - last_m1_cyc) & " clocks, expected " &
									integer'image(TIMING(i).clocks) severity error;
								errors := errors + 1;
							else
								report "timing ok   " & TIMING(i).what & ": " &
									integer'image(cyc - last_m1_cyc) & " T";
							end if;
						end if;
					end loop;
					last_m1_cyc := cyc;
					last_m1_addr := addr;
				end if;
			end if;
			prev_m1_n := m1_n;
			exit when halt_n = '0' and to_integer(unsigned(a)) >= 16#0200#;
			if halt_n = '0' then
				report "CPU halted early at " & integer'image(to_integer(unsigned(a)))
					severity error;
				errors := errors + 1;
				exit;
			end if;
			if cyc > 2000000 then
				report "timeout" severity error;
				errors := errors + 1;
				exit;
			end if;
		end loop;

		for i in EXPECTED'range loop
			got := mem(RSLT + EXPECTED(i).offs);
			if got /= EXPECTED(i).val then
				report "FAIL " & EXPECTED(i).what & ": got " & to_hstring(got) &
					" expected " & to_hstring(EXPECTED(i).val) severity error;
				errors := errors + 1;
			end if;
		end loop;
		if timing_seen /= TIMING'length and WAITS = 0 then
			report "timing probe incomplete: saw " & integer'image(timing_seen) &
				" of " & integer'image(TIMING'length) severity error;
			errors := errors + 1;
		end if;

		if errors = 0 then
			if WAITS = 0 then
				report "tb_ixstack: ALL " & integer'image(EXPECTED'length) &
					" result bytes and " & integer'image(TIMING'length) &
					" timing checks PASSED (" & integer'image(cyc) & " clocks)";
			else
				report "tb_ixstack: ALL " & integer'image(EXPECTED'length) &
					" result bytes PASSED with wait states, timing checks skipped (" &
					integer'image(cyc) & " clocks)";
			end if;
		else
			report "tb_ixstack: " & integer'image(errors) & " FAILURE(S)" severity failure;
		end if;
		done <= true;
		wait;
	end process;

end sim;

-- tb_ixmin.vhd - minimal per-instruction test of PUSHIX/POPIX.
--
-- Each case is a tiny hand-assembled program loaded at 0000h:
--   set up registers, execute ONE custom instruction, HALT.
-- After HALT the testbench checks registers directly via the T80s REG
-- debug output, plus the relevant stack bytes in RAM.  The CPU is reset
-- and RAM cleared between cases.
--
-- Run from the project root:  sim/run_ixmin.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ixmin is
end tb_ixmin;

architecture sim of tb_ixmin is

	type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);
	signal mem : mem_t := (others => x"00");

	signal clk     : std_logic := '0';
	signal reset_n : std_logic := '0';
	signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
	signal a       : std_logic_vector(15 downto 0);
	signal di, do  : std_logic_vector(7 downto 0);
	signal done    : boolean := false;

	type bytes is array (natural range <>) of natural;	-- 0..255
	constant NONE : bytes(1 to 0) := (others => 0);

begin

	clk <= not clk after 50 ns when not done else '0';

	cpu : entity work.T80s
		generic map (Mode => 0, T2Write => 0, IOWait => 1)
		port map (
			RESET_n => reset_n, CLK_n => clk, WAIT_n => '1', INT_n => '1',
			NMI_n => '1', BUSRQ_n => '1', M1_n => m1_n, MREQ_n => mreq_n,
			IORQ_n => iorq_n, RD_n => rd_n, WR_n => wr_n, RFSH_n => rfsh_n,
			HALT_n => halt_n, BUSAK_n => busak_n, A => a, DI => di, DO => do,
			REG => open);

	di <= mem(to_integer(unsigned(a)));

	stim : process
		-- T80s does not wire its inner core's REG debug port out, so read
		-- it from the T80 instance directly (VHDL-2008 external name).
		alias reg is << signal .tb_ixmin.cpu.u0.REG : std_logic_vector(211 downto 0) >>;
		variable errors : natural := 0;
		variable cases  : natural := 0;

		-- REG layout (Alternate = 0): A 7:0, F 15:8, SP 63:48, BC 95:80,
		-- DE 111:96, HL 127:112, IX 143:128
		impure function r16(hi : natural) return natural is
		begin
			return to_integer(unsigned(reg(hi downto hi - 15)));
		end function;

		procedure check(name, what : string; got, exp : natural) is
		begin
			if got /= exp then
				report name & ": " & what & " = " &
					to_hstring(to_unsigned(got, 16)) & ", expected " &
					to_hstring(to_unsigned(exp, 16)) severity error;
				errors := errors + 1;
			end if;
		end procedure;

		-- code   : program bytes at 0000h (must end in HALT, 76h)
		-- pre    : (addr, byte) pairs preloaded into RAM
		-- ix..af : expected register values, -1 = don't check
		-- post   : (addr, byte) pairs expected in RAM afterwards
		procedure run(name : string; code, pre : bytes;
		              ix, bc, de, hl, af : integer; post : bytes) is
			variable n : natural := 0;
			variable i : natural;
		begin
			cases := cases + 1;
			reset_n <= '0';
			mem <= (others => x"00");
			wait until rising_edge(clk);
			for k in code'range loop
				mem(k - code'low) <= std_logic_vector(to_unsigned(code(k), 8));
			end loop;
			i := pre'low;
			while i < pre'high loop
				mem(pre(i)) <= std_logic_vector(to_unsigned(pre(i + 1), 8));
				i := i + 2;
			end loop;
			for k in 1 to 4 loop
				wait until rising_edge(clk);
			end loop;
			reset_n <= '1';
			loop
				wait until rising_edge(clk);
				if mreq_n = '0' and wr_n = '0' then
					mem(to_integer(unsigned(a))) <= do;
				end if;
				n := n + 1;
				exit when halt_n = '0';
				if n > 500 then
					report name & ": TIMEOUT (no HALT)" severity error;
					errors := errors + 1;
					return;
				end if;
			end loop;
			wait until rising_edge(clk);
			if ix >= 0 then check(name, "IX", r16(143), ix); end if;
			if bc >= 0 then check(name, "BC", r16(95),  bc); end if;
			if de >= 0 then check(name, "DE", r16(111), de); end if;
			if hl >= 0 then check(name, "HL", r16(127), hl); end if;
			if af >= 0 then
				check(name, "AF", to_integer(unsigned(std_logic_vector'(reg(7 downto 0) & reg(15 downto 8)))), af);
			end if;
			i := post'low;
			while i < post'high loop
				check(name, "(" & to_hstring(to_unsigned(post(i), 16)) & ")",
				      to_integer(unsigned(mem(post(i)))), post(i + 1));
				i := i + 2;
			end loop;
			report name & ": done";
		end procedure;

	begin
		-- LD IX,E000 = DD 21 00 E0 ; LD BC = 01 ; LD DE = 11 ; LD HL = 21
		-- PUSHIX BC/DE/HL = ED C5/D5/E5 ; POPIX BC/DE/HL = ED C1/D1/E1

		run("PUSHIX DE",
		    (16#DD#,16#21#,16#00#,16#E0#, 16#11#,16#34#,16#12#, 16#ED#,16#D5#, 16#76#),
		    NONE, 16#DFFE#, -1, 16#1234#, -1, -1,
		    (16#DFFF#,16#12#, 16#DFFE#,16#34#, 16#DFFD#,16#00#));

		run("PUSHIX BC",
		    (16#DD#,16#21#,16#00#,16#E0#, 16#01#,16#78#,16#56#, 16#ED#,16#C5#, 16#76#),
		    NONE, 16#DFFE#, 16#5678#, -1, -1, -1,
		    (16#DFFF#,16#56#, 16#DFFE#,16#78#, 16#DFFD#,16#00#));

		run("PUSHIX HL",
		    (16#DD#,16#21#,16#00#,16#E0#, 16#21#,16#BC#,16#9A#, 16#ED#,16#E5#, 16#76#),
		    NONE, 16#DFFE#, -1, -1, 16#9ABC#, -1,
		    (16#DFFF#,16#9A#, 16#DFFE#,16#BC#, 16#DFFD#,16#00#));

		run("POPIX DE",
		    (16#DD#,16#21#,16#FE#,16#DF#, 16#11#,16#00#,16#00#, 16#ED#,16#D1#, 16#76#),
		    (16#DFFE#,16#34#, 16#DFFF#,16#12#),
		    16#E000#, -1, 16#1234#, -1, -1, NONE);

		run("POPIX BC",
		    (16#DD#,16#21#,16#FE#,16#DF#, 16#01#,16#00#,16#00#, 16#ED#,16#C1#, 16#76#),
		    (16#DFFE#,16#78#, 16#DFFF#,16#56#),
		    16#E000#, 16#5678#, -1, -1, -1, NONE);

		run("POPIX HL",
		    (16#DD#,16#21#,16#FE#,16#DF#, 16#21#,16#00#,16#00#, 16#ED#,16#E1#, 16#76#),
		    (16#DFFE#,16#BC#, 16#DFFF#,16#9A#),
		    16#E000#, -1, -1, 16#9ABC#, -1, NONE);

		-- other pairs must be left alone by a push/pop of one pair
		run("POPIX DE leaves BC,HL",
		    (16#DD#,16#21#,16#FE#,16#DF#, 16#01#,16#11#,16#11#, 16#21#,16#22#,16#22#,
		     16#ED#,16#D1#, 16#76#),
		    (16#DFFE#,16#34#, 16#DFFF#,16#12#),
		    16#E000#, 16#1111#, 16#1234#, 16#2222#, -1, NONE);

		-- flags/A preserved: LD SP,F000 / LD BC,FFD7 / PUSH BC / POP AF /
		-- LD IX,E000 / PUSHIX DE / HALT
		run("PUSHIX keeps AF",
		    (16#31#,16#00#,16#F0#, 16#01#,16#D7#,16#FF#, 16#C5#, 16#F1#,
		     16#DD#,16#21#,16#00#,16#E0#, 16#ED#,16#D5#, 16#76#),
		    NONE, 16#DFFE#, -1, -1, -1, 16#FFD7#, NONE);

		run("POPIX keeps AF",
		    (16#31#,16#00#,16#F0#, 16#01#,16#D7#,16#FF#, 16#C5#, 16#F1#,
		     16#DD#,16#21#,16#FE#,16#DF#, 16#ED#,16#D1#, 16#76#),
		    (16#DFFE#,16#34#, 16#DFFF#,16#12#),
		    16#E000#, -1, 16#1234#, -1, 16#FFD7#, NONE);

		-- round trip: PUSHIX DE then POPIX BC copies DE to BC via the stack
		run("PUSHIX DE ; POPIX BC",
		    (16#DD#,16#21#,16#00#,16#E0#, 16#11#,16#FE#,16#CA#, 16#01#,16#00#,16#00#,
		     16#ED#,16#D5#, 16#ED#,16#C1#, 16#76#),
		    NONE, 16#E000#, 16#CAFE#, 16#CAFE#, -1, -1,
		    (16#DFFF#,16#CA#, 16#DFFE#,16#FE#));

		if errors = 0 then
			report "tb_ixmin: all " & integer'image(cases) & " cases PASSED";
		else
			report "tb_ixmin: " & integer'image(errors) & " FAILURE(S)" severity failure;
		end if;
		done <= true;
		wait;
	end process;

end sim;

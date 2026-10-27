-- tb_cpuregs.vhd - ground-truth test of the T80s REG debug vector (212 bits)
-- and the individual register-file slots inside T80_Reg.
--
-- Each case is a tiny hand-assembled program loaded at 0000h that loads
-- known distinct values into registers through one architectural path
-- (16-bit / 8-bit loads, flags, EX AF,AF', EXX even/odd, EI/IM/LD I,A),
-- then HALTs.  After HALT the testbench checks:
--
--   1. every loaded register appears at its documented REG bit position
--      (layout comment in MicrocomputerZ80CPM.vhd / T80.vhd), honouring
--      the Alternate-dependent field map, and
--   2. the same values sit in the matching T80_Reg RegsH/RegsL slots
--      (external name), so a REG concatenation that lies about the file
--      is caught.
--
-- Key semantics under test (this modified T80 has ONE register file,
-- slots 0..7 = BC DE HL IX BC' DE' HL' IY; register addresses are
-- Alternate & pair, so EXX flips Alternate and re-windows the addresses;
-- the REG dump has a second concatenation for Alternate='1' that keeps
-- "BC/DE/HL" meaning the CURRENT set):
--
--   * Alternate=0 (even EXX, idle):   BC  95:80  DE 111:96  HL 127:112
--                                     IX 143:128  BC' 159:144 DE' 175:160
--                                     HL' 191:176 IY 207:192
--   * Alternate=1 (odd EXX):          BC 159:144 DE 175:160 HL 191:176
--                                     IX 143:128  BC'  95:80 DE' 111:96
--                                     HL' 127:112 IY 207:192
--     ("BC" = current set either way: EXX re-windows, no data moves.)
--   * fixed in both: PC 79:64 SP 63:48 R 47:40 I 39:32 F' 31:24
--                    A' 23:16 F 15:8 A 7:0 IFF2 211 IFF1 210 IM 209:208
--   * EX AF,AF' swaps the dedicated ACC/F/Fp/Ap registers only.
--
-- R is not checked (HALT refetch loops increment it); PC is checked to
-- within the HALT-refetch allowance.
--
-- Run from the project root:  sim/run_cpuregs.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cpuregs is
end tb_cpuregs;

architecture sim of tb_cpuregs is

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
			REG => open,
			FREEZE_req_n => '1', FREEZE_any => '0');  -- LOCAL D-25: no SSP park in this bench

	di <= mem(to_integer(unsigned(a)));

	stim : process
		-- T80s does not wire its inner core's REG debug port out, so read
		-- it (and the register file slots / Alternate flag) from the
		-- instances directly via VHDL-2008 external names.
		alias reg is << signal .tb_cpuregs.cpu.u0.REG : std_logic_vector(211 downto 0) >>;
		alias alt is << signal .tb_cpuregs.cpu.u0.Alternate : std_logic >>;
		alias dor is << signal .tb_cpuregs.cpu.u0.Regs.DOR : std_logic_vector(127 downto 0) >>;

		variable errors : natural := 0;
		variable cases  : natural := 0;

		-- T80_Reg.DOR is the file's own flattened slot dump:
		-- slot k = DOR(k*16+15 downto k*16), k = 0..7 =
		-- BC DE HL IX BC' DE' HL' IY.  Reading the value straight from
		-- the register file (not from REG) and cross-checking it against
		-- the REG field catches a bad mux/concatenation feeding REG.
		impure function slot_val(k : natural) return std_logic_vector is
		begin
			return dor(k * 16 + 15 downto k * 16);
		end function;

		impure function r16(hi : natural) return natural is
		begin
			return to_integer(unsigned(reg(hi downto hi - 15)));
		end function;

		-- Field bases are FIXED at the documented Alternate=0 positions:
		-- the Alternate='1' concatenation in T80.vhd deliberately
		-- re-orders DOR so a fixed-position read always yields the
		-- architecturally current set.  Reading fixed positions in both
		-- windows is what proves that re-ordering (an EXX-odd case with
		-- a buggy swap reports swapped current/shadow values).
		constant F_BC  : natural := 95;		-- current BC  (slot0 / slot4)
		constant F_DE  : natural := 111;	-- current DE  (slot1 / slot5)
		constant F_HL  : natural := 127;	-- current HL  (slot2 / slot6)
		constant F_IX  : natural := 143;	-- IX  (slot3, both windows)
		constant F_BCP : natural := 159;	-- shadow BC   (slot4 / slot0)
		constant F_DEP : natural := 175;	-- shadow DE   (slot5 / slot1)
		constant F_HLP : natural := 191;	-- shadow HL   (slot6 / slot2)
		constant F_IY  : natural := 207;	-- IY  (slot7, both windows)
		constant F_SP  : natural := 63;

		procedure check(name, what : string; got, exp : natural) is
		begin
			if got /= exp then
				report name & ": " & what & " = " &
					to_hstring(to_unsigned(got, 16)) & ", expected " &
					to_hstring(to_unsigned(exp, 16)) severity error;
				errors := errors + 1;
			end if;
		end procedure;

		-- code    : program bytes at 0000h (must end in HALT, 76h)
		-- expected values, -1 = don't check (values derive purely from
		--           Z80 instruction semantics, never from REG itself)
		-- exp_alt : expected Alternate state at halt ('0'/'1')
		-- pc_at   : code length; PC must be pc_at or pc_at+1 (HALT refetch)
		-- slots   : (slot index, expected 16-bit value) pairs, T80_Reg
		--           file cross-check; only slots the program wrote
		procedure run(name : string; code : bytes;
		              a_exp, f_exp, ap_exp, fp_exp,
		              bc, de, hl, ix, bcp, dep, hlp, iy, sp : integer;
		              iff_im, i_exp, exp_alt : integer; pc_at : natural;
		              slots_exp : bytes) is
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

			-- Alternate window sanity: the EXX cases pin it explicitly.
			if (alt = '1' and exp_alt /= 1) or (alt = '0' and exp_alt /= 0) then
				report name & ": wrong Alternate window (expected " &
					integer'image(exp_alt) & ")" severity error;
				errors := errors + 1;
			end if;

			if a_exp  >= 0 then check(name, "A",  to_integer(unsigned(reg(7 downto 0))), a_exp); end if;
			if f_exp  >= 0 then check(name, "F",  to_integer(unsigned(reg(15 downto 8))), f_exp); end if;
			if ap_exp >= 0 then check(name, "A'", to_integer(unsigned(reg(23 downto 16))), ap_exp); end if;
			if fp_exp >= 0 then check(name, "F'", to_integer(unsigned(reg(31 downto 24))), fp_exp); end if;
			if bc  >= 0 then check(name, "BC",  r16(F_BC), bc); end if;
			if de  >= 0 then check(name, "DE",  r16(F_DE), de); end if;
			if hl  >= 0 then check(name, "HL",  r16(F_HL), hl); end if;
			if ix  >= 0 then check(name, "IX",  r16(F_IX), ix); end if;
			if bcp >= 0 then check(name, "BC'", r16(F_BCP), bcp); end if;
			if dep >= 0 then check(name, "DE'", r16(F_DEP), dep); end if;
			if hlp >= 0 then check(name, "HL'", r16(F_HLP), hlp); end if;
			if iy  >= 0 then check(name, "IY",  r16(F_IY), iy); end if;
			if sp  >= 0 then check(name, "SP",  r16(F_SP), sp); end if;

			if iff_im >= 0 then
				check(name, "IFF2/IFF1/IM", to_integer(unsigned(reg(211 downto 208))), iff_im);
			end if;
			if i_exp >= 0 then
				check(name, "I", to_integer(unsigned(reg(39 downto 32))), i_exp);
			end if;

			if r16(79) < pc_at or r16(79) > pc_at + 1 then
				report name & ": PC = " &
					to_hstring(to_unsigned(r16(79), 16)) &
					", expected " & integer'image(pc_at) & " or " &
					integer'image(pc_at + 1) severity error;
				errors := errors + 1;
			end if;

			i := slots_exp'low;
			while i < slots_exp'high loop
				if to_integer(unsigned(slot_val(slots_exp(i)))) /= slots_exp(i + 1) then
					report name & ": RegFile slot " & integer'image(slots_exp(i)) &
						" = " & to_hstring(slot_val(slots_exp(i))) &
						", expected " &
						to_hstring(to_unsigned(slots_exp(i + 1), 16)) severity error;
					errors := errors + 1;
				end if;
				i := i + 2;
			end loop;

			report name & ": done";
		end procedure;

	begin
		-- All values are distinct per register so any mis-wiring or field
		-- aliasing shows up, not just plain zero/default mistakes.

		-- 16-bit immediate loads on every 16-bit architectural path
		run("LD16 pairs/IX/IY/SP",
		    (16#01#,16#34#,16#12#, 16#11#,16#78#,16#56#, 16#21#,16#BC#,16#9A#,
		     16#DD#,16#21#,16#F0#,16#DE#, 16#FD#,16#21#,16#45#,16#23#,
		     16#31#,16#89#,16#67#, 16#76#),
		    -1, -1, -1, -1,
		    16#1234#, 16#5678#, 16#9ABC#, 16#DEF0#, -1, -1, -1, 16#2345#,
		    16#6789#, -1, -1, 0, 21,
		    (0, 16#1234#, 1, 16#5678#, 2, 16#9ABC#, 3, 16#DEF0#, 7, 16#2345#));

		-- 8-bit LD r,n on every path; pairs assemble from the byte loads
		run("LD8 into B C D E H L A",
		    (16#3E#,16#11#, 16#06#,16#22#, 16#0E#,16#33#, 16#16#,16#44#,
		     16#1E#,16#55#, 16#26#,16#66#, 16#2E#,16#77#, 16#76#),
		    -- a  f  ap fp
		    16#11#, -1, -1, -1,
		    -- bc     de     hl     ix  bcp dep hlp iy  sp  iff i  alt pc
		    16#2233#, 16#4455#, 16#6677#, -1, -1, -1, -1, -1, -1, -1, -1, 0, 15,
		    (0, 16#2233#, 1, 16#4455#, 2, 16#6677#));

		-- flags through a deterministic ALU op: SUB A of 55h leaves
		-- A=00 and F = Z|N = 0x42 (H is the half-borrow out of bit 3:
		-- 5h-5h borrows nothing, so H=0)
		run("SUB A flags",
		    (16#3E#,16#55#, 16#97#, 16#76#),
		    16#00#, 16#42#, -1, -1,
		    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 4, NONE);

		-- EX AF,AF' both ways: trace -> main A=00 F=42, shadow A'=EE F'=AC
		-- (SUB A: N=1 so PV=signed-overflow=0, 5h-5h half-borrow=0 so
		--  H=0 -> F=42; OR A of EEh sets S,b5,b3 and PV=parity(6 ones,
		--  even), RESETS H, N and C (logic ops clear C) -> F=AC; good
		--  C/H check since the incoming F=FF had C=H=1)
		run("EX AF,AF' both sets",
		    (16#3E#,16#55#, 16#97#, 16#08#, 16#3E#,16#EE#, 16#B7#,
		     16#08#, 16#76#),
		    16#00#, 16#42#, 16#EE#, 16#AC#,
		    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 9, NONE);

		-- EXX twice (back to main at halt): current and shadow sets both
		-- visible in the Alternate=0 field map; IX/IY unaffected by EXX
		run("EXX even",
		    (16#01#,16#11#,16#11#, 16#11#,16#22#,16#22#, 16#21#,16#33#,16#33#,
		     16#DD#,16#21#,16#44#,16#44#, 16#FD#,16#21#,16#88#,16#88#,
		     16#D9#,
		     16#01#,16#55#,16#55#, 16#11#,16#66#,16#66#, 16#21#,16#77#,16#77#,
		     16#D9#, 16#76#),
		    -1, -1, -1, -1,
		    16#1111#, 16#2222#, 16#3333#, 16#4444#,
		    16#5555#, 16#6666#, 16#7777#, 16#8888#, -1, -1, -1, 0, 29,
		    (0, 16#1111#, 1, 16#2222#, 2, 16#3333#, 3, 16#4444#,
		     4, 16#5555#, 5, 16#6666#, 6, 16#7777#, 7, 16#8888#));

		-- EXX once (Alternate=1 at halt): EXX re-windows register
		-- addresses without moving data; the T80 REG mux re-orders DOR
		-- so the FIXED field bases must still read the CURRENT values
		-- (5555/6666/7777) as BC/DE/HL and the pre-EXX values as shadow.
		run("EXX odd alternate window",
		    (16#01#,16#11#,16#11#, 16#11#,16#22#,16#22#, 16#21#,16#33#,16#33#,
		     16#DD#,16#21#,16#44#,16#44#, 16#FD#,16#21#,16#88#,16#88#,
		     16#D9#,
		     16#01#,16#55#,16#55#, 16#11#,16#66#,16#66#, 16#21#,16#77#,16#77#,
		     16#76#),
		    -1, -1, -1, -1,
		    16#5555#, 16#6666#, 16#7777#, 16#4444#,
		    16#1111#, 16#2222#, 16#3333#, 16#8888#, -1, -1, -1, 1, 28,
		    (0, 16#1111#, 1, 16#2222#, 2, 16#3333#, 3, 16#4444#,
		     4, 16#5555#, 5, 16#6666#, 6, 16#7777#, 7, 16#8888#));

		-- EI (active after next insn), IM 1, LD I,A: interrupt state in
		-- the top REG bits and the I register.  iff_im = IFF2,IFF1,IM1,IM0
		run("EI IM1 LD I,A",
		    (16#FB#, 16#3E#,16#E0#, 16#ED#,16#47#, 16#ED#,16#56#, 16#76#),
		    -1, -1, -1, -1,
		    -1, -1, -1, -1, -1, -1, -1, -1, -1,
		    13,  -- 2#1101#: IFF2=1 IFF1=1 IM=01
		    16#E0#, 0, 8, NONE);

		-- DI after EI+NOP clears both flip-flops; IM stays 0
		run("DI clears IFFs",
		    (16#FB#, 16#00#, 16#F3#, 16#76#),
		    -1, -1, -1, -1,
		    -1, -1, -1, -1, -1, -1, -1, -1, -1,
		    0, -1, 0, 4, NONE);

		if errors = 0 then
			report "tb_cpuregs: all " & integer'image(cases) & " cases PASSED";
		else
			report "tb_cpuregs: " & integer'image(errors) & " FAILURE(S)" severity failure;
		end if;
		done <= true;
		wait;
	end process;

end sim;

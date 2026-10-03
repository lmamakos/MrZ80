-- tb_forth.vhd - boot a CamelFORTH kernel binary on a bare T80s core and
-- drive its console over an emulated ACIA, for end-to-end testing of the
-- custom Forth instructions (F_NEXT ED 92, PUSHIX/POPIX ED C5../ED C1..).
--
-- The kernel image (generic BIN, assembled for ORG 0 - i.e. the BOOTABLE
-- camel80.bin / camelf.bin from forth/Makefile) is loaded into a flat
-- 64 KB RAM.  The console is the ACIA1 interface that forth/io-multi.azm
-- uses: status port 82h (bit 0 = RX data ready, bit 1 = TX ready) and data
-- port 83h.  The SCRIPT below is fed to the interpreter one line at a time.
-- Every output line is echoed via 'report' and also written to the text
-- file named by generic LOG so two kernels' transcripts can be diffed.
-- For each script line the testbench reports the number of CPU clocks
-- between the line's terminating CR being consumed and the interpreter
-- printing its "ok" prompt - i.e. the time to interpret/run that line.
--
-- Run from the project root:  sim/run_forth.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_forth is
	generic (
		BIN    : string  := "forth/camelf.bin";
		LOG    : string  := "/tmp/tb_forth.log";
		MAXCLK : natural := 40000000
	);
end tb_forth;

architecture sim of tb_forth is

	type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);
	signal mem : mem_t := (others => x"00");

	signal clk     : std_logic := '0';
	signal reset_n : std_logic := '0';
	signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
	signal a       : std_logic_vector(15 downto 0);
	signal di, do  : std_logic_vector(7 downto 0);
	signal loaded  : boolean := false;
	signal done    : boolean := false;

	constant CR : character := character'val(13);
	constant LF : character := character'val(10);

	-- Each line ends in CR.  Exercises ENTER/EXIT (colon calls), >R/R>,
	-- DO loops (PUSHIX HL x2), DOES> (dodoes PUSHIX DE), recursion.
	constant SCRIPT : string :=
		"1 2 3 + + ." & CR &
		": SQ DUP * ; 7 SQ ." & CR &
		"5 >R R@ R> + ." & CR &
		": T 5 0 DO I . LOOP ; T" & CR &
		": T2 3 0 DO 2 0 DO J . I . LOOP LOOP ; T2" & CR &
		": TS 1 2 3 >R >R >R R> R> R> . . . ; TS" & CR &
		"42 CONSTANT K K . VARIABLE V 9 V ! V @ ." & CR &
		": MK CREATE , DOES> @ ; 77 MK Q Q ." & CR &
		": FIB DUP 2 < IF EXIT THEN DUP 1- RECURSE SWAP 2 - RECURSE + ; 15 FIB ." & CR &
		": L1 ; : L2 L1 L1 L1 L1 ; : L3 L2 L2 L2 L2 ; : BENCH 200 0 DO L3 LOOP ; BENCH" & CR &
		": B2 1000 0 DO I DROP LOOP ; B2" & CR &
		": B3 500 0 DO I >R R> DROP LOOP ; B3" & CR &
		": B4 300 0 DO 1000 0 DO LOOP LOOP ; B4" & CR &
		"DEPTH ." & CR;

	signal rx_pos : natural := 1;		-- next SCRIPT char to deliver
	signal rx_gate : boolean := false;	-- true: current line may be delivered

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

	di <= mem(to_integer(unsigned(a))) when iorq_n = '1' else
	      "0000001" & '1' when a(7 downto 0) = x"82" and rx_gate and rx_pos <= SCRIPT'length else
	      "00000010"      when a(7 downto 0) = x"82" else
	      std_logic_vector(to_unsigned(character'pos(SCRIPT(rx_pos)), 8))
	                      when a(7 downto 0) = x"83" and rx_pos <= SCRIPT'length else
	      x"FF";

	ram : process (clk)
		type char_file_t is file of character;
		file f : char_file_t;
		variable c : character;
		variable n : natural;
		variable st : file_open_status;
	begin
		if not loaded then
			file_open(st, f, BIN, read_mode);
			assert st = open_ok report "cannot open " & BIN severity failure;
			n := 0;
			while not endfile(f) loop
				read(f, c);
				mem(n) <= std_logic_vector(to_unsigned(character'pos(c), 8));
				n := n + 1;
			end loop;
			file_close(f);
			report "loaded " & BIN & ": " & integer'image(n) & " bytes";
			loaded <= true;
		elsif rising_edge(clk) then
			if mreq_n = '0' and wr_n = '0' then
				mem(to_integer(unsigned(a))) <= do;
			end if;
		end if;
	end process;

	console : process
		file logf : text;
		variable l : line;
		variable cyc : natural := 0;
		variable outbuf : string(1 to 256);
		variable outlen : natural := 0;
		variable prev_iorq_n : std_logic := '1';
		variable io_rd_83, io_wr_83 : boolean := false;
		variable ch : character;
		variable t_cr : natural := 0;
		variable timing : boolean := false;
		variable prevch : character := ' ';
		variable lineno : natural := 0;
		variable total : natural := 0;
		variable lastline : boolean := false;
	begin
		file_open(logf, LOG, write_mode);
		wait until loaded;
		for i in 1 to 5 loop
			wait until rising_edge(clk);
		end loop;
		reset_n <= '1';
		rx_gate <= true;

		loop
			wait until rising_edge(clk);
			cyc := cyc + 1;

			-- latch which I/O cycle is in progress; act at its end
			if iorq_n = '0' and m1_n = '1' then
				io_rd_83 := rd_n = '0' and a(7 downto 0) = x"83";
				if wr_n = '0' and a(7 downto 0) = x"83" then
					io_wr_83 := true;
					ch := character'val(to_integer(unsigned(do)));
				end if;
			end if;

			if iorq_n = '1' and prev_iorq_n = '0' then
				if io_rd_83 and rx_pos <= SCRIPT'length then
					if SCRIPT(rx_pos) = CR then
						t_cr := cyc;
						timing := true;
						rx_gate <= false;	-- hold next line until "ok"
						lastline := rx_pos = SCRIPT'length;
					end if;
					rx_pos <= rx_pos + 1;
				end if;
				if io_wr_83 then
					if ch = LF then
						write(l, outbuf(1 to outlen));
						writeline(logf, l);
						report "| " & outbuf(1 to outlen);
						outlen := 0;
					elsif ch /= CR and outlen < outbuf'length then
						outlen := outlen + 1;
						outbuf(outlen) := ch;
					end if;
					if timing and prevch = 'o' and ch = 'k' then
						lineno := lineno + 1;
						timing := false;
						total := total + (cyc - t_cr);
						report "line " & integer'image(lineno) & ": " &
							integer'image(cyc - t_cr) & " clocks";
						rx_gate <= true;
						if lastline then
							exit;
						end if;
					end if;
					prevch := ch;
				end if;
				io_rd_83 := false;
				io_wr_83 := false;
			end if;
			prev_iorq_n := iorq_n;

			if halt_n = '0' then
				report "CPU HALTED at " & to_hstring(a) severity error;
				exit;
			end if;
			if cyc > MAXCLK then
				report "timeout after " & integer'image(cyc) & " clocks" severity error;
				exit;
			end if;
		end loop;

		-- flush any partial output line
		if outlen > 0 then
			write(l, outbuf(1 to outlen));
			writeline(logf, l);
			report "| " & outbuf(1 to outlen);
		end if;
		report "tb_forth: " & integer'image(lineno) & " lines, " &
			integer'image(total) & " clocks total in script lines, " &
			integer'image(cyc) & " clocks overall";
		file_close(logf);
		done <= true;
		wait;
	end process;

end sim;

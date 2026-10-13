-- tb_hps_blockdev: self-checking testbench for Components/SDCARD/hps_blockdev.vhd
--
-- Models (a) a Z-80 I/O cycle (n_rd/n_wr strobes held for several clk with
-- the address/data stable) and (b) the HPS side of hps_io's block interface:
-- on sd_rd it raises sd_ack and streams a 512-byte block into the device
-- (sd_buff_addr/sd_buff_dout/sd_buff_wr), on sd_wr it raises sd_ack and reads
-- the block back from the device (sd_buff_addr/sd_buff_din), then drops
-- sd_ack. Ends with "PASS" or asserts on the first failure.
--
-- Run with sim/run_blockdev.sh

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_hps_blockdev is
end tb_hps_blockdev;

architecture sim of tb_hps_blockdev is
	constant NBLK : integer := 4;

	signal clk      : std_logic := '0';
	signal n_reset  : std_logic := '0';
	signal n_rd     : std_logic := '1';
	signal n_wr     : std_logic := '1';
	signal dataIn   : std_logic_vector(7 downto 0) := (others => '0');
	signal dataOut  : std_logic_vector(7 downto 0);
	signal regAddr  : std_logic_vector(2 downto 0) := (others => '0');

	signal sd_lba       : std_logic_vector(31 downto 0);
	signal sd_rd        : std_logic;
	signal sd_wr        : std_logic;
	signal sd_ack       : std_logic := '0';
	signal sd_buff_addr : std_logic_vector(8 downto 0) := (others => '0');
	signal sd_buff_dout : std_logic_vector(7 downto 0) := (others => '0');
	signal sd_buff_din  : std_logic_vector(7 downto 0);
	signal sd_buff_wr   : std_logic := '0';
	signal img_mounted  : std_logic := '0';
	signal img_readonly : std_logic := '0';
	signal img_size     : std_logic_vector(63 downto 0) := (others => '0');
	signal activity     : std_logic;

	-- the "image file" on the Linux side
	type image_t is array (0 to NBLK*512-1) of std_logic_vector(7 downto 0);
	signal image : image_t;

	signal hps_reads  : integer := 0;
	signal hps_writes : integer := 0;
	signal last_lba   : std_logic_vector(31 downto 0) := (others => '1');
	signal done       : boolean := false;

begin
	clk <= not clk after 10 ns when not done else clk;   -- 50 MHz

	dut : entity work.hps_blockdev
		generic map (LED_CYCLES => 50)
		port map (
			clk => clk, n_reset => n_reset,
			n_rd => n_rd, n_wr => n_wr,
			dataIn => dataIn, dataOut => dataOut, regAddr => regAddr,
			sd_lba => sd_lba, sd_rd => sd_rd, sd_wr => sd_wr, sd_ack => sd_ack,
			sd_buff_addr => sd_buff_addr, sd_buff_dout => sd_buff_dout,
			sd_buff_din => sd_buff_din, sd_buff_wr => sd_buff_wr,
			img_mounted => img_mounted, img_readonly => img_readonly,
			img_size => img_size, activity => activity);

	-- ------------------------------------------------------------ HPS model
	hps : process
		variable blk : integer;
		variable first : boolean := true;
	begin
		-- (image has exactly one driver: this process)
		if first then
			for i in 0 to NBLK*512-1 loop
				image(i) <= std_logic_vector(to_unsigned((i * 7 + i / 512 * 13) mod 256, 8));
			end loop;
			first := false;
		end if;
		wait until rising_edge(clk);
		if sd_rd = '1' or sd_wr = '1' then
			-- hps_io: request polled, LBA read, then the 0x17/0x18 command
			-- begins (sd_ack high) a good while later.
			blk := to_integer(unsigned(sd_lba(23 downto 0)));
			last_lba <= sd_lba;
			for i in 1 to 20 loop wait until rising_edge(clk); end loop;
			if sd_rd = '1' then
				sd_ack <= '1';
				for i in 1 to 5 loop wait until rising_edge(clk); end loop;
				for i in 0 to 511 loop
					sd_buff_addr <= std_logic_vector(to_unsigned(i, 9));
					sd_buff_dout <= image(blk*512 + i);
					for k in 1 to 6 loop wait until rising_edge(clk); end loop;
					sd_buff_wr <= '1';
					wait until rising_edge(clk);
					sd_buff_wr <= '0';
					for k in 1 to 4 loop wait until rising_edge(clk); end loop;
				end loop;
				for i in 1 to 10 loop wait until rising_edge(clk); end loop;
				sd_ack <= '0';
				hps_reads <= hps_reads + 1;
			else
				sd_ack <= '1';
				for i in 1 to 5 loop wait until rising_edge(clk); end loop;
				for i in 0 to 511 loop
					sd_buff_addr <= std_logic_vector(to_unsigned(i, 9));
					for k in 1 to 8 loop wait until rising_edge(clk); end loop;
					image(blk*512 + i) <= sd_buff_din;
				end loop;
				for i in 1 to 10 loop wait until rising_edge(clk); end loop;
				sd_ack <= '0';
				hps_writes <= hps_writes + 1;
			end if;
			-- wait for the device to drop the request
			for i in 1 to 20 loop wait until rising_edge(clk); end loop;
		end if;
	end process;

	-- -------------------------------------------------------------- tests
	stim : process

		procedure tick(n : integer) is
		begin
			for i in 1 to n loop wait until rising_edge(clk); end loop;
		end procedure;

		procedure io_write(a : integer; d : integer) is
		begin
			regAddr <= std_logic_vector(to_unsigned(a, 3));
			dataIn  <= std_logic_vector(to_unsigned(d, 8));
			tick(2);
			n_wr <= '0';
			tick(8);
			n_wr <= '1';
			tick(2);
		end procedure;

		procedure io_read(a : integer; d : out integer) is
		begin
			regAddr <= std_logic_vector(to_unsigned(a, 3));
			tick(2);
			n_rd <= '0';
			tick(7);
			assert not is_x(dataOut) report "dataOut metavalue, addr " & integer'image(a) severity failure;
			d := to_integer(unsigned(dataOut));   -- sampled before strobe ends
			tick(1);
			n_rd <= '1';
			tick(2);
		end procedure;

		procedure expect_status(exp : integer; what : string) is
			variable s : integer;
		begin
			io_read(1, s);
			assert s = exp
				report what & ": STATUS=" & integer'image(s) &
				       " expected " & integer'image(exp)
				severity failure;
		end procedure;

		procedure wait_status(exp : integer; what : string) is
			variable s : integer;
			variable n : integer := 0;
		begin
			loop
				io_read(1, s);
				exit when s = exp;
				n := n + 1;
				assert n < 20000
					report what & ": timeout waiting for STATUS=" & integer'image(exp) &
					       " (last " & integer'image(s) & ")"
					severity failure;
			end loop;
		end procedure;

		procedure set_lba(l : integer) is
		begin
			io_write(2, l mod 256);
			io_write(3, (l / 256) mod 256);
			io_write(4, (l / 65536) mod 256);
		end procedure;

		procedure mount(size_bytes : unsigned(63 downto 0); ro : std_logic) is
		begin
			img_size     <= std_logic_vector(size_bytes);
			img_readonly <= ro;
			tick(3);
			img_mounted <= '1';
			tick(8);
			img_mounted <= '0';
			tick(5);
		end procedure;

		variable d : integer;
		variable e : integer;
	begin
		tick(5);
		n_reset <= '1';
		tick(5);

		-- 1. no image mounted
		expect_status(16#90#, "unmounted");
		io_read(5, d);  assert d = 0 report "size0 when unmounted" severity failure;
		set_lba(0);
		io_write(1, 0);                         -- read command: rejected
		tick(10);
		expect_status(16#94#, "unmounted cmd rejected");
		assert hps_reads = 0 report "HPS read with no image" severity failure;

		-- 2. mount a 4-block image
		mount(to_unsigned(NBLK*512, 64), '0');
		expect_status(16#80#, "mounted idle");
		io_read(5, d);  assert d = NBLK mod 256 report "size0" severity failure;
		io_read(6, d);  assert d = 0 report "size1" severity failure;
		io_read(7, d);  assert d = 0 report "size2" severity failure;

		-- 3. read block 2
		set_lba(2);
		io_write(1, 0);
		tick(2);
		expect_status(16#20#, "read waiting for HPS");
		assert activity = '1' report "activity during read" severity failure;
		for i in 0 to 511 loop
			wait_status(16#E0#, "read byte " & integer'image(i));
			io_read(0, d);
			assert d = to_integer(unsigned(image(2*512 + i)))
				report "read blk2 byte " & integer'image(i) & " got " & integer'image(d) &
				       " expected " & integer'image(to_integer(unsigned(image(2*512 + i))))
				severity failure;
		end loop;
		tick(10);
		expect_status(16#80#, "idle after read");
		assert hps_reads = 1 report "hps_reads" severity failure;
		assert last_lba = x"00000002" report "sd_lba for read" severity failure;

		-- 4. write block 1 with a new pattern, then read it back
		set_lba(1);
		io_write(1, 1);
		tick(2);
		for i in 0 to 511 loop
			wait_status(16#A0#, "write byte " & integer'image(i));
			io_write(0, (i * 3 + 5) mod 256);
		end loop;
		wait_status(16#80#, "idle after write");
		assert hps_writes = 1 report "hps_writes" severity failure;
		assert last_lba = x"00000001" report "sd_lba for write" severity failure;
		for i in 0 to 511 loop
			assert image(512 + i) = std_logic_vector(to_unsigned((i * 3 + 5) mod 256, 8))
				report "image blk1 byte " & integer'image(i) & " not written" severity failure;
		end loop;
		-- neighbours untouched
		assert image(0) = x"00" and image(1024) = std_logic_vector(to_unsigned((1024*7 + 2*13) mod 256, 8))
			report "neighbour block modified" severity failure;

		set_lba(1);
		io_write(1, 0);
		for i in 0 to 511 loop
			wait_status(16#E0#, "readback byte " & integer'image(i));
			io_read(0, d);
			assert d = (i * 3 + 5) mod 256
				report "readback blk1 byte " & integer'image(i) severity failure;
		end loop;
		wait_status(16#80#, "idle after readback");

		-- 5. out-of-range LBA rejected; error clears on next good command
		set_lba(NBLK);
		io_write(1, 0);
		tick(10);
		expect_status(16#84#, "LBA out of range");
		assert hps_reads = 2 report "HPS read for out-of-range LBA" severity failure;
		set_lba(0);
		io_write(1, 0);
		tick(2);
		for i in 0 to 511 loop
			wait_status(16#E0#, "blk0 byte " & integer'image(i));
			io_read(0, d);
			assert d = to_integer(unsigned(image(i))) report "read blk0" severity failure;
		end loop;
		wait_status(16#80#, "idle after blk0 (error cleared)");

		-- 6. CPU reset in the middle of a transfer returns to idle; image stays mounted
		set_lba(3);
		io_write(1, 0);
		wait_status(16#E0#, "pre-reset");
		io_read(0, d);
		n_reset <= '0';  tick(4);  n_reset <= '1';  tick(4);
		expect_status(16#80#, "idle after CPU reset (still mounted)");
		io_read(5, d);  assert d = NBLK report "size kept over reset" severity failure;
		tick(200);

		-- 7. read-only image: writes rejected, reads ok
		mount(to_unsigned(NBLK*512, 64), '1');
		expect_status(16#88#, "read-only mounted");
		set_lba(1);
		io_write(1, 1);
		tick(10);
		expect_status(16#8C#, "write to read-only rejected");
		assert hps_writes = 1 report "HPS write to read-only image" severity failure;

		-- 8. large image: size saturates at $FFFFFF
		mount(shift_left(to_unsigned(1, 64), 33) + 512, '0');           -- 8 GB + 512
		io_read(5, d);  assert d = 255 report "sat size0" severity failure;
		io_read(6, d);  assert d = 255 report "sat size1" severity failure;
		io_read(7, d);  assert d = 255 report "sat size2" severity failure;

		-- 9. exact 2 GB image: 4M blocks = $400000
		mount(shift_left(to_unsigned(1, 64), 31), '0');
		io_read(5, d);  assert d = 0   report "2G size0" severity failure;
		io_read(6, d);  assert d = 0   report "2G size1" severity failure;
		io_read(7, d);  assert d = 64  report "2G size2" severity failure;

		-- 10. unmount (size 0)
		mount(to_unsigned(0, 64), '0');
		expect_status(16#90#, "unmounted again");
		io_read(5, d);  assert d = 0 report "size after unmount" severity failure;

		-- activity LED decays
		tick(300);
		assert activity = '0' report "activity stuck" severity failure;

		report "PASS: tb_hps_blockdev";
		done <= true;
		wait;
	end process;

end sim;

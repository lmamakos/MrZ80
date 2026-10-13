-- hps_blockdev: block storage device backed by an image file on the MiSTer
-- Linux (HPS) side.
--
-- The Z-80 sees the SAME register layout as sd_controller.vhd (SDHC-style
-- block addressing), so a driver for the SPI SD card can be reused almost
-- unchanged, but there is no SPI and no SD-card protocol here: the device
-- asks the HPS (via hps_io's sd_rd/sd_wr/sd_ack/sd_buff_* block interface)
-- to move one 512-byte block between the mounted image and an internal
-- sector buffer.
--
-- Register map (offset from the device's base port, e.g. $90):
--
--    0   DATA     R/W  sector data, sequential (auto-advancing)
--    1   STATUS   R    see below
--    1   CONTROL  W    $00 = read block, $01 = write block
--    2   LBA0     W    block number bits  7:0
--    3   LBA1     W    block number bits 15:8
--    4   LBA2     W    block number bits 23:16
--    5   SIZE0    R    image size in 512-byte blocks, bits  7:0
--    6   SIZE1    R                                   bits 15:8
--    7   SIZE2    R                                   bits 23:16
--
--    Size saturates at $FFFFFF blocks (8 GB). It reads 0 with no image.
--
-- STATUS (same bit meanings as sd_controller where they overlap):
--    b7  write byte can be accepted (idle, or filling the write buffer)
--    b6  read byte available
--    b5  block busy (a command is in progress)
--    b4  "init busy": NO IMAGE MOUNTED (reads $90 until an image is mounted)
--    b3  mounted image is read-only
--    b2  last command was rejected (no image, LBA >= size, or write to a
--        read-only image). Cleared by the next accepted command.
--    b1:0  0
--
-- To read block N:
--    wait STATUS = $80; write LBA0..2; write $00 to CONTROL;
--    512 times: wait STATUS = $E0, read DATA.   (then STATUS returns to $80)
-- To write block N:
--    wait STATUS = $80; write LBA0..2; write $01 to CONTROL;
--    512 times: wait STATUS = $A0, write DATA.  (device then writes the
--    block to the image; STATUS = $20 while that completes, then $80)
--
-- Timing / clocking: everything runs on clk (clk_sys). The CPU strobes
-- n_rd/n_wr are treated as ordinary synchronous signals (edge detected on
-- clk), NOT used as clocks. hps_io is clocked by the same clk (clk_sys) in
-- MrZ80.sv, so its signals are synchronous and are sampled directly, with
-- the sd_ack handshake edge-detected through a short shift register. The mounted-image info persists across CPU resets (the
-- HPS only reports a mount once).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hps_blockdev is
generic (
	LED_CYCLES : integer := 1000000   -- activity stretch, clk cycles (20 ms @ 50 MHz)
);
port (
	clk      : in  std_logic;
	n_reset  : in  std_logic;

	-- CPU side (strobes are active low and already qualified by chip select)
	n_rd     : in  std_logic;
	n_wr     : in  std_logic;
	dataIn   : in  std_logic_vector(7 downto 0);
	dataOut  : out std_logic_vector(7 downto 0);
	regAddr  : in  std_logic_vector(2 downto 0);

	-- hps_io block interface
	sd_lba       : out std_logic_vector(31 downto 0);
	sd_rd        : out std_logic;
	sd_wr        : out std_logic;
	sd_ack       : in  std_logic;
	sd_buff_addr : in  std_logic_vector(8 downto 0);
	sd_buff_dout : in  std_logic_vector(7 downto 0);   -- HPS -> device
	sd_buff_din  : out std_logic_vector(7 downto 0);   -- device -> HPS
	sd_buff_wr   : in  std_logic;

	-- hps_io image mount notification
	img_mounted  : in  std_logic;
	img_readonly : in  std_logic;
	img_size     : in  std_logic_vector(63 downto 0);

	-- high while a command is in progress and for LED_CYCLES afterwards
	activity     : out std_logic
);
end hps_blockdev;

architecture rtl of hps_blockdev is

	type state_t is (S_IDLE, S_RD_REQ, S_RD_DATA, S_WR_FILL, S_WR_REQ);
	signal state : state_t := S_IDLE;

	-- sector buffer (single simple-dual-port RAM; the two users of each port
	-- are never active in the same state, see the address/data muxes below)
	type ram_t is array (0 to 511) of std_logic_vector(7 downto 0);
	signal mem    : ram_t := (others => (others => '0'));
	signal ram_q  : std_logic_vector(7 downto 0) := (others => '0');
	signal ram_we : std_logic;
	signal ram_wa : unsigned(8 downto 0);
	signal ram_wd : std_logic_vector(7 downto 0);
	signal ram_ra : unsigned(8 downto 0);

	signal ptr    : unsigned(8 downto 0) := (others => '0');

	-- CPU strobe edge detection
	signal wr_d1, wr_d2 : std_logic := '0';
	signal rd_d1, rd_d2 : std_logic := '0';
	signal wr_pulse     : std_logic;
	signal rd_end       : std_logic;
	signal rd_addr_q    : std_logic_vector(2 downto 0) := (others => '0');

	-- HPS handshake
	signal ack_s    : std_logic_vector(3 downto 0) := (others => '0');
	signal ack_rise : std_logic;
	signal ack_fall : std_logic;
	signal ack_seen : std_logic := '0';
	signal sd_rd_r  : std_logic := '0';
	signal sd_wr_r  : std_logic := '0';

	-- registers
	signal lba      : unsigned(23 downto 0) := (others => '0');
	signal req_lba  : unsigned(23 downto 0) := (others => '0');
	signal err      : std_logic := '0';

	-- mounted image info (not cleared by CPU reset)
	signal mounted  : std_logic := '0';
	signal readonly : std_logic := '0';
	signal blocks   : unsigned(23 downto 0) := (others => '0');
	signal mnt_d    : std_logic := '0';
	signal mnt_evt  : std_logic;

	signal status   : std_logic_vector(7 downto 0);
	signal led_cnt  : integer range 0 to LED_CYCLES := 0;

begin

	wr_pulse <= wr_d1 and not wr_d2;       -- 2nd clk of a write strobe
	rd_end   <= rd_d2 and not rd_d1;       -- strobe just ended
	ack_rise <= ack_s(2) and not ack_s(3);
	ack_fall <= ack_s(3) and not ack_s(2);
	mnt_evt  <= img_mounted and not mnt_d;

	-- ---------------------------------------------------------------- RAM
	ram_we <= '1' when (state = S_WR_FILL and wr_pulse = '1' and regAddr = "000")
	               or  (state = S_RD_REQ and sd_ack = '1' and sd_buff_wr = '1')
	          else '0';
	ram_wa <= ptr when state = S_WR_FILL else unsigned(sd_buff_addr);
	ram_wd <= dataIn when state = S_WR_FILL else sd_buff_dout;
	ram_ra <= unsigned(sd_buff_addr) when state = S_WR_REQ else ptr;

	ram_proc : process(clk)
	begin
		if rising_edge(clk) then
			if ram_we = '1' then
				mem(to_integer(ram_wa)) <= ram_wd;
			end if;
			ram_q <= mem(to_integer(ram_ra));
		end if;
	end process;

	sd_buff_din <= ram_q;
	sd_lba      <= x"00" & std_logic_vector(req_lba);
	sd_rd       <= sd_rd_r;
	sd_wr       <= sd_wr_r;

	-- ------------------------------------------------------------- status
	process(state, mounted, readonly, err)
	begin
		status <= x"00";
		if mounted = '0' then
			status <= x"90";                        -- no image: "init busy"
		else
			case state is
				when S_IDLE    => status <= x"80";
				when S_WR_FILL => status <= x"A0";
				when S_RD_DATA => status <= x"E0";
				when others    => status <= x"20";  -- waiting for HPS
			end case;
			status(3) <= readonly;
		end if;
		status(2) <= err;
	end process;

	process(regAddr, ram_q, status, blocks, mounted)
	begin
		case regAddr is
			when "000" => dataOut <= ram_q;
			when "001" => dataOut <= status;
			when "101" => dataOut <= std_logic_vector(blocks(7 downto 0));
			when "110" => dataOut <= std_logic_vector(blocks(15 downto 8));
			when "111" => dataOut <= std_logic_vector(blocks(23 downto 16));
			when others => dataOut <= x"00";
		end case;
	end process;

	-- ------------------------------------------------------------ control
	main : process(clk)
	begin
		if rising_edge(clk) then
			wr_d1 <= not n_wr;  wr_d2 <= wr_d1;
			rd_d1 <= not n_rd;  rd_d2 <= rd_d1;
			ack_s <= ack_s(2 downto 0) & sd_ack;
			mnt_d <= img_mounted;

			if rd_d1 = '1' and rd_d2 = '0' then
				rd_addr_q <= regAddr;          -- address at start of the access
			end if;

			-- mounted-image info: img_size/img_readonly are valid while
			-- img_mounted is high; image size 0 means "unmounted".
			if img_mounted = '1' then
				if unsigned(img_size) /= 0 then
					mounted <= '1';
				else
					mounted <= '0';
				end if;
				readonly <= img_readonly;
				if unsigned(img_size(63 downto 33)) /= 0 then
					blocks <= (others => '1');
				else
					blocks <= unsigned(img_size(32 downto 9));
				end if;
			end if;

			-- LBA registers: writable any time (latched again at command time)
			if wr_pulse = '1' then
				case regAddr is
					when "010"  => lba(7 downto 0)   <= unsigned(dataIn);
					when "011"  => lba(15 downto 8)  <= unsigned(dataIn);
					when "100"  => lba(23 downto 16) <= unsigned(dataIn);
					when others => null;
				end case;
			end if;

			if n_reset = '0' or mnt_evt = '1' then
				state    <= S_IDLE;
				sd_rd_r  <= '0';
				sd_wr_r  <= '0';
				ack_seen <= '0';
				ptr      <= (others => '0');
				err      <= '0';
			else
				case state is

					when S_IDLE =>
						if wr_pulse = '1' and regAddr = "001" then
							if dataIn = x"00" or dataIn = x"01" then
								if mounted = '0' or lba >= blocks
								   or (dataIn = x"01" and readonly = '1') then
									err <= '1';                -- rejected
								else
									err     <= '0';
									req_lba <= lba;
									ptr     <= (others => '0');
									ack_seen <= '0';
									if dataIn = x"00" then
										sd_rd_r <= '1';
										state   <= S_RD_REQ;
									else
										state   <= S_WR_FILL;
									end if;
								end if;
							end if;
						end if;

					when S_RD_REQ | S_WR_REQ =>
						if ack_rise = '1' then
							ack_seen <= '1';
						end if;
						if ack_fall = '1' and ack_seen = '1' then
							ack_seen <= '0';
							ptr      <= (others => '0');
							sd_rd_r  <= '0';
							sd_wr_r  <= '0';
							if state = S_RD_REQ then
								state <= S_RD_DATA;
							else
								state <= S_IDLE;
							end if;
						end if;

					when S_RD_DATA =>
						if rd_end = '1' and rd_addr_q = "000" then
							if ptr = 511 then
								ptr   <= (others => '0');
								state <= S_IDLE;
							else
								ptr <= ptr + 1;
							end if;
						end if;

					when S_WR_FILL =>
						if wr_pulse = '1' and regAddr = "000" then
							if ptr = 511 then
								ptr      <= (others => '0');
								ack_seen <= '0';
								sd_wr_r  <= '1';
								state    <= S_WR_REQ;
							else
								ptr <= ptr + 1;
							end if;
						end if;

				end case;
			end if;

			-- activity indicator
			if state /= S_IDLE then
				led_cnt <= LED_CYCLES;
			elsif led_cnt /= 0 then
				led_cnt <= led_cnt - 1;
			end if;
		end if;
	end process;

	activity <= '1' when state /= S_IDLE or led_cnt /= 0 else '0';

end rtl;

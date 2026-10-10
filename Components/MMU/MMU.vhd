--+-----------------------------------+-------------------------------------+--
--|                      ___   ___    | (c) 2013-2014 William R Sowerbutts  |--
--|   ___  ___   ___ ___( _ ) / _ \   | will@sowerbutts.com                 |--
--|  / __|/ _ \ / __|_  / _ \| | | |  |                                     |--
--|  \__ \ (_) | (__ / / (_) | |_| |  | A Z80 FPGA computer, just for fun   |--
--|  |___/\___/ \___/___\___/ \___/   |                                     |--
--|                                   |              http://sowerbutts.com/ |--
--+-----------------------------------+-------------------------------------+--
--| 16K paged Memory Management Unit: Translates 16-bit virtual addresses   |--
--| from the CPU into (physical_page_bits + 14) bit physical addresses to   |--
--| allow more memory to be addressed. Also has a "direct access" window    |--
--| that lets unmapped physical memory be accessed through an IO port which |--
--| synthesises memory operations.                                          |--
--+-------------------------------------------------------------------------+--
--
-- The MMU takes a 16-bit virtual address from the CPU and divides it into a
-- 2-bit frame number and a 14-bit offset. The frame number is used as an index
-- into an array of four mapping registers which contain the hardware page
-- numbers (the translation table). The physical address is formed from the
-- hardware page number concatenated with the 14-bit offset.
--
-- The width of each mapping register (and therefore of the physical address
-- bus) is controlled by the generic physical_page_bits. The default value 8
-- gives a 22-bit (4 MB) physical address space, compatible with the "Z2" MMU
-- model used by RomWBW. Larger values widen the physical address space and
-- enable the extension I/O ports described below.
--
-- I/O REGISTER MAP
-- ----------------
-- The MMU presents a window of 16 consecutive I/O ports. The base address of
-- that window is set entirely by the external I/O decoder that drives the
-- io_cs input; this module only looks at the low four address bits to pick
-- a register within the window. The integrator should align the window on a
-- 16-port boundary (i.e. the four low address bits should be a clean offset
-- into the window).
--
--   offset  function (write)                  function (read)
--   ------  -------------------------------- ---------------------------------
--   +0      Frame 0 mapping reg, bits  7:0   Frame 0 mapping reg, bits  7:0
--   +1      Frame 1 mapping reg, bits  7:0   Frame 1 mapping reg, bits  7:0
--   +2      Frame 2 mapping reg, bits  7:0   Frame 2 mapping reg, bits  7:0
--   +3      Frame 3 mapping reg, bits  7:0   Frame 3 mapping reg, bits  7:0
--   +4      Frame 0 mapping reg, bits 15:8   Frame 0 mapping reg, bits 15:8
--   +5      Frame 1 mapping reg, bits 15:8   Frame 1 mapping reg, bits 15:8
--   +6      Frame 2 mapping reg, bits 15:8   Frame 2 mapping reg, bits 15:8
--   +7      Frame 3 mapping reg, bits 15:8   Frame 3 mapping reg, bits 15:8
--   +8      Direct access pointer, bits  7:0
--   +9      Direct access pointer, bits 15:8
--   +10     Direct access pointer, bits 23:16
--   +11     Direct access pointer, bits 31:24
--   +12     Direct access data port (R/W triggers a physical memory access at
--           the pointer; pointer post-increments after the access)
--   +13..+15  reserved (writes ignored, reads return 0x00)
--
-- Ports +0..+3 are binary-compatible with the RomWBW "Z2" MMU: each frame's
-- physical page number sits in its own port, no selector mux is needed. With
-- physical_page_bits = 8 (the default) this covers the full mapping register
-- and ports +4..+7 read as 0 / ignore writes.
--
-- When physical_page_bits > 8, ports +4..+7 expose the upper bits of the
-- mapping registers (bits 15:8). The on-write behaviour only updates bits
-- that actually exist in the register; the rest of the byte is dropped. On
-- read, bits past physical_page_bits-1 read as 0.
--
-- Z2 COMPATIBILITY OF THE LOW-BYTE WRITE
-- --------------------------------------
-- Writing a frame's low byte (+0..+3) clears the whole mapping register
-- first, so the high byte (bits 15:8) is forced to 0. This means software
-- written for the original 8-bit Z2 MMU -- which only ever writes the low
-- byte -- always selects a page in the low 256, no matter what the high
-- byte happened to contain beforehand. To address a page above 255, write
-- the low byte (+0..+3) FIRST and then the high byte (+4..+7); writing the
-- high byte does not disturb the low byte.
--
-- DIRECT ACCESS WINDOW
-- --------------------
-- The direct access window (port +12) lets code read and write physical
-- memory without remapping any logical frame; this is convenient when the
-- code/stack/source/target pointers would otherwise force a remap. To use it,
-- the program first writes the desired physical address into the four
-- pointer-byte ports (+8..+11, little-endian: low byte first), then issues
-- a read or write to port +12. The MMU rewrites that I/O cycle into a
-- physical memory cycle to the pointer address, then post-increments the
-- pointer so that INIR/OUTIR-style block transfers walk forward through
-- physical memory.
--
-- The pointer is (physical_page_bits + 14) bits wide. Bits beyond that read
-- as 0; writes to those bits are dropped.
--
-- A forced CPU wait state is inserted when port +12 is accessed so the
-- synchronous memory has a cycle to read the new address off the bus.
--
-- RESET MAPPING / BLOCK-RAM RELOCATION
-- ------------------------------------
-- The on-chip block RAM is no longer placed at physical page 0 (it used to
-- shadow the bottom of the physical address space). It is relocated to its
-- own physical page given by the generic block_ram_page, above the SDRAM
-- region, so the full SDRAM is contiguously addressable with no shadowing.
-- At reset the map points logical frame 0 at block_ram_page (so the Z-80
-- boots from block RAM at logical 0x0000) and frames 1..3 at SDRAM physical
-- pages 1..3. The bin_loaded input overrides frame 0 to SDRAM physical page
-- 0 when a .BIN boot image has been loaded into SDRAM, so it boots from
-- 0x0000 instead. This default-mapping mechanism replaces the former
-- external "force block RAM on/off" control signals.
--

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity MMU is
    generic(
        -- Width of each mapping register in bits. 8 gives a Z2-compatible
        -- 4 MB physical address space; larger values widen the physical
        -- address bus and enable the extension I/O ports at offsets +4..+7.
        -- Legal range: 8..32.
        physical_page_bits : integer := 8;

        -- Physical page number of the relocated on-chip block RAM. The
        -- block RAM no longer shadows the bottom of the physical address
        -- space; it is placed at its own page above the SDRAM region. With
        -- physical_page_bits = 14 (256 MB / 16384 pages) and the block RAM
        -- relocated to physical 0x8000000 (just above the 128 MB SDRAM),
        -- this is page 8192. The reset map points frame 0 here so the Z-80
        -- boots from block RAM at logical 0x0000.
        block_ram_page     : integer := 8192
    );
    port(
        clk             : in  std_logic;
        reset           : in  std_logic;
        address_in      : in  std_logic_vector(15 downto 0);
        address_out     : out std_logic_vector(physical_page_bits + 14 - 1 downto 0);
        cpu_data_in     : in  std_logic_vector(7 downto 0);
        cpu_data_out    : out std_logic_vector(7 downto 0);
        cpu_wait        : out std_logic;
        req_mem_in      : in  std_logic;
        req_mem_out     : out std_logic;
        req_io_in       : in  std_logic;
        req_io_out      : out std_logic;
        io_cs           : in  std_logic;
        req_read        : in  std_logic;
        req_write       : in  std_logic;
        -- Boot-source select for the reset mapping. When low (default), the
        -- reset map points logical frame 0 at the relocated on-chip block
        -- RAM page (block_ram_page) so the Z-80 fetches its first
        -- instructions from block RAM at logical 0x0000. When high (a .BIN
        -- boot image has been loaded into SDRAM), the reset map points frame
        -- 0 at SDRAM physical page 0 instead, so the loaded image boots from
        -- 0x0000. This replaces the former external "force block RAM on/off"
        -- control signals: the boot source is now chosen purely by the
        -- default MMU mapping.
        bin_loaded      : in  std_logic := '0'
    );
end MMU;

architecture behaviour of MMU is

    -- Width of the physical address bus (and of the direct access pointer).
    constant phys_addr_bits : integer := physical_page_bits + 14;

    -- Storage for the 4 mapping registers.
    type mmu_frame_array is array(natural range <>) of std_logic_vector(physical_page_bits - 1 downto 0);
    signal mmu_frame : mmu_frame_array(0 to 3);

    -- Direct access pointer, sized to the physical address space.
    signal direct_access_pointer : std_logic_vector(phys_addr_bits - 1 downto 0);

    -- Break up the incoming virtual address: top 2 bits select a frame,
    -- low 14 bits are the offset within the 16K page.
    alias frame_number : std_logic_vector( 1 downto 0) is address_in(15 downto 14);
    alias page_offset  : std_logic_vector(13 downto 0) is address_in(13 downto  0);

    -- I/O window offset within the 16-port chip-select region.
    alias io_offset    : std_logic_vector( 3 downto 0) is address_in( 3 downto  0);

    signal map_io_to_direct     : std_logic;
    signal was_map_io_to_direct : std_logic := '0';

    -- Helper: zero-pad a byte's worth of value into the variable-width
    -- "upper" portion of a mapping register (bits 15:8 visible at the port,
    -- but only physical_page_bits-1 downto 8 actually exist).
    function read_upper_byte(v : std_logic_vector) return std_logic_vector is
        variable result : std_logic_vector(7 downto 0) := (others => '0');
    begin
        if v'length > 8 then
            for i in 0 to 7 loop
                if (i + 8) <= v'high then
                    result(i) := v(i + 8);
                end if;
            end loop;
        end if;
        return result;
    end function;

begin

    -- The direct access data port lives at offset +12 within the MMU's
    -- 16-port chip-select region. The base address of that region is set by
    -- the external I/O decoder that drives io_cs; this block only checks
    -- that io_cs is asserted and that the low four address bits select
    -- offset +12.
    map_io_to_mem_proc: process(io_cs, io_offset, req_mem_in, req_io_in)
    begin
        if req_mem_in = '0' and req_io_in = '1' and io_cs = '1'
           and io_offset = "1100" then
            map_io_to_direct <= '1';
        else
            map_io_to_direct <= '0';
        end if;
    end process;

    with map_io_to_direct select
        address_out <=
                      mmu_frame(to_integer(unsigned(frame_number))) & page_offset when '0',
                      direct_access_pointer when others;

    with map_io_to_direct select
        req_mem_out <=
                      req_mem_in when '0',
                      '1' when others;

    with map_io_to_direct select
        req_io_out <=
                      req_io_in when '0',
                      '0' when others;

    -- Force CPU to wait one cycle when we map IO to memory access; this
    -- gives synchronous memory a cycle to read the address, look up the
    -- data, and provide a result.
    cpu_wait <= map_io_to_direct and (not was_map_io_to_direct);

    -- Read-back path: select the appropriate register based on io_offset.
    data_out: process(io_offset, mmu_frame, direct_access_pointer)
        variable ptr_byte : std_logic_vector(7 downto 0);
        variable lo       : integer;
    begin
        case io_offset is
            -- Mapping register low bytes (Z2 compatible)
            when "0000" => cpu_data_out <= mmu_frame(0)(7 downto 0);
            when "0001" => cpu_data_out <= mmu_frame(1)(7 downto 0);
            when "0010" => cpu_data_out <= mmu_frame(2)(7 downto 0);
            when "0011" => cpu_data_out <= mmu_frame(3)(7 downto 0);

            -- Mapping register upper bytes (extension; reads 0 when the
            -- mapping register is only 8 bits wide).
            when "0100" => cpu_data_out <= read_upper_byte(mmu_frame(0));
            when "0101" => cpu_data_out <= read_upper_byte(mmu_frame(1));
            when "0110" => cpu_data_out <= read_upper_byte(mmu_frame(2));
            when "0111" => cpu_data_out <= read_upper_byte(mmu_frame(3));

            -- Direct access pointer bytes (little-endian). Bits beyond the
            -- pointer width read as 0.
            when "1000" | "1001" | "1010" | "1011" =>
                ptr_byte := (others => '0');
                lo := to_integer(unsigned(io_offset(1 downto 0))) * 8;
                for i in 0 to 7 loop
                    if (lo + i) <= direct_access_pointer'high then
                        ptr_byte(i) := direct_access_pointer(lo + i);
                    end if;
                end loop;
                cpu_data_out <= ptr_byte;

            -- Direct access data port +12: handled by the address-translation
            -- mux above. The byte that comes back on the CPU data bus is
            -- whatever the memory subsystem returns, not anything we drive.
            -- Reads of +12 should not be served from this process. Return 0
            -- as a safe default so the read-back path is fully defined.
            when others =>
                cpu_data_out <= (others => '0');
        end case;
    end process;

    -- Write path and state updates.
    mmu_registers: process(clk)
        variable lo : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Reset mapping. The on-chip block RAM has been relocated to
                -- its own physical page (block_ram_page) above the SDRAM
                -- region; it no longer shadows physical page 0. To keep the
                -- Z-80 booting from 0x0000 the default map points logical
                -- frame 0 at the block RAM page, and frames 1..3 at SDRAM
                -- physical pages 1..3 (so logical 0x4000..0xFFFF is SDRAM low
                -- memory).
                --
                -- When bin_loaded = '1' a .BIN boot image has been written
                -- into SDRAM at physical 0x0000, so frame 0 instead maps to
                -- SDRAM physical page 0 and the image boots from 0x0000. This
                -- replaces the former external block-RAM enable/disable
                -- control signals.
                if bin_loaded = '1' then
                    mmu_frame(0) <= (others => '0');               -- SDRAM page 0
                else
                    mmu_frame(0) <= std_logic_vector(to_unsigned(block_ram_page, physical_page_bits));
                end if;
                mmu_frame(1) <= std_logic_vector(to_unsigned(1, physical_page_bits));  -- SDRAM page 1
                mmu_frame(2) <= std_logic_vector(to_unsigned(2, physical_page_bits));  -- SDRAM page 2
                mmu_frame(3) <= std_logic_vector(to_unsigned(3, physical_page_bits));  -- SDRAM page 3
                direct_access_pointer <= (others => '0');
                was_map_io_to_direct  <= '0';
            else
                was_map_io_to_direct <= map_io_to_direct;

                if io_cs = '1' and req_write = '1' then
                    case io_offset is
                        -- Z2-compatible mapping register low bytes.
                        --
                        -- Writing the low byte clears the entire register
                        -- first, so any high-order page bits (present only
                        -- when physical_page_bits > 8) are zeroed. This
                        -- maximises compatibility with the Z2 MMU: code that
                        -- only knows about the 8-bit page number can write the
                        -- low byte and always land on a page in the low 256,
                        -- regardless of whatever was previously left in the
                        -- high byte. To select a page above 255, write the
                        -- high byte (+4..+7) AFTER the low byte.
                        when "0000" =>
                            mmu_frame(0) <= (others => '0');
                            mmu_frame(0)(7 downto 0) <= cpu_data_in;
                        when "0001" =>
                            mmu_frame(1) <= (others => '0');
                            mmu_frame(1)(7 downto 0) <= cpu_data_in;
                        when "0010" =>
                            mmu_frame(2) <= (others => '0');
                            mmu_frame(2)(7 downto 0) <= cpu_data_in;
                        when "0011" =>
                            mmu_frame(3) <= (others => '0');
                            mmu_frame(3)(7 downto 0) <= cpu_data_in;

                        -- Mapping register upper bytes (extension). Only the
                        -- bits that actually exist in the register are
                        -- updated; the rest of the byte is dropped.
                        when "0100" | "0101" | "0110" | "0111" =>
                            if physical_page_bits > 8 then
                                for i in 0 to 7 loop
                                    if (i + 8) <= mmu_frame(0)'high then
                                        case io_offset(1 downto 0) is
                                            when "00" => mmu_frame(0)(i + 8) <= cpu_data_in(i);
                                            when "01" => mmu_frame(1)(i + 8) <= cpu_data_in(i);
                                            when "10" => mmu_frame(2)(i + 8) <= cpu_data_in(i);
                                            when others => mmu_frame(3)(i + 8) <= cpu_data_in(i);
                                        end case;
                                    end if;
                                end loop;
                            end if;

                        -- Direct access pointer bytes (little-endian)
                        when "1000" | "1001" | "1010" | "1011" =>
                            lo := to_integer(unsigned(io_offset(1 downto 0))) * 8;
                            for i in 0 to 7 loop
                                if (lo + i) <= direct_access_pointer'high then
                                    direct_access_pointer(lo + i) <= cpu_data_in(i);
                                end if;
                            end loop;

                        when others =>
                            -- +12 is the direct-access data port (handled by
                            -- the bus rewrite above, not by this register
                            -- file). +13..+15 are reserved.
                            null;
                    end case;

                elsif map_io_to_direct = '0' and was_map_io_to_direct = '1' then
                    -- Post-increment the direct access pointer once the
                    -- synthesised memory cycle has completed.
                    direct_access_pointer <= std_logic_vector(unsigned(direct_access_pointer) + 1);
                end if;
            end if;
        end if;
    end process;
end;

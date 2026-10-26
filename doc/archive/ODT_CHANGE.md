> **ARCHIVED 2026-10-23.** Historical handoff only — superseded by
> `doc/SSP_DESIGN.md` (v0.6) and fact-corrected by
> `doc/SSP_RISCV_REVIEW.md`; see `doc/archive/README.md`. Do not implement
> from this document or its `z80_bus_monitor.v` sketch.

RISC-V VexRiscv & Mecrisp-Quintus Debug Monitor Handoff Document

Target Platform: Intel Cyclone V FPGA (MiSTer MultiComp Framework)

Host Subsystem: T80 Z80 Soft-Core running RomWBW + 128MB SDRAM MMU

Monitor Core: VexRiscv (RV32IMC) running Mecrisp-Quintus FORTH

Memory Budget: 16KB Block RAM ROM (0x0000_0000) / 16KB Block RAM RAM (0x1000_0000)
1. Action Items & To-Do Roadmap
Task 1: Hardware & RTL Integration (FPGA)

    [ ] VexRiscv Core Generation: Build RV32IMC core with SpinalHDL (M-Mode, CSRs, Timer/External IRQs, SimpleBus interface).

    [ ] Subsystem Memory Mapping: Instantiate 16KB ROM (forth_rom.hex) and 16KB RAM using Cyclone V M10K blocks with byte-enable controls.

    [ ] MMIO Peripheral Integration: Integrate the z80_bus_monitor module at base address 0x2000_0000.

    [ ] SDRAM Controller Dual-Porting: Hook VexRiscv to an unused port on the MultiComp SDRAM controller to enable direct 128MB RAM inspection without stalling the T80.

Task 2: Mecrisp-Quintus Assembly & Build Pipeline

    [ ] Linker Script Setup: Finalize linker.ld for 16KB ROM / 16KB RAM boundaries.

    [ ] Reset Vector & Stacks: Validate vector initialization code, BSS clearing, and stack setup (s0 = DSP, s1 = RSP).

    [ ] UART Terminal Hooks: Wire Mecrisp's serial-key, serial-emit, and serial-key? primitives to the MMIO UART registers.

    [ ] Build Toolchain: Execute build script to assemble .elf, extract .bin, and convert to forth_rom.hex via bin2hex.py.

Task 3: RomWBW Debugging Suite (FORTH Software)

    [ ] Base Hardware Words: Test z80-reset, z80-halt, z80-run, and z80-probe.

    [ ] HBIOS Inspection Tooling: Write FORTH words to parse RomWBW page table registers and decode 16-bit logical to 27-bit physical SDRAM mappings.

    [ ] Live Bus Tracing: Implement breakpoint/match triggers for Z80 I/O port writes and HBIOS traps.

2. Hardware Interface Code (Verilog RTL)
z80_bus_monitor.v
Verilog

// ============================================================================
// MMIO Module: Z80 Bus Debugger & Monitor for RISC-V VexRiscv
// Memory Space: 0x2000_0000 - 0x2000_001F
// ============================================================================

module z80_bus_monitor (
    input  wire        clk,            // System Clock (FPGA main clock)
    input  wire        reset,          // Active-high reset
    
    // ------------------------------------------------------------------------
    // SimpleBus MMIO Interface (From VexRiscv / Address Decoder)
    // ------------------------------------------------------------------------
    input  wire        bus_valid,      // MMIO Chip Select
    input  wire        bus_write,      // Write enable
    input  wire [5:0]  bus_addr,       // Offset [5:0] from base address 0x2000_0000
    input  wire [31:0] bus_wdata,      // Write data from RISC-V
    output reg  [31:0] bus_rdata,      // Read data to RISC-V
    
    // ------------------------------------------------------------------------
    // Z80 Physical / T80 CPU & MMU Interface
    // ------------------------------------------------------------------------
    input  wire [15:0] z80_addr_in,    // Z80 Logical Address Bus (sampled)
    input  wire [26:0] mmu_phys_addr_in,// 27-bit Physical SDRAM Address from MMU
    inout  wire [7:0]  z80_data_bus,   // Z80 Data Bus
    
    // Inputs from T80 CPU
    input  wire        z80_m1_n,       // Machine Cycle 1 (active low)
    input  wire        z80_mreq_n,     // Memory Request (active low)
    input  wire        z80_iorq_n,     // I/O Request (active low)
    input  wire        z80_rd_n,       // Read Strobe (active low)
    input  wire        z80_wr_n,       // Write Strobe (active low)
    input  wire        z80_busack_n,   // Z80 Bus Acknowledge (active low)
    input  wire        z80_halt_n,     // Z80 Halt State (active low)

    // Outputs to T80 CPU
    output reg         z80_reset_n,    // Reset Z80 CPU
    output reg         z80_busreq_n,   // Request Z80 bus control (DMA)
    output reg         z80_wait_n      // Pause Z80 execution
);

    // Synchronizers & Edge Detectors for Async/Cross-Domain Z80 Signals
    reg [2:0] m1_sync, mreq_sync, iorq_sync, wr_sync, rd_sync;

    always @(posedge clk) begin
        if (reset) begin
            m1_sync   <= 3'b111;
            mreq_sync <= 3'b111;
            iorq_sync <= 3'b111;
            wr_sync   <= 3'b111;
            rd_sync   <= 3'b111;
        end else begin
            m1_sync   <= {m1_sync[1:0],   z80_m1_n};
            mreq_sync <= {mreq_sync[1:0], z80_mreq_n};
            iorq_sync <= {iorq_sync[1:0], z80_iorq_n};
            wr_sync   <= {wr_sync[1:0],   z80_wr_n};
            rd_sync   <= {rd_sync[1:0],   z80_rd_n};
        end
    end

    wire m1_asserted   = (m1_sync[2:1]   == 2'b10);
    wire mreq_asserted = (mreq_sync[2:1] == 2'b10);
    wire iorq_asserted = (iorq_sync[2:1] == 2'b10);

    // Latched Bus & Trace Registers
    reg [15:0] latched_addr;
    reg [26:0] latched_phys_addr;
    reg [7:0]  latched_data;
    reg [7:0]  latched_ctrl;
    reg [31:0] cycle_counter;

    always @(posedge clk) begin
        if (reset) begin
            latched_addr      <= 16'h0000;
            latched_phys_addr <= 27'd0;
            latched_data      <= 8'h00;
            latched_ctrl      <= 8'h00;
            cycle_counter     <= 32'd0;
        end else begin
            if (m1_asserted) cycle_counter <= cycle_counter + 1'b1;

            if (mreq_asserted || iorq_asserted) begin
                latched_addr      <= z80_addr_in;
                latched_phys_addr <= mmu_phys_addr_in;
                latched_data      <= z80_data_bus;
                latched_ctrl      <= {
                    z80_halt_n,
                    z80_busack_n,
                    m1_sync[1],
                    mreq_sync[1],
                    iorq_sync[1],
                    rd_sync[1],
                    wr_sync[1],
                    1'b0
                };
            end
        end
    end

    // RISC-V Control Register Writes
    reg [7:0] ctrl_reg;

    always @(posedge clk) begin
        if (reset) begin
            ctrl_reg     <= 8'b0000_0111;
            z80_reset_n  <= 1'b1;
            z80_busreq_n <= 1'b1;
            z80_wait_n   <= 1'b1;
        end else if (bus_valid && bus_write && (bus_addr == 6'h00)) begin
            ctrl_reg     <= bus_wdata[7:0];
            z80_reset_n  <= bus_wdata[0];
            z80_busreq_n <= bus_wdata[1];
            z80_wait_n   <= bus_wdata[2];
        end
    end

    // MMIO Read Mux
    always @(*) begin
        case (bus_addr)
            6'h00: bus_rdata = {24'b0, ctrl_reg};                 // 0x2000_0000 : Control Flags
            6'h04: bus_rdata = {16'b0, z80_addr_in};              // 0x2000_0004 : Live Z80 Logical Addr
            6'h08: bus_rdata = {24'b0, z80_data_bus};             // 0x2000_0008 : Live Z80 Data
            6'h0C: bus_rdata = {16'b0, latched_addr};             // 0x2000_000C : Latched Logical Addr
            6'h10: bus_rdata = {24'b0, latched_data};             // 0x2000_0010 : Latched Data
            6'h14: bus_rdata = {24'b0, latched_ctrl};             // 0x2000_0014 : Status Bits
            6'h18: bus_rdata = cycle_counter;                     // 0x2000_0018 : M1 Cycle Count
            6'h1C: bus_rdata = {5'b0, latched_phys_addr};         // 0x2000_001C : Latched 27-bit SDRAM Addr
            default: bus_rdata = 32'h0000_0000;
        endcase
    end

endmodule

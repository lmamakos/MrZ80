// ssp_sdp_ram.v -- SIMULATION behavioral twin of ssp/rtl/ssp_sdp_ram.vhd
// (explicit M10K altsyncram IP wrapper, D-36; bake-off R21 proven shape).
// NOT part of the Quartus file set (MrZ80.qsf resolves the VHDL entity);
// this exists so the Verilator lane exercises the exact same launch+1
// read-latency contract: registered address read, q valid at launch+1,
// byte-enable write port.
//
// Hierarchy: sim path only (sim/ssp is the Verilator source dir; production
// ssp_top instantiates this module name against whichever language the
// flow includes).

`timescale 1 ns / 1 ps

module ssp_sdp_ram (
    input  wire [13:0] address_w,
    input  wire [13:0] address_r,
    input  wire        clock,
    input  wire [31:0] data_w,
    input  wire [3:0]  byteena,
    input  wire        wren,
    output reg  [31:0] q
);

    (* ramstyle = "M9K, logic" *) reg [31:0] mem [0:16383];

    always @(posedge clock) begin
        q <= mem[address_r];                 // launch+1 (D-36 fabric truth)
        if (wren) begin
            if (byteena[0]) mem[address_w][7:0]   <= data_w[7:0];
            if (byteena[1]) mem[address_w][15:8]  <= data_w[15:8];
            if (byteena[2]) mem[address_w][23:16] <= data_w[23:16];
            if (byteena[3]) mem[address_w][31:24] <= data_w[31:24];
        end
    end

endmodule

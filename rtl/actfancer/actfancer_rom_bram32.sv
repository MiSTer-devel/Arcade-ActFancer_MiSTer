// SPDX-License-Identifier: GPL-3.0-or-later
// 32-bit ROM in BRAM, populated via ioctl_download byte stream.
// 4 separate byte planes (M10K) read in parallel.
//
// Used for chars region (128KB → 32K × 32-bit words).
// Layout MAME chars 8x8 4bpp = RGN_FRAC(1,4): 4 planes from
// {0/4, 1/4, 2/4, 3/4} of the region. So:
//   plane 0 = bytes 0x00000..0x07FFF
//   plane 1 = bytes 0x08000..0x0FFFF
//   plane 2 = bytes 0x10000..0x17FFF
//   plane 3 = bytes 0x18000..0x1FFFF
// (vedi gfx_layout layout_8x8x4 in actfancr.cpp riga 308-317)

module actfancer_rom_bram32 #(
    parameter AW         = 15,           // word address width
    parameter START_ADDR = 25'h040000,   // ioctl byte offset start
    parameter ROM_SIZE   = 25'h020000    // ROM size in bytes
) (
    input               clk,

    // ioctl write side
    input               ioctl_download,
    input               ioctl_wr,
    input  [24:0]       ioctl_addr,
    input  [ 7:0]       ioctl_dout,
    input  [15:0]       ioctl_index,

    // 32-bit read side (4 planes packed: {p3, p2, p1, p0})
    input  [AW-1:0]     rom_addr,
    output reg [31:0]   rom_data
);
    // Plane size = ROM_SIZE / 4
    localparam [24:0] PLANE_SIZE = ROM_SIZE >> 2;

    reg [7:0] mem0 [0:(1<<AW)-1];
    reg [7:0] mem1 [0:(1<<AW)-1];
    reg [7:0] mem2 [0:(1<<AW)-1];
    reg [7:0] mem3 [0:(1<<AW)-1];

    wire [24:0] dl_off    = ioctl_addr - START_ADDR;
    wire        dl_in_range = ioctl_download && (ioctl_index == 16'd0)
                              && (ioctl_addr >= START_ADDR)
                              && (ioctl_addr < (START_ADDR + ROM_SIZE));

    wire [1:0]  dl_plane = dl_off[24:0] / PLANE_SIZE;     // 0..3 (sintetizzato come compare)
    wire [AW-1:0] dl_idx = dl_off[AW-1:0];                // offset all'interno del piano

    always @(posedge clk) begin
        if (dl_in_range && ioctl_wr) begin
            case (dl_plane)
                2'd0: mem0[dl_idx] <= ioctl_dout;
                2'd1: mem1[dl_idx] <= ioctl_dout;
                2'd2: mem2[dl_idx] <= ioctl_dout;
                2'd3: mem3[dl_idx] <= ioctl_dout;
            endcase
        end
        rom_data <= { mem3[rom_addr], mem2[rom_addr], mem1[rom_addr], mem0[rom_addr] };
    end
endmodule

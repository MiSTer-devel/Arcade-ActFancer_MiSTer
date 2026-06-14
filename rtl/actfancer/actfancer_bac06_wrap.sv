// SPDX-License-Identifier: GPL-3.0-or-later
// 8-bit → 16-bit wrapper around jtcop_bac06.
// ActFancer's H6280 main CPU is 8-bit; MAME accesses BAC06 via
//   pf_data_8bit_swap_w(): A0 selects high/low byte of the 16-bit word.
//
// We translate:
//   cpu_8bit_addr[12:0]  →  cpu_dout[15:0] / cpu_dsn[1:0] / cpu_addr[12:1]
// such that for A0=0 → write hi byte, A0=1 → write lo byte
// (the "swap" variant in MAME swaps endianness vs the plain one).

module actfancer_bac06_wrap #(parameter MASTER=0, REGION8_IS_16=0)
(
    input              rst,
    input              clk,
    input              clk_cpu,
    input              pxl2_cen,
    input              pxl_cen,

    // From actfancer_main
    input              mode_cs,
    input              vram_cs,
    input        [7:0] cpu_dout8,
    output       [7:0] cpu_din8,
    input       [12:1] cpu_addr,
    input              cpu_a0,
    input              cpu_we,        // 1 = write strobe

    // VRAM (4KB or 16KB) external BRAM, 16-bit
    output             ram_cs,
    output      [13:1] ram_addr,
    input       [15:0] ram_data,
    input              ram_ok,

    // tile ROM (graphics)
    output             rom_cs,
    output      [17:1] rom_addr,
    input       [31:0] rom_data,
    input              rom_ok,

    // pixel out
    output       [7:0] pxl,

    // timing (inout from master)
    inout              flip,
    inout        [8:0] vdump,
    inout        [8:0] vrender,
    inout        [8:0] hdump,
    inout              LHBL,
    inout              LVBL,
    inout              HS,
    inout              VS,
    inout              vload,
    inout              hinit,

    // OSD debug toggles (12 bit)
    input  [ 4:0] dbg_plane_perm,
    input         dbg_bit_reverse,
    input         dbg_nibble_swap,
    input         dbg_word16_swap,
    input         dbg_byte_swap_w16,
    input         dbg_pen_invert,
    input         dbg_pen_reverse
);

// MAME pf_data_8bit_swap_w (decbac06.cpp:625-660):
//   A0=0 → byte BASSO del word
//   A0=1 → byte ALTO  del word
// (validato in sim/tb_bac06_swap.sv)
//
// cpu_dsn è active-low byte enable.
//   A0=0 → dsn = 2'b10 (dsn[0]=0 ⇒ lo enabled, dsn[1]=1 ⇒ hi disabled)
//   A0=1 → dsn = 2'b01 (dsn[1]=0 ⇒ hi enabled, dsn[0]=1 ⇒ lo disabled)
//   read → dsn = 2'b11 (both disabled — read uses cpu_din comb)
wire [15:0] din16;
wire [15:0] dout16   = { cpu_dout8, cpu_dout8 };
wire [ 1:0] dsn_w    = cpu_we
                       ? (cpu_a0 ? 2'b01 : 2'b10)
                       : 2'b11;

assign cpu_din8 = cpu_a0 ? din16[15:8] : din16[7:0];

jtcop_bac06 #(.MASTER(MASTER), .REGION8_IS_16(REGION8_IS_16)) u_bac06 (
    .rst        (rst),
    .clk        (clk),
    .clk_cpu    (clk_cpu),
    .pxl2_cen   (pxl2_cen),
    .pxl_cen    (pxl_cen),

    .mode_cs    (mode_cs),
    .flip       (flip),

    .cpu_dout   (dout16),
    .cpu_din    (din16),
    .cpu_addr   (cpu_addr),
    .cpu_rnw    (~cpu_we),
    .cpu_dsn    (dsn_w),

    .vdump      (vdump),
    .vrender    (vrender),
    .hdump      (hdump),
    .LHBL       (LHBL),
    .LVBL       (LVBL),
    .HS         (HS),
    .VS         (VS),
    .vload      (vload),
    .hinit      (hinit),

    .ram_cs     (ram_cs),
    .ram_addr   (ram_addr),
    .ram_data   (ram_data),
    .ram_ok     (ram_ok),

    .rom_cs     (rom_cs),
    .rom_addr   (rom_addr),
    .rom_data   (rom_data),
    .rom_ok     (rom_ok),

    .pxl        (pxl),
    .st_addr    (8'd0),
    .st_dout    (),

    .dbg_plane_perm   (dbg_plane_perm),
    .dbg_bit_reverse  (dbg_bit_reverse),
    .dbg_nibble_swap  (dbg_nibble_swap),
    .dbg_word16_swap  (dbg_word16_swap),
    .dbg_byte_swap_w16(dbg_byte_swap_w16),
    .dbg_pen_invert   (dbg_pen_invert),
    .dbg_pen_reverse  (dbg_pen_reverse)
);

endmodule

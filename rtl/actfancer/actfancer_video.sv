// SPDX-License-Identifier: GPL-3.0-or-later
// Act-Fancer — Video subsystem.
//
// Two tile layers via Jotego's jtcop_bac06 (wrapped for 8-bit CPU bus):
//   PF0 = MASTER (16x16 background), provides H/V timing reference
//   PF1 = SLAVE  (8x8 chars overlay)
// DECO MXC06 sprite engine (bespoke MAME-faithful actfancer_sprites).
// Color mixing via jtcop_colmix (PF0/PF1/SPR priority + palette lookup).
//
// Video timing: jtframe_vtimer internal to PF0 (384x272 total @ 6 MHz pixel
// clock -> 256x240 active @ 57.45 Hz, hardware-accurate to MAME).

module actfancer_video
(
    input              clk,
    input              clk_cpu,
    input              pxl2_cen,
    input              pxl_cen,
    input              rst,

    input              pf0_mode_cs,
    input              pf0_vram_cs,
    input              pf1_mode_cs,
    input              pf1_vram_cs,
    input       [12:1] pf_addr,
    input        [7:0] pf_dout,
    input              pf_we,
    input              pf_a0,
    output       [7:0] pf0_din,
    output       [7:0] pf1_din,

    input       [10:0] spr_addr,
    input        [7:0] spr_dout,
    input              spr_we,
    input              spr_cs,
    output       [7:0] spr_din,
    input              spr_buffer,

    input       [10:0] pal_addr,
    input        [7:0] pal_dout,
    input              pal_we,
    input              pal_cs,
    output       [7:0] pal_din,

    output      [17:0] pf0_rom_addr,
    output             pf0_rom_cs,
    input       [31:0] pf0_rom_data,
    input              pf0_rom_ok,

    output      [17:0] pf1_rom_addr,
    output             pf1_rom_cs,
    input       [31:0] pf1_rom_data,
    input              pf1_rom_ok,

    output      [18:0] spr_rom_addr,
    output             spr_rom_cs,
    input       [31:0] spr_rom_data,
    input              spr_rom_ok,

    output             vbl,
    output             hbl,
    output             hs,
    output             vs,
    output      [11:0] rgb,

    // OSD debug (3 layer × 12 bit + 3 enable)
    input              dbg_dis_pf0,
    input              dbg_dis_pf1,
    input              dbg_dis_spr,
    input       [11:0] dbg_pf0,    // {pen_rev, pen_inv, bsw, w16sw, nibsw, br, perm[4:0]}
    input       [11:0] dbg_pf1,
    input       [11:0] dbg_spr
);

    // dbg_pf0 [11:0]:
    //   [4:0]  plane_perm
    //   [5]    bit_reverse_byte
    //   [6]    nibble_swap_byte
    //   [7]    word16_swap
    //   [8]    byte_swap_in_w16
    //   [9]    pen_invert
    //   [10]   pen_reverse
    //   [11]   (riserva)

// ============================================================
// Timing master = PF0 BAC06 (MASTER=1) — vtimer interno a jtcop_bac06
// ============================================================
wire        flip_bus;
wire [8:0]  vdump, vrender, hdump;
wire        LHBL, LVBL, HS_int, VS_int, vload, hinit;

assign vbl = ~LVBL;
assign hbl = ~LHBL;
assign hs  = HS_int;
assign vs  = VS_int;

// ============================================================
// VRAM PF0 (4KB / 4K word) e PF1 (1KB / 1K word) — dual-port 16-bit
// ============================================================
wire        pf0_ram_cs;
wire [13:1] pf0_ram_addr;
wire [15:0] pf0_ram_data;

vram_16bit_8bit_dp #(.AW(12)) u_pf0_vram (
    .clk        (clk),
    .cpu_addr   (pf_addr[12:1]),
    .cpu_a0     (pf_a0),
    .cpu_we     (pf_we & pf0_vram_cs),
    .cpu_din    (pf_dout),
    .cpu_dout   (pf0_din),
    .gfx_addr   (pf0_ram_addr[12:1]),
    .gfx_q      (pf0_ram_data)
);

wire        pf1_ram_cs;
wire [13:1] pf1_ram_addr;
wire [15:0] pf1_ram_data;

vram_16bit_8bit_dp #(.AW(10)) u_pf1_vram (
    .clk        (clk),
    .cpu_addr   (pf_addr[10:1]),
    .cpu_a0     (pf_a0),
    .cpu_we     (pf_we & pf1_vram_cs),
    .cpu_din    (pf_dout),
    .cpu_dout   (pf1_din),
    .gfx_addr   (pf1_ram_addr[10:1]),
    .gfx_q      (pf1_ram_data)
);

wire [7:0] pf0_pxl, pf1_pxl;

actfancer_bac06_wrap #(.MASTER(1), .REGION8_IS_16(1)) u_pf0_wrap (
    .rst        (rst),
    .clk        (clk),
    .clk_cpu    (clk_cpu),
    .pxl2_cen   (pxl2_cen),
    .pxl_cen    (pxl_cen),
    .mode_cs    (pf0_mode_cs),
    .vram_cs    (pf0_vram_cs),
    .cpu_dout8  (pf_dout),
    .cpu_din8   (),
    .cpu_addr   (pf_addr),
    .cpu_a0     (pf_a0),
    .cpu_we     (pf_we),
    .ram_cs     (pf0_ram_cs),
    .ram_addr   (pf0_ram_addr),
    .ram_data   (pf0_ram_data),
    .ram_ok     (1'b1),
    .rom_cs     (pf0_bac_rom_cs),
    .rom_addr   (pf0_bac_rom_addr),
    .rom_data   (pf0_bac_rom_data),
    .rom_ok     (pf0_bac_rom_ok),
    .pxl        (pf0_pxl),
    .flip       (flip_bus),
    .vdump      (vdump),
    .vrender    (vrender),
    .hdump      (hdump),
    .LHBL       (LHBL),
    .LVBL       (LVBL),
    .HS         (HS_int),
    .VS         (VS_int),
    .vload      (vload),
    .hinit      (hinit),
    .dbg_plane_perm   (dbg_pf0[4:0]),
    .dbg_bit_reverse  (dbg_pf0[5]),
    .dbg_nibble_swap  (dbg_pf0[6]),
    .dbg_word16_swap  (dbg_pf0[7]),
    .dbg_byte_swap_w16(dbg_pf0[8]),
    .dbg_pen_invert   (dbg_pf0[9]),
    .dbg_pen_reverse  (dbg_pf0[10])
);
assign pf0_rom_addr[0] = 1'b0;

// Bypass cache: collega bac06 direttamente al bridge SDRAM PF0
wire        pf0_bac_rom_cs;
wire [16:0] pf0_bac_rom_addr;
wire [31:0] pf0_bac_rom_data = pf0_rom_data;
wire        pf0_bac_rom_ok   = pf0_rom_ok;
assign      pf0_rom_cs        = pf0_bac_rom_cs;
assign      pf0_rom_addr[17:1]= pf0_bac_rom_addr;

actfancer_bac06_wrap #(.MASTER(0)) u_pf1_wrap (
    .rst        (rst),
    .clk        (clk),
    .clk_cpu    (clk_cpu),
    .pxl2_cen   (pxl2_cen),
    .pxl_cen    (pxl_cen),
    .mode_cs    (pf1_mode_cs),
    .vram_cs    (pf1_vram_cs),
    .cpu_dout8  (pf_dout),
    .cpu_din8   (),
    .cpu_addr   (pf_addr),
    .cpu_a0     (pf_a0),
    .cpu_we     (pf_we),
    .ram_cs     (pf1_ram_cs),
    .ram_addr   (pf1_ram_addr),
    .ram_data   (pf1_ram_data),
    .ram_ok     (1'b1),
    .rom_cs     (pf1_bac_rom_cs),
    .rom_addr   (pf1_bac_rom_addr),
    .rom_data   (pf1_bac_rom_data),
    .rom_ok     (pf1_bac_rom_ok),
    .pxl        (pf1_pxl),
    .flip       (flip_bus),
    .vdump      (vdump),
    .vrender    (vrender),
    .hdump      (hdump),
    .LHBL       (LHBL),
    .LVBL       (LVBL),
    .HS         (HS_int),
    .VS         (VS_int),
    .vload      (vload),
    .hinit      (hinit),
    .dbg_plane_perm   (dbg_pf1[4:0]),
    .dbg_bit_reverse  (dbg_pf1[5]),
    .dbg_nibble_swap  (dbg_pf1[6]),
    .dbg_word16_swap  (dbg_pf1[7]),
    .dbg_byte_swap_w16(dbg_pf1[8]),
    .dbg_pen_invert   (dbg_pf1[9]),
    .dbg_pen_reverse  (dbg_pf1[10])
);
assign pf1_rom_addr[0] = 1'b0;

// Bypass cache PF1: collega bac06 direttamente al bridge SDRAM
wire        pf1_bac_rom_cs;
wire [16:0] pf1_bac_rom_addr;
wire [31:0] pf1_bac_rom_data = pf1_rom_data;
wire        pf1_bac_rom_ok   = pf1_rom_ok;
assign      pf1_rom_cs        = pf1_bac_rom_cs;
assign      pf1_rom_addr[17:1]= pf1_bac_rom_addr;

// ============================================================
// Sprites (DECO MXC06) — actfancer_sprites
// ============================================================
wire [7:0]  spr_pxl;
wire        spr_bac_rom_cs;
wire [17:0] spr_bac_rom_addr_inner;
wire [31:0] spr_bac_rom_data;
wire        spr_bac_rom_ok;

actfancer_obj_wrap u_spr (
    .rst         (rst),
    .clk         (clk),
    .clk_cpu     (clk_cpu),
    .pxl_cen     (pxl_cen),
    .HS          (HS_int),
    .LVBL        (LVBL),
    .LHBL        (LHBL),
    .flip        (flip_bus),
    .hinit       (hinit),
    .vload       (vload),
    .vrender     (vrender),
    .hdump       (hdump),
    .cpu_addr    (spr_addr),
    .cpu_din     (spr_dout),
    .cpu_we      (spr_we),
    .cpu_dout    (spr_din),
    .cpu_cs      (spr_cs),
    .buffer_pulse(spr_buffer),
    .mixpsel     (1'b0),
    .rom_cs      (spr_bac_rom_cs),
    .rom_addr    (spr_bac_rom_addr_inner[17:1]),
    .rom_data    (spr_bac_rom_data),
    .rom_ok      (spr_bac_rom_ok),
    .dbg_plane_perm   (dbg_spr[4:0]),
    .dbg_bit_reverse  (dbg_spr[5]),
    .dbg_nibble_swap  (dbg_spr[6]),
    .dbg_word16_swap  (dbg_spr[7]),
    .dbg_byte_swap_w16(dbg_spr[8]),
    .dbg_pen_invert   (dbg_spr[9]),
    .dbg_pen_reverse  (dbg_spr[10]),
    .pxl         (spr_pxl)
);
assign spr_bac_rom_addr_inner[0] = 1'b0;

// Bypass cache sprite: collega direttamente al bridge SDRAM
assign      spr_bac_rom_data    = spr_rom_data;
assign      spr_bac_rom_ok      = spr_rom_ok;
assign      spr_rom_cs          = spr_bac_rom_cs;
assign      spr_rom_addr[18:1]  = {1'b0, spr_bac_rom_addr_inner[17:1]};
assign      spr_rom_addr[0]     = 1'b0;

// ============================================================
// ============================================================
// Compositing: PF1 (chars) > sprite > PF0 (tiles)
// Indici palette base (MAME GFXDECODE):
//   chars  → 0x000
//   tiles  → 0x100
//   sprite → 0x200
// ============================================================
// Layer enable mask (OSD: disable layer = forza pen=0 -> trasparente)
wire [7:0] pf0_pxl_m = dbg_dis_pf0 ? 8'h00 : pf0_pxl;
wire [7:0] pf1_pxl_m = dbg_dis_pf1 ? 8'h00 : pf1_pxl;
wire [7:0] spr_pxl_m = dbg_dis_spr ? 8'h00 : spr_pxl;

reg [10:0] pal_lookup;
always @* begin
    if (pf1_pxl_m[3:0] != 4'd0)
        pal_lookup = 11'h000 + {3'b0, pf1_pxl_m};
    else if (spr_pxl_m[3:0] != 4'd0)
        pal_lookup = 11'h200 + {3'b0, spr_pxl_m};
    else
        pal_lookup = 11'h100 + {3'b0, pf0_pxl_m};
end

// Palette 1536 byte (768 entries × 16-bit xBGR_444) — split in 2 BRAM dual-port
// per LO byte (pal_addr[0]=0) e HI byte (pal_addr[0]=1).
// AW=10 = 1024 entries (768 effettivi). Lato CPU usa pal_addr[10:1] come word16-index
// + pal_addr[0] come selector LO/HI. Lato video usa pal_lookup come word16-index.
// ============================================================
wire [9:0]  pal_word_addr_cpu = pal_addr[10:1];
wire        pal_byte_sel      = pal_addr[0];   // 0 = LO byte, 1 = HI byte
wire        we_pal_lo = pal_we & pal_cs & ~pal_byte_sel;
wire        we_pal_hi = pal_we & pal_cs &  pal_byte_sel;
wire [7:0]  pal_lo_cpu_q, pal_hi_cpu_q;
wire [7:0]  pal_lo_gfx_q, pal_hi_gfx_q;

jtframe_dual_ram #(.DW(8), .AW(10)) u_pal_lo (
    .clk0   (clk), .data0 (pal_dout), .addr0 (pal_word_addr_cpu), .we0 (we_pal_lo), .q0 (pal_lo_cpu_q),
    .clk1   (clk), .data1 (8'd0),     .addr1 (pal_lookup[9:0]),    .we1 (1'b0),       .q1 (pal_lo_gfx_q)
);
jtframe_dual_ram #(.DW(8), .AW(10)) u_pal_hi (
    .clk0   (clk), .data0 (pal_dout), .addr0 (pal_word_addr_cpu), .we0 (we_pal_hi), .q0 (pal_hi_cpu_q),
    .clk1   (clk), .data1 (8'd0),     .addr1 (pal_lookup[9:0]),    .we1 (1'b0),       .q1 (pal_hi_gfx_q)
);
assign pal_din = pal_byte_sel ? pal_hi_cpu_q : pal_lo_cpu_q;

// xBGR_444: hi = {x, B}, lo = {G, R}
assign rgb = { pal_hi_gfx_q[3:0], pal_lo_gfx_q[7:4], pal_lo_gfx_q[3:0] };

endmodule


// ============================================================
// VRAM dual-port 16-bit / CPU 8-bit (split into 2 byte planes)
// ============================================================
module vram_16bit_8bit_dp #(parameter AW=12) (
    input               clk,
    input  [AW-1:0]     cpu_addr,
    input               cpu_a0,
    input               cpu_we,
    input  [7:0]        cpu_din,
    output [7:0]        cpu_dout,
    input  [AW-1:0]     gfx_addr,
    output [15:0]       gfx_q
);
    // MAME pf_data_8bit_swap_w (decbac06.cpp:496+641):
    //   CPU A0=0 → MAME offset^1 → odd → mask 0x00ff → write LO byte
    //   CPU A0=1 → MAME offset^1 → even → mask 0xff00 → write HI byte
    wire we_hi = cpu_we &  cpu_a0;
    wire we_lo = cpu_we & ~cpu_a0;
    wire [7:0] hi_q_cpu, lo_q_cpu;
    wire [7:0] hi_q_gfx, lo_q_gfx;

    jtframe_dual_ram #(.DW(8), .AW(AW)) u_hi (
        .clk0   (clk), .data0  (cpu_din), .addr0  (cpu_addr), .we0(we_hi), .q0(hi_q_cpu),
        .clk1   (clk), .data1  (8'd0),    .addr1  (gfx_addr), .we1(1'b0),  .q1(hi_q_gfx)
    );
    jtframe_dual_ram #(.DW(8), .AW(AW)) u_lo (
        .clk0   (clk), .data0  (cpu_din), .addr0  (cpu_addr), .we0(we_lo), .q0(lo_q_cpu),
        .clk1   (clk), .data1  (8'd0),    .addr1  (gfx_addr), .we1(1'b0),  .q1(lo_q_gfx)
    );
    assign cpu_dout = cpu_a0 ? hi_q_cpu : lo_q_cpu;
    assign gfx_q    = { hi_q_gfx, lo_q_gfx };
endmodule

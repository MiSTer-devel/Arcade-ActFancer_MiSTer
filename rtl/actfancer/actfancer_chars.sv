// SPDX-License-Identifier: GPL-3.0-or-later
// Act-Fancer PF1 (chars 8x8 4bpp) — pipeline scan+linebuffer 1:1 jtcop_bac06.
// Stessa architettura di actfancer_tiles ma con tile 8x8 + index VRAM da
// MAME tile_shape0_8x8_scan (cpp:173).

module actfancer_chars (
    input              rst,
    input              clk,
    input              pxl_cen,

    input              flip_screen,

    input              mode_cs,
    input       [4:1]  ctrl_addr,
    input              ctrl_a0,
    input        [7:0] ctrl_din,
    input              ctrl_we,

    output reg  [11:0] vram_addr,
    input       [15:0] vram_q,
    input              vram_ok,

    output reg  [16:0] rom_addr,
    output reg         rom_cs,
    input       [31:0] rom_data,
    input              rom_ok,

    input              HS,
    input        [8:0] vrender,
    input        [8:0] hdump,
    input              LHBL,

    // OSD debug toggles
    input  [ 4:0] dbg_plane_perm,
    input         dbg_bit_reverse,
    input         dbg_nibble_swap,
    input         dbg_word16_swap,
    input         dbg_byte_swap_w16,
    input         dbg_pen_invert,
    input         dbg_pen_reverse,

    output       [7:0] pxl
);

reg [7:0]  ctl0_0, ctl0_3;
reg [15:0] ctl1_0, ctl1_1;

wire        row_major = ctl0_0[1];
wire [1:0]  geometry  = ctl0_3[1:0];

always @(posedge clk) begin
    if (rst) begin
        ctl0_0 <= 8'd0; ctl0_3 <= 8'd0;
        ctl1_0 <= 16'd0; ctl1_1 <= 16'd0;
    end else if (mode_cs && ctrl_we) begin
        if (~ctrl_addr[4]) begin
            case (ctrl_addr[3:1])
                3'd0: ctl0_0 <= ctrl_din;
                3'd3: ctl0_3 <= ctrl_din;
                default: ;
            endcase
        end else begin
            case (ctrl_addr[3:1])
                3'd0: if (~ctrl_a0) ctl1_0[7:0]  <= ctrl_din;
                      else          ctl1_0[15:8] <= ctrl_din;
                3'd1: if (~ctrl_a0) ctl1_1[7:0]  <= ctrl_din;
                      else          ctl1_1[15:8] <= ctrl_din;
                default: ;
            endcase
        end
    end
end

wire [15:0] hscr = row_major ? ctl1_0 : (16'h0 - ctl1_0 - 16'h100);
wire [15:0] vscr = ctl1_1;

wire [8:0]  vflp = flip_screen ? (9'd255 - vrender) : vrender;
wire [9:0]  veff0 = vflp + vscr[9:0];

reg HSl;
always @(posedge clk) HSl <= HS;
wire hs_rise = HSl && !HS;

reg  [9:0]  veff_reg;
reg  [11:0] hn;
reg         scan_busy, pre_cs, draw;
reg  [1:0]  ram_good;
reg  [5:0]  tilecnt;
reg  [11:0] tile_id;
reg  [ 3:0] tile_pal;

// MAME tile_shape0_8x8_scan: idx = (col & 0x1f) + ((row & 0x1f) << 5) + ((col & 0x60) << 5)
reg [11:0] pre_idx;
always @* begin
    case (geometry)
        2'd0: pre_idx = { hn[9:8], veff_reg[7:3], hn[7:3] };       // 128x32
        2'd1: pre_idx = { hn[10], veff_reg[8], veff_reg[7:3], hn[7:3] }; // 64x64
        default: pre_idx = { veff_reg[9:3], hn[7:3] };             // 32x128
    endcase
end

always @(posedge clk) begin
    if (rst) vram_addr <= 12'd0;
    else if (pre_cs) vram_addr <= pre_idx;
end

// Linebuffer
reg  [8:0]  buf_waddr;
reg         buf_we;
wire [7:0]  buf_wdata;
reg  [7:0]  lbuf[0:511];
reg  [7:0]  lbuf_rdata;

always @(posedge clk) begin
    if (buf_we) lbuf[buf_waddr] <= buf_wdata;
    lbuf_rdata <= lbuf[hdump];
end
assign pxl = LHBL ? lbuf_rdata : 8'h00;

reg [8:0] clr_addr;
reg       clr_active;
always @(posedge clk) begin
    if (rst) begin
        clr_addr <= 9'd0;
        clr_active <= 1'b0;
    end else begin
        if (hs_rise) begin
            clr_addr <= 9'd0;
            clr_active <= 1'b1;
        end
        if (clr_active && !buf_we) begin
            lbuf[clr_addr] <= 8'h00;
            clr_addr <= clr_addr + 9'd1;
            if (clr_addr == 9'd511) clr_active <= 1'b0;
        end
    end
end

// Scan
always @(posedge clk) begin
    if (rst) begin
        scan_busy <= 0; pre_cs <= 0; ram_good <= 0; draw <= 0;
        hn <= 0; tilecnt <= 0; tile_id <= 0; tile_pal <= 0; veff_reg <= 0;
    end else begin
        ram_good <= { ram_good[0] & vram_ok, vram_ok };
        draw <= 0;

        if (hs_rise) begin
            hn        <= hscr[11:0];
            tilecnt   <= 0;
            ram_good  <= 0;
            pre_cs    <= 1;
            veff_reg  <= veff0;
            scan_busy <= 1;
        end

        if (scan_busy && ram_good[1] && vram_ok) begin
            if (!draw && !draw_busy) begin
                tile_id  <= vram_q[11:0];
                tile_pal <= vram_q[15:12];
                draw     <= 1;
                hn       <= hn + 12'd8;
                tilecnt  <= tilecnt + 1'd1;
                ram_good <= 0;
                if (buf_waddr[8] && tilecnt > 1) begin
                    scan_busy <= 0;
                    pre_cs    <= 0;
                end
            end
        end
    end
end

// Draw FSM (chars 8x8 = 1 fetch ROM, no half)
reg  [31:0] draw_data;
reg  [ 3:0] draw_cnt;
reg         draw_busy;
reg         rom_good;
reg         get_hsub;

wire        hflip = ~row_major;
wire [3:0]  pen;

gfx_decode_debug u_dec (
    .rom_data         (draw_data),
    .bit_idx          (hflip ? 3'd7 : 3'd0),
    .plane_perm       (dbg_plane_perm),
    .bit_reverse_byte (dbg_bit_reverse),
    .nibble_swap_byte (dbg_nibble_swap),
    .word16_swap      (dbg_word16_swap),
    .byte_swap_in_w16 (dbg_byte_swap_w16),
    .pen_invert       (dbg_pen_invert),
    .pen_reverse      (dbg_pen_reverse),
    .pen              (pen)
);

assign buf_wdata = { tile_pal, pen };

always @(posedge clk) begin
    if (rst) begin
        draw_busy <= 0; draw_cnt <= 0; buf_waddr <= 0;
        rom_good <= 0; buf_we <= 0; rom_cs <= 0;
        get_hsub <= 0; rom_addr <= 0; draw_data <= 32'd0;
    end else begin
        rom_good <= rom_ok;
        if (hs_rise) get_hsub <= 1;

        if (draw) begin
            draw_busy <= 1;
            // 8x8 4bpp = 8 word32/tile = tile_id*32 byte = tile_id*8 word16
            // Byte-indexed layout: tile_id@[16:5], row@[4:2], 0@[1:0]
            rom_addr <= { tile_id, veff_reg[2:0], 2'd0 };  // 12+3+2 = 17 bit ✓
            draw_cnt <= 0;
            rom_cs   <= 1;
            rom_good <= 0;
            get_hsub <= 0;
            if (get_hsub) buf_waddr <= 9'd0 - {6'd0, hn[2:0]};
        end

        if (!buf_we && rom_cs && rom_good && rom_ok && draw_cnt==0) begin
            draw_data <= rom_data;
            rom_cs    <= 0;
            buf_we    <= 1;
            draw_cnt  <= 7;
        end

        if (buf_we) begin
            draw_data <= hflip ? draw_data<<1 : draw_data>>1;
            draw_cnt  <= draw_cnt - 1'd1;
            buf_waddr <= buf_waddr + 9'd1;
            if (draw_cnt == 0) begin
                buf_we    <= 0;
                draw_busy <= 0;
                rom_cs    <= 0;
            end
        end
    end
end

endmodule

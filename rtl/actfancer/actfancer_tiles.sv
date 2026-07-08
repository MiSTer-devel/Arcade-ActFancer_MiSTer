// SPDX-License-Identifier: GPL-3.0-or-later
// Act-Fancer PF0 (tiles 16x16 4bpp) — pipeline scan+linebuffer 1:1 jtcop_bac06.
//
// Schema:
//   1. HS rising → scan_busy=1, hn = hscroll, tilecnt=0
//   2. ram_good[1]+ram_ok → leggi tile_id+color da vram_q, draw=1, hn+=16, tilecnt++
//   3. draw → emetti rom_addr per left-half (sub_col_h=0), rom_cs=1, rom_good=0
//   4. rom_good+rom_ok → latch rom_data in draw_data, write 8 pxl in linebuffer
//   5. half=0→1 → rifai fetch ROM con sub_col_h=1, ridraw 8 pxl
//   6. Quando buf_waddr coperto + tilecnt>1 → scan_busy=0
//   7. Linebuffer letto da hdump per emettere pxl al pxl_cen
//
// VRAM indexing MAME (decbac06.cpp):
//   - shape0 col-major: idx = (row & 0xf) + ((0xFF - col[7:0]) << 4)
//   - shape0 row-major: idx = (col & 0xf) + ((row & 0xf) << 4) + ((col & 0x1f0) << 4)
//   - shape1: idx = (col & 0xf) + ((row & 0x1f) << 4) + ((col & 0xf0) << 5)
//   - shape2: idx = (col & 0xf) + ((row & 0x3f) << 4) + ((col & 0x70) << 6)

module actfancer_tiles (
    input              rst,
    input              clk,
    input              pxl_cen,

    input              flip_screen,

    // CPU writes a pf_control_0 (mode register)
    input              mode_cs,
    input       [4:1]  ctrl_addr,
    input              ctrl_a0,
    input        [7:0] ctrl_din,
    input              ctrl_we,

    // VRAM 16-bit (gestito esternamente, dual-port)
    output reg  [11:0] vram_addr,
    input       [15:0] vram_q,
    input              vram_ok,    // VRAM BRAM → sempre 1 (1 ciclo latency)

    // ROM 32-bit (via SDRAM bridge)
    output reg  [17:0] rom_addr,
    output reg         rom_cs,
    input       [31:0] rom_data,
    input              rom_ok,

    // Timing
    input              HS,
    input        [8:0] vrender,
    input        [8:0] hdump,
    input              LHBL,

    // OSD debug toggles (12 bit)
    input  [ 4:0] dbg_plane_perm,
    input         dbg_bit_reverse,
    input         dbg_nibble_swap,
    input         dbg_word16_swap,
    input         dbg_byte_swap_w16,
    input         dbg_pen_invert,
    input         dbg_pen_reverse,

    output       [7:0] pxl                // {color[3:0], pen[3:0]}
);

// ============================================================
// Mode register (pf_control_0[0..3] + pf_control_1[0..1])
// ============================================================
reg [7:0]  ctl0_0, ctl0_3;
reg [15:0] ctl1_0, ctl1_1;     // hscroll, vscroll (16-bit)

wire        tile8x8_en  = ctl0_0[0];   // 1 = 8x8 mode
wire        row_major   = ctl0_0[1];   // 1 = row-major, 0 = col-major (TILE_FLIPX)
wire [1:0]  geometry    = ctl0_3[1:0];

always @(posedge clk) begin
    if (rst) begin
        ctl0_0 <= 8'd0; ctl0_3 <= 8'd0;
        ctl1_0 <= 16'd0; ctl1_1 <= 16'd0;
    end else if (mode_cs && ctrl_we) begin
        if (~ctrl_addr[4]) begin
            // control_0 (LO byte only)
            case (ctrl_addr[3:1])
                3'd0: ctl0_0 <= ctrl_din;
                3'd3: ctl0_3 <= ctrl_din;
                default: ;
            endcase
        end else begin
            // control_1 (16-bit registers, swap convention)
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

// scroll x invertito per col-major (MAME cpp:274-278)
wire [15:0] hscr = row_major ? ctl1_0 : (16'h0 - ctl1_0 - 16'h100);
wire [15:0] vscr = ctl1_1;

// ============================================================
// veff (per il modulo opera 1 riga avanti rispetto al rendering)
// hn parte da hscr e avanza di 16 per ogni tile letto
// ============================================================
wire [8:0]  vflp = flip_screen ? (9'd255 - vrender) : vrender;
wire [9:0]  veff0 = vflp + vscr[9:0];

// HS rising edge detect
reg HSl;
always @(posedge clk) HSl <= HS;
wire hs_rise = HSl && !HS;   // jtcop pattern: HSl high prev, HS low now

// ============================================================
// State machine scan tilemap
// ============================================================
reg  [9:0]  veff_reg;
reg  [11:0] hn;
reg         scan_busy, pre_cs, draw;
reg  [1:0]  ram_good;
reg  [5:0]  tilecnt;
reg  [11:0] tile_id;
reg  [ 3:0] tile_pal;

// VRAM index calculation (MAME tile_shape*_scan)
reg  [11:0] pre_idx;
always @* begin
    pre_idx = 12'd0;
    case (geometry)
        2'd0: begin // shape0
            if (~tile8x8_en) begin
                // 16x16: 256 × 16 rows
                if (row_major)
                    pre_idx = { hn[11:8], veff_reg[7:4], hn[7:4] };
                else
                    pre_idx = { ~hn[11:4], veff_reg[7:4] };
            end else begin
                // 8x8: 128 × 32 rows
                pre_idx = { hn[10:9], veff_reg[7:3], hn[7:3] };
            end
        end
        2'd1: begin // shape1
            if (~tile8x8_en)
                pre_idx = { hn[11:8], veff_reg[8:4], hn[7:4] };
            else
                pre_idx = { hn[10], veff_reg[8], veff_reg[7:3], hn[7:3] };
        end
        default: begin // shape2 (geom 2 or 3)
            if (~tile8x8_en)
                pre_idx = { hn[11:9], veff_reg[9:4], hn[7:4] };
            else
                pre_idx = { veff_reg[9:3], hn[7:3] };
        end
    endcase
end

// vram_addr = pre_idx quando scan_busy in fetch tile_id phase
always @(posedge clk) begin
    if (rst) begin
        vram_addr <= 12'd0;
    end else begin
        if (pre_cs)
            vram_addr <= pre_idx;
    end
end

// ============================================================
// Linebuffer 512x8 (write side scan, read side hdump)
// ============================================================
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

// Clear linebuffer dopo lettura (1 ciclo dopo read)
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

// ============================================================
// Scan FSM: fetch tile_id from VRAM, then trigger draw
// ============================================================
always @(posedge clk) begin
    if (rst) begin
        scan_busy <= 0;
        pre_cs    <= 0;
        ram_good  <= 0;
        draw      <= 0;
        hn        <= 0;
        tilecnt   <= 0;
        tile_id   <= 0;
        tile_pal  <= 0;
        veff_reg  <= 0;
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
                hn       <= hn + (tile8x8_en ? 12'd8 : 12'd16);
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

// ============================================================
// Draw FSM: fetch ROM, write 8 pixel into linebuffer
// ============================================================
reg  [31:0] draw_data;
reg  [ 3:0] draw_cnt;
reg         half;
reg         draw_busy;
reg         rom_good;
reg         get_hsub;

// hflip from MAME: column-major -> TILE_FLIPX
wire        hflip = ~row_major;
wire [3:0]  pen;

gfx_decode_debug u_dec (
    .rom_data         (draw_data),
    .bit_idx          (hflip ? 3'd7 : 3'd0),  // hflip=1: MSB (shift<<); hflip=0: LSB (shift>>)
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
        draw_busy <= 0;
        draw_cnt  <= 0;
        buf_waddr <= 0;
        rom_good  <= 0;
        buf_we    <= 0;
        rom_cs    <= 0;
        half      <= 0;
        get_hsub  <= 0;
        rom_addr  <= 0;
        draw_data <= 32'd0;
    end else begin
        rom_good <= rom_ok;
        if (hs_rise) get_hsub <= 1;

        if (draw) begin
            draw_busy <= 1;
            half      <= 0;
            // rom_addr layout: tile 16x16 = 8 word32; tile 8x8 = 8 word32 packed
            // word32_idx = tile_id*8 + row[3:0] + (sub_col_h ? 1 : 0)
            // sdram bridge fa <<1 quindi rom_addr [17:1] = word32_idx, rom_addr[0]=0
            if (~tile8x8_en)
                rom_addr <= { tile_id, 1'b1, veff_reg[3:0], 1'b0 };  // 12+1+4+1=18b: tile_id@[17:6], sub_col_h=1 (right half first, jtcop), row@[4:1], 0@[0]
            else
                rom_addr <= { 1'b0, tile_id, veff_reg[2:0], 2'd0 };  // 1+12+3+2=18b: tile_id@[16:5], row@[4:2], 0@[1:0]
            draw_cnt <= 0;
            rom_cs   <= 1;
            rom_good <= 0;
            get_hsub <= 0;
            if (get_hsub) begin
                if (~tile8x8_en)
                    buf_waddr <= 9'd0 - {5'd0, hn[3:0]};
                else
                    buf_waddr <= 9'd0 - {6'd0, hn[2:0]};
            end
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
                buf_we <= 0;
                if (tile8x8_en || half) begin
                    draw_busy <= 0;
                    rom_cs    <= 0;
                end else begin
                    // second half of 16x16 tile
                    rom_addr[5] <= ~rom_addr[5];   // toggle sub_col_h (bit[5] = half index in byte-indexed addr)
                    rom_cs      <= 1;
                    rom_good    <= 0;
                    half        <= 1;
                    draw_cnt    <= 0;
                end
            end
        end
    end
end

endmodule

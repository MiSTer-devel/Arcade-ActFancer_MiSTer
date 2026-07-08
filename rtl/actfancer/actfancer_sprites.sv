// SPDX-License-Identifier: GPL-3.0-or-later
// Act-Fancer DECO MXC06 sprite engine — 1:1 MAME decmxc06::draw_sprites.
//
// Reference: reference/decmxc06.cpp
//
// Sprite layout (4 word × 16 bit per sprite, big-endian sprite RAM 2KB = 256 sprite):
//   word0 (byte0,1) = {byte0:[en, yflip, xflip, h[1:0], w[1:0], yh], byte1:[ylo[7:0]]}
//      bit 15 : enable
//      bit 14 : Y flip
//      bit 13 : X flip
//      bit 12:11 : height (1x, 2x, 4x, 8x)
//      bit 10: 9 : width
//      bit  8   : Y[8]
//      bit  7:0 : Y[7:0]
//   word1 (byte2,3) = {byte2:[?, code[12:8]], byte3:[code[7:0]]}
//      bit 12:0 : code base
//   word2 (byte4,5) = {byte4:[color[3:0], 0, flash, ?, xh], byte5:[xlo[7:0]]}
//      bit 15:12 : color
//      bit 11   : flash
//      bit  8:0 : X (signed-ish, see MAME conversion)
//   word3 = ignored
//
// MAME conversion (cpp:80-85):
//   sx = data2 & 0x01ff; if (sx >= 256) sx -= 512; sx = 240 - sx;
//   sy = data0 & 0x01ff; if (sy >= 256) sy -= 512; sy = 240 - sy;
//
// Multi-tile loop (cpp:105-157):
//   for (x=0; x<w; x++) {
//     code = spriteram[offs+1] & 0x1fff;
//     code &= ~(h-1);
//     if (parentFlipY) incy = -1; else { code += h-1; incy = 1; }
//     for (y=0; y<h; y++) {
//       draw tile (code - y*incy) at (sx + mult*x, sy + mult*y)
//     }
//     offs += 4;   // CONSUMA UN'ALTRA ENTRY per la prossima column
//   }
//   // mult = -16 (non-flipped) means tile column moves LEFT by 16 px
//
// Sprite ROM 384KB / 4 plane = 96KB/plane = 1536 tile 16x16.
//   Tile size in ROM = 32 byte (8 byte/plane × 4 plane interleaved 32-bit) = 8 word32/tile.
//   Word32 index = code * 8 + row_y[3:0]/2 + col_half (left=0, right=1).
//   Stesso layout di tiles.sv ma in regione sprites @ SDRAM 0x060000.
//
// MRA sprites interleave (B0..B3):
//   B0 = region 1/4
//   B1 = region 3/4
//   B2 = region 0
//   B3 = region 2/4
// MAME planes = {0, 1/4, 2/4, 3/4} → pen[3]=B2, pen[2]=B0, pen[1]=B3, pen[0]=B1.

module actfancer_sprites (
    input              rst,
    input              clk,
    input              pxl_cen,

    input              flip_screen,

    // CPU-side spriteram (8-bit)
    input       [10:0] cpu_addr,
    input        [7:0] cpu_din,
    input              cpu_we,
    output reg   [7:0] cpu_dout,
    input              cpu_cs,

    // Buffer trigger (pulse on 0x110000 write)
    input              buffer_pulse,

    // ROM port (32-bit, 4 plane interleaved)
    output reg [17:0]  rom_addr,
    output reg         rom_cs,
    input      [31:0]  rom_data,
    input              rom_ok,

    // Timing
    input        [8:0] vrender,
    input        [8:0] hdump,
    input              LVBL,        // 1 = active, 0 = vblank
    input              LHBL,

    // OSD debug toggles (12 bit)
    input  [ 4:0] dbg_plane_perm,
    input         dbg_bit_reverse,
    input         dbg_nibble_swap,
    input         dbg_word16_swap,
    input         dbg_byte_swap_w16,
    input         dbg_pen_invert,
    input         dbg_pen_reverse,

    output       [7:0] pxl
);

// ---- Spriteram dual-port: working copy ----
// CPU scrive sram_work, su buffer_pulse copia in sram_shadow.
// Engine legge sram_shadow durante VBL per pre-rendering.
reg [7:0] sram_work[0:2047];
reg [7:0] sram_shadow[0:2047];

always @(posedge clk) begin
    if (cpu_cs && cpu_we) sram_work[cpu_addr] <= cpu_din;
    cpu_dout <= sram_work[cpu_addr];
end

// DMA copy FSM (2048 cycles, triggered by buffer_pulse)
reg [10:0] dma_cnt;
reg        dma_busy, dma_arm;
reg [7:0]  dma_q;

always @(posedge clk) begin
    if (rst) begin dma_busy <= 0; dma_arm <= 0; dma_cnt <= 0; end
    else begin
        if (buffer_pulse) dma_arm <= 1;
        if (~dma_busy && dma_arm) begin
            dma_busy <= 1; dma_arm <= 0; dma_cnt <= 0;
        end else if (dma_busy) begin
            dma_q <= sram_work[dma_cnt];
            if (dma_cnt != 0) sram_shadow[dma_cnt - 11'd1] <= dma_q;
            if (dma_cnt == 11'd2047) begin
                sram_shadow[2047] <= sram_work[2047];   // last write direct
                dma_busy <= 0;
            end
            dma_cnt <= dma_cnt + 11'd1;
        end
    end
end

// ---- Line buffer 512×8 (double-buffer ping-pong per scanline) ----
// L'engine prepara la riga N+1 mentre la riga N viene letta.
// 512 wide per gestire sx negativo (signed wrap MAME).
reg [7:0] lbuf_a[0:511];
reg [7:0] lbuf_b[0:511];
reg       lbuf_sel;          // 0 → write A, read B; 1 → write B, read A

reg [8:0] lbuf_waddr; reg [7:0] lbuf_wdata; reg lbuf_we;
reg [7:0] lbuf_rdata;

always @(posedge clk) begin
    if (lbuf_we) begin
        if (lbuf_sel) lbuf_b[lbuf_waddr] <= lbuf_wdata;
        else          lbuf_a[lbuf_waddr] <= lbuf_wdata;
    end
    lbuf_rdata <= lbuf_sel ? lbuf_a[hdump[8:0]] : lbuf_b[hdump[8:0]];
end

// Read pixel from line buffer (with hdump alignment lookahead 1 ciclo per BRAM)
assign pxl = lbuf_rdata;

// pen extraction via gfx_decode_debug — usato in S_DRAW
// bit_x è ricomputato qui in modo combinatorio dal pixel_in_tile + flipx,
// poi gfx_decode_debug estrae il pen dai 4 byte plane di rom_data.
wire [2:0] draw_bit_x = flipx ? pixel_in_tile[2:0] : (3'd7 - pixel_in_tile[2:0]);
wire [3:0] draw_pen;
gfx_decode_debug u_dec (
    .rom_data         (rom_data),
    .bit_idx          (draw_bit_x),
    .plane_perm       (dbg_plane_perm),
    .bit_reverse_byte (dbg_bit_reverse),
    .nibble_swap_byte (dbg_nibble_swap),
    .word16_swap      (dbg_word16_swap),
    .byte_swap_in_w16 (dbg_byte_swap_w16),
    .pen_invert       (dbg_pen_invert),
    .pen_reverse      (dbg_pen_reverse),
    .pen              (draw_pen)
);

// ---- Scan engine FSM ----
// Triggered da HS rising (avvio scanline successiva): scan tutti gli sprite della
// riga (vrender+1), per ognuno controlla se la riga è dentro lo zone vertical,
// se sì fetcha codes e disegna i 16 pixel della riga.

reg        HSl;
wire       hs_rise = ~HSl /* dummy */;     // computed below

reg [9:0]  scan_idx;        // sprite index × 4 (offs)
reg [3:0]  state;
reg [7:0]  cur_byte0, cur_byte1, cur_byte2, cur_byte3,
           cur_byte4, cur_byte5;
reg [15:0] data0, data2;
reg [12:0] code_base;
reg [3:0]  x_iter, y_iter, w_tiles, h_tiles;
reg [8:0]  sx_base, sy_base;
reg [3:0]  color;
reg        flipx, flipy, parentFlipY;
reg        enable_spr, flash_spr;
reg [8:0]  current_row;      // riga da preparare (vrender+1)
reg [8:0]  row_in_sprite;    // 0..(h*16-1)
reg [12:0] code_y;
reg [3:0]  row_in_tile;
reg [3:0]  tile_yi;          // 0..h-1
reg        rom_pending;
reg [8:0]  draw_x;            // pixel x to write
reg [4:0]  pixel_in_tile;    // 0..15
reg        half;             // 0 = left 8 px, 1 = right 8 px

localparam S_IDLE   = 4'd0;
localparam S_NEXT   = 4'd1;
localparam S_W0     = 4'd2;
localparam S_W1     = 4'd3;
localparam S_W2     = 4'd4;
localparam S_CHECK  = 4'd5;
localparam S_TILE   = 4'd6;
localparam S_ROM_REQ= 4'd7;
localparam S_ROM_WAIT=4'd8;
localparam S_DRAW   = 4'd9;
localparam S_CLEAR  = 4'd10;

reg [8:0] clear_cnt;

// HS edge detection (from outside)
reg HS_prev;
wire HS_in = ~LHBL;          // crude: hblank active ≈ HS region
always @(posedge clk) HS_prev <= HS_in;
wire scan_start = HS_in & ~HS_prev;

always @(posedge clk) begin
    if (rst) begin
        state <= S_IDLE;
        scan_idx <= 0;
        lbuf_we  <= 0;
        rom_cs   <= 0;
        lbuf_sel <= 0;
    end else begin
        lbuf_we <= 0;
        case (state)
            S_IDLE: begin
                if (scan_start) begin
                    // Inizio scansione per riga vrender+1; flip line buffer
                    lbuf_sel    <= ~lbuf_sel;
                    current_row <= vrender + 9'd1;
                    scan_idx    <= 0;
                    clear_cnt   <= 0;
                    state       <= S_CLEAR;
                end
            end

            S_CLEAR: begin
                lbuf_we    <= 1;
                lbuf_waddr <= clear_cnt;
                lbuf_wdata <= 8'h00;
                clear_cnt  <= clear_cnt + 9'd1;
                if (clear_cnt == 9'd511) state <= S_W0;
            end

            S_W0: begin
                // Read byte0,1 from shadow (word0)
                cur_byte0 <= sram_shadow[{scan_idx[7:0], 3'd0}];
                cur_byte1 <= sram_shadow[{scan_idx[7:0], 3'd1}];
                state <= S_W1;
            end
            S_W1: begin
                cur_byte2 <= sram_shadow[{scan_idx[7:0], 3'd2}];
                cur_byte3 <= sram_shadow[{scan_idx[7:0], 3'd3}];
                state <= S_W2;
            end
            S_W2: begin
                cur_byte4 <= sram_shadow[{scan_idx[7:0], 3'd4}];
                cur_byte5 <= sram_shadow[{scan_idx[7:0], 3'd5}];
                state <= S_CHECK;
            end

            S_CHECK: begin
                // Decode
                data0 <= {cur_byte0, cur_byte1};
                data2 <= {cur_byte4, cur_byte5};
                enable_spr  <= cur_byte0[7];
                flipy       <= cur_byte0[6];
                flipx       <= cur_byte0[5];
                parentFlipY <= cur_byte0[6];
                h_tiles     <= 4'd1 << cur_byte0[4:3];
                w_tiles     <= 4'd1 << cur_byte0[2:1];
                // Y: 9-bit (byte0 bit0 = Y[8]) - MAME conversion
                begin : decode_y
                    reg [8:0] sy_raw;
                    sy_raw = {cur_byte0[0], cur_byte1};   // 9 bit
                    // sy_signed: if ≥256 sub 512 (signed-style wrap) — per now, we use raw 9-bit and convert
                    sy_base <= 9'd240 - sy_raw;
                end
                // X: byte4 bit0 = X[8]
                begin : decode_x
                    reg [8:0] sx_raw;
                    sx_raw = {cur_byte4[0], cur_byte5};
                    sx_base <= 9'd240 - sx_raw;
                end
                color       <= cur_byte4[7:4];
                flash_spr   <= cur_byte4[3];
                code_base   <= {cur_byte2[4:0], cur_byte3};   // 13-bit
                if (cur_byte0[7]) begin
                    tile_yi <= 0;
                    state   <= S_TILE;
                end else begin
                    state <= S_NEXT;
                end
            end

            S_TILE: begin
                // Determine if current_row is inside vertical span of this sprite at column 0
                // sy_base = top y of sprite; height = h_tiles*16
                // For now: scan all rows of sprite and only draw if row matches
                row_in_sprite <= current_row - sy_base;
                // simple check: if (current_row >= sy_base) && (current_row < sy_base + h*16)
                if ((current_row >= sy_base) && ((current_row - sy_base) < {3'd0, h_tiles, 4'd0})) begin
                    // Inside zone → fetch tile for this row
                    tile_yi      <= (current_row - sy_base) >> 4;
                    row_in_tile  <= (current_row - sy_base) & 4'hF;
                    x_iter       <= 0;
                    pixel_in_tile <= 0;
                    half         <= 0;
                    state        <= S_ROM_REQ;
                end else begin
                    state <= S_NEXT;
                end
            end

            S_ROM_REQ: begin
                // code per tile row in multi-h sprite:
                //   code = (code_base & ~(h-1))
                //   if (parentFlipY) y_offset = -tile_yi else y_offset = (h-1) - tile_yi
                // For multi-width (x_iter > 0): MAME consumes additional spriteram entries.
                // SEMPLIFICAZIONE per bring-up: ignoriamo le entry extra (multi-w col 0 only).
                begin : compute_code
                    reg [12:0] base_aligned;
                    reg [3:0]  y_off;
                    base_aligned = code_base & ~({9'd0, h_tiles} - 13'd1);
                    if (parentFlipY) y_off = tile_yi;
                    else             y_off = (h_tiles - 4'd1) - tile_yi;
                    code_y <= base_aligned + {9'd0, y_off};
                end
                // rom_addr = {code_y[11:0], row_in_tile[3:0], half}
                //   (code_y truncated to 12 bit per MAME tile region size 1536 ≈ 11 bit)
                // word32-index shiftato di 1 (bridge fa [17:1]<<1, preserva [1:17])
                rom_addr <= { code_y[10:0], row_in_tile, half, 1'b0 };
                rom_cs   <= 1;
                rom_pending <= 1;
                state    <= S_ROM_WAIT;
            end

            S_ROM_WAIT: begin
                if (rom_ok) begin
                    rom_pending <= 0;
                    pixel_in_tile <= 0;
                    state         <= S_DRAW;
                end
            end

            S_DRAW: begin
                begin : draw_block
                    reg [2:0] bit_x;
                    reg [8:0] xpos;
                    bit_x = flipx ? pixel_in_tile[2:0] : (3'd7 - pixel_in_tile[2:0]);
                    xpos = sx_base + {4'd0, half, pixel_in_tile[2:0]};
                    if (draw_pen != 4'd0) begin
                        lbuf_we    <= 1;
                        lbuf_waddr <= xpos;
                        lbuf_wdata <= {color, draw_pen};
                    end
                end
                if (pixel_in_tile == 3'd7) begin
                    pixel_in_tile <= 0;
                    if (~half) begin
                        half  <= 1;
                        state <= S_ROM_REQ;
                    end else begin
                        // tile done (16 px); next? For multi-h same column already handled by
                        // tile_yi selection above. We don't do multi-w here.
                        rom_cs <= 0;
                        state  <= S_NEXT;
                    end
                end else begin
                    pixel_in_tile <= pixel_in_tile + 3'd1;
                end
            end

            S_NEXT: begin
                if (scan_idx >= 10'd1020) begin
                    // done
                    state    <= S_IDLE;
                    rom_cs   <= 0;
                end else begin
                    scan_idx <= scan_idx + 10'd4;
                    state    <= S_W0;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule

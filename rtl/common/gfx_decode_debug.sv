// SPDX-License-Identifier: GPL-3.0-or-later
// gfx_decode_debug — modulo riutilizzabile per esplorare runtime via OSD
// tutte le possibili organizzazioni dati di una ROM 4bpp packed 32-bit.
//
// Scopo: quando MAME / la documentazione lascia ambiguità sull'ordine dei
// plane / bit / byte / nibble in una ROM gfx, questo modulo permette di
// switchare combinazioni in tempo reale dall'OSD MiSTer fino a trovare
// l'organizzazione che produce immagine corretta in HW.
//
// Input:
//   rom_data [31:0]   : i 4 byte plane impacchettati come letti da SDRAM
//                       (convenzione tipica MRA interleave: {B3,B2,B1,B0})
//   bit_idx  [2:0]    : indice del bit pixel dentro il byte plane (0..7)
//
// OSD toggles (12 bit totali per istanza):
//   plane_perm [4:0]  : 0..23 -> permutazione dei 4 byte -> pen[3..0]
//   bit_reverse_byte  : inverte i bit di ogni byte (MSB<->LSB)
//   nibble_swap_byte  : swap nibble alto<->basso entro ogni byte
//   word16_swap       : swap word16 alto<->basso del word32
//   byte_swap_in_w16  : swap byte entro ciascuna word16
//   pen_invert        : XOR pen[3:0] con 0xF
//   pen_reverse       : inverte ordine bit del pen finale
//
// Output:
//   pen [3:0]         : pen pixel risultante
//
// Note implementative:
//   - tutte le manipolazioni sono combinational
//   - le 24 permutazioni dei 4 plane sono codificate in una case statement
//     (5 bit OSD coprono 0..31, valori 24..31 ricadono su default 0)

module gfx_decode_debug (
    input  [31:0] rom_data,
    input  [ 2:0] bit_idx,

    // OSD toggles
    input  [ 4:0] plane_perm,
    input         bit_reverse_byte,
    input         nibble_swap_byte,
    input         word16_swap,
    input         byte_swap_in_w16,
    input         pen_invert,
    input         pen_reverse,

    output [ 3:0] pen
);

    // ============================================================
    // Stage 1: byte-level rearrangements
    // ============================================================
    // word16_swap: {B3,B2,B1,B0} -> {B1,B0,B3,B2}
    wire [31:0] s1_w16 = word16_swap
        ? {rom_data[15:0], rom_data[31:16]}
        : rom_data;

    // byte_swap_in_w16: swap byte entro ciascuna word16
    // {B3,B2,B1,B0} -> {B2,B3,B0,B1}
    wire [31:0] s1_bsw = byte_swap_in_w16
        ? {s1_w16[23:16], s1_w16[31:24], s1_w16[7:0], s1_w16[15:8]}
        : s1_w16;

    // ============================================================
    // Stage 2: per-byte bit manipulations
    // ============================================================
    function [7:0] byte_reverse;
        input [7:0] b;
        begin
            byte_reverse = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
        end
    endfunction

    function [7:0] byte_nibble_swap;
        input [7:0] b;
        begin
            byte_nibble_swap = {b[3:0], b[7:4]};
        end
    endfunction

    function [7:0] byte_xform;
        input [7:0] b;
        input       rev;
        input       nsw;
        reg   [7:0] tmp;
        begin
            tmp = rev ? byte_reverse(b) : b;
            byte_xform = nsw ? byte_nibble_swap(tmp) : tmp;
        end
    endfunction

    wire [7:0] B0 = byte_xform(s1_bsw[ 7: 0], bit_reverse_byte, nibble_swap_byte);
    wire [7:0] B1 = byte_xform(s1_bsw[15: 8], bit_reverse_byte, nibble_swap_byte);
    wire [7:0] B2 = byte_xform(s1_bsw[23:16], bit_reverse_byte, nibble_swap_byte);
    wire [7:0] B3 = byte_xform(s1_bsw[31:24], bit_reverse_byte, nibble_swap_byte);

    // ============================================================
    // Stage 3: select 1 bit per byte at bit_idx
    // ============================================================
    wire b0 = B0[bit_idx];
    wire b1 = B1[bit_idx];
    wire b2 = B2[bit_idx];
    wire b3 = B3[bit_idx];

    // ============================================================
    // Stage 4: 24 permutazioni dei 4 plane -> pen[3:0]
    // Convenzione: pen = {p3, p2, p1, p0} dove px = uno tra b0..b3
    // ============================================================
    reg [3:0] pen_raw;
    always @* begin
        case (plane_perm)
            //              pen[3] pen[2] pen[1] pen[0]
            5'd0 : pen_raw = {b2,   b3,   b0,   b1};   // default DECO-MAME (tiles/sprites)
            5'd1 : pen_raw = {b3,   b2,   b1,   b0};
            5'd2 : pen_raw = {b0,   b1,   b2,   b3};
            5'd3 : pen_raw = {b1,   b0,   b3,   b2};
            5'd4 : pen_raw = {b2,   b0,   b3,   b1};
            5'd5 : pen_raw = {b0,   b2,   b1,   b3};
            5'd6 : pen_raw = {b3,   b1,   b2,   b0};
            5'd7 : pen_raw = {b1,   b3,   b0,   b2};
            5'd8 : pen_raw = {b3,   b2,   b0,   b1};
            5'd9 : pen_raw = {b2,   b3,   b1,   b0};
            5'd10: pen_raw = {b0,   b1,   b3,   b2};
            5'd11: pen_raw = {b1,   b0,   b2,   b3};
            5'd12: pen_raw = {b2,   b1,   b3,   b0};
            5'd13: pen_raw = {b1,   b2,   b0,   b3};
            5'd14: pen_raw = {b3,   b0,   b1,   b2};
            5'd15: pen_raw = {b0,   b3,   b2,   b1};
            5'd16: pen_raw = {b0,   b2,   b3,   b1};
            5'd17: pen_raw = {b2,   b0,   b1,   b3};
            5'd18: pen_raw = {b1,   b3,   b2,   b0};
            5'd19: pen_raw = {b3,   b1,   b0,   b2};
            5'd20: pen_raw = {b0,   b3,   b1,   b2};
            5'd21: pen_raw = {b3,   b0,   b2,   b1};
            5'd22: pen_raw = {b1,   b2,   b3,   b0};
            5'd23: pen_raw = {b2,   b1,   b0,   b3};
            default: pen_raw = {b2,  b3,   b0,   b1}; // fallback = perm 0
        endcase
    end

    // ============================================================
    // Stage 5: pen post-processing
    // ============================================================
    wire [3:0] pen_inv = pen_invert ? ~pen_raw : pen_raw;
    wire [3:0] pen_rev = pen_reverse
        ? {pen_inv[0], pen_inv[1], pen_inv[2], pen_inv[3]}
        : pen_inv;

    assign pen = pen_rev;

endmodule

// SPDX-License-Identifier: GPL-3.0-or-later
// Sprite engine wrapper per ActFancer (CPU H6280 8-bit).
// Riusa jtcop_obj_buffer + jtcop_obj_draw originali Jotego (= adapted M68000).
//
// Wrapper traduce CPU 8-bit -> bus 16-bit con cpu_dsn[1:0] byte enable.
// Sprite RAM 2KB = 1024 word16. CPU vede 8-bit address [10:0]:
//   - cpu_addr[10:1] = word16 index (= 10 bit)
//   - cpu_addr[0]    = byte select within word16 (= A0)
//
// MAME spriteram ActFancer (actfancr.cpp:150 buffer_spriteram_w):
//   m_spriteram16[i] = m_spriteram[i*2] | (m_spriteram[(i*2)+1] << 8);
//                       LO byte             HI byte
// Cioè LITTLE-ENDIAN dentro il word16:
//   spriteram byte 2i   = LO byte (= cpu A0=0)
//   spriteram byte 2i+1 = HI byte (= cpu A0=1)
//
// Mapping CPU<->BAC06_buffer:
//   CPU A0=0 → LO byte → cpu_dsn = 2'b10 (dsn[0]=0 we[0]=1 enable LO)
//   CPU A0=1 → HI byte → cpu_dsn = 2'b01 (dsn[1]=0 we[1]=1 enable HI)
//   CPU read A0=0 → obj_din16[7:0]   (LO byte)
//   CPU read A0=1 → obj_din16[15:8]  (HI byte)
//
// jtcop_obj_buffer.we = ~({2{cpu_rnw}} | cpu_dsn) & {2{objram_cs}}
//   cpu_dsn[0]=0 → we[0]=1 = scrive LO byte
//   cpu_dsn[1]=0 → we[1]=1 = scrive HI byte

module actfancer_obj_wrap (
    input              rst,
    input              clk,
    input              clk_cpu,
    input              pxl_cen,

    input              HS,
    input              LVBL,
    input              LHBL,
    input              flip,
    input              hinit,
    input              vload,
    input        [8:0] vrender,
    input        [8:0] hdump,

    // CPU 8-bit interface (da actfancer_main)
    input       [10:0] cpu_addr,        // 11-bit byte address (0..0x7FF)
    input        [7:0] cpu_din,         // CPU writes
    output       [7:0] cpu_dout,        // CPU reads
    input              cpu_we,          // pulse 1-clk
    input              cpu_cs,          // spriteram cs

    // DMA trigger (pulse on buffer_spriteram_w from CPU)
    input              buffer_pulse,
    input              mixpsel,         // tipicamente 0 in ActFancer

    // ROM interface
    output             rom_cs,
    output      [17:1] rom_addr,
    input       [31:0] rom_data,
    input              rom_ok,

    // OSD debug toggles
    input        [4:0] dbg_plane_perm,
    input              dbg_bit_reverse,
    input              dbg_nibble_swap,
    input              dbg_word16_swap,
    input              dbg_byte_swap_w16,
    input              dbg_pen_invert,
    input              dbg_pen_reverse,

    output       [7:0] pxl
);

    // Convert CPU 8-bit -> 16-bit bus for jtcop_obj_buffer
    wire [10:1] obj_addr16 = cpu_addr[10:1];
    wire [15:0] obj_dout16 = { cpu_din, cpu_din };
    wire [15:0] obj_din16;
    wire        cpu_a0 = cpu_addr[0];
    // little-endian (MAME buffer_spriteram_w):
    //   A0=0 -> LO byte -> dsn = 2'b10 (we[0]=1 enable LO)
    //   A0=1 -> HI byte -> dsn = 2'b01 (we[1]=1 enable HI)
    wire [ 1:0] cpu_dsn  = cpu_we ? (cpu_a0 ? 2'b01 : 2'b10) : 2'b11;

    // CPU read demux (little-endian: A0=0 -> LO, A0=1 -> HI)
    assign cpu_dout = cpu_a0 ? obj_din16[15:8] : obj_din16[7:0];

    jtcop_obj u_obj (
        .rst        (rst),
        .clk        (clk),
        .clk_cpu    (clk_cpu),
        .pxl_cen    (pxl_cen),

        .HS         (HS),
        .LVBL       (LVBL),
        .LHBL       (LHBL),
        .flip       (flip),
        .hinit      (hinit),
        .vload      (vload),
        .vrender    (vrender),
        .hdump      (hdump),

        // SD dump (not used)
        .ioctl_ram  (1'b0),
        .ioctl_addr (11'd0),
        .ioctl_din  (),

        // CPU interface
        .cpu_addr   (obj_addr16),
        .cpu_dout   (obj_dout16),
        .obj_dout   (obj_din16),
        .cpu_dsn    (cpu_dsn),
        .cpu_rnw    (~cpu_we),
        .objram_cs  (cpu_cs),

        // ROM interface
        .rom_cs     (rom_cs),
        .rom_addr   (rom_addr),
        .rom_data   (rom_data),
        .rom_ok     (rom_ok),

        // DMA trigger
        .obj_copy   (buffer_pulse),
        .mixpsel    (mixpsel),

        // OSD debug toggles
        .dbg_plane_perm   (dbg_plane_perm),
        .dbg_bit_reverse  (dbg_bit_reverse),
        .dbg_nibble_swap  (dbg_nibble_swap),
        .dbg_word16_swap  (dbg_word16_swap),
        .dbg_byte_swap_w16(dbg_byte_swap_w16),
        .dbg_pen_invert   (dbg_pen_invert),
        .dbg_pen_reverse  (dbg_pen_reverse),

        .pxl        (pxl)
    );

endmodule

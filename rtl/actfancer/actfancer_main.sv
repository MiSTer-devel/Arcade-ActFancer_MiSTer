// SPDX-License-Identifier: GPL-3.0-or-later
// Act-Fancer / Trio The Punch — main CPU subsystem
//
// MAME reference: dataeast/actfancr.cpp::actfancr_state::prg_map (lines 154-173)
//
//   0x000000-0x02FFFF  ROM  (3 × 64KB on PCB)
//   0x060000-0x060007  PF0 BAC06 control0  (W only)
//   0x060010-0x06001F  PF0 BAC06 control1  (W only, 8bit_swap)
//   0x062000-0x063FFF  PF0 VRAM            (R/W, 8bit_swap)
//   0x070000-0x070007  PF1 BAC06 control0  (W only)
//   0x070010-0x07001F  PF1 BAC06 control1  (W only, 8bit_swap)
//   0x072000-0x0727FF  PF1 VRAM            (R/W, 8bit_swap)
//   0x100000-0x1007FF  Spriteram           (R/W, 8 bit)
//   0x110000           buffer_spriteram_w  (latch sprite buffer)
//   0x120000-0x1205FF  Palette             (R/W, 8 bit)
//   0x130000           P1
//   0x130001           P2
//   0x130002           DSW1
//   0x130003           DSW2
//   0x140000-0x140001  SYSTEM (VBL bit7)
//   0x150000           soundlatch (W)
//   0x1F0000-0x1F3FFF  Main RAM 16KB
//
// VBL → /IRQ1 of H6280 (HOLD_LINE) via screen_vblank callback

module actfancer_main
(
    input              clk,           // 21.477 MHz master
    input              ce_h6280,      // CPU clock enable (~7.16 MHz)
    input              paused_safe,   // 1=ferma HUC6280 (RDY=0), gia` sync VBlank dal top
    input              rst_n,

    // From video
    input              vbl,           // 1 = vblank active

    // Inputs
    input        [7:0] p1,
    input        [7:0] p2,
    input        [7:0] coin,           // {x, x, x, x, x, service, coin2, coin1} active-low
    input        [7:0] dsw1,
    input        [7:0] dsw2,

    // ROM read (H6280 program ROM, 192KB @ SDRAM 0x000000)
    output      [17:0] rom_addr,
    output reg         rom_cs,
    input        [7:0] rom_data,
    input              rom_ok,

    // PF0/PF1 BAC06 control busses (write strobes only)
    output             pf0_mode_cs,
    output             pf0_vram_cs,
    output             pf1_mode_cs,
    output             pf1_vram_cs,
    output      [12:1] pf_addr,
    output       [7:0] pf_dout,
    output             pf_we,
    output             pf_a0,         // byte select inside 16-bit word
    input        [7:0] pf0_din,
    input        [7:0] pf1_din,

    // Spriteram (2KB) shared with sprite engine
    output      [10:0] spr_addr,
    output       [7:0] spr_dout,
    output             spr_we,
    output             spr_cs,
    input        [7:0] spr_din,
    output             spr_buffer,    // pulse on 0x110000 write → latch shadow RAM

    // Palette (1536 bytes = 768 entries × 2 bytes, xBGR_444)
    output      [10:0] pal_addr,
    output       [7:0] pal_dout,
    output             pal_we,
    input        [7:0] pal_din,
    output             pal_cs,

    // Sound latch out
    output       [7:0] snd_latch,
    output             snd_latch_we
);

// ---------------------------------------------------------------
// HUC6280 instance
// ---------------------------------------------------------------
wire [20:0] cpu_a;
wire [7:0]  cpu_do, cpu_di;
wire        cpu_wrn, cpu_rdn, cpu_ce, cpu_sx;

reg  [7:0]  din_mux;
initial     din_mux = 8'h00;
wire        wait_n;

// CS decode (combinational on cpu_a) — see prg_map
// NOTA H6280 da disasm fe08-3.bin boot:
//   Banco MPR  | Device              | cpu_a[20] | cpu_a[19:16]
//   $00..$0F   | ROM                 | 0         | varies
//   $10..$17   | ROM (256KB max)     | 0         | varies
//   $30..$33   | PF0 BAC06 (mode+VRAM)| 0        | $6
//   $38..$39   | PF1 BAC06           | 0         | $7
//   $78..$79   | (main RAM mirror?)  | 0         | $F
//   $80..$87   | SPR RAM             | 1         | $0
//   $88..$8F   | sprite buffer       | 1         | $1
//   $90..$97   | Palette             | 1         | $2
//   $98..$9F   | INPUT (P1/P2/DSW)   | 1         | $3
//   $A0..$A7   | SYSTEM (VBL)        | 1         | $4
//   $A8..$AF   | Soundlatch          | 1         | $5
//   $B0..$B7   | PF0 mirror          | 1         | $6
//   $B8..$BF   | PF1 mirror?         | 1         | $7
//   $F8..$F9   | Main RAM (16KB)     | 1         | $F (bit[19:14]=$3E)
//
// Regole decode:
//   ROM:  cpu_a[20]=0 AND cpu_a[19:17]=000  (= banchi $00-$0F, 128KB di ROM in logical)
//                                            (ROM physical 192KB, ma il PCB la accede via banchi)
//   PF0:  cpu_a[19:16]=6 AND cpu_a[15:14]=00 (mirror via A20, banchi $30 e $B0)
//   PF1:  cpu_a[19:16]=7 AND cpu_a[15:14]=00 (banchi $38, $B8)
//   Devices A20=1 only:
//     SPR  : cpu_a[20]=1 AND cpu_a[19:16]=0 AND cpu_a[15:11]=0
//     SBUF : cpu_a[20]=1 AND cpu_a[19:16]=1
//     PAL  : cpu_a[20]=1 AND cpu_a[19:16]=2 AND cpu_a[15:11]=0
//     INP  : cpu_a[20]=1 AND cpu_a[19:16]=3
//     SYS  : cpu_a[20]=1 AND cpu_a[19:16]=4
//     SLATCH: cpu_a[20]=1 AND cpu_a[19:16]=5
//     RAM  : cpu_a[20]=1 AND cpu_a[19:14]=6'b111110 (banco $F8/$F9)
// ROM: banchi MPR $00-$1F = 256KB (ActFancer usa 192KB = banchi $00-$17).
// NOTA H6280: durante vector fetch (MC.ADDR_BUS=100), A_OUT[20:13]=MPR[7].
// Al reset MPR7=$00 → vector legge phys $001FF6-$001FFF = ROM banco 0 ✓.
// Il gioco usa MPR5 con banchi $10-$17 per leggere asset table (es. PF1 init
// da phys $02E000 = banco $17). Devo catturare cpu_a[19:18]==00 (= 256KB).
wire cs_rom   = cpu_a[20] == 1'b0 && cpu_a[19:18] == 2'b00;
wire cs_pf0   = cpu_a[20] == 1'b0 && cpu_a[19:16] == 4'h6 && cpu_a[15:14] == 2'b00;  // PF0 strict bank $30 only (no mirror $B0)
wire cs_pf1   = cpu_a[19:16] == 4'h7 && cpu_a[15:14] == 2'b00;     // PF1 (banchi $38, $B8)
wire cs_spr   = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h0 && cpu_a[15:11] == 5'h00;
// MAME: 0x110000-0x110001 (buffer_spriteram_w 2 byte). Restringo a 32 byte per evitare
// che scritture accidentali in banco $11 triggerino DMA sprite.
wire cs_sbuf  = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h1 && cpu_a[15:5] == 11'd0;
wire cs_pal   = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h2 && cpu_a[15:11] == 5'h00;
wire cs_inp   = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h3;
wire cs_sys   = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h4;
wire cs_slatch= cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h5;
wire cs_ram   = cpu_a[20] == 1'b1 && cpu_a[19:14] == 6'b111100;    // bank $F8/$F9 (RAM 16KB)

// 16KB main RAM in BRAM. La RAM legge SEMPRE (non gated da cpu_ce)
// così che ram_q segua cpu_a istantaneamente. Scrive solo quando cs_ram
// AND WR_N=0 (la VHDL HUC6280 alza WR_N=0 solo durante la write).
// 16KB main RAM in BRAM. La RAM legge SEMPRE (non gated da cpu_ce)
// così che ram_q segua cpu_a istantaneamente. Scrive solo quando cs_ram
// AND WR_N=0 (la VHDL HUC6280 alza WR_N=0 solo durante la write).
reg [7:0] main_ram[0:16383] /* synthesis ramstyle = "M10K, no_rw_check" */;
reg [7:0] ram_q;
initial $readmemh("rtl/actfancer/main_ram_init.hex", main_ram);
wire ram_we = cs_ram && ~cpu_wrn;
always @(posedge clk) begin
    if (ram_we) main_ram[cpu_a[13:0]] <= cpu_do;
    ram_q <= main_ram[cpu_a[13:0]];
end

// Inputs MUX
wire [7:0] inp_q =
    (cpu_a[1:0] == 2'd0) ? p1 :
    (cpu_a[1:0] == 2'd1) ? p2 :
    (cpu_a[1:0] == 2'd2) ? dsw1 :
                           dsw2;
// SYSTEM port MAME (active-low except bit7=VBL active-high):
//   bit 0 = COIN1, bit 1 = COIN2, bit 7 = VBL
wire [7:0] sys_q = { vbl, 5'b11111, coin[1:0] };

always @* begin
    din_mux = 8'h00;     // default per evitare xx in sim quando cs_* metastable
    casez ({cs_rom, cs_ram, cs_pf0, cs_pf1, cs_spr, cs_pal, cs_inp, cs_sys})
        8'b1???????: din_mux = rom_data;
        8'b01??????: din_mux = ram_q;
        8'b001?????: din_mux = pf0_din;
        8'b0001????: din_mux = pf1_din;
        8'b00001???: din_mux = spr_din;
        8'b000001??: din_mux = pal_din;
        8'b0000001?: din_mux = inp_q;
        8'b00000001: din_mux = sys_q;
        default:     din_mux = 8'hFF;
    endcase
end

assign rom_addr = cpu_a[17:0];
always @(posedge clk) if (cpu_sx) rom_cs <= cs_rom;
assign wait_n = ~cs_rom | rom_ok;
assign cpu_di = din_mux;

// PF bus fanout (BAC06 wrapper esterno gestisce 8-bit→16-bit)
// MAME maps tightly:
//   pf0:  0x060000-0x060007 ctrl0, 0x060010-0x06001F ctrl1, 0x062000-0x063FFF VRAM
//   pf1:  0x070000-0x070007 ctrl0, 0x070010-0x07001F ctrl1, 0x072000-0x0727FF VRAM
// mode_cs deve essere stretto: solo bit 5..0 = 0x000-0x01F (cpu_a[13:5]==0)
assign pf0_mode_cs = cs_pf0 && cpu_a[13:5] == 9'b0;     // 0x060000-0x06001F
assign pf0_vram_cs = cs_pf0 && cpu_a[13];               // 0x062000-0x063FFF
assign pf1_mode_cs = cs_pf1 && cpu_a[13:5] == 9'b0;     // 0x070000-0x07001F
// PF1 VRAM: MAME limita a 2KB (0x072000-0x0727FF) — restringo per evitare aliasing
assign pf1_vram_cs = cs_pf1 && cpu_a[13] && cpu_a[12:11] == 2'b00;
assign pf_addr     = cpu_a[12:1];
assign pf_dout     = cpu_do;
assign pf_we       = ~cpu_wrn & cpu_ce;
assign pf_a0       = cpu_a[0];

// Spriteram
assign spr_addr    = cpu_a[10:0];
assign spr_dout    = cpu_do;
assign spr_we      = cs_spr & ~cpu_wrn & cpu_ce;
assign spr_cs      = cs_spr;
assign spr_buffer  = cs_sbuf & ~cpu_wrn & cpu_ce;

// Palette
assign pal_addr    = cpu_a[10:0];
assign pal_dout    = cpu_do;
assign pal_we      = cs_pal & ~cpu_wrn & cpu_ce;
assign pal_cs      = cs_pal;

// Sound latch — register (latch must hold data after main CPU moves on)
reg [7:0] snd_latch_r;
wire snd_latch_we_w = cs_slatch & ~cpu_wrn & cpu_ce;
always @(posedge clk) begin
    if (snd_latch_we_w) snd_latch_r <= cpu_do;
end
assign snd_latch     = snd_latch_r;
assign snd_latch_we  = snd_latch_we_w;

// VBL → IRQ1 (verificato: ISR a $F403 setta $26; vector $F44F è dummy RTI).
// HOLD_LINE = asserted while vbl=1.
wire   irq1_n = ~vbl;

HUC6280 u_huc (
    .CLK        (clk),
    .RST_N      (rst_n),
    .WAIT_N     (wait_n),
    .SX         (cpu_sx),

    .A          (cpu_a),
    .DI         (cpu_di),
    .DO         (cpu_do),
    .WR_N       (cpu_wrn),
    .RD_N       (cpu_rdn),

    .RDY        (~paused_safe),
    .NMI_N      (1'b1),
    .IRQ1_N     (irq1_n),
    .IRQ2_N     (1'b1),

    .CE         (cpu_ce),
    .CEK_N      (),
    .CE7_N      (),
    .CER_N      (),
    .PRE_RD     (),
    .PRE_WR     (),
    .HSM        (),
    .O          (),
    .K          (8'd0),
    .VDCNUM     (1'b0),
    .AUD_LDATA  (),
    .AUD_RDATA  ()
);

endmodule

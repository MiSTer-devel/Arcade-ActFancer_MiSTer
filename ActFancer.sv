// SPDX-License-Identifier: GPL-3.0-or-later
//
// ActFancer_MiSTer — MiSTer emu wrapper (entry point).
//
// Routes MiSTer HPS_BUS / SDRAM / DDRAM / video / audio to actfancer_top.
// CONF_STR exposes aspect ratio, scale, audio mixer (per-chip volume), analog
// VGA H-Shift / V-Shift / H-Size, Clean Pause overlay, DIP switches, joystick
// mapping. ROM streaming via ioctl_download is wired to BRAM (CPU ROMs +
// OKI ADPCM) and to the SDRAM bridge / DDRAM bridge for gfx ROMs.
//
// Author: Umberto Parisi (rmonic79), 2026.

module emu
(
    input         CLK_50M,
    input         RESET,
    inout  [48:0] HPS_BUS,
    output        CLK_VIDEO,
    output        CE_PIXEL,
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,
    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output  [2:0] VGA_HSIZE,
    output        VGA_F1,
    output [1:0]  VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,
    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,
    output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,
    output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
    output        FB_PAL_CLK,
    output  [7:0] FB_PAL_ADDR,
    output [23:0] FB_PAL_DOUT,
    input  [23:0] FB_PAL_DIN,
    output        FB_PAL_WR,
`endif
`endif

    output        LED_USER,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,
    output  [1:0] BUTTONS,

    input         CLK_AUDIO,
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

    inout   [3:0] ADC_BUS,

    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    output        SDRAM_CLK,
    output        SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output        SDRAM_nCS,
    output        SDRAM_nCAS,
    output        SDRAM_nRAS,
    output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
    input         SDRAM2_EN,
    output        SDRAM2_CLK,
    output [12:0] SDRAM2_A,
    output  [1:0] SDRAM2_BA,
    inout  [15:0] SDRAM2_DQ,
    output        SDRAM2_nCS,
    output        SDRAM2_nCAS,
    output        SDRAM2_nRAS,
    output        SDRAM2_nWE,
`endif

    input         UART_CTS,
    output        UART_RTS,
    input         UART_RXD,
    output        UART_TXD,
    output        UART_DTR,
    input         UART_DSR,

    input   [6:0] USER_IN,
    output  [6:0] USER_OUT,

    input         OSD_STATUS
);

// Unused ports
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM cablato in basso (actfancer_ddram instance)
assign VGA_SL      = 0;
assign VGA_F1      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
// Pause forward-declarations (logic in basso, dopo clk_sys disponibile)
reg pause_toggle;
reg joy_pause_prev;
wire pause;
assign HDMI_FREEZE    = 1'b0;  // overlay pause renderizzato real-time, no freeze scaler
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;
assign LED_USER  = 0;
// VIDEO_ARX/ARY driven by video_freak (vedi sotto)

`include "build_id.v"
localparam CONF_STR = {
    "ActFancer;;",
    "-;",
    "P1,Video;",
    "P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "P1O[7:5],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
    "P1O[97:92],Analog VGA H-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "P1O[28:23],Analog VGA V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "P1O[100:98],Analog VGA H-Size,0,+1,+2,+3,+4,+5,+6,+7;",
    "P1O[18],Clean Pause,Off,On;",
    "-;",
    "P2,Audio Mixer;",
    "P2O[106:104],YM2203 (OPN) volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
    "P2O[109:107],YM3812 (OPL) volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
    "P2O[112:110],OKI ADPCM volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
    "-;",
    "DIP;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "-;",
    "J1,Attack,Jump,Start,Coin,Pause;",
    "jn,A,B,Start,R,L;",
    "V,v",`BUILD_DATE
};

//////////////////////////////////////////////////////////////////
// HPS_IO
//////////////////////////////////////////////////////////////////
wire        clk_sys;
wire        pll_locked;
wire        clk_sdram = clk_sys;   // SDRAM is stubbed; share clk for now

pll pll (
    .refclk     (CLK_50M),
    .rst        (0),
    .outclk_0   (clk_sys),
    .locked     (pll_locked)
);
assign SDRAM_CLK = clk_sys;

wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;
wire         ioctl_download, ioctl_wr;
wire  [24:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire  [15:0] ioctl_index;
wire         ioctl_wait;   // OR di ioctl_wait_sdram | ioctl_wait_ddram (definiti dopo)
wire         forced_scandoubler;
wire  [21:0] gamma_bus;

wire [35:0] EXT_BUS;

hps_io #(.CONF_STR(CONF_STR)) hps_io_i (
    .clk_sys        (clk_sys),
    .HPS_BUS        (HPS_BUS),
    .EXT_BUS        (EXT_BUS),
    .gamma_bus      (gamma_bus),
    .forced_scandoubler(forced_scandoubler),

    .buttons        (),
    .status         (status),
    .status_menumask(16'd0),

    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_index    (ioctl_index),
    .ioctl_wait     (ioctl_wait),

    .joystick_0     (joystick_0),
    .joystick_1     (joystick_1),

    .ps2_key        (ps2_key)
);

// DSW from MRA ioctl_index==254
reg [15:0] dip_sw = 16'hFFFF;
always @(posedge clk_sys) begin
    if (ioctl_wr && (ioctl_index == 16'd254)) begin
        if (ioctl_addr == 25'd0) dip_sw[ 7:0] <= ioctl_dout;
        if (ioctl_addr == 25'd1) dip_sw[15:8] <= ioctl_dout;
    end
end

//////////////////////////////////////////////////////////////////
// Reset
//////////////////////////////////////////////////////////////////
wire reset = RESET | status[0] | ioctl_download | ~pll_locked;

//////////////////////////////////////////////////////////////////
// Pause: toggle on rising edge of joy[12] (standard MiSTer pause bit).
// `pause` ferma la CPU dentro actfancer_top, l'overlay (sopra) viene
// renderizzato sopra l'ultimo frame quando pause=1 e clean=0.
//////////////////////////////////////////////////////////////////
always @(posedge clk_sys) begin
    if (reset) begin
        pause_toggle   <= 1'b0;
        joy_pause_prev <= 1'b0;
    end else begin
        joy_pause_prev <= joystick_0[12] | joystick_1[12];
        if ((joystick_0[12] | joystick_1[12]) && !joy_pause_prev)
            pause_toggle <= ~pause_toggle;
    end
end
assign pause = pause_toggle;

//////////////////////////////////////////////////////////////////
// Game
//////////////////////////////////////////////////////////////////
wire [7:0] r8, g8, b8;
wire       hs, vs, hb, vb, ce_pix;
wire signed [15:0] aud_l, aud_r;

// Audio volumi OSD (Q4.4 fixed-point, 16 = 100% unity)
wire [2:0] osd_opn_vol = status[106:104];
wire [2:0] osd_opl_vol = status[109:107];
wire [2:0] osd_oki_vol = status[112:110];

// Bilanciamento percepito (psicoacustica, +6 dB = x2 percepito):
//   YM2203 (OPN, effetti)  +25% percepito  -> unity 28  (~+5 dB, x1.78 lin)
//   YM3812 (OPL, musica)   -15% percepito  -> unity 11  (~-3 dB, x0.71 lin)
//   OKI ADPCM (voci)       OKI alzato      -> unity 70  (~+12.8 dB, x4.4 lin)
// vol_q44 esteso a 7 bit (max 127 = +18 dB sopra unity originale 16) per
// dare headroom all'OKI senza saturazione del moltiplicatore.
// Preset OSD scalati COERENTEMENTE al nuovo unity per chip.
reg [6:0] opn_vol_q44, opl_vol_q44, oki_vol_q44;
always @* begin
    case (osd_opn_vol)
        3'd0: opn_vol_q44 = 7'd28;   // 100% bilanciato
        3'd1: opn_vol_q44 = 7'd4;    // 12.5%
        3'd2: opn_vol_q44 = 7'd7;    // 25%
        3'd3: opn_vol_q44 = 7'd14;   // 50%
        3'd4: opn_vol_q44 = 7'd21;   // 75%
        3'd5: opn_vol_q44 = 7'd42;   // 150%
        3'd6: opn_vol_q44 = 7'd56;   // 200%
        3'd7: opn_vol_q44 = 7'd0;    // Mute
    endcase
    case (osd_opl_vol)
        3'd0: opl_vol_q44 = 7'd11;   // 100% bilanciato
        3'd1: opl_vol_q44 = 7'd1;    // 12.5%
        3'd2: opl_vol_q44 = 7'd3;    // 25%
        3'd3: opl_vol_q44 = 7'd6;    // 50%
        3'd4: opl_vol_q44 = 7'd8;    // 75%
        3'd5: opl_vol_q44 = 7'd17;   // 150%
        3'd6: opl_vol_q44 = 7'd22;   // 200%
        3'd7: opl_vol_q44 = 7'd0;    // Mute
    endcase
    case (osd_oki_vol)
        3'd0: oki_vol_q44 = 7'd70;   // 100% bilanciato
        3'd1: oki_vol_q44 = 7'd9;    // 12.5%
        3'd2: oki_vol_q44 = 7'd18;   // 25%
        3'd3: oki_vol_q44 = 7'd35;   // 50%
        3'd4: oki_vol_q44 = 7'd53;   // 75%
        3'd5: oki_vol_q44 = 7'd105;  // 150%
        3'd6: oki_vol_q44 = 7'd127;  // 200% (saturato 7-bit max)
        3'd7: oki_vol_q44 = 7'd0;    // Mute
    endcase
end

// MAME actfancr.cpp port mapping:
//   P1 bit 0=UP, 1=DOWN, 2=LEFT, 3=RIGHT, 4=BUTTON1, 5=BUTTON2, 7=START1
//   SYSTEM bit 0=COIN1, 1=COIN2
// MiSTer hps_io with jn keywords (pattern BoogieWings/Darius DataEast):
//   D-pad joy[0..3] = R,L,D,U
//   J1 buttons base joy[4]=A, joy[5]=B
//   jn keyword "Start" → joy[10] (fixed)
//   jn keyword "R"     → joy[11] (used for Coin)
//   jn keyword "L"     → joy[12] (used for Pause)
wire [7:0] joy1_w = { joystick_0[10], 1'b0, joystick_0[5], joystick_0[4],
                      joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3] };
wire [7:0] joy2_w = { joystick_1[10], 1'b0, joystick_1[5], joystick_1[4],
                      joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3] };
wire [7:0] coin_w = { 6'b0, joystick_1[11], joystick_0[11] };
wire [15:0] dsw_w = dip_sw;

// === SDRAM client wires (game -> bridge) ===
wire [17:0] sdr_pf0_addr; wire sdr_pf0_cs; wire [31:0] sdr_pf0_data; wire sdr_pf0_ok;
wire [17:0] sdr_pf1_addr; wire sdr_pf1_cs; wire [31:0] sdr_pf1_data; wire sdr_pf1_ok;
wire [18:0] sdr_spr_addr; wire sdr_spr_cs; wire [31:0] sdr_spr_data; wire sdr_spr_ok;
wire [17:0] sdr_oki_addr; wire sdr_oki_cs; wire  [7:0] sdr_oki_data; wire sdr_oki_ok;

actfancer_top u_game (
    .clk            (clk_sys),
    .clk_sdram      (clk_sys),
    .rst            (reset),
    .pause          (pause),

    .joy1           (joy1_w),
    .joy2           (joy2_w),
    .coin           (coin_w),
    .dsw            (dsw_w),

    .ioctl_download (ioctl_download),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_wr       (ioctl_wr),
    .ioctl_index    (ioctl_index),

    .sdr_pf0_addr   (sdr_pf0_addr), .sdr_pf0_cs (sdr_pf0_cs),
    .sdr_pf0_data   (sdr_pf0_data), .sdr_pf0_ok (sdr_pf0_ok),
    .sdr_pf1_addr   (sdr_pf1_addr), .sdr_pf1_cs (sdr_pf1_cs),
    .sdr_pf1_data   (sdr_pf1_data), .sdr_pf1_ok (sdr_pf1_ok),
    .sdr_spr_addr   (sdr_spr_addr), .sdr_spr_cs (sdr_spr_cs),
    .sdr_spr_data   (sdr_spr_data), .sdr_spr_ok (sdr_spr_ok),
    .sdr_oki_addr   (sdr_oki_addr), .sdr_oki_cs (sdr_oki_cs),
    .sdr_oki_data   (sdr_oki_data), .sdr_oki_ok (sdr_oki_ok),

    .vga_r          (r8),
    .vga_g          (g8),
    .vga_b          (b8),
    .vga_hs         (hs),
    .vga_vs         (vs),
    .vga_hb         (hb),
    .vga_vb         (vb),
    .ce_pix         (ce_pix),

    .aud_l          (aud_l),
    .aud_r          (aud_r),
    .vol_opn        (opn_vol_q44),
    .vol_opl        (opl_vol_q44),
    .vol_oki        (oki_vol_q44),

    .dbg_dis_pf0    (1'b0),
    .dbg_dis_pf1    (1'b0),
    .dbg_dis_spr    (1'b0),
    .dbg_pf0        (12'd0),
    .dbg_pf1        (12'd0),
    .dbg_spr        (12'd0)
);

// ── Pause overlay: render_x/render_y counter derivati da hb/vb del core ─────
// AF e` 256x224 active (uguale a BloodBros). Genero counter logici sopra ce_pix
// per indirizzare il pause_overlay alle coordinate giuste durante l'active.
// Reset: render_x al rising di hb (fine linea), render_y al rising di vb (fine
// frame). Active = active pixel del modulo BAC06.
reg hb_prev, vb_prev;
always @(posedge clk_sys) begin
    if (ce_pix) begin
        hb_prev <= hb;
        vb_prev <= vb;
    end
end
wire hb_rise = ce_pix & hb & ~hb_prev;
wire vb_rise = ce_pix & vb & ~vb_prev;

reg [9:0] render_x;
reg [8:0] render_y;
always @(posedge clk_sys) begin
    if (ce_pix) begin
        if (hb_rise)      render_x <= 10'd0;
        else if (~hb)     render_x <= render_x + 10'd1;

        if (vb_rise)      render_y <= 9'd0;
        else if (hb_rise & ~vb) render_y <= render_y + 9'd1;
    end
end

// Pause overlay: dim video + logo + SUPPORTERS + patron scroll.
// Modulo standalone 8-bit RGB. OSD "Clean Pause" (status[18]): ON=raw, OFF=overlay.
pause_overlay u_pause_ovl (
    .clk       (clk_sys),
    .pause     (pause),
    .clean     (status[18]),
    .vblank    (vb),
    .render_x  (render_x[8:0]),
    .render_y  (render_y),
    .rgb_r_in  (r8),
    .rgb_g_in  (g8),
    .rgb_b_in  (b8),
    .rgb_r_out (VGA_R),
    .rgb_g_out (VGA_G),
    .rgb_b_out (VGA_B)
);

// VGA_HSIZE forwarded to sys_top analog_hsize module (analog branch only).
// Modulo standalone in sys/analog_hsize.sv.
assign VGA_HSIZE = status[100:98];

// ── Analog VGA H-Shift / V-Shift (bidirezionali) ─────────────────────────────
// Shift register su HSync/VSync verso il SOLO pin analogico VGA.
// HDMI scaler usa sync propri, core timing invariato.
//
// H-Shift: OSD signed -32..+31 ce_pix (6 bit two's complement).
//   +N = ritarda HSync di N ce_pix  -> immagine spostata a SINISTRA.
//   -N = anticipa HSync di N ce_pix -> immagine spostata a DESTRA.
//   Anticipo implementato come ritardo equivalente (HTotal - |N|).
//   HTotal AF = 384 ce_pix (jtcop_bac06 VCNT_END/HB_END timing).
// V-Shift: OSD signed -32..+31 linee, stessa convenzione.
//   VTotal AF = 272 linee (jtcop_bac06 VCNT_END=271).
localparam int H_TOTAL_AF = 384;
localparam int V_TOTAL_AF = 272;

// H-Shift -----------------------------------------------------------------
reg signed [5:0] osd_vga_hshift_d;
always @(posedge clk_sys) if (ce_pix) osd_vga_hshift_d <= $signed(status[97:92]);

// indice tap: positivo -> ritardo = N; negativo -> ritardo = HTotal + N (= HTotal - |N|).
wire [8:0] hshift_tap = osd_vga_hshift_d[5]
    ? (9'(H_TOTAL_AF) + {{3{osd_vga_hshift_d[5]}}, osd_vga_hshift_d})
    : {3'd0, osd_vga_hshift_d};

reg [H_TOTAL_AF-1:0] hsync_shreg;
always @(posedge clk_sys) if (ce_pix) hsync_shreg <= {hsync_shreg[H_TOTAL_AF-2:0], hs};
reg vga_hs_reg;
always @(posedge clk_sys) if (ce_pix)
    vga_hs_reg <= (hshift_tap == 9'd0) ? hs : hsync_shreg[hshift_tap - 9'd1];
assign VGA_HS = vga_hs_reg;

// V-Shift -----------------------------------------------------------------
reg hs_d;
always @(posedge clk_sys) if (ce_pix) hs_d <= hs;
wire line_tick = ce_pix && (hs & ~hs_d);

reg signed [5:0] osd_vga_vshift_d;
always @(posedge clk_sys) if (line_tick) osd_vga_vshift_d <= $signed(status[28:23]);

wire [8:0] vshift_tap = osd_vga_vshift_d[5]
    ? (9'(V_TOTAL_AF) + {{3{osd_vga_vshift_d[5]}}, osd_vga_vshift_d})
    : {3'd0, osd_vga_vshift_d};

reg [V_TOTAL_AF-1:0] vsync_line_shreg;
always @(posedge clk_sys) if (line_tick) vsync_line_shreg <= {vsync_line_shreg[V_TOTAL_AF-2:0], vs};
reg vga_vs_reg;
always @(posedge clk_sys) if (line_tick)
    vga_vs_reg <= (vshift_tap == 9'd0) ? vs : vsync_line_shreg[vshift_tap - 9'd1];
assign VGA_VS = vga_vs_reg;
// VGA_DE pilotato da video_freak (vedi fondo)
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;

assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

//////////////////////////////////////////////////////////////////
// SDRAM controller + bridge
//////////////////////////////////////////////////////////////////
wire        sdram_ready;
wire [23:0] sd_addr0, sd_addr1, sd_addr2, sd_addr3;
wire [15:0] sd_din0;
wire [15:0] sd_dout0, sd_dout1, sd_dout2, sd_dout3;
wire        sd_wrl0, sd_wrh0;
wire        sd_req0, sd_req1, sd_req2, sd_req3;
wire        sd_ack0, sd_ack1, sd_ack2, sd_ack3;

sdram u_sdram (
    .SDRAM_DQ   (SDRAM_DQ),
    .SDRAM_A    (SDRAM_A),
    .SDRAM_DQML (SDRAM_DQML),
    .SDRAM_DQMH (SDRAM_DQMH),
    .SDRAM_BA   (SDRAM_BA),
    .SDRAM_nCS  (SDRAM_nCS),
    .SDRAM_nWE  (SDRAM_nWE),
    .SDRAM_nRAS (SDRAM_nRAS),
    .SDRAM_nCAS (SDRAM_nCAS),
    .SDRAM_CLK  (),
    .SDRAM_CKE  (SDRAM_CKE),
    .ready      (sdram_ready),

    .init       (~pll_locked),
    .clk        (clk_sys),
    .prio_mode  (2'b00),

    .addr0(sd_addr0), .wrl0(sd_wrl0), .wrh0(sd_wrh0), .din0(sd_din0), .dout0(sd_dout0), .req0(sd_req0), .ack0(sd_ack0),
    .addr1(sd_addr1), .wrl1(1'b0),    .wrh1(1'b0),    .din1(16'd0),   .dout1(sd_dout1), .req1(sd_req1), .ack1(sd_ack1),
    .addr2(sd_addr2), .wrl2(1'b0),    .wrh2(1'b0),    .din2(16'd0),   .dout2(sd_dout2), .req2(sd_req2), .ack2(sd_ack2),
    .addr3(sd_addr3), .wrl3(1'b0),    .wrh3(1'b0),    .din3(16'd0),   .dout3(sd_dout3), .req3(sd_req3), .ack3(sd_ack3)
);

wire        ioctl_wait_sdram;
wire        ioctl_wait_ddram;
assign      ioctl_wait = ioctl_wait_sdram | ioctl_wait_ddram;

actfancer_sdram_bridge u_bridge (
    .clk            (clk_sys),
    .rst            (~pll_locked),

    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_index    (ioctl_index),
    .ioctl_wait     (ioctl_wait_sdram),

    .oki_byte_addr  (sdr_oki_addr),
    .oki_cs         (sdr_oki_cs),
    .oki_data       (sdr_oki_data),
    .oki_ok         (sdr_oki_ok),

    .sd_addr0(sd_addr0), .sd_din0(sd_din0), .sd_wrl0(sd_wrl0), .sd_wrh0(sd_wrh0),
    .sd_req0(sd_req0),   .sd_ack0(sd_ack0), .sd_dout0(sd_dout0),

    .sd_addr1(sd_addr1), .sd_req1(sd_req1), .sd_ack1(sd_ack1), .sd_dout1(sd_dout1),
    .sd_addr2(sd_addr2), .sd_req2(sd_req2), .sd_ack2(sd_ack2), .sd_dout2(sd_dout2),
    .sd_addr3(sd_addr3), .sd_req3(sd_req3), .sd_ack3(sd_ack3), .sd_dout3(sd_dout3)
);

//////////////////////////////////////////////////////////////////
// DDRAM — sprite + PF0 tile + PF1 chars (32-bit fetch + 8-byte cache)
//////////////////////////////////////////////////////////////////
// DDR layout (byte offset):
//   0x000000-0x05FFFF  sprite ROM (384KB, ioctl 0x60000-0xBFFFF)
//   0x060000-0x09FFFF  tiles PF0  (256KB, ioctl 0xC0000-0xFFFFF)
//   0x0A0000-0x0BFFFF  chars PF1  (128KB, ioctl 0x40000-0x5FFFF)

reg  [27:0] ddr_wraddr_r;
reg  [15:0] ddr_din_r;
reg         ddr_we_req_r;
wire        ddr_we_ack;
reg  [ 7:0] dl_lo_byte;
wire        dl_active_w = ioctl_download && (ioctl_index == 16'd0);
wire        in_spr_dl   = (ioctl_addr >= 25'h060000) && (ioctl_addr < 25'h0C0000);
wire        in_tile_dl  = (ioctl_addr >= 25'h0C0000) && (ioctl_addr < 25'h100000);
wire        in_char_dl  = (ioctl_addr >= 25'h040000) && (ioctl_addr < 25'h060000);
wire        in_ddr_dl   = in_spr_dl | in_tile_dl | in_char_dl;

// DDR base offsets (byte address)
localparam [27:0] DDR_SPR_BASE  = 28'h0000000;
localparam [27:0] DDR_TILE_BASE = 28'h0060000;
localparam [27:0] DDR_CHAR_BASE = 28'h00A0000;

// DL write a DDR (byte-pair → word16 every 2 byte)
reg dl_wait_ddr;
assign ioctl_wait_ddram = dl_wait_ddr;

always @(posedge clk_sys) begin
    if (~pll_locked) begin
        ddr_we_req_r <= 1'b0;
        dl_wait_ddr  <= 1'b0;
        dl_lo_byte   <= 8'd0;
    end else begin
        if (dl_wait_ddr && ddr_we_ack == ddr_we_req_r) dl_wait_ddr <= 1'b0;
        if (dl_active_w && ioctl_wr && in_ddr_dl) begin
            if (~ioctl_addr[0]) begin
                dl_lo_byte <= ioctl_dout;
            end else begin
                ddr_din_r <= {ioctl_dout, dl_lo_byte};
                if (in_spr_dl)
                    ddr_wraddr_r <= DDR_SPR_BASE + {3'd0, (ioctl_addr - 25'h060000)};
                else if (in_tile_dl)
                    ddr_wraddr_r <= DDR_TILE_BASE + {3'd0, (ioctl_addr - 25'h0C0000)};
                else // in_char_dl
                    ddr_wraddr_r <= DDR_CHAR_BASE + {3'd0, (ioctl_addr - 25'h040000)};
                ddr_we_req_r <= ~ddr_we_req_r;
                dl_wait_ddr  <= 1'b1;
            end
        end
    end
end

// Sprite read (port 4)
reg  [27:0] spr_rd_addr_r;
reg         spr_rd_req_r;
wire        spr_rd_ack;
wire [31:0] spr_ddr_data;
reg  [18:0] spr_addr_last_top;
reg         spr_ok_top;

always @(posedge clk_sys) begin
    if (~pll_locked) begin
        spr_rd_req_r       <= 1'b0;
        spr_addr_last_top  <= 19'h7FFFF;
        spr_ok_top         <= 1'b0;
    end else begin
        if (sdr_spr_cs && (sdr_spr_addr != spr_addr_last_top)) begin
            // rom_addr emesso come word16-index (legacy SDRAM bridge faceva <<1).
            // DDR3 ha layout 4-byte/word32 sequenziali: byte_DDR = word16_idx * 2.
            spr_rd_addr_r     <= DDR_SPR_BASE + {8'd0, sdr_spr_addr, 1'b0};
            spr_rd_req_r      <= ~spr_rd_req_r;
            spr_addr_last_top <= sdr_spr_addr;
            spr_ok_top        <= 1'b0;
        end else if (spr_rd_ack == spr_rd_req_r) begin
            spr_ok_top <= 1'b1;
        end
    end
end

assign sdr_spr_data = spr_ddr_data;
assign sdr_spr_ok   = spr_ok_top;

// PF0 tile read (port 5)
reg  [27:0] pf0_rd_addr_r;
reg         pf0_rd_req_r;
wire        pf0_rd_ack;
wire [31:0] pf0_ddr_data;
reg  [17:0] pf0_addr_last_top;
reg         pf0_ok_top;

always @(posedge clk_sys) begin
    if (~pll_locked) begin
        pf0_rd_req_r      <= 1'b0;
        pf0_addr_last_top <= 18'h3FFFF;
        pf0_ok_top        <= 1'b0;
    end else begin
        if (sdr_pf0_cs && (sdr_pf0_addr != pf0_addr_last_top)) begin
            // word16-index → byte DDR: *2 (vedi commento sprite)
            pf0_rd_addr_r     <= DDR_TILE_BASE + {9'd0, sdr_pf0_addr, 1'b0};
            pf0_rd_req_r      <= ~pf0_rd_req_r;
            pf0_addr_last_top <= sdr_pf0_addr;
            pf0_ok_top        <= 1'b0;
        end else if (pf0_rd_ack == pf0_rd_req_r) begin
            pf0_ok_top <= 1'b1;
        end
    end
end

assign sdr_pf0_data = pf0_ddr_data;
assign sdr_pf0_ok   = pf0_ok_top;

// PF1 chars read (port 6)
reg  [27:0] pf1_rd_addr_r;
reg         pf1_rd_req_r;
wire        pf1_rd_ack;
wire [31:0] pf1_ddr_data;
reg  [17:0] pf1_addr_last_top;
reg         pf1_ok_top;

always @(posedge clk_sys) begin
    if (~pll_locked) begin
        pf1_rd_req_r      <= 1'b0;
        pf1_addr_last_top <= 18'h3FFFF;
        pf1_ok_top        <= 1'b0;
    end else begin
        if (sdr_pf1_cs && (sdr_pf1_addr != pf1_addr_last_top)) begin
            // word16-index → byte DDR: *2 (vedi commento sprite)
            pf1_rd_addr_r     <= DDR_CHAR_BASE + {9'd0, sdr_pf1_addr, 1'b0};
            pf1_rd_req_r      <= ~pf1_rd_req_r;
            pf1_addr_last_top <= sdr_pf1_addr;
            pf1_ok_top        <= 1'b0;
        end else if (pf1_rd_ack == pf1_rd_req_r) begin
            pf1_ok_top <= 1'b1;
        end
    end
end

assign sdr_pf1_data = pf1_ddr_data;
assign sdr_pf1_ok   = pf1_ok_top;

actfancer_ddram u_ddram (
    .DDRAM_CLK        (clk_sys),
    .DDRAM_BUSY       (DDRAM_BUSY),
    .DDRAM_BURSTCNT   (DDRAM_BURSTCNT),
    .DDRAM_ADDR       (DDRAM_ADDR),
    .DDRAM_DOUT       (DDRAM_DOUT),
    .DDRAM_DOUT_READY (DDRAM_DOUT_READY),
    .DDRAM_RD         (DDRAM_RD),
    .DDRAM_DIN        (DDRAM_DIN),
    .DDRAM_BE         (DDRAM_BE),
    .DDRAM_WE         (DDRAM_WE),

    .wraddr   (ddr_wraddr_r),
    .din      (ddr_din_r),
    .we_byte  (1'b0),               // word write
    .we_req   (ddr_we_req_r),
    .we_ack   (ddr_we_ack),

    .rdaddr   (28'd0), .rd_req(1'b0), .rd_ack(),
    .rdaddr2  (28'd0), .rd_req2(1'b0), .rd_ack2(),
    .rdaddr3  (28'd0), .rd_req3(1'b0), .rd_ack3(),

    .rdaddr4  (spr_rd_addr_r),
    .dout4    (spr_ddr_data),
    .rd_req4  (spr_rd_req_r),
    .rd_ack4  (spr_rd_ack),

    .rdaddr5  (pf0_rd_addr_r),
    .dout5    (pf0_ddr_data),
    .rd_req5  (pf0_rd_req_r),
    .rd_ack5  (pf0_rd_ack),

    .rdaddr6  (pf1_rd_addr_r),
    .dout6    (pf1_ddr_data),
    .rd_req6  (pf1_rd_req_r),
    .rd_ack6  (pf1_rd_ack),

    .cpaddr   (28'd0),
    .cpdout   (),
    .cpwr     (),
    .cpreq    (1'b0),
    .cpbusy   ()
);

assign DDRAM_CLK = clk_sys;

//////////////////////////////////////////////////////////////////
// Aspect Ratio + Scale (video_freak)
//////////////////////////////////////////////////////////////////
wire [1:0] ar = status[122:121];
wire [11:0] arx = (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary = (!ar) ? 12'd3 : 12'd0;

video_freak video_freak (
    .CLK_VIDEO  (clk_sys),
    .CE_PIXEL   (ce_pix),
    .VGA_VS     (VGA_VS),
    .HDMI_WIDTH (HDMI_WIDTH),
    .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE     (VGA_DE),
    .VIDEO_ARX  (VIDEO_ARX),
    .VIDEO_ARY  (VIDEO_ARY),
    .VGA_DE_IN  (~(hb | vb)),
    .ARX        (arx),
    .ARY        (ary),
    .CROP_SIZE  (12'd0),
    .CROP_OFF   (5'd0),
    .SCALE      (status[7:5])
);

endmodule

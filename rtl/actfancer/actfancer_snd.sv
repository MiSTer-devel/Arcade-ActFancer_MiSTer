// SPDX-License-Identifier: GPL-3.0-or-later
// Act-Fancer / Trio The Punch — sound CPU subsystem
//
// MAME reference: dataeast/actfancr.cpp::dec0_s_map (lines 196-204)
//
//   0x0000-0x07FF  Sound RAM (2KB)
//   0x0800-0x0801  YM2203 (ym1)
//   0x1000-0x1001  YM3812 (ym2 / OPL2)
//   0x3000         soundlatch read
//   0x3800         OKI M6295 R/W
//   0x4000-0xFFFF  ROM (loaded at $8000 → SDRAM 0x030000 + offset)
//
// NMI ← soundlatch write from main CPU (generic_latch_8.data_pending_callback)
// IRQ ← YM3812 (M6502_IRQ_LINE)

module actfancer_snd
(
    input              clk,           // 21.477 MHz
    input              ce_m6502,      // 1.5 MHz CPU enable
    input              ce_opn,        // 1.5 MHz YM2203 cen
    input              ce_opl,        // 3.0 MHz YM3812 cen
    input              ce_oki,        // 1.024188 MHz OKI cen
    input              rst_n,

    // From main CPU
    input        [7:0] latch_in,
    input              latch_we,      // NMI trigger

    // Sound CPU ROM (64KB SDRAM @ 0x030000, only top 48KB really used = $4000-$FFFF)
    output      [15:0] rom_addr,
    output reg         rom_cs,
    input        [7:0] rom_data,
    input              rom_ok,

    // OKI ROM (256KB @ SDRAM 0x100000)
    output      [17:0] oki_rom_addr,
    output             oki_rom_cs,
    input        [7:0] oki_rom_data,
    input              oki_rom_ok,

    // OSD volume controls (Q4.4 fixed-point, 16 = 100% unity)
    input        [6:0] vol_opn,
    input        [6:0] vol_opl,
    input        [6:0] vol_oki,

    // Combined mono audio
    output signed [15:0] snd_l,
    output signed [15:0] snd_r
);

// ---------------------------------------------------------------
// 6502 instance — T65 (VHDL collaudato).
// MC6502 jtframe NON funziona: CPU stuck su BNE (sim verificata).
// ---------------------------------------------------------------
wire [15:0] cpu_ab;
wire [7:0]  cpu_do;
reg  [7:0]  cpu_di;
wire        cpu_rw_raw;
wire        cpu_rw = cpu_rw_raw;     // T65 R_W_n: 1=read, 0=write
reg         nmi_n;
wire        opl_irqn;
wire        irq_n = opl_irqn;

// CS decode
wire cs_ram   = cpu_ab[15:11] == 5'b00000;          // 0x0000-0x07FF
wire cs_opn   = cpu_ab[15:11] == 5'b00001;          // 0x0800-0x0FFF
wire cs_opl   = cpu_ab[15:11] == 5'b00010;          // 0x1000-0x17FF
wire cs_latch = cpu_ab[15:11] == 5'b00110;          // 0x3000-0x37FF
wire cs_oki   = cpu_ab[15:11] == 5'b00111;          // 0x3800-0x3FFF
wire cs_rom   = cpu_ab[15:14] != 2'b00;             // any access >= 0x4000

wire cpu_rd_latch = cs_latch && cpu_rw;

// NMI: edge-detected from soundlatch write, cleared by sound CPU read of $3000.
// Pattern jtcop_snd (Robocop, same DEC0 sound HW).
reg latch_we_l;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        nmi_n      <= 1'b1;
        latch_we_l <= 1'b0;
    end else begin
        latch_we_l <= latch_we;
        if (cpu_rd_latch && ce_m6502)    nmi_n <= 1'b1;
        else if (latch_we & ~latch_we_l) nmi_n <= 1'b0;
    end
end

// 2KB sound RAM in BRAM — pattern jtcop_snd (read-always, write gated)
reg [7:0] snd_ram[0:2047] /* synthesis ramstyle = "M10K, no_rw_check" */;
reg [7:0] ram_q;
wire snd_ram_we = cs_ram & ~cpu_rw & ce_m6502;
always @(posedge clk) begin
    if (snd_ram_we) snd_ram[cpu_ab[10:0]] <= cpu_do;
    ram_q <= snd_ram[cpu_ab[10:0]];   // always read so ram_q tracks cpu_ab
end

// YM2203
wire [7:0]  opn_dout;
wire signed [15:0] opn_fm;
wire        [ 9:0] opn_psg;
wire signed [15:0] opn_snd;

jt03 u_opn (
    .rst        (~rst_n),
    .clk        (clk),
    .cen        (ce_opn),
    .din        (cpu_do),
    .addr       (cpu_ab[0]),
    .cs_n       (~cs_opn),
    .wr_n       (cpu_rw),
    .dout       (opn_dout),
    .irq_n      (),
    .IOA_in     (8'd0),
    .IOB_in     (8'd0),
    .psg_A      (),
    .psg_B      (),
    .psg_C      (),
    .fm_snd     (opn_fm),
    .psg_snd    (opn_psg),
    .snd        (opn_snd),
    .snd_sample (),
    .debug_view ()
);

// YM3812 (OPL2)
wire [7:0]  opl_dout;
wire signed [15:0] opl_snd;
jtopl2 u_opl (
    .rst    (~rst_n),
    .clk    (clk),
    .cen    (ce_opl),
    .din    (cpu_do),
    .addr   (cpu_ab[0]),
    .cs_n   (~cs_opl),
    .wr_n   (cpu_rw),
    .dout   (opl_dout),
    .irq_n  (opl_irqn),
    .snd    (opl_snd),
    .sample ()
);

// OKI 6295
wire [7:0]  oki_dout;
wire signed [13:0] oki_snd;
jt6295 #(.INTERPOL(0)) u_oki (
    .rst        (~rst_n),
    .clk        (clk),
    .cen        (ce_oki),
    .ss         (1'b1),         // PIN7_HIGH (MAME)
    .wrn        (cpu_rw | ~cs_oki),
    .din        (cpu_do),
    .dout       (oki_dout),
    .rom_addr   (oki_rom_addr),
    .rom_data   (oki_rom_data),
    .rom_ok     (oki_rom_ok),
    .sound      (oki_snd),
    .sample     ()
);
assign oki_rom_cs = 1'b1;

// ROM access (64KB window; offset 0 in this region = SDRAM 0x030000)
assign rom_addr = cpu_ab;
always @(posedge clk) if (ce_m6502) rom_cs <= cs_rom;

// DI mux
always @* begin
    casez ({cs_rom, cs_ram, cs_opn, cs_opl, cs_oki, cs_latch})
        6'b1?????: cpu_di = rom_data;
        6'b01????: cpu_di = ram_q;
        6'b001???: cpu_di = opn_dout;
        6'b0001??: cpu_di = opl_dout;
        6'b00001?: cpu_di = oki_dout;
        6'b000001: cpu_di = latch_in;
        default:   cpu_di = 8'hFF;
    endcase
end

// T65 collaudato (VHDL) — sostituisce MC6502 jtframe che non avanza
// oltre opcode BNE (cfr. sim/tb_snd: PC stuck su $8007 di=$D0).
wire [23:0] t65_a;
assign cpu_ab = t65_a[15:0];
T65 u_cpu (
    .Mode    (2'b00),         // 6502 NMOS
    .Res_n   (rst_n),
    .Enable  (ce_m6502),
    .Clk     (clk),
    .Rdy     (rom_ok),
    .Abort_n (1'b1),
    .IRQ_n   (irq_n),
    .NMI_n   (nmi_n),
    .SO_n    (1'b1),
    .R_W_n   (cpu_rw_raw),
    .Sync    (),
    .EF      (),
    .MF      (),
    .XF      (),
    .ML_n    (),
    .VP_n    (),
    .VDA     (),
    .VPA     (),
    .A       (t65_a),
    .DI      (cpu_di),
    .DO      (cpu_do)
);

// Mixer con volumi OSD Q4.4. Pattern ChinaGate:
//   sample_scaled = (sample * vol_q44) >>> 4
wire signed [15:0] oki_ext  = { {2{oki_snd[13]}}, oki_snd };

// Q4.4 multiplications (signed × unsigned 7-bit)
wire signed [23:0] opn_mul = $signed(opn_snd) * $signed({1'b0, vol_opn});
wire signed [23:0] opl_mul = $signed(opl_snd) * $signed({1'b0, vol_opl});
wire signed [23:0] oki_mul = $signed(oki_ext) * $signed({1'b0, vol_oki});

reg signed [20:0] mix_acc;
always @(posedge clk) begin
    mix_acc <= (opn_mul >>> 4) + (opl_mul >>> 4) + (oki_mul >>> 4);
end

// Saturate
function signed [15:0] sat16(input signed [20:0] v);
    if (v >  $signed(21'sd32767))  sat16 = 16'sd32767;
    else if (v < -$signed(21'sd32768)) sat16 = -16'sd32768;
    else sat16 = v[15:0];
endfunction

assign snd_l = sat16(mix_acc);
assign snd_r = sat16(mix_acc);

endmodule

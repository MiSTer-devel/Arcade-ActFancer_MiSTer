// SPDX-License-Identifier: GPL-3.0-or-later
// Act-Fancer SDRAM bridge — single-bank linear layout (BoogieWings-style).
//
// Layout SDRAM (tutto in bank 0, sd_addr = word16 index lineare):
//   word16 0x000000-0x017FFF  main CPU 192KB byte (96KB word16)  [in BRAM, scritto qui per ridondanza]
//   word16 0x018000-0x01FFFF  sound CPU 64KB byte (32KB word16)
//   word16 0x020000-0x02FFFF  chars 128KB byte (64KB word16)    → PF1
//   word16 0x030000-0x05FFFF  sprite 384KB byte (192KB word16)
//   word16 0x060000-0x07FFFF  tiles 256KB byte (128KB word16)   → PF0
//   word16 0x080000-0x09FFFF  oki 256KB byte (128KB word16)
//
// Convenzione:
//   word16 idx = ioctl byte_addr >> 1 (con region offset rebased).
//   Bridge legge 2 word16 consecutivi per ottenere word32 (4 plane).
//   Tutti i client su bank 0 = niente bank-switching trickery.

module actfancer_sdram_bridge (
    input              clk,
    input              rst,

    // ioctl download stream
    input              ioctl_download,
    input              ioctl_wr,
    input  [24:0]      ioctl_addr,
    input  [ 7:0]      ioctl_dout,
    input  [15:0]      ioctl_index,
    output             ioctl_wait,

    // PF0/PF1/Sprite moved to DDR3 (see ActFancer.sv + actfancer_ddram)
    // Bridge SDRAM ora solo per: download CPU/sound (BRAM mirror) + OKI read

    // OKI (256KB)
    input  [17:0]      oki_byte_addr,
    input              oki_cs,
    output reg [ 7:0]  oki_data,
    output reg         oki_ok,

    // SDRAM 4-port — TUTTI su bank 0, sd_addrN[23:22]=00
    output reg [23:0]  sd_addr0, output reg [15:0] sd_din0, output reg sd_wrl0, output reg sd_wrh0,
    output reg         sd_req0, input              sd_ack0,
    input      [15:0]  sd_dout0,

    output reg [23:0]  sd_addr1, output reg sd_req1, input sd_ack1, input [15:0] sd_dout1,
    output reg [23:0]  sd_addr2, output reg sd_req2, input sd_ack2, input [15:0] sd_dout2,
    output reg [23:0]  sd_addr3, output reg sd_req3, input sd_ack3, input [15:0] sd_dout3
);

    // ==========================================================
    // Layout SDRAM word16 (tutti su bank 0)
    // ==========================================================
    // BASE word16 idx (sd_addr count by 1 = 1 word16 = 2 byte)
    localparam [23:0] CHARS_W16  = 24'h020000;  // chars 64KB word16
    localparam [23:0] SPR_W16    = 24'h030000;  // sprite 192KB word16
    localparam [23:0] TILES_W16  = 24'h060000;  // tiles 128KB word16
    localparam [23:0] OKI_W16    = 24'h080000;  // oki 128KB word16

    // ==========================================================
    // Port 0 — Download writer + OKI reader
    // ==========================================================
    reg  [ 7:0] dl_lo;
    reg  [23:0] dl_addr;
    // SDRAM ora gestisce SOLO: main CPU mirror + sound CPU mirror + OKI
    // Tutto il resto (chars, sprite, tiles) → DDR3 esterno
    wire        in_ddr_range = (ioctl_addr >= 25'h040000) && (ioctl_addr < 25'h100000);
    wire        dl_wr = ioctl_download && ioctl_wr && (ioctl_index == 16'd0) && !in_ddr_range;

    // ioctl backpressure
    reg         dl_wait_r;
    wire        dl_idle = (sd_ack0 == sd_req0);
    assign      ioctl_wait = dl_wait_r;

    // Routing iaddr → sd_addr0 (word16 lineare bank 0)
    function [23:0] dl_route;
        input [24:0] iaddr;
        begin
            if (iaddr < 25'h040000) begin
                // main+audio (CPU): 0x000000-0x03FFFF byte → word16 0x000000-0x01FFFF
                dl_route = {1'b0, iaddr[24:1]};
            end else if (iaddr < 25'h060000) begin
                // chars (PF1): 0x040000-0x05FFFF byte → CHARS_W16 + (offset)/2
                dl_route = CHARS_W16 + {1'b0, (iaddr - 25'h040000) >> 1};
            end else if (iaddr < 25'h0C0000) begin
                // sprite: ora va a DDR3 esterno. Mai chiamato (dl_wr gated).
                dl_route = 24'd0;
            end else if (iaddr < 25'h100000) begin
                // tiles (PF0): 0x0C0000-0x0FFFFF byte → TILES_W16 + (offset)/2
                dl_route = TILES_W16 + {1'b0, (iaddr - 25'h0C0000) >> 1};
            end else begin
                // oki: 0x100000-0x13FFFF byte → OKI_W16 + (offset)/2
                dl_route = OKI_W16 + {1'b0, (iaddr - 25'h100000) >> 1};
            end
        end
    endfunction

    // OKI reader state
    reg [17:0] oki_addr_last;
    reg        oki_need;
    reg        oki_a0_lat;
    reg        oki_busy;

    always @(posedge clk) begin
        if (rst) begin
            sd_addr0 <= 24'd0;
            sd_din0  <= 16'd0;
            sd_wrl0  <= 1'b0;
            sd_wrh0  <= 1'b0;
            sd_req0  <= 1'b0;
            dl_lo    <= 8'd0;
            dl_addr  <= 24'd0;
            dl_wait_r <= 1'b0;
            oki_ok        <= 1'b0;
            oki_need      <= 1'b0;
            oki_busy      <= 1'b0;
            oki_addr_last <= 18'h3FFFF;
        end else begin
            // OKI need detection (combinationally check, latch su clk)
            if (oki_cs && (oki_byte_addr != oki_addr_last)) begin
                oki_need <= 1'b1;
                oki_ok   <= 1'b0;
            end

            // ioctl backpressure: scende quando ack matcha req
            if (dl_wait_r && dl_idle) dl_wait_r <= 1'b0;

            if (dl_wr) begin
                // Download write
                if (~ioctl_addr[0]) begin
                    // Primo byte (LO) della coppia word16
                    dl_lo   <= ioctl_dout;
                    dl_addr <= dl_route(ioctl_addr);
                end else begin
                    // Secondo byte (HI) della coppia → trigger write SDRAM
                    sd_wrl0  <= 1'b1;
                    sd_wrh0  <= 1'b1;
                    sd_din0  <= {ioctl_dout, dl_lo};
                    sd_addr0 <= dl_addr;
                    sd_req0  <= ~sd_req0;
                    dl_wait_r <= 1'b1;
                end
            end else if (!oki_busy && oki_need && !ioctl_download) begin
                // OKI read trigger
                sd_wrl0       <= 1'b0;
                sd_wrh0       <= 1'b0;
                sd_addr0      <= OKI_W16 + {6'd0, oki_byte_addr[17:1]};
                sd_req0       <= ~sd_req0;
                oki_a0_lat    <= oki_byte_addr[0];
                oki_addr_last <= oki_byte_addr;
                oki_need      <= 1'b0;
                oki_busy      <= 1'b1;
            end else if (oki_busy && sd_ack0 == sd_req0) begin
                // OKI read complete: latch byte secondo a0
                oki_data <= oki_a0_lat ? sd_dout0[15:8] : sd_dout0[7:0];
                oki_ok   <= 1'b1;
                oki_busy <= 1'b0;
            end
        end
    end

    // ==========================================================
    // Port 1/2/3 SDRAM — UNUSED (PF0/PF1/sprite tutti su DDR3 ora)
    // ==========================================================
    always @(posedge clk) begin
        if (rst) begin
            sd_addr1 <= 24'd0; sd_req1 <= 1'b0;
            sd_addr2 <= 24'd0; sd_req2 <= 1'b0;
            sd_addr3 <= 24'd0; sd_req3 <= 1'b0;
        end
    end

endmodule

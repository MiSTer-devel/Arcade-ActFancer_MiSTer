// SPDX-License-Identifier: GPL-3.0-or-later
// Single-port BRAM populated via ioctl_download stream.
// Used for CPU program ROMs (main H6280, snd M6502) — total ~256 KB.
//
// During ioctl_download:
//   - if ioctl_addr falls inside [START_ADDR, START_ADDR+SIZE):
//     write to BRAM at (ioctl_addr - START_ADDR)
// During runtime:
//   - cpu_rd: address -> data (1-cycle BRAM read latency)
//
// Inferred as M10K block(s) by Quartus.

// Pattern ChinaGate: download segnali (dl_wr/dl_addr/dl_data) generati
// esternamente; il modulo si limita a scriver/leggere la BRAM.
module actfancer_rom_bram #(
    parameter AW = 18
) (
    input               clk,

    // Download write port
    input               dl_wr,
    input  [AW-1:0]     dl_addr,
    input  [ 7:0]       dl_data,

    // CPU read port (registered → infer M10K)
    input  [AW-1:0]     cpu_addr,
    output reg [7:0]    cpu_data
);
    reg [7:0] mem [0:(1<<AW)-1];
    initial cpu_data = 8'h00;

    always @(posedge clk) begin
        if (dl_wr) mem[dl_addr] <= dl_data;
        cpu_data <= mem[cpu_addr];
    end
endmodule

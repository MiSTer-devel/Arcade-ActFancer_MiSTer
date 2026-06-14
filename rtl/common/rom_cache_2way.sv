// SPDX-License-Identifier: GPL-3.0-or-later
// 2-way block cache davanti a un bridge SDRAM 32-bit con handshake req/ok.
//
// Pattern di jtframe_romrq_bcache:
//   - Memorizza 2 ultime fetch + indirizzo
//   - Quando il consumer richiede addr noto -> data_ok=1 immediato (no roundtrip SDRAM)
//   - Quando addr nuovo -> emette request al bridge, riempie cache, then data_ok=1
//
// Questo permette al BAC06/MXC06 di leggere ROM tile_data senza stallare la pipeline:
//   - Mentre disegna 8 pixel da un tile (= stessa rom_addr), il dato e' in cache.
//   - Quando passa al tile successivo, prima miss -> roundtrip; eventuali tile vicini
//     in cache se gia' visitati.
//
// Lato CONSUMER (verso BAC06):
//   addr_ok   -> consumer richiede dato a `addr`
//   data_ok   -> dato pronto in `dout`
//
// Lato SDRAM (verso bridge):
//   req       -> 1 quando il bridge deve fare una fetch
//   sdram_addr-> indirizzo della fetch (passa direttamente l'addr_req del consumer)
//   sdram_dout-> dato 32-bit di ritorno dal bridge
//   sdram_ok  -> bridge segnala dato valido
//
// Nota: il bridge attuale (actfancer_sdram_bridge.sv) usa un protocollo "cs + addr"
// in cui ok va alto quando il dato e' pronto. Quindi mappiamo:
//   req       -> bridge.rom_cs
//   sdram_addr-> bridge.rom_addr
//   sdram_dout-> bridge.rom_data
//   sdram_ok  -> bridge.rom_ok
//
// Il bridge esistente detecta "new request" su cambio di addr; quindi il req combinatorio
// che il cache emette deve essere stabile ma cambiare addr solo quando vogliamo una nuova
// fetch. Implementato latching addr_req nel ciclo di miss.

module rom_cache_2way #(
    parameter AW = 18,
    parameter DW = 32
)(
    input               rst,
    input               clk,

    // <-> consumer (BAC06)
    input  [AW-1:0]     addr,
    input               addr_ok,
    output reg          data_ok,
    output reg [DW-1:0] dout,

    // <-> bridge SDRAM
    output reg          req,
    output reg [AW-1:0] sdram_addr,
    input  [DW-1:0]     sdram_dout,
    input               sdram_ok
);

    reg [AW-1:0] cached_addr0, cached_addr1;
    reg [DW-1:0] cached_data0, cached_data1;
    reg          valid0, valid1;
    reg          lru;          // 0 = entry 0 piu' vecchia, 1 = entry 1 piu' vecchia
    reg          fetching;
    reg [AW-1:0] fetch_addr;

    wire hit0 = valid0 && (cached_addr0 == addr);
    wire hit1 = valid1 && (cached_addr1 == addr);
    wire hit  = hit0 || hit1;

    always @* begin
        if (hit0)      dout = cached_data0;
        else if (hit1) dout = cached_data1;
        else           dout = cached_data0;   // default to cache 0 while fetching
        data_ok = addr_ok && hit;
    end

    always @(posedge clk) begin
        if (rst) begin
            valid0       <= 0;
            valid1       <= 0;
            cached_addr0 <= 0;
            cached_addr1 <= 0;
            lru          <= 0;
            fetching     <= 0;
            req          <= 0;
            sdram_addr   <= 0;
            fetch_addr   <= 0;
        end else begin
            if (!fetching) begin
                if (addr_ok && !hit) begin
                    // miss -> avvia fetch
                    sdram_addr <= addr;
                    fetch_addr <= addr;
                    req        <= 1;
                    fetching   <= 1;
                end else begin
                    req <= 0;
                end
            end else begin
                // attesa risposta bridge
                if (sdram_ok) begin
                    // memorizza in LRU
                    if (!lru) begin
                        cached_addr0 <= fetch_addr;
                        cached_data0 <= sdram_dout;
                        valid0       <= 1;
                    end else begin
                        cached_addr1 <= fetch_addr;
                        cached_data1 <= sdram_dout;
                        valid1       <= 1;
                    end
                    lru      <= ~lru;
                    fetching <= 0;
                    req      <= 0;
                end
            end
        end
    end

endmodule

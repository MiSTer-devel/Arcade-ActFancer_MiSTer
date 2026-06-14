derive_pll_clocks
derive_clock_uncertainty

# ============================================================================
# Act-Fancer — core specific timing constraints
# ============================================================================
# clk_sys = 96 MHz (10.416 ns).
# Main CPU pacing (HUC6280):
#   ce_h6280 = clk_sys / 13 ≈ 7.16 MHz (jtframe_frac_cen 1/13).
#   HUC6280 registers update only on ce_h6280 ticks.
# Sound CPU pacing (T65 / jt65c02):
#   t65 cen ≈ 1.5 MHz (clk_sys / 64 nominal).
# Path BRAM_porta(write CPU @ ce) -> CPU registers (read @ next ce):
#   Setup window reale = numero di cicli clk_sys tra due ce consecutivi.
# ============================================================================

# ---------------------------------------------------------------------------
# pll_audio (se non collegato): false_path elimina rumore
# ---------------------------------------------------------------------------
set_false_path -from [get_clocks {pll_audio|*|divclk}]
set_false_path -to   [get_clocks {pll_audio|*|divclk}]

# Nota: CDC tra HPS DDR, pll_audio, pll_hdmi e core clk_sys e` gia` gestita
# da sys/sys_top.sdc tramite set_clock_groups -exclusive. Per questo serve
# che l'istanza PLL nel core abbia nome `pll` (matcha pattern *|pll|pll_inst|*).

# ===========================================================================
# HUC6280 (main CPU) - clock enable ~7.16 MHz (clk_sys / 13).
# Tutti i path interni al modulo HUC6280 e i path BRAM/cache -> HUC6280
# hanno una setup window reale di 13 cicli clk_sys.
# Pattern get_registers matcha qualsiasi registro dentro istanze HUC6280_*.
# ===========================================================================

# Multicycle 13/12 sui path BRAM port?_we_reg -> HUC6280 (BRAM scrive @ ce, CPU
# legge @ ce successivo, almeno 6-7 cicli dopo).
set_multicycle_path -setup -end 13 \
    -from [get_registers {*altsyncram*ram_block*~port?_we_reg*}] \
    -to   [get_registers {*HUC6280*|*}]
set_multicycle_path -hold  -end 12 \
    -from [get_registers {*altsyncram*ram_block*~port?_we_reg*}] \
    -to   [get_registers {*HUC6280*|*}]

# Multicycle 13/12 sui path interni HUC6280 (registri CPU aggiornati solo su
# ce_h6280, qualsiasi coppia di registri interni ha setup window 13 cicli).
set_multicycle_path -setup -end 13 \
    -from [get_registers {*HUC6280*|*}] \
    -to   [get_registers {*HUC6280*|*}]
set_multicycle_path -hold  -end 12 \
    -from [get_registers {*HUC6280*|*}] \
    -to   [get_registers {*HUC6280*|*}]

# Multicycle 13/12 sui path HUC6280 -> SDRAM/BRAM cache (cpu_addr/cpu_dout)
# pilotano logiche di indirizzo cache che vengono lette dalla CPU al ce
# successivo. Window reale = 13 cicli.
set_multicycle_path -setup -end 13 \
    -from [get_registers {*HUC6280*|*}] \
    -to   [get_registers {*rom_bram*|* *rom_cache*|*}]
set_multicycle_path -hold  -end 12 \
    -from [get_registers {*HUC6280*|*}] \
    -to   [get_registers {*rom_bram*|* *rom_cache*|*}]

set_multicycle_path -setup -end 13 \
    -from [get_registers {*rom_bram*|* *rom_cache*|*}] \
    -to   [get_registers {*HUC6280*|*}]
set_multicycle_path -hold  -end 12 \
    -from [get_registers {*rom_bram*|* *rom_cache*|*}] \
    -to   [get_registers {*HUC6280*|*}]

# Multicycle 13/12 sui path dip_sw -> HUC6280.
# dip_sw e` caricato da ioctl_wr una volta all'avvio, poi statico.
# HUC6280.D viene campionato solo su ce_h6280 (1 ogni 13 ck).
set_multicycle_path -setup -end 13 \
    -from [get_registers {*emu|dip_sw[*]}] \
    -to   [get_registers {*HUC6280*|*}]
set_multicycle_path -hold  -end 12 \
    -from [get_registers {*emu|dip_sw[*]}] \
    -to   [get_registers {*HUC6280*|*}]

# Multicycle 13/12 sui path hps_io -> HUC6280.
# hps_io.cfg, joystick_0/1, status sono registri statici/lenti.
set_multicycle_path -setup -end 13 \
    -from [get_registers {*hps_io:u_hps_io|*}] \
    -to   [get_registers {*HUC6280*|*}]
set_multicycle_path -hold  -end 12 \
    -from [get_registers {*hps_io:u_hps_io|*}] \
    -to   [get_registers {*HUC6280*|*}]

# ===========================================================================
# T65 / jt65c02 (sound CPU) - clock enable ~1.5 MHz (clk_sys / 64 nominal).
# Path interni e BRAM->T65 hanno setup window molto piu` ampia.
# Usiamo 16/15 (conservativo) per evitare false alarm su path ce molto lento.
# ===========================================================================

# Multicycle 16/15 sui path BRAM port?_we_reg -> T65/jt65c02.
set_multicycle_path -setup -end 16 \
    -from [get_registers {*altsyncram*ram_block*~port?_we_reg*}] \
    -to   [get_registers {*T65*|* *jt65c02*|*}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*altsyncram*ram_block*~port?_we_reg*}] \
    -to   [get_registers {*T65*|* *jt65c02*|*}]

# Multicycle 16/15 sui path interni T65/jt65c02 (registri aggiornati su ce).
set_multicycle_path -setup -end 16 \
    -from [get_registers {*T65*|* *jt65c02*|*}] \
    -to   [get_registers {*T65*|* *jt65c02*|*}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*T65*|* *jt65c02*|*}] \
    -to   [get_registers {*T65*|* *jt65c02*|*}]

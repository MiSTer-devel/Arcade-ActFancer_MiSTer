# Authors and Credits

## ActFancer_MiSTer core

**Author**: Umberto Parisi ([rmonic79](https://github.com/rmonic79))

The original RTL source files for the Act-Fancer-specific logic (under
`rtl/actfancer/` and the project wrapper `ActFancer.sv`) are copyright
Umberto Parisi and distributed under GNU GPL v3 or later.

The standalone **Analog VGA H-Size** module (`sys/analog_hsize.sv`) is
also authored by Umberto Parisi (originally released as the
[MiSTer-AnalogHStretch](https://github.com/rmonic79/MiSTer-AnalogHStretch)
standalone repository) and is reused here under GPL-3.

## Third-party components

This core builds on top of excellent open-source projects. All third-party
sources retain their original copyright and license. The core as a whole
is distributed under **GNU GPL v3 or later** to stay compatible with the
most restrictive upstream (JTFRAME / JTCORES).

| Component | Author | Project | License |
|-----------|--------|---------|---------|
| **HUC6280** — HuC6280 main CPU (VHDL) | Mike Johnson / Wolfgang Scherr et al. | upstream VHDL HuC6280 implementation | GPL-3 |
| **T65** — 6502 NMOS CPU (VHDL) | Daniel Wallner | OpenCores T65 | BSD / GPL |
| **JTFRAME / JTCORES** — framework, filters, tilemap, etc. | Jose Tejada ([@topapate](https://twitter.com/topapate)) | [jotego/jtcores](https://github.com/jotego/jtcores) | GPL-3 |
| **JT03** — YM2203 (OPN) FM/PSG synthesizer | Jose Tejada | [jotego/jt12](https://github.com/jotego/jt12) | GPL-3 |
| **JTOPL** — YM3812 (OPL2) FM synthesizer | Jose Tejada | [jotego/jtopl](https://github.com/jotego/jtopl) | GPL-3 |
| **JT6295** — OKI M6295 ADPCM sample player | Jose Tejada | [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3 |
| **jtcop_bac06 / jtcop_obj** — DECO BAC06 tilemap + MXC06 sprite primitives | Jose Tejada | [jotego/jtcores](https://github.com/jotego/jtcores) | GPL-3 |
| **sdram.sv** — SDRAM controller | Sorgelig ([sorgelig](https://github.com/sorgelig)) | [MiSTer-devel](https://github.com/MiSTer-devel) | GPL-3 |
| **sys/ framework** — MiSTer HPS/IO, OSD, video scaler, audio | Sorgelig / MiSTer-devel | [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3 |

## Reference

- **Act-Fancer Cybernetick Hyper Weapon arcade hardware** — Data East
  Corporation, 1989. ROMs are **not** included and must be provided by
  the user.

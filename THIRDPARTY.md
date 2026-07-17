# Third-party components

| Component | Version | License | Location |
|---|---|---|---|
| SeaBIOS (`bios.bin`) | rel-1.16.3-retvrn99 | LGPLv3 | `vendor_local/seabios/`, `assets/seabios/` |
| Bochs VGABIOS (`vgabios.bin`) | commit `6563908d0f54b7699b6adb13e0f0503ef8d84cfc` | LGPL-2.0-or-later | `vendor_local/vgabios/`, `assets/vgabios/` |
| IBM VGA 8x16 font (`vga8x16.bin`) | int10h vga-text-mode-fonts `PC-IBM/VGA8.F16` | not copyrightable bitmap data; CC BY-SA 4.0 renditions | `assets/font/` |
| Libre Franklin (`libre-franklin.ttf`) | Google Fonts blob `8cf5549196f5e98dc27be05fc2b3691e77eaa89c` | SIL Open Font License 1.1 | `assets/font/` |
| odin-imgui (Dear ImGui v1.92.8-docking bindings + prebuilt `imgui_windows_x64.lib`, SDL3/SDLRenderer3 backends) | commit `a116eb1` (2026-07-07) | MIT | `vendor_local/imgui/` |
| IzarraVM algorithm and test references | commit `d930de57acccbc6a70cda8cc5a603173bf23cd1c` | GPL-3.0-only | selectively adapted in `src/`; see `src/IZARRAVM_NOTICE.md` |
| patcher9x Windows 98 TLB patch data and W3/W4 decoding reference | commit `b6e30d4b5a396dcd453b6c8e6733fd5b5cbce59e` | MIT | adapted in `src/win98imageprep/`; see `src/win98imageprep/PATCHER9X_NOTICE.md` |

Details per component in each directory's `LICENSE-NOTES.md`.

The CRT presentation shader in `assets/shaders/` is adapted from IzarraVM's
GPL-3.0-only shader and is distributed under RETVRN99's GPL-3.0-only license.

The legacy VGA implementation uses DOSBox-X commit
[`f3483ce0bda88c977dc266924fa36c15ce7eb5f8`](https://github.com/joncampbell123/dosbox-x/commit/f3483ce0bda88c977dc266924fa36c15ce7eb5f8)
as a GPL-2.0-or-later behavioral and algorithmic reference. DOSBox-X source is
not vendored here; adapted code retains upstream attribution in its source
header.

# Third-party components

| Component | Version | License | Location |
|---|---|---|---|
| SeaBIOS (`bios.bin`) | rel-1.16.3-retvrn99 | LGPLv3 | `vendor_local/seabios/`, `assets/seabios/` |
| SeaVGABIOS (`vgabios-stdvga.bin`) | rel-1.16.3 (QEMU v9.0.0 `pc-bios/`) | LGPLv3 | `assets/seabios/` |
| IBM VGA 8x16 font (`vga8x16.bin`) | int10h vga-text-mode-fonts `PC-IBM/VGA8.F16` | not copyrightable bitmap data; CC BY-SA 4.0 renditions | `assets/font/` |
| odin-imgui (Dear ImGui v1.92.8-docking bindings + prebuilt `imgui_windows_x64.lib`, SDL3/SDLRenderer3 backends) | commit `a116eb1` (2026-07-07) | MIT | `vendor_local/imgui/` |

Details per component in each directory's `LICENSE-NOTES.md`.

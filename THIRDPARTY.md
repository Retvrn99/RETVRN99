# Third-party components

| Component | Version | License | Location |
|---|---|---|---|
| SeaBIOS (`bios.bin`) | rel-1.16.3-retvrn99 | LGPLv3 | `vendor_local/seabios/`, `assets/seabios/` |
| Bochs VGABIOS (`vgabios.bin`) | commit `6563908d0f54b7699b6adb13e0f0503ef8d84cfc` | LGPL-2.0-or-later | `vendor_local/vgabios/`, `assets/vgabios/` |
| IBM VGA 8x16 font (`vga8x16.bin`) | int10h vga-text-mode-fonts `PC-IBM/VGA8.F16` | not copyrightable bitmap data; CC BY-SA 4.0 renditions | `assets/font/` |
| Libre Franklin (`libre-franklin.ttf`) | Google Fonts blob `8cf5549196f5e98dc27be05fc2b3691e77eaa89c` | SIL Open Font License 1.1 | `assets/font/` |
| Chicago95 icon theme | commit `abadacfbda68c0031e051d15dadd3c287b75afe2` | GPL-3.0-or-later (upstream also declares MIT) | `assets/icons/chicago95/` |
| 86Box drive-audio state model (no recordings vendored) | commit `82c0e7a3ca74da1f52682544d533b58f6665e9bd` | GPL-2.0-or-later | behavior adapted in `src/audio/mechanical.odin`; see `docs/drive-sounds.md` |
| odin-imgui (Dear ImGui v1.92.8-docking bindings + prebuilt `imgui_windows_x64.lib`, SDL3/SDLRenderer3 backends) | commit `a116eb1` (2026-07-07) | MIT | `vendor_local/imgui/` |
| IzarraVM algorithm and test references | commits `d930de57acccbc6a70cda8cc5a603173bf23cd1c` and `b88a9fe68a8109f26632ff2802262cc38a6a5ad9` | GPL-3.0-only | selectively adapted in `src/`; see `src/IZARRAVM_NOTICE.md` |
| patcher9x Windows 98 TLB patch data and W3/W4 decoding reference | commit `b6e30d4b5a396dcd453b6c8e6733fd5b5cbce59e` | MIT | adapted in `src/win98imageprep/`; see `src/win98imageprep/PATCHER9X_NOTICE.md` |

Details per component in each directory's `LICENSE-NOTES.md`.

The optional Bigfoot HDD recordings are by Toni Riikonen (`Domppari`). The Alps
source recordings are by Andres del Campo (`andresdelcampo`) under CC BY 4.0;
the 86Box FDD credits identify Agetian and Domppari as the editors who added
seek/step-down support. These files are discovered from a user-supplied 86Box
assets tree. The loader targets 86Box assets commit
[`f06840ba5cb7cd3d42f1faa7fe418871a3b3be52`](https://github.com/86Box/assets/commit/f06840ba5cb7cd3d42f1faa7fe418871a3b3be52).
The repository does not clearly license the adapted files or the editors'
contributions for redistribution, so RETVRN99 does not copy, bundle, hash, or
redistribute any of its WAV files. Exact filenames, source links, and
provenance commits are documented in `docs/drive-sounds.md`.

The CRT presentation shader in `assets/shaders/` is adapted from IzarraVM's
GPL-3.0-only shader and is distributed under RETVRN99's GPL-3.0-only license.

The legacy VGA implementation and SB16 command framing use DOSBox-X commit
[`f3483ce0bda88c977dc266924fa36c15ce7eb5f8`](https://github.com/joncampbell123/dosbox-x/commit/f3483ce0bda88c977dc266924fa36c15ce7eb5f8)
as a GPL-2.0-or-later behavioral and algorithmic reference. DOSBox-X source is
not vendored here; adapted code retains upstream attribution in its source
header.

The exact Windows 98 driver and graphics sources in
`drivers/win98/upstream.lock.tsv` are pinned planned or reference inputs.
VMDisp9x and VMHAL9x are adapted into local derived build trees; their upstream
MIT notices remain in those trees. Neither external repository nor compiled
driver output is committed to RETVRN99. Locally built GSW-VGA payloads retain
the applicable upstream notices and RETVRN99's GPL-3.0-only adaptation terms.

The Windows 98 driver build feasibility proof uses the official Open Watcom
C/C++ 1.9 archive and extracted toolchain pinned by
`drivers/win98/toolchain.lock.json`. Neither the archive nor its extraction is
vendored or distributed by RETVRN99. The lock records integrity and build
environment metadata only; Open Watcom's own license remains applicable to a
locally acquired copy.

The VMHAL9x-derived build uses a pinned MSYS2 MinGW32 GCC 15.2.0 extraction in
`drivers/win98/mingw32-toolchain.lock.json`. The extraction is not vendored or
distributed. `gswhal9x.dll` and `gswdd32.dll` statically use GCC support code
under the GCC Runtime Library Exception; the compiler and runtime's own license
terms remain applicable to the locally acquired toolchain.

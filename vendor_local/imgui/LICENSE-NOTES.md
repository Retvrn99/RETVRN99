# vendor_local/imgui

Vendored subset of **odin-imgui** (Odin bindings for Dear ImGui generated with
`dear_bindings`), commit `a116eb1ceaa6acde60219efdd56bf6c2e1aedf4c`
(2026-07-07), Dear ImGui version `v1.92.8-docking`.

- Upstream binding project: https://gitlab.com/L-4/odin-imgui (maintained fork used here)
- Dear ImGui: https://github.com/ocornut/imgui (MIT)
- License: MIT (see `LICENSE` in this directory). MIT is one-way compatible
  with this project's GPLv3-only license.

Contents kept: core bindings (`imgui.odin`, `imgui_internal.odin`,
`imconfig.odin`, `imgui_manual.odin`, `lib_name.odin`), the prebuilt static
library `imgui_windows_x64.lib` (compiled from upstream `build.py` with all
backends enabled, including `sdl3` and `sdlrenderer3`), and the two backend
binding packages `imgui_impl_sdl3/` and `imgui_impl_sdlrenderer3/`.
Everything else (examples, generators, other backends, wasm objects) was not
vendored. Binding files are generated upstream and kept verbatim (exempt from
the local file-length rule).

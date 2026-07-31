# RETVRN99 CRT presentation shader

- `retvrn99-crt.hlsl` adapts the CRT presentation formulas from IzarraVM
  commit `d930de57acccbc6a70cda8cc5a603173bf23cd1c`. Both projects license this
  code under GPL-3.0-only.
- Its neutral scaler adapts Libretro's public-domain `sharp-bilinear-simple`
  coordinate remapping:
  <https://github.com/libretro/slang-shaders/blob/master/pixel-art-scaling/shaders/sharp-bilinear-simple.slang>.
- `retvrn99-crt.spv` is the precompiled form of that source for SDL3's Vulkan
  GPU renderer.
- `gsw3d-triangle.hlsl` is RETVRN99's GPL-3.0-only POSITIONT and D3DCOLOR proof
  shader. Its `.vert.spv` and `.frag.spv` files are the precompiled forms for
  SDL3's Vulkan GPU backend.
- The checked-in binaries were built with Microsoft DirectX Shader Compiler
  `v1.9.2602.24`. The x64 release files used for the recorded build have these
  SHA-256 values: `dxc.exe`
  `1367FD29D0EBBA5BF10D1041A9DEFF85396D30090B3651D872EC65D11A476EA4`,
  `dxcompiler.dll`
  `9B5E10ED756C461B4EC2C83A99F1D6ACE20E97826E9C0B0E966B7B1CD6F2AEC6`, and
  `dxil.dll`
  `CBCFE883A09FD0CA1F98ABDF3A9553B560895E3283A136DA82A8381253A169DF`.
  Rebuild all checked-in shaders with `tools/shaders/build.ps1`; add `-Verify`
  to compile into temporary files and require byte-identical SHA-256 results.

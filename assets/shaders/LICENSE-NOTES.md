# RETVRN99 CRT presentation shader

- `retvrn99-crt.hlsl` adapts the CRT presentation formulas from IzarraVM
  commit `d930de57acccbc6a70cda8cc5a603173bf23cd1c`. Both projects license this
  code under GPL-3.0-only.
- `retvrn99-crt.dxil` and `retvrn99-crt.spv` are precompiled forms of that
  source for SDL3's Direct3D 12 and Vulkan GPU renderers.
- The checked-in binaries were built with Microsoft DirectX Shader Compiler
  `v1.9.2602.24`. Rebuild them with `tools/shaders/build.ps1`.

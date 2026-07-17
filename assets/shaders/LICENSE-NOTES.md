# RETVRN99 CRT presentation shader

- `retvrn99-crt.hlsl` adapts the CRT presentation formulas from IzarraVM
  commit `d930de57acccbc6a70cda8cc5a603173bf23cd1c`. Both projects license this
  code under GPL-3.0-only.
- `retvrn99-crt.spv` is the precompiled form of that source for SDL3's Vulkan
  GPU renderer.
- The checked-in binary was built with Microsoft DirectX Shader Compiler
  `v1.9.2602.24`. Rebuild it with `tools/shaders/build.ps1`.

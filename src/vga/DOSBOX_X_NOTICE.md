# DOSBox-X VGA algorithm notice

The VGA latch, raster-operation, write-mode, odd/even, and chain-four
algorithms in `memory.odin`, and the related pixel-expansion logic in
`scanout.odin`, were selectively adapted from:

- DOSBox-X `src/hardware/vga_memory.cpp`
- DOSBox-X `src/hardware/vga_draw.cpp`
- pinned upstream commit `f3483ce`

Copyright (C) 2002-2021 The DOSBox Team.

Those upstream files are licensed under GPL-2.0-or-later. RETVRN99's adapted
Odin implementation is distributed under GPL-3.0-only, a permitted later
version, and retains this attribution and source provenance.

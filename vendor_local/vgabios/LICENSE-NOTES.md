# Bochs VGABIOS vendored source

This directory is based on the source snapshot of
[`bochs-emu/VGABIOS`](https://github.com/bochs-emu/VGABIOS) commit
`6563908d0f54b7699b6adb13e0f0503ef8d84cfc`, committed upstream on
30 December 2025. Git metadata is omitted and `.version` records the exact
upstream revision.

RETVRN99 adds one compatibility fix in `vgabios/vbe.c`: the VBE image-page
calculation clamps before a 16-bit `DIV` when the quotient cannot fit. Without
that guard, enumerating 800x600x4 with a 32 MiB DISPI aperture raises #DE before
the function's existing 256-page clamp. No mode tables or firmware interfaces
are changed.

Upstream source headers grant LGPL-2.0-or-later and the repository ships the
LGPL-2.1 license text in `LICENSE` and `vgabios/COPYING`. Files retain their
upstream notices.

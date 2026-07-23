<!-- SPDX-License-Identifier: GPL-3.0-only -->

# vmhal9x GSW-VGA derived source

This recipe adapts the exact `vmhal9x` commit and gitlinks recorded by the
pinned source checkout. The preparation pipeline copies the clean source,
applies the lexical patch set, and copies the GSW overlay plus shared ABI into
the derived tree. Upstream notices remain in that tree; RETVRN99's new bridge,
backend, build profile, definitions, and resources are GPL-3.0-only.

Build the prepared tree with the pinned MinGW32 environment:

```text
mingw32-make.exe -f gsw.mk gsw
```

The bounded output set is `gswhal9x.dll` and `gswdd32.dll`. The build links no
Mesa, OpenGL, Direct3D, VESA, or tray payload. Fixed image bases, resource
versions, and linker timestamps keep the outputs reproducible.

`gswhal9x.dll` implements the conservative DirectDraw HAL callbacks. It
defers surface allocation to DirectDraw, then lazily registers only
video-memory surfaces with bounded framebuffer offsets and supported RGB
formats. It forwards fill/blit/stretch/color-key/present operations through
generation-tagged surface IDs and returns `DDHAL_DRIVER_NOTHANDLED` for
unsupported flags so DirectDraw can use its software path. `gswdd32.dll` is the
narrow DeviceIoControl bridge to the display VxD. HAL initialization fails
unless the bridge ABI, capability mask, and framebuffer identity match.

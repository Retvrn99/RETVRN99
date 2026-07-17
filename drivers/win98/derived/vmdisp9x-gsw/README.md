<!-- SPDX-License-Identifier: GPL-3.0-only -->

# vmdisp9x GSW-VGA derived source

This recipe adapts the exact `vmdisp9x` commit recorded in
`drivers/win98/upstream.lock.tsv`. The preparation pipeline copies that clean
source tree, applies every patch in `patches/` in lexical order, and then
copies `overlay/` over its root. The pinned source checkout must also have its
`fixlink` gitlink populated at the commit recorded by the parent tree. The
upstream MIT notice remains part of the derived tree; RETVRN99's new transport
and integration sources are GPL-3.0-only.

Build the prepared tree with the pinned Open Watcom 1.9 environment:

```text
wmake.exe -f gsw.mak gsw
```

`gsw.mak` selects the release profile, leaving upstream `DBGPRINT` and serial
logging disabled. Its prerequisites include only objects linked into the GSW
driver pair.

The bounded output set is `gswmini.drv`, `gswmini.vxd`, and the source
`gswmini.inf`. The Win16 normalizer must run on `gswmini.drv` before its final
size and SHA-256 are recorded.

The driver retains the QEMU/Bochs VBE mode programming used by the real VGA
BIOS, then mirrors Windows mode sets and flips to GSW-VGA ABI v2. Its VxD:

- accepts only `PCI\VEN_FFFE&DEV_0002` with the expected private capability;
- probes BAR sizes with memory decode disabled, then maps the current 4 KiB
  BAR0 and advertised BAR1 rather than assuming their reset addresses;
- allocates one fixed, zeroed, physically contiguous 4 KiB guest ring;
- submits one bounded command at a time and requires synchronous head and
  nonzero-fence completion before reusing ring storage;
- presents surface offsets without framebuffer copies; and
- initializes the small upstream WRAM metadata allocation before FBHDA and
  cursor code can dereference it.

`GSW_transport_fill` and `GSW_transport_copy` are callable VxD-side helpers,
but this package does not install VMHAL9x or advertise DirectDraw acceleration.
Its bootstrap 16-bit driver declines the DirectDraw 32-bit-driver query rather
than naming an absent VMHAL DLL, and it declines the OpenGL ICD escape rather
than naming an absent Mesa DLL. The helpers become the backend for the
separately proof-gated DirectDraw port.

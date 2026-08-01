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

The bounded output set from this recipe is `gswmini.drv`, `gswmini.vxd`, and
the source `gswmini.inf`. The complete install set also requires
`gswhal9x.dll` and `gswdd32.dll` from the paired `vmhal9x-gsw` recipe. The INF
copies all five files to the Windows system directory, so staging must reject
an incomplete set. The Win16 normalizer must run on `gswmini.drv` before its
final size and SHA-256 are recorded.

The 0.2.0.8 patch set preserves the existing low-resolution rejection except
for exactly 320x240x8, and the INF exposes only that added low mode. The display
arbiter owns firmware, Windows desktop, and foreground VGA authority through
VDD transitions and the existing DirectDraw-exclusive messages. Stable Windows
ownership consumes unauthorized legacy and DISPI mode changes without granting
mode 13h special authority. Driver disable cancels transitions, bypasses DISPI
trapping, and permits only the Windows mode 3 or 83h BIOS restoration before
unhooking. The private VBE operation reports its real completion but does not
self-authorize a transition, and the pinned VDD `SAVE_REGISTERS` callback
remains a no-op. Desktop return commits through the directional VDD POST only
when its fresh physical-owner observation agrees.

Terminal shutdown follows the Win9x VxD phases without assuming the Win16
driver received `Disable`. `System_Exit` first publishes forward-only firmware
authority, bypasses DISPI trapping, disables the extension directly, and
restores the borrowed VDD dispatch. A failed INT 10h unhook cannot strand
terminal cleanup, but still rejects dynamic unload. `Sys_Critical_Exit` only
retries an outstanding owned hook and repeats that bounded quiescence; it never
enters BIOS, waits, allocates, or invokes general device teardown.

Patch 0013 supersedes the screen-switch re-entry workaround in patch 0012. A
retained A/B run showed that workaround changed neither the first divergent
state nor the shutdown outcome, so the final derived source restores the prior
Win16 hook behavior and records ordered disable markers instead. Guest mode
return and shutdown remain runtime acceptance gates; source or build success
alone does not establish either result.

The driver retains the QEMU/Bochs VBE mode programming used by the real VGA
BIOS, then mirrors Windows mode sets and flips to GSW-VGA ABI v2. Its VxD:

- accepts only `PCI\VEN_FFFE&DEV_0002` with the expected private capability;
- probes BAR sizes with memory decode disabled, then maps the current 4 KiB
  BAR0 and advertised BAR1 rather than assuming their reset addresses;
- allocates one fixed, zeroed, physically contiguous 4 KiB guest ring;
- submits one bounded command at a time and requires synchronous head and
  nonzero-fence completion before reusing ring storage;
- owns a separate fixed 4 KiB GSW3D ring and a bounded 64 KiB staging region,
  and exposes context, submit, upload, present, and fence-poll DIOCs only when
  the host advertises the guarded SVGA9 proof capabilities;
- presents surface offsets without framebuffer copies; and
- initializes the small upstream WRAM metadata allocation before FBHDA and
  cursor code can dereference it.

The v3 transport registers bounded framebuffer surfaces and exposes validated
fill, blit, present, and dirty-range commands. The bootstrap 16-bit driver names
`gswhal9x.dll` only in this GSW DirectDraw build, while continuing to decline
the OpenGL ICD escape. The HAL and VxD fail closed when their exact bridge ABI
or framebuffer identity does not match.

<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0003: Windows 98 setup driver bundles

## Status

Accepted

## Context

Guided installation already copies the validated Windows 98 `WIN98` directory
into bounded host scratch and imports it into `C:\GSWSETUP` through one stopped-
machine Edit transaction. RETVRN99 needs to enable the inbox IDE DMA policy now
and will later provide GSW VGA and sound drivers. Rewriting a user-owned ISO,
embedding language-specific Microsoft INFs, running the GUI-only `INFINST.EXE`,
or mutating an installed system with unrelated one-off mechanisms would make
that path difficult to validate across Spanish, English, and Korean media.

Windows 98 also contains a VMM TLB-invalidation bug exposed by modern host
processors even through hardware virtualization. Guided Setup therefore uses
the same bounded source-copy seam for a separate, mandatory compatibility
overlay. It extracts `VMM32.VXD`, applies only the reviewed TLB transformation,
and places the result loose without enabling unrelated CPU, memory, or driver
patches.

Windows 9x Setup treats a loose file already known to its layout metadata as a
replacement for the same file in a CAB. Brand-new Plug and Play INFs are
different: they must be copied during precopy and registered with Setup through
`CUSTOM.INF`. Microsoft InfInst performs that registration but is interactive,
modifies matching inbox INFs on PnP-ID collisions, and is not suitable as a
runtime dependency.

## Decision

RETVRN99 applies typed internal `Driver_Bundle` manifests to the writable Setup
copy before it enters the image transaction. The user ISO remains read-only.
Bundle processing is deterministic, bounded, idempotent, and fails closed on
unsafe paths, duplicate package identities, cross-bundle PnP-ID collisions, or
case-insensitive and 8.3 filename collisions. The shipped DMA policy is the
first stock overlay; no RETVRN99 PnP driver payload ships yet.

Four bundle kinds keep Setup phases explicit:

- `Stock_Overlay` extracts the complete localized CAB member, patches only
  declared sections and keys byte-preservingly, and places it loose in the
  Setup root under the exact known filename. `MSHDC.INF` and `DISKDRV.INF` use
  this mode for `IDEDMADrive0` through `IDEDMADrive3` defaults.
- `PnP_Driver` defines the manifest and `CUSTOM.INF` merge contract for a
  Windows 9x `$CHICAGO$` hardware INF and its declared payload. The pure merger
  is implemented now; the content Adapter added with the first GSW driver must
  validate the actual INF, payload, and inbox-ID conflicts before invoking it.
  GSW VGA and sound will use this mode.
- `Early_Setup` is reserved for a future driver required before normal PnP
  enumeration, such as boot storage or installation media. It may additionally
  participate in Setup's `load_inf` phase.
- `Post_Setup_Component` is reserved for optional non-PnP INF components with
  an explicit install section. It cannot be used to force hardware binding.

The merger preserves an OEM-provided `CUSTOM.INF`, appends only RETVRN99-owned
sections and references, and never comments out a competing hardware ID.
Cross-bundle collisions are rejected now. Before the first PnP payload ships,
its content Adapter must also compare declared IDs with the Setup inbox INFs;
an inbox collision requires an explicit reviewed replacement manifest. Driver
binaries are installed by each hardware INF's own `CopyFiles` sections. Every
dependent INF must be listed as its own bundle.

InfInst's 545-file `WININF` directory is an analysis cache used by its
interactive collision workflow, not Setup registration metadata. RETVRN99 does
not reproduce it. The relevant on-disc contract is the loose driver content and
the root `CUSTOM.INF`: the driver INF is copied through LDID 2 during precopy
and through LDID 17 into `Windows\INF`; payload files remain governed by the
driver INF itself.

`MSBATCH.INF` keeps `DevicePath=0`; Windows 98's value is a policy switch for
retaining the Setup source as a later search location, not a modern path list.
`Windows\INF\OTHER` is treated as Setup's installed OEM cache, not as a source-
integration API. The existing post-Setup IDE INF check and registry import are
retained as an idempotent recovery and compatibility safety net until fresh
localized installations prove the stock overlay at first enumeration.

Host CAB decompression is behind a narrow extraction Adapter. Windows uses the
Cabinet FDI API for multi-volume LZX sets; another host can provide the same
bounded interface without changing bundle or INF semantics.

## Consequences

- Driver integration shares the existing transactional installation path and
  cannot partially modify the hard-drive image.
- Microsoft-owned localized bytes originate from the user's media and retain
  their source code page, comments, line endings, and EOF convention.
- GSW VGA and sound can be added as data-driven packages without teaching the
  sidecar or GUI about individual drivers.
- The Windows cabinet implementation is platform-specific, but the package
  model, validation, collision policy, and Setup output are portable.
- A fresh Spanish OEM install and Korean byte/path tests remain required before
  this installation policy is considered proven.

## References

- [Microsoft Cabinet FDI API](https://learn.microsoft.com/en-us/windows/win32/api/fdi/)
- [VOGONS discussion of loose Setup files and new INF registration](https://www.vogons.org/viewtopic.php?t=91993)
- [Windows 95D unattended media customization background](https://drevonor.com/win95d.php)
- [Patcher9x Windows 98 TLB patch](https://github.com/JHRobotics/patcher9x)

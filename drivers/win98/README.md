<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Windows 98 driver build and packaging

This directory contains the pinned source, toolchain, derivation, build, and
staging metadata for the GSW-VGA Windows 98 display package. Compiled payloads
remain external to Git and are produced only into a previously absent output
root.

## Immutable inputs

`upstream.lock.tsv` pins every reviewed upstream by exact origin and commit.
The source verifier also checks initialized gitlinks and performs no clone or
fetch:

```powershell
.\scripts\verify-win98-driver-sources.ps1 -SourceRoot D:\src\retvrn99-win98
```

Rows marked `planned-component` link a raw-SHA-256-pinned closure manifest that
also names the lock row's owning commit. A ready closure must
enumerate each selected regular Git blob with its byte count, SHA-256,
allowlisted file-level license expression, notice binding, source-prefix ID,
and role. Prefixes are exact named subtrees or the explicit
`exact-root-files` mode, which covers only separately listed root files. They
never imply recursive copying or globs. Notices form their own exact blob
inventory, and every source file must bind to one notice with the same approved
license expression. The schema carries a closed, curated license-expression
allowlist. Its narrowly scoped additions include `SGI-B-2.0`,
`LicenseRef-Mesa-Vrije-Permissive`, and
`LicenseRef-Mesa-U-Atomic-Public-Domain`; adding another expression requires a
schema and verifier change.
Blocked manifests contain no notices or files and cannot be consumed by
derivation, build, or staging. Their linkage and schema can be checked without
turning them into usable source:

```powershell
.\scripts\verify-win98-component-closure.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -PolicyAudit
```

Mesa9x is pinned at `29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f`;
only its `mesa-23.1.x` subtree, whose `VERSION` is 23.1.9, is selected. Its ready
schema-2 closure binds 1,687 unique files: 837 source units, 652 compiler
dependencies, 198 generator inputs, and one generator recipe. The existing
`p_defines.h` row also carries the compiler-dependency role, so the role counts
overlap by one file. Every selected file binds exact inline or project-level
license evidence through 1,502 evidence records. The `libs/vkd3d-shader`
component is tracked separately. Glide and Voodoo compatibility are excluded.

`libs/vkd3d-shader` is pinned at
`1b0924d12c18df03912a8876ed17fd017ce9308e`. Its ready schema-2 closure binds
40 unique files: 15 source units, 12 compiler dependencies, 10 generator
inputs, three build descriptions, and one resource. The
`include/vkd3d_d3d9types.h` row carries both compiler-dependency and
generator-input roles, so those role counts overlap by one file. The 39 exact
license-evidence records bind 38 `LGPL-2.1-or-later` files, one MIT file, and
the combined `LGPL-2.1-or-later AND MIT` `hlsl.h`. OpenGlide9x and pthread9x
are excluded and authorize no source prefixes. Wine9x is reference-only.

The schema-1 vkd3d-shader compiler closure is `compile-proven` at 2,664,488
LF-only bytes and SHA-256
`23c682f4a797dd1cbe9f2eaf302cd3b1d42b32b728168f52a71f52cb59467438`.
Twin LF/CRLF checkouts canonicalize the same 40 Git blobs and consume two exact
MIT Mesa SPIR-V headers. Each run reproduces 11 generated outputs and compiles
15 tracked plus four generated units. The proof validates 38 AMD64 COFF
objects and 38 objdump results, with only the COFF timestamp normalized. Both
runs match at 4,879 dependency occurrences, 306 unique dependencies, and 19
normalized object pairs. All 197 collector children are bounded to one
top-level process and an evidence-derived maximum tree width of five;
temporary outputs and linker invocations are zero. The proof-only recipe uses
`-fno-lto`; the upstream production `-flto=auto` link path remains outside this
closure. Production build, link, staging, installation, activation, guest
execution, renderer selection, and capability advertisement remain false.

`mesa-generator-toolchain-lock.json` records the blocked Mesa 23.1.9 generator
environment as 26 exact MSYS2 package archives: 24 required and two reserved,
unselected packages. All 26 detached signatures are present but unverified.
The trust root, extractor, extracted tree, runtime, tool and module probes,
and commands are separate audit evidence. The audit
reads and hashes local files only; it never executes or extracts a package and
cannot authorize a build or payload:

```powershell
.\scripts\verify-win98-mesa-generator-toolchain.ps1 `
    -PolicyAudit `
    -PackageRoot .\.scratch\graphics-source-tools\packages `
    -MesaCheckout D:\src\retvrn99-win98\mesa9x
```

The production path does not consume that package graph. It uses the fixed
`hash-locked-generated-outputs` strategy. The Generated Source Module verifies
an already generated checkout against the exact Mesa commit, source seed, and
generator recipe, then copies only the 67 `GENERATE_FILES` targets into a fresh
normalized root. Known generator side effects are checked but never replace
tracked Mesa blobs. The Module never invokes Python, Mako, Flex, Bison, or a
package-cache executable.

Distinct LF and CRLF generation checkouts now produce the same normalized
67-file root. `mesa-generated-source-reproducibility.json` binds both run
identities and the canonical tree digest. The schema-2 generated-output lock
binds all 67 files and that proof while excluding four validation-only side
outputs. Its 77 reviewed evidence rows cover 58 generated outputs and 19
component-closure sources. Source evidence is read from the exact pinned Git
blobs, so LF and CRLF checkout policy cannot alter the license decision. The
lock proves generated-output identity and license review only; it cannot
authorize compilation, staging, installation, or graphics capability
advertisement.

`mesa-gsw` is the original source Module replacing the prohibited Nine memory
helper and build-identity implementations. Its strict verifier binds eight MIT
Mesa Interface and caller blobs plus three GPL-3.0-only local outputs. The
resident Win32 memory Adapter provides 64-byte aligned owned allocations,
bounded suballocation arithmetic, worker-safe frees, and deterministic teardown.
The caller must quiesce its worker before allocator destruction. The external
pointer Interface carries no extent, so its caller retains extent
responsibility. This source proof does not wire a recipe or assert compilation:

```powershell
.\scripts\verify-win98-mesa-gsw-original-source.ps1 `
    -MesaCheckout D:\src\retvrn99-win98\mesa9x
```

Its separate compile-only proof derives the complete ordered MinGW CPU flag
sequence from `guest-cpu-profile.json`, compiles the Nine memory Adapter in two
private roots, and requires byte-identical normalized i386 COFF outputs. Every
compiler child has a 10-second timeout, a pinned-toolchain-only `PATH`, and an
inherited no-dialog error mode. The objects are inspected, never executed, and
deleted before the verifier returns:

```powershell
.\scripts\build-win98-mesa-gsw-original-source.ps1 `
    -MesaCheckout D:\src\retvrn99-win98\mesa9x `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains
```

`mesa-compiler-closure.json` is the schema-3 compile proof. It binds nine exact
inputs, materializes canonical LF Git bytes from the ready component closure,
and records the exact 869 compiler dispositions. Two bounded runs produce
1,738 depfiles and 1,738 i386 COFF objects. The verifier normalizes only COFF
`TimeDateStamp` bytes 4-7, rejects optional headers and private absolute paths,
requires each normalized A/B pair to match, and binds one ordered aggregate
object digest. All temporary objects are deleted. Upstream multi-backend
recipes, software and DRM SVGA winsys paths, LLVM definitions, and VirtualBox
definitions remain explicit exclusions. The POSIX threads and read/write-lock
source dispositions have two bound compile-only `HAVE_PTHREAD` exceptions. The
selected x86 assembly disposition has one bound compile-only `USE_X86_ASM` and
`GLX_X86_READONLY_TEXT` exception. All three definitions remain absent from
common arguments; the winpthreads source/include tree and every pthread link or
ABI claim remain excluded.

`mesa-gsw-build-profile.json` is `compile-proven`. Each of its nine ordered
logical gates binds an exact evidence path and SHA-256; the CPU, backend, and
compile-output gates intentionally share the compiler-closure artifact that
owns those subproofs. This is non-package compile evidence only. Production
build, link, staging, guest installation, DLL activation, renderer selection,
and capability advertisement remain false.

Package staging dispatches provenance by lock disposition. Whole-source
`planned` rows use the immutable checkout verifier, `planned-component` rows
must pass a ready component closure, and `reference-only` rows always reject a
package that requires them. The current five-file GSW-VGA package requires only
VMDisp9x and VMHAL9x. Future GSW DX9 compatibility's Mesa prerequisite is ready
and `compile-proven`, but the package remains unavailable because production
build, link, and package authorizations remain false. No Glide or Voodoo
compatibility package is offered.

`toolchain.lock.json` pins the complete Open Watcom 1.9 archive and extraction.
`mingw32-toolchain.lock.json` pins the complete MinGW32 GCC 15.2.0 extraction.
Both locks cover every extracted file with the canonical tree digest, and each
build step selects its exact executable and environment from one lock.

```powershell
.\scripts\verify-win98-driver-toolchain.ps1 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -LockFile .\drivers\win98\toolchain.lock.json

.\scripts\verify-win98-driver-toolchain.ps1 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -LockFile .\drivers\win98\mingw32-toolchain.lock.json
```

The repository forces LF working-tree bytes for every raw-hashed JSON, TSV,
patch, overlay, and shared ABI input. The EOL regression creates fresh local
checkouts with `core.autocrlf=true` and `false`, compares the complete raw hash
closure, and runs ready derivation and build verification in both.

## Derived sources and build

`derived-source-plan.json` contains schema-2 ready recipes for `vmdisp9x-gsw`
and `vmhal9x-gsw`. Schema 2 retains whole-upstream behavior. Schema 3 requires
each recipe to select `whole-upstream` or `component-closure`. A component
selection repeats the closure path and raw SHA-256 from the canonical lock row,
requires that closure to be ready, and materializes only its declared regular
notice and source blobs. Component-only recipes may have no patch or overlay;
whole-upstream recipes retain the existing patch-or-overlay requirement.
Preparation applies any ordered, hash-pinned patches and complete tree-pinned
overlays after source materialization, verifies the exact combined output-tree
descriptor, and publishes only after final source and tree checks.

`build-plan.json` schema 3 is ready and links the source plan, upstream lock,
and both toolchain locks by SHA-256. It runs the pinned
tools with literal arguments, restores inherited mixed-case environment
variables, normalizes only the Win16 version-date fields declared for
`gswmini.drv`, validates every output, and atomically publishes the completed
two-recipe build.

```powershell
.\scripts\build-win98-driver-sources.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -OutputRoot V:\tmp\retvrn99-gsw-vga-build-a
```

The current independently reproduced package payloads are:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `gswmini.drv` | 16,988 | `2fccc72676e9ec67b0abe7f7db8ce266dc081d39e7722848579d79f550cea6e0` |
| `gswmini.vxd` | 39,361 | `fe51fe90fc986082b236fc3926341ed418cf97d8f7f514d985d8d294c6625ecb` |
| `gswmini.inf` | 3,210 | `5b954dc86a1c4e2e4e06c7fd16f3ea8c93991e485f1bae5512121c371d39b8ea` |
| `gswhal9x.dll` | 48,128 | `c1b0dd934da52684886f01bcabb38fb812ad610bba147e65ead99cca2d980cc0` |
| `gswdd32.dll` | 32,256 | `bfb72b4641e8e45e5ec90eb5c30e44aa4fac64fc37164c3429f428717d3964b4` |

The DLL identity is GSW-specific. `gswhal9x.dll` is the DirectDraw HAL and
`gswdd32.dll` is its narrow VxD bridge. The build does not produce or advertise
an OpenGL ICD, Direct3D driver, Mesa component, VESA helper, or tray utility.
The mini-VDD contains the capability-gated GSW3D guest transport, but it exposes
no usable 3D path unless the host explicitly advertises the guarded proof
backend.

GSW-VGA 0.2.0.8 also provides capability-gated screen and offscreen VRAM GDI
`BitBlt` acceleration for packed 8-, 16-, 24-, and 32-bit modes. Its private
pointer-free command supports all 256 ROP3 truth tables with solid or opaque
native-color 8x8 brushes. Unsupported surfaces, brushes, formats, and failed
submissions immediately return to the DIB Engine for that operation.
The synchronous GDI hot path uses a separately negotiated shared-memory
completion cookie, reducing successful submissions to one MMIO doorbell while
retaining the two-exit and generic fenced paths for older hosts.

Version 0.2.0.8 revalidates PCI BARs and decode state across ConfigMgr
re-enumeration, updates the existing Win16 framebuffer selector after a BAR
move, reconnects a resident Win16 driver to a dynamically reloaded mini-VDD,
and balances VDD mode-change notifications on every restore outcome. While
Windows owns high-resolution mode, the mini-VDD rejects BIOS standard and VBE
mode-set probes and swallows direct Bochs VBE register access. Mode 13h remains
available for fullscreen Win32 software renderers, and explicit VDD transitions
release the guard. The required V86 hook has checked installation and removal,
  and a failed unhook rejects dynamic unload. If a full display-driver Disable
  is followed by ReEnable, the Win16 driver restores the removed screen-switch
  hook and matching I/O-trap state; ordinary in-place ReEnable remains
  unchanged. Per-process teardown releases all owned 2D surfaces and guarded 3D
  contexts before Windows completes driver exit. Its source and INF contracts
  add exactly one low-resolution exception, 320x240x8. Guest discovery and
  runtime acceptance remain separate required gates before that mode can be
  promoted.

## GSW-Sound deferred native package

GSW-Sound is a separate, unavailable PnP package reserved for
`PCI\VEN_FFFE&DEV_0003`. Its VxD-first contract requires the complete
`GSWSOUND.INF`, `GSWSOUND.DRV`, and `GSWSOUND.VXD` set. This repository does
contain original source, reviewed hash-locked compatible Interface inputs, an
executable deterministic twin-build plan, exact linked-output hashes, mixer and
wave-loop support, and a ConfigMgr/VPICD interrupt path. The exact three-file
package is reproducible, but guest install/runtime proof failed and payload
inventory/manifest rows do not exist. The default machine now hides the native
PCI function under ADR 0009, so this package is a retained developer artifact,
not the active manual-test path. Native DirectSound discovery remains fail
closed.

The current manual Windows gate adds the inbox Creative SB16 driver as a
separate legacy device using I/O `220h` and `388h`, IRQ5, DMA1, and DMA5. Never
force that driver onto `FFFE:0003`; IRQ10 plus a 4 KiB memory range identifies
the wrong PCI devnode.

The [package contract](gsw-sound/README.md) records the implemented surface.
The [build and delivery plan](gsw-sound/draft-build-delivery-plan.md) records
the closed deterministic-build proof and remaining guest gates.
Neither document changes `payload_available`, the reviewed inventory, or
Guided Setup.

## Stageable package

`payload-inventory.schema.tsv` is the reviewed five-file destination set and
`payload-manifest.schema.tsv` binds each build output to its exact size and
hash. Staging requires the one INF and all four binaries, verifies both source
provenances again, rejects path and Windows 9x short-name collisions, copies
into private scratch, rehashes every copy, and publishes only the complete
package.

```powershell
.\scripts\invoke-win98-gsw-vga-pipeline.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -BuildOutputRoot D:\src\retvrn99-win98\build\gsw-vga `
    -StageOutputRoot D:\src\retvrn99-win98\stage\gsw-vga `
    -PayloadManifest .\drivers\win98\payload-manifest.schema.tsv
```

The INF copies the DRV, mini-VDD, HAL, and bridge into the Windows system
directory. DirectDraw is advertised by this exact GSW build only. The HAL and
VxD validate their ABI and framebuffer identity and fail closed on mismatch;
unsupported DirectDraw operations return to the runtime software path.

## Proof boundaries

- Deterministic build proof means two clean absent roots produced identical
  declared bytes from the locked inputs.
- Stageable package means the complete five-file PnP shape passed inventory,
  provenance, size, hash, and atomic-staging checks.
- Windows 98 runtime proof requires a licensed local guest fixture with the
  needed DirectX runtime. A successful build or stage is not runtime proof.

Guided Setup integration remains a separate acceptance boundary: the staged
package is not silently injected into user media, and the user's installation
media is never modified or redistributed.

### Offline stage into a stopped profile clone

The reviewed package can be copied into an existing disposable Profile image
while the VM is stopped. Point `PackageDirectory` at the five-file `GSW-VGA`
directory published by the staging pipeline, not at its parent:

```powershell
.\scripts\stage-win98-gsw-vga-offline.ps1 `
    -ProfileRoot D:\proof\install-profile\profile `
    -PackageDirectory D:\proof\stage\payloads\GSW-VGA `
    -OutputDirectory D:\proof\offline-stage-tools
```

The output directory must not exist. The wrapper verifies that the Profile
lock and FAT32 companion are absent, that `settings.json` names the Profile's
`c_drive.img`, and that all traversed paths are ordinary non-reparse paths. It
then freshly builds the staging executable and an adjacent
`retvrn99-fat32.exe`. The executable verifies the reviewed manifest and
inventory, requires those identities to equal its independently compiled
current five-file size and SHA-256 contract, and then verifies the exact host
files. A caller-supplied, self-consistent manifest cannot define another
replacement target. The whole directory is transactionally imported as
`C:\GSW-VGA`.

If `C:\GSW-VGA` already exists, replacement is allowed only when its complete
five-file content matches either the requested package or the one reviewed
legacy set in `gsw-vga-prior-only-manifest.tsv`. The tool pins every legacy
size and SHA-256 independently, so another manifest cannot widen replacement
authority. Any mixed generation, extra, missing, nested, changed, or
non-directory prior content fails before mutation. The caller remains
responsible for supplying a disposable clone; the wrapper can prove that a
Profile is stopped, but cannot prove how its image was cloned.

This is offline package staging only. It does not alter the Windows registry,
copy files into `WINDOWS`, bind or activate the display device, launch the
guest, or establish guest-runtime proof. Driver selection and all acceptance
observations still occur inside the licensed Windows 98 guest.

## GSW3D guest smoke

The standalone Windows 98 proof client has a separate locked build closure and
does not change the five-file VGA package:

```powershell
.\scripts\invoke-win98-gsw3d-smoke-pipeline.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -OutputRoot D:\src\retvrn99-win98\proof\gsw3d-smoke
```

Run `gsw3d-smoke.exe` only inside a licensed Windows 98 guest with the GSW-VGA
driver active and the host started with the guarded proof backend. A passing
run writes `GSW3D_SMOKE PASS` to the console and `GSW3D.LOG`. Normal production
hosts return `GSW3D_SMOKE UNAVAILABLE`; the tool is not an OpenGL or Mesa
capability claim.

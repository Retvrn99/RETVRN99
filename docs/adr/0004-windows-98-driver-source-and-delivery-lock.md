<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0004: Windows 98 driver source and delivery lock

## Status

Accepted

## Context

RETVRN99 targets high-resolution, high-frame-rate Windows 98 games without the
compatibility constraints of a general VMware product. Its guest display path
can still learn from the mature VMDisp9x, VMHAL9x, Mesa9x, SoftGPU, Wine9x,
vkd3d-shader, and VMware SVGA sources. Those projects use different licenses,
build systems, and old Windows driver toolchains. A moving branch, an
unreviewed compiler, or an unverified binary copied into Setup would make the
guest boundary neither reproducible nor auditable.

The repository contains reviewed GSW display, mini-VDD, DirectDraw HAL, bridge,
and INF adaptation sources. Compiled payloads remain external to Git. Source
selection, deterministic compilation, staging, and actual guest acceptance are
separate claims and must remain independently provable.

GSW-Sound follows the same separation but is original RETVRN99 work rather
than an upstream-derived driver. ADR 0008 fixes its VxD-first three-file package
shape and native PCI Interface. Its original source, reviewed Interface lock,
linked binaries, deterministic twin build, and exact build hashes now exist,
but guest installation never passed and no payload inventory rows were
promoted. ADR 0009 therefore hides the native PCI function in the default
persona while a separately added inbox legacy SB16 driver is tested.

## Decision

`drivers/win98/upstream.lock.tsv` is the authoritative source-provenance lock.
Every entry names an HTTPS repository, a complete immutable Git commit, its
repository-level license policy, and whether it is planned input,
planned-component input, or reference-only material. A planned-component row
links a closure manifest by relative path and raw SHA-256. A ready
manifest binds itself to the lock row's owning commit and lists exact regular
Git blobs, byte counts, SHA-256 digests, allowlisted file-specific license
expressions, notice IDs, source-prefix IDs, and roles. A source prefix is either
a named subtree or `exact-root-files`, which permits only separately enumerated
root files. Prefixes never authorize globs or implicit tree copying. Each file
binds to exact license evidence with the same approved expression. The schema
carries a closed, curated expression set; extending it requires a schema and
verifier review. Narrow additions include `SGI-B-2.0`,
`LicenseRef-Mesa-Vrije-Permissive`, and
`LicenseRef-Mesa-U-Atomic-Public-Domain`. A blocked manifest has no notices or
files and authorizes no derivation, build, staging, or distribution.
The verifier accepts only clean local checkouts at those exact origins and
commits, including initialized and matching submodules. It does not clone,
fetch, or resolve a branch or tag. With no source selection it verifies the
whole lock. Build and staging workflows instead pass an exact, closed source
allowlist derived from the work they will perform, so an unavailable unrelated
planned or reference-only checkout cannot block a narrower package build.

`drivers/win98/toolchain.lock.json` pins the Open Watcom C/C++ 1.9 archive by
size, SHA-256, and MD5, then pins the complete extracted tree by a canonical
path, size, and per-file-hash digest. It also fixes the relative `WATCOM`,
`EDPATH`, `INCLUDE`, and `PATH` layout. The verifier rejects added, removed, or
modified extraction files and performs no install or network operation. The
archive and extraction remain external to the repository.

`drivers/win98/mingw32-toolchain.lock.json` applies the same full-tree lock to
the MinGW32 GCC 15.2.0 extraction used by VMHAL9x. Build-plan schema 3 binds
each tool executable and environment to its named lock rather than sharing a
global compiler environment.

The pinned vmdisp9x source builds with that extraction and its bundled
DDK-derived headers and `dibeng.lbc`; no separate Windows 98 DDK is required.
Two clean builds proved every VxD byte-stable. Open Watcom places the current
Unix time in each Win16 driver's `VS_FIXEDFILEINFO.dwFileDateLS`, so the bounded
NE-resource normalizer zeros only `dwFileDateMS` and `dwFileDateLS`. The four
corresponding normalized DRVs were byte-identical across both builds.

`drivers/win98/derived-source-plan.json` separates immutable upstream source
from RETVRN99 adaptations. Schema 2 retains whole-upstream derivation. Schema 3
requires each recipe to select either `whole-upstream` or `component-closure`.
A component recipe must repeat the canonical lock row's closure path and raw
SHA-256, and the linked closure must be ready at the pinned owning commit. The
preparer materializes only its declared regular notice and source Git blobs,
rejects case-folded and DOS 8.3 collisions, and verifies the component again
after the pre-publication boundary. It never expands a component gitlink or
copies an omitted upstream file. Whole-upstream recipes retain recursive
expansion of initialized superproject-pinned gitlinks.

Every recipe identifies a disjoint output directory, ordered patches pinned by
size and SHA-256, complete overlay directories pinned by the canonical tree
descriptor, and the exact descriptor of the combined result. A component-only
recipe may use no patch or overlay because the closure itself is an exact
selection. Whole-upstream recipes retain the patch-or-overlay requirement. Each
patch explicitly names the regular text paths whose canonical CRLF bytes must
be converted to LF; undeclared blobs are unchanged, and unsafe, missing,
duplicate, reparse-point, NUL-containing, or isolated-CR inputs are rejected.
The preparer prevents unapproved overlay replacement, rejects overlapping
recipe destinations, scans each result again before publication, and
atomically creates a previously absent output root. `reference-only` rows
remain ineligible for derivation and staging.

The plan may instead be `draft` solely to bootstrap the combined descriptor.
Draft recipes already require exact patch and overlay descriptors, but omit the
not-yet-known output descriptor. `-DescribeRecipe` builds the tree in bounded
private scratch, scans it twice, emits the candidate descriptor, and deletes
the tree. Draft mode cannot publish an output or be consumed by the builder.
`-DescribeTree` similarly emits a double-scanned descriptor for an existing
overlay without changing it.

`drivers/win98/build-plan.json` is `ready` for the paired VMDisp9x-derived
display driver and VMHAL9x-derived GSW DirectDraw HAL. The schema-3 plan pins
the ready derived-source plan, both toolchain locks, and upstream lock. The builder
snapshots those exact linked bytes and every lock-linked component manifest at
its canonical relative path before use, and rejects an alternate upstream-lock
path. It names a hash-verified local toolchain executable, a
literal argument array, a derived-recipe working directory, one explicit
Win16 normalization operation, and exact adapted output sizes and SHA-256
values. Every DRV output must be normalized exactly once. A `build`-origin
output must be absent before its producing step, while a `derived`-origin
output must already match and remain unchanged.

The builder re-verifies both complete toolchains, prepares private derived
scratch, installs only the selected child environment, and launches pinned
`wmake.exe` or `mingw32-make.exe` with literal arguments. It restores inherited
mixed-case environment variables and never mutates the caller's PATH. It
validates every normalized output before atomic publication, performs no
network operation, and cannot consume a `reference-only` source row. The exact
declared GSW-VGA payloads are:

- `gswmini.drv`: 16,922 bytes, `9748b9feeebfaa4b4597f63a17fd8699ddfa01bce1aba6fc8ecc8ec7542fb13d`.
- `gswmini.vxd`: 39,341 bytes, `61edea1973a7ce17fde3725d930c75495dd1ce2eeeb87fa799b8289cf534d876`.
- `gswmini.inf`: 3,188 bytes, `952c2a18697a363944879b64031872266505d34ac50fca7080663bfa54783dea`.
- `gswhal9x.dll`: 46,592 bytes, `8668d85be8d2fc8b3d32253aa7e04c9104a2713494f9b309c2d4404f1ae12b38`.
- `gswdd32.dll`: 32,256 bytes, `bfb72b4641e8e45e5ec90eb5c30e44aa4fac64fc37164c3429f428717d3964b4`.

This proof covers deterministic derivation and compilation, not Windows 98
installation or device operation.

`drivers/win98/payload-inventory.schema.tsv` and
`drivers/win98/payload-manifest.schema.tsv` contain the reviewed closed
five-file `gsw-vga` destination set and its exact build hashes. The five reserved
package identities are independently stageable; availability of one package
does not imply availability of the other four. With no `-PackageId`, staging
selects every package declared by the reviewed inventory. An explicit
`-PackageId` list selects an exact subset and rejects empty, duplicate, unknown,
or inventory-undeclared IDs.

Every selected PnP package must have exactly one INF, at least one binary, at
most one catalog, and no RunOnce component. Every selected RunOnce package must
have at least one component and no INF or catalog. The payload manifest must
match every reviewed destination for the selected set one-for-one and cannot
add an unselected package. Staging still bounds row and byte counts, rejects
unsafe paths and Windows 9x short-name collisions, validates the exact size and
SHA-256 of each source and staged copy, and atomically creates a previously
absent output directory. The tracked source and build metadata are not binaries
and are not install-ready packages.

Package provenance is a closed mapping to lock `source_directory` values. GSW
VGA requires `vmdisp9x` and `vmhal9x`; GSW-Sound and the user-supplied DirectX
9 runtime have no upstream checkout requirement; and GSW DX9 compatibility
requires only `mesa9x`. RETVRN99 does not offer a Glide or Voodoo compatibility
package. The current five-file VGA inventory does not require Mesa until
`gswgl32.dll` joins its reviewed package shape. GSW-Sound's empty upstream
requirement means that its guest driver will use original, repository-owned
sources; it does not make an absent source tree or payload stageable. Staging
resolves required upstream directories to the authoritative lock names. A `planned` row uses the
whole-source verifier. A `planned-component` row must pass its ready component
closure verifier. A blocked closure or `reference-only` row cannot authorize a
package. Missing, ambiguous, dirty, or mismatched required provenance also
blocks staging.

The host-side delivery plan reserves these identities:

- GSW VGA is a PnP package for `PCI\VEN_FFFE&DEV_0002`.
- GSW-Sound reserves a dormant PnP package for `PCI\VEN_FFFE&DEV_0003`; its
  complete VxD-first shape is `GSWSOUND.INF`, `GSWSOUND.DRV`, and
  `GSWSOUND.VXD`, but the default machine does not enumerate the endpoint.
- The user-supplied DirectX 9 runtime is a future RunOnce component at order
  100.
- The GSW DirectX compatibility component is a future RunOnce component at
  order 200.
- GSW Glide is a future RunOnce component at order 300.

PnP installation occurs during Windows Setup, so the sound and display drivers
precede the post-Setup component sequence. Within that future sequence, the
DirectX runtime precedes the compatibility layer, which precedes Glide, so the
runtime cannot replace the final GSW compatibility files. No RunOnce command is
emitted while those payloads are unavailable.

The pinned VMDisp9x and VMHAL9x revisions have reviewed RETVRN99 adaptations,
bounded build proofs, and a closed stageable PnP package. Mesa9x is retained at
`29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f`, with only its `mesa-23.1.x`
23.1.9 subtree selected. Its ready schema-2 component closure binds 1,687 unique
files: 837 selected source units, 652 compiler dependencies, 198 generator
inputs, and one generator recipe. `p_defines.h` carries both an existing role
and the compiler-dependency role, so those role counts overlap by one file.
Every row binds exact inline or project-level license evidence through 1,502
evidence records.

`libs/vkd3d-shader` is pinned at
`1b0924d12c18df03912a8876ed17fd017ce9308e`. Its ready schema-2 component
closure binds 40 unique files: 15 source units, 12 compiler dependencies, 10
generator inputs, three build descriptions, and one resource. The
`include/vkd3d_d3d9types.h` row has both compiler-dependency and generator-input
roles, so those counts overlap by one file. Its 39 exact license-evidence
records bind 38 `LGPL-2.1-or-later` files, one MIT file, and the combined
`LGPL-2.1-or-later AND MIT` `hlsl.h`.

The schema-1 vkd3d-shader compiler closure is `compile-proven` at 2,664,488
LF-only bytes and SHA-256
`23c682f4a797dd1cbe9f2eaf302cd3b1d42b32b728168f52a71f52cb59467438`.
Twin LF/CRLF checkouts canonicalize the same 40 Git blobs and consume two exact
MIT Mesa SPIR-V headers. Each run reproduces 11 generated outputs and compiles
15 tracked plus four generated units. The proof validates 38 AMD64 COFF
objects and 38 objdump results, normalizing only the COFF timestamp. Both runs
match at 4,879 dependency occurrences, 306 unique dependency identities, and
19 normalized object pairs. Its 197 collector children use one top-level
process at a time and an evidence-derived maximum tree width of five; temporary
outputs and linker invocations are zero, and all authority fields remain false.
The closure uses proof-only `-fno-lto`; production LTO and linking remain
unproven and unauthorized.

OpenGlide9x and pthread9x are excluded because RETVRN99 does not offer Glide or
Voodoo compatibility. Wine9x, SoftGPU, and the VMware SVGA Device Developer Kit
mirror are reference-only. Changing a
disposition or manifest status requires a separate review; a lock update alone
does not approve source copying or binary distribution.

`drivers/win98/mesa-generator-toolchain-lock.json` records a blocked-only Mesa
generator environment. It fixes an immutable 26-package dependency graph with
24 required packages and two reserved, unselected packages. Every local package
archive is bound by relative path, byte count, and SHA-256. Detached signatures
are recorded as present or missing, but none is trusted until the exact signing
root and verification procedure are separately pinned.

Trust-root validation, extraction, extracted-tree identity, runtime validation,
tool and Python-module probes, generator commands, and generated-output identity
remain separate proofs. The verifier accepts this lock only for policy audit.
It authorizes no build, staging, guest installation, or capability
advertisement.

The Mesa compile proof uses the alternative allowed by the graphics source
plan: reviewed, hash-locked generated outputs. The Generated Source Module
accepts a checkout already populated by an independently run generator,
verifies the exact Mesa commit, generator recipe, source seed, and permitted
working-tree state, and publishes only the 67 outputs declared by
`GENERATE_FILES` into a fresh normalized root. It never executes a generator,
extracts a package, or reads the package cache. Three Bison header byproducts
and the byte-identical `tr_util.h` byproduct are validation-only; tracked Mesa
blobs remain authoritative and are never replaced by publication.

Two distinct LF and CRLF generation checkouts have independently produced the
same normalized 67-file root. The reproducibility record binds both run
identities and canonical tree digest
`dd0ae888829eabf2a0043f27100aa64c57b43ad12054270bee62f50ccc451d84`.
The generated-output lock binds every published byte, directly binds that
reproducibility record, and excludes the four validation-only side outputs.
Its 77 ordered evidence rows prove all 67 output license expressions: 58 rows
bind ranges in generated outputs and 19 bind exact source evidence from the
pinned Git blobs already reviewed by the Mesa component manifest. The lock is
therefore `reviewed-generated-source`. This classification proves generated
bytes and their license evidence only. Within the generated-output lock,
generator-input, component, header, depfile, and production-build closure are
separate claims whose status can come only from their owning artifacts.

`drivers/win98/mesa-gsw` is an original source Module for the two prohibited
implementation replacements. Its verifier binds eight permissive Mesa
Interface and caller blobs, the pinned checkout identity, and three
GPL-3.0-only outputs: deterministic Mesa identity macros, the Nine memory
Interface, and the resident Win32 memory Adapter. The Adapter uses 64-byte
aligned process-heap allocations, explicit suballocation ownership, and a
worker-safe free path. Its caller must quiesce the worker before allocator
destruction, and external-pointer extent remains a caller responsibility
because Mesa supplies no extent in that Interface. This Module proves source
identity only; compile and build claims remain false.

The original-source compile proof binds the canonical GSW-886 CPU profile
rather than carrying a reduced flag copy. It compiles the Nine memory Adapter
twice in private roots with the pinned i686 compiler, suppresses Windows crash
dialogs for every bounded child, inspects but never executes the COFF objects,
zeros only their timestamps, and requires byte-identical normalized results.
The proof produces no persistent object or DLL and authorizes no production
build. Its reviewed source lock is a build-profile dependency, while the
869-unit Compiler Closure owns the broader object-compilation proof.

`mesa-compiler-closure.json` is a schema-3, `compile-proven` Compiler Closure
Module. It binds the ready component closure, reviewed generated and original
roots, direct plan, GSW-886 CPU profile, disabled winsys sentinel, and locked
toolchain. It records the exact 869 dispositions and two bounded runs of every
dependency and object command. The 1,738 i386 COFF objects are inspected but
never executed; normalization changes only `TimeDateStamp` bytes 4-7, rejects
optional headers and private absolute paths, requires every normalized A/B pair
to match, and binds one ordered aggregate digest. No temporary object remains.
Upstream multi-backend recipes, software renderers, the DRM SVGA winsys, LLVM
definitions, and VirtualBox definitions remain excluded inputs. The selected
POSIX threads and read/write-lock sources have two exact compile-only
`HAVE_PTHREAD` exceptions. The latter avoids selecting Vista-era SRW APIs at the
locked Windows 98 target level. The selected generated x86 assembly has one
exact compile-only `USE_X86_ASM` and `GLX_X86_READONLY_TEXT` exception so its
PE/COFF-compatible path matches the pinned recipe context. These definitions
remain absent from common arguments. The vendored winpthreads source/include
tree is still excluded, and the closure explicitly leaves the upstream recipe
and pthread link ABI unproven.

The schema-2 build profile fixes `hash-locked-generated-outputs` as its only
generation strategy and is `compile-proven`. All nine ordered gates bind exact
evidence paths and SHA-256 digests. The CPU, backend-exclusion, and
compile-output gates share the compiler-closure artifact that independently
owns those subproofs. Production build, link, staging, guest installation, DLL
activation, renderer selection, and capability advertisement all remain false.

## Consequences

- Source evaluation can proceed against stable revisions without importing
  binaries into the repository.
- The Mesa generator package graph and local archive inventory can be audited
  without treating downloaded bytes or detached signatures as trusted.
- The production build never runs or extracts that package graph. Completing a
  generator-toolchain proof does not imply completion of any source or build
  proof.
- A policy-audited Mesa generator lock cannot be consumed by build or delivery
  workflows.
- Generated-source reproducibility, exact output coverage, component licensing,
  and the clean 869-unit object proof are complete. `compile-proven` remains an
  evidence classification, not authority to produce or deliver a DLL.
- The full compiler extraction, not only its launcher executable, is covered by
  a deterministic integrity check.
- A missing required checkout, dirty tree, wrong origin, toolchain hash
  mismatch, incomplete selected package, inventory mismatch, or output hash
  mismatch stops the workflow; an unrelated absent checkout does not block a
  scoped build or staging operation.
- The GSW-VGA payload is stageable only as the complete DRV, VxD, INF, HAL,
  and bridge set; removing or changing any member closes staging.
- GSW-Sound remains unavailable despite its closed source/build proof: the
  default persona hides the failed native endpoint, the exact three-file
  inventory and manifest do not exist, and licensed guest acceptance has not
  passed. Build success cannot reopen delivery by itself.
- Draft descriptors and failed or unstaged builds do not create a package
  claim. A stageable package still does not prove Device Manager, DirectDraw,
  dxdiag, mode switching, or performance inside a licensed Windows 98 guest.
- The plan preserves a lean RETVRN99-specific architecture while keeping useful
  Windows 9x compatibility knowledge traceable.

## References

- [Windows 98 setup driver bundles](0003-windows-98-setup-driver-bundles.md)
- [VxD-first GSW-Sound architecture](0008-gsw-sound-vxd-first-audio-architecture.md)
- [Default Windows 98 sound path](0009-default-windows-98-sound-path.md)
- [Pinned upstream source lock](../../drivers/win98/upstream.lock.tsv)
- [Component closure schema](../../drivers/win98/component-closure.schema.json)
- [Reviewed component closure schema](../../drivers/win98/component-closure-v2.schema.json)
- [Mesa generated-output review lock](../../drivers/win98/generated-output-locks/mesa-23.1.9.json)
- [Original GSW Mesa source Module](../../drivers/win98/mesa-gsw/README.md)

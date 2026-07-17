<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Windows 98 driver packaging metadata

This directory contains reviewed bounded GSW display adaptation source,
provenance, and validation metadata. It contains no compiled driver, DirectX,
or compatibility-layer payload and no install-ready package.

`upstream.lock.tsv` pins every candidate source checkout by repository and full
Git commit. Verify pre-existing local checkouts without fetching them:

```powershell
.\scripts\verify-win98-driver-sources.ps1 -SourceRoot D:\src\retvrn99-win98
```

Pass `-SourceName` to verify an exact nonempty subset. The build and staging
scripts derive that allowlist from their reviewed steps or selected packages;
they never accept an independently supplied provenance override.

`toolchain.lock.json` pins the official Open Watcom C/C++ 1.9 archive and a
canonical digest of every file in its extracted tree, together with the exact
relative `WATCOM`, `EDPATH`, `INCLUDE`, and `PATH` layout used by vmdisp9x.
Verify a pre-existing archive and extraction without installing or executing
the archive:

```powershell
.\scripts\verify-win98-driver-toolchain.ps1 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains
```

The pinned vmdisp9x revision builds with that toolchain and its bundled
DDK-derived headers and `dibeng.lbc`; a separate Windows 98 DDK is not needed.
Two clean evaluation builds produced byte-identical VxDs. Open Watcom writes
the current Unix time into `VS_FIXEDFILEINFO.dwFileDateLS` in each 16-bit DRV,
so `normalize-win16-version-date.ps1` parses the NE resource table and zeros
only `dwFileDateMS` and `dwFileDateLS`. After normalization, corresponding
drivers from both builds were byte-identical:

| Driver | Bytes | Normalized SHA-256 |
|---|---:|---|
| `boxvmini.drv` | 20,302 | `dbc00b8d8b0b6218c1ac1827267d553db8c47c0a9c186ac9e2c62051186e11c7` |
| `qemumini.drv` | 20,302 | `01c8ca2e609e41ef14ad6367b231cf0aaecd75dae7e9eaeac29cab5563d3fc39` |
| `vesamini.drv` | 20,366 | `d623579e48d9866ab7c00a9db612fe1f1317fd27716432af8c6350b88b2d3d1d` |
| `vmwsmini.drv` | 20,362 | `2d8d15898bcb5b2de475bd3e35773b86e87eb43f7d37622d912297fd0e27e3b4` |

`derived-source-plan.json` and `build-plan.json` are ready for the reviewed
VMDisp9x-derived GSW mini display-driver build. This reproducible slice contains
the GSW DRV, mini-VDD, and INF only; it does not include VMHAL9x, an ICD, or an
installable package. The schema-2 source preparer materializes exact tracked Git
blob bytes from an
already verified checkout, recursively including each initialized gitlink at
its superproject-pinned commit. Each ordered, hash-locked patch explicitly
declares `normalize_lf_paths`: only those regular text files are converted from
canonical CRLF to LF before the patch is checked and applied. Missing, unsafe,
duplicate, reparse-point, NUL-containing, or isolated-CR inputs fail closed;
undeclared blobs remain byte-identical. The preparer then merges whole
hash-locked overlay trees and compares the complete result with the canonical
`retvrn99-file-tree-sha256-v1` descriptor twice. It creates the previously
absent output root atomically and never modifies the upstream checkout. An
overlay cannot replace an upstream file unless its recipe says so explicitly.

Descriptor authoring is separate from ready-mode verification. Describe the
complete overlay after its reviewed files have landed:

```powershell
.\scripts\prepare-win98-derived-sources.ps1 `
    -DescribeTree .\drivers\win98\derived\vmdisp9x-gsw\overlay
```

Copy that descriptor into a `draft` recipe containing the exact overlay and/or
patch inputs, then materialize the recipe transiently to obtain its final
output descriptor. Draft mode emits JSON and removes the temporary tree; it
cannot publish a derived source:

```powershell
.\scripts\prepare-win98-derived-sources.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -RecipePlan .\drivers\win98\derived-source-plan.json `
    -RecipeRoot .\drivers\win98 `
    -LockFile .\drivers\win98\upstream.lock.tsv `
    -DescribeRecipe vmdisp9x-gsw
```

Only after both descriptors are reviewed may the source plan change to
`ready`. A schema-2 ready build plan pins that plan, `toolchain.lock.json`, and
`upstream.lock.tsv` by SHA-256. The builder snapshots those exact bytes before
using them and rejects any alternate `LockFile` path. Each toolchain gives a
name, path within the locked extraction, and
executable SHA-256. Each step gives a derived recipe, toolchain, working
directory, literal argument array, explicit Win16 date normalizations, and
exact output sizes and SHA-256 values. Every `.drv` output must have exactly
one `win16-version-date` operation, and no non-DRV output may claim one.

The builder verifies the entire toolchain extraction, prepares the derived
tree in private scratch, and installs the locked Watcom environment for the
child build. It launches the pinned `wmake.exe` with a literal argument array;
the reviewed makefile controls its Open Watcom subprocesses. The locked
`binnt` and `binw` directories are prepended to the caller's existing `PATH`.
An output whose `origin` is `build` must not exist before its producing step,
while an output whose `origin` is `derived` must already match and remain
unchanged. Declared DRVs are normalized, every output is rehashed, and the
previously absent build root is then published atomically. The reproducibility
gate is two independent absent output roots:

```powershell
.\scripts\build-win98-driver-sources.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -OutputRoot D:\src\retvrn99-win98\proof\gsw-vga-codex-c

.\scripts\build-win98-driver-sources.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -OutputRoot D:\src\retvrn99-win98\proof\gsw-vga-codex-d

Get-FileHash `
    D:\src\retvrn99-win98\proof\gsw-vga-codex-c\vmdisp9x-gsw\gswmini.*,
    D:\src\retvrn99-win98\proof\gsw-vga-codex-d\vmdisp9x-gsw\gswmini.* `
    -Algorithm SHA256
```

That gate completed on 2026-07-17 in the independent
`gsw-vga-codex-c` and `gsw-vga-codex-d` roots. The only compiler diagnostic was
the existing unused `tm_handle` warning in `vxd_async.c`. All declared artifacts
were byte-identical and matched the ready plan:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `gswmini.drv` | 14,404 | `8ae871b002f60b4ba5d25834849c4534192339ecbf19f096ce0a80ec55aec096` |
| `gswmini.vxd` | 29,557 | `d4127232095fb7683c2ab43af4fbb3add5a955253a188afb06ed86d6dcabe27f` |
| `gswmini.inf` | 3,108 | `f8d665e757af2af4732d78a8b8d1fc0c40040b4f9d009b344e12b6bdae8af944` |

This proves deterministic source derivation and compilation for that bounded
VMDisp9x slice. It does not prove Windows 98 installation, device operation, or
guest compatibility, and the outputs are not an installable RETVRN99 driver
package.

`payload-inventory.schema.tsv` and `payload-manifest.schema.tsv` are header-only
staging schemas. Future inventory rows enumerate the exact reviewed destination
set and package shape for whichever package identities are available. Omitted
`-PackageId` stages every inventory-declared package; an explicit list stages
only that closed subset. GSW VGA provenance requires vmdisp9x and vmhal9x, GSW
DX9 compatibility requires Mesa9x and Wine9x, and source-free sound/runtime
packages do not require unrelated checkouts. Staging bounds row and byte counts,
requires complete PnP or RunOnce shapes, rejects long-name and Windows 9x
short-name collisions, and never overwrites an existing output directory.

Once a complete reviewed `gsw-vga` inventory and payload manifest exist, the
closed wrapper performs the ready build and stages only that package:

```powershell
.\scripts\invoke-win98-gsw-vga-pipeline.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -BuildOutputRoot D:\src\retvrn99-win98\build\gsw-vga `
    -StageOutputRoot D:\src\retvrn99-win98\stage\gsw-vga `
    -PayloadManifest D:\src\retvrn99-win98\manifests\gsw-vga.tsv
```

The wrapper cannot bypass a non-ready build, header-only inventory, incomplete
PnP shape, missing VMHAL9x provenance, or a payload hash mismatch. The current
header-only inventory therefore keeps staging closed even though this bounded
build is ready.

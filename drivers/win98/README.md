<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Windows 98 driver packaging metadata

This directory contains provenance and validation metadata only. It contains no
driver, DirectX, or compatibility-layer payload.

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

`build-plan.json` is intentionally blocked. A future `ready` plan must give each
toolchain a `name`, `relative_path`, and lowercase `sha256`. Each step must give
a `name`, locked `source_directory`, toolchain name, `working_directory`,
literal `arguments` array, and one or more outputs with `relative_path`, exact
`bytes`, and lowercase `sha256`. The build script validates the complete plan
before invoking the first executable. The plan remains blocked until the
reviewed GSW-derived source preparation recipe, normalization steps, and exact
adapted outputs are committed; the pristine-build proof alone is not an
installable RETVRN99 driver.

`payload-inventory.schema.tsv` and `payload-manifest.schema.tsv` are header-only
staging schemas. Future inventory rows enumerate the exact reviewed destination
set and package shape for whichever package identities are available. Omitted
`-PackageId` stages every inventory-declared package; an explicit list stages
only that closed subset. GSW VGA provenance requires vmdisp9x and vmhal9x, GSW
DX9 compatibility requires Mesa9x and Wine9x, and source-free sound/runtime
packages do not require unrelated checkouts. Staging bounds row and byte counts,
requires complete PnP or RunOnce shapes, rejects long-name and Windows 9x
short-name collisions, and never overwrites an existing output directory.

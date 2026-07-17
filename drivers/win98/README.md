<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Windows 98 driver packaging metadata

This directory contains provenance and validation metadata only. It contains no
driver, DirectX, or compatibility-layer payload.

`upstream.lock.tsv` pins every candidate source checkout by repository and full
Git commit. Verify pre-existing local checkouts without fetching them:

```powershell
.\scripts\verify-win98-driver-sources.ps1 -SourceRoot D:\src\retvrn99-win98
```

`build-plan.json` is intentionally blocked. A future `ready` plan must give each
toolchain a `name`, `relative_path`, and lowercase `sha256`. Each step must give
a `name`, locked `source_directory`, toolchain name, `working_directory`,
literal `arguments` array, and one or more outputs with `relative_path`, exact
`bytes`, and lowercase `sha256`. The build script validates the complete plan
before invoking the first executable.

`payload-inventory.schema.tsv` and `payload-manifest.schema.tsv` are header-only
staging schemas. Future inventory rows must enumerate the exact reviewed
destination set and package shape. A matching payload manifest must provide
every row in that set for GSW VGA, GSW sound, the DirectX 9 runtime, and GSW DX9
compatibility, with exact sizes and hashes. Staging bounds the row and byte
counts, rejects long-name and Windows 9x short-name collisions, refuses a
missing or partial set, and never overwrites an existing output directory.

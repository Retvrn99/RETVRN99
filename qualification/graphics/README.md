<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Phase 0 graphics qualification

The JSON files in this directory describe an inert WinQuake baseline and its
external media identities. They do not authorize guest launch, installation,
or host mutation.

Before preparing a run, locally ignore `.scratch/`. The repository does not
track this workstation-specific rule. Add it to `.git/info/exclude`, then
confirm the evidence target is ignored:

```powershell
git check-ignore --quiet -- .scratch/graphics-qualification/baseline/prepared-run-v1.json
if ($LASTEXITCODE -ne 0) { throw '.scratch graphics evidence is not ignored.' }
```

`prepare-graphics-baseline-run.ps1` fails closed when this precondition is not
met. Media payloads remain external under `.scratch/graphics-qualification/media`.

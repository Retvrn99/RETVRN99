# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MesaCheckout
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'mesa-compiler-dependency-roles.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Get-OrdinalPathHash {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $bytes = [Text.Encoding]::UTF8.GetBytes(($Paths -join "`n") + "`n")
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return (([BitConverter]::ToString($sha256.ComputeHash($bytes))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $repoRoot 'drivers\win98\component-closures\mesa9x-23.1.x.json'
$lockPath = Join-Path $repoRoot 'drivers\win98\upstream.lock.tsv'
$seedPath = Join-Path $repoRoot 'drivers\win98\mesa-source-seed.json'
$compilerClosurePath = Join-Path $repoRoot 'drivers\win98\mesa-compiler-closure.json'
$verifyScript = Join-Path $PSScriptRoot 'verify-win98-component-closure.ps1'
$updateScript = Join-Path $PSScriptRoot `
    'update-win98-mesa-component-license-closure.ps1'

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$seed = Get-Content -Raw -LiteralPath $seedPath | ConvertFrom-Json
$compilerClosure = Get-Content -Raw -LiteralPath $compilerClosurePath | ConvertFrom-Json
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

$lockLines = @(Get-Content -LiteralPath $lockPath | Where-Object {
    $_.Length -ne 0 -and -not $_.StartsWith('#', [StringComparison]::Ordinal)
})
$lockRows = @($lockLines | ConvertFrom-Csv -Delimiter "`t")
$mesaRows = @($lockRows | Where-Object { $_.name -ceq 'mesa9x' })
Assert-Equal $mesaRows.Count 1 'The upstream lock must contain one Mesa row.'
Assert-Equal $mesaRows[0].closure_manifest_sha256 $manifestHash `
    'The Mesa manifest hash must be bound by the upstream lock.'

Assert-Equal $manifest.schema 2 'The Mesa manifest schema is wrong.'
Assert-Equal $manifest.status 'ready' 'The Mesa manifest must be ready.'
Assert-Equal $manifest.reason '' 'The ready Mesa manifest must not have a blocker.'
Assert-Equal $manifest.upstream_name 'mesa9x' 'The Mesa upstream name is wrong.'
Assert-Equal $manifest.owning_commit '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f' `
    'The Mesa owning commit is wrong.'

$files = @($manifest.files)
$evidence = @($manifest.license_evidence)
Assert-Equal $files.Count 1687 'The reviewed Mesa file-row count is wrong.'
Assert-Equal $evidence.Count 1502 'The Mesa license-evidence count is wrong.'
Assert-Equal @($manifest.source_prefixes).Count 7 'The Mesa source-prefix count is wrong.'

$pathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$previousPath = $null
foreach ($file in $files) {
    Assert-True ($pathSet.Add([string]$file.relative_path)) `
        "Duplicate Mesa file path '$($file.relative_path)'."
    if ($null -ne $previousPath) {
        Assert-True ([StringComparer]::Ordinal.Compare($previousPath, [string]$file.relative_path) -lt 0) `
            'Mesa file rows are not in strict ordinal path order.'
    }
    $previousPath = [string]$file.relative_path
    Assert-True ($file.git_blob -cmatch '^[0-9a-f]{40}$') `
        "Invalid Git blob for '$($file.relative_path)'."
    Assert-True ($file.sha256 -cmatch '^[0-9a-f]{64}$') `
        "Invalid SHA-256 for '$($file.relative_path)'."
    if ($file.declared_license_expression -cin @(
        'GPL-2.0-only OR MIT',
        'GPL-3.0-only OR MIT'
    )) {
        Assert-Equal $file.selected_license_expression 'MIT' `
            "The ready OR selection is wrong for '$($file.relative_path)'."
    }
    else {
        Assert-Equal $file.declared_license_expression $file.selected_license_expression `
            "License selection differs for '$($file.relative_path)'."
    }
    Assert-Equal @($file.license_evidence_ids).Count 1 `
        "Unexpected evidence binding count for '$($file.relative_path)'."
}

$sourceFiles = @($files | Where-Object { @($_.roles) -ccontains 'source-unit' })
$compilerDependencies = @($files | Where-Object {
    @($_.roles) -ccontains 'compiler-dependency'
})
$generatorInputs = @($files | Where-Object { @($_.roles) -ccontains 'generator-input' })
$buildDescriptions = @($files | Where-Object { @($_.roles) -ccontains 'build-description' })
Assert-Equal $sourceFiles.Count 837 'The reviewed source-unit count is wrong.'
Assert-Equal $compilerDependencies.Count 652 `
    'The reviewed compiler-dependency count is wrong.'
Assert-Equal $generatorInputs.Count 198 'The generator-input count is wrong.'
Assert-Equal $buildDescriptions.Count 1 'The build-description count is wrong.'
Assert-Equal $buildDescriptions[0].relative_path 'generator/mesa-23.1.x-gen.mk' `
    'The pinned generator recipe is wrong.'
Assert-Equal (Get-OrdinalPathHash @($sourceFiles.relative_path)) `
    '997781a5878e69eb4386b23c7d41b99ae88852a9eba8370f966becd9532d735c' `
    'The reviewed source-unit path set changed.'
Assert-Equal (Get-OrdinalPathHash @($generatorInputs.relative_path)) `
    '4bd2109936b4ce4dedba129a864edab3cfe1327e94cd552839744aecc98ad3ea' `
    'The generator-input path set changed.'
Assert-Equal (Get-OrdinalPathHash @($compilerDependencies.relative_path)) `
    '00ac4082aab6cdca6d81b1293948ee7774da08101d708628fb1d045b5717d05e' `
    'The compiler-dependency path set changed.'

$compilerDependencyRoles = Resolve-MesaCompilerDependencyRoles `
    @($compilerClosure.evidence.headers)
Assert-Equal $compilerDependencyRoles.RolePaths.Count 652 `
    'The compiler closure dependency-role count is wrong.'
Assert-Equal (Get-OrdinalPathHash $compilerDependencyRoles.RolePaths) `
    (Get-OrdinalPathHash @($compilerDependencies.relative_path)) `
    'The component and compiler dependency role path sets differ.'
$shadowedDependency = @($compilerDependencies | Where-Object {
    $_.relative_path -ceq $compilerDependencyRoles.ShadowedPath
})
Assert-Equal $shadowedDependency.Count 1 `
    'The generated-shadowed dependency role is missing.'
Assert-MesaShadowedCompilerDependencyRole $shadowedDependency[0]
if ($compilerClosure.schema -eq 3) {
    Assert-Equal $compilerDependencyRoles.ObservedSourcePaths.Count 651 `
        'The schema-v3 compiler observed-source count is wrong.'
    Assert-Equal $compilerDependencyRoles.Mode 'generated-replacement-observed' `
        'The schema-v3 generated-shadow contract is wrong.'
}
else {
    Assert-Equal $compilerDependencyRoles.ObservedSourcePaths.Count 652 `
        'The legacy compiler observed-source count is wrong.'
    Assert-Equal $compilerDependencyRoles.Mode 'source-placeholder-observed' `
        'The legacy source-placeholder contract is wrong.'
}
$pDefines = @($compilerDependencies | Where-Object {
    $_.relative_path -ceq 'mesa-23.1.x/src/gallium/include/pipe/p_defines.h'
})
Assert-Equal $pDefines.Count 1 'The shared p_defines.h row is missing.'
Assert-Equal (@($pDefines[0].roles) -join ',') `
    'compiler-dependency,generator-input' `
    'The shared p_defines.h roles are wrong.'

$licenseCounts = @{}
foreach ($group in @($files | Group-Object selected_license_expression)) {
    $licenseCounts[$group.Name] = $group.Count
}
foreach ($expected in @{
    'MIT' = 1643
    'BSD-2-Clause' = 17
    'BSL-1.0' = 3
    'BSD-3-Clause' = 3
    'Apache-2.0' = 12
    'LicenseRef-Mesa-SHA1-Public-Domain' = 2
    'GPL-3.0-or-later WITH Bison-exception-2.2' = 3
    'LicenseRef-Mesa-DbgHelp-Public-Domain' = 1
    'SGI-B-2.0' = 1
    'LicenseRef-Mesa-Vrije-Permissive' = 1
    'LicenseRef-Mesa-U-Atomic-Public-Domain' = 1
}.GetEnumerator()) {
    Assert-True ($licenseCounts.ContainsKey($expected.Key)) `
        "Missing license partition '$($expected.Key)'."
    Assert-Equal $licenseCounts[$expected.Key] $expected.Value `
        "Wrong count for license partition '$($expected.Key)'."
}
Assert-Equal $licenseCounts.Count 11 'Unexpected Mesa license partition.'

foreach ($binding in @(
    @('mesa-23.1.x/include/GLES3/gl3ext.h', 'SGI-B-2.0'),
    @('mesa-23.1.x/src/mesa/x86/assyntax.h',
        'LicenseRef-Mesa-Vrije-Permissive'),
    @('mesa-23.1.x/src/util/u_atomic.h',
        'LicenseRef-Mesa-U-Atomic-Public-Domain'),
    @('mesa-23.1.x/src/gallium/auxiliary/util/dbghelp.h',
        'LicenseRef-Mesa-DbgHelp-Public-Domain'),
    @('mesa-23.1.x/src/util/sha1/sha1.h',
        'LicenseRef-Mesa-SHA1-Public-Domain')
)) {
    $file = @($files | Where-Object { $_.relative_path -ceq $binding[0] })
    Assert-Equal $file.Count 1 "Missing curated license row '$($binding[0])'."
    Assert-Equal $file[0].declared_license_expression $binding[1] `
        "Wrong curated license for '$($binding[0])'."
    $evidenceRow = @($evidence | Where-Object {
        $_.id -ceq $file[0].license_evidence_ids[0]
    })
    Assert-Equal $evidenceRow.Count 1 `
        "Missing curated evidence for '$($binding[0])'."
    Assert-Equal $evidenceRow[0].kind 'inline' `
        "Curated evidence for '$($binding[0])' is not source-bound."
    Assert-Equal $evidenceRow[0].relative_path $binding[0] `
        "Curated evidence for '$($binding[0])' is bound to another file."
    Assert-Equal $evidenceRow[0].observed_license_expression $binding[1] `
        "Wrong observed license for '$($binding[0])'."
}

$evidenceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$usedEvidenceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($row in $evidence) {
    Assert-True ($evidenceIds.Add([string]$row.id)) `
        "Duplicate evidence ID '$($row.id)'."
    Assert-True ($row.git_blob -cmatch '^[0-9a-f]{40}$') `
        "Invalid evidence Git blob for '$($row.id)'."
    Assert-True ($row.sha256 -cmatch '^[0-9a-f]{64}$') `
        "Invalid evidence SHA-256 for '$($row.id)'."
}
foreach ($file in $files) {
    foreach ($evidenceId in @($file.license_evidence_ids)) {
        Assert-True ($evidenceIds.Contains([string]$evidenceId)) `
            "Unknown evidence ID '$evidenceId'."
        [void]$usedEvidenceIds.Add([string]$evidenceId)
    }
}
Assert-Equal $usedEvidenceIds.Count $evidenceIds.Count `
    'The Mesa manifest has unused license evidence.'
Assert-Equal @($evidence | Where-Object { $_.kind -ceq 'license-document' }).Count 3 `
    'The license-document evidence count is wrong.'
Assert-Equal @($evidence | Where-Object { $_.kind -ceq 'inline' }).Count 1499 `
    'The inline evidence count is wrong.'

$excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in @(
    'win9x/nine/nine_memory_helper.c',
    'extra/clock_gettime32.c',
    'mesa-23.1.x/src/gallium/auxiliary/postprocess/pp_mlaa.c',
    'include/git_sha1.h',
    'win9x/wddm_screen.h',
    'win9x/gadrv9x.cpp',
    'win9x/gadrv9xenv.cpp',
    'win9x/libgl_vmws.c',
    'win9x/svgadrv.c',
    'win9x/svgadrv_cb.c',
    'win9x/svgadrv_present.c',
    'win9x/winsys/vmw_screen.c',
    'win9x/winsys/vmw_screen_ioctl.c',
    'win9x/winsys/vmw_screen_wddm.c'
) + @($seed.selection.generated_absent_paths)) {
    [void]$excluded.Add([string]$path)
}
foreach ($path in $excluded) {
    Assert-True (-not $pathSet.Contains($path)) "Excluded Mesa path '$path' is present."
}
Assert-Equal @($files | Where-Object {
    $_.relative_path.StartsWith('include/winddk/', [StringComparison]::OrdinalIgnoreCase)
}).Count 0 'A WinDDK path entered the reviewed closure.'

$forbiddenPattern = '(?i)(/drivers/(softpipe|llvmpipe|virgl|zink)/|/frontends/lavapipe/|/winsys/svga/drm/|^win9x/winsys/|^win9x/(gadrv9x|gadrv9xenv|svgadrv|svgadrv_cb|svgadrv_present|libgl_vmws)\.(c|cpp)$)'
Assert-Equal @($files | Where-Object { $_.relative_path -match $forbiddenPattern }).Count 0 `
    'A forbidden renderer or backend entered the reviewed closure.'

if (-not [string]::IsNullOrWhiteSpace($MesaCheckout)) {
    $checkout = [IO.Path]::GetFullPath($MesaCheckout)
    Assert-True (Test-Path -LiteralPath $checkout -PathType Container) `
        "Mesa checkout not found: $checkout"
    Assert-True (Test-Path -LiteralPath (Join-Path $checkout '.git')) `
        "Mesa checkout is not a Git checkout: $checkout"

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
    $tempRoot = Join-Path $tempBase ("retvrn99-mesa-closure-{0}" -f [Guid]::NewGuid().ToString('N'))
    Assert-True ($tempRoot.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) `
        'Unsafe Mesa closure test directory.'
    try {
        $closureDirectory = Join-Path $tempRoot 'component-closures'
        New-Item -ItemType Directory -Path $closureDirectory -Force | Out-Null
        $localManifest = Join-Path $closureDirectory 'mesa9x-23.1.x.json'
        Copy-Item -LiteralPath $manifestPath -Destination $localManifest
        $generatorOutput = @(& $updateScript -MesaCheckout $checkout `
            -ManifestPath $localManifest `
            -CompilerClosurePath $compilerClosurePath)
        Assert-Equal ($generatorOutput -join [Environment]::NewLine) `
            "Wrote ready Mesa component closure with 1687 files, 652 compiler dependencies, 1502 evidence rows, and SHA-256 $manifestHash." `
            'The Mesa license-closure generator result is wrong.'
        Assert-Equal (Get-FileHash -LiteralPath $localManifest `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The Mesa license-closure generator is not idempotent.'
        $localLock = Join-Path $tempRoot 'upstream.lock.tsv'
        $checkoutName = Split-Path -Leaf $checkout
        $localLockText = @(
            '# SPDX-License-Identifier: GPL-3.0-only',
            '# Source-provenance lock only. These rows do not identify shipped or install-ready payloads.',
            "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope",
            "mesa9x`t$checkoutName`thttps://github.com/JHRobotics/mesa9x.git`t29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f`tLicenseRef-Mixed-File-Level`tplanned-component`tcomponent-closures/mesa9x-23.1.x.json`t$manifestHash`tmesa-23-1-9-gsw-graphics"
        ) -join "`n"
        [IO.File]::WriteAllText($localLock, $localLockText + "`n", [Text.UTF8Encoding]::new($false))
        $output = @(& $verifyScript -SourceRoot (Split-Path -Parent $checkout) `
            -LockFile $localLock -SourceName mesa9x)
        Assert-Equal ($output -join [Environment]::NewLine) `
            'Verified 1 ready Windows 98 component source closures.' `
            'The ready Mesa source-bound result is wrong.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
    Write-Output 'All Mesa component-closure manifest and source-bound tests passed.'
}
else {
    Write-Output 'All Mesa component-closure manifest tests passed; source-bound verification was not requested.'
}

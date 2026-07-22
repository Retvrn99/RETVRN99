# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$Vkd3dCheckout
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    try {
        & $Body | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $($_.Exception.Message)"
        }
        return
    }
    throw 'Expected an exception.'
}

function Assert-SameOrdinalSet {
    param(
        [Parameter(Mandatory = $true)][string[]]$Actual,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [string[]]$actualCopy = @($Actual)
    [string[]]$expectedCopy = @($Expected)
    [Array]::Sort($actualCopy, [StringComparer]::Ordinal)
    [Array]::Sort($expectedCopy, [StringComparer]::Ordinal)
    Assert-Equal ($actualCopy -join "`n") ($expectedCopy -join "`n") $Message
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Write-TestLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SourceDirectory
    )

    $hash = (Get-FileHash -LiteralPath $ManifestPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    $text = @(
        '# SPDX-License-Identifier: GPL-3.0-only',
        '# Source-provenance lock only. These rows do not identify shipped or install-ready payloads.',
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope",
        "vkd3d-shader`t$SourceDirectory`thttps://gitlab.winehq.org/wine/vkd3d.git`t1b0924d12c18df03912a8876ed17fd017ce9308e`tLGPL-2.1-or-later`tplanned-component`tcomponent-closures/vkd3d-shader.json`t$hash`tlibs-vkd3d-shader"
    ) -join "`n"
    [IO.File]::WriteAllText($Path, $text + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-ManifestTransactionFiles {
    param([Parameter(Mandatory = $true)][string]$Path)

    $directory = [IO.Path]::GetDirectoryName($Path)
    $prefix = '.' + [IO.Path]::GetFileName($Path) + '.retvrn99-'
    return @([IO.Directory]::EnumerateFileSystemEntries($directory) |
        Where-Object {
            [IO.Path]::GetFileName($_).StartsWith(
                $prefix,
                [StringComparison]::Ordinal
            )
        })
}

function Assert-NoManifestTransactionFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $leftovers = @(Get-ManifestTransactionFiles $Path)
    Assert-Equal $leftovers.Count 0 $Message
}

function Get-TestStableFileIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Initialize-Vkd3dEvidenceNative
    $handle = [Retvrn99.Vkd3dEvidenceNative]::OpenStableFile($Path)
    try {
        return [Retvrn99.Vkd3dEvidenceNative]::GetFileIdentity($handle)
    }
    finally { $handle.Dispose() }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $repoRoot `
    'drivers\win98\component-closures\vkd3d-shader.json'
$lockPath = Join-Path $repoRoot 'drivers\win98\upstream.lock.tsv'
$updateScript = Join-Path $PSScriptRoot `
    'update-win98-vkd3d-shader-component-license-closure.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify-win98-component-closure.ps1'
$schemaPath = Join-Path $repoRoot `
    'drivers\win98\component-closure-v2.schema.json'

$manifestText = Get-Content -Raw -LiteralPath $manifestPath
$manifest = $manifestText | ConvertFrom-Json
if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
    Assert-True (Test-Json -Json $manifestText -SchemaFile $schemaPath) `
        'The vkd3d manifest does not satisfy component schema v2.'
}
$manifestHash = (Get-FileHash -LiteralPath $manifestPath `
    -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal $manifestHash `
    '459cab81112ce075532fdee5e4f4b55f38fa03798506a28ecddd1f23ba42d03f' `
    'The reviewed vkd3d-shader manifest hash changed.'

$lockLines = @(Get-Content -LiteralPath $lockPath | Where-Object {
    $_.Length -ne 0 -and -not $_.StartsWith('#', [StringComparison]::Ordinal)
})
$lockRows = @($lockLines | ConvertFrom-Csv -Delimiter "`t")
$lockRows = @($lockRows | Where-Object { $_.name -ceq 'vkd3d-shader' })
Assert-Equal $lockRows.Count 1 'The upstream lock must select one vkd3d row.'
Assert-Equal $lockRows[0].closure_manifest_sha256 $manifestHash `
    'The upstream lock does not bind the reviewed vkd3d manifest.'

Assert-Equal $manifest.schema 2 'The vkd3d manifest schema is wrong.'
Assert-Equal $manifest.status 'ready' 'The vkd3d manifest is not ready.'
Assert-Equal $manifest.reason '' 'The ready vkd3d manifest has a blocker.'
Assert-Equal $manifest.upstream_name 'vkd3d-shader' `
    'The vkd3d manifest upstream name is wrong.'
Assert-Equal $manifest.owning_commit `
    '1b0924d12c18df03912a8876ed17fd017ce9308e' `
    'The vkd3d manifest commit changed.'
Assert-Equal @($manifest.source_prefixes).Count 3 `
    'The vkd3d source-prefix count is wrong.'

$files = @($manifest.files)
$evidence = @($manifest.license_evidence)
Assert-Equal $files.Count 40 'The reviewed vkd3d file count is wrong.'
Assert-Equal $evidence.Count 39 'The reviewed vkd3d evidence count is wrong.'
Assert-Equal @($evidence | Where-Object { $_.kind -ceq 'license-document' }).Count 2 `
    'The vkd3d project-license evidence count is wrong.'
Assert-Equal @($evidence | Where-Object { $_.kind -ceq 'inline' }).Count 37 `
    'The vkd3d inline evidence count is wrong.'

$sourceUnits = @(
    'checksum.c', 'd3d_asm.c', 'd3dbc.c', 'dxbc.c', 'dxil.c', 'fx.c',
    'glsl.c', 'hlsl.c', 'hlsl_codegen.c', 'hlsl_constant_ops.c', 'ir.c',
    'msl.c', 'spirv.c', 'tpf.c', 'vkd3d_shader_main.c'
) | ForEach-Object { "libs/vkd3d-shader/$_" }
$compilerDependencies = @(
    'include/private/list.h',
    'include/private/rbtree.h',
    'include/private/vkd3d_common.h',
    'include/private/vkd3d_memory.h',
    'include/private/vkd3d_shader_utils.h',
    'include/vkd3d_d3d9types.h',
    'include/vkd3d_shader.h',
    'include/vkd3d_types.h',
    'include/vkd3d_windows.h',
    'libs/vkd3d-shader/hlsl.h',
    'libs/vkd3d-shader/preproc.h',
    'libs/vkd3d-shader/vkd3d_shader_private.h'
)
$generatorInputs = @(
    'include/private/spirv.core.grammar.json',
    'include/vkd3d_d3d9types.h',
    'include/vkd3d_d3dcommon.idl',
    'include/vkd3d_d3dx9shader.idl',
    'include/vkd3d_unknown.idl',
    'libs/vkd3d-shader/hlsl.l',
    'libs/vkd3d-shader/hlsl.y',
    'libs/vkd3d-shader/make_spirv',
    'libs/vkd3d-shader/preproc.l',
    'libs/vkd3d-shader/preproc.y'
)
$buildDescriptions = @(
    'Makefile.am',
    'configure.ac',
    'libs/vkd3d-shader/vkd3d_shader.map'
)
$resources = @('libs/vkd3d-shader/libvkd3d-shader.pc.in')
Assert-SameOrdinalSet @($files | Where-Object {
    @($_.roles) -ccontains 'source-unit'
} | ForEach-Object relative_path) $sourceUnits 'The vkd3d source-unit set changed.'
Assert-SameOrdinalSet @($files | Where-Object {
    @($_.roles) -ccontains 'compiler-dependency'
} | ForEach-Object relative_path) $compilerDependencies `
    'The vkd3d compiler-dependency set changed.'
Assert-SameOrdinalSet @($files | Where-Object {
    @($_.roles) -ccontains 'generator-input'
} | ForEach-Object relative_path) $generatorInputs `
    'The vkd3d generator-input set changed.'
Assert-SameOrdinalSet @($files | Where-Object {
    @($_.roles) -ccontains 'build-description'
} | ForEach-Object relative_path) $buildDescriptions `
    'The vkd3d build-description set changed.'
Assert-SameOrdinalSet @($files | Where-Object {
    @($_.roles) -ccontains 'resource'
} | ForEach-Object relative_path) $resources 'The vkd3d resource set changed.'

$seenPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$previousPath = $null
foreach ($file in $files) {
    Assert-True ($seenPaths.Add([string]$file.relative_path)) `
        "Duplicate vkd3d path '$($file.relative_path)'."
    if ($null -ne $previousPath) {
        Assert-True ([StringComparer]::Ordinal.Compare(
            $previousPath,
            [string]$file.relative_path
        ) -lt 0) 'The vkd3d rows are not in strict ordinal order.'
    }
    $previousPath = [string]$file.relative_path
    Assert-True ($file.git_blob -cmatch '^[0-9a-f]{40}$') `
        "Invalid Git blob for '$($file.relative_path)'."
    Assert-True ($file.sha256 -cmatch '^[0-9a-f]{64}$') `
        "Invalid SHA-256 for '$($file.relative_path)'."
    Assert-True (-not ([string]$file.relative_path).Contains('\')) `
        "Noncanonical path '$($file.relative_path)'."
}

$licenseCounts = @{}
foreach ($group in @($files | Group-Object selected_license_expression)) {
    $licenseCounts[$group.Name] = $group.Count
}
Assert-Equal $licenseCounts.Count 3 'The vkd3d license partition changed.'
Assert-Equal $licenseCounts['LGPL-2.1-or-later'] 38 `
    'The vkd3d LGPL partition changed.'
Assert-Equal $licenseCounts['LGPL-2.1-or-later AND MIT'] 1 `
    'The vkd3d conjunctive partition changed.'
Assert-Equal $licenseCounts['MIT'] 1 'The vkd3d MIT partition changed.'

$evidenceById = @{}
$usedEvidence = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($row in $evidence) {
    Assert-True (-not $evidenceById.ContainsKey([string]$row.id)) `
        "Duplicate vkd3d evidence '$($row.id)'."
    $evidenceById[[string]$row.id] = $row
}
foreach ($file in $files) {
    foreach ($id in @($file.license_evidence_ids)) {
        Assert-True ($evidenceById.ContainsKey([string]$id)) `
            "Unknown evidence '$id'."
        [void]$usedEvidence.Add([string]$id)
    }
}
Assert-Equal $usedEvidence.Count $evidence.Count `
    'The vkd3d manifest has unused evidence.'

$hlsl = @($files | Where-Object {
    $_.relative_path -ceq 'libs/vkd3d-shader/hlsl.h'
})[0]
Assert-Equal $hlsl.declared_license_expression `
    'LGPL-2.1-or-later AND MIT' 'hlsl.h lost its exact conjunction.'
$hlslEvidence = @($hlsl.license_evidence_ids | ForEach-Object {
    $evidenceById[$_]
})
Assert-SameOrdinalSet @($hlslEvidence.observed_license_expression) `
    @('LGPL-2.1-or-later', 'MIT') 'hlsl.h evidence changed.'
$hlslLgpl = @($hlslEvidence | Where-Object {
    $_.observed_license_expression -ceq 'LGPL-2.1-or-later'
})[0]
$hlslMit = @($hlslEvidence | Where-Object {
    $_.observed_license_expression -ceq 'MIT'
})[0]
Assert-Equal $hlslLgpl.locator.byte_offset 0 'hlsl.h LGPL offset changed.'
Assert-Equal $hlslLgpl.locator.byte_count 847 'hlsl.h LGPL range changed.'
Assert-Equal $hlslMit.locator.byte_offset 996 'hlsl.h MIT offset changed.'
Assert-Equal $hlslMit.locator.byte_count 1338 'hlsl.h MIT range changed.'

$grammar = @($files | Where-Object {
    $_.relative_path -ceq 'include/private/spirv.core.grammar.json'
})[0]
Assert-Equal $grammar.selected_license_expression 'MIT' `
    'The SPIR-V grammar is not classified as MIT.'
$checksum = @($files | Where-Object {
    $_.relative_path -ceq 'libs/vkd3d-shader/checksum.c'
})[0]
Assert-Equal $checksum.selected_license_expression 'LGPL-2.1-or-later' `
    'checksum.c public-domain provenance was misclassified as a second license.'

foreach ($binding in @(
    @('libs/vkd3d-shader/libvkd3d-shader.pc.in', 'copying-lgpl'),
    @('libs/vkd3d-shader/vkd3d_shader.map', 'copying-lgpl'),
    @('Makefile.am', 'license-lgpl'),
    @('configure.ac', 'license-lgpl')
)) {
    $file = @($files | Where-Object { $_.relative_path -ceq $binding[0] })[0]
    Assert-Equal (@($file.license_evidence_ids) -join ',') $binding[1] `
        "Project-license binding changed for '$($binding[0])'."
}

Assert-True ($manifestText -notmatch '(?i)([A-Z]:\\|/home/|/tmp/)') `
    'The vkd3d manifest leaks a private absolute path.'

$updaterText = Get-Content -Raw -LiteralPath $updateScript
$updaterTokens = $null
$updaterErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $updateScript,
    [ref]$updaterTokens,
    [ref]$updaterErrors
)
Assert-Equal $updaterErrors.Count 0 'The vkd3d updater does not parse.'
Assert-True ($updaterText.Contains(
    "'vkd3d-shader-compiler-evidence.ps1'",
    [StringComparison]::Ordinal
)) 'The updater does not bind the hardened process helper.'
Assert-True ($updaterText.Contains(
    'Invoke-Vkd3dEvidenceProcess',
    [StringComparison]::Ordinal
)) 'The updater does not use the runtime-bounded process launcher.'
Assert-True ($updaterText.Contains(
    'Vkd3dEvidenceNative]::OpenStableDirectory',
    [StringComparison]::Ordinal
)) 'The updater does not use the pinned native directory handle.'
Assert-True (-not $updaterText.Contains(
    "GetType('Interop+Kernel32'",
    [StringComparison]::Ordinal
)) 'The updater still reflects an internal runtime directory primitive.'
foreach ($requiredPattern in @(
    "`$privateTempState = 'absent'",
    "`$privateTempState = 'bootstrap'",
    "`$privateTempState = 'owned'",
    '[IO.File]::Replace',
    'CreateExclusiveDirectory',
    'GetFileIdentity',
    'MarkDelete',
    'Get-Vkd3dEvidenceSanitizedFailureText',
    'forward-replace-partial',
    'rollback-replace-partial',
    'An unowned manifest transaction leaf was preserved.'
)) {
    Assert-True ($updaterText.Contains(
        $requiredPattern,
        [StringComparison]::Ordinal
    )) "The updater is missing transaction guard '$requiredPattern'."
}
Assert-True (-not $updaterText.Contains(
    'Write-CompactManifest $manifest $ManifestPath',
    [StringComparison]::Ordinal
)) 'The updater still writes the live manifest in place.'
Assert-True (-not $updaterText.Contains(
    '[scriptblock]$Before',
    [StringComparison]::Ordinal
)) 'The updater still exposes arbitrary in-process mutation hooks.'
Assert-True (-not $updaterText.Contains(
    '[IO.Directory]::CreateDirectory($privateTempRoot)',
    [StringComparison]::Ordinal
)) 'The updater still creates its private root non-exclusively.'
$promotionBackupFaultIndex = $updaterText.IndexOf(
    "if (`$TestFault -ceq 'promotion-backup-race')",
    [StringComparison]::Ordinal
)
$immediateBoundaryIndex = $updaterText.IndexOf(
    'Immediate pre-promotion manifest parent',
    [StringComparison]::Ordinal
)
$atomicPromotionIndex = $updaterText.IndexOf(
    '[IO.File]::Replace($candidatePath, $ManifestPath, $backupPath, $true)',
    [StringComparison]::Ordinal
)
Assert-True ($promotionBackupFaultIndex -ge 0 -and
    $immediateBoundaryIndex -gt $promotionBackupFaultIndex -and
    $atomicPromotionIndex -gt $immediateBoundaryIndex) `
    'The updater does not renew its boundary after the backup-race seam.'
$publicUpdater = Get-Command -Name $updateScript -CommandType ExternalScript
Assert-True (-not $publicUpdater.Parameters.ContainsKey('TestFault')) `
    'The updater ExternalScript exposes its internal fault selector.'
foreach ($unsafePattern in @(
    'Diagnostics.ProcessStartInfo', 'CopyToAsync', 'ReadToEndAsync',
    '$Arguments -join'
)) {
    Assert-True ($updaterText.IndexOf(
        $unsafePattern,
        [StringComparison]::Ordinal
    ) -lt 0) "The updater retains unsafe child handling '$unsafePattern'."
}

$sourceBoundCheckout = $Vkd3dCheckout
$canonicalManifestPath = $manifestPath
. $updateScript -Vkd3dCheckout 'internal-test-seam-load'
$Vkd3dCheckout = $sourceBoundCheckout
$manifestPath = $canonicalManifestPath
Initialize-Vkd3dEvidenceNative
$internalUpdater = Get-Command `
    -Name Invoke-Vkd3dComponentClosureUpdaterInternal `
    -CommandType Function
Assert-True $internalUpdater.Parameters.ContainsKey('TestFault') `
    'The dot-sourced updater did not expose its internal fault selector.'

$syntheticBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
    [char[]]'\/'
)
$ownedBefore = @([IO.Directory]::EnumerateDirectories(
    $syntheticBase,
    'retvrn99-vkd3d-updater-*',
    [IO.SearchOption]::TopDirectoryOnly
))
[Array]::Sort($ownedBefore, [StringComparer]::OrdinalIgnoreCase)
$syntheticRoot = Join-Path $syntheticBase (
    'retvrn99-vkd3d-updater-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
try {
    $syntheticCheckout = Join-Path $syntheticRoot 'private-checkout-sentinel'
    [void][IO.Directory]::CreateDirectory((Join-Path $syntheticCheckout '.git'))
    $stablePath = Join-Path $syntheticRoot 'stable-directory'
    $movedStablePath = Join-Path $syntheticRoot 'stable-directory-moved'
    [void][IO.Directory]::CreateDirectory($stablePath)
    $stableHandle = [Retvrn99.Vkd3dEvidenceNative]::OpenStableDirectory(
        $stablePath
    )
    try {
        $renameBlocked = $false
        try { [IO.Directory]::Move($stablePath, $movedStablePath) }
        catch { $renameBlocked = $true }
        Assert-True ($renameBlocked -and
            [IO.Directory]::Exists($stablePath) -and
            -not [IO.Directory]::Exists($movedStablePath)) `
            'The stable directory handle allowed a rename.'

        $deleteBlocked = $false
        $deleteHandle = $null
        try {
            $deleteHandle =
                [Retvrn99.Vkd3dEvidenceNative]::OpenDeleteHandle($stablePath)
            [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($deleteHandle)
        }
        catch { $deleteBlocked = $true }
        finally {
            if ($null -ne $deleteHandle) { $deleteHandle.Dispose() }
        }
        Assert-True ($deleteBlocked -and [IO.Directory]::Exists($stablePath)) `
            'The stable directory handle allowed delete disposition.'
    }
    finally { $stableHandle.Dispose() }
    [IO.Directory]::Move($stablePath, $movedStablePath)
    $syntheticManifest = Join-Path $syntheticRoot 'candidate.json'
    [IO.File]::Copy($manifestPath, $syntheticManifest)
    $whereExe = Join-Path ([Environment]::GetFolderPath('System')) 'where.exe'
    $caught = $null
    try {
        & $updateScript -Vkd3dCheckout $syntheticCheckout `
            -ManifestPath $syntheticManifest -GitExe $whereExe | Out-Null
    }
    catch { $caught = $_.Exception.Message }
    Assert-True (-not [string]::IsNullOrWhiteSpace($caught)) `
        'The synthetic Git failure was not rejected.'
    Assert-True ($caught -match
        'Git command|pinned vkd3d checkout must be clean') `
        'The synthetic Git failure did not use a sanitized error.'
    Assert-True ($caught.IndexOf(
        $syntheticCheckout,
        [StringComparison]::OrdinalIgnoreCase
    ) -lt 0) 'The synthetic Git failure exposed its private checkout path.'
    Assert-Equal (Get-FileHash -LiteralPath $syntheticManifest `
        -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
        'The failed updater changed its target manifest.'

    $bootstrapManifest = Join-Path $syntheticRoot 'bootstrap.json'
    [IO.File]::Copy($manifestPath, $bootstrapManifest)
    $bootstrapCaught = $null
    try {
        Invoke-Vkd3dComponentClosureUpdaterInternal `
            -Vkd3dCheckout $syntheticCheckout `
            -ManifestPath $bootstrapManifest -GitExe $whereExe `
            -TestFault bootstrap-after-marker | Out-Null
    }
    catch { $bootstrapCaught = $_.Exception.Message }
    Assert-True ($bootstrapCaught -match
        'Injected owner-marker bootstrap failure') `
        'The owner-marker bootstrap failure was not preserved.'
    Assert-True ($bootstrapCaught.IndexOf(
        $syntheticCheckout,
        [StringComparison]::OrdinalIgnoreCase
    ) -lt 0) 'The bootstrap failure exposed its private checkout path.'
    Assert-Equal (Get-FileHash -LiteralPath $bootstrapManifest `
        -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
        'The bootstrap failure changed its target manifest.'

    $cleanupManifest = Join-Path $syntheticRoot 'cleanup.json'
    [IO.File]::Copy($manifestPath, $cleanupManifest)
    $cleanupCaught = $null
    try {
        Invoke-Vkd3dComponentClosureUpdaterInternal `
            -Vkd3dCheckout $syntheticCheckout `
            -ManifestPath $cleanupManifest -GitExe $whereExe `
            -TestFault cleanup-failure | Out-Null
    }
    catch { $cleanupCaught = $_.Exception }
    Assert-True ($null -ne $cleanupCaught) `
        'The combined primary and cleanup failure was not rejected.'
    $cleanupText = $cleanupCaught.ToString()
    Assert-True ($cleanupText -match
        'Git command|pinned vkd3d checkout must be clean') `
        'Cleanup masked the updater primary failure.'
    Assert-True ($cleanupCaught.Message.StartsWith(
        'vkd3d-shader updater and cleanup both failed.',
        [StringComparison]::Ordinal
    )) 'The updater did not aggregate its cleanup failure.'
    Assert-True ($cleanupText -match 'Injected cleanup failure') `
        'The updater omitted its cleanup failure from the aggregate.'
    Assert-True ($cleanupText.IndexOf(
        $syntheticCheckout,
        [StringComparison]::OrdinalIgnoreCase
    ) -lt 0) 'The combined failure exposed its private checkout path.'
    Assert-Equal (Get-FileHash -LiteralPath $cleanupManifest `
        -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
        'The combined failure changed its target manifest.'
}
finally {
    if ([IO.Directory]::Exists($syntheticRoot)) {
        [IO.Directory]::Delete($syntheticRoot, $true)
    }
}
$ownedAfter = @([IO.Directory]::EnumerateDirectories(
    $syntheticBase,
    'retvrn99-vkd3d-updater-*',
    [IO.SearchOption]::TopDirectoryOnly
))
[Array]::Sort($ownedAfter, [StringComparer]::OrdinalIgnoreCase)
Assert-Equal ($ownedAfter -join "`n") ($ownedBefore -join "`n") `
    'The failed updater retained an owned private temporary root.'

if ([string]::IsNullOrWhiteSpace($Vkd3dCheckout)) {
    Write-Output 'All vkd3d-shader component-closure manifest tests passed; source-bound verification was not requested.'
    return
}

$checkout = [IO.Path]::GetFullPath($Vkd3dCheckout)
Assert-True (Test-Path -LiteralPath (Join-Path $checkout '.git')) `
    'The requested vkd3d checkout is not a Git checkout.'
$sourceRoot = Split-Path -Parent $checkout
$sourceDirectory = Split-Path -Leaf $checkout
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
    [char[]]'\/'
)
$tempRoot = Join-Path $tempBase (
    'retvrn99-vkd3d-component-{0}' -f [Guid]::NewGuid().ToString('N')
)
try {
    $closureRoot = Join-Path $tempRoot 'component-closures'
    New-Item -ItemType Directory -Path $closureRoot -Force | Out-Null
    $candidatePath = Join-Path $closureRoot 'vkd3d-shader.json'
    Copy-Item -LiteralPath $manifestPath -Destination $candidatePath
    $testLock = Join-Path $tempRoot 'upstream.lock.tsv'
    $poisonConfig = Join-Path $tempRoot 'host-global.gitconfig'
    [IO.File]::WriteAllText(
        $poisonConfig,
        "[safe]`n  directory = %(prefix)///retvrn99-private-sentinel`n",
        [Text.UTF8Encoding]::new($false)
    )
    $gitEnvironmentNames = @(
        'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
        'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0'
    )
    $savedGitEnvironment = @{}
    foreach ($name in $gitEnvironmentNames) {
        $item = Get-Item -LiteralPath ('Env:' + $name) `
            -ErrorAction SilentlyContinue
        $savedGitEnvironment[$name] = if ($null -eq $item) {
            [pscustomobject]@{Present = $false; Value = ''}
        }
        else {
            [pscustomobject]@{Present = $true; Value = [string]$item.Value}
        }
    }
    try {
        $env:GIT_CONFIG_GLOBAL = $poisonConfig
        $env:GIT_CONFIG_SYSTEM = $poisonConfig
        $env:GIT_CONFIG_NOSYSTEM = '0'
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'safe.directory'
        $env:GIT_CONFIG_VALUE_0 = 'Z:/retvrn99-private-sentinel'

        $updaterTempsBefore = @([IO.Directory]::EnumerateDirectories(
            $tempBase,
            'retvrn99-vkd3d-updater-*',
            [IO.SearchOption]::TopDirectoryOnly
        ))
        [Array]::Sort($updaterTempsBefore, [StringComparer]::OrdinalIgnoreCase)
        $output = @(& $updateScript -Vkd3dCheckout $checkout `
            -ManifestPath $candidatePath 2>&1)
        $updaterTempsAfter = @([IO.Directory]::EnumerateDirectories(
            $tempBase,
            'retvrn99-vkd3d-updater-*',
            [IO.SearchOption]::TopDirectoryOnly
        ))
        [Array]::Sort($updaterTempsAfter, [StringComparer]::OrdinalIgnoreCase)
        Assert-Equal ($updaterTempsAfter -join "`n") `
            ($updaterTempsBefore -join "`n") `
            'The successful updater retained an owned private temporary root.'
        Assert-Equal ($output -join [Environment]::NewLine) `
            "Wrote ready vkd3d-shader component closure with 40 files (25 subtree, 13 dependency, and 2 build-description roots), 39 evidence rows, and SHA-256 $manifestHash." `
            'The vkd3d updater output changed.'
        Assert-Equal (Get-FileHash -LiteralPath $candidatePath `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The vkd3d updater is not idempotent.'
        Assert-NoManifestTransactionFiles $candidatePath `
            'The successful updater retained a manifest transaction file.'

        $verificationPath = Join-Path $closureRoot 'verification-failure.json'
        Copy-Item -LiteralPath $manifestPath -Destination $verificationPath
        $verificationCaught = $null
        try {
            Invoke-Vkd3dComponentClosureUpdaterInternal `
                -Vkd3dCheckout $checkout `
                -ManifestPath $verificationPath `
                -TestFault candidate-corrupt | Out-Null
        }
        catch { $verificationCaught = $_.Exception.Message }
        Assert-True ($verificationCaught -match
            'Candidate component manifest failed exact verification') `
            'Candidate corruption was not rejected before promotion.'
        Assert-Equal (Get-FileHash -LiteralPath $verificationPath `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'Candidate verification failure changed the live manifest.'
        Assert-NoManifestTransactionFiles $verificationPath `
            'Candidate verification failure retained a transaction file.'

        $replacementPath = Join-Path $closureRoot 'replacement-failure.json'
        Copy-Item -LiteralPath $manifestPath -Destination $replacementPath
        $replacementCaught = $null
        try {
            Invoke-Vkd3dComponentClosureUpdaterInternal `
                -Vkd3dCheckout $checkout `
                -ManifestPath $replacementPath `
                -TestFault candidate-replace-exact | Out-Null
        }
        catch { $replacementCaught = $_.Exception }
        Assert-True ($replacementCaught.Message.StartsWith(
            'vkd3d-shader updater and cleanup both failed.',
            [StringComparison]::Ordinal
        )) 'Candidate replacement did not fail with preserved cleanup state.'
        Assert-True ($replacementCaught.ToString() -match
            'Candidate component manifest ownership changed') `
            'Candidate replacement masked its primary failure.'
        Assert-Equal (Get-FileHash -LiteralPath $replacementPath `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'Candidate replacement changed the live manifest.'
        $replacementLeaves = @(Get-ManifestTransactionFiles $replacementPath)
        Assert-Equal $replacementLeaves.Count 1 `
            'Candidate replacement did not preserve exactly one raced leaf.'
        Assert-True ([IO.Path]::GetFileName($replacementLeaves[0]).Contains(
            '.retvrn99-candidate-',
            [StringComparison]::Ordinal
        )) 'Candidate replacement preserved the wrong transaction leaf.'
        Assert-Equal (Get-FileHash -LiteralPath $replacementLeaves[0] `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The preserved candidate replacement bytes changed.'

        $promotionBackupPath = Join-Path $closureRoot `
            'promotion-backup-race.json'
        Copy-Item -LiteralPath $manifestPath -Destination $promotionBackupPath
        $promotionBackupCaught = $null
        try {
            Invoke-Vkd3dComponentClosureUpdaterInternal `
                -Vkd3dCheckout $checkout `
                -ManifestPath $promotionBackupPath `
                -TestFault promotion-backup-race | Out-Null
        }
        catch { $promotionBackupCaught = $_.Exception }
        Assert-True ($promotionBackupCaught.Message.StartsWith(
            'vkd3d-shader updater and cleanup both failed.',
            [StringComparison]::Ordinal
        )) 'The raced-in promotion backup did not fail closed.'
        Assert-True ($promotionBackupCaught.ToString() -match
            'transaction output appeared immediately before promotion') `
            'The raced-in promotion backup masked its primary failure.'
        Assert-Equal (Get-FileHash -LiteralPath $promotionBackupPath `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The raced-in promotion backup changed the live manifest.'
        $promotionBackupLeaves = @(
            Get-ManifestTransactionFiles $promotionBackupPath
        )
        Assert-Equal $promotionBackupLeaves.Count 1 `
            'The raced-in promotion backup was not preserved exactly once.'
        Assert-True ([IO.Path]::GetFileName($promotionBackupLeaves[0]).Contains(
            '.retvrn99-backup-',
            [StringComparison]::Ordinal
        )) 'The promotion backup race preserved the wrong transaction leaf.'
        Assert-Equal ([IO.File]::ReadAllText($promotionBackupLeaves[0])) `
            "foreign promotion backup`n" `
            'The raced-in promotion backup bytes changed.'

        $promotionRacePath = Join-Path $closureRoot 'promotion-race.json'
        Copy-Item -LiteralPath $manifestPath -Destination $promotionRacePath
        $promotionRaceCaught = $null
        try {
            Invoke-Vkd3dComponentClosureUpdaterInternal `
                -Vkd3dCheckout $checkout `
                -ManifestPath $promotionRacePath `
                -TestFault promotion-destination-race | Out-Null
        }
        catch { $promotionRaceCaught = $_.Exception.Message }
        Assert-True ($promotionRaceCaught -match
            'Promotion destination drifted') `
            'The pre-promotion destination race was not rejected.'
        Assert-Equal ([IO.File]::ReadAllText($promotionRacePath)) "{}`n" `
            'Rollback did not restore the actual raced destination.'
        Assert-NoManifestTransactionFiles $promotionRacePath `
            'Pre-promotion race retained a transaction file.'

        $forwardPartialPath = Join-Path $closureRoot 'forward-partial.json'
        Copy-Item -LiteralPath $manifestPath -Destination $forwardPartialPath
        $forwardPartialIdentity = Get-TestStableFileIdentity `
            $forwardPartialPath 'Forward partial initial manifest'
        $forwardPartialCaught = $null
        try {
            Invoke-Vkd3dComponentClosureUpdaterInternal `
                -Vkd3dCheckout $checkout `
                -ManifestPath $forwardPartialPath `
                -TestFault forward-replace-partial | Out-Null
        }
        catch { $forwardPartialCaught = $_.Exception }
        Assert-True ($forwardPartialCaught -is [AggregateException]) `
            'The forward partial mapping did not retain its replace failure.'
        $forwardPartialText = $forwardPartialCaught.ToString()
        Assert-True ($forwardPartialText -match
            'Injected forward ReplaceFile partial-state failure') `
            'The forward partial mapping masked its replace failure.'
        Assert-True ($forwardPartialText.IndexOf(
            $checkout,
            [StringComparison]::OrdinalIgnoreCase
        ) -lt 0) 'The forward partial mapping exposed its private checkout.'
        Assert-Equal (Get-FileHash -LiteralPath $forwardPartialPath `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The forward partial mapping did not restore the prior bytes.'
        Assert-Equal (Get-TestStableFileIdentity `
            $forwardPartialPath 'Forward partial restored manifest') `
            $forwardPartialIdentity `
            'The forward partial mapping did not restore the prior identity.'
        Assert-NoManifestTransactionFiles $forwardPartialPath `
            'The forward partial mapping retained a transaction file.'

        $postRacePath = Join-Path $closureRoot 'post-promotion-race.json'
        Copy-Item -LiteralPath $manifestPath -Destination $postRacePath
        $postRaceCaught = $null
        try {
            Invoke-Vkd3dComponentClosureUpdaterInternal `
                -Vkd3dCheckout $checkout `
                -ManifestPath $postRacePath `
                -TestFault postpromotion-destination-race | Out-Null
        }
        catch { $postRaceCaught = $_.Exception }
        Assert-True ($postRaceCaught.Message.StartsWith(
            'vkd3d-shader updater and cleanup both failed.',
            [StringComparison]::Ordinal
        )) 'The post-promotion race did not preserve its raced destination.'
        Assert-True ($postRaceCaught.ToString() -match
            'Promoted component manifest drifted and was rolled back') `
            'The post-promotion race masked its primary failure.'
        Assert-Equal (Get-FileHash -LiteralPath $postRacePath `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The post-promotion race did not restore the original manifest.'
        $postRaceLeaves = @(Get-ManifestTransactionFiles $postRacePath)
        Assert-Equal $postRaceLeaves.Count 1 `
            'The post-promotion race did not preserve one discard.'
        Assert-True ([IO.Path]::GetFileName($postRaceLeaves[0]).Contains(
            '.retvrn99-discard-',
            [StringComparison]::Ordinal
        )) 'The post-promotion race preserved the wrong transaction leaf.'
        Assert-Equal ([IO.File]::ReadAllText($postRaceLeaves[0])) "{}`n" `
            'The preserved raced destination bytes changed.'

        $rollbackPartialPath = Join-Path $closureRoot 'rollback-partial.json'
        Copy-Item -LiteralPath $manifestPath -Destination $rollbackPartialPath
        $rollbackPartialIdentity = Get-TestStableFileIdentity `
            $rollbackPartialPath 'Rollback partial initial manifest'
        $rollbackPartialCaught = $null
        try {
            Invoke-Vkd3dComponentClosureUpdaterInternal `
                -Vkd3dCheckout $checkout `
                -ManifestPath $rollbackPartialPath `
                -TestFault rollback-replace-partial | Out-Null
        }
        catch { $rollbackPartialCaught = $_.Exception }
        Assert-True ($rollbackPartialCaught -is [AggregateException]) `
            'The rollback partial mapping did not aggregate its failures.'
        Assert-True ($rollbackPartialCaught.Message.StartsWith(
            'vkd3d-shader updater and cleanup both failed.',
            [StringComparison]::Ordinal
        )) 'The rollback partial mapping did not report preserved state.'
        $rollbackPartialText = $rollbackPartialCaught.ToString()
        Assert-True ($rollbackPartialText -match
            'Promoted component manifest drifted and was rolled back') `
            'The rollback partial mapping masked the promotion failure.'
        Assert-True ($rollbackPartialText -match
            'Injected rollback ReplaceFile partial-state failure') `
            'The rollback partial mapping masked the replace failure.'
        Assert-True ($rollbackPartialText.IndexOf(
            $checkout,
            [StringComparison]::OrdinalIgnoreCase
        ) -lt 0) 'The rollback partial mapping exposed its private checkout.'
        Assert-Equal (Get-FileHash -LiteralPath $rollbackPartialPath `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The rollback partial mapping did not restore the prior bytes.'
        Assert-Equal (Get-TestStableFileIdentity `
            $rollbackPartialPath 'Rollback partial restored manifest') `
            $rollbackPartialIdentity `
            'The rollback partial mapping did not restore the prior identity.'
        $rollbackPartialLeaves = @(
            Get-ManifestTransactionFiles $rollbackPartialPath
        )
        Assert-Equal $rollbackPartialLeaves.Count 1 `
            'The rollback partial mapping did not preserve one discard.'
        Assert-True ([IO.Path]::GetFileName(
            $rollbackPartialLeaves[0]
        ).Contains(
            '.retvrn99-discard-',
            [StringComparison]::Ordinal
        )) 'The rollback partial mapping preserved the wrong transaction leaf.'
        Assert-Equal ([IO.File]::ReadAllText(
            $rollbackPartialLeaves[0]
        )) "{}`n" 'The rollback partial discard bytes changed.'

        $backupRacePath = Join-Path $closureRoot 'backup-race.json'
        Copy-Item -LiteralPath $manifestPath -Destination $backupRacePath
        $backupRaceCaught = $null
        try {
            Invoke-Vkd3dComponentClosureUpdaterInternal `
                -Vkd3dCheckout $checkout `
                -ManifestPath $backupRacePath `
                -TestFault backup-replace-exact | Out-Null
        }
        catch { $backupRaceCaught = $_.Exception }
        Assert-True ($backupRaceCaught.Message.StartsWith(
            'vkd3d-shader updater and cleanup both failed.',
            [StringComparison]::Ordinal
        )) 'The replaced backup did not fail closed.'
        Assert-True ($backupRaceCaught.ToString() -match
            'backup ownership changed after promotion') `
            'The replaced backup masked its primary failure.'
        Assert-Equal (Get-FileHash -LiteralPath $backupRacePath `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The replaced backup changed the promoted manifest bytes.'
        $backupRaceLeaves = @(Get-ManifestTransactionFiles $backupRacePath)
        Assert-Equal $backupRaceLeaves.Count 1 `
            'The replaced backup did not preserve one raced leaf.'
        Assert-True ([IO.Path]::GetFileName($backupRaceLeaves[0]).Contains(
            '.retvrn99-backup-',
            [StringComparison]::Ordinal
        )) 'The replaced backup preserved the wrong transaction leaf.'
        Assert-Equal (Get-FileHash -LiteralPath $backupRaceLeaves[0] `
            -Algorithm SHA256).Hash.ToLowerInvariant() $manifestHash `
            'The preserved replacement backup bytes changed.'

        Write-TestLock $testLock $candidatePath $sourceDirectory
        $verifyOutput = @(& $verifyScript -SourceRoot $sourceRoot `
            -LockFile $testLock -SourceName vkd3d-shader 2>&1)
        Assert-Equal ($verifyOutput -join [Environment]::NewLine) `
            'Verified 1 ready Windows 98 component source closures.' `
            'The source-bound vkd3d closure did not verify cleanly.'
    }
    finally {
        foreach ($name in $gitEnvironmentNames) {
            Remove-Item -LiteralPath ('Env:' + $name) `
                -ErrorAction SilentlyContinue
            if ($savedGitEnvironment[$name].Present) {
                Set-Item -LiteralPath ('Env:' + $name) `
                    -Value $savedGitEnvironment[$name].Value
            }
        }
    }

    $mutation = Get-Content -Raw -LiteralPath $candidatePath | ConvertFrom-Json
    $mutatedHlsl = @($mutation.files | Where-Object {
        $_.relative_path -ceq 'libs/vkd3d-shader/hlsl.h'
    })[0]
    $mitId = @($mutatedHlsl.license_evidence_ids | Where-Object {
        $evidenceById[$_].observed_license_expression -ceq 'MIT'
    })[0]
    $mutatedHlsl.license_evidence_ids = @(
        $mutatedHlsl.license_evidence_ids | Where-Object { $_ -cne $mitId }
    )
    $mutation.license_evidence = @(
        $mutation.license_evidence | Where-Object { $_.id -cne $mitId }
    )
    Write-JsonFile $candidatePath $mutation
    Write-TestLock $testLock $candidatePath $sourceDirectory
    Assert-Throws {
        & $verifyScript -SourceRoot $sourceRoot -LockFile $testLock `
            -SourceName vkd3d-shader 2>$null
    } 'declared license does not match all bound evidence'

    Copy-Item -LiteralPath $manifestPath -Destination $candidatePath -Force
    $mutation = Get-Content -Raw -LiteralPath $candidatePath | ConvertFrom-Json
    $mutatedHlsl = @($mutation.files | Where-Object {
        $_.relative_path -ceq 'libs/vkd3d-shader/hlsl.h'
    })[0]
    $mutatedHlsl.selected_license_expression = 'LGPL-2.1-or-later'
    Write-JsonFile $candidatePath $mutation
    Write-TestLock $testLock $candidatePath $sourceDirectory
    Assert-Throws {
        & $verifyScript -SourceRoot $sourceRoot -LockFile $testLock `
            -SourceName vkd3d-shader 2>$null
    } 'invalid structural license selection'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Output 'All vkd3d-shader component-closure manifest, mutation, idempotence, and source-bound tests passed.'

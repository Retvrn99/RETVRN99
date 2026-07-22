# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LfSourceRoot,
    [Parameter(Mandatory = $true)][string]$CrlfSourceRoot,
    [Parameter(Mandatory = $true)][string]$MesaCanonicalSourceRoot,
    [Parameter(Mandatory = $true)][string]$GitExe,
    [Parameter(Mandatory = $true)][string]$FlexExe,
    [Parameter(Mandatory = $true)][string]$BisonExe,
    [Parameter(Mandatory = $true)][string]$BisonDataRoot,
    [Parameter(Mandatory = $true)][string]$M4Exe,
    [Parameter(Mandatory = $true)][string]$WidlExe,
    [Parameter(Mandatory = $true)][string]$PerlExe,
    [Parameter(Mandatory = $true)][string]$PerlLibraryRoot,
    [Parameter(Mandatory = $true)][string]$GccExe,
    [Parameter(Mandatory = $true)][string]$GccToolRoot,
    [Parameter(Mandatory = $true)][string]$ObjdumpExe,
    [Parameter(Mandatory = $true)][string]$ProofRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'vkd3d-shader-compiler-evidence.ps1')
. (Join-Path $PSScriptRoot 'vkd3d-shader-source-root.ps1')
. (Join-Path $PSScriptRoot 'vkd3d-shader-generated-license.ps1')
. (Join-Path $PSScriptRoot 'mesa-object-proof.ps1')

$script:ExpectedVkd3dManifestSha256 = `
    '459cab81112ce075532fdee5e4f4b55f38fa03798506a28ecddd1f23ba42d03f'
$script:ExpectedMesaManifestSha256 = `
    '11020fe9315d80f3ebb14f50266bd50e9f2f2e982c9464c8b0d3d42556fd4f2a'
$script:ExpectedToolchainLockSha256 = `
    '0e38b6d9098200f0572ac0c9a6b38e2b0b2e563309cd8493c4629a661364f533'
$script:Vkd3dCommit = '1b0924d12c18df03912a8876ed17fd017ce9308e'
$script:MesaCommit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$script:Vkd3dRepository = 'https://gitlab.winehq.org/wine/vkd3d.git'
$script:StrictOutputUtf8 = [Text.UTF8Encoding]::new($false, $true)
$script:OutputUtf8 = [Text.UTF8Encoding]::new($false)

function Get-FullEvidencePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is invalid.' }
    return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
}

function Test-EvidencePathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $full = Get-FullEvidencePath $Path
    $base = Get-FullEvidencePath $Root
    return $full.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith(
            $base + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )
}

function Assert-EvidenceDistinctPaths {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in $Paths) {
        if (-not $seen.Add((Get-FullEvidencePath $path))) {
            throw 'Evidence roots and outputs must be pairwise distinct.'
        }
    }
}

function Assert-EvidenceNoReparseAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-Vkd3dEvidenceNoReparseAncestor $Path $Name
}

function Get-EvidenceForwardPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FullEvidencePath $Path).Replace('\', '/')
}

function Join-EvidenceRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    Assert-Vkd3dEvidenceRelativePath $RelativePath 'contained path'
    $full = Get-FullEvidencePath (Join-Path $Root $RelativePath.Replace('/', '\'))
    if (-not (Test-EvidencePathInside $full $Root)) {
        throw "Relative path '$RelativePath' escaped its root."
    }
    return $full
}

function Test-EvidenceStringArrayEqual {
    param([object[]]$First, [object[]]$Second)

    if ($First.Count -ne $Second.Count) { return $false }
    for ($index = 0; $index -lt $First.Count; $index++) {
        if ([string]$First[$index] -cne [string]$Second[$index]) { return $false }
    }
    return $true
}

function Get-EvidenceGitBlobSha1 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    [byte[]]$header = [Text.Encoding]::ASCII.GetBytes(
        'blob ' + $Bytes.Length.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ) + [char]0
    )
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA1
    )
    try {
        $hash.AppendData($header)
        $hash.AppendData($Bytes)
        return ([BitConverter]::ToString($hash.GetHashAndReset()) `
            -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function Get-EvidenceStrictLines {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $text = ConvertFrom-Vkd3dEvidenceUtf8 $Bytes $Name
    $text = $text.Replace("`r`n", "`n")
    if ($text.Contains("`r")) { throw "$Name contains a lone CR." }
    $text = $text.TrimEnd([char[]]"`n")
    if ($text.Length -eq 0) { return @() }
    return @($text.Split([char]10))
}

function Get-EvidenceLockedRow {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $matches = @($Rows | Where-Object { [string]$_.id -ceq $Id })
    if ($matches.Count -ne 1) { throw "$Name has no unique '$Id' row." }
    return $matches[0]
}

function Get-EvidenceRootFromLockedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Row,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $full = Get-FullEvidencePath $Path
    [void](Get-Vkd3dEvidenceFileIdentity $full $Name)
    $suffix = ([string]$Row.relative_path).Replace('/', '\')
    if (-not $full.EndsWith(
            [IO.Path]::DirectorySeparatorChar + $suffix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name does not have its exact locked relative path."
    }
    $root = $full.Substring(
        0,
        $full.Length - $suffix.Length - 1
    ).TrimEnd([char[]]'\/')
    Assert-EvidenceNoReparseAncestor $full $Name
    Assert-Vkd3dEvidenceDirectory $root "$Name root"
    return $root
}

function Assert-EvidenceLockedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Row
    )

    $path = Join-EvidenceRelativePath $Root ([string]$Row.relative_path)
    $identity = Get-Vkd3dEvidenceFileIdentity $path "locked file '$($Row.id)'"
    if ([UInt64]$identity.bytes -ne [UInt64]$Row.bytes -or
        [string]$identity.sha256 -cne [string]$Row.sha256) {
        throw "Locked file '$($Row.id)' identity differs."
    }
}

function Invoke-EvidenceGit {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Temp,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ref]$ChildCount,
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$GitBin
    )

    $safe = 'safe.directory=' + (Get-EvidenceForwardPath $Checkout)
    [string[]]$allArguments = @('-c', $safe, '-C', $Checkout) + $Arguments
    $result = Invoke-Vkd3dEvidenceProcess -File $GitPath `
        -Arguments $allArguments -WorkingDirectory $Checkout `
        -PathDirectories @($GitBin) -PrivateTemp $Temp -Name $Name `
        -ChildCount $ChildCount -Environment @{
            GIT_CONFIG_NOSYSTEM = '1'
            GIT_CONFIG_GLOBAL = 'NUL'
            GIT_OPTIONAL_LOCKS = '0'
            GIT_TERMINAL_PROMPT = '0'
        }
    if ($result.stderr.Length -ne 0) { throw "$Name wrote standard error." }
    return $result
}

function Write-EvidenceBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $path = Join-EvidenceRelativePath $Root $RelativePath
    $parent = [IO.Path]::GetDirectoryName($path)
    [void][IO.Directory]::CreateDirectory($parent)
    if ([IO.File]::Exists($path)) { throw "Output '$RelativePath' already exists." }
    $stream = [IO.File]::Open(
        $path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    $identity = Get-Vkd3dEvidenceFileIdentity $path "output '$RelativePath'"
    if ([UInt64]$identity.bytes -ne [UInt64]$Bytes.Length -or
        [string]$identity.sha256 -cne (Get-Vkd3dEvidenceSha256 $Bytes)) {
        throw "Output '$RelativePath' changed while written."
    }
    return $path
}

function Set-EvidenceCanonicalBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $path = Join-EvidenceRelativePath $Root $RelativePath
    [void](Get-Vkd3dEvidenceFileIdentity $path `
        "raw output '$RelativePath'")
    $temporary = $path + '.retvrn99-normalized'
    if ([IO.File]::Exists($temporary)) {
        throw "Normalization output '$RelativePath' already exists."
    }
    try {
        $stream = [IO.File]::Open(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        $identity = Get-Vkd3dEvidenceFileIdentity $temporary `
            "normalized output '$RelativePath'"
        if ([UInt64]$identity.bytes -ne [UInt64]$Bytes.Length -or
            [string]$identity.sha256 -cne (Get-Vkd3dEvidenceSha256 $Bytes)) {
            throw "Normalized output '$RelativePath' changed while written."
        }
        [IO.File]::Move($temporary, $path, $true)
        $final = Get-Vkd3dEvidenceFileIdentity $path `
            "canonical output '$RelativePath'"
        if ([UInt64]$final.bytes -ne [UInt64]$identity.bytes -or
            [string]$final.sha256 -cne [string]$identity.sha256) {
            throw "Canonical output '$RelativePath' changed after promotion."
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Expand-EvidenceRecipeArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Recipe,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Values,
        [switch]$AllowLogicalRoots
    )

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($templateValue in @($Recipe.arguments)) {
        $value = [string]$templateValue
        foreach ($key in $Values.Keys) {
            $value = $value.Replace('{' + [string]$key + '}', [string]$Values[$key])
        }
        if (-not $AllowLogicalRoots -and $value -match '\{[a-z_]+\}') {
            throw "Recipe '$($Recipe.id)' has an unresolved placeholder."
        }
        $arguments.Add($value)
    }
    return @($arguments)
}

function Get-EvidenceStreamRecord {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return [pscustomobject][ordered]@{
        bytes = [UInt64]$Bytes.Length
        sha256 = Get-Vkd3dEvidenceSha256 $Bytes
    }
}

function Assert-EvidenceRowsEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$First,
        [Parameter(Mandatory = $true)][object[]]$Second,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($First.Count -ne $Second.Count) { throw "$Name row counts differ." }
    for ($index = 0; $index -lt $First.Count; $index++) {
        foreach ($property in @('relative_path', 'bytes', 'sha256')) {
            if ($First[$index].$property -cne $Second[$index].$property) {
                throw "$Name differs at row $($index + 1)."
            }
        }
    }
}

function Assert-EvidenceDependencyRowsEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$First,
        [Parameter(Mandatory = $true)][object[]]$Second,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($First.Count -ne $Second.Count) { throw "$Name row counts differ." }
    for ($index = 0; $index -lt $First.Count; $index++) {
        foreach ($property in @(
            'relative_path', 'occurrence_count', 'bytes', 'sha256'
        )) {
            if ($First[$index].$property -cne $Second[$index].$property) {
                throw "$Name differs at row $($index + 1)."
            }
        }
    }
}

function Get-EvidenceSortedRows {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    [object[]]$copy = @($Rows)
    [Array]::Sort($copy, [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.relative_path,
                [string]$right.relative_path
            )
        }
    ))
    return @($copy)
}

function Get-EvidenceOrdinalStrings {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    [string[]]$copy = @($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return @($copy)
}

function Assert-EvidenceNoPrivateText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$PrivateRoots,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-Vkd3dEvidenceNoPrivatePathText $Text $Name

    foreach ($privateRoot in $PrivateRoots) {
        foreach ($spelling in @(
            (Get-FullEvidencePath $privateRoot).Replace('\', '/'),
            (Get-FullEvidencePath $privateRoot).Replace('/', '\')
        )) {
            if ($Text.IndexOf(
                    $spelling, [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                throw "$Name exposes a private absolute path."
            }
        }
    }
}

$repoRoot = Get-FullEvidencePath (Join-Path $PSScriptRoot '..')
$driversRoot = Join-Path $repoRoot 'drivers\win98'
$schemaPath = Join-Path $driversRoot 'vkd3d-shader-compiler-closure.schema.json'
$componentPath = Join-Path $driversRoot 'component-closures\vkd3d-shader.json'
$mesaComponentPath = Join-Path $driversRoot 'component-closures\mesa9x-23.1.x.json'
$toolchainLockPath = Join-Path $driversRoot 'vkd3d-shader-toolchain-lock.json'
$lfCheckout = Get-FullEvidencePath $LfSourceRoot
$crlfCheckout = Get-FullEvidencePath $CrlfSourceRoot
$mesaSource = Get-FullEvidencePath $MesaCanonicalSourceRoot
$proof = Get-FullEvidencePath $ProofRoot
$output = Get-FullEvidencePath $EvidenceOutput
$partialOutput = $output + '.partial'

foreach ($pair in @(
    @($lfCheckout, 'LF source checkout'),
    @($crlfCheckout, 'CRLF source checkout'),
    @($mesaSource, 'Mesa canonical source root')
)) {
    Assert-EvidenceNoReparseAncestor $pair[0] $pair[1]
    Assert-Vkd3dEvidenceDirectory $pair[0] $pair[1]
}
Assert-EvidenceDistinctPaths @(
    $lfCheckout, $crlfCheckout, $mesaSource, $proof, $output, $partialOutput
)
foreach ($path in @($proof, $output, $partialOutput)) {
    if (Test-EvidencePathInside $path $repoRoot) {
        throw 'Proof and evidence outputs must stay outside the repository.'
    }
}
foreach ($root in @($lfCheckout, $crlfCheckout, $mesaSource)) {
    if ((Test-EvidencePathInside $proof $root) -or
        (Test-EvidencePathInside $output $root) -or
        (Test-EvidencePathInside $partialOutput $root)) {
        throw 'Proof and evidence outputs must stay outside every input root.'
    }
}
$proofParent = [IO.Path]::GetDirectoryName($proof)
$outputParent = [IO.Path]::GetDirectoryName($output)
Assert-Vkd3dEvidenceFreshMutationBoundary `
    $outputParent @($output, $partialOutput) 'evidence-output boundary'

$schemaSnapshot = Read-GswStrictJsonFileSnapshot -Path $schemaPath `
    -Name 'vkd3d-shader compiler-closure schema' -MaximumBytes 1048576
$componentSnapshot = Read-GswStrictJsonFileSnapshot -Path $componentPath `
    -Name 'vkd3d-shader component manifest' -MaximumBytes 1048576
$mesaSnapshot = Read-GswStrictJsonFileSnapshot -Path $mesaComponentPath `
    -Name 'Mesa component manifest' -MaximumBytes 2097152
$lockSnapshot = Read-GswStrictJsonFileSnapshot -Path $toolchainLockPath `
    -Name 'vkd3d-shader toolchain lock' -MaximumBytes 1048576
if ($componentSnapshot.Sha256 -cne $script:ExpectedVkd3dManifestSha256 -or
    $mesaSnapshot.Sha256 -cne $script:ExpectedMesaManifestSha256 -or
    $lockSnapshot.Sha256 -cne $script:ExpectedToolchainLockSha256) {
    throw 'A pinned checked-in input binding drifted.'
}
$component = $componentSnapshot.Value
$mesaComponent = $mesaSnapshot.Value
$toolchainLock = $lockSnapshot.Value
if ($component.schema -ne 2 -or $component.status -cne 'ready' -or
    $component.upstream_name -cne 'vkd3d-shader' -or
    $component.owning_commit -cne $script:Vkd3dCommit -or
    @($component.files).Count -ne 40) {
    throw 'vkd3d-shader component manifest is not the exact ready closure.'
}
if ($mesaComponent.schema -ne 2 -or $mesaComponent.status -cne 'ready' -or
    $mesaComponent.owning_commit -cne $script:MesaCommit -or
    @($mesaComponent.files).Count -ne 1687) {
    throw 'Mesa component manifest is not the exact ready closure.'
}
if ($toolchainLock.schema -ne 1 -or $toolchainLock.status -cne 'ready') {
    throw 'vkd3d-shader toolchain lock is not ready.'
}
$toolchainMetadata = @(& (Join-Path $PSScriptRoot `
    'verify-win98-vkd3d-shader-toolchain.ps1') `
    -LockFile $toolchainLockPath -MetadataOnly)
if ($toolchainMetadata.Count -ne 1 -or
    $toolchainMetadata[0].status -cne 'ready' -or
    $toolchainMetadata[0].mode -cne 'metadata-only') {
    throw 'Toolchain metadata verifier did not return ready metadata.'
}

$expectedTrackedUnitGuard = @(
    'libs/vkd3d-shader/checksum.c',
    'libs/vkd3d-shader/d3d_asm.c',
    'libs/vkd3d-shader/d3dbc.c',
    'libs/vkd3d-shader/dxbc.c',
    'libs/vkd3d-shader/dxil.c',
    'libs/vkd3d-shader/fx.c',
    'libs/vkd3d-shader/glsl.c',
    'libs/vkd3d-shader/hlsl.c',
    'libs/vkd3d-shader/hlsl_codegen.c',
    'libs/vkd3d-shader/hlsl_constant_ops.c',
    'libs/vkd3d-shader/ir.c',
    'libs/vkd3d-shader/msl.c',
    'libs/vkd3d-shader/spirv.c',
    'libs/vkd3d-shader/tpf.c',
    'libs/vkd3d-shader/vkd3d_shader_main.c'
)
$manifestTrackedRows = @($component.files | Where-Object {
    @($_.roles) -ccontains 'source-unit'
})
$dependencyRows = @($component.files | Where-Object {
    @($_.roles) -ccontains 'compiler-dependency'
})
$licenseIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($license in @($component.license_evidence)) {
    if (-not $licenseIds.Add([string]$license.id)) {
        throw 'Component manifest repeats a license-evidence id.'
    }
}
foreach ($file in @($component.files)) {
    if ([string]::IsNullOrWhiteSpace([string]$file.selected_license_expression) -or
        [string]$file.selected_license_expression -match
            'UNKNOWN|NOASSERTION|LicenseRef-Unknown') {
        throw "Unknown licensing for '$($file.relative_path)'."
    }
    foreach ($id in @($file.license_evidence_ids)) {
        if (-not $licenseIds.Contains([string]$id)) {
            throw "Missing license evidence '$id'."
        }
    }
}

$fileRows = @($toolchainLock.files)
$gitRow = Get-EvidenceLockedRow $fileRows 'git-core' 'toolchain lock'
$flexRow = Get-EvidenceLockedRow $fileRows 'msys-flex' 'toolchain lock'
$bisonRow = Get-EvidenceLockedRow $fileRows 'msys-bison' 'toolchain lock'
$m4Row = Get-EvidenceLockedRow $fileRows 'msys-m4' 'toolchain lock'
$widlRow = Get-EvidenceLockedRow $fileRows 'ucrt-widl' 'toolchain lock'
$perlRow = Get-EvidenceLockedRow $fileRows 'git-perl' 'toolchain lock'
$gccRow = Get-EvidenceLockedRow $fileRows 'ucrt-gcc' 'toolchain lock'
$objdumpRow = Get-EvidenceLockedRow $fileRows 'ucrt-objdump' 'toolchain lock'
$msysRoot = Get-EvidenceRootFromLockedFile $FlexExe $flexRow 'Flex executable'
$ucrtRoot = Get-EvidenceRootFromLockedFile $GccExe $gccRow 'GCC executable'
$gitRoot = Get-EvidenceRootFromLockedFile $GitExe $gitRow 'Git executable'
foreach ($binding in @(
    @($BisonExe, $bisonRow, $msysRoot, 'Bison executable'),
    @($M4Exe, $m4Row, $msysRoot, 'M4 executable'),
    @($WidlExe, $widlRow, $ucrtRoot, 'WIDL executable'),
    @($PerlExe, $perlRow, $gitRoot, 'Perl executable'),
    @($ObjdumpExe, $objdumpRow, $ucrtRoot, 'objdump executable')
)) {
    $derived = Get-EvidenceRootFromLockedFile $binding[0] $binding[1] $binding[3]
    if (-not $derived.Equals($binding[2], [StringComparison]::OrdinalIgnoreCase)) {
        throw "$($binding[3]) resolves under a different locked root."
    }
}
$rootMap = @{ msys = $msysRoot; ucrt64 = $ucrtRoot; git = $gitRoot }
foreach ($file in $fileRows) {
    if (-not $rootMap.ContainsKey([string]$file.root)) {
        throw "Locked live file '$($file.id)' has an unavailable root."
    }
    Assert-EvidenceLockedFile $rootMap[[string]$file.root] $file
}
$bisonTree = Get-EvidenceLockedRow @($toolchainLock.trees) `
    'bison-data' 'toolchain lock'
$gccTree = Get-EvidenceLockedRow @($toolchainLock.trees) `
    'gcc-internal-headers' 'toolchain lock'
$expectedBisonData = Join-EvidenceRelativePath $msysRoot `
    ([string]$bisonTree.relative_path)
$expectedGccTool = Join-EvidenceRelativePath $ucrtRoot `
    ([string]$gccTree.relative_path)
if (-not (Get-FullEvidencePath $BisonDataRoot).Equals(
        $expectedBisonData, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Get-FullEvidencePath $GccToolRoot).Equals(
        $expectedGccTool, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'An explicit tool data root differs from its locked location.'
}
$perlUsr = Join-EvidenceRelativePath $gitRoot 'usr'
if (-not (Get-FullEvidencePath $PerlLibraryRoot).Equals(
        $perlUsr, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'PerlLibraryRoot must be the exact locked Git usr directory.'
}
$bisonTreeObserved = Get-Vkd3dEvidenceTreeIdentity $expectedBisonData `
    $bisonTree.descriptor 'Bison data tree'
$gccTreeObserved = Get-Vkd3dEvidenceTreeIdentity $expectedGccTool `
    $gccTree.descriptor 'GCC internal-header tree'

if ($toolchainLock.process_limits.maximum_top_level_processes -ne 1 -or
    $toolchainLock.process_limits.maximum_process_tree_width -ne 5 -or
    $toolchainLock.process_limits.timeout_seconds -ne 30 -or
    $toolchainLock.process_limits.termination_grace_seconds -ne 5 -or
    $toolchainLock.process_limits.maximum_stdout_bytes -ne 1048576 -or
    $toolchainLock.process_limits.maximum_stderr_bytes -ne 1048576 -or
    -not $toolchainLock.process_limits.no_shell -or
    -not $toolchainLock.process_limits.terminate_process_tree) {
    throw 'Toolchain process bounds drifted.'
}

$ownerToken = $null
$proofRootHandle = $null
$ownerMarkerHandle = $null
$partialCreated = $false
$outputWritten = $false
$finalCreated = $false
$partialFileIdentity = $null
$partialExpectedBytes = $null
$partialExpectedSha256 = $null
$primaryFailure = $null
$cleanupPrivateRoots = @(
    $repoRoot, $proof, $lfCheckout, $crlfCheckout, $mesaSource,
    $msysRoot, $ucrtRoot, $gitRoot, $proofParent, $outputParent
)
$childCount = 0
$sourceInternals = [Collections.Generic.List[object]]::new()
$sourceEvidence = [Collections.Generic.List[object]]::new()
$generatedRuns = [Collections.Generic.List[object]]::new()
$commandEvidence = [Collections.Generic.List[object]]::new()
$probeEvidence = [Collections.Generic.List[object]]::new()
$globalDependencyRows = @{}
$objectRowsByRun = @{ lf = @(); crlf = @() }

try {
    $proofOwnership = New-Vkd3dEvidenceOwnedDirectory `
        $proof 'compiler evidence proof root'
    $ownerToken = $proofOwnership.OwnerToken
    $proofRootHandle = $proofOwnership.RootHandle
    $ownerMarkerHandle = $proofOwnership.OwnerMarkerHandle
    $privateTemp = Join-Path $proof 'temp'
    [void][IO.Directory]::CreateDirectory($privateTemp)

    $toolPaths = @{
        'git-core' = Get-FullEvidencePath $GitExe
        'msys-flex' = Get-FullEvidencePath $FlexExe
        'msys-bison' = Get-FullEvidencePath $BisonExe
        'msys-m4' = Get-FullEvidencePath $M4Exe
        'ucrt-widl' = Get-FullEvidencePath $WidlExe
        'git-perl' = Get-FullEvidencePath $PerlExe
        'ucrt-gcc' = Get-FullEvidencePath $GccExe
        'ucrt-objdump' = Get-FullEvidencePath $ObjdumpExe
    }
    foreach ($probe in @($toolchainLock.tool_probes)) {
        if (-not $toolPaths.ContainsKey([string]$probe.file_id)) {
            $probePathRow = Get-EvidenceLockedRow $fileRows `
                ([string]$probe.file_id) 'toolchain lock'
            $probePath = Join-EvidenceRelativePath `
                $rootMap[[string]$probePathRow.root] `
                ([string]$probePathRow.relative_path)
        }
        else { $probePath = $toolPaths[[string]$probe.file_id] }
        $probeBin = [IO.Path]::GetDirectoryName($probePath)
        $probeResult = Invoke-Vkd3dEvidenceProcess -File $probePath `
            -Arguments @($probe.arguments) -WorkingDirectory $proof `
            -PathDirectories @($probeBin) -PrivateTemp $privateTemp `
            -Name "tool probe '$($probe.id)'" -ChildCount ([ref]$childCount) `
            -TimeoutSeconds ([Math]::Ceiling([int]$probe.timeout_ms / 1000)) `
            -MaximumOutputBytes ([int]$probe.maximum_output_bytes)
        $streamSelection = Select-Vkd3dEvidenceProcessStreams $probeResult `
            ([string]$probe.expected_stream)
        [byte[]]$selected = $streamSelection.selected
        [byte[]]$other = $streamSelection.other
        if ($other.Length -ne 0) { throw "Tool probe '$($probe.id)' used both streams." }
        $observedLines = @(Get-EvidenceStrictLines $selected `
            "tool probe '$($probe.id)'")
        $expectedLines = @($probe.expected_lines)
        if ($observedLines.Count -lt $expectedLines.Count) {
            throw "Tool probe '$($probe.id)' output is incomplete."
        }
        for ($line = 0; $line -lt $expectedLines.Count; $line++) {
            if ($observedLines[$line] -cne $expectedLines[$line]) {
                throw "Tool probe '$($probe.id)' output differs."
            }
        }
        $probeEvidence.Add([pscustomobject][ordered]@{
            id = [string]$probe.id
            file_id = [string]$probe.file_id
            expected_lines = @($expectedLines)
            observed_lines = @($observedLines)
            stdout_bytes = [UInt64]$probeResult.stdout.Length
            stdout_sha256 = Get-Vkd3dEvidenceSha256 $probeResult.stdout
        })
    }

    $gitBin = [IO.Path]::GetDirectoryName((Get-FullEvidencePath $GitExe))
    foreach ($checkout in @(
        [pscustomobject]@{ id = 'lf'; mode = 'lf'; root = $lfCheckout },
        [pscustomobject]@{ id = 'crlf'; mode = 'crlf'; root = $crlfCheckout }
    )) {
        $topResult = Invoke-EvidenceGit $checkout.root `
            @('rev-parse', '--show-toplevel') $privateTemp `
            "$($checkout.id) checkout root" ([ref]$childCount) $GitExe $gitBin
        $top = @(Get-EvidenceStrictLines $topResult.stdout `
            "$($checkout.id) checkout root")
        if ($top.Count -ne 1 -or
            -not (Get-FullEvidencePath $top[0]).Equals(
                $checkout.root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$($checkout.id) checkout is not the requested Git root."
        }
        $headResult = Invoke-EvidenceGit $checkout.root @('rev-parse', 'HEAD') `
            $privateTemp "$($checkout.id) checkout HEAD" ([ref]$childCount) `
            $GitExe $gitBin
        $headLines = @(Get-EvidenceStrictLines $headResult.stdout `
            "$($checkout.id) checkout HEAD")
        if ($headLines.Count -ne 1 -or $headLines[0] -cne $script:Vkd3dCommit) {
            throw "$($checkout.id) checkout is not at the pinned commit."
        }
        $branchResult = Invoke-EvidenceGit $checkout.root `
            @('rev-parse', '--abbrev-ref', 'HEAD') $privateTemp `
            "$($checkout.id) detached HEAD" ([ref]$childCount) $GitExe $gitBin
        $branchLines = @(Get-EvidenceStrictLines $branchResult.stdout `
            "$($checkout.id) detached HEAD")
        if ($branchLines.Count -ne 1 -or $branchLines[0] -cne 'HEAD') {
            throw "$($checkout.id) checkout must have a detached HEAD."
        }
        $statusResult = Invoke-EvidenceGit $checkout.root `
            @('status', '--porcelain=v1', '-z', '--untracked-files=all') `
            $privateTemp "$($checkout.id) checkout status" `
            ([ref]$childCount) $GitExe $gitBin
        if ($statusResult.stdout.Length -ne 0) {
            throw "$($checkout.id) checkout is not clean."
        }
        $originResult = Invoke-EvidenceGit $checkout.root `
            @('config', '--get', 'remote.origin.url') $privateTemp `
            "$($checkout.id) checkout origin" ([ref]$childCount) $GitExe $gitBin
        $originLines = @(Get-EvidenceStrictLines $originResult.stdout `
            "$($checkout.id) checkout origin")
        if ($originLines.Count -ne 1 -or
            $originLines[0] -cne $script:Vkd3dRepository) {
            throw "$($checkout.id) checkout origin differs from the pin."
        }
    }

    [UInt64]$sourceBytes = 0
    $ordinal = 0
    foreach ($file in @($component.files)) {
        $ordinal++
        $relative = [string]$file.relative_path
        $blobResult = Invoke-EvidenceGit $lfCheckout `
            @('cat-file', 'blob', ($script:Vkd3dCommit + ':' + $relative)) `
            $privateTemp "Git blob '$relative'" ([ref]$childCount) $GitExe $gitBin
        [byte[]]$gitBytes = $blobResult.stdout
        if ((Get-EvidenceGitBlobSha1 $gitBytes) -cne [string]$file.git_blob -or
            [UInt64]$gitBytes.Length -ne [UInt64]$file.bytes -or
            (Get-Vkd3dEvidenceSha256 $gitBytes) -cne [string]$file.sha256) {
            throw "Git bytes for '$relative' differ from the component manifest."
        }
        [byte[]]$lfBytes = Read-Vkd3dEvidenceFileBytes `
            (Join-EvidenceRelativePath $lfCheckout $relative) `
            "LF checkout '$relative'"
        [byte[]]$crlfBytes = Read-Vkd3dEvidenceFileBytes `
            (Join-EvidenceRelativePath $crlfCheckout $relative) `
            "CRLF checkout '$relative'"
        $lfObservation = ConvertTo-Vkd3dShaderCanonicalObservation `
            $lfBytes $gitBytes 'lf' $relative
        $crlfObservation = ConvertTo-Vkd3dShaderCanonicalObservation `
            $crlfBytes $gitBytes 'crlf' $relative
        $pair = Resolve-Vkd3dShaderCanonicalPair $lfObservation $crlfObservation
        $sourceBytes += [UInt64]$pair.bytes
        $sourceInternals.Add([pscustomobject]@{
            RelativePath = $relative
            LfBytes = [byte[]]$lfObservation.CanonicalBytes
            CrlfBytes = [byte[]]$crlfObservation.CanonicalBytes
        })
        $sourceEvidence.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]$ordinal
            relative_path = $relative
            git_blob = [string]$file.git_blob
            bytes = [UInt64]$pair.bytes
            lf_count = [UInt64]$pair.lf_count
            crlf_count = [UInt64]$pair.crlf_count
            sha256 = [string]$pair.sha256
            declared_license_expression = [string]$file.declared_license_expression
            selected_license_expression = [string]$file.selected_license_expression
            license_evidence_ids = @($file.license_evidence_ids)
            roles = @($file.roles)
            canonical_pair = $true
        })
    }

    $mesaInputDefinitions = @(
        [pscustomobject]@{
            source = 'mesa-23.1.x/src/compiler/spirv/spirv.h'
            target = 'include/spirv/unified1/spirv.h'
        },
        [pscustomobject]@{
            source = 'mesa-23.1.x/src/compiler/spirv/GLSL.std.450.h'
            target = 'include/spirv/unified1/GLSL.std.450.h'
        }
    )
    $mesaInputs = [Collections.Generic.List[object]]::new()
    $mesaEvidence = [Collections.Generic.List[object]]::new()
    $mesaOrdinal = 0
    foreach ($definition in $mesaInputDefinitions) {
        $mesaOrdinal++
        $matches = @($mesaComponent.files | Where-Object {
            [string]$_.relative_path -ceq [string]$definition.source
        })
        if ($matches.Count -ne 1 -or
            [string]$matches[0].selected_license_expression -cne 'MIT' -or
            @($matches[0].roles) -cnotcontains 'compiler-dependency') {
            throw "Mesa cross-component input '$($definition.source)' is not exact MIT compiler evidence."
        }
        $mesaRow = $matches[0]
        [byte[]]$bytes = Read-Vkd3dEvidenceFileBytes `
            (Join-EvidenceRelativePath $mesaSource ([string]$definition.source)) `
            "Mesa cross-component input '$($definition.source)'"
        if ([UInt64]$bytes.Length -ne [UInt64]$mesaRow.bytes -or
            (Get-Vkd3dEvidenceSha256 $bytes) -cne [string]$mesaRow.sha256 -or
            $bytes -contains [byte]0 -or $bytes -contains [byte]13 -or
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
                $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)) {
            throw "Mesa cross-component input '$($definition.source)' drifted."
        }
        $mesaInputs.Add([pscustomobject]@{
            Target = [string]$definition.target
            Bytes = $bytes
        })
        $mesaEvidence.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]$mesaOrdinal
            source_relative_path = [string]$definition.source
            target_relative_path = [string]$definition.target
            git_blob = [string]$mesaRow.git_blob
            bytes = [UInt64]$mesaRow.bytes
            sha256 = [string]$mesaRow.sha256
            license_expression = 'MIT'
        })
    }

    $recipes = @($toolchainLock.recipes)
    $flexRecipe = Get-EvidenceLockedRow $recipes 'flex-c' 'toolchain lock'
    $bisonRecipe = Get-EvidenceLockedRow $recipes 'bison-c-header' 'toolchain lock'
    $widlRecipe = Get-EvidenceLockedRow $recipes 'widl-header' 'toolchain lock'
    $spirvRecipe = Get-EvidenceLockedRow $recipes 'spirv-header' 'toolchain lock'
    $compileRecipe = Get-EvidenceLockedRow $recipes 'compile-c-object' 'toolchain lock'
    $objdumpRecipe = Get-EvidenceLockedRow $recipes 'validate-object' 'toolchain lock'
    foreach ($binding in @(
        @($flexRecipe, 'msys-flex'),
        @($bisonRecipe, 'msys-bison'),
        @($widlRecipe, 'ucrt-widl'),
        @($spirvRecipe, 'git-perl'),
        @($compileRecipe, 'ucrt-gcc'),
        @($objdumpRecipe, 'ucrt-objdump')
    )) {
        if ([string]$binding[0].tool_file_id -cne [string]$binding[1]) {
            throw "Recipe '$($binding[0].id)' selected a different tool."
        }
    }

    $generatedDefinitions = @(
        [pscustomobject]@{ path = 'libs/vkd3d-shader/hlsl.yy.c'; kind = 'generated-c'; recipe = 'flex-c'; inputs = @('libs/vkd3d-shader/hlsl.l') },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/hlsl.tab.c'; kind = 'generated-c'; recipe = 'bison-c-header'; inputs = @('libs/vkd3d-shader/hlsl.y') },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/hlsl.tab.h'; kind = 'generated-header'; recipe = 'bison-c-header'; inputs = @('libs/vkd3d-shader/hlsl.y') },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/preproc.yy.c'; kind = 'generated-c'; recipe = 'flex-c'; inputs = @('libs/vkd3d-shader/preproc.l') },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/preproc.tab.c'; kind = 'generated-c'; recipe = 'bison-c-header'; inputs = @('libs/vkd3d-shader/preproc.y') },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/preproc.tab.h'; kind = 'generated-header'; recipe = 'bison-c-header'; inputs = @('libs/vkd3d-shader/preproc.y') },
        [pscustomobject]@{ path = 'include/vkd3d_d3dcommon.h'; kind = 'generated-header'; recipe = 'widl-header'; inputs = @('include/vkd3d_d3dcommon.idl', 'include/vkd3d_unknown.idl') },
        [pscustomobject]@{ path = 'include/vkd3d_d3dx9shader.h'; kind = 'generated-header'; recipe = 'widl-header'; inputs = @('include/vkd3d_d3dx9shader.idl', 'include/vkd3d_d3d9types.h') },
        [pscustomobject]@{ path = 'include/private/spirv_grammar.h'; kind = 'generated-header'; recipe = 'spirv-header'; inputs = @('libs/vkd3d-shader/make_spirv', 'include/private/spirv.core.grammar.json') },
        [pscustomobject]@{ path = 'include/config.h'; kind = 'generated-header'; recipe = 'reviewed-config-header'; inputs = @('configure.ac') },
        [pscustomobject]@{ path = 'include/private/vkd3d_version.h'; kind = 'generated-header'; recipe = 'reviewed-version-header'; inputs = @('Makefile.am') }
    )
    if ($generatedDefinitions.Count -ne 11 -or
        @($generatedDefinitions | Where-Object kind -ceq 'generated-c').Count -ne 4) {
        throw 'The exact generated-output inventory is malformed.'
    }
    $expectedWidlNormalization =
        [Collections.Generic.Dictionary[string, object]]::new(
            [StringComparer]::Ordinal
        )
    $expectedWidlNormalization.Add(
        'include/vkd3d_d3dcommon.h',
        [pscustomobject]@{
            raw_bytes = [UInt64]23406
            raw_sha256 = 'fb522341733698aefa4b52c7e1d8860cd9ddd63b533c81f49331afe9d6b55942'
            newline_count = [UInt64]699
            bytes = [UInt64]22707
            sha256 = 'c52dc8d4aa832294220b3684b4b011319523595d038eaa0a1c055a4028112482'
        }
    )
    $expectedWidlNormalization.Add(
        'include/vkd3d_d3dx9shader.h',
        [pscustomobject]@{
            raw_bytes = [UInt64]2017
            raw_sha256 = '7a10933742f289060141d9366943817742f7c8efb6fb33a7ea54208165a55542'
            newline_count = [UInt64]87
            bytes = [UInt64]1930
            sha256 = '574e09c72ad2bb9f3182a38cb32dac70a25753d34f9f3d2454db514864e1c6d0'
        }
    )
    $expectedGeneratorInputLicenses =
        [Collections.Generic.Dictionary[string, string]]::new(
            [StringComparer]::Ordinal
        )
    foreach ($inputLicense in @(
        @('libs/vkd3d-shader/hlsl.l', 'LGPL-2.1-or-later'),
        @('libs/vkd3d-shader/hlsl.y', 'LGPL-2.1-or-later'),
        @('libs/vkd3d-shader/preproc.l', 'LGPL-2.1-or-later'),
        @('libs/vkd3d-shader/preproc.y', 'LGPL-2.1-or-later'),
        @('include/vkd3d_d3dcommon.idl', 'LGPL-2.1-or-later'),
        @('include/vkd3d_unknown.idl', 'LGPL-2.1-or-later'),
        @('include/vkd3d_d3dx9shader.idl', 'LGPL-2.1-or-later'),
        @('include/vkd3d_d3d9types.h', 'LGPL-2.1-or-later'),
        @('libs/vkd3d-shader/make_spirv', 'LGPL-2.1-or-later'),
        @('include/private/spirv.core.grammar.json', 'MIT'),
        @('configure.ac', 'LGPL-2.1-or-later'),
        @('Makefile.am', 'LGPL-2.1-or-later')
    )) {
        $expectedGeneratorInputLicenses.Add(
            [string]$inputLicense[0], [string]$inputLicense[1]
        )
    }
    $generatorInputPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $licensedGeneratorInputPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($definition in $generatedDefinitions) {
        foreach ($generatorInput in @($definition.inputs)) {
            $matches = @($component.files | Where-Object {
                [string]$_.relative_path -ceq [string]$generatorInput
            })
            if ($matches.Count -ne 1) {
                throw "Generated input '$generatorInput' is absent from the component closure."
            }
            $expectedRole = if ($generatorInput -in @('Makefile.am', 'configure.ac')) {
                'build-description'
            }
            else { 'generator-input' }
            if (@($matches[0].roles) -cnotcontains $expectedRole) {
                throw "Generated input '$generatorInput' lacks role '$expectedRole'."
            }
            if (-not $expectedGeneratorInputLicenses.ContainsKey(
                    [string]$generatorInput
                )) {
                throw "Generated input '$generatorInput' lacks an exact license disposition."
            }
            $expectedInputLicense =
                $expectedGeneratorInputLicenses[[string]$generatorInput]
            if ([string]$matches[0].declared_license_expression -cne
                    $expectedInputLicense -or
                [string]$matches[0].selected_license_expression -cne
                    $expectedInputLicense) {
                throw "Generated input '$generatorInput' changed license disposition."
            }
            [void]$licensedGeneratorInputPaths.Add([string]$generatorInput)
            if ($expectedRole -ceq 'generator-input') {
                [void]$generatorInputPaths.Add([string]$generatorInput)
            }
        }
    }
    if ($expectedGeneratorInputLicenses.Count -ne 12 -or
        $licensedGeneratorInputPaths.Count -ne
            $expectedGeneratorInputLicenses.Count) {
        throw 'Generated input license coverage is incomplete.'
    }
    $manifestGeneratorInputs = @($component.files | Where-Object {
        @($_.roles) -ccontains 'generator-input'
    } | ForEach-Object relative_path)
    if (-not (Test-EvidenceStringArrayEqual `
            (Get-EvidenceOrdinalStrings @($generatorInputPaths)) `
            (Get-EvidenceOrdinalStrings $manifestGeneratorInputs))) {
        throw 'Generated recipes do not cover the complete generator-input role set.'
    }
    $generatedRecipeEvidence = [Collections.Generic.List[object]]::new()
    $generatedOrdinal = 0
    foreach ($definition in $generatedDefinitions) {
        $generatedOrdinal++
        $generatedRecipeEvidence.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]$generatedOrdinal
            relative_path = [string]$definition.path
            kind = [string]$definition.kind
            recipe_id = [string]$definition.recipe
            inputs = @($definition.inputs)
        })
    }

    $sourceByPath = @{}
    foreach ($internal in $sourceInternals) {
        if ($sourceByPath.ContainsKey([string]$internal.RelativePath)) {
            throw 'Canonical source inventory repeats a path.'
        }
        $sourceByPath[[string]$internal.RelativePath] = $internal
    }
    $makefileText = ConvertFrom-Vkd3dEvidenceUtf8 `
        $sourceByPath['Makefile.am'].LfBytes 'Makefile.am'
    $makefileSources = @(Get-Vkd3dEvidenceMakefileList $makefileText `
        'libvkd3d_shader_la_SOURCES')
    $makefileTrackedCUnits = @($makefileSources | Where-Object {
        ([string]$_).EndsWith('.c', [StringComparison]::Ordinal)
    })
    $makefileGeneratedSources = @(Get-Vkd3dEvidenceMakefileList `
        $makefileText 'vkd3d_shader_yyfiles')
    $makefileGeneratedCUnits = @($makefileGeneratedSources | Where-Object {
        ([string]$_).EndsWith('.c', [StringComparison]::Ordinal)
    })
    $nodistMatches = [regex]::Matches(
        $makefileText,
        '(?m)^nodist_libvkd3d_shader_la_SOURCES = \$\(vkd3d_shader_yyfiles\)$',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if ($nodistMatches.Count -ne 1) {
        throw 'Makefile.am does not bind the generated compiler units exactly once.'
    }
    $trackedPathSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($path in @($manifestTrackedRows | ForEach-Object relative_path)) {
        if (-not $trackedPathSet.Add([string]$path)) {
            throw 'Tracked compiler-unit inventory repeats a path.'
        }
    }
    $generatedCSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($path in @($generatedDefinitions |
            Where-Object kind -ceq 'generated-c' | ForEach-Object path)) {
        if (-not $generatedCSet.Add([string]$path)) {
            throw 'Generated compiler-unit inventory repeats a path.'
        }
    }
    if (-not (Test-EvidenceStringArrayEqual `
            (Get-EvidenceOrdinalStrings $makefileGeneratedCUnits) `
            (Get-EvidenceOrdinalStrings @($generatedCSet)))) {
        throw 'Makefile-generated C inventory differs from reviewed generator output.'
    }
    $unitOrder = [Collections.Generic.List[object]]::new()
    foreach ($path in @($makefileTrackedCUnits + $makefileGeneratedCUnits)) {
        if ($trackedPathSet.Contains([string]$path)) {
            $kind = 'tracked'
        }
        elseif ($generatedCSet.Contains([string]$path)) {
            $kind = 'generated'
        }
        else {
            throw "Makefile compile unit '$path' is outside the reviewed closure."
        }
        $unitOrder.Add(@($kind, [string]$path))
    }
    $derivedTrackedUnits = @($unitOrder | Where-Object { $_[0] -ceq 'tracked' })
    $derivedGeneratedUnits = @($unitOrder | Where-Object { $_[0] -ceq 'generated' })
    if ($unitOrder.Count -ne 19 -or $derivedTrackedUnits.Count -ne 15 -or
        $derivedGeneratedUnits.Count -ne 4 -or
        -not (Test-EvidenceStringArrayEqual `
            (Get-EvidenceOrdinalStrings @($derivedTrackedUnits | ForEach-Object { $_[1] })) `
            (Get-EvidenceOrdinalStrings @($manifestTrackedRows | ForEach-Object relative_path))) -or
        -not (Test-EvidenceStringArrayEqual `
            (Get-EvidenceOrdinalStrings @($derivedGeneratedUnits | ForEach-Object { $_[1] })) `
            (Get-EvidenceOrdinalStrings @($generatedCSet)))) {
        throw 'Makefile-derived compiler inventory does not close over reviewed units.'
    }
    if (-not (Test-EvidenceStringArrayEqual `
            (Get-EvidenceOrdinalStrings @($derivedTrackedUnits | ForEach-Object { $_[1] })) `
            (Get-EvidenceOrdinalStrings $expectedTrackedUnitGuard))) {
        throw 'The pinned tracked-unit drift guard changed.'
    }

    $runContexts = [Collections.Generic.List[object]]::new()
    foreach ($runDefinition in @(
        [pscustomobject]@{ id = 'lf'; mode = 'lf' },
        [pscustomobject]@{ id = 'crlf'; mode = 'crlf' }
    )) {
        $runRoot = Join-Path $proof ('run-' + $runDefinition.id)
        $sourceRoot = Join-Path $runRoot 'source'
        $generatedRoot = Join-Path $runRoot 'generated'
        $runTemp = Join-Path $runRoot 'temp'
        $objectRoot = Join-Path $runRoot 'obj'
        $depRoot = Join-Path $runRoot 'dep'
        foreach ($directory in @(
            $runRoot, $sourceRoot, $generatedRoot, $runTemp, $objectRoot, $depRoot
        )) { [void][IO.Directory]::CreateDirectory($directory) }
        foreach ($internal in $sourceInternals) {
            [byte[]]$bytes = [byte[]]::new(0)
            if ($runDefinition.id -ceq 'lf') {
                $bytes = $internal.LfBytes
            }
            else { $bytes = $internal.CrlfBytes }
            [void](Write-EvidenceBytes $sourceRoot $internal.RelativePath $bytes)
        }
        foreach ($mesaInput in $mesaInputs) {
            [void](Write-EvidenceBytes $generatedRoot `
                $mesaInput.Target $mesaInput.Bytes)
        }

        $generatorCommands = [Collections.Generic.List[object]]::new()
        $generatorCommandOrdinal = 0
        $msysBin = [IO.Path]::GetDirectoryName((Get-FullEvidencePath $FlexExe))
        $ucrtBin = [IO.Path]::GetDirectoryName((Get-FullEvidencePath $GccExe))
        $perlBin = [IO.Path]::GetDirectoryName((Get-FullEvidencePath $PerlExe))
        $perl5lib = @(
            (Join-EvidenceRelativePath $perlUsr 'share/perl5/vendor_perl'),
            (Join-EvidenceRelativePath $perlUsr 'share/perl5/core_perl'),
            (Join-EvidenceRelativePath $perlUsr 'lib/perl5/core_perl')
        ) -join [IO.Path]::PathSeparator

        $generatorPlans = @(
            [pscustomobject]@{
                recipe = $flexRecipe; tool = $FlexExe; bin = $msysBin
                execution_values = @{
                    output_c = '../generated/libs/vkd3d-shader/hlsl.yy.c'
                    input_l = 'libs/vkd3d-shader/hlsl.l'
                }
                logical_values = @{
                    output_c = '{generated}/libs/vkd3d-shader/hlsl.yy.c'
                    input_l = '{source}/libs/vkd3d-shader/hlsl.l'
                }
                source_value_keys = @('input_l')
                generated_value_keys = @('output_c')
                environment = @{}
                outputs = @('libs/vkd3d-shader/hlsl.yy.c')
            },
            [pscustomobject]@{
                recipe = $bisonRecipe; tool = $BisonExe; bin = $msysBin
                execution_values = @{
                    output_c = '../generated/libs/vkd3d-shader/hlsl.tab.c'
                    input_y = 'libs/vkd3d-shader/hlsl.y'
                }
                logical_values = @{
                    output_c = '{generated}/libs/vkd3d-shader/hlsl.tab.c'
                    input_y = '{source}/libs/vkd3d-shader/hlsl.y'
                }
                source_value_keys = @('input_y')
                generated_value_keys = @('output_c')
                environment = @{
                    BISON_PKGDATADIR = Get-EvidenceForwardPath $expectedBisonData
                    M4 = Get-EvidenceForwardPath $M4Exe
                }
                outputs = @(
                    'libs/vkd3d-shader/hlsl.tab.c',
                    'libs/vkd3d-shader/hlsl.tab.h'
                )
            },
            [pscustomobject]@{
                recipe = $flexRecipe; tool = $FlexExe; bin = $msysBin
                execution_values = @{
                    output_c = '../generated/libs/vkd3d-shader/preproc.yy.c'
                    input_l = 'libs/vkd3d-shader/preproc.l'
                }
                logical_values = @{
                    output_c = '{generated}/libs/vkd3d-shader/preproc.yy.c'
                    input_l = '{source}/libs/vkd3d-shader/preproc.l'
                }
                source_value_keys = @('input_l')
                generated_value_keys = @('output_c')
                environment = @{}
                outputs = @('libs/vkd3d-shader/preproc.yy.c')
            },
            [pscustomobject]@{
                recipe = $bisonRecipe; tool = $BisonExe; bin = $msysBin
                execution_values = @{
                    output_c = '../generated/libs/vkd3d-shader/preproc.tab.c'
                    input_y = 'libs/vkd3d-shader/preproc.y'
                }
                logical_values = @{
                    output_c = '{generated}/libs/vkd3d-shader/preproc.tab.c'
                    input_y = '{source}/libs/vkd3d-shader/preproc.y'
                }
                source_value_keys = @('input_y')
                generated_value_keys = @('output_c')
                environment = @{
                    BISON_PKGDATADIR = Get-EvidenceForwardPath $expectedBisonData
                    M4 = Get-EvidenceForwardPath $M4Exe
                }
                outputs = @(
                    'libs/vkd3d-shader/preproc.tab.c',
                    'libs/vkd3d-shader/preproc.tab.h'
                )
            },
            [pscustomobject]@{
                recipe = $widlRecipe; tool = $WidlExe; bin = $ucrtBin
                execution_values = @{
                    source_include = 'include'
                    output_h = '../generated/include/vkd3d_d3dcommon.h'
                    input_idl = 'include/vkd3d_d3dcommon.idl'
                }
                logical_values = @{
                    source_include = '{source}/include'
                    output_h = '{generated}/include/vkd3d_d3dcommon.h'
                    input_idl = '{source}/include/vkd3d_d3dcommon.idl'
                }
                source_value_keys = @('source_include', 'input_idl')
                generated_value_keys = @('output_h')
                environment = @{}
                outputs = @('include/vkd3d_d3dcommon.h')
            },
            [pscustomobject]@{
                recipe = $widlRecipe; tool = $WidlExe; bin = $ucrtBin
                execution_values = @{
                    source_include = 'include'
                    output_h = '../generated/include/vkd3d_d3dx9shader.h'
                    input_idl = 'include/vkd3d_d3dx9shader.idl'
                }
                logical_values = @{
                    source_include = '{source}/include'
                    output_h = '{generated}/include/vkd3d_d3dx9shader.h'
                    input_idl = '{source}/include/vkd3d_d3dx9shader.idl'
                }
                source_value_keys = @('source_include', 'input_idl')
                generated_value_keys = @('output_h')
                environment = @{}
                outputs = @('include/vkd3d_d3dx9shader.h')
            },
            [pscustomobject]@{
                recipe = $spirvRecipe; tool = $PerlExe; bin = $perlBin
                execution_values = @{
                    make_spirv = 'libs/vkd3d-shader/make_spirv'
                    grammar = 'include/private/spirv.core.grammar.json'
                }
                logical_values = @{
                    make_spirv = '{source}/libs/vkd3d-shader/make_spirv'
                    grammar = '{source}/include/private/spirv.core.grammar.json'
                }
                source_value_keys = @('make_spirv', 'grammar')
                generated_value_keys = @()
                environment = @{ PERL5LIB = $perl5lib }
                outputs = @('include/private/spirv_grammar.h')
            }
        )
        foreach ($plan in $generatorPlans) {
            $generatorCommandOrdinal++
            foreach ($relativeOutput in @($plan.outputs)) {
                $parent = [IO.Path]::GetDirectoryName(
                    (Join-EvidenceRelativePath $generatedRoot $relativeOutput)
                )
                [void][IO.Directory]::CreateDirectory($parent)
            }
            $executionKeys = @(Get-EvidenceOrdinalStrings @(
                $plan.execution_values.Keys | ForEach-Object { [string]$_ }
            ))
            $logicalKeys = @(Get-EvidenceOrdinalStrings @(
                $plan.logical_values.Keys | ForEach-Object { [string]$_ }
            ))
            if (-not (Test-EvidenceStringArrayEqual `
                    $executionKeys $logicalKeys)) {
                throw "Generator '$($plan.recipe.id)' value maps differ."
            }
            $classifiedKeys = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal
            )
            foreach ($key in @($plan.source_value_keys)) {
                if (-not $classifiedKeys.Add([string]$key) -or
                    -not $plan.execution_values.ContainsKey([string]$key)) {
                    throw "Generator '$($plan.recipe.id)' source values are invalid."
                }
                $relative = [string]$plan.execution_values[$key]
                Assert-Vkd3dEvidenceRelativePath $relative `
                    "generator '$($plan.recipe.id)' source value"
                [void](Join-EvidenceRelativePath $sourceRoot $relative)
                if ([string]$plan.logical_values[$key] -cne
                    ('{source}/' + $relative)) {
                    throw "Generator '$($plan.recipe.id)' source evidence is unstable."
                }
            }
            foreach ($key in @($plan.generated_value_keys)) {
                if (-not $classifiedKeys.Add([string]$key) -or
                    -not $plan.execution_values.ContainsKey([string]$key)) {
                    throw "Generator '$($plan.recipe.id)' output values are invalid."
                }
                $executionValue = [string]$plan.execution_values[$key]
                $prefix = '../generated/'
                if (-not $executionValue.StartsWith(
                        $prefix, [StringComparison]::Ordinal
                    )) {
                    throw "Generator '$($plan.recipe.id)' output is not stable."
                }
                $relative = $executionValue.Substring($prefix.Length)
                $expected = Join-EvidenceRelativePath $generatedRoot $relative
                $actual = Get-FullEvidencePath (Join-Path $sourceRoot `
                    $executionValue.Replace('/', '\'))
                if (-not $actual.Equals(
                        $expected, [StringComparison]::OrdinalIgnoreCase
                    ) -or @($plan.outputs) -cnotcontains $relative) {
                    throw "Generator '$($plan.recipe.id)' output escaped its root."
                }
                if ([string]$plan.logical_values[$key] -cne
                    ('{generated}/' + $relative)) {
                    throw "Generator '$($plan.recipe.id)' output evidence is unstable."
                }
            }
            if ($classifiedKeys.Count -ne $executionKeys.Count) {
                throw "Generator '$($plan.recipe.id)' has an unclassified value."
            }
            $arguments = Expand-EvidenceRecipeArguments `
                $plan.recipe $plan.execution_values
            $result = Invoke-Vkd3dEvidenceProcess -File $plan.tool `
                -Arguments $arguments -WorkingDirectory $sourceRoot `
                -PathDirectories @($plan.bin) -PrivateTemp $runTemp `
                -Name "$($runDefinition.id) generator '$($plan.recipe.id)'" `
                -ChildCount ([ref]$childCount) -Environment $plan.environment
            if ($result.stderr.Length -ne 0) {
                throw "$($runDefinition.id) generator '$($plan.recipe.id)' wrote standard error."
            }
            if ($plan.recipe.standard_output -ceq 'capture-for-validation' -and
                $result.stdout.Length -ne 0) {
                throw "$($runDefinition.id) generator '$($plan.recipe.id)' wrote unexpected standard output."
            }
            if ($plan.recipe.standard_output -ceq 'capture-as-output') {
                if (@($plan.outputs).Count -ne 1 -or $result.stdout.Length -eq 0) {
                    throw 'SPIR-V generator did not produce one bounded output stream.'
                }
                [void](Write-EvidenceBytes $generatedRoot $plan.outputs[0] `
                    ([byte[]]$result.stdout))
            }
            foreach ($relativeOutput in @($plan.outputs)) {
                [void](Get-Vkd3dEvidenceFileIdentity `
                    (Join-EvidenceRelativePath $generatedRoot $relativeOutput) `
                    "generated output '$relativeOutput'")
            }
            $generatorCommands.Add([pscustomobject][ordered]@{
                ordinal = [UInt64]$generatorCommandOrdinal
                recipe_id = [string]$plan.recipe.id
                tool_file_id = [string]$plan.recipe.tool_file_id
                arguments = @(Expand-EvidenceRecipeArguments `
                    $plan.recipe $plan.logical_values -AllowLogicalRoots)
                exit_code = [UInt64]$result.exit_code
                stdout_bytes = [UInt64]$result.stdout.Length
                stdout_sha256 = Get-Vkd3dEvidenceSha256 $result.stdout
                stderr_bytes = [UInt64]$result.stderr.Length
                stderr_sha256 = Get-Vkd3dEvidenceSha256 $result.stderr
            })
        }

        $generatorCommandOrdinal++
        [byte[]]$configBytes = Get-Vkd3dShaderExpectedConfigBytes
        [void](Write-EvidenceBytes $generatedRoot 'include/config.h' $configBytes)
        $emptyHash = Get-Vkd3dEvidenceSha256 ([byte[]]@())
        $generatorCommands.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]$generatorCommandOrdinal
            recipe_id = 'reviewed-config-header'
            tool_file_id = 'retvrn99-reviewed-bytes'
            arguments = @('write-exact', 'include/config.h')
            exit_code = [UInt64]0
            stdout_bytes = [UInt64]0
            stdout_sha256 = $emptyHash
            stderr_bytes = [UInt64]0
            stderr_sha256 = $emptyHash
        })
        $generatorCommandOrdinal++
        [byte[]]$versionBytes = Get-Vkd3dShaderExpectedVersionBytes
        [void](Write-EvidenceBytes $generatedRoot `
            'include/private/vkd3d_version.h' $versionBytes)
        $generatorCommands.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]$generatorCommandOrdinal
            recipe_id = 'reviewed-version-header'
            tool_file_id = 'retvrn99-reviewed-bytes'
            arguments = @('write-exact', 'include/private/vkd3d_version.h')
            exit_code = [UInt64]0
            stdout_bytes = [UInt64]0
            stdout_sha256 = $emptyHash
            stderr_bytes = [UInt64]0
            stderr_sha256 = $emptyHash
        })
        if ($generatorCommands.Count -ne 9) {
            throw 'Generator command count is not exactly nine.'
        }

        $outputRows = [Collections.Generic.List[object]]::new()
        $outputOrdinal = 0
        [UInt64]$outputBytes = 0
        [UInt64]$rawOutputBytes = 0
        foreach ($definition in $generatedDefinitions) {
            $outputOrdinal++
            $path = Join-EvidenceRelativePath $generatedRoot $definition.path
            [byte[]]$rawBytes = Read-Vkd3dEvidenceFileBytes $path `
                "raw generated output '$($definition.path)'"
            $normalization = Get-Vkd3dEvidenceGeneratedNormalization `
                -RelativePath $definition.path -RawBytes $rawBytes `
                -Name "generated output '$($definition.path)'"
            $expectedMode = if ([string]$definition.recipe -ceq 'widl-header') {
                'crlf-to-lf'
            }
            else { 'none' }
            if ([string]$normalization.Mode -cne $expectedMode -or
                -not $normalization.Proven) {
                throw "Generated output '$($definition.path)' has an unexpected normalization."
            }
            foreach ($variant in @(
                @('raw', [byte[]]$normalization.RawBytes),
                @('canonical', [byte[]]$normalization.CanonicalBytes)
            )) {
                $text = ConvertFrom-Vkd3dEvidenceUtf8 $variant[1] `
                    "generated output '$($definition.path)' $($variant[0])"
                Assert-EvidenceNoPrivateText $text @(
                    $repoRoot, $proof, $lfCheckout, $crlfCheckout,
                    $mesaSource, $msysRoot, $ucrtRoot, $gitRoot,
                    $proofParent, $outputParent
                ) "generated output '$($definition.path)' $($variant[0])"
            }
            if ($expectedMode -ceq 'crlf-to-lf') {
                $expected = $expectedWidlNormalization[$definition.path]
                if ($null -eq $expected -or
                    [UInt64]$normalization.Raw.bytes -ne [UInt64]$expected.raw_bytes -or
                    [string]$normalization.Raw.sha256 -cne [string]$expected.raw_sha256 -or
                    [UInt64]$normalization.Raw.crlf_count -ne [UInt64]$expected.newline_count -or
                    [UInt64]$normalization.Canonical.bytes -ne [UInt64]$expected.bytes -or
                    [string]$normalization.Canonical.sha256 -cne [string]$expected.sha256 -or
                    [UInt64]$normalization.Canonical.lf_only_count -ne [UInt64]$expected.newline_count) {
                    throw "Generated WIDL output '$($definition.path)' drifted."
                }
                Set-EvidenceCanonicalBytes $generatedRoot $definition.path `
                    ([byte[]]$normalization.CanonicalBytes)
            }
            [byte[]]$bytes = [byte[]]$normalization.CanonicalBytes
            $license = Get-Vkd3dShaderGeneratedLicense `
                -RelativePath $definition.path -Bytes $bytes `
                -InputRelativePaths ([string[]]@($definition.inputs))
            $identity = Get-Vkd3dEvidenceFileIdentity $path `
                "generated output '$($definition.path)'"
            if ([UInt64]$identity.bytes -ne
                    [UInt64]$normalization.Canonical.bytes -or
                [string]$identity.sha256 -cne
                    [string]$normalization.Canonical.sha256) {
                throw "Generated output '$($definition.path)' canonical identity changed."
            }
            $outputBytes += [UInt64]$identity.bytes
            $rawOutputBytes += [UInt64]$normalization.Raw.bytes
            $outputRows.Add([pscustomobject][ordered]@{
                ordinal = [UInt64]$outputOrdinal
                relative_path = [string]$definition.path
                raw_bytes = [UInt64]$normalization.Raw.bytes
                raw_sha256 = [string]$normalization.Raw.sha256
                raw_lf_count = [UInt64]$normalization.Raw.lf_count
                raw_crlf_count = [UInt64]$normalization.Raw.crlf_count
                raw_lf_only_count = [UInt64]$normalization.Raw.lf_only_count
                raw_cr_only_count = [UInt64]$normalization.Raw.cr_only_count
                raw_utf8_bom = [bool]$normalization.Raw.utf8_bom
                normalization = [string]$normalization.Mode
                removed_cr_bytes = [UInt64]$normalization.RemovedCrBytes
                normalization_proven = [bool]$normalization.Proven
                bytes = [UInt64]$identity.bytes
                sha256 = [string]$identity.sha256
                lf_count = [UInt64]$normalization.Canonical.lf_count
                crlf_count = [UInt64]$normalization.Canonical.crlf_count
                lf_only_count = [UInt64]$normalization.Canonical.lf_only_count
                cr_only_count = [UInt64]$normalization.Canonical.cr_only_count
                utf8_bom = [bool]$normalization.Canonical.utf8_bom
                license_expression = [string]$license.license_expression
                provenance = [string]$license.provenance
            })
        }
        $actualGeneratedFiles = @(Get-EvidenceOrdinalStrings @([IO.Directory]::EnumerateFiles(
            $generatedRoot, '*', [IO.SearchOption]::AllDirectories
        ) | ForEach-Object {
            [IO.Path]::GetRelativePath($generatedRoot, $_).Replace('\', '/')
        }))
        $expectedGeneratedFiles = @(Get-EvidenceOrdinalStrings @(
            @($generatedDefinitions | ForEach-Object path) +
            @($mesaInputDefinitions | ForEach-Object target)
        ))
        if (-not (Test-EvidenceStringArrayEqual `
                $actualGeneratedFiles $expectedGeneratedFiles)) {
            throw 'Generated root contains an unexpected or missing file.'
        }
        $actualSourceFiles = @(Get-EvidenceOrdinalStrings @([IO.Directory]::EnumerateFiles(
            $sourceRoot, '*', [IO.SearchOption]::AllDirectories
        ) | ForEach-Object {
            [IO.Path]::GetRelativePath($sourceRoot, $_).Replace('\', '/')
        }))
        $expectedSourceFiles = @(Get-EvidenceOrdinalStrings `
            @($sourceInternals | ForEach-Object RelativePath))
        if (-not (Test-EvidenceStringArrayEqual `
                $actualSourceFiles $expectedSourceFiles)) {
            throw 'Canonical source root contains an unexpected or missing file.'
        }

        $generatedRuns.Add([pscustomobject][ordered]@{
            id = [string]$runDefinition.id
            source_mode = [string]$runDefinition.mode
            generator_commands = @($generatorCommands)
            output_count = [UInt64]$outputRows.Count
            raw_aggregate_bytes = $rawOutputBytes
            raw_aggregate_sha256 = Get-Vkd3dEvidenceAggregateSha256 @(
                $outputRows | ForEach-Object {
                    [pscustomobject]@{
                        relative_path = [string]$_.relative_path
                        bytes = [UInt64]$_.raw_bytes
                        sha256 = [string]$_.raw_sha256
                    }
                }
            )
            aggregate_bytes = $outputBytes
            aggregate_sha256 = Get-Vkd3dEvidenceAggregateSha256 @($outputRows)
            outputs = @($outputRows)
        })
        $runContexts.Add([pscustomobject]@{
            Id = [string]$runDefinition.id
            Mode = [string]$runDefinition.mode
            Root = $runRoot
            Source = $sourceRoot
            Generated = $generatedRoot
            Temp = $runTemp
            Object = $objectRoot
            Dep = $depRoot
            Outputs = @($outputRows)
        })
    }

    $firstGeneratedJson = $generatedRuns[0].outputs |
        ConvertTo-Json -Depth 10 -Compress
    $secondGeneratedJson = $generatedRuns[1].outputs |
        ConvertTo-Json -Depth 10 -Compress
    if ($firstGeneratedJson -cne $secondGeneratedJson -or
        $generatedRuns[0].raw_aggregate_bytes -ne
            $generatedRuns[1].raw_aggregate_bytes -or
        $generatedRuns[0].raw_aggregate_sha256 -cne
            $generatedRuns[1].raw_aggregate_sha256 -or
        $generatedRuns[0].aggregate_sha256 -cne
            $generatedRuns[1].aggregate_sha256) {
        throw 'Twin raw or canonical generated outputs differ.'
    }

    $compilationUnits = [Collections.Generic.List[object]]::new()
    $allPrivateRoots = @(
        $proof, $lfCheckout, $crlfCheckout, $mesaSource,
        $msysRoot, $ucrtRoot, $gitRoot
    )
    $globalDependencyRows = @{
        lf = [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
        crlf = [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
    }
    $unitOrdinal = 0
    foreach ($unit in $unitOrder) {
        $unitOrdinal++
        $inputKind = [string]$unit[0]
        $inputRelative = [string]$unit[1]
        $stem = Get-Vkd3dEvidenceObjectStem $inputRelative
        $objectRelative = 'obj/{0:D2}-{1}.o' -f $unitOrdinal, $stem
        $depRelative = 'dep/{0:D2}-{1}.d' -f $unitOrdinal, $stem
        $runDetails = [Collections.Generic.List[object]]::new()
        $proofObjects = [Collections.Generic.List[object]]::new()
        $unitSha256 = $null
        $logicalArguments = $null
        foreach ($run in $runContexts) {
            $inputRoot = if ($inputKind -ceq 'tracked') {
                $run.Source
            }
            else { $run.Generated }
            $inputPath = Join-EvidenceRelativePath $inputRoot $inputRelative
            $inputIdentity = Get-Vkd3dEvidenceFileIdentity $inputPath `
                "compiler input '$inputRelative'"
            if ($null -eq $unitSha256) {
                $unitSha256 = [string]$inputIdentity.sha256
            }
            elseif ($unitSha256 -cne [string]$inputIdentity.sha256) {
                throw "Compiler input '$inputRelative' differs between runs."
            }
            $objectPath = Join-EvidenceRelativePath $run.Root $objectRelative
            $depPath = Join-EvidenceRelativePath $run.Root $depRelative
            if ([IO.File]::Exists($objectPath) -or [IO.File]::Exists($depPath)) {
                throw 'Compiler output path was not fresh.'
            }
            $values = @{
                source_root = Get-EvidenceForwardPath $run.Source
                generated_root = Get-EvidenceForwardPath $run.Generated
                temporary_root = Get-EvidenceForwardPath $run.Temp
                unit_sha256 = $unitSha256
                depfile = Get-EvidenceForwardPath $depPath
                object = Get-EvidenceForwardPath $objectPath
                input_c = Get-EvidenceForwardPath $inputPath
            }
            $arguments = Expand-EvidenceRecipeArguments $compileRecipe $values
            foreach ($argument in $arguments) {
                if ([string]$argument -match '^[A-Za-z]:\\' -or
                    ([string]$argument).Contains('\')) {
                    throw 'GCC received a backslash-spelled argument.'
                }
            }
            $compileResult = Invoke-Vkd3dEvidenceProcess -File $GccExe `
                -Arguments $arguments -WorkingDirectory $run.Root `
                -PathDirectories @([IO.Path]::GetDirectoryName(
                    (Get-FullEvidencePath $GccExe)
                )) -PrivateTemp $run.Temp `
                -Name "$($run.Id) compile '$inputRelative'" `
                -ChildCount ([ref]$childCount)
            if ($compileResult.stdout.Length -ne 0 -or
                $compileResult.stderr.Length -ne 0) {
                throw "$($run.Id) compile '$inputRelative' produced unexpected diagnostics."
            }
            [byte[]]$depBytes = Read-Vkd3dEvidenceFileBytes $depPath `
                "$($run.Id) depfile '$inputRelative'" 4194304
            $depText = ConvertFrom-Vkd3dEvidenceUtf8 $depBytes `
                "$($run.Id) depfile '$inputRelative'"
            $tokens = @(Get-Vkd3dEvidenceDependencyTokens $depText `
                (Get-EvidenceForwardPath $objectPath))
            if ($tokens.Count -gt 4096) {
                throw "Depfile for '$inputRelative' exceeds its occurrence bound."
            }
            $logicalRoots = [ordered]@{
                source = $run.Source
                generated = $run.Generated
                gcc_tool = $expectedGccTool
                ucrt64 = $ucrtRoot
            }
            $dependencyByPath =
                [Collections.Generic.Dictionary[string, object]]::new(
                [StringComparer]::Ordinal
            )
            foreach ($token in $tokens) {
                $logical = ConvertTo-Vkd3dEvidenceLogicalPath $token $logicalRoots
                $identity = Get-Vkd3dEvidenceFileIdentity `
                    (Get-FullEvidencePath $token) `
                    "$($run.Id) dependency '$logical'"
                $row = Add-Vkd3dEvidenceDependencyOccurrence `
                    -Rows $dependencyByPath -RelativePath $logical `
                    -Bytes ([UInt64]$identity.bytes) `
                    -Sha256 ([string]$identity.sha256) `
                    -MaximumOccurrenceCount 4096
                $global = $globalDependencyRows[$run.Id]
                [void](Add-Vkd3dEvidenceDependencyOccurrence `
                    -Rows $global -RelativePath $logical `
                    -Bytes ([UInt64]$identity.bytes) `
                    -Sha256 ([string]$identity.sha256) `
                    -MaximumOccurrenceCount 77824)
            }
            $sortedDependencyRows = @(Get-EvidenceSortedRows `
                @($dependencyByPath.Values))
            [UInt64]$derivedOccurrenceCount = 0
            foreach ($row in $sortedDependencyRows) {
                $derivedOccurrenceCount += [UInt64]$row.occurrence_count
            }
            if ($derivedOccurrenceCount -ne [UInt64]$tokens.Count) {
                throw "Depfile for '$inputRelative' multiplicity changed."
            }

            $objectProof = Get-MesaNormalizedCoffObject -Path $objectPath `
                -PrivateRoots @($allPrivateRoots + @(
                    $run.Root, $run.Source, $run.Generated, $run.Temp,
                    $run.Object, $run.Dep
                )) -ExpectedMachine ([UInt16]0x8664)
            $proofObjects.Add($objectProof)
            $objdumpArguments = Expand-EvidenceRecipeArguments $objdumpRecipe `
                @{ object = $objectRelative }
            $objdumpResult = Invoke-Vkd3dEvidenceProcess -File $ObjdumpExe `
                -Arguments $objdumpArguments -WorkingDirectory $run.Root `
                -PathDirectories @([IO.Path]::GetDirectoryName(
                    (Get-FullEvidencePath $ObjdumpExe)
                )) -PrivateTemp $run.Temp `
                -Name "$($run.Id) objdump '$inputRelative'" `
                -ChildCount ([ref]$childCount)
            if ($objdumpResult.stderr.Length -ne 0) {
                throw "$($run.Id) objdump '$inputRelative' wrote standard error."
            }
            $objdumpLines = @(Get-EvidenceStrictLines $objdumpResult.stdout `
                "$($run.Id) objdump '$inputRelative'")
            $objdumpText = $objdumpLines -join "`n"
            Assert-EvidenceNoPrivateText $objdumpText `
                @($allPrivateRoots + @(
                    $run.Root, $run.Source, $run.Generated, $run.Temp,
                    $run.Object, $run.Dep
                )) "$($run.Id) objdump output"
            if ($objdumpText.IndexOf(
                    'file format pe-x86-64',
                    [StringComparison]::Ordinal
                ) -lt 0 -or $objdumpText.IndexOf(
                    'architecture: i386:x86-64',
                    [StringComparison]::Ordinal
                ) -lt 0) {
                throw "$($run.Id) objdump did not confirm AMD64 PE-COFF."
            }
            [byte[]]$logicalObjdumpBytes = $script:OutputUtf8.GetBytes(
                $objdumpText + "`n"
            )
            $objectEvidence = [pscustomobject][ordered]@{
                relative_path = $objectRelative
                machine = [UInt64]$objectProof.Machine
                machine_name = 'amd64'
                bytes = [UInt64]$objectProof.Bytes
                timestamp = [UInt64]$objectProof.Timestamp
                raw_sha256 = [string]$objectProof.RawSha256
                normalized_sha256 = [string]$objectProof.NormalizedSha256
            }
            $runDetails.Add([pscustomobject][ordered]@{
                id = [string]$run.Id
                dependency_file = [pscustomobject][ordered]@{
                    relative_path = $depRelative
                    dependency_count = $derivedOccurrenceCount
                    unique_dependency_count =
                        [UInt64]$sortedDependencyRows.Count
                    aggregate_sha256 =
                        Get-Vkd3dEvidenceDependencyMultiplicitySha256 `
                        @($sortedDependencyRows)
                    files = @($sortedDependencyRows)
                }
                object = $objectEvidence
                objdump = [pscustomobject][ordered]@{
                    arguments = @($objdumpArguments)
                    format = 'pe-x86-64'
                    architecture = 'i386:x86-64'
                    stdout_bytes = [UInt64]$logicalObjdumpBytes.Length
                    stdout_sha256 = Get-Vkd3dEvidenceSha256 $logicalObjdumpBytes
                }
            })
            $objectRowsByRun[$run.Id] += [pscustomobject]@{
                unit_ordinal = [UInt64]$unitOrdinal
                object = $objectRelative
                bytes = [UInt64]$objectProof.Bytes
                normalized_sha256 = [string]$objectProof.NormalizedSha256
            }
            if ($null -eq $logicalArguments) {
                $logicalValues = @{
                    source_root = '{source}'
                    generated_root = '{generated}'
                    temporary_root = '{temporary}'
                    unit_sha256 = $unitSha256
                    depfile = $depRelative
                    object = $objectRelative
                    input_c = if ($inputKind -ceq 'tracked') {
                        '{source}/' + $inputRelative
                    }
                    else { '{generated}/' + $inputRelative }
                }
                $logicalArguments = @(Expand-EvidenceRecipeArguments `
                    $compileRecipe $logicalValues -AllowLogicalRoots)
            }
        }
        if ($runDetails.Count -ne 2 -or $proofObjects.Count -ne 2) {
            throw "Compiler unit '$inputRelative' lacks twin evidence."
        }
        Assert-EvidenceDependencyRowsEqual `
            @($runDetails[0].dependency_file.files) `
            @($runDetails[1].dependency_file.files) `
            "Dependency evidence for '$inputRelative'"
        if ([UInt64]$runDetails[0].dependency_file.dependency_count -ne
                [UInt64]$runDetails[1].dependency_file.dependency_count -or
            [UInt64]$runDetails[0].dependency_file.unique_dependency_count -ne
                [UInt64]$runDetails[1].dependency_file.unique_dependency_count -or
            $runDetails[0].dependency_file.aggregate_sha256 -cne
                $runDetails[1].dependency_file.aggregate_sha256) {
            throw "Dependency multiplicity for '$inputRelative' differs between runs."
        }
        Assert-MesaObjectTwin $proofObjects[0] $proofObjects[1] `
            "Compiler unit '$inputRelative'"
        if ($runDetails[0].objdump.stdout_sha256 -cne
                $runDetails[1].objdump.stdout_sha256) {
            throw "Objdump evidence for '$inputRelative' differs between runs."
        }
        $compilationUnits.Add([pscustomobject][ordered]@{
            unit_ordinal = [UInt64]$unitOrdinal
            input_kind = $inputKind
            input = $inputRelative
            sha256 = $unitSha256
        })
        $commandEvidence.Add([pscustomobject][ordered]@{
            unit_ordinal = [UInt64]$unitOrdinal
            input_kind = $inputKind
            input = $inputRelative
            input_sha256 = $unitSha256
            arguments = @($logicalArguments)
            runs = @($runDetails)
            twin = [pscustomobject][ordered]@{
                dependency_match = $true
                normalized_object_match = $true
                objdump_format_match = $true
            }
        })
        foreach ($run in $runContexts) {
            [IO.File]::Delete((Join-EvidenceRelativePath $run.Root $objectRelative))
            [IO.File]::Delete((Join-EvidenceRelativePath $run.Root $depRelative))
        }
    }
    if ($commandEvidence.Count -ne $unitOrder.Count) {
        throw 'Compiler command evidence count differs from Makefile evidence.'
    }

    $dependencySets = @{}
    foreach ($runId in @('lf', 'crlf')) {
        $rows = @(Get-EvidenceSortedRows @($globalDependencyRows[$runId].Values))
        [UInt64]$occurrenceCount = 0
        foreach ($row in $rows) {
            $occurrenceCount += [UInt64]$row.occurrence_count
        }
        $dependencySets[$runId] = [pscustomobject]@{
            Rows = @($rows)
            OccurrenceCount = $occurrenceCount
            Aggregate = Get-Vkd3dEvidenceDependencyMultiplicitySha256 @($rows)
        }
    }
    Assert-EvidenceDependencyRowsEqual @($dependencySets.lf.Rows) `
        @($dependencySets.crlf.Rows) 'Global dependency evidence'
    if ([UInt64]$dependencySets.lf.OccurrenceCount -ne
            [UInt64]$dependencySets.crlf.OccurrenceCount -or
        $dependencySets.lf.Aggregate -cne $dependencySets.crlf.Aggregate) {
        throw 'Global dependency multiplicity differs between runs.'
    }
    foreach ($dependency in $dependencyRows) {
        $logical = '{source}/' + [string]$dependency.relative_path
        if (-not $globalDependencyRows.lf.ContainsKey($logical)) {
            throw "Reviewed compiler dependency '$logical' was not observed."
        }
    }
    foreach ($mesaInput in $mesaInputDefinitions) {
        $logical = '{generated}/' + [string]$mesaInput.target
        if (-not $globalDependencyRows.lf.ContainsKey($logical)) {
            throw "Mesa compiler dependency '$logical' was not observed."
        }
    }
    $objectAggregateLf = Get-MesaObjectAggregateSha256 @($objectRowsByRun.lf)
    $objectAggregateCrlf = Get-MesaObjectAggregateSha256 @($objectRowsByRun.crlf)
    if ($objectAggregateLf -cne $objectAggregateCrlf) {
        throw 'Normalized object aggregates differ between runs.'
    }

    foreach ($run in $runContexts) {
        $recordedRun = @($generatedRuns | Where-Object id -ceq $run.Id)
        if ($recordedRun.Count -ne 1) {
            throw 'Generated run evidence became ambiguous.'
        }
        $currentOutputs = [Collections.Generic.List[object]]::new()
        foreach ($row in @($recordedRun[0].outputs)) {
            $identity = Get-Vkd3dEvidenceFileIdentity `
                (Join-EvidenceRelativePath $run.Generated $row.relative_path) `
                "final generated output '$($row.relative_path)'"
            $currentOutputs.Add([pscustomobject]@{
                relative_path = [string]$row.relative_path
                bytes = [UInt64]$identity.bytes
                sha256 = [string]$identity.sha256
            })
        }
        Assert-EvidenceRowsEqual @($recordedRun[0].outputs) `
            @($currentOutputs) "Final $($run.Id) generated outputs"
        foreach ($internal in $sourceInternals) {
            $identity = Get-Vkd3dEvidenceFileIdentity `
                (Join-EvidenceRelativePath $run.Source $internal.RelativePath) `
                "final canonical source '$($internal.RelativePath)'"
            [byte[]]$expectedBytes = [byte[]]::new(0)
            if ($run.Id -ceq 'lf') {
                $expectedBytes = $internal.LfBytes
            }
            else { $expectedBytes = $internal.CrlfBytes }
            if ([UInt64]$identity.bytes -ne [UInt64]$expectedBytes.Length -or
                [string]$identity.sha256 -cne
                    (Get-Vkd3dEvidenceSha256 $expectedBytes)) {
                throw "Canonical source '$($internal.RelativePath)' changed during proof."
            }
        }
    }

    foreach ($checkout in @(
        [pscustomobject]@{ id = 'lf'; mode = 'lf'; root = $lfCheckout },
        [pscustomobject]@{ id = 'crlf'; mode = 'crlf'; root = $crlfCheckout }
    )) {
        $head = Invoke-EvidenceGit $checkout.root @('rev-parse', 'HEAD') `
            $privateTemp "final $($checkout.id) HEAD" ([ref]$childCount) `
            $GitExe $gitBin
        $headLines = @(Get-EvidenceStrictLines $head.stdout `
            "final $($checkout.id) HEAD")
        $branch = Invoke-EvidenceGit $checkout.root `
            @('rev-parse', '--abbrev-ref', 'HEAD') $privateTemp `
            "final $($checkout.id) detached HEAD" ([ref]$childCount) `
            $GitExe $gitBin
        $branchLines = @(Get-EvidenceStrictLines $branch.stdout `
            "final $($checkout.id) detached HEAD")
        $status = Invoke-EvidenceGit $checkout.root `
            @('status', '--porcelain=v1', '-z', '--untracked-files=all') `
            $privateTemp "final $($checkout.id) status" `
            ([ref]$childCount) $GitExe $gitBin
        $origin = Invoke-EvidenceGit $checkout.root `
            @('config', '--get', 'remote.origin.url') $privateTemp `
            "final $($checkout.id) origin" ([ref]$childCount) $GitExe $gitBin
        $originLines = @(Get-EvidenceStrictLines $origin.stdout `
            "final $($checkout.id) origin")
        if ($headLines.Count -ne 1 -or
            $headLines[0] -cne $script:Vkd3dCommit -or
            $branchLines.Count -ne 1 -or $branchLines[0] -cne 'HEAD' -or
            $status.stdout.Length -ne 0 -or $originLines.Count -ne 1 -or
            $originLines[0] -cne $script:Vkd3dRepository) {
            throw "$($checkout.id) checkout drifted during proof."
        }
        foreach ($internal in $sourceInternals) {
            [byte[]]$gitBytes = [byte[]]::new(0)
            if ($checkout.id -ceq 'lf') {
                $blob = Invoke-EvidenceGit $lfCheckout `
                    @('cat-file', 'blob', ($script:Vkd3dCommit + ':' +
                        $internal.RelativePath)) $privateTemp `
                    "final Git blob '$($internal.RelativePath)'" `
                    ([ref]$childCount) $GitExe $gitBin
                $gitBytes = $blob.stdout
            }
            else { $gitBytes = $internal.LfBytes }
            [byte[]]$checkoutBytes = Read-Vkd3dEvidenceFileBytes `
                (Join-EvidenceRelativePath $checkout.root $internal.RelativePath) `
                "final $($checkout.id) source '$($internal.RelativePath)'"
            $observation = ConvertTo-Vkd3dShaderCanonicalObservation `
                $checkoutBytes $gitBytes $checkout.mode $internal.RelativePath
            if (-not (Test-Vkd3dShaderBytesEqual `
                    $observation.CanonicalBytes $internal.LfBytes)) {
                throw "Selected source '$($internal.RelativePath)' drifted during proof."
            }
        }
    }
    foreach ($mesaInput in $mesaInputs) {
        [byte[]]$currentMesaBytes = Read-Vkd3dEvidenceFileBytes `
            (Join-EvidenceRelativePath $mesaSource `
                $mesaInputDefinitions[$mesaInputs.IndexOf($mesaInput)].source) `
            'final Mesa cross-component input'
        if (-not (Test-Vkd3dShaderBytesEqual `
                $currentMesaBytes $mesaInput.Bytes)) {
            throw 'A Mesa cross-component input drifted during proof.'
        }
    }
    foreach ($file in $fileRows) {
        Assert-EvidenceLockedFile $rootMap[[string]$file.root] $file
    }
    [void](Get-Vkd3dEvidenceTreeIdentity $expectedBisonData `
        $bisonTree.descriptor 'final Bison data tree')
    [void](Get-Vkd3dEvidenceTreeIdentity $expectedGccTool `
        $gccTree.descriptor 'final GCC internal-header tree')
    foreach ($snapshotCheck in @(
        @($schemaPath, 'vkd3d-shader compiler-closure schema', 1048576, $schemaSnapshot),
        @($componentPath, 'vkd3d-shader component manifest', 1048576, $componentSnapshot),
        @($mesaComponentPath, 'Mesa component manifest', 2097152, $mesaSnapshot),
        @($toolchainLockPath, 'vkd3d-shader toolchain lock', 1048576, $lockSnapshot)
    )) {
        $currentSnapshot = Read-GswStrictJsonFileSnapshot `
            -Path $snapshotCheck[0] `
            -Name ('final ' + $snapshotCheck[1]) `
            -MaximumBytes ([UInt64]$snapshotCheck[2])
        if ($currentSnapshot.Length -ne $snapshotCheck[3].Length -or
            $currentSnapshot.Sha256 -cne $snapshotCheck[3].Sha256) {
            throw "$($snapshotCheck[1]) drifted during proof."
        }
    }

    if ($null -eq $proofRootHandle -or $proofRootHandle.IsInvalid -or
        $proofRootHandle.IsClosed -or $null -eq $ownerMarkerHandle -or
        $ownerMarkerHandle.IsInvalid -or $ownerMarkerHandle.IsClosed -or
        [string]::IsNullOrWhiteSpace($ownerToken)) {
        throw 'Proof ownership state was lost before cleanup.'
    }
    Remove-Vkd3dEvidenceOwnedTree $proof $ownerToken `
        -RootHandle $proofRootHandle `
        -OwnerMarkerHandle $ownerMarkerHandle
    $proofRootHandle = $null
    $ownerMarkerHandle = $null
    $ownerToken = $null
    if ([IO.Directory]::Exists($proof) -or [IO.File]::Exists($proof) -or
        [IO.File]::Exists($partialOutput) -or
        [IO.Directory]::Exists($partialOutput)) {
        throw 'Temporary proof cleanup is incomplete.'
    }

    $sourceAggregateRows = @($sourceEvidence | ForEach-Object {
        [pscustomobject]@{
            relative_path = [string]$_.relative_path
            bytes = [UInt64]$_.bytes
            sha256 = [string]$_.sha256
        }
    })
    $mesaAggregateRows = @($mesaEvidence | ForEach-Object {
        [pscustomobject]@{
            relative_path = [string]$_.target_relative_path
            bytes = [UInt64]$_.bytes
            sha256 = [string]$_.sha256
        }
    })
    [UInt64]$mesaAggregateBytes = 0
    foreach ($row in $mesaEvidence) { $mesaAggregateBytes += [UInt64]$row.bytes }
    $gitProbe = @($probeEvidence | Where-Object id -ceq 'git-version')
    if ($gitProbe.Count -ne 1 -or $gitProbe[0].observed_lines.Count -lt 1) {
        throw 'Git version probe evidence is absent.'
    }
    $toolFileEvidence = @($fileRows | ForEach-Object {
        [pscustomobject][ordered]@{
            id = [string]$_.id
            root = [string]$_.root
            relative_path = [string]$_.relative_path
            role = [string]$_.role
            bytes = [UInt64]$_.bytes
            sha256 = [string]$_.sha256
        }
    })
    $treeEvidence = @(
        [pscustomobject][ordered]@{
            id = [string]$bisonTree.id
            root = [string]$bisonTree.root
            relative_path = [string]$bisonTree.relative_path
            role = [string]$bisonTree.role
            descriptor = $bisonTreeObserved
        },
        [pscustomobject][ordered]@{
            id = [string]$gccTree.id
            root = [string]$gccTree.root
            relative_path = [string]$gccTree.relative_path
            role = [string]$gccTree.role
            descriptor = $gccTreeObserved
        }
    )
    $generatorRecipeEvidence = @(
        @($flexRecipe, $bisonRecipe, $widlRecipe, $spirvRecipe) |
            ForEach-Object {
            [pscustomobject][ordered]@{
                id = [string]$_.id
                tool_file_id = [string]$_.tool_file_id
                provenance = [string]$_.provenance
                arguments = @($_.arguments)
                standard_output = [string]$_.standard_output
            }
        }
    )
    $evidence = [pscustomobject][ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = [UInt64]1
        schema_definition = [pscustomobject][ordered]@{
            relative_path = 'vkd3d-shader-compiler-closure.schema.json'
            bytes = [UInt64]$schemaSnapshot.Length
            sha256 = [string]$schemaSnapshot.Sha256
        }
        status = 'compile-proven'
        source = [pscustomobject][ordered]@{
            component = 'vkd3d-shader'
            repository = $script:Vkd3dRepository
            owning_commit = $script:Vkd3dCommit
            component_manifest = [pscustomobject][ordered]@{
                relative_path = 'component-closures/vkd3d-shader.json'
                bytes = [UInt64]$componentSnapshot.Length
                sha256 = [string]$componentSnapshot.Sha256
                status = 'ready'
                file_count = [UInt64]$sourceEvidence.Count
            }
            git_tool = [pscustomobject][ordered]@{
                file_id = 'git-core'
                bytes = [UInt64]$gitRow.bytes
                sha256 = [string]$gitRow.sha256
                probe_id = 'git-version'
                version = [string]$gitProbe[0].observed_lines[0]
            }
        }
        source_pair = [pscustomobject][ordered]@{
            status = 'canonical-lf-crlf-proven'
            checkouts = @(
                [pscustomobject][ordered]@{
                    id = 'lf'
                    checkout_mode = 'lf'
                    clean = $true
                    detached = $true
                    owning_commit = $script:Vkd3dCommit
                    origin = $script:Vkd3dRepository
                },
                [pscustomobject][ordered]@{
                    id = 'crlf'
                    checkout_mode = 'crlf'
                    clean = $true
                    detached = $true
                    owning_commit = $script:Vkd3dCommit
                    origin = $script:Vkd3dRepository
                }
            )
            file_count = [UInt64]$sourceEvidence.Count
            aggregate_bytes = $sourceBytes
            aggregate_sha256 = Get-Vkd3dEvidenceAggregateSha256 $sourceAggregateRows
            files = @($sourceEvidence)
        }
        cross_component_inputs = [pscustomobject][ordered]@{
            status = 'ready'
            component_manifest = [pscustomobject][ordered]@{
                relative_path = 'component-closures/mesa9x-23.1.x.json'
                bytes = [UInt64]$mesaSnapshot.Length
                sha256 = [string]$mesaSnapshot.Sha256
                status = 'ready'
                file_count = [UInt64]@($mesaComponent.files).Count
            }
            owning_commit = $script:MesaCommit
            file_count = [UInt64]$mesaEvidence.Count
            aggregate_bytes = $mesaAggregateBytes
            aggregate_sha256 = Get-Vkd3dEvidenceAggregateSha256 $mesaAggregateRows
            files = @($mesaEvidence)
        }
        toolchain = [pscustomobject][ordered]@{
            status = 'ready'
            lock = [pscustomobject][ordered]@{
                relative_path = 'vkd3d-shader-toolchain-lock.json'
                bytes = [UInt64]$lockSnapshot.Length
                sha256 = [string]$lockSnapshot.Sha256
                status = 'ready'
            }
            roots = @(
                [pscustomobject][ordered]@{ id = 'msys'; verified = $true },
                [pscustomobject][ordered]@{ id = 'ucrt64'; verified = $true },
                [pscustomobject][ordered]@{ id = 'git'; verified = $true }
            )
            files = $toolFileEvidence
            trees = $treeEvidence
            probes = @($probeEvidence)
            environment = [pscustomobject][ordered]@{
                path_policy = 'executable-parent-directories-only'
                perl5lib_roots = @(
                    'git:usr/share/perl5/vendor_perl',
                    'git:usr/share/perl5/core_perl',
                    'git:usr/lib/perl5/core_perl'
                )
                ambient_library_paths = $false
            }
            process_limits = [pscustomobject][ordered]@{
                no_shell = $true
                maximum_top_level_processes = [UInt64]1
                maximum_process_tree_width = [UInt64]5
                timeout_seconds = [UInt64]30
                termination_grace_seconds = [UInt64]5
                maximum_stdout_bytes = [UInt64]1048576
                maximum_stderr_bytes = [UInt64]1048576
                terminate_process_tree = $true
            }
        }
        recipe = [pscustomobject][ordered]@{
            status = 'exact-compile-only'
            generated_output_count = [UInt64]$generatedDefinitions.Count
            tracked_source_unit_count = [UInt64]$derivedTrackedUnits.Count
            generated_source_unit_count = [UInt64]$derivedGeneratedUnits.Count
            compile_command_count = [UInt64]$unitOrder.Count
            generator_recipes = @($generatorRecipeEvidence)
            compile_arguments = @($compileRecipe.arguments)
            object_validation_arguments = @($objdumpRecipe.arguments)
            generated_outputs = @($generatedRecipeEvidence)
            compilation_units = @($compilationUnits)
        }
        generated_runs = @($generatedRuns)
        commands = @($commandEvidence)
        comparison = [pscustomobject][ordered]@{
            raw_generated_outputs = [pscustomobject][ordered]@{
                match = $true
                count = [UInt64]$generatedDefinitions.Count
                aggregate_sha256 = [string]$generatedRuns[0].raw_aggregate_sha256
            }
            generated_outputs = [pscustomobject][ordered]@{
                match = $true
                count = [UInt64]$generatedDefinitions.Count
                aggregate_sha256 = [string]$generatedRuns[0].aggregate_sha256
            }
            dependencies = [pscustomobject][ordered]@{
                match = $true
                occurrence_count =
                    [UInt64]$dependencySets.lf.OccurrenceCount
                unique_count = [UInt64]$dependencySets.lf.Rows.Count
                aggregate_sha256 = [string]$dependencySets.lf.Aggregate
            }
            normalized_objects = [pscustomobject][ordered]@{
                match = $true
                count = [UInt64]$unitOrder.Count
                aggregate_sha256 = $objectAggregateLf
            }
        }
        summary = [pscustomobject][ordered]@{
            source_files = [UInt64]$sourceEvidence.Count
            generated_outputs = [UInt64]$generatedDefinitions.Count
            tracked_source_units = [UInt64]$derivedTrackedUnits.Count
            generated_source_units = [UInt64]$derivedGeneratedUnits.Count
            compile_commands = [UInt64]$unitOrder.Count
            twin_compile_invocations = [UInt64](2 * $unitOrder.Count)
            dependency_files = [UInt64](2 * $unitOrder.Count)
            validated_amd64_coff_objects = [UInt64](2 * $unitOrder.Count)
            objdump_validations = [UInt64](2 * $unitOrder.Count)
            child_processes = [UInt64]$childCount
            temporary_output_count = [UInt64]0
            proof_root_removed = $true
            partial_evidence_removed = $true
            linker_invocations = [UInt64]0
            failed_generator_commands = [UInt64]0
            failed_compile_commands = [UInt64]0
            failed_dependency_validations = [UInt64]0
            failed_object_validations = [UInt64]0
        }
        authorizations = [pscustomobject][ordered]@{
            fetch = $false
            download = $false
            production_build = $false
            link = $false
            persistent_artifacts = $false
            stage = $false
            install = $false
            activate = $false
            guest_execution = $false
            renderer_selection = $false
            capability_advertisement = $false
            unreviewed_generator_execution = $false
        }
    }

    $json = ($evidence | ConvertTo-Json -Depth 100).Replace("`r`n", "`n")
    if ($json.Contains("`r")) { throw 'Evidence JSON contains a lone CR.' }
    $json += "`n"
    Assert-EvidenceNoPrivateText $json @(
        $repoRoot, $proof, $lfCheckout, $crlfCheckout, $mesaSource,
        $msysRoot, $ucrtRoot, $gitRoot, $proofParent, $outputParent
    ) 'Final evidence JSON'
    [byte[]]$jsonBytes = $script:OutputUtf8.GetBytes($json)
    [void](ConvertFrom-GswStrictJsonUtf8Bytes -Bytes $jsonBytes `
        -Source 'generated vkd3d-shader compiler evidence')
    Assert-Vkd3dEvidenceFreshMutationBoundary `
        $outputParent @($output, $partialOutput) `
        'evidence-output mutation boundary'
    $partialStream = [IO.File]::Open(
        $partialOutput,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    $partialCreated = $true
    try {
        $createdPartialIdentity = Get-Vkd3dEvidenceHandleIdentity `
            $partialStream.SafeFileHandle 'new partial compiler evidence' `
            16777216
        $partialFileIdentity = $createdPartialIdentity.file_identity
        $partialStream.Write($jsonBytes, 0, $jsonBytes.Length)
        $partialStream.Flush($true)
        $partialIdentity = Get-Vkd3dEvidenceHandleIdentity `
            $partialStream.SafeFileHandle 'partial compiler evidence' `
            16777216
        $partialExpectedBytes = [UInt64]$partialIdentity.bytes
        $partialExpectedSha256 = [string]$partialIdentity.sha256
    }
    finally { $partialStream.Dispose() }
    if ([UInt64]$partialIdentity.bytes -ne [UInt64]$jsonBytes.Length -or
        [string]$partialIdentity.sha256 -cne
            (Get-Vkd3dEvidenceSha256 $jsonBytes) -or
        [string]$partialIdentity.file_identity -cne $partialFileIdentity) {
        throw 'Partial compiler evidence changed while written.'
    }
    [IO.File]::Move($partialOutput, $output, $false)
    $finalCreated = $true
    $partialCreated = $false
    $finalHandle = Open-Vkd3dEvidenceStableHandle `
        $output 'compiler evidence'
    try {
        $finalIdentity = Get-Vkd3dEvidenceHandleIdentity `
            $finalHandle 'compiler evidence' 16777216
    }
    finally { $finalHandle.Dispose() }
    if ([UInt64]$finalIdentity.bytes -ne [UInt64]$jsonBytes.Length -or
        [string]$finalIdentity.sha256 -cne [string]$partialIdentity.sha256 -or
        [string]$finalIdentity.file_identity -cne $partialFileIdentity -or
        [IO.File]::Exists($partialOutput) -or
        [IO.Directory]::Exists($partialOutput)) {
        throw 'Final compiler evidence failed atomic promotion validation.'
    }
    $outputWritten = $true
    Write-Output (
        'Wrote compile-proven vkd3d-shader evidence: source={0}, generated={1}, commands={2}, dependencies={3}, objects={4}, sha256={5}.' -f
        $sourceEvidence.Count, $generatedDefinitions.Count, $unitOrder.Count,
        $dependencySets.lf.Rows.Count, $unitOrder.Count, $finalIdentity.sha256
    )
}
catch {
    $primaryFailure = $_.Exception
}
finally {
    $cleanupFailures = [Collections.Generic.List[Exception]]::new()
    if ($null -ne $proofRootHandle -or $null -ne $ownerMarkerHandle) {
        $proofHandlesUsable = $null -ne $proofRootHandle -and
            $null -ne $ownerMarkerHandle -and
            -not $proofRootHandle.IsClosed -and
            -not $proofRootHandle.IsInvalid -and
            -not $ownerMarkerHandle.IsClosed -and
            -not $ownerMarkerHandle.IsInvalid -and
            -not [string]::IsNullOrWhiteSpace($ownerToken)
        if ($proofHandlesUsable) {
            try {
                Remove-Vkd3dEvidenceOwnedTree $proof $ownerToken `
                    -RootHandle $proofRootHandle `
                    -OwnerMarkerHandle $ownerMarkerHandle
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        else {
            $cleanupFailures.Add([InvalidOperationException]::new(
                'Proof ownership handles are incomplete; recursive cleanup refused.'
            ))
        }
        if ($null -ne $ownerMarkerHandle -and
            -not $ownerMarkerHandle.IsClosed) {
            $ownerMarkerHandle.Dispose()
        }
        if ($null -ne $proofRootHandle -and
            -not $proofRootHandle.IsClosed) {
            $proofRootHandle.Dispose()
        }
        $ownerMarkerHandle = $null
        $proofRootHandle = $null
        $ownerToken = $null
    }
    if ($partialCreated) {
        if ([string]::IsNullOrWhiteSpace($partialFileIdentity)) {
            $cleanupFailures.Add([InvalidOperationException]::new(
                'Partial compiler evidence lacks an owned file identity; cleanup refused.'
            ))
        }
        else {
            try {
                Remove-Vkd3dEvidenceOwnedLeaf `
                    $outputParent $partialOutput `
                    'partial compiler evidence' `
                    -ExpectedBytes $partialExpectedBytes `
                    -ExpectedSha256 $partialExpectedSha256 `
                    -ExpectedFileIdentity $partialFileIdentity
                $partialCreated = $false
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }
    }
    if ($finalCreated -and -not $outputWritten) {
        try {
            Remove-Vkd3dEvidenceOwnedLeaf `
                $outputParent $output 'compiler evidence' `
                -ExpectedBytes $partialExpectedBytes `
                -ExpectedSha256 $partialExpectedSha256 `
                -ExpectedFileIdentity $partialFileIdentity
            $finalCreated = $false
        }
        catch { $cleanupFailures.Add($_.Exception) }
    }
    if ($cleanupFailures.Count -gt 0) {
        if ($null -ne $primaryFailure) {
            $combinedFailure = New-Vkd3dEvidenceCombinedFailure `
                $primaryFailure `
                ([Exception[]]$cleanupFailures.ToArray()) `
                $cleanupPrivateRoots
            throw $combinedFailure
        }
        $cleanupFailure = New-Vkd3dEvidenceCleanupFailure `
            ([Exception[]]$cleanupFailures.ToArray()) `
            $cleanupPrivateRoots
        throw $cleanupFailure
    }
}

if ($null -ne $primaryFailure) {
    if ($primaryFailure -is [AggregateException] -and
        $primaryFailure.Message.StartsWith(
            'Compiler evidence collection and cleanup both failed.',
            [StringComparison]::Ordinal
        )) {
        Assert-Vkd3dEvidenceNoPrivatePathText `
            $primaryFailure.ToString() 'combined compiler evidence failure'
        throw $primaryFailure
    }
    $primaryText = Get-Vkd3dEvidenceSanitizedFailureText `
        -Exception $primaryFailure -PrivateRoots $cleanupPrivateRoots
    throw [InvalidOperationException]::new(
        "Compiler evidence collection failed: $primaryText"
    )
}

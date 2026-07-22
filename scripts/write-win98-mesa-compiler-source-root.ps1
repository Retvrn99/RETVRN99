# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('SourceRoot')]
    [string]$LfSourceRoot,
    [Parameter(Mandatory = $true)][string]$CrlfSourceRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$ClosureFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'mesa-compiler-source-root.ps1')
. (Join-Path $PSScriptRoot 'mesa-compiler-dependency-roles.ps1')

function Assert-MaterializedPath {
    param([string]$RelativePath)

    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains('\') -or
        $RelativePath -match '(^|/)\.\.?(/|$)') {
        throw "Unsafe materialized path '$RelativePath'."
    }
}

function Get-CheckoutGitText {
    param([string]$Root, [string[]]$Arguments, [string]$Name)

    $output = @(& git -C $Root @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
    return ($output -join "`n").Trim()
}

function Assert-CleanCheckout {
    param([string]$Root, [string]$ExpectedCommit, [string]$Name)

    $top = [IO.Path]::GetFullPath((Get-CheckoutGitText $Root `
        @('rev-parse', '--show-toplevel') "$Name root"))
    if ($top.TrimEnd([char[]]'\/') -cne $Root.TrimEnd([char[]]'\/')) {
        throw "$Name must be the checkout root."
    }
    $commit = Get-CheckoutGitText $Root @('rev-parse', 'HEAD') "$Name HEAD"
    if ($commit -cne $ExpectedCommit) {
        throw "$Name is not at owning commit $ExpectedCommit."
    }
    $status = Get-CheckoutGitText $Root `
        @('status', '--porcelain=v1', '--untracked-files=no') "$Name status"
    if ($status.Length -ne 0) { throw "$Name has tracked changes." }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$driversRoot = Join-Path $repoRoot 'drivers\win98'
if ([string]::IsNullOrWhiteSpace($ClosureFile)) {
    $ClosureFile = Join-Path $driversRoot 'mesa-compiler-closure.json'
}
$lf = [IO.Path]::GetFullPath($LfSourceRoot)
$crlf = [IO.Path]::GetFullPath($CrlfSourceRoot)
$output = [IO.Path]::GetFullPath($OutputRoot)
$outputParent = [IO.Path]::GetDirectoryName($output)
if ($lf -ceq $crlf) { throw 'LF and CRLF checkout roots must be distinct.' }
if (-not (Test-Path -LiteralPath $lf -PathType Container) -or
    -not (Test-Path -LiteralPath $crlf -PathType Container) -or
    -not (Test-Path -LiteralPath $outputParent -PathType Container) -or
    (Test-Path -LiteralPath $output)) {
    throw 'Materialized source inputs, parent, or fresh-output contract failed.'
}
$closure = (Read-GswStrictJsonFileSnapshot -Path $ClosureFile `
    -Name 'Mesa compiler closure' -MaximumBytes ([UInt64]4194304)).Value
$plan = (Read-GswStrictJsonFileSnapshot `
    -Path (Join-Path $driversRoot 'mesa-gsw-direct-build-plan.json') `
    -Name 'Mesa direct-build plan' -MaximumBytes ([UInt64]2097152)).Value
$component = (Read-GswStrictJsonFileSnapshot `
    -Path (Join-Path $driversRoot 'component-closures\mesa9x-23.1.x.json') `
    -Name 'Mesa component closure' -MaximumBytes ([UInt64]4194304)).Value

if ($component.schema -ne 2 -or $component.status -cne 'ready' -or
    $component.owning_commit -cne
        '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f' -or
    $component.files.Count -ne 1687) {
    throw 'Mesa component closure is not the ready 1,687-file closure.'
}
Assert-CleanCheckout $lf $component.owning_commit 'LF checkout'
Assert-CleanCheckout $crlf $component.owning_commit 'CRLF checkout'

$componentFiles = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
$dependencyPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($file in $component.files) {
    $path = [string]$file.relative_path
    $componentFiles.Add($path, $file)
    if (@($file.roles) -ccontains 'compiler-dependency') {
        [void]$dependencyPaths.Add($path)
    }
}
if ($dependencyPaths.Count -ne 652) {
    throw 'Ready Mesa component closure must contain 652 compiler dependencies.'
}

$selected = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($unit in @($plan.units | Where-Object source_kind -ceq 'upstream')) {
    $path = [string]$unit.relative_path
    if (-not $componentFiles.ContainsKey($path) -or
        @($componentFiles[$path].roles) -cnotcontains 'source-unit') {
        throw "Upstream source '$path' is absent from the source-unit closure."
    }
    $selected.Add($path, $componentFiles[$path])
}
$dependencyRoles = Resolve-MesaCompilerDependencyRoles `
    @($closure.evidence.headers)
$shadowedDependency = $componentFiles[$dependencyRoles.ShadowedPath]
Assert-MesaShadowedCompilerDependencyRole $shadowedDependency
foreach ($path in $dependencyRoles.RolePaths) {
    if (-not $dependencyPaths.Contains($path) -or
        -not $componentFiles.ContainsKey($path)) {
        throw "Source dependency '$path' lacks compiler-dependency closure."
    }
    if ($selected.ContainsKey($path)) {
        throw "Source dependency '$path' overlaps a primary source unit."
    }
    $selected.Add($path, $componentFiles[$path])
}
foreach ($path in $dependencyPaths) {
    if ($dependencyRoles.RolePaths -cnotcontains $path) {
        throw "Compiler closure lacks dependency-role file '$path'."
    }
}
if ($selected.Count -ne 1489) {
    throw "Exact compiler source root requires 1,489 files, observed $($selected.Count)."
}

$temporary = Join-Path $outputParent (
    '.retvrn99-mesa-compiler-source-' + [Guid]::NewGuid().ToString('N')
)
$sawIndependentEolPair = $false
try {
    [void][IO.Directory]::CreateDirectory($temporary)
    $paths = @($selected.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    foreach ($relativePath in $paths) {
        Assert-MaterializedPath $relativePath
        $expected = $selected[$relativePath]
        $lfObservation = ConvertTo-MesaCanonicalSourceObservation `
            -Path (Join-Path $lf ($relativePath.Replace('/', '\'))) `
            -ExpectedBytes ([int64]$expected.bytes) `
            -ExpectedSha256 ([string]$expected.sha256) -RequireLf $false `
            -Name "LF checkout file '$relativePath'"
        $crlfObservation = ConvertTo-MesaCanonicalSourceObservation `
            -Path (Join-Path $crlf ($relativePath.Replace('/', '\'))) `
            -ExpectedBytes ([int64]$expected.bytes) `
            -ExpectedSha256 ([string]$expected.sha256) -RequireLf $false `
            -Name "CRLF checkout file '$relativePath'"
        $pair = Resolve-MesaCanonicalSourcePair `
            -LfObservation $lfObservation -CrlfObservation $crlfObservation `
            -Name "Checkout file '$relativePath'"
        [byte[]]$lfBytes = $pair.Bytes
        if (-not $lfObservation.SawCrlf -and $crlfObservation.SawCrlf) {
            $sawIndependentEolPair = $true
        }
        $target = Join-Path $temporary ($relativePath.Replace('/', '\'))
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllBytes($target, $lfBytes)
    }
    if (-not $sawIndependentEolPair) {
        throw 'The two checkouts supplied no independent LF/CRLF observation.'
    }
    [IO.Directory]::Move($temporary, $output)
}
finally {
    if ([IO.Directory]::Exists($temporary)) {
        [IO.Directory]::Delete($temporary, $true)
    }
}
Write-Output (
    "Materialized exact 1,489-file canonical-LF Mesa compiler source root " +
    "from clean LF and CRLF checkouts at '$output'."
)

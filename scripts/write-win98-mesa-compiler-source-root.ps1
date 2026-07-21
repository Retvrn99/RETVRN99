# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$ClosureFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')

function Get-MaterializedSha256 {
    param([byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function Assert-MaterializedPath {
    param([string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains('\') -or
        $RelativePath -match '(^|/)\.\.?(/|$)') {
        throw "Unsafe materialized path '$RelativePath'."
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$driversRoot = Join-Path $repoRoot 'drivers\win98'
if ([string]::IsNullOrWhiteSpace($ClosureFile)) {
    $ClosureFile = Join-Path $driversRoot 'mesa-compiler-closure.json'
}
$source = [IO.Path]::GetFullPath($SourceRoot)
$output = [IO.Path]::GetFullPath($OutputRoot)
$outputParent = [IO.Path]::GetDirectoryName($output)
if (-not (Test-Path -LiteralPath $source -PathType Container) -or
    -not (Test-Path -LiteralPath $outputParent -PathType Container) -or
    (Test-Path -LiteralPath $output)) {
    throw 'Materialized source input, parent, or fresh-output contract failed.'
}
$closure = (Read-GswStrictJsonFileSnapshot -Path $ClosureFile `
    -Name 'Mesa compiler closure' -MaximumBytes ([UInt64]2097152)).Value
$plan = (Read-GswStrictJsonFileSnapshot `
    -Path (Join-Path $driversRoot 'mesa-gsw-direct-build-plan.json') `
    -Name 'Mesa direct-build plan' -MaximumBytes ([UInt64]2097152)).Value
$component = (Read-GswStrictJsonFileSnapshot `
    -Path (Join-Path $driversRoot 'component-closures\mesa9x-23.1.x.json') `
    -Name 'Mesa component closure' -MaximumBytes ([UInt64]2097152)).Value

$componentFiles = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($file in $component.files) {
    $componentFiles.Add([string]$file.relative_path, $file)
}
$selected = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($unit in @($plan.units | Where-Object source_kind -ceq 'upstream')) {
    $path = [string]$unit.relative_path
    if (-not $componentFiles.ContainsKey($path)) {
        throw "Upstream source '$path' is absent from the component closure."
    }
    $file = $componentFiles[$path]
    $selected.Add($path, [pscustomobject]@{
        bytes = [int64]$file.bytes
        sha256 = [string]$file.sha256
        mode = 'canonical-lf'
    })
}
foreach ($header in @($closure.evidence.headers | Where-Object root -ceq 'source')) {
    $path = [string]$header.relative_path
    if ($selected.ContainsKey($path)) {
        throw "Source dependency '$path' overlaps a primary source unit."
    }
    $selected.Add($path, [pscustomobject]@{
        bytes = [int64]$header.bytes
        sha256 = [string]$header.sha256
        mode = 'observed-worktree'
    })
}
if ($selected.Count -ne 1489) {
    throw "Exact compiler source root requires 1,489 files, observed $($selected.Count)."
}

$temporary = Join-Path $outputParent (
    '.retvrn99-mesa-compiler-source-' + [Guid]::NewGuid().ToString('N')
)
try {
    [void][IO.Directory]::CreateDirectory($temporary)
    $paths = @($selected.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    foreach ($relativePath in $paths) {
        Assert-MaterializedPath $relativePath
        $sourcePath = Join-Path $source ($relativePath.Replace('/', '\'))
        $item = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Source '$relativePath' is not one ordinary file."
        }
        $bytes = [IO.File]::ReadAllBytes($item.FullName)
        $expected = $selected[$relativePath]
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        if ($text.Replace("`r`n", '').Contains("`r")) {
            throw "Source '$relativePath' contains an isolated carriage return."
        }
        $normalized = [Text.UTF8Encoding]::new($false).GetBytes(
            $text.Replace("`r`n", "`n")
        )
        if ($expected.mode -ceq 'canonical-lf') {
            if ($bytes.Length -eq $expected.bytes -and
                (Get-MaterializedSha256 $bytes) -ceq $expected.sha256) {
                $content = $bytes
            }
            elseif ($normalized.Length -eq $expected.bytes -and
                (Get-MaterializedSha256 $normalized) -ceq $expected.sha256) {
                $content = $normalized
            }
            else {
                throw "Source '$relativePath' changed before materialization."
            }
        }
        else {
            if ($bytes.Length -ne $expected.bytes -or
                (Get-MaterializedSha256 $bytes) -cne $expected.sha256) {
                throw "Dependency '$relativePath' changed before materialization."
            }
            $content = $bytes
        }
        $target = Join-Path $temporary ($relativePath.Replace('/', '\'))
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllBytes($target, $content)
    }
    [IO.Directory]::Move($temporary, $output)
}
finally {
    if ([IO.Directory]::Exists($temporary)) {
        [IO.Directory]::Delete($temporary, $true)
    }
}
Write-Output "Materialized exact 1,489-file Mesa compiler source root at '$output'."

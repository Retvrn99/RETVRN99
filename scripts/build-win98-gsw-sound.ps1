# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$ToolchainRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$BuildPlan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'strict-tsv.ps1')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$soundRoot = Join-Path $repoRoot 'drivers\win98\gsw-sound'
if ([string]::IsNullOrWhiteSpace($BuildPlan)) {
    $BuildPlan = Join-Path $soundRoot 'gsw-sound-build-plan.json'
}
$script:MaximumPlannedFiles = 128
$script:PackageNames = @('GSWSOUND.INF', 'GSWSOUND.DRV', 'GSWSOUND.VXD')

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-StrictJson {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Label = 'JSON')
    try {
        return Read-GswStrictJsonFile -Path $Path -Name $Label -MaximumBytes 4194304
    }
    catch { throw "Malformed $Label`: $($_.Exception.Message)" }
}

function Assert-RegularFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is absent: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a reparse point: $Path"
    }
    return $item
}

function Assert-FileRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Record.bytes -isnot [ValueType] -or [long]$Record.bytes -lt 0) {
        throw "$Label has an invalid byte count."
    }
    if ($Record.sha256 -isnot [string] -or $Record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Label has an invalid SHA-256 digest."
    }
    $item = Assert-RegularFile $Path $Label
    if ($item.Length -ne [long]$Record.bytes) {
        throw "$Label byte count differs. Expected $($Record.bytes), observed $($item.Length)."
    }
    $actual = Get-Sha256 $Path
    if ($actual -cne [string]$Record.sha256) {
        throw "$Label SHA-256 differs. Expected $($Record.sha256), observed $actual."
    }
}

function Get-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($RelativePath -isnot [string] -or [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains('\')) {
        throw "Unsafe relative path '$RelativePath' in $Label."
    }
    foreach ($component in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or $component -in @('.', '..') -or
            $component -match '[\x00-\x1f:*?"<>|]' -or $component.EndsWith('.') -or
            $component.EndsWith(' ')) {
            throw "Unsafe path component '$component' in $Label."
        }
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath.Replace('/', '\')))
    $prefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Relative path '$RelativePath' escapes $Label root."
    }
    return $path
}

function Copy-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $parent = [IO.Path]::GetDirectoryName($Destination)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    [IO.File]::Copy($Source, $Destination, $false)
}

function Get-EnvironmentSnapshot {
    param([Parameter(Mandatory = $true)][string[]]$Names)
    $snapshot = @{}
    foreach ($name in $Names) {
        $entry = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        $snapshot[$name] = if ($null -eq $entry) { $null } else { [string]$entry.Value }
    }
    return $snapshot
}

function Restore-EnvironmentSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)
    foreach ($name in $Snapshot.Keys) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        if ($null -ne $Snapshot[$name]) { Set-Item -LiteralPath "Env:$name" -Value $Snapshot[$name] }
    }
}

$planPath = [IO.Path]::GetFullPath($BuildPlan)
Assert-RegularFile $planPath 'GSW-Sound build plan' | Out-Null
$plan = Read-StrictJson $planPath 'GSW-Sound build plan JSON'
if ($plan._spdx -cne 'GPL-3.0-only' -or $plan.schema -ne 1 -or
    $plan.status -cne 'ready-for-manual-install') {
    throw 'The GSW-Sound build plan is not ready for manual installation.'
}
$sourceFiles = @($plan.source_files)
$repositoryFiles = @($plan.repository_files)
$outputs = @($plan.outputs)
if ($sourceFiles.Count -lt 1 -or $sourceFiles.Count -gt $script:MaximumPlannedFiles -or
    $repositoryFiles.Count -lt 1 -or $repositoryFiles.Count -gt $script:MaximumPlannedFiles -or
    $outputs.Count -ne $script:PackageNames.Count) {
    throw 'The GSW-Sound build plan has an unsupported file count.'
}

$seenSource = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($record in $sourceFiles) {
    $source = Get-SafeRelativePath $soundRoot $record.relative_path 'sound source'
    if (-not $seenSource.Add([string]$record.relative_path)) {
        throw "Duplicate planned source '$($record.relative_path)'."
    }
    Assert-FileRecord $source $record "Planned source '$($record.relative_path)'"
}
$seenRepository = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($record in $repositoryFiles) {
    $source = Get-SafeRelativePath $repoRoot $record.relative_path 'repository metadata'
    if (-not $seenRepository.Add([string]$record.relative_path)) {
        throw "Duplicate repository metadata '$($record.relative_path)'."
    }
    Assert-FileRecord $source $record "Repository metadata '$($record.relative_path)'"
}

$outputByName = @{}
foreach ($record in $outputs) {
    if ($record.name -isnot [string] -or $script:PackageNames -cnotcontains $record.name -or
        $outputByName.ContainsKey($record.name)) {
        throw "Unexpected or duplicate package output '$($record.name)'."
    }
    if ($record.bytes -isnot [ValueType] -or [long]$record.bytes -lt 1 -or
        $record.sha256 -isnot [string] -or $record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid package output record '$($record.name)'."
    }
    $outputByName[$record.name] = $record
}

$interfaceRecord = @($repositoryFiles | Where-Object {
    $_.relative_path -ceq 'drivers/win98/gsw-sound/interface-inputs.lock.json'
})
if ($interfaceRecord.Count -ne 1) { throw 'The build plan must lock the Interface input lock exactly once.' }
$interfaceLockPath = Join-Path $repoRoot 'drivers\win98\gsw-sound\interface-inputs.lock.json'
& (Join-Path $PSScriptRoot 'verify-win98-gsw-sound-interfaces.ps1') `
    -SourceRoot $SourceRoot -ToolchainRoot $ToolchainRoot -InterfaceLock $interfaceLockPath

$toolchainLockPath = Join-Path $repoRoot 'drivers\win98\toolchain.lock.json'
$toolchainLock = Read-StrictJson $toolchainLockPath 'Open Watcom lock JSON'
$watcomRoot = Get-SafeRelativePath ([IO.Path]::GetFullPath($ToolchainRoot)) `
    $toolchainLock.extracted.relative_path 'toolchain'
$wmake = Join-Path $watcomRoot 'binnt\wmake.exe'
Assert-RegularFile $wmake 'Pinned Open Watcom wmake' | Out-Null
$wdump = Join-Path $watcomRoot 'binnt\wdump.exe'
Assert-RegularFile $wdump 'Pinned Open Watcom wdump' | Out-Null

$upstreamHeader = @(
    'name', 'source_directory', 'repository', 'commit', 'upstream_license',
    'disposition', 'closure_manifest', 'closure_manifest_sha256', 'scope'
)
$upstreamRows = @(Read-StrictTsvFile `
    -Path (Join-Path $repoRoot 'drivers\win98\upstream.lock.tsv') `
    -ExpectedHeader $upstreamHeader -Name 'Windows 98 upstream lock' `
    -MaximumBytes 1048576 -MaximumRows 256 -MaximumLineBytes 16384 `
    -MaximumPhysicalLines 1024)
$interfaceLock = Read-StrictJson $interfaceLockPath 'GSW-Sound Interface lock JSON'
$sourceRows = @($upstreamRows | Where-Object { $_.name -ceq $interfaceLock.vmm_interface.source_name })
if ($sourceRows.Count -ne 1) { throw 'The Interface checkout has no unique upstream source row.' }
$checkout = Join-Path ([IO.Path]::GetFullPath($SourceRoot)) $sourceRows[0].source_directory

$outputPath = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $outputPath) { throw "Output root must be absent: $outputPath" }
$outputParent = [IO.Path]::GetDirectoryName($outputPath)
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "Output parent must already exist: $outputParent"
}
$parentItem = Get-Item -LiteralPath $outputParent -Force
if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Output parent must not be a reparse point.'
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('retvrn99-gswsound-' + [Guid]::NewGuid().ToString('N'))
$staging = Join-Path $outputParent ('.gsw-sound-stage-' + [Guid]::NewGuid().ToString('N'))
$environmentNames = @('WATCOM', 'PATH', 'EDPATH', 'INCLUDE', 'LIB', 'WCL', 'WCC',
    'WCC386', 'WLINK', 'WLIB', 'WRC', 'WMAKE', 'MAKEFLAGS')
$environment = Get-EnvironmentSnapshot $environmentNames
try {
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $buildOutputs = @{}
    foreach ($buildName in @('build-a', 'build-b')) {
        $buildRoot = Join-Path $scratch $buildName
        $buildSource = Join-Path $buildRoot 'source'
        $buildOutput = Join-Path $buildRoot 'output'
        [IO.Directory]::CreateDirectory($buildSource) | Out-Null
        foreach ($record in $sourceFiles) {
            $source = Get-SafeRelativePath $soundRoot $record.relative_path 'sound source'
            $destination = Get-SafeRelativePath $buildSource $record.relative_path 'private build source'
            Copy-VerifiedFile $source $destination
        }
        foreach ($record in @($interfaceLock.vmm_interface.files)) {
            $source = Get-SafeRelativePath $checkout $record.source_relative_path 'Interface checkout'
            Assert-FileRecord $source $record "Interface input '$($record.source_relative_path)'"
            $destination = Get-SafeRelativePath $buildSource $record.derived_relative_path 'private build source'
            Copy-VerifiedFile $source $destination
        }

        $env:WATCOM = $watcomRoot
        $env:EDPATH = Join-Path $watcomRoot 'eddat'
        $env:INCLUDE = @(
            (Join-Path $watcomRoot 'h\nt'), (Join-Path $watcomRoot 'h\win'),
            (Join-Path $watcomRoot 'h')
        ) -join ';'
        $env:LIB = @(
            (Join-Path $watcomRoot 'lib386'), (Join-Path $watcomRoot 'lib386\nt'),
            (Join-Path $watcomRoot 'lib286'), (Join-Path $watcomRoot 'lib286\win')
        ) -join ';'
        $env:PATH = @(
            (Join-Path $watcomRoot 'binnt'), (Join-Path $watcomRoot 'binw'),
            (Join-Path $env:SystemRoot 'System32'), $env:SystemRoot
        ) -join ';'
        foreach ($name in @('WCL', 'WCC', 'WCC386', 'WLINK', 'WLIB', 'WRC', 'WMAKE', 'MAKEFLAGS')) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }

        Push-Location $buildSource
        try {
            & $wmake -f gswsound.mak "WATCOM=$watcomRoot" "GSW_SOUND_OUT=$buildOutput"
            if ($LASTEXITCODE -ne 0) { throw "$buildName failed with wmake exit code $LASTEXITCODE." }
        }
        finally { Pop-Location }
        & (Join-Path $PSScriptRoot 'normalize-win98-vxd-ddb-entry.ps1') `
            -Path (Join-Path $buildOutput 'GSWSOUND.VXD')
        & (Join-Path $PSScriptRoot 'normalize-win16-version-date.ps1') `
            -Path (Join-Path $buildOutput 'GSWSOUND.DRV')

        $unexpected = @(Get-ChildItem -LiteralPath $buildOutput -File | Where-Object {
            $script:PackageNames -cnotcontains $_.Name
        })
        if ($unexpected.Count -ne 0) { throw "$buildName emitted an unexpected package-root file." }
        foreach ($name in $script:PackageNames) {
            $record = $outputByName[$name]
            $artifact = Join-Path $buildOutput $name
            Assert-FileRecord $artifact $record "$buildName output '$name'"
        }
        & (Join-Path $PSScriptRoot 'verify-win98-gsw-sound-binaries.ps1') `
            -DriverPath (Join-Path $buildOutput 'GSWSOUND.DRV') `
            -VxdPath (Join-Path $buildOutput 'GSWSOUND.VXD') -WdumpPath $wdump
        $buildOutputs[$buildName] = $buildOutput
    }

    foreach ($name in $script:PackageNames) {
        $first = Join-Path $buildOutputs['build-a'] $name
        $second = Join-Path $buildOutputs['build-b'] $name
        $firstHash = Get-Sha256 $first
        $secondHash = Get-Sha256 $second
        if ($firstHash -cne $secondHash -or
            (Get-Item -LiteralPath $first).Length -ne (Get-Item -LiteralPath $second).Length) {
            throw "Twin-build comparison differs for '$name'."
        }
    }

    if (Test-Path -LiteralPath $staging) { throw "Unexpected staging collision: $staging" }
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    foreach ($name in $script:PackageNames) {
        Copy-VerifiedFile (Join-Path $buildOutputs['build-a'] $name) (Join-Path $staging $name)
    }
    if (Test-Path -LiteralPath $outputPath) { throw "Output root appeared during build: $outputPath" }
    Move-Item -LiteralPath $staging -Destination $outputPath
    foreach ($name in $script:PackageNames) {
        $artifact = Join-Path $outputPath $name
        $record = $outputByName[$name]
        Assert-FileRecord $artifact $record "Published output '$name'"
        Write-Output ("{0}`t{1}`t{2}" -f $name, $record.bytes, $record.sha256)
    }
    Write-Output "Manual-install package built reproducibly: $outputPath"
}
finally {
    Restore-EnvironmentSnapshot $environment
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

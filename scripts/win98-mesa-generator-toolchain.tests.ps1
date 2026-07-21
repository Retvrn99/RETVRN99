# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$PackageSourceRoot,
    [string]$MesaSourceCheckout,
    [string]$NameFilter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:ExpectedRepository = 'https://github.com/JHRobotics/mesa9x.git'
$script:ExpectedCommit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$script:Utf8 = New-Object Text.UTF8Encoding($false, $true)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Verifier = Join-Path $PSScriptRoot `
    'verify-win98-mesa-generator-toolchain.ps1'
$script:CanonicalLock = Join-Path $repoRoot `
    'drivers\win98\mesa-generator-toolchain-lock.json'
$script:CanonicalSchema = Join-Path $repoRoot `
    'drivers\win98\mesa-generator-toolchain-lock.schema.json'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
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

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    if (-not [string]::IsNullOrWhiteSpace($NameFilter) -and
        $Name -notlike "*$NameFilter*") {
        return
    }
    try {
        & $Body
        Write-Host "PASS: $Name"
    }
    catch {
        $script:Failures++
        [Console]::Error.WriteLine("FAIL: $Name`n  $($_.Exception.Message)")
    }
}

function Invoke-TestGit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $savedErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorAction
    }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Restore-TestEnvironmentVariable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Value
    )

    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function New-DirectoryReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $kind = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        'Junction'
    }
    else {
        'SymbolicLink'
    }
    New-Item -ItemType $kind -Path $Path -Target $Target | Out-Null
}

function Resolve-PackageSourceRoot {
    if (-not [string]::IsNullOrWhiteSpace($PackageSourceRoot)) {
        return [IO.Path]::GetFullPath($PackageSourceRoot)
    }
    $environmentPath = [Environment]::GetEnvironmentVariable(
        'RETVRN99_MESA_PACKAGE_ROOT',
        'Process'
    )
    $candidates = @(
        $environmentPath,
        (Join-Path $repoRoot '.scratch\graphics-source-tools\packages'),
        'D:\dev\RETVRN99\.scratch\graphics-source-tools\packages'
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Container)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'The read-only Mesa generator package cache is unavailable.'
}

function Resolve-MesaSourceCheckout {
    if (-not [string]::IsNullOrWhiteSpace($MesaSourceCheckout)) {
        return [IO.Path]::GetFullPath($MesaSourceCheckout)
    }
    $environmentPath = [Environment]::GetEnvironmentVariable(
        'RETVRN99_MESA9X_CHECKOUT',
        'Process'
    )
    foreach ($candidate in @($environmentPath, 'D:\src\retvrn99-win98\mesa9x')) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Container)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'The pinned local Mesa9x checkout is unavailable.'
}

function Copy-PackageFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination | Out-Null
    foreach ($entry in Get-ChildItem -LiteralPath $Source -Force) {
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($entry.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "Package cache contains non-file entry '$($entry.Name)'."
        }
        [IO.File]::Copy(
            $entry.FullName,
            (Join-Path $Destination $entry.Name),
            $false
        )
    }
}

function Remove-TestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = [IO.Path]::GetFullPath(
        [IO.Path]::GetTempPath()
    ).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith(
            $temporaryRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        (Split-Path -Leaf $resolved) -notlike
            'retvrn99-mesa-generator-toolchain-*') {
        throw "Refusing to remove unsafe test root '$resolved'."
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function Reset-TestMetadata {
    [IO.File]::Copy($script:CanonicalLock, $script:LockPath, $true)
    [IO.File]::Copy($script:CanonicalSchema, $script:SchemaPath, $true)
}

function Read-CanonicalLockObject {
    return [IO.File]::ReadAllText($script:CanonicalLock) | ConvertFrom-Json
}

function Write-TestLockObject {
    param([Parameter(Mandatory = $true)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($script:LockPath, $json + "`n", $script:Utf8)
}

function Invoke-Verification {
    param(
        [string]$LockFile = $script:LockPath,
        [string]$Packages = $script:PackageRoot,
        [string]$Checkout = $script:MesaCheckout,
        [switch]$WithoutPolicyAudit,
        [scriptblock]$BeforeFinalMetadataCheck
    )

    $arguments = @{
        LockFile = $LockFile
        PackageRoot = $Packages
        MesaCheckout = $Checkout
    }
    if (-not $WithoutPolicyAudit) {
        $arguments.PolicyAudit = $true
    }
    if ($null -ne $BeforeFinalMetadataCheck) {
        $arguments.BeforeFinalMetadataCheck = $BeforeFinalMetadataCheck
    }
    return & $script:Verifier @arguments
}

function Assert-ExpectedPolicyAudit {
    param([Parameter(Mandatory = $true)][object[]]$Output)

    Assert-Equal $Output.Count 1 'PolicyAudit emitted an unexpected record count.'
    Assert-Equal $Output[0] (
        'Policy-audited blocked Mesa generator toolchain lock: ' +
        'packages=26 required=24 reserved=2 signatures_present=26 ' +
        'signatures_missing=0 proofs=0/6; unusable.'
    )
}

if (-not (Test-Path -LiteralPath $script:Verifier -PathType Leaf) -or
    -not (Test-Path -LiteralPath $script:CanonicalLock -PathType Leaf) -or
    -not (Test-Path -LiteralPath $script:CanonicalSchema -PathType Leaf)) {
    throw 'Mesa generator toolchain verifier metadata is incomplete.'
}
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for the local Mesa generator toolchain tests.'
}

$packageSource = Resolve-PackageSourceRoot
$mesaSource = Resolve-MesaSourceCheckout
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-generator-toolchain-{0}' -f [Guid]::NewGuid().ToString('N')
)
$metadataRoot = Join-Path $script:TestRoot 'metadata'
$script:PackageRoot = Join-Path $script:TestRoot 'packages'
$script:MesaCheckout = Join-Path $script:TestRoot 'mesa9x'
$script:LockPath = Join-Path $metadataRoot 'mesa-generator-toolchain-lock.json'
$script:SchemaPath = Join-Path $metadataRoot `
    'mesa-generator-toolchain-lock.schema.json'

New-Item -ItemType Directory -Path $metadataRoot -Force | Out-Null
try {
    Reset-TestMetadata
    Copy-PackageFixture -Source $packageSource -Destination $script:PackageRoot
    $emptyHooks = Join-Path $script:TestRoot 'empty-git-hooks'
    New-Item -ItemType Directory -Path $emptyHooks | Out-Null
    Invoke-TestGit @(
        '-c', "init.templateDir=$emptyHooks", 'clone', '--shared',
        '--no-checkout', $mesaSource, $script:MesaCheckout
    ) | Out-Null
    Invoke-TestGit @(
        '-C', $script:MesaCheckout, 'config', 'core.hooksPath', $emptyHooks
    ) | Out-Null
    Invoke-TestGit @('-C', $script:MesaCheckout, 'config', 'core.autocrlf', 'false') |
        Out-Null
    Invoke-TestGit @('-C', $script:MesaCheckout, 'config', 'core.eol', 'lf') |
        Out-Null
    Invoke-TestGit @(
        '-C', $script:MesaCheckout, 'checkout', '--detach', $script:ExpectedCommit
    ) | Out-Null
    Invoke-TestGit @(
        '-C', $script:MesaCheckout, 'remote', 'set-url', 'origin',
        $script:ExpectedRepository
    ) | Out-Null

    Invoke-SelfTest 'Production blocked PolicyAudit returns the exact summary' {
        $output = @(Invoke-Verification)
        Assert-ExpectedPolicyAudit $output
    }

    Invoke-SelfTest 'Inherited Git config cannot override the audited origin' {
        $names = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')
        $saved = @{}
        foreach ($name in $names) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        try {
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', '1', 'Process')
            [Environment]::SetEnvironmentVariable(
                'GIT_CONFIG_KEY_0',
                'remote.origin.url',
                'Process'
            )
            [Environment]::SetEnvironmentVariable(
                'GIT_CONFIG_VALUE_0',
                'https://example.invalid/poisoned-origin.git',
                'Process'
            )
            Assert-ExpectedPolicyAudit @(Invoke-Verification)
        }
        finally {
            foreach ($name in $names) {
                Restore-TestEnvironmentVariable $name $saved[$name]
            }
        }
    }

    Invoke-SelfTest 'Inherited Git repository redirection is ignored' {
        $values = @{
            GIT_COMMON_DIR = $metadataRoot
            GIT_OBJECT_DIRECTORY = $metadataRoot
            GIT_ALTERNATE_OBJECT_DIRECTORIES = $metadataRoot
            GIT_NAMESPACE = 'hostile-namespace'
            GIT_ATTR_SOURCE = 'hostile-attributes'
            GIT_NO_LAZY_FETCH = '0'
        }
        $saved = @{}
        foreach ($name in $values.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        try {
            foreach ($name in $values.Keys) {
                [Environment]::SetEnvironmentVariable(
                    $name,
                    $values[$name],
                    'Process'
                )
            }
            Assert-ExpectedPolicyAudit @(Invoke-Verification)
        }
        finally {
            foreach ($name in $values.Keys) {
                Restore-TestEnvironmentVariable $name $saved[$name]
            }
        }
    }

    Invoke-SelfTest 'Local config include-file injection is rejected' {
        $includePath = Join-Path $script:TestRoot 'hostile-origin.include'
        [IO.File]::WriteAllText(
            $includePath,
            "[remote `"origin`"]`n`turl = https://example.invalid/included.git`n",
            $script:Utf8
        )
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'config', '--local', 'include.path',
            $includePath
        ) | Out-Null
        try {
            Assert-Throws { Invoke-Verification } `
                "forbidden key 'include.path'"
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'config', '--local', '--unset-all',
                'include.path'
            ) | Out-Null
            Remove-Item -LiteralPath $includePath -Force
        }
    }

    Invoke-SelfTest 'Worktree-specific Git config is rejected' {
        $path = Join-Path $script:MesaCheckout '.git\config.worktree'
        try {
            [IO.File]::WriteAllText(
                $path,
                "[remote `"origin`"]`n`turl = https://example.invalid/worktree.git`n",
                $script:Utf8
            )
            Assert-Throws { Invoke-Verification } `
                'cannot use worktree-specific Git config'
        }
        finally {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }

    Invoke-SelfTest 'Partial-clone promisor config is rejected' {
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'config', '--local',
            'remote.origin.promisor', 'true'
        ) | Out-Null
        try {
            Assert-Throws { Invoke-Verification } `
                "forbidden key 'remote.origin.promisor'"
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'config', '--local', '--unset-all',
                'remote.origin.promisor'
            ) | Out-Null
        }
    }

    Invoke-SelfTest 'Local fsmonitor helper is forced off during audit' {
        $markerPath = Join-Path $script:TestRoot 'fsmonitor-invoked.marker'
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            $helperPath = Join-Path $script:TestRoot 'hostile-fsmonitor.cmd'
            $helperText = "@echo off`r`ntype nul > `"$markerPath`"`r`nexit /b 1`r`n"
            $configuredHelper = $helperPath.Replace('\', '/')
        }
        else {
            $helperPath = Join-Path $script:TestRoot 'hostile-fsmonitor.sh'
            $helperText = "#!/bin/sh`n: > '$markerPath'`nexit 1`n"
            $configuredHelper = 'sh ' + $helperPath
        }
        [IO.File]::WriteAllText($helperPath, $helperText, $script:Utf8)
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'config', '--local', 'core.fsmonitor',
            $configuredHelper
        ) | Out-Null
        try {
            Assert-ExpectedPolicyAudit @(Invoke-Verification)
            if (Test-Path -LiteralPath $markerPath) {
                throw 'The hostile fsmonitor helper executed during verification.'
            }
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'config', '--local', '--unset-all',
                'core.fsmonitor'
            ) | Out-Null
            if (Test-Path -LiteralPath $helperPath) {
                Remove-Item -LiteralPath $helperPath -Force
            }
            if (Test-Path -LiteralPath $markerPath) {
                Remove-Item -LiteralPath $markerPath -Force
            }
        }
    }

    Invoke-SelfTest 'Local clean-filter execution is rejected' {
        $markerPath = Join-Path $script:TestRoot 'clean-filter-invoked.marker'
        $attributePath = Join-Path $script:MesaCheckout '.git\info\attributes'
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            $helperPath = Join-Path $script:TestRoot 'hostile-clean-filter.cmd'
            $helperText = "@echo off`r`ntype nul > `"$markerPath`"`r`nexit /b 1`r`n"
            $configuredHelper = $helperPath.Replace('\', '/')
        }
        else {
            $helperPath = Join-Path $script:TestRoot 'hostile-clean-filter.sh'
            $helperText = "#!/bin/sh`n: > '$markerPath'`nexit 1`n"
            $configuredHelper = 'sh ' + $helperPath
        }
        [IO.File]::WriteAllText($helperPath, $helperText, $script:Utf8)
        New-Item -ItemType Directory -Path (
            Split-Path -Parent $attributePath
        ) -Force | Out-Null
        [IO.File]::WriteAllText(
            $attributePath,
            "* filter=hostile`n",
            $script:Utf8
        )
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'config', '--local',
            'filter.hostile.clean', $configuredHelper
        ) | Out-Null
        try {
            Assert-Throws { Invoke-Verification } `
                "forbidden key 'filter.hostile.clean'"
            if (Test-Path -LiteralPath $markerPath) {
                throw 'The hostile clean filter executed during verification.'
            }
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'config', '--local', '--unset-all',
                'filter.hostile.clean'
            ) | Out-Null
            foreach ($path in @($attributePath, $helperPath, $markerPath)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Force
                }
            }
        }
    }

    Invoke-SelfTest 'Normal invocation remains blocked' {
        Assert-Throws { Invoke-Verification -WithoutPolicyAudit } `
            'only -PolicyAudit is permitted'
    }

    Invoke-SelfTest 'Malformed lock JSON is rejected by the strict reader' {
        try {
            [IO.File]::WriteAllText($script:LockPath, '{', $script:Utf8)
            Assert-Throws { Invoke-Verification } 'Unterminated JSON object'
        }
        finally {
            Reset-TestMetadata
        }
    }

    Invoke-SelfTest 'Duplicate lock JSON properties are rejected by the strict reader' {
        try {
            $json = [IO.File]::ReadAllText($script:CanonicalLock).Replace(
                '"schema": 1,',
                '"schema": 1, "SCHEMA": 1,'
            )
            [IO.File]::WriteAllText($script:LockPath, $json, $script:Utf8)
            Assert-Throws { Invoke-Verification } 'Duplicate JSON property'
        }
        finally {
            Reset-TestMetadata
        }
    }

    Invoke-SelfTest 'Oversized lock JSON is rejected before parsing' {
        try {
            [IO.File]::WriteAllBytes(
                $script:LockPath,
                (New-Object byte[] (1024 * 1024 + 1))
            )
            Assert-Throws { Invoke-Verification } 'exceeds the 1048576-byte bound'
        }
        finally {
            Reset-TestMetadata
        }
    }

    Invoke-SelfTest 'A reparse-point lock ancestor is rejected' {
        $target = Join-Path $script:TestRoot 'reparse-target'
        $link = Join-Path $script:TestRoot 'reparse-link'
        New-Item -ItemType Directory -Path $target | Out-Null
        [IO.File]::Copy(
            $script:CanonicalLock,
            (Join-Path $target 'mesa-generator-toolchain-lock.json')
        )
        [IO.File]::Copy(
            $script:CanonicalSchema,
            (Join-Path $target 'mesa-generator-toolchain-lock.schema.json')
        )
        New-DirectoryReparsePoint -Path $link -Target $target
        try {
            Assert-Throws {
                Invoke-Verification -LockFile (
                    Join-Path $link 'mesa-generator-toolchain-lock.json'
                )
            } 'traverses reparse point'
        }
        finally {
            if (Test-Path -LiteralPath $link) {
                [IO.Directory]::Delete($link, $false)
            }
        }
    }

    Invoke-SelfTest 'Immutable lock hash drift is rejected' {
        try {
            [IO.File]::AppendAllText($script:LockPath, ' ', $script:Utf8)
            Assert-Throws { Invoke-Verification } 'immutable semantic contract'
        }
        finally {
            Reset-TestMetadata
        }
    }

    Invoke-SelfTest 'Immutable schema hash drift is rejected' {
        try {
            [IO.File]::AppendAllText($script:SchemaPath, ' ', $script:Utf8)
            Assert-Throws { Invoke-Verification } 'schema hash does not match'
        }
        finally {
            Reset-TestMetadata
        }
    }

    $semanticDrifts = @(
        [pscustomobject]@{
            Name = 'package'
            Mutate = { param($lock) $lock.packages[0].name = 'bash-drift' }
        },
        [pscustomobject]@{
            Name = 'package order'
            Mutate = {
                param($lock)
                $first = $lock.packages[0]
                $lock.packages[0] = $lock.packages[1]
                $lock.packages[1] = $first
            }
        },
        [pscustomobject]@{
            Name = 'package role'
            Mutate = {
                param($lock)
                $lock.packages[0].role = 'reserved-unselected'
            }
        },
        [pscustomobject]@{
            Name = 'dependency'
            Mutate = {
                param($lock)
                $lock.packages[1].dependencies = @(
                    @($lock.packages[1].dependencies) + 'bash'
                )
            }
        },
        [pscustomobject]@{
            Name = 'virtual provider'
            Mutate = {
                param($lock)
                $lock.package_policy.virtual_providers[0].package = 'binutils'
            }
        },
        [pscustomobject]@{
            Name = 'permitted cycle'
            Mutate = {
                param($lock)
                $lock.package_policy.permitted_dependency_cycles[0].packages = @(
                    'libintl', 'libiconv'
                )
            }
        },
        [pscustomobject]@{
            Name = 'tool probe'
            Mutate = {
                param($lock)
                $lock.expected_tools[0].expected_output = 'Python drift'
            }
        },
        [pscustomobject]@{
            Name = 'module probe'
            Mutate = {
                param($lock)
                $lock.expected_modules[0].version = '0.0.0'
            }
        },
        [pscustomobject]@{
            Name = 'proof'
            Mutate = { param($lock) $lock.proofs.runtime.proven = $true }
        },
        [pscustomobject]@{
            Name = 'authorization'
            Mutate = { param($lock) $lock.authorizations.build = $true }
        }
    )
    foreach ($drift in $semanticDrifts) {
        Invoke-SelfTest "Immutable contract rejects $($drift.Name) drift" {
            try {
                $lock = Read-CanonicalLockObject
                & ($drift.Mutate) $lock
                Write-TestLockObject $lock
                Assert-Throws { Invoke-Verification } 'immutable semantic contract'
            }
            finally {
                Reset-TestMetadata
            }
        }
    }

    Invoke-SelfTest 'Unsafe package paths are rejected before hash acceptance' {
        try {
            $lock = Read-CanonicalLockObject
            $lock.packages[0].archive.relative_path = 'nested/unsafe.pkg.tar.zst'
            Write-TestLockObject $lock
            Assert-Throws { Invoke-Verification } `
                'must be one package-directory filename'
        }
        finally {
            Reset-TestMetadata
        }
    }

    Invoke-SelfTest 'Duplicate package paths are rejected before hash acceptance' {
        try {
            $lock = Read-CanonicalLockObject
            $lock.packages[1].archive.relative_path = `
                $lock.packages[0].archive.relative_path
            Write-TestLockObject $lock
            Assert-Throws { Invoke-Verification } 'Duplicate package filename'
        }
        finally {
            Reset-TestMetadata
        }
    }

    Invoke-SelfTest 'An undeclared package-root file is rejected' {
        $path = Join-Path $script:PackageRoot 'undeclared.pkg.tar.zst'
        try {
            [IO.File]::WriteAllBytes($path, [byte[]](0x00))
            Assert-Throws { Invoke-Verification } 'contains undeclared file'
        }
        finally {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }

    Invoke-SelfTest 'A missing declared package-root file is rejected' {
        $name = 'libbz2-1.0.8-4-x86_64.pkg.tar.zst'
        $path = Join-Path $script:PackageRoot $name
        $held = Join-Path $script:TestRoot $name
        [IO.File]::Move($path, $held)
        try {
            Assert-Throws { Invoke-Verification } `
                "missing declared file '$([regex]::Escape($name))'"
        }
        finally {
            if (Test-Path -LiteralPath $held -PathType Leaf) {
                [IO.File]::Move($held, $path)
            }
        }
    }

    Invoke-SelfTest 'A missing detached signature is rejected' {
        $name = 'bash-5.3.009-1-x86_64.pkg.tar.zst.sig'
        $path = Join-Path $script:PackageRoot $name
        $held = Join-Path $script:TestRoot $name
        [IO.File]::Move($path, $held)
        try {
            Assert-Throws { Invoke-Verification } `
                "missing declared file '$([regex]::Escape($name))'"
        }
        finally {
            if (Test-Path -LiteralPath $held -PathType Leaf) {
                [IO.File]::Move($held, $path)
            }
        }
    }

    Invoke-SelfTest 'Archive content mismatch is rejected' {
        $path = Join-Path $script:PackageRoot `
            'libbz2-1.0.8-4-x86_64.pkg.tar.zst'
        [byte[]]$original = [IO.File]::ReadAllBytes($path)
        try {
            [byte[]]$mutated = $original.Clone()
            $mutated[0] = $mutated[0] -bxor 0xff
            [IO.File]::WriteAllBytes($path, $mutated)
            Assert-Throws { Invoke-Verification } `
                "package 'libbz2' archive bytes do not match"
        }
        finally {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }

    Invoke-SelfTest 'Detached-signature content mismatch is rejected' {
        $path = Join-Path $script:PackageRoot `
            'binutils-2.45.1-1-x86_64.pkg.tar.zst.sig'
        [byte[]]$original = [IO.File]::ReadAllBytes($path)
        try {
            [byte[]]$mutated = $original.Clone()
            $mutated[0] = $mutated[0] -bxor 0xff
            [IO.File]::WriteAllBytes($path, $mutated)
            Assert-Throws { Invoke-Verification } `
                "package 'binutils' signature bytes do not match"
        }
        finally {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }

    Invoke-SelfTest 'A checkout with the wrong origin is rejected' {
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'remote', 'set-url', 'origin',
            'https://example.invalid/mesa9x.git'
        ) | Out-Null
        try {
            Assert-Throws { Invoke-Verification } `
                'exactly one unpadded local origin URL'
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'remote', 'set-url', 'origin',
                $script:ExpectedRepository
            ) | Out-Null
        }
    }

    Invoke-SelfTest 'Multiple local origin values are rejected' {
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'config', '--local', '--add',
            'remote.origin.url', 'https://example.invalid/second.git'
        ) | Out-Null
        try {
            Assert-Throws { Invoke-Verification } `
                'exactly one unpadded local origin URL'
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'config', '--local', '--unset-all',
                'remote.origin.url'
            ) | Out-Null
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'config', '--local',
                'remote.origin.url', $script:ExpectedRepository
            ) | Out-Null
        }
    }

    Invoke-SelfTest 'Whitespace-padded local origin is rejected' {
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'config', '--local',
            'remote.origin.url', " $($script:ExpectedRepository) "
        ) | Out-Null
        try {
            Assert-Throws { Invoke-Verification } `
                'exactly one unpadded local origin URL'
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'config', '--local',
                'remote.origin.url', $script:ExpectedRepository
            ) | Out-Null
        }
    }

    Invoke-SelfTest 'A checkout at the wrong HEAD is rejected' {
        $wrongHead = (
            Invoke-TestGit @('-C', $script:MesaCheckout, 'rev-parse', 'HEAD^')
        ) -join "`n"
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'checkout', '--detach', $wrongHead.Trim()
        ) | Out-Null
        try {
            Assert-Throws { Invoke-Verification } 'is not the pinned commit'
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'checkout', '--detach',
                $script:ExpectedCommit
            ) | Out-Null
        }
    }

    Invoke-SelfTest 'A dirty checkout is rejected' {
        $dirtyPath = Join-Path $script:MesaCheckout 'untracked-generator-test.tmp'
        try {
            [IO.File]::WriteAllBytes($dirtyPath, [byte[]](0x00))
            Assert-Throws { Invoke-Verification } 'checkout is not clean'
        }
        finally {
            if (Test-Path -LiteralPath $dirtyPath) {
                Remove-Item -LiteralPath $dirtyPath -Force
            }
        }
    }

    Invoke-SelfTest 'Hidden generator recipe index state is rejected' {
        $recipe = 'generator/mesa-23.1.x-gen.mk'
        Invoke-TestGit @(
            '-C', $script:MesaCheckout, 'update-index', '--skip-worktree', '--',
            $recipe
        ) | Out-Null
        try {
            Assert-Throws { Invoke-Verification } `
                'generator recipe has hidden or unexpected index state'
        }
        finally {
            Invoke-TestGit @(
                '-C', $script:MesaCheckout, 'update-index',
                '--no-skip-worktree', '--', $recipe
            ) | Out-Null
        }
    }

    Invoke-SelfTest 'Final metadata recheck detects lock mutation' {
        $path = $script:LockPath
        $encoding = $script:Utf8
        [byte[]]$original = [IO.File]::ReadAllBytes($path)
        $callback = {
            [IO.File]::AppendAllText($path, ' ', $encoding)
        }.GetNewClosure()
        try {
            Assert-Throws {
                Invoke-Verification -BeforeFinalMetadataCheck $callback
            } 'immutable semantic contract'
        }
        finally {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }
}
finally {
    Remove-TestRoot $script:TestRoot
}

if ($script:Failures -ne 0) {
    throw "$script:Failures Mesa generator toolchain test(s) failed."
}
Write-Host 'All Windows 98 Mesa generator toolchain tests passed.'

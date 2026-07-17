# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [string]$Message = 'Expected true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', observed '$Actual'." }
}

function Assert-Throws {
    param([Parameter(Mandatory = $true)][scriptblock]$Body, [string]$Pattern = '')
    try {
        & $Body | Out-Null
    }
    catch {
        if ($Pattern.Length -ne 0 -and $_.Exception.Message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $($_.Exception.Message)"
        }
        return
    }
    throw 'Expected an exception.'
}

function Invoke-SelfTest {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures++
        [Console]::Error.WriteLine("FAIL $Name`: $($_.Exception.Message)")
    }
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function New-PinnedCheckout {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Origin
    )

    New-Item -ItemType Directory -Path $Path | Out-Null
    Invoke-Git @('init', '-q', $Path) | Out-Null
    Invoke-Git @('-C', $Path, 'config', 'user.name', 'RETVRN99 Test') | Out-Null
    Invoke-Git @('-C', $Path, 'config', 'user.email', 'test@retvrn99.invalid') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'fixture.txt'), 'pinned-source')
    Invoke-Git @('-C', $Path, 'add', 'fixture.txt') | Out-Null
    Invoke-Git @('-C', $Path, 'commit', '-q', '-m', 'Pinned fixture') | Out-Null
    Invoke-Git @('-C', $Path, 'remote', 'add', 'origin', $Origin) | Out-Null
    return Invoke-Git @('-C', $Path, 'rev-parse', 'HEAD')
}

function Write-UpstreamLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayCommit
    )

    $contents = @(
        '# SPDX-License-Identifier: GPL-3.0-only'
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tscope"
        "vmdisp9x`tvmdisp9x`thttps://example.invalid/vmdisp9x.git`t$DisplayCommit`tMIT`tplanned`tdisplay-driver"
        "vmhal9x`tvmhal9x`thttps://example.invalid/vmhal9x.git`t$DisplayCommit`tMIT`tplanned`tdirectdraw-hal"
    ) -join "`r`n"
    [IO.File]::WriteAllText($Path, $contents + "`r`n")
}

function Get-ByteHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for the Windows 98 source script tests.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-win98-source-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $verifyScript = Join-Path $PSScriptRoot 'verify-win98-driver-sources.ps1'
    $buildScript = Join-Path $PSScriptRoot 'build-win98-driver-sources.ps1'
    $sourceRoot = Join-Path $testRoot 'sources'
    New-Item -ItemType Directory -Path $sourceRoot | Out-Null
    $displayCheckout = Join-Path $sourceRoot 'vmdisp9x'
    $displayOrigin = 'https://example.invalid/vmdisp9x.git'
    $displayCommit = New-PinnedCheckout -Path $displayCheckout -Origin $displayOrigin
    $lockPath = Join-Path $testRoot 'upstream.lock.tsv'
    Write-UpstreamLock -Path $lockPath -DisplayCommit $displayCommit

    Invoke-SelfTest 'A source-name allowlist verifies only selected checkouts' {
        $output = @(& $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath -SourceName 'vmdisp9x')
        Assert-Equal ($output -join [Environment]::NewLine) 'Verified 1 immutable Windows 98 source checkouts.'
    }

    Invoke-SelfTest 'Default verification still requires every locked checkout' {
        Assert-Throws {
            & $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath
        } "Pinned checkout is absent for 'vmhal9x'"
    }

    Invoke-SelfTest 'A source-name allowlist rejects unknown and duplicate names' {
        Assert-Throws {
            & $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath -SourceName 'unknown-source'
        } "Unknown requested upstream name 'unknown-source'"
        Assert-Throws {
            & $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath -SourceName @('vmdisp9x', 'vmdisp9x')
        } "Duplicate requested upstream name 'vmdisp9x'"
        Assert-Throws {
            & $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath -SourceName @()
        } 'must contain at least one'
    }

    Invoke-SelfTest 'Filtered verification still rejects a dirty checkout' {
        $dirtyPath = Join-Path $displayCheckout 'dirty.tmp'
        [IO.File]::WriteAllText($dirtyPath, 'dirty')
        try {
            Assert-Throws {
                & $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath -SourceName 'vmdisp9x'
            } "Pinned source 'vmdisp9x' has local changes"
        }
        finally {
            Remove-Item -LiteralPath $dirtyPath
        }
    }

    Invoke-SelfTest 'Filtered verification still rejects an unexpected origin' {
        Invoke-Git @('-C', $displayCheckout, 'remote', 'set-url', 'origin', 'https://example.invalid/unexpected.git') | Out-Null
        try {
            Assert-Throws {
                & $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath -SourceName 'vmdisp9x'
            } 'has unexpected origin'
        }
        finally {
            Invoke-Git @('-C', $displayCheckout, 'remote', 'set-url', 'origin', $displayOrigin) | Out-Null
        }
    }

    Invoke-SelfTest 'Filtered verification still rejects a commit mismatch' {
        Write-UpstreamLock -Path $lockPath -DisplayCommit ('0' * 40)
        try {
            Assert-Throws {
                & $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath -SourceName 'vmdisp9x'
            } 'expected 0000000000000000000000000000000000000000'
        }
        finally {
            Write-UpstreamLock -Path $lockPath -DisplayCommit $displayCommit
        }
    }

    Invoke-SelfTest 'Build verification requires canonical planned sources from its exact step set' {
        $toolchainRoot = Join-Path $testRoot 'toolchains'
        New-Item -ItemType Directory -Path $toolchainRoot | Out-Null
        $toolchainPath = Join-Path $toolchainRoot 'write-artifact.cmd'
        [IO.File]::WriteAllText(
            $toolchainPath,
            "@echo off`r`n<nul set /p `"=abc`" > artifact.bin`r`nexit /b 0`r`n",
            [Text.Encoding]::ASCII
        )
        $artifactBytes = [byte[]](0x61, 0x62, 0x63)
        $plan = [ordered]@{
            _spdx = 'GPL-3.0-only'
            schema = 1
            status = 'ready'
            reason = ''
            toolchains = @([ordered]@{
                name = 'fixture-toolchain'
                relative_path = 'write-artifact.cmd'
                sha256 = (Get-FileHash -LiteralPath $toolchainPath -Algorithm SHA256).Hash.ToLowerInvariant()
            })
            steps = @([ordered]@{
                name = 'build-display'
                toolchain = 'fixture-toolchain'
                source_directory = 'vmdisp9x'
                working_directory = '.'
                arguments = @()
                outputs = @([ordered]@{
                    relative_path = 'artifact.bin'
                    sha256 = Get-ByteHash $artifactBytes
                    bytes = $artifactBytes.Length
                })
            })
        }
        $planPath = Join-Path $testRoot 'build-plan.json'
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8))

        $plan.steps[0].source_directory = 'VMDISP9X'
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -BuildPlan $planPath -LockFile $lockPath
        } "must use canonical source directory 'vmdisp9x'"
        $plan.steps[0].source_directory = 'vmdisp9x'
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8))

        $plannedLock = [IO.File]::ReadAllText($lockPath)
        $referenceLock = $plannedLock.Replace(
            "MIT`tplanned`tdisplay-driver",
            "MIT`treference-only`tdisplay-driver"
        )
        [IO.File]::WriteAllText($lockPath, $referenceLock)
        try {
            Assert-Throws {
                & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                    -BuildPlan $planPath -LockFile $lockPath
            } 'must reference exactly one named planned source'
        }
        finally {
            [IO.File]::WriteAllText($lockPath, $plannedLock)
        }

        $output = @(
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -BuildPlan $planPath -LockFile $lockPath
        )
        Assert-True (($output -join [Environment]::NewLine) -match 'Verified 1 immutable')
        Assert-True (($output -join [Environment]::NewLine) -match 'Completed and verified 1 Windows 98 driver build steps')
        $artifactPath = Join-Path $displayCheckout 'artifact.bin'
        Assert-True (Test-Path -LiteralPath $artifactPath -PathType Leaf)
        Assert-Equal ([Convert]::ToHexString([IO.File]::ReadAllBytes($artifactPath))) '616263'
        Remove-Item -LiteralPath $artifactPath
    }

}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures Windows 98 driver source script test(s) failed."
}
Write-Host 'All Windows 98 driver source script tests passed.'

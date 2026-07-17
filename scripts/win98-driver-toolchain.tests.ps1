# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
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

function New-FixtureToolchain {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$ReverseCreationOrder
    )

    New-Item -ItemType Directory -Path (Join-Path $Root 'downloads') -Force | Out-Null
    $extracted = Join-Path $Root 'open-watcom-1.9'
    $directories = @('eddat', 'h\nt', 'h\win', 'h', 'binnt', 'binw', 'lib')
    $files = [ordered]@{
        'eddat\editor.dat' = [byte[]](0x45, 0x44)
        'h\nt\nt.h' = [byte[]](0x4e, 0x54, 0x0a)
        'h\win\windows.h' = [byte[]](0x57, 0x49, 0x4e)
        'h\stddef.h' = [byte[]](0x48)
        'binnt\wmake.exe' = [byte[]](0x4d, 0x5a, 0x01)
        'binw\wcc.exe' = [byte[]](0x4d, 0x5a, 0x02)
        'lib\fixture.lbc' = [byte[]](0x4c, 0x49, 0x42, 0x00)
    }
    if ($ReverseCreationOrder) {
        [Array]::Reverse($directories)
    }
    foreach ($directory in $directories) {
        New-Item -ItemType Directory -Path (Join-Path $extracted $directory) -Force | Out-Null
    }
    $fileNames = [string[]]@($files.Keys)
    if ($ReverseCreationOrder) {
        [Array]::Reverse($fileNames)
    }
    foreach ($fileName in $fileNames) {
        [IO.File]::WriteAllBytes((Join-Path $extracted $fileName), $files[$fileName])
    }
    [IO.File]::WriteAllBytes(
        (Join-Path $Root 'downloads\open-watcom-c-win32-1.9.exe'),
        [byte[]](0x4d, 0x5a, 0x19, 0x09)
    )
}

function New-DirectoryReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $itemType = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $itemType -Path $Path -Target $Target | Out-Null
}

function Write-FixtureLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ArchivePath = 'downloads/open-watcom-c-win32-1.9.exe',
        [string]$ExtractedPath = 'open-watcom-1.9',
        [string[]]$Include = @('h/nt', 'h/win', 'h'),
        [string[]]$PathPrefixes = @('binnt', 'binw'),
        [string]$WatcomRoot = '.',
        [string]$EdPath = 'eddat',
        [int]$Schema = 1
    )

    $lock = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = $Schema
        name = 'fixture-open-watcom-1.9'
        archive = [ordered]@{
            relative_path = $ArchivePath
            bytes = 4
            sha256 = '0d544339904ea7428ad390047125ad73d4cb4da779b14909664f723aa6ad5afd'
            md5 = 'af899a80765c8f35d4b045803fdb1559'
        }
        extracted = [ordered]@{
            relative_path = $ExtractedPath
            file_count = 7
            directory_count = 7
            total_entries = 14
            aggregate_bytes = 19
            maximum_file_bytes = 4
            maximum_path_bytes = 16
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'
            sha256 = '12d34c7f434075ddce253237ebb82e1509c12ce7736fcafe3b48a0426477273b'
        }
        environment = if ($Schema -eq 2) {
            [ordered]@{ path_prefixes = $PathPrefixes }
        } else {
            [ordered]@{
                watcom_root = $WatcomRoot
                edpath = $EdPath
                include = $Include
                path_prefixes = $PathPrefixes
            }
        }
    }
    [IO.File]::WriteAllText($Path, ($lock | ConvertTo-Json -Depth 8))
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-win98-toolchain-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $verifyScript = Join-Path $PSScriptRoot 'verify-win98-driver-toolchain.ps1'
    $lockPath = Join-Path $testRoot 'toolchain.lock.json'
    $toolchainRoot = Join-Path $testRoot 'forward'
    New-FixtureToolchain -Root $toolchainRoot
    Write-FixtureLock -Path $lockPath

    Invoke-SelfTest 'A complete pinned toolchain verifies' {
        $output = @(& $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath)
        Assert-Equal ($output -join [Environment]::NewLine) (
            "Verified Windows 98 toolchain 'fixture-open-watcom-1.9' " +
            '(7 files, 19 bytes, tree 12d34c7f434075ddce253237ebb82e1509c12ce7736fcafe3b48a0426477273b).'
        )
    }

    Invoke-SelfTest 'A PATH-only schema-2 toolchain verifies and stays strict' {
        $schema2Root = Join-Path $testRoot 'schema2-root'
        New-FixtureToolchain -Root $schema2Root
        Move-Item -LiteralPath (Join-Path $schema2Root 'open-watcom-1.9\binnt') `
            -Destination (Join-Path $schema2Root 'open-watcom-1.9\bin')
        $descriptor = & $verifyScript -ToolchainRoot $schema2Root `
            -DescribeRelativePath 'open-watcom-1.9' | ConvertFrom-Json
        $schema2Lock = Join-Path $testRoot 'schema2.lock.json'
        Write-FixtureLock -Path $schema2Lock -Schema 2 -PathPrefixes @('bin')
        $lockObject = Get-Content -Raw -LiteralPath $schema2Lock | ConvertFrom-Json
        foreach ($property in @(
            'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
            'maximum_file_bytes', 'maximum_path_bytes', 'sha256'
        )) { $lockObject.extracted.$property = $descriptor.$property }
        [IO.File]::WriteAllText($schema2Lock, ($lockObject | ConvertTo-Json -Depth 8))
        $output = @(& $verifyScript -ToolchainRoot $schema2Root -LockFile $schema2Lock)
        Assert-Equal (($output -join [Environment]::NewLine) -match "fixture-open-watcom-1.9") $true

        $invalid = Join-Path $testRoot 'schema2-invalid.lock.json'
        $text = [IO.File]::ReadAllText($schema2Lock).Replace(
            '"path_prefixes":',
            '"watcom_root": ".", "path_prefixes":'
        )
        [IO.File]::WriteAllText($invalid, $text)
        Assert-Throws {
            & $verifyScript -ToolchainRoot $schema2Root -LockFile $invalid
        } 'Unexpected property.*in environment metadata'
    }

    Invoke-SelfTest 'Canonical tree digest is independent of creation order' {
        $reverseRoot = Join-Path $testRoot 'reverse'
        New-FixtureToolchain -Root $reverseRoot -ReverseCreationOrder
        $output = @(& $verifyScript -ToolchainRoot $reverseRoot -LockFile $lockPath)
        Assert-Equal ($output -join [Environment]::NewLine) (
            "Verified Windows 98 toolchain 'fixture-open-watcom-1.9' " +
            '(7 files, 19 bytes, tree 12d34c7f434075ddce253237ebb82e1509c12ce7736fcafe3b48a0426477273b).'
        )
    }

    Invoke-SelfTest 'Archive mutation is rejected' {
        $archivePath = Join-Path $toolchainRoot 'downloads\open-watcom-c-win32-1.9.exe'
        $original = [IO.File]::ReadAllBytes($archivePath)
        try {
            [IO.File]::WriteAllBytes($archivePath, [byte[]](0x4d, 0x5a, 0x19, 0x08))
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'archive SHA256 mismatch'
        }
        finally {
            [IO.File]::WriteAllBytes($archivePath, $original)
        }
    }

    Invoke-SelfTest 'Extracted file mutation, addition, and removal are rejected' {
        $mutatedPath = Join-Path $toolchainRoot 'open-watcom-1.9\h\stddef.h'
        $original = [IO.File]::ReadAllBytes($mutatedPath)
        try {
            [IO.File]::WriteAllBytes($mutatedPath, [byte[]](0x49))
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'Extracted toolchain Sha256 mismatch'
        }
        finally {
            [IO.File]::WriteAllBytes($mutatedPath, $original)
        }

        $addedPath = Join-Path $toolchainRoot 'open-watcom-1.9\added.bin'
        try {
            [IO.File]::WriteAllBytes($addedPath, [byte[]](0x00))
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'entry count exceeds locked or hard bounds'
        }
        finally {
            Remove-Item -LiteralPath $addedPath
        }

        $removedPath = Join-Path $toolchainRoot 'open-watcom-1.9\lib\fixture.lbc'
        $removed = [IO.File]::ReadAllBytes($removedPath)
        try {
            Remove-Item -LiteralPath $removedPath
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'Extracted toolchain FileCount mismatch'
        }
        finally {
            [IO.File]::WriteAllBytes($removedPath, $removed)
        }
    }

    Invoke-SelfTest 'Unsafe and duplicate metadata are rejected' {
        $unsafeLock = Join-Path $testRoot 'unsafe.lock.json'
        Write-FixtureLock -Path $unsafeLock -ArchivePath '../outside.exe'
        Assert-Throws {
            & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $unsafeLock
        } 'Unsafe relative path'

        $duplicateArrayLock = Join-Path $testRoot 'duplicate-array.lock.json'
        Write-FixtureLock -Path $duplicateArrayLock -Include @('h/nt', 'h/nt', 'h')
        Assert-Throws {
            & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $duplicateArrayLock
        } 'Duplicate environment.include entry'

        $duplicatePropertyLock = Join-Path $testRoot 'duplicate-property.lock.json'
        $duplicateJson = [IO.File]::ReadAllText($lockPath).Replace(
            '"schema": 1,',
            '"schema": 1, "schema": 1,'
        )
        [IO.File]::WriteAllText($duplicatePropertyLock, $duplicateJson)
        Assert-Throws {
            & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $duplicatePropertyLock
        } 'Duplicate JSON property'

        $wrongTypeLock = Join-Path $testRoot 'wrong-type.lock.json'
        $wrongTypeJson = [IO.File]::ReadAllText($lockPath).Replace(
            '"relative_path": "downloads/open-watcom-c-win32-1.9.exe"',
            '"relative_path": 123'
        )
        [IO.File]::WriteAllText($wrongTypeLock, $wrongTypeJson)
        Assert-Throws {
            & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $wrongTypeLock
        } 'Unsafe relative path'
    }

    Invoke-SelfTest 'Pinned environment shape and directory closure are enforced' {
        $wrongEnvironmentLock = Join-Path $testRoot 'wrong-environment.lock.json'
        Write-FixtureLock -Path $wrongEnvironmentLock -EdPath 'lib'
        Assert-Throws {
            & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $wrongEnvironmentLock
        } "WATCOM='.' and EDPATH='eddat'"

        $eddataPath = Join-Path $toolchainRoot 'open-watcom-1.9\eddat'
        $heldPath = Join-Path $toolchainRoot 'open-watcom-1.9\eddat-held'
        Move-Item -LiteralPath $eddataPath -Destination $heldPath
        try {
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'Required Watcom environment directory is absent: eddat'
        }
        finally {
            Move-Item -LiteralPath $heldPath -Destination $eddataPath
        }
    }

    Invoke-SelfTest 'Tree paths are portable and bounded before file hashing' {
        $heldPath = Join-Path $testRoot 'held-fixture.lbc'
        $fixturePath = Join-Path $toolchainRoot 'open-watcom-1.9\lib\fixture.lbc'
        Move-Item -LiteralPath $fixturePath -Destination $heldPath
        try {
            $nonPortablePath = Join-Path $toolchainRoot 'open-watcom-1.9\bad name.bin'
            [IO.File]::WriteAllBytes($nonPortablePath, [byte[]](0x4c, 0x49, 0x42, 0x00))
            try {
                Assert-Throws {
                    & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
                } 'Non-portable toolchain path component'
            }
            finally {
                Remove-Item -LiteralPath $nonPortablePath
            }

            $longPath = Join-Path $toolchainRoot 'open-watcom-1.9\abcdefghijklmnopq.bin'
            [IO.File]::WriteAllBytes($longPath, [byte[]](0x4c, 0x49, 0x42, 0x00))
            try {
                Assert-Throws {
                    & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
                } 'exceeds locked or hard length bounds'
            }
            finally {
                Remove-Item -LiteralPath $longPath
            }

            if ([IO.Path]::DirectorySeparatorChar -eq '/') {
                $backslashPath = Join-Path $toolchainRoot 'open-watcom-1.9/binnt\wmake.exe'
                [IO.File]::WriteAllBytes($backslashPath, [byte[]](0x4c, 0x49, 0x42, 0x00))
                try {
                    Assert-Throws {
                        & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
                    } 'Literal backslashes are not portable'
                }
                finally {
                    Remove-Item -LiteralPath $backslashPath
                }
            }
        }
        finally {
            Move-Item -LiteralPath $heldPath -Destination $fixturePath
        }
    }

    Invoke-SelfTest 'Streaming traversal enforces file, directory, and hard lock bounds' {
        $fixturePath = Join-Path $toolchainRoot 'open-watcom-1.9\lib\fixture.lbc'
        $original = [IO.File]::ReadAllBytes($fixturePath)
        try {
            [IO.File]::WriteAllBytes($fixturePath, [byte[]](0x4c, 0x49, 0x42, 0x00, 0x01))
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'exceeds locked or hard size bounds'
        }
        finally {
            [IO.File]::WriteAllBytes($fixturePath, $original)
        }

        $heldPath = Join-Path $testRoot 'held-for-directory.lbc'
        $newDirectory = Join-Path $toolchainRoot 'open-watcom-1.9\replacement'
        Move-Item -LiteralPath $fixturePath -Destination $heldPath
        New-Item -ItemType Directory -Path $newDirectory | Out-Null
        try {
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'directory count exceeds locked or hard bounds'
        }
        finally {
            Remove-Item -LiteralPath $newDirectory
            Move-Item -LiteralPath $heldPath -Destination $fixturePath
        }

        $hardBoundLock = Join-Path $testRoot 'hard-bound.lock.json'
        $hardBoundJson = [IO.File]::ReadAllText($lockPath).Replace(
            '"file_count": 7,',
            '"file_count": 10001,'
        )
        [IO.File]::WriteAllText($hardBoundLock, $hardBoundJson)
        Assert-Throws {
            & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $hardBoundLock
        } 'lock exceeds verifier hard bounds'
    }

    Invoke-SelfTest 'Every metadata path component rejects reparse points' {
        $downloadsPath = Join-Path $toolchainRoot 'downloads'
        $downloadsTarget = Join-Path $toolchainRoot 'downloads-real'
        Move-Item -LiteralPath $downloadsPath -Destination $downloadsTarget
        New-DirectoryReparsePoint -Path $downloadsPath -Target $downloadsTarget
        try {
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'Reparse-point path component'
        }
        finally {
            Remove-Item -LiteralPath $downloadsPath -Force
            Move-Item -LiteralPath $downloadsTarget -Destination $downloadsPath
        }

        $extractedPath = Join-Path $toolchainRoot 'open-watcom-1.9'
        $payloadTarget = Join-Path $toolchainRoot 'payload-real'
        $payloadLink = Join-Path $toolchainRoot 'payload'
        New-Item -ItemType Directory -Path $payloadTarget | Out-Null
        Move-Item -LiteralPath $extractedPath -Destination (Join-Path $payloadTarget 'open-watcom-1.9')
        New-DirectoryReparsePoint -Path $payloadLink -Target $payloadTarget
        $nestedLock = Join-Path $testRoot 'nested-extracted.lock.json'
        Write-FixtureLock -Path $nestedLock -ExtractedPath 'payload/open-watcom-1.9'
        try {
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $nestedLock
            } 'Reparse-point path component'
        }
        finally {
            Remove-Item -LiteralPath $payloadLink -Force
            Move-Item -LiteralPath (Join-Path $payloadTarget 'open-watcom-1.9') -Destination $extractedPath
            Remove-Item -LiteralPath $payloadTarget
        }

        $headerPath = Join-Path $extractedPath 'h'
        $headerTarget = Join-Path $extractedPath 'h-real'
        Move-Item -LiteralPath $headerPath -Destination $headerTarget
        New-DirectoryReparsePoint -Path $headerPath -Target $headerTarget
        try {
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath
            } 'Reparse-point path component'
        }
        finally {
            Remove-Item -LiteralPath $headerPath -Force
            Move-Item -LiteralPath $headerTarget -Destination $headerPath
        }
    }

    Invoke-SelfTest 'A complete second scan catches additions and mutations between passes' {
        $addedPath = Join-Path $toolchainRoot 'open-watcom-1.9\new.bin'
        try {
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath `
                    -BeforeSecondScan {
                        param($root)
                        [IO.File]::WriteAllBytes(
                            (Join-Path $root 'new.bin'),
                            [byte[]](0x00)
                        )
                    }
            } 'entry count exceeds locked or hard bounds'
        }
        finally {
            if (Test-Path -LiteralPath $addedPath) {
                Remove-Item -LiteralPath $addedPath
            }
        }

        $mutatedPath = Join-Path $toolchainRoot 'open-watcom-1.9\h\stddef.h'
        $original = [IO.File]::ReadAllBytes($mutatedPath)
        try {
            Assert-Throws {
                & $verifyScript -ToolchainRoot $toolchainRoot -LockFile $lockPath `
                    -BeforeSecondScan {
                        param($root)
                        [IO.File]::WriteAllBytes(
                            (Join-Path $root 'h\stddef.h'),
                            [byte[]](0x49)
                        )
                    }
            } 'Second extracted-toolchain scan Sha256 mismatch'
        }
        finally {
            [IO.File]::WriteAllBytes($mutatedPath, $original)
        }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures Windows 98 driver toolchain test(s) failed."
}
Write-Host 'All Windows 98 driver toolchain tests passed.'

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
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
        "vmdisp9x`tvmdisp9x`thttps://example.invalid/vmdisp9x.git`t$DisplayCommit`tMIT`tplanned`t`t`tdisplay-driver"
        "vmhal9x`tvmhal9x`thttps://example.invalid/vmhal9x.git`t$DisplayCommit`tMIT`tplanned`t`t`tdirectdraw-hal"
    ) -join "`r`n"
    [IO.File]::WriteAllText($Path, $contents + "`r`n")
}

function Write-MixedUpstreamLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayCommit,
        [Parameter(Mandatory = $true)][string]$ManifestRelativePath,
        [Parameter(Mandatory = $true)][string]$ManifestHash
    )

    $contents = @(
        '# SPDX-License-Identifier: GPL-3.0-only'
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
        "vmdisp9x`tvmdisp9x`thttps://example.invalid/vmdisp9x.git`t$DisplayCommit`tMIT`tplanned`t`t`tdisplay-driver"
        "vmhal9x`tvmhal9x`thttps://example.invalid/vmhal9x.git`t$DisplayCommit`tMIT`tplanned`t`t`tdirectdraw-hal"
        "fixture-component`tfixture-component`thttps://example.invalid/component.git`t$DisplayCommit`tMIT`tplanned-component`t$ManifestRelativePath`t$ManifestHash`tfixture-component"
    ) -join "`r`n"
    [IO.File]::WriteAllText($Path, $contents + "`r`n")
}

function Get-ByteHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Set-UInt16LE {
    param([byte[]]$Bytes, [int]$Offset, [uint16]$Value)

    $Bytes[$Offset] = [byte]($Value -band 0xff)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xff)
}

function Set-UInt32LE {
    param([byte[]]$Bytes, [int]$Offset, [uint32]$Value)

    $Bytes[$Offset] = [byte]($Value -band 0xff)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xff)
    $Bytes[$Offset + 2] = [byte](($Value -shr 16) -band 0xff)
    $Bytes[$Offset + 3] = [byte](($Value -shr 24) -band 0xff)
}

function New-MinimalWin16Driver {
    $neStart = 0x40
    $resourceTableStart = $neStart + 0x40
    $residentTableStart = $resourceTableStart + 24
    $moduleTableStart = $residentTableStart + 1
    $entryTableStart = $moduleTableStart + 1
    $resourceStart = 0x200
    $resourceLength = 0x80
    $bytes = [byte[]]::new($resourceStart + $resourceLength)
    $bytes[0] = 0x4d
    $bytes[1] = 0x5a
    Set-UInt32LE $bytes 0x3c ([uint32]$neStart)
    $bytes[$neStart] = 0x4e
    $bytes[$neStart + 1] = 0x45
    Set-UInt16LE $bytes ($neStart + 0x04) ([uint16]($entryTableStart - $neStart))
    Set-UInt16LE $bytes ($neStart + 0x22) 0x0040
    Set-UInt16LE $bytes ($neStart + 0x24) ([uint16]($resourceTableStart - $neStart))
    Set-UInt16LE $bytes ($neStart + 0x26) ([uint16]($residentTableStart - $neStart))
    Set-UInt16LE $bytes ($neStart + 0x28) ([uint16]($moduleTableStart - $neStart))
    Set-UInt16LE $bytes ($neStart + 0x2a) ([uint16]($moduleTableStart - $neStart))
    Set-UInt16LE $bytes ($neStart + 0x34) 1
    $bytes[$neStart + 0x36] = 2
    Set-UInt16LE $bytes $resourceTableStart 4
    Set-UInt16LE $bytes ($resourceTableStart + 2) 0x8010
    Set-UInt16LE $bytes ($resourceTableStart + 4) 1
    Set-UInt32LE $bytes ($resourceTableStart + 6) 0
    Set-UInt16LE $bytes ($resourceTableStart + 10) ([uint16]($resourceStart -shr 4))
    Set-UInt16LE $bytes ($resourceTableStart + 12) ([uint16]($resourceLength -shr 4))
    Set-UInt16LE $bytes ($resourceTableStart + 14) 0x0030
    Set-UInt16LE $bytes ($resourceTableStart + 16) 0x8001
    Set-UInt32LE $bytes ($resourceTableStart + 18) 0
    Set-UInt16LE $bytes ($resourceTableStart + 22) 0
    Set-UInt16LE $bytes $resourceStart 72
    Set-UInt16LE $bytes ($resourceStart + 2) 52
    $key = [Text.Encoding]::ASCII.GetBytes("VS_VERSION_INFO`0")
    [Array]::Copy($key, 0, $bytes, $resourceStart + 4, $key.Length)
    $fixedInfo = $resourceStart + 20
    Set-UInt32LE $bytes $fixedInfo ([uint32]4277077181)
    Set-UInt32LE $bytes ($fixedInfo + 4) 0x00010000
    for ($field = 2; $field -lt 11; $field++) {
        Set-UInt32LE $bytes ($fixedInfo + ($field * 4)) ([uint32](0x01010101 * $field))
    }
    Set-UInt32LE $bytes ($fixedInfo + 44) 0x11223344
    Set-UInt32LE $bytes ($fixedInfo + 48) 0x55667788
    return [pscustomobject]@{
        Bytes = $bytes
        DateOffsets = @(($fixedInfo + 44), ($fixedInfo + 48))
    }
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

    Invoke-SelfTest 'Strict upstream TSV rejects ambiguous rows and headers' {
        $originalLock = [IO.File]::ReadAllText($lockPath)
        $header = @(
            'name', 'source_directory', 'repository', 'commit', 'upstream_license',
            'disposition', 'closure_manifest', 'closure_manifest_sha256', 'scope'
        )
        $validRow = @(
            'vmdisp9x', 'vmdisp9x', 'https://example.invalid/vmdisp9x.git',
            $displayCommit, 'MIT', 'planned', '', '', 'display-driver'
        ) -join "`t"
        $duplicateHeader = @($header)
        $duplicateHeader[1] = 'name'
        $mutations = @(
            [pscustomobject]@{
                Name = 'surplus field'
                Header = $header -join "`t"
                Row = $validRow + "`textra"
                Pattern = 'data row 1 has 10 fields'
            },
            [pscustomobject]@{
                Name = 'missing field'
                Header = $header -join "`t"
                Row = (@($validRow.Split([char]"`t"))[0..7] -join "`t")
                Pattern = 'data row 1 has 8 fields'
            },
            [pscustomobject]@{
                Name = 'reordered header'
                Header = (@($header[1], $header[0]) + @($header[2..8])) -join "`t"
                Row = $validRow
                Pattern = "header column 1 must be 'name'"
            },
            [pscustomobject]@{
                Name = 'extra header'
                Header = ($header + 'unexpected') -join "`t"
                Row = $validRow + "`textra"
                Pattern = 'header must contain exactly 9 ordered columns'
            },
            [pscustomobject]@{
                Name = 'duplicate header'
                Header = $duplicateHeader -join "`t"
                Row = $validRow
                Pattern = "duplicate header column 'name'"
            },
            [pscustomobject]@{
                Name = 'quoted field'
                Header = $header -join "`t"
                Row = $validRow.Replace('vmdisp9x', 'vmd"isp9x')
                Pattern = 'contains unsupported quoting'
            },
            [pscustomobject]@{
                Name = 'control character'
                Header = $header -join "`t"
                Row = $validRow.Replace('vmdisp9x', ('vmd' + [char]1 + 'isp9x'))
                Pattern = 'contains a control character'
            }
        )
        try {
            foreach ($mutation in $mutations) {
                $text = @(
                    '# SPDX-License-Identifier: GPL-3.0-only'
                    $mutation.Header
                    $mutation.Row
                ) -join "`r`n"
                [IO.File]::WriteAllText($lockPath, $text + "`r`n")
                Assert-Throws {
                    & $verifyScript -SourceRoot $sourceRoot -LockFile $lockPath `
                        -SourceName 'vmdisp9x'
                } $mutation.Pattern
            }

            . (Join-Path $PSScriptRoot 'strict-tsv.ps1')
            $parsed = @(ConvertFrom-StrictTsv `
                -Lines @('# comment', '', "left`tmiddle`tright", "x`ty`t") `
                -ExpectedHeader @('left', 'middle', 'right') -Name 'fixture TSV')
            Assert-Equal $parsed.Count 1
            Assert-Equal $parsed[0].right '' 'A trailing empty field was not preserved.'
            Assert-Throws {
                ConvertFrom-StrictTsv `
                    -Lines @("left`tmiddle`tright", "x`ty`ninside") `
                    -ExpectedHeader @('left', 'middle', 'right') -Name 'fixture TSV'
            } 'contains a control character'
            Assert-Throws {
                ConvertFrom-StrictTsv `
                    -Lines @("# comment`rsmuggled", "left`tmiddle`tright", "x`ty`tz") `
                    -ExpectedHeader @('left', 'middle', 'right') -Name 'fixture TSV'
            } 'contains a control character'
            Assert-Throws {
                ConvertFrom-StrictTsv `
                    -Lines @("left`tmiddle`tright", (('x' * 65) + "`ty`tz")) `
                    -ExpectedHeader @('left', 'middle', 'right') -Name 'fixture TSV' `
                    -MaximumLineBytes 64
            } 'exceeds the 64-byte limit'
        }
        finally {
            [IO.File]::WriteAllText($lockPath, $originalLock)
        }
    }

    Invoke-SelfTest 'Strict TSV file decoding is UTF-8 deterministic and bounded' {
        . (Join-Path $PSScriptRoot 'strict-tsv.ps1')
        $fixturePath = Join-Path $testRoot 'strict-utf8.tsv'
        $expectedHeader = @('left', 'right')
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        [byte[]]$validBytes = $utf8.GetBytes("left`tright`ncaf$([char]0x00e9)`tok`n")
        [IO.File]::WriteAllBytes($fixturePath, $validBytes)

        $parsed = @(Read-StrictTsvFile -Path $fixturePath `
            -ExpectedHeader $expectedHeader -Name 'UTF-8 fixture' `
            -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
            -MaximumPhysicalLines 8)
        Assert-Equal $parsed.Count 1
        Assert-Equal $parsed[0].left "caf$([char]0x00e9)" `
            'The strict byte decoder did not preserve the UTF-8 field.'

        [byte[]]$oneBom = New-Object byte[] ($validBytes.Length + 3)
        $oneBom[0] = 0xef
        $oneBom[1] = 0xbb
        $oneBom[2] = 0xbf
        [Array]::Copy($validBytes, 0, $oneBom, 3, $validBytes.Length)
        [IO.File]::WriteAllBytes($fixturePath, $oneBom)
        $bomParsed = @(Read-StrictTsvFile -Path $fixturePath `
            -ExpectedHeader $expectedHeader -Name 'UTF-8 fixture' `
            -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
            -MaximumPhysicalLines 8)
        Assert-Equal $bomParsed[0].left "caf$([char]0x00e9)" `
            'One leading UTF-8 BOM was not handled consistently.'

        [byte[]]$twoBoms = New-Object byte[] ($validBytes.Length + 6)
        [Array]::Copy($oneBom, 0, $twoBoms, 0, 3)
        [Array]::Copy($oneBom, 0, $twoBoms, 3, $oneBom.Length)
        [IO.File]::WriteAllBytes($fixturePath, $twoBoms)
        Assert-Throws {
            Read-StrictTsvFile -Path $fixturePath `
                -ExpectedHeader $expectedHeader -Name 'UTF-8 fixture' `
                -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
                -MaximumPhysicalLines 8
        } 'unsupported UTF-8 byte-order mark'

        [byte[]]$prefix = [Text.Encoding]::ASCII.GetBytes("left`tright`nx`t")
        [byte[]]$malformed = New-Object byte[] ($prefix.Length + 3)
        [Array]::Copy($prefix, 0, $malformed, 0, $prefix.Length)
        $malformed[$prefix.Length] = 0xc3
        $malformed[$prefix.Length + 1] = 0x28
        $malformed[$prefix.Length + 2] = 0x0a
        [IO.File]::WriteAllBytes($fixturePath, $malformed)
        Assert-Throws {
            Read-StrictTsvFile -Path $fixturePath `
                -ExpectedHeader $expectedHeader -Name 'UTF-8 fixture' `
                -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
                -MaximumPhysicalLines 8
        } 'not valid UTF-8'

        [IO.File]::WriteAllBytes(
            $fixturePath,
            $utf8.GetBytes("# comment`n`nleft`tright`nx`ty")
        )
        Assert-Throws {
            Read-StrictTsvFile -Path $fixturePath `
                -ExpectedHeader $expectedHeader -Name 'UTF-8 fixture' `
                -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
                -MaximumPhysicalLines 3
        } 'exceeds the 3-physical-line limit'

        [IO.File]::WriteAllBytes($fixturePath, $validBytes)
        Assert-Throws {
            Read-StrictTsvFile -Path $fixturePath `
                -ExpectedHeader $expectedHeader -Name 'UTF-8 fixture' `
                -MaximumBytes ($validBytes.Length - 1) -MaximumRows 4 `
                -MaximumLineBytes 128 -MaximumPhysicalLines 8
        } 'byte limit'
        [IO.File]::WriteAllBytes(
            $fixturePath,
            $utf8.GetBytes("left`tright`rx`ty")
        )
        Assert-Throws {
            Read-StrictTsvFile -Path $fixturePath `
                -ExpectedHeader $expectedHeader -Name 'UTF-8 fixture' `
                -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
                -MaximumPhysicalLines 8
        } 'bare carriage return'
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

    Invoke-SelfTest 'A ready build atomically prepares, builds, and verifies exact outputs' {
        $buildEnvironmentNames = @('WATCOM', 'EDPATH', 'INCLUDE', 'PATH')
        $savedBuildEnvironment = @{}
        foreach ($name in $buildEnvironmentNames) {
            $item = Get-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
            $savedBuildEnvironment[$name] = [pscustomobject]@{
                Present = $null -ne $item
                Name = if ($null -eq $item) { $name } else { [string]$item.Name }
                Value = if ($null -eq $item) { $null } else { [string]$item.Value }
            }
        }
        foreach ($name in $buildEnvironmentNames) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        }
        Set-Item -LiteralPath Env:WatCom -Value 'caller-watcom'
        Set-Item -LiteralPath Env:PATH -Value ([string]$savedBuildEnvironment.PATH.Value)
        $expectedPathEnvironment = [Environment]::GetEnvironmentVariable('PATH', 'Process')
        $assertBuildEnvironmentRestored = {
            $watcomItem = Get-Item -LiteralPath Env:WATCOM -ErrorAction SilentlyContinue
            Assert-True ($null -ne $watcomItem) 'Builder removed the caller WATCOM value.'
            Assert-Equal ([string]$watcomItem.Name) 'WatCom' `
                'Builder did not preserve the mixed-case WATCOM key.'
            Assert-Equal ([string]$watcomItem.Value) 'caller-watcom' `
                'Builder did not restore the caller WATCOM value.'
            foreach ($name in @('EDPATH', 'INCLUDE')) {
                Assert-True (-not (Test-Path -LiteralPath ('Env:' + $name))) `
                    "Builder leaked the $name environment variable."
            }
            Assert-Equal ([Environment]::GetEnvironmentVariable('PATH', 'Process')) `
                $expectedPathEnvironment 'Builder did not restore PATH exactly.'
        }
        try {
        $prepareScript = Join-Path $PSScriptRoot 'prepare-win98-derived-sources.ps1'
        $toolchainRoot = Join-Path $testRoot 'toolchains'
        $downloadDirectory = Join-Path $toolchainRoot 'downloads'
        $extractedRoot = Join-Path $toolchainRoot 'extracted'
        foreach ($directory in @(
            $downloadDirectory,
            (Join-Path $extractedRoot 'binnt'),
            (Join-Path $extractedRoot 'binw'),
            (Join-Path $extractedRoot 'eddat'),
            (Join-Path $extractedRoot 'h\nt'),
            (Join-Path $extractedRoot 'h\win')
        )) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $archivePath = Join-Path $downloadDirectory 'fixture-toolchain.exe'
        [IO.File]::WriteAllText($archivePath, 'fixture archive')
        $toolchainPath = Join-Path $extractedRoot 'binnt\write-artifact.cmd'
        [IO.File]::WriteAllText(
            $toolchainPath,
            "@echo off`r`n<nul set /p `"=abc`" > artifact.bin`r`ncopy /b input.drv artifact.drv >nul`r`necho %PATH%> path.txt`r`nexit /b 0`r`n",
            [Text.Encoding]::ASCII
        )
        $mutationToolchainPath = Join-Path $extractedRoot 'binnt\mutate-artifact.cmd'
        [IO.File]::WriteAllText(
            $mutationToolchainPath,
            "@echo off`r`n<nul set /p `"=x`" >> artifact.bin`r`n<nul set /p `"=ok`" > second.bin`r`nexit /b 0`r`n",
            [Text.Encoding]::ASCII
        )
        $junctionTarget = Join-Path $testRoot 'junction-target'
        [void](New-Item -ItemType Directory -Path $junctionTarget)
        $junctionToolchainPath = Join-Path $extractedRoot 'binnt\junction-artifact.cmd'
        [IO.File]::WriteAllText(
            $junctionToolchainPath,
            "@echo off`r`nmklink /J escape `"$junctionTarget`" >nul`r`ncopy /b input.drv escape\escaped.drv >nul`r`nexit /b 0`r`n",
            [Text.Encoding]::ASCII
        )
        $buildTreeJunctionTarget = Join-Path $testRoot 'build-tree-junction-target'
        [void](New-Item -ItemType Directory -Path $buildTreeJunctionTarget)
        [IO.File]::WriteAllText((Join-Path $buildTreeJunctionTarget 'sentinel.txt'), 'external')
        $buildTreeJunctionToolchainPath = Join-Path $extractedRoot 'binnt\build-tree-junction.cmd'
        [IO.File]::WriteAllText(
            $buildTreeJunctionToolchainPath,
            "@echo off`r`n<nul set /p `"=abc`" > artifact.bin`r`ncopy /b input.drv artifact.drv >nul`r`nmklink /J %1 `"$buildTreeJunctionTarget`" >nul`r`nexit /b 0`r`n",
            [Text.Encoding]::ASCII
        )
        $extractedDescriptor = & $prepareScript -DescribeTree $extractedRoot | ConvertFrom-Json
        $toolchainLock = [ordered]@{
            _spdx = 'GPL-3.0-only'
            schema = 1
            name = 'fixture-toolchain'
            archive = [ordered]@{
                relative_path = 'downloads/fixture-toolchain.exe'
                bytes = (Get-Item $archivePath).Length
                sha256 = (Get-FileHash $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
                md5 = (Get-FileHash $archivePath -Algorithm MD5).Hash.ToLowerInvariant()
            }
            extracted = [ordered]@{
                relative_path = 'extracted'
                file_count = $extractedDescriptor.file_count
                directory_count = $extractedDescriptor.directory_count
                total_entries = $extractedDescriptor.total_entries
                aggregate_bytes = $extractedDescriptor.aggregate_bytes
                maximum_file_bytes = $extractedDescriptor.maximum_file_bytes
                maximum_path_bytes = $extractedDescriptor.maximum_path_bytes
                digest_algorithm = 'retvrn99-file-tree-sha256-v1'
                sha256 = $extractedDescriptor.sha256
            }
            environment = [ordered]@{
                watcom_root = '.'
                edpath = 'eddat'
                include = @('h/nt', 'h/win', 'h')
                path_prefixes = @('binnt', 'binw')
            }
        }
        $toolchainLockPath = Join-Path $testRoot 'toolchain.lock.json'
        [IO.File]::WriteAllText($toolchainLockPath, ($toolchainLock | ConvertTo-Json -Depth 8))

        $schema2ArchivePath = Join-Path $downloadDirectory 'fixture-schema2.zip'
        [IO.File]::WriteAllText($schema2ArchivePath, 'fixture schema 2 archive')
        $schema2Root = Join-Path $toolchainRoot 'extracted-schema2'
        $schema2Bin = Join-Path $schema2Root 'bin'
        New-Item -ItemType Directory -Path $schema2Bin -Force | Out-Null
        $schema2ToolchainPath = Join-Path $schema2Bin 'write-schema2-artifact.cmd'
        [IO.File]::WriteAllText(
            $schema2ToolchainPath,
            "@echo off`r`nif defined WATCOM exit /b 21`r`nif defined EDPATH exit /b 22`r`nif defined INCLUDE exit /b 23`r`n<nul set /p `"=xyz`" > schema2.bin`r`nexit /b 0`r`n",
            [Text.Encoding]::ASCII
        )
        $schema2Descriptor = & $prepareScript -DescribeTree $schema2Root | ConvertFrom-Json
        $schema2Lock = [ordered]@{
            _spdx = 'GPL-3.0-only'
            schema = 2
            name = 'fixture-schema2'
            archive = [ordered]@{
                relative_path = 'downloads/fixture-schema2.zip'
                bytes = (Get-Item $schema2ArchivePath).Length
                sha256 = (Get-FileHash $schema2ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
                md5 = (Get-FileHash $schema2ArchivePath -Algorithm MD5).Hash.ToLowerInvariant()
            }
            extracted = [ordered]@{
                relative_path = 'extracted-schema2'
                file_count = $schema2Descriptor.file_count
                directory_count = $schema2Descriptor.directory_count
                total_entries = $schema2Descriptor.total_entries
                aggregate_bytes = $schema2Descriptor.aggregate_bytes
                maximum_file_bytes = $schema2Descriptor.maximum_file_bytes
                maximum_path_bytes = $schema2Descriptor.maximum_path_bytes
                digest_algorithm = 'retvrn99-file-tree-sha256-v1'
                sha256 = $schema2Descriptor.sha256
            }
            environment = [ordered]@{ path_prefixes = @('bin') }
        }
        $schema2LockPath = Join-Path $testRoot 'toolchain-schema2.lock.json'
        [IO.File]::WriteAllText($schema2LockPath, ($schema2Lock | ConvertTo-Json -Depth 8))

        $overlayPath = Join-Path $testRoot 'overlay'
        New-Item -ItemType Directory -Path $overlayPath | Out-Null
        [IO.File]::WriteAllText((Join-Path $overlayPath 'marker.txt'), 'derived marker')
        $driverFixture = New-MinimalWin16Driver
        [IO.File]::WriteAllBytes((Join-Path $overlayPath 'input.drv'), $driverFixture.Bytes)
        $expectedPath = Join-Path $testRoot 'expected-derived'
        New-Item -ItemType Directory -Path $expectedPath | Out-Null
        Copy-Item -LiteralPath (Join-Path $displayCheckout 'fixture.txt') -Destination $expectedPath
        Copy-Item -LiteralPath (Join-Path $overlayPath 'marker.txt') -Destination $expectedPath
        Copy-Item -LiteralPath (Join-Path $overlayPath 'input.drv') -Destination $expectedPath
        $overlayDescriptor = & $prepareScript -DescribeTree $overlayPath | ConvertFrom-Json
        $derivedDescriptor = & $prepareScript -DescribeTree $expectedPath | ConvertFrom-Json
        $derivedPlan = [ordered]@{
            _spdx = 'GPL-3.0-only'
            schema = 2
            status = 'ready'
            reason = ''
            recipes = @([ordered]@{
                name = 'vmdisp9x-derived'
                upstream_name = 'vmdisp9x'
                source_directory = 'vmdisp9x'
                destination_directory = 'vmdisp9x-derived'
                patches = @()
                overlays = @([ordered]@{
                    relative_path = 'overlay'
                    destination_relative_path = '.'
                    replace_existing = $false
                    tree = $overlayDescriptor
                })
                output_tree = $derivedDescriptor
            })
        }
        $derivedPlanPath = Join-Path $testRoot 'derived-source-plan.json'
        [IO.File]::WriteAllText($derivedPlanPath, ($derivedPlan | ConvertTo-Json -Depth 12))
        $artifactBytes = [byte[]](0x61, 0x62, 0x63)
        $markerBytes = [Text.Encoding]::UTF8.GetBytes('derived marker')
        $expectedChildPath = "$extractedRoot\binnt;$extractedRoot\binw;$expectedPathEnvironment"
        $expectedChildPathBytes = [Text.Encoding]::ASCII.GetBytes("$expectedChildPath`r`n")
        $normalizedDriverBytes = [byte[]]$driverFixture.Bytes.Clone()
        foreach ($dateOffset in $driverFixture.DateOffsets) {
            for ($index = 0; $index -lt 4; $index++) {
                $normalizedDriverBytes[$dateOffset + $index] = 0
            }
        }
        $plan = [ordered]@{
            _spdx = 'GPL-3.0-only'
            schema = 2
            status = 'ready'
            reason = ''
            derived_source_plan = [ordered]@{
                relative_path = 'derived-source-plan.json'
                sha256 = (Get-FileHash $derivedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            toolchain_lock = [ordered]@{
                relative_path = 'toolchain.lock.json'
                sha256 = (Get-FileHash $toolchainLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            upstream_lock = [ordered]@{
                relative_path = 'upstream.lock.tsv'
                sha256 = (Get-FileHash $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            toolchains = @(
                [ordered]@{
                    name = 'fixture-toolchain'
                    relative_path = 'binnt/write-artifact.cmd'
                    sha256 = (Get-FileHash $toolchainPath -Algorithm SHA256).Hash.ToLowerInvariant()
                },
                [ordered]@{
                    name = 'mutation-toolchain'
                    relative_path = 'binnt/mutate-artifact.cmd'
                    sha256 = (Get-FileHash $mutationToolchainPath -Algorithm SHA256).Hash.ToLowerInvariant()
                },
                [ordered]@{
                    name = 'junction-toolchain'
                    relative_path = 'binnt/junction-artifact.cmd'
                    sha256 = (Get-FileHash $junctionToolchainPath -Algorithm SHA256).Hash.ToLowerInvariant()
                },
                [ordered]@{
                    name = 'build-tree-junction-toolchain'
                    relative_path = 'binnt/build-tree-junction.cmd'
                    sha256 = (Get-FileHash $buildTreeJunctionToolchainPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            )
            steps = @([ordered]@{
                name = 'build-display'
                recipe = 'vmdisp9x-derived'
                toolchain = 'fixture-toolchain'
                working_directory = '.'
                arguments = @()
                normalizations = @([ordered]@{
                    kind = 'win16-version-date'
                    relative_path = 'artifact.drv'
                })
                outputs = @(
                    [ordered]@{
                        relative_path = 'artifact.bin'
                        origin = 'build'
                        sha256 = Get-ByteHash $artifactBytes
                        bytes = $artifactBytes.Length
                    },
                    [ordered]@{
                        relative_path = 'artifact.drv'
                        origin = 'build'
                        sha256 = Get-ByteHash $normalizedDriverBytes
                        bytes = $normalizedDriverBytes.Length
                    },
                    [ordered]@{
                        relative_path = 'marker.txt'
                        origin = 'derived'
                        sha256 = Get-ByteHash $markerBytes
                        bytes = $markerBytes.Length
                    },
                    [ordered]@{
                        relative_path = 'path.txt'
                        origin = 'build'
                        sha256 = Get-ByteHash $expectedChildPathBytes
                        bytes = $expectedChildPathBytes.Length
                    }
                )
            })
        }
        $planPath = Join-Path $testRoot 'build-plan.json'
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))

        $validBuildPlanText = [IO.File]::ReadAllText($planPath)
        $duplicateBuildPlanText = $validBuildPlanText -replace `
            '("schema"\s*:\s*2\s*,)', '$1 "SCHEMA": 2,'
        Assert-True ($duplicateBuildPlanText -cne $validBuildPlanText) `
            'The duplicate build-plan JSON mutation was not applied.'
        try {
            [IO.File]::WriteAllText($planPath, $duplicateBuildPlanText)
            Assert-Throws {
                & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                    -OutputRoot (Join-Path $testRoot 'duplicate-build-plan-json') `
                    -BuildPlan $planPath -LockFile $lockPath
            } "Duplicate JSON property 'SCHEMA'"

            $plan.schema = '2'
            [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
            Assert-Throws {
                & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                    -OutputRoot (Join-Path $testRoot 'typed-build-plan-json') `
                    -BuildPlan $planPath -LockFile $lockPath
            } 'schema must be a JSON integer'
        }
        finally {
            $plan.schema = 2
            [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        }

        $strictBuildLockText = [IO.File]::ReadAllText($lockPath)
        try {
            $strictBuildLockLines = @([IO.File]::ReadAllLines($lockPath))
            $strictBuildLockLines[1] += "`tunexpected"
            [IO.File]::WriteAllLines($lockPath, $strictBuildLockLines)
            $plan.upstream_lock.sha256 = (
                Get-FileHash $lockPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
            Assert-Throws {
                & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                    -OutputRoot (Join-Path $testRoot 'strict-build-lock') `
                    -BuildPlan $planPath -LockFile $lockPath
            } 'upstream lock header must contain exactly 9 ordered columns'
        }
        finally {
            [IO.File]::WriteAllText($lockPath, $strictBuildLockText)
            $plan.upstream_lock.sha256 = (
                Get-FileHash $lockPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        }

        $componentManifestRelativePath = 'component-closures/blocked.json'
        $componentManifestPath = Join-Path $testRoot 'component-closures\blocked.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $componentManifestPath) | Out-Null
        $componentManifest = [ordered]@{
            _spdx = 'GPL-3.0-only'
            schema = 1
            status = 'blocked'
            reason = 'Fixture component source closure remains blocked.'
            upstream_name = 'fixture-component'
            owning_commit = $displayCommit
            source_prefixes = @()
            notices = @()
            files = @()
        }
        [IO.File]::WriteAllText(
            $componentManifestPath,
            ($componentManifest | ConvertTo-Json -Depth 8)
        )
        Write-MixedUpstreamLock -Path $lockPath -DisplayCommit $displayCommit `
            -ManifestRelativePath $componentManifestRelativePath `
            -ManifestHash ((Get-FileHash $componentManifestPath -Algorithm SHA256).Hash.ToLowerInvariant())
        $plan.upstream_lock.sha256 = (Get-FileHash $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        $mixedBuildOutput = Join-Path $testRoot 'mixed-lock-build'
        $componentManifestText = [IO.File]::ReadAllText($componentManifestPath)
        try {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot $mixedBuildOutput -BuildPlan $planPath -LockFile $lockPath `
                -BeforeLinkedMetadataUse {
                    [IO.File]::AppendAllText($componentManifestPath, ' ')
                } | Out-Null
        }
        finally {
            [IO.File]::WriteAllText($componentManifestPath, $componentManifestText)
            Write-UpstreamLock -Path $lockPath -DisplayCommit $displayCommit
            $plan.upstream_lock.sha256 = (Get-FileHash $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        }
        Assert-True (Test-Path -LiteralPath (
            Join-Path $mixedBuildOutput 'vmdisp9x-derived\artifact.bin'
        ) -PathType Leaf) 'The mixed-lock build did not publish its verified output.'
        & $assertBuildEnvironmentRestored

        $plan.steps[0].outputs[0].relative_path = 'unexpected.drv'
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot (Join-Path $testRoot 'invalid-drv') `
                -BuildPlan $planPath -LockFile $lockPath
        } 'Every DRV output.*explicit Win16 normalization'
        $plan.steps[0].outputs[0].relative_path = 'artifact.bin'
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))

        $normalBuildSteps = @($plan.steps)
        $plan.steps = @([ordered]@{
            name = 'reject-junction-output'
            recipe = 'vmdisp9x-derived'
            toolchain = 'junction-toolchain'
            working_directory = '.'
            arguments = @()
            normalizations = @([ordered]@{
                kind = 'win16-version-date'
                relative_path = 'escape/escaped.drv'
            })
            outputs = @([ordered]@{
                relative_path = 'escape/escaped.drv'
                origin = 'build'
                sha256 = Get-ByteHash $normalizedDriverBytes
                bytes = $normalizedDriverBytes.Length
            })
        })
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot (Join-Path $testRoot 'junction-output') `
                -BuildPlan $planPath -LockFile $lockPath
        } 'Reparse-point component.*normalization'
        $escapedDriver = Join-Path $junctionTarget 'escaped.drv'
        Assert-True (Test-Path -LiteralPath $escapedDriver -PathType Leaf)
        Assert-Equal (Get-ByteHash ([IO.File]::ReadAllBytes($escapedDriver))) `
            (Get-ByteHash $driverFixture.Bytes) 'Normalizer followed a build-created junction.'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'junction-output')))
        & $assertBuildEnvironmentRestored
        $plan.steps = $normalBuildSteps
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))

        $junctionStep = [ordered]@{
            name = 'create-undeclared-junction'
            recipe = 'vmdisp9x-derived'
            toolchain = 'build-tree-junction-toolchain'
            working_directory = '.'
            arguments = @('escape')
            normalizations = @([ordered]@{
                kind = 'win16-version-date'
                relative_path = 'artifact.drv'
            })
            outputs = @(
                [ordered]@{
                    relative_path = 'artifact.bin'
                    origin = 'build'
                    sha256 = Get-ByteHash $artifactBytes
                    bytes = $artifactBytes.Length
                },
                [ordered]@{
                    relative_path = 'artifact.drv'
                    origin = 'build'
                    sha256 = Get-ByteHash $normalizedDriverBytes
                    bytes = $normalizedDriverBytes.Length
                }
            )
        }
        $plan.steps = @($junctionStep)
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot (Join-Path $testRoot 'undeclared-junction-output') `
                -BuildPlan $planPath -LockFile $lockPath
        } 'Reparse points are not allowed in the private build tree after step'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $buildTreeJunctionTarget 'sentinel.txt'))) 'external'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'undeclared-junction-output')))

        $junctionStep.arguments = @('later')
        $plan.steps = @($junctionStep, [ordered]@{
            name = 'reject-later-working-directory'
            recipe = 'vmdisp9x-derived'
            toolchain = 'mutation-toolchain'
            working_directory = 'later'
            arguments = @()
            normalizations = @()
            outputs = @([ordered]@{
                relative_path = 'second.bin'
                origin = 'build'
                sha256 = Get-ByteHash ([byte[]](0x6f, 0x6b))
                bytes = 2
            })
        })
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot (Join-Path $testRoot 'later-working-junction-output') `
                -BuildPlan $planPath -LockFile $lockPath
        } 'Reparse points are not allowed in the private build tree after step'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'later-working-junction-output')))
        $plan.steps = $normalBuildSteps
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))

        $originalDerivedPlan = [IO.File]::ReadAllText($derivedPlanPath)
        [IO.File]::AppendAllText($derivedPlanPath, ' ')
        try {
            Assert-Throws {
                & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                    -OutputRoot (Join-Path $testRoot 'tampered-link') `
                    -BuildPlan $planPath -LockFile $lockPath
            } 'derived_source_plan failed its exact SHA-256 check'
        }
        finally {
            [IO.File]::WriteAllText($derivedPlanPath, $originalDerivedPlan)
        }

        $originalSteps = @($plan.steps)
        $plan.steps = @($originalSteps + [ordered]@{
            name = 'mutate-prior-output'
            recipe = 'vmdisp9x-derived'
            toolchain = 'mutation-toolchain'
            working_directory = '.'
            arguments = @()
            normalizations = @()
            outputs = @([ordered]@{
                relative_path = 'second.bin'
                origin = 'build'
                sha256 = Get-ByteHash ([byte[]](0x6f, 0x6b))
                bytes = 2
            })
        })
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot (Join-Path $testRoot 'mutated-prior-output') `
                -BuildPlan $planPath -LockFile $lockPath
        } 'Previously verified build output changed before publication'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'mutated-prior-output')))
        $plan.steps = $originalSteps
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12))

        $alternateLockPath = Join-Path $testRoot 'alternate-upstream.lock.tsv'
        [IO.File]::WriteAllBytes($alternateLockPath, [IO.File]::ReadAllBytes($lockPath))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot (Join-Path $testRoot 'alternate-lock-output') `
                -BuildPlan $planPath -LockFile $alternateLockPath
        } 'must resolve to the SHA-linked upstream_lock path'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'alternate-lock-output')))

        $schema3Plan = ($plan | ConvertTo-Json -Depth 12) | ConvertFrom-Json
        $schema3Plan.schema = 3
        $schema3Plan.PSObject.Properties.Remove('toolchain_lock')
        $schema3Plan | Add-Member -NotePropertyName toolchain_locks -NotePropertyValue @(
            [pscustomobject]@{
                name = 'fixture-lock'
                relative_path = 'toolchain.lock.json'
                sha256 = (Get-FileHash $toolchainLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
            },
            [pscustomobject]@{
                name = 'fixture-schema2-lock'
                relative_path = 'toolchain-schema2.lock.json'
                sha256 = (Get-FileHash $schema2LockPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        )
        foreach ($schema3Toolchain in $schema3Plan.toolchains) {
            $schema3Toolchain | Add-Member -NotePropertyName lock -NotePropertyValue 'fixture-lock'
        }
        $schema3Plan.toolchains += [pscustomobject]@{
            name = 'fixture-schema2-toolchain'
            lock = 'fixture-schema2-lock'
            relative_path = 'bin/write-schema2-artifact.cmd'
            sha256 = (Get-FileHash $schema2ToolchainPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $schema3Plan.steps += [pscustomobject]@{
            name = 'build-schema2-after-watcom'
            recipe = 'vmdisp9x-derived'
            toolchain = 'fixture-schema2-toolchain'
            working_directory = '.'
            arguments = @()
            normalizations = @()
            outputs = @([pscustomobject]@{
                relative_path = 'schema2.bin'
                origin = 'build'
                sha256 = Get-ByteHash ([byte[]](0x78, 0x79, 0x7a))
                bytes = 3
            })
        }
        $schema3PlanPath = Join-Path $testRoot 'build-plan-schema3.json'
        [IO.File]::WriteAllText($schema3PlanPath, ($schema3Plan | ConvertTo-Json -Depth 12))
        $schema3Output = Join-Path $testRoot 'verified-schema3-build'
        & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
            -OutputRoot $schema3Output -BuildPlan $schema3PlanPath -LockFile $lockPath | Out-Null
        Assert-True (Test-Path -LiteralPath (
            Join-Path $schema3Output 'vmdisp9x-derived\artifact.bin'
        ) -PathType Leaf)
        Assert-True (Test-Path -LiteralPath (
            Join-Path $schema3Output 'vmdisp9x-derived\schema2.bin'
        ) -PathType Leaf)
        & $assertBuildEnvironmentRestored

        $schema3Plan.toolchain_locks = @(
            $schema3Plan.toolchain_locks + $schema3Plan.toolchain_locks[0]
        )
        [IO.File]::WriteAllText($schema3PlanPath, ($schema3Plan | ConvertTo-Json -Depth 12))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot (Join-Path $testRoot 'duplicate-schema3-lock') `
                -BuildPlan $schema3PlanPath -LockFile $lockPath
        } 'Invalid or duplicate toolchain lock link'
        $schema3Plan.toolchain_locks = @($schema3Plan.toolchain_locks[0], $schema3Plan.toolchain_locks[1])
        $schema3Plan.toolchains[0].lock = 'missing-lock'
        [IO.File]::WriteAllText($schema3PlanPath, ($schema3Plan | ConvertTo-Json -Depth 12))
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot (Join-Path $testRoot 'missing-schema3-lock') `
                -BuildPlan $schema3PlanPath -LockFile $lockPath
        } 'references an unknown lock'

        $buildOutput = Join-Path $testRoot 'verified-build'
        $savedNativeExitCode = $global:LASTEXITCODE
        $linkedDerivedText = [IO.File]::ReadAllText($derivedPlanPath)
        $linkedToolchainText = [IO.File]::ReadAllText($toolchainLockPath)
        $linkedUpstreamText = [IO.File]::ReadAllText($lockPath)
        try {
            $global:LASTEXITCODE = 17
            $output = @(
                & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                    -OutputRoot $buildOutput -BuildPlan $planPath -LockFile $lockPath `
                    -BeforeLinkedMetadataUse {
                        param($linkedDerivedPath, $linkedToolchainPath, $linkedUpstreamPath)
                        [IO.File]::AppendAllText($linkedDerivedPath, ' ')
                        [IO.File]::AppendAllText($linkedToolchainPath, ' ')
                        [IO.File]::AppendAllText($linkedUpstreamPath, ' ')
                    }
            )
        }
        finally {
            [IO.File]::WriteAllText($derivedPlanPath, $linkedDerivedText)
            [IO.File]::WriteAllText($toolchainLockPath, $linkedToolchainText)
            [IO.File]::WriteAllText($lockPath, $linkedUpstreamText)
            $global:LASTEXITCODE = $savedNativeExitCode
        }
        Assert-True (($output -join [Environment]::NewLine) -match 'Verified 1 immutable')
        Assert-True (($output -join [Environment]::NewLine) -match 'Normalized Win16 version date')
        Assert-True (($output -join [Environment]::NewLine) -match 'Built, normalized, and verified 4')
        $artifactPath = Join-Path $buildOutput 'vmdisp9x-derived\artifact.bin'
        Assert-True (Test-Path -LiteralPath $artifactPath -PathType Leaf)
        Assert-Equal (([BitConverter]::ToString(
            [IO.File]::ReadAllBytes($artifactPath)
        ) -replace '-', '')) '616263'
        $driverPath = Join-Path $buildOutput 'vmdisp9x-derived\artifact.drv'
        Assert-Equal (Get-ByteHash ([IO.File]::ReadAllBytes($driverPath))) (Get-ByteHash $normalizedDriverBytes)
        Assert-Equal ([IO.File]::ReadAllText(
            (Join-Path $buildOutput 'vmdisp9x-derived\path.txt')
        ).TrimEnd("`r", "`n")) $expectedChildPath 'Child build PATH did not retain the exact host suffix.'
        & $assertBuildEnvironmentRestored
        Assert-Throws {
            & $buildScript -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -OutputRoot $buildOutput -BuildPlan $planPath -LockFile $lockPath
        } 'already exists; refusing to overwrite'
        & $assertBuildEnvironmentRestored
        Assert-Equal (Invoke-Git @('-C', $displayCheckout, 'status', '--porcelain')) ''
        }
        finally {
            foreach ($name in $buildEnvironmentNames) {
                Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
                if ($savedBuildEnvironment[$name].Present) {
                    Set-Item -LiteralPath (
                        'Env:' + [string]$savedBuildEnvironment[$name].Name
                    ) -Value ([string]$savedBuildEnvironment[$name].Value)
                }
            }
        }
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

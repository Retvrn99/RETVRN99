# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'strict-tsv.ps1')
$script:Failures = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Assert-Throws {
    param([Parameter(Mandatory = $true)][scriptblock]$Body, [string]$Pattern)
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
    param([Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS: $Name"
    }
    catch {
        $script:Failures++
        [Console]::Error.WriteLine("FAIL: $Name`n  $($_.Exception.Message)")
    }
}

function New-DirectoryReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target)
    $kind = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        'Junction'
    }
    else {
        'SymbolicLink'
    }
    New-Item -ItemType $kind -Path $Path -Target $Target | Out-Null
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-strict-input-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false, $true)

try {
    Invoke-SelfTest 'A bounded JSON snapshot keeps bytes, hash, and value coherent' {
        $path = Join-Path $testRoot 'coherent.json'
        [byte[]]$bytes = $utf8.GetBytes('{"value":1}')
        [IO.File]::WriteAllBytes($path, $bytes)
        $snapshot = Read-GswStrictJsonFileSnapshot -Path $path `
            -Name 'coherent JSON' -MaximumBytes 1024
        Assert-Equal $snapshot.Length ([UInt64]$bytes.Length)
        Assert-Equal $snapshot.Sha256 (Get-GswSha256Hex $bytes)
        Assert-Equal $snapshot.Value.value 1
    }

    Invoke-SelfTest 'Strict JSON accepts canonical Boolean and null primitives' {
        $value = ConvertFrom-GswStrictJson `
            -Json '{"truth":true,"falsehood":false,"empty":null}' `
            -Source 'canonical primitives'
        Assert-Equal $value.truth $true
        Assert-Equal $value.falsehood $false
        Assert-Equal $value.empty $null
    }

    Invoke-SelfTest 'Strict JSON accepts canonical number forms' {
        foreach ($json in @(
            '0', '-0', '17', '-17', '0.125', '-0.125',
            '1e3', '1E+3', '1e-3', '-1.25E+2'
        )) {
            $null = ConvertFrom-GswStrictJson -Json $json -Source "number $json"
        }
    }

    Invoke-SelfTest 'Strict JSON rejects non-RFC primitive tokens' {
        foreach ($json in @(
            '01', '-01', '+1', 'NaN', 'Infinity', '-Infinity',
            '1.', '-0.', '1e', '1e+', '1E-', 'arbitrary'
        )) {
            Assert-Throws {
                ConvertFrom-GswStrictJson -Json $json -Source "invalid primitive $json"
            } 'Invalid JSON primitive token'
        }
    }

    Invoke-SelfTest 'Strict JSON rejects block and line comments' {
        foreach ($json in @(
            '{"value":1/* comment */}',
            ("{`"value`":1// comment`n}")
        )) {
            Assert-Throws {
                ConvertFrom-GswStrictJson -Json $json -Source 'commented JSON'
            } 'Invalid JSON primitive token'
        }
    }

    Invoke-SelfTest 'A same-length content replacement is rejected' {
        $directory = Join-Path $testRoot 'content-replacement'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $path = Join-Path $directory 'input.json'
        $replacement = Join-Path $directory 'replacement.json'
        [IO.File]::WriteAllBytes($path, $utf8.GetBytes('{"value":1}'))
        [IO.File]::WriteAllBytes($replacement, $utf8.GetBytes('{"value":2}'))
        Assert-Throws {
            Read-GswBoundedFileSnapshot -Path $path -Name 'mutable JSON' `
                -MaximumBytes 1024 -BeforePostReadCheck {
                    param($openedPath)
                    Move-Item -LiteralPath $replacement -Destination $openedPath -Force
                }
        } 'changed during its bounded read'
    }

    Invoke-SelfTest 'A same-content file identity replacement is rejected' {
        $directory = Join-Path $testRoot 'identity-replacement'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $path = Join-Path $directory 'input.json'
        $replacement = Join-Path $directory 'replacement.json'
        [byte[]]$bytes = $utf8.GetBytes('{"value":1}')
        [IO.File]::WriteAllBytes($path, $bytes)
        [IO.File]::WriteAllBytes($replacement, $bytes)
        [IO.File]::SetLastWriteTimeUtc($replacement, [DateTime]::UtcNow.AddMinutes(-5))
        Assert-Throws {
            Read-GswBoundedFileSnapshot -Path $path -Name 'replaceable JSON' `
                -MaximumBytes 1024 -BeforePostReadCheck {
                    param($openedPath)
                    Move-Item -LiteralPath $replacement -Destination $openedPath -Force
                }
        } 'changed during its bounded read'
    }

    Invoke-SelfTest 'An ancestor replacement during a read is rejected' {
        $parent = Join-Path $testRoot 'ancestor-replacement'
        $live = Join-Path $parent 'live'
        $substitute = Join-Path $parent 'substitute'
        $parked = Join-Path $parent 'parked'
        New-Item -ItemType Directory -Path $live -Force | Out-Null
        New-Item -ItemType Directory -Path $substitute -Force | Out-Null
        $path = Join-Path $live 'input.json'
        [IO.File]::WriteAllBytes($path, $utf8.GetBytes('{"value":1}'))
        [IO.File]::WriteAllBytes(
            (Join-Path $substitute 'input.json'),
            $utf8.GetBytes('{"value":2}')
        )
        Assert-Throws {
            Read-GswBoundedFileSnapshot -Path $path -Name 'ancestor JSON' `
                -MaximumBytes 1024 -BeforePostReadCheck {
                    Move-Item -LiteralPath $live -Destination $parked
                    Move-Item -LiteralPath $substitute -Destination $live
                }
        } 'changed during its bounded read'
    }

    Invoke-SelfTest 'Strict TSV preserves one leading UTF-8 BOM only' {
        $path = Join-Path $testRoot 'compat.tsv'
        [byte[]]$content = $utf8.GetBytes("left`tright`nvalue`tok`n")
        [byte[]]$oneBom = New-Object byte[] ($content.Length + 3)
        $oneBom[0] = 0xef
        $oneBom[1] = 0xbb
        $oneBom[2] = 0xbf
        [Array]::Copy($content, 0, $oneBom, 3, $content.Length)
        [IO.File]::WriteAllBytes($path, $oneBom)
        $rows = @(Read-StrictTsvFile -Path $path `
            -ExpectedHeader @('left', 'right') -Name 'compatibility TSV' `
            -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
            -MaximumPhysicalLines 8)
        Assert-Equal $rows.Count 1
        Assert-Equal $rows[0].left 'value'

        [byte[]]$twoBoms = New-Object byte[] ($oneBom.Length + 3)
        [Array]::Copy($oneBom, 0, $twoBoms, 0, 3)
        [Array]::Copy($oneBom, 0, $twoBoms, 3, $oneBom.Length)
        [IO.File]::WriteAllBytes($path, $twoBoms)
        Assert-Throws {
            Read-StrictTsvFile -Path $path `
                -ExpectedHeader @('left', 'right') -Name 'compatibility TSV' `
                -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
                -MaximumPhysicalLines 8
        } 'unsupported UTF-8 byte-order mark'
    }

    Invoke-SelfTest 'Strict TSV rejects a reparse-point ancestor' {
        $target = Join-Path $testRoot 'tsv-target'
        $link = Join-Path $testRoot 'tsv-link'
        New-Item -ItemType Directory -Path $target | Out-Null
        [IO.File]::WriteAllBytes(
            (Join-Path $target 'input.tsv'),
            $utf8.GetBytes("left`tright`nvalue`tok`n")
        )
        New-DirectoryReparsePoint -Path $link -Target $target
        Assert-Throws {
            Read-StrictTsvFile -Path (Join-Path $link 'input.tsv') `
                -ExpectedHeader @('left', 'right') -Name 'reparse TSV' `
                -MaximumBytes 1024 -MaximumRows 4 -MaximumLineBytes 128 `
                -MaximumPhysicalLines 8
        } 'traverses reparse point'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures strict input boundary test(s) failed."
}
Write-Host 'All strict input boundary tests passed.'

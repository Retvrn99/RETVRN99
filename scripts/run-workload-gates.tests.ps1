# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'run-workload-gates.ps1')

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

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
$testRoot = Join-Path $tempBase ("retvrn99-workload-gates-test-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Invoke-SelfTest 'EXITVM.COM protocol bytes are exact' {
        $actual = (Get-ExitVmBytes | ForEach-Object { $_.ToString('X2') }) -join ''
        Assert-Equal $actual 'B00CE6E430C0E6E5B003E6E6B8014CCD21'
    }

    Invoke-SelfTest 'Doom parser extracts semantic and timing metrics' {
        $metric = Parse-DoomTimedemo -Sources @([pscustomobject]@{
            name = 'final text'; text = "timed 2134 gametics in 1067 realtics`r`n"
        })
        Assert-Equal $metric.value 2134
        Assert-Equal $metric.realtics 1067
        Assert-Equal $metric.throughput 70.0
    }

    Invoke-SelfTest 'Quake parser extracts frames, seconds, and fps' {
        $metric = Parse-QuakeTimedemo -Sources @([pscustomobject]@{
            name = 'QCONSOLE.LOG'; text = '969 frames 32.3 seconds 30.0 fps'
        })
        Assert-Equal $metric.value 969
        Assert-Equal $metric.seconds 32.3
        Assert-Equal $metric.throughput 30.0
        Assert-Equal $metric.source 'QCONSOLE.LOG'
    }

    Invoke-SelfTest 'Amplification gates reject sectorized storage and silent audio work' {
        $good = [pscustomobject]@{
            audio = [pscustomobject]@{ frames_produced = 0 }
            execution = [pscustomobject]@{
                storage_host_calls = 1; storage_transactions = 1
                scheduler_dispatches = 5; device_advances = 5; audio_blocks = 0
            }
        }
        Assert-True (Test-AmplificationResult -Result $good).passed
        $good.execution.storage_host_calls = 2
        Assert-True (-not (Test-AmplificationResult -Result $good).passed)
        $good.execution.storage_host_calls = 1
        $good.execution.audio_blocks = 1
        Assert-True (-not (Test-AmplificationResult -Result $good).passed)
    }

    Invoke-SelfTest 'Metric parsers reject incomplete output' {
        Assert-Throws { Parse-DoomTimedemo -Sources @([pscustomobject]@{ name = 'x'; text = '2134 ticks' }) } 'not found'
        Assert-Throws { Parse-QuakeTimedemo -Sources @([pscustomobject]@{ name = 'x'; text = '969 frames' }) } 'not found'
    }

    $repository = Join-Path $testRoot 'repository'
    $sourceRoot = Join-Path $repository 'src'
    $development = Join-Path $repository 'dev'
    $workloads = Join-Path $development 'workloads'
    $seed = Join-Path $workloads 'dos-seed'
    $doom = Join-Path $workloads 'doom-shareware-demo3'
    $quake = Join-Path $workloads 'quake-shareware-demo1'
    foreach ($directory in @($sourceRoot, $seed, $doom, (Join-Path $quake 'ID1'))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    foreach ($required in @('IO.SYS', 'MSDOS.SYS', 'COMMAND.COM')) {
        [IO.File]::WriteAllText((Join-Path $seed $required), "seed-$required")
    }
    [IO.File]::WriteAllText((Join-Path $seed 'AUTOEXEC.BAT'), 'source-autoexec')
    [IO.File]::WriteAllBytes((Join-Path $doom 'doom.exe'), [byte[]](1, 2, 3))
    [IO.File]::WriteAllText((Join-Path $doom 'doom1.wad'), 'fixture')
    [IO.File]::WriteAllBytes((Join-Path $quake 'quake.exe'), [byte[]](4, 5, 6))
    [IO.File]::WriteAllText((Join-Path $quake 'ID1\PAK0.PAK'), 'fixture')
    $emulator = Join-Path $repository 'retvrn99.exe'
    [IO.File]::WriteAllBytes($emulator, [byte[]](0x4D, 0x5A))
    $manifestPath = Join-Path $sourceRoot 'workload-manifest.json'
    $manifestJson = @'
{
  "version": 1,
  "workloads": [
    {
      "id": "doom-shareware-demo3",
      "executable": "doom.exe",
      "arguments": ["-config", "MAX.CFG", "-timedemo", "demo3"],
      "executable_sha256": "",
      "metric": "gametics",
      "expected": 2134,
      "repetitions": 3,
      "semantic_exit": "test_device"
    },
    {
      "id": "quake-shareware-demo1",
      "executable": "quake.exe",
      "arguments": ["-nosound", "+timedemo", "demo1"],
      "executable_sha256": "",
      "metric": "frames",
      "expected": 969,
      "repetitions": 3,
      "semantic_exit": "test_device"
    }
  ]
}
'@
    [IO.File]::WriteAllText($manifestPath, $manifestJson)
    $manifest = Read-WorkloadManifest -Path $manifestPath

    Invoke-SelfTest 'Manifest validation preserves declared gates' {
        Assert-Equal $manifest.workloads.Count 2
        Assert-Equal $manifest.workloads[0].expected 2134
        Assert-Equal $manifest.workloads[1].repetitions 3
        Assert-Equal $manifest.workloads[1].semantic_exit 'test_device'
    }

    Invoke-SelfTest 'Manifest rejects DOS batch injection' {
        $unsafePath = Join-Path $sourceRoot 'unsafe.json'
        [IO.File]::WriteAllText($unsafePath, ($manifestJson.Replace('"-config"', '"-config&format"')))
        Assert-Throws { Read-WorkloadManifest -Path $unsafePath } 'unsafe DOS argument'
        $spacePath = Join-Path $sourceRoot 'unsafe-space.json'
        [IO.File]::WriteAllText($spacePath, ($manifestJson.Replace('"MAX.CFG"', '"MAX CFG"')))
        Assert-Throws { Read-WorkloadManifest -Path $spacePath } 'unsafe DOS argument'
    }

    Invoke-SelfTest 'Output path safety accepts only isolated output' {
        $safe = Join-Path $development 'gate-output'
        $resolved = Assert-SafeOutputRoot -Path $safe -RepositoryRoot $repository -ProtectedPaths @($manifestPath, $seed, $workloads, $emulator)
        Assert-Equal $resolved ([IO.Path]::GetFullPath($safe))
        Assert-Throws {
            Assert-SafeOutputRoot -Path $sourceRoot -RepositoryRoot $repository -ProtectedPaths @($manifestPath, $seed, $workloads, $emulator)
        } 'under the excluded dev'
        Assert-Throws {
            Assert-SafeOutputRoot -Path (Join-Path $seed 'output') -RepositoryRoot $repository -ProtectedPaths @($manifestPath, $seed, $workloads, $emulator)
        } 'overlaps protected'
        Assert-Throws {
            Assert-SafeOutputRoot -Path ([IO.Path]::GetPathRoot($repository)) -RepositoryRoot $repository -ProtectedPaths @($manifestPath)
        } 'filesystem root'
        Assert-Throws { Get-FullPath -Path "$safe`:stream" -Label 'Output root' } 'valid path|alternate data stream'
    }

    Invoke-SelfTest 'Fixture tree hash is stable and content-sensitive' {
        $first = Get-FixtureTreeHash -Root $doom
        $second = Get-FixtureTreeHash -Root $doom
        Assert-Equal $first.sha256 $second.sha256
        [IO.File]::AppendAllText((Join-Path $doom 'doom1.wad'), '!')
        $third = Get-FixtureTreeHash -Root $doom
        Assert-True ($third.sha256 -ne $first.sha256) 'Fixture hash did not change.'
    }

    Invoke-SelfTest 'Doom profile staging is isolated and byte-exact' {
        $profile = Join-Path $testRoot 'doom-profile'
        $staged = Stage-WorkloadProfile -ProfileRoot $profile -DosSeed $seed -WorkloadDirectory $doom -Workload $manifest.workloads[0]
        Assert-True (Test-Path -LiteralPath (Join-Path $staged.c_drive 'DOOM.EXE'))
        $exitHex = ([IO.File]::ReadAllBytes((Join-Path $staged.c_drive 'EXITVM.COM')) | ForEach-Object { $_.ToString('X2') }) -join ''
        Assert-Equal $exitHex 'B00CE6E430C0E6E5B003E6E6B8014CCD21'
        $autoexecBytes = [IO.File]::ReadAllBytes((Join-Path $staged.c_drive 'AUTOEXEC.BAT'))
        $autoexec = [Text.Encoding]::ASCII.GetString($autoexecBytes)
        Assert-True ($autoexec.Contains("doom.exe -config MAX.CFG -timedemo demo3 > GATE.OUT`r`n"))
        for ($index = 0; $index -lt $autoexecBytes.Length; $index++) {
            if ($autoexecBytes[$index] -eq 0x0A) {
                Assert-True ($index -gt 0 -and $autoexecBytes[$index - 1] -eq 0x0D) 'AUTOEXEC.BAT contains a lone LF.'
            }
        }
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $seed 'AUTOEXEC.BAT'))) 'source-autoexec'
    }

    Invoke-SelfTest 'Quake staging adds bounded completion config and logging' {
        $profile = Join-Path $testRoot 'quake-profile'
        $staged = Stage-WorkloadProfile -ProfileRoot $profile -DosSeed $seed -WorkloadDirectory $quake -Workload $manifest.workloads[1]
        $autoexec = [IO.File]::ReadAllText((Join-Path $staged.c_drive 'AUTOEXEC.BAT'))
        Assert-True ($autoexec.Contains('-condebug +exec GATEEND.CFG'))
        $gate = [IO.File]::ReadAllText((Join-Path $staged.c_drive 'ID1\GATEEND.CFG'))
        Assert-True ($gate.EndsWith("quit`r`n"))
        Assert-Equal ([regex]::Matches($gate, '(?m)^wait\r$').Count) (969 + 128)
    }

    Invoke-SelfTest 'Staging rejects fixture collisions' {
        $collision = Join-Path $workloads 'collision'
        New-Item -ItemType Directory -Path $collision | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $collision 'doom.exe'), [byte[]](1))
        [IO.File]::WriteAllText((Join-Path $collision 'COMMAND.COM'), 'collision')
        $workload = [pscustomobject]@{
            id = 'collision'; executable = 'doom.exe'; arguments = @(); metric = 'gametics'; expected = 1
        }
        Assert-Throws {
            Stage-WorkloadProfile -ProfileRoot (Join-Path $testRoot 'collision-profile') -DosSeed $seed -WorkloadDirectory $collision -Workload $workload
        } 'overwrite'
    }
}
finally {
    $verified = [IO.Path]::GetFullPath($testRoot)
    if (-not (Test-PathWithin -Path $verified -Root $tempBase) -or
        -not ([IO.Path]::GetFileName($verified)).StartsWith('retvrn99-workload-gates-test-', [StringComparison]::Ordinal)) {
        throw "Refusing to remove unverified self-test directory: $verified"
    }
    Remove-Item -LiteralPath $verified -Recurse -Force
}

if ($script:Failures -ne 0) {
    [Console]::Error.WriteLine("$script:Failures workload-gate self-test(s) failed.")
    exit 1
}
Write-Host 'All workload-gate self-tests passed.'

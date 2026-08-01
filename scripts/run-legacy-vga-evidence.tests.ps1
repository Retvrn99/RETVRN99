# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'run-legacy-vga-evidence.ps1') -DefineFunctionsOnly

$script:LegacyVgaEvidenceTestFailures = 0
$script:LegacyVgaEvidenceTestCount = 0

function Assert-LegacyVgaEvidenceTestTrue {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Assert-LegacyVgaEvidenceTestEqual {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Assert-LegacyVgaEvidenceTestThrows {
    param([scriptblock]$Action, [string]$Pattern)

    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $($_.Exception.Message)"
        }
        return
    }
    throw "Expected an exception matching '$Pattern'."
}

function Invoke-LegacyVgaEvidenceTest {
    param([string]$Name, [scriptblock]$Body)

    $script:LegacyVgaEvidenceTestCount += 1
    try {
        & $Body
        Write-Host "PASS $Name"
    } catch {
        $script:LegacyVgaEvidenceTestFailures += 1
        [Console]::Error.WriteLine("FAIL $Name`: $($_.Exception.Message)")
    }
}

function New-LegacyVgaEvidenceShutdownTraceFixture {
    param([string[]]$Markers)

    $count = $Markers.Count
    $lines = [Collections.Generic.List[string]]::new()
    [void]$lines.Add(
        "enabled`tarmed`tcapacity`tcount`trecorded`tdropped_unarmed`tdropped_markers`toverwritten"
    )
    [void]$lines.Add("true`ttrue`t65536`t$count`t$count`t0`t0`t0")
    [void]$lines.Add("sequence`tkind`tvalue`tcs`tflags`trip`taddress`tdetail")
    $sequence = 0
    foreach ($marker in $Markers) {
        $sequence += 1
        [void]$lines.Add(
            "$sequence`tmarker`t$marker`t0000`t00000000`t0000000000000000" +
            "`t0000000000000000`t0000000000000000"
        )
    }
    return $lines.ToArray()
}

function Write-LegacyVgaEvidenceShutdownTraceFixture {
    param([string]$Path, [string[]]$Lines)

    [IO.File]::WriteAllText(
        $Path,
        ($Lines -join "`r`n") + "`r`n",
        [Text.UTF8Encoding]::new($false)
    )
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-legacy-vga-evidence-test-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Invoke-LegacyVgaEvidenceTest 'Exact PIF identity is fixed' {
        Assert-LegacyVgaEvidencePifMetadata `
            967 'B4CAF52E570078852B84A814664A3D091CF0916EBA70DB4DBA559FA90C400281'
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidencePifMetadata `
                966 'B4CAF52E570078852B84A814664A3D091CF0916EBA70DB4DBA559FA90C400281'
        } 'exactly 967 bytes'
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidencePifMetadata 967 ('0' * 64)
        } 'approved exact PIF'
    }

    Invoke-LegacyVgaEvidenceTest 'Disposable and evidence paths stay under V tmp' {
        Assert-LegacyVgaEvidenceTestTrue `
            (Test-LegacyVgaEvidencePathWithin 'V:\tmp\legacy-vga-a' 'V:\tmp') `
            'A child of V tmp should be accepted.'
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceTemporaryPath 'D:\dev\RETVRN99' 'Test output'
        } 'must remain under'
    }

    Invoke-LegacyVgaEvidenceTest 'Guest paths reject traversal and command injection' {
        $path = ConvertTo-LegacyVgaEvidenceGuestPath `
            'QUAKE/QUAKEPIF.PIF' 'Guest PIF'
        Assert-LegacyVgaEvidenceTestEqual $path 'C:\QUAKE\QUAKEPIF.PIF' `
            'Guest path conversion changed.'
        Assert-LegacyVgaEvidenceTestThrows {
            ConvertTo-LegacyVgaEvidenceGuestPath '..\QUAKE\BAD.PIF' 'Guest PIF'
        } 'without spaces or traversal'
        Assert-LegacyVgaEvidenceTestThrows {
            ConvertTo-LegacyVgaEvidenceGuestPath 'QUAKE/BAD & X.PIF' 'Guest PIF'
        } 'without spaces or traversal'
    }

    Invoke-LegacyVgaEvidenceTest 'Candidate driver set is exact and hash-bearing' {
        $driverRoot = Join-Path $testRoot 'candidate-drivers'
        New-Item -ItemType Directory -Path $driverRoot | Out-Null
        $names = @('gswmini.drv', 'gswmini.vxd', 'gswhal9x.dll', 'gswdd32.dll')
        foreach ($name in $names) {
            [IO.File]::WriteAllBytes((Join-Path $driverRoot $name), [byte[]](0x4D, 0x5A))
        }
        $drivers = @(Get-LegacyVgaEvidenceCandidateDrivers $driverRoot)
        Assert-LegacyVgaEvidenceTestEqual $drivers.Count 4 `
            'Candidate driver count changed.'
        Assert-LegacyVgaEvidenceTestEqual $drivers[0].guest_path `
            'WINDOWS/SYSTEM/GSWMINI.DRV' 'Mini driver guest path changed.'
        Assert-LegacyVgaEvidenceTestEqual $drivers[3].guest_path `
            'WINDOWS/SYSTEM/GSWDD32.DLL' 'DirectDraw bridge guest path changed.'
        foreach ($driver in $drivers) {
            Assert-LegacyVgaEvidenceTestEqual $driver.bytes 2 `
                "Candidate driver size was not recorded for $($driver.name)."
            Assert-LegacyVgaEvidenceTestTrue ($driver.sha256 -match '^[0-9A-F]{64}$') `
                "Candidate driver hash was not recorded for $($driver.name)."
        }
        [IO.File]::Delete((Join-Path $driverRoot 'gswmini.vxd'))
        Assert-LegacyVgaEvidenceTestThrows {
            Get-LegacyVgaEvidenceCandidateDrivers $driverRoot
        } 'Candidate driver gswmini.vxd'
    }

    Invoke-LegacyVgaEvidenceTest 'Launcher receives the validated guest REG path' {
        $arguments = @(New-LegacyVgaEvidenceLauncherArguments `
            'clone.img' 'driver.reg' 'autoexec.bat' 'C:\QUAKE\DRIVER.REG')
        Assert-LegacyVgaEvidenceTestEqual $arguments.Count 4 `
            'Launcher argument count changed.'
        Assert-LegacyVgaEvidenceTestEqual $arguments[3] 'QUAKE/DRIVER.REG' `
            'Launcher did not receive the FAT-relative REG path.'
        Assert-LegacyVgaEvidenceTestThrows {
            New-LegacyVgaEvidenceLauncherArguments `
                'clone.img' 'driver.reg' 'autoexec.bat' 'QUAKE\DRIVER.REG'
        } 'absolute DOS path'
    }

    Invoke-LegacyVgaEvidenceTest 'Run REG is derived by replacing known-good bytes' {
        $sourceText = @(
            'REGEDIT4',
            '',
            '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run]',
            '"GSWGFX"="C:\\GSWGFX\\GSWGFX.EXE /bounded /import-vbe /host-report"',
            ''
        ) -join "`r`n"
        [byte[]]$source = Get-LegacyVgaEvidenceAsciiBytes ($sourceText + "`r`n")
        [byte[]]$derived = Get-LegacyVgaEvidenceDerivedRegBytes `
            $source 'C:\QUAKE\RETURN3.BAT'
        $observed = [Text.Encoding]::ASCII.GetString($derived)
        Assert-LegacyVgaEvidenceTestTrue `
            $observed.Contains('"GSWGFX"="C:\\QUAKE\\RETURN3.BAT"') `
            'Derived REG did not preserve doubled backslashes.'
        Assert-LegacyVgaEvidenceTestTrue `
            $observed.Contains('[HKEY_LOCAL_MACHINE\Software\Microsoft') `
            'Derived REG changed bytes outside the Run value.'
        Assert-LegacyVgaEvidenceTestThrows {
            $broken = $sourceText.Replace('C:\\GSWGFX', 'C:\GSWGFX')
            Get-LegacyVgaEvidenceDerivedRegBytes `
                (Get-LegacyVgaEvidenceAsciiBytes ($broken + "`r`n")) `
                'C:\QUAKE\RETURN3.BAT'
        } 'doubled Run-value backslash'
    }

    Invoke-LegacyVgaEvidenceTest 'Batch blocks on exact PIF and shuts down normally' {
        $batch = New-LegacyVgaEvidenceBatchText `
            'C:\QUAKE\QUAKEPIF.PIF' `
            'C:\QUAKE\EXITVM.COM' `
            '-condebug +_vid_default_mode 2 +timedemo demo1 +quit'
        Assert-LegacyVgaEvidenceTestTrue `
            $batch.Contains('START /W C:\QUAKE\QUAKEPIF.PIF ') `
            'Batch must use the blocking Win98 START form.'
        Assert-LegacyVgaEvidenceTestTrue `
            $batch.Contains("C:\QUAKE\EXITVM.COM P`r`n") `
            'Batch must emit the pre-PIF receipt.'
        Assert-LegacyVgaEvidenceTestTrue `
            $batch.Contains("C:\QUAKE\EXITVM.COM O`r`n") `
            'Batch must emit the restored-desktop receipt.'
        Assert-LegacyVgaEvidenceTestTrue `
            $batch.EndsWith("RUNDLL32.EXE user.exe,ExitWindows`r`n") `
            'Batch must request normal Windows shutdown.'
        Assert-LegacyVgaEvidenceTestThrows {
            New-LegacyVgaEvidenceBatchText `
                'C:\QUAKE\QUAKEPIF.PIF' 'C:\QUAKE\EXITVM.COM' `
                '+vid_mode 2 & format c: +quit'
        } 'unsafe Win98 command characters'
        Assert-LegacyVgaEvidenceTestThrows {
            New-LegacyVgaEvidenceBatchText `
                'C:\QUAKE\QUAKEPIF.PIF' 'C:\QUAKE\EXITVM.COM' '+vid_mode 2'
        } 'must contain \+quit'
    }

    Invoke-LegacyVgaEvidenceTest 'Report payload carries lifecycle join fields' {
        $payloads = New-LegacyVgaEvidenceReportPayloads `
            'quake-mode-x' '2' 320 240 3 '89ABCDEF'
        Assert-LegacyVgaEvidenceTestTrue `
            $payloads.Pre.StartsWith("schema`tcase`tmode`twidth`theight") `
            'Pre payload lost its TSV schema.'
        Assert-LegacyVgaEvidenceTestTrue `
            $payloads.Pre.Contains("owner_generation`tmode_generation") `
            'Generation join fields are missing.'
        Assert-LegacyVgaEvidenceTestTrue `
            $payloads.Pre.Contains("aperture_exits`tpresented_hz") `
            'Execution join fields are missing.'
        Assert-LegacyVgaEvidenceTestTrue `
            $payloads.Post.Contains("`tterminal`t") `
            'Post payload lost its terminal row.'
        Assert-LegacyVgaEvidenceTestTrue `
            $payloads.Post.Contains("`tPASS`tlauncher-complete") `
            'Post payload terminal row is not PASS.'
        Assert-LegacyVgaEvidenceTestTrue `
            $payloads.Post.Contains("`t89ABCDEF`tpending`tPASS`t") `
            'Post payload lost the expected sentinel CRC.'
        Assert-LegacyVgaEvidenceTestThrows {
            New-LegacyVgaEvidenceReportPayloads `
                'bad-geometry' '2' 640 480 1 '89ABCDEF'
        } 'ten 320/360 Mode X geometries'
    }

    Invoke-LegacyVgaEvidenceTest 'Sentinel contract is bounded and little endian' {
        $sentinel = Get-LegacyVgaEvidenceSentinel `
            17 33 64 48 '0x89abcdef'
        Assert-LegacyVgaEvidenceTestEqual $sentinel.CrcHex '89ABCDEF' `
            'Sentinel CRC normalization changed.'
        [byte[]]$bytes = Get-LegacyVgaEvidenceSentinelBytes $sentinel
        $hex = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
        Assert-LegacyVgaEvidenceTestEqual `
            $hex '1100210040003000EFCDAB89' `
            'Sentinel configuration is not little endian.'
        Assert-LegacyVgaEvidenceTestThrows {
            Get-LegacyVgaEvidenceSentinel 790 590 20 20 '00000000'
        } 'inside the 800x600 desktop'
        Assert-LegacyVgaEvidenceTestThrows {
            Get-LegacyVgaEvidenceSentinel 0 0 1 1 '1234'
        } 'eight hexadecimal digits'
    }

    Invoke-LegacyVgaEvidenceTest 'Katea helper builds deterministically' {
        $assembler = (Get-Command nasm -ErrorAction Stop).Source
        $template = Join-Path $PSScriptRoot 'legacy-vga-evidence-katea.asm'
        $payloads = New-LegacyVgaEvidenceReportPayloads `
            'quake-mode-x' '2' 320 200 1 '89ABCDEF'
        $sentinel = Get-LegacyVgaEvidenceSentinel `
            17 33 64 48 '89ABCDEF'
        $firstRoot = Join-Path $testRoot 'helper-first'
        $secondRoot = Join-Path $testRoot 'helper-second'
        New-Item -ItemType Directory -Path $firstRoot | Out-Null
        New-Item -ItemType Directory -Path $secondRoot | Out-Null
        $first = Build-LegacyVgaEvidenceKateaHelper `
            $firstRoot $assembler $template $payloads $sentinel
        $second = Build-LegacyVgaEvidenceKateaHelper `
            $secondRoot $assembler $template $payloads $sentinel
        Assert-LegacyVgaEvidenceTestEqual $first.Sha256 $second.Sha256 `
            'Generated COM bytes are not deterministic.'
        Assert-LegacyVgaEvidenceTestEqual $first.Bytes $second.Bytes `
            'Generated COM sizes differ.'
        $binaryText = [Text.Encoding]::ASCII.GetString(
            [IO.File]::ReadAllBytes($first.Path)
        )
        Assert-LegacyVgaEvidenceTestTrue `
            $binaryText.Contains("schema`tcase`tmode") `
            'Generated COM does not embed the report schema.'
        Assert-LegacyVgaEvidenceTestTrue `
            $binaryText.Contains('launcher-complete') `
            'Generated COM does not embed the terminal receipt.'
    }

    Invoke-LegacyVgaEvidenceTest 'Katea helper uses only existing test commands' {
        $source = Get-Content -Raw -LiteralPath (
            Join-Path $PSScriptRoot 'legacy-vga-evidence-katea.asm'
        )
        foreach ($contract in @(
            '%define KATEA_INDEX_PORT 0xE4',
            '%define KATEA_DATA_PORT 0xE5',
            '%define KATEA_COMMAND_PORT 0xE6',
            '%define KATEA_REPORT_BEGIN 4',
            '%define KATEA_REPORT_APPEND 5',
            '%define KATEA_REPORT_COMMIT 6',
            '%define KATEA_CRC 1',
            '%define KATEA_CANVAS_CAPTURE 2',
            '%define KATEA_COMPOSED_CAPTURE 8'
        )) {
            Assert-LegacyVgaEvidenceTestTrue $source.Contains($contract) `
                "Katea helper lost contract '$contract'."
        }
        Assert-LegacyVgaEvidenceTestTrue `
            (-not $source.Contains('0xE7')) `
            'Katea helper must not add another guest-host port.'
    }

    Invoke-LegacyVgaEvidenceTest 'Shutdown trace is complete ordered balanced and fault free' {
        $trace = Join-Path $testRoot 'shutdown-trace.tsv'
        $markers = @(
            'd1', 'd2', 'd3', 'd4', 'd5', 'd6', 'e8',
            'd7', 'd8', 'd9', 'da', 'db', 'dc'
        )
        $lines = @(New-LegacyVgaEvidenceShutdownTraceFixture $markers)
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $lines
        Assert-LegacyVgaEvidenceShutdownTrace $trace

        $broken = @(New-LegacyVgaEvidenceShutdownTraceFixture `
            @($markers | Where-Object { $_ -cne 'd6' }))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $broken
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'ordered marker d6 through dc'

        $prematureSystemExit = @(New-LegacyVgaEvidenceShutdownTraceFixture `
            (@('d6') + $markers))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $prematureSystemExit
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'terminal lifecycle marker before driver disabling'

        $rebasedLifecycle = @(New-LegacyVgaEvidenceShutdownTraceFixture @(
            'd1', 'd2', 'd3', 'd4', 'd5',
            'd1', 'd2', 'd3', 'd4', 'd5',
            'd6', 'e8', 'd7', 'd8', 'd9', 'da', 'db', 'dc'
        ))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $rebasedLifecycle
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'transition after driver disabling'

        $prematureTerminal = @(New-LegacyVgaEvidenceShutdownTraceFixture @(
            'd1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd7', 'e8',
            'd7', 'd8', 'd9', 'da', 'db', 'dc'
        ))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $prematureTerminal
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'ordered marker d6 through dc'

        $withoutQuiesce = @(New-LegacyVgaEvidenceShutdownTraceFixture `
            @($markers | Where-Object { $_ -cne 'e8' }))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $withoutQuiesce
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'ordered marker d6 through dc'

        $unbalanced = @(New-LegacyVgaEvidenceShutdownTraceFixture `
            @($markers | Where-Object { $_ -cne 'd2' }))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $unbalanced
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'balanced D1-D4'

        $orphanedTransition = @(New-LegacyVgaEvidenceShutdownTraceFixture `
            (@('d2') + $markers))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $orphanedTransition
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'balanced D1-D4'

        $postDisableTransition = @(New-LegacyVgaEvidenceShutdownTraceFixture `
            (@($markers[0..4]) + @('d1') + @($markers[5..12])))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $postDisableTransition
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'transition after driver disabling'

        $splicedTerminal = @(New-LegacyVgaEvidenceShutdownTraceFixture @(
            'd1', 'd2', 'd3', 'd4', 'd5', 'd6', 'e8', 'd7', 'd8',
            'd5', 'd9', 'da', 'db', 'dc'
        ))
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $splicedTerminal
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'ordered marker d6 through dc'

        foreach ($fault in @('eb', 'ef')) {
            $faultedMarkers = @($markers[0..3]) + @($fault) + @($markers[4..12])
            $faulted = @(New-LegacyVgaEvidenceShutdownTraceFixture $faultedMarkers)
            Write-LegacyVgaEvidenceShutdownTraceFixture $trace $faulted
            Assert-LegacyVgaEvidenceTestThrows {
                Assert-LegacyVgaEvidenceShutdownTrace $trace
            } "failure marker $fault"
        }

        $dropped = @($lines)
        $dropped[1] = "true`ttrue`t65536`t13`t13`t0`t1`t0"
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $dropped
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'dropped lifecycle markers'

        $truncated = @($lines[0..($lines.Count - 2)])
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $truncated
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'event count'

        $missingField = @($lines)
        $missingField[1] = "true`ttrue`t65536`t13`t13`t0`t0"
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $missingField
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'metadata row is malformed'

        $inconsistent = @($lines)
        $inconsistent[1] = "true`ttrue`t65536`t13`t14`t0`t0`t0"
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $inconsistent
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'accounting is inconsistent'

        $negative = @($lines)
        $negative[1] = "true`ttrue`t65536`t13`t13`t0`t0`t-1"
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $negative
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'invalid counter'

        $regressed = @($lines)
        $regressed[4] = $regressed[4] -replace "^2`t", "1`t"
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $regressed
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'not strictly increasing'

        $shifted = @($lines)
        for ($index = 3; $index -lt $shifted.Count; $index += 1) {
            $fields = @($shifted[$index].Split("`t"))
            $fields[0] = ([uint64]$fields[0] + 1).ToString()
            $shifted[$index] = $fields -join "`t"
        }
        $shifted[1] = "true`ttrue`t65536`t13`t14`t0`t0`t1"
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $shifted
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'sequence accounting is inconsistent'

        $accountedOverwrite = @(New-LegacyVgaEvidenceShutdownTraceFixture @(
            'd1', 'd2', 'd3', 'd4', 'aa', 'd5', 'd6', 'e8',
            'd7', 'd8', 'd9', 'da', 'db', 'dc'
        ))
        $accountedOverwrite[7] = $accountedOverwrite[7] -replace `
            "`tmarker`taa`t", "`tmmio`taa`t"
        $accountedOverwrite = @($accountedOverwrite[0..6]) + `
            @($accountedOverwrite[8..($accountedOverwrite.Count - 1)])
        $accountedOverwrite[1] = "true`ttrue`t65536`t13`t14`t0`t0`t1"
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $accountedOverwrite
        Assert-LegacyVgaEvidenceShutdownTrace $trace

        $caseMismatchedKind = @($lines)
        $caseMismatchedKind[3] = $caseMismatchedKind[3] -replace `
            "`tmarker`td1`t", "`tMarker`teb`t"
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $caseMismatchedKind
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'event kind is invalid'

        $malformedEvent = @($lines)
        $malformedEvent[3] = $malformedEvent[3] -replace "`t0000000000000000$", ''
        Write-LegacyVgaEvidenceShutdownTraceFixture $trace $malformedEvent
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceShutdownTrace $trace
        } 'event row is malformed'
    }

    Invoke-LegacyVgaEvidenceTest 'Guest result and logs reject every reset path' {
        $newResult = {
            [pscustomobject]@{
                stop_reason = 'power_off'
                exit_code = 0
                reset_count = 0
                boot_epoch = 1
                guest_requested_resets = 0
                unclassified_io = 0
                unclassified_mmio = 0
            }
        }
        Assert-LegacyVgaEvidenceResult (& $newResult) 0
        foreach ($field in @('reset_count', 'guest_requested_resets')) {
            $invalid = & $newResult
            $invalid.$field = 1
            Assert-LegacyVgaEvidenceTestThrows {
                Assert-LegacyVgaEvidenceResult $invalid 0
            } 'without a guest or lifetime reset'
        }
        $invalidEpoch = & $newResult
        $invalidEpoch.boot_epoch = 2
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceResult $invalidEpoch 0
        } 'without a guest or lifetime reset'
        foreach ($field in @(
            'exit_code', 'reset_count', 'guest_requested_resets', 'boot_epoch',
            'unclassified_io', 'unclassified_mmio'
        )) {
            $invalid = & $newResult
            $invalid.$field = $null
            Assert-LegacyVgaEvidenceTestThrows {
                Assert-LegacyVgaEvidenceResult $invalid 0
            } 'missing or null'
        }

        $cleanLog = Join-Path $testRoot 'clean-reset.log'
        $warmLog = Join-Path $testRoot 'warm-reset.log'
        $stormLog = Join-Path $testRoot 'mmio-storm.log'
        [IO.File]::WriteAllText($cleanLog, 'normal power off')
        [IO.File]::WriteAllText($warmLog, 'warm CPU reset 1 after 10 iterations')
        [IO.File]::WriteAllText(
            $stormLog,
            'diagnostic: MMIO exit storm fallbacks=42209 scalar=38583 string=3626'
        )
        Assert-LegacyVgaEvidenceLogs @($cleanLog)
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceLogs @($cleanLog, $warmLog)
        } 'warm CPU reset'
        Assert-LegacyVgaEvidenceTestThrows {
            Assert-LegacyVgaEvidenceLogs @($cleanLog, $stormLog)
        } 'MMIO exit storm'
    }

    Invoke-LegacyVgaEvidenceTest 'ValidateOnly performs no guest mutation' {
        $externalPif =
            'V:\tmp\retvrn99-winquake-vga-diagnosis-20260731-01\evidence\quake-start-menu.pif'
        if (-not (Test-Path -LiteralPath $externalPif -PathType Leaf)) {
            Write-Host 'SKIP exact external PIF is not present'
            return
        }
        $validationId = [Guid]::NewGuid().ToString('N')
        $validationRoot = Join-Path $testRoot ('validation-' + $validationId)
        $source = Join-Path $validationRoot 'source'
        $tools = Join-Path $validationRoot 'tools'
        $assets = Join-Path $validationRoot 'assets'
        $profile = Join-Path 'V:\tmp' (
            'retvrn99-legacy-vga-validation-profile-' + $validationId
        )
        $evidence = Join-Path 'V:\tmp' (
            'retvrn99-legacy-vga-validation-evidence-' + $validationId
        )
        foreach ($directory in @($source, $tools, $assets)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        try {
            [IO.File]::WriteAllBytes(
                (Join-Path $source 'c_drive.img'),
                [byte[]](1, 2, 3, 4)
            )
            [IO.File]::WriteAllBytes((Join-Path $source 'cmos.bin'), [byte[]](5))
            [IO.File]::WriteAllText(
                (Join-Path $source 'install-state.json'),
                '{}',
                [Text.UTF8Encoding]::new($false)
            )
            [IO.File]::WriteAllText(
                (Join-Path $source 'settings.json'),
                '{"hard_drive_path":"source","cdrom_path":"","floppy_path":""}',
                [Text.UTF8Encoding]::new($false)
            )
            foreach ($name in @(
                'retvrn99.exe', 'retvrn99-fat32.exe',
                'guest-import.exe', 'gswgfx-launcher-stage.exe'
            )) {
                [IO.File]::WriteAllBytes((Join-Path $tools $name), [byte[]](0x4D, 0x5A))
            }
            foreach ($name in @(
                'gswmini.drv', 'gswmini.vxd', 'gswhal9x.dll', 'gswdd32.dll'
            )) {
                [IO.File]::WriteAllBytes((Join-Path $assets $name), [byte[]](0x4D, 0x5A))
            }
            $knownReg = @(
                'REGEDIT4',
                '',
                '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run]',
                '"GSWGFX"="C:\\GSWGFX\\GSWGFX.EXE /bounded /import-vbe /host-report"',
                ''
            ) -join "`r`n"
            [IO.File]::WriteAllText(
                (Join-Path $assets 'DRIVER.REG'),
                $knownReg + "`r`n",
                [Text.Encoding]::ASCII
            )
            $autoexec =
                'C:\WINDOWS\REGEDIT.EXE /L:C:\WINDOWS\SYSTEM.DAT ' +
                '/R:C:\WINDOWS\USER.DAT C:\QUAKE\DRIVER.REG' + "`r`n"
            [IO.File]::WriteAllText(
                (Join-Path $assets 'AUTOEXEC.BAT'),
                $autoexec,
                [Text.Encoding]::ASCII
            )
            $validated = @(& (Join-Path $PSScriptRoot 'run-legacy-vga-evidence.ps1') `
                -SourceProfile $source `
                -DisposableProfile $profile `
                -EvidenceDirectory $evidence `
                -PifFile $externalPif `
                -KnownGoodRegFile (Join-Path $assets 'DRIVER.REG') `
                -KnownGoodAutoexecFile (Join-Path $assets 'AUTOEXEC.BAT') `
                -HostExecutable (Join-Path $tools 'retvrn99.exe') `
                -GuestImportExecutable (Join-Path $tools 'guest-import.exe') `
                -LauncherStageExecutable (Join-Path $tools 'gswgfx-launcher-stage.exe') `
                -CandidateDriverRoot $assets `
                -NasmExecutable (Get-Command nasm -ErrorAction Stop).Source `
                -Case 'quake-mode-x' -Mode '2' -Width 320 -Height 200 -Repetition 1 `
                -SentinelX 16 -SentinelY 16 -SentinelWidth 32 -SentinelHeight 32 `
                -ExpectedDesktopSentinelCrc '89ABCDEF' `
                -QuakeArguments '-condebug +_vid_default_mode 2 +timedemo demo1 +quit' `
                -ValidateOnly)
            $record = @($validated | Where-Object {
                $_ -is [psobject] -and $_.PSObject.Properties.Name -contains 'validated'
            })
            Assert-LegacyVgaEvidenceTestEqual $record.Count 1 `
                'ValidateOnly did not return one validation record.'
            Assert-LegacyVgaEvidenceTestTrue ([bool]$record[0].validated) `
                'ValidateOnly did not report success.'
            Assert-LegacyVgaEvidenceTestTrue `
                (-not (@($record[0].host_arguments) -contains '--graphics-trace')) `
                'Console evidence must not request the GUI-only graphics trace.'
            foreach ($requiredArgument in @(
                '--test-device', '--strict-io', '--guest-report-kind:legacy-vga',
                '--shutdown-trace'
            )) {
                Assert-LegacyVgaEvidenceTestTrue `
                    (@($record[0].host_arguments) -contains $requiredArgument) `
                    "Console evidence lost required argument $requiredArgument."
            }
            Assert-LegacyVgaEvidenceTestTrue `
                (-not (Test-Path -LiteralPath $profile)) `
                'ValidateOnly created a disposable guest profile.'
            Assert-LegacyVgaEvidenceTestTrue `
                (-not (Test-Path -LiteralPath $evidence)) `
                'ValidateOnly created an evidence directory.'
        } finally {
            Assert-LegacyVgaEvidenceTestTrue `
                (-not (Test-Path -LiteralPath $profile)) `
                'Validation cleanup found an unexpected disposable profile.'
            Assert-LegacyVgaEvidenceTestTrue `
                (-not (Test-Path -LiteralPath $evidence)) `
                'Validation cleanup found unexpected evidence.'
        }
    }
}
finally {
    $verified = [IO.Path]::GetFullPath($testRoot)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]@('\', '/')
    )
    if (-not (Test-LegacyVgaEvidencePathWithin $verified $temporary) -or
        -not (Split-Path -Leaf $verified).StartsWith(
            'retvrn99-legacy-vga-evidence-test-',
            [StringComparison]::Ordinal
        )) {
        throw "Refusing to remove unexpected test path: $verified"
    }
    Remove-Item -LiteralPath $verified -Recurse -Force
}

if ($script:LegacyVgaEvidenceTestFailures -ne 0) {
    throw (
        "Legacy VGA evidence tests failed: $script:LegacyVgaEvidenceTestFailures " +
        "of $script:LegacyVgaEvidenceTestCount."
    )
}
Write-Output "PASS legacy-vga-evidence tests=$script:LegacyVgaEvidenceTestCount"

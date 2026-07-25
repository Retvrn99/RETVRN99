# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Tests = 0

function Assert-GswgfxOfflineTestTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-GswgfxOfflineTestThrows {
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

function Invoke-GswgfxOfflineSelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $script:Tests += 1
    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures += 1
        [Console]::Error.WriteLine("FAIL $Name`: $($_.Exception.Message)")
    }
}

function Invoke-GswgfxOfflineProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $stdoutPath = Join-Path $script:TestRoot ("stdout-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    $stderrPath = Join-Path $script:TestRoot ("stderr-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
        -WorkingDirectory (Split-Path -Parent $FilePath) -Wait -PassThru `
        -WindowStyle Hidden -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = [IO.File]::ReadAllText($stdoutPath)
        Stderr = [IO.File]::ReadAllText($stderrPath)
    }
}

function Write-GswgfxOfflineAsciiFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [IO.File]::WriteAllBytes($Path, [Text.Encoding]::ASCII.GetBytes($Text))
}

function Write-GswgfxOfflineUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-GswgfxOfflineFixtureManifest {
    param(
        [Parameter(Mandatory = $true)][string]$PackageDirectory,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $rows = foreach ($name in @('GSWGFX.EXE', 'GSWVBE.EXE')) {
        $path = Join-Path $PackageDirectory $name
        $item = Get-Item -LiteralPath $path -Force
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        "GSWGFX`t$name`t$hash`t$($item.Length)"
    }
    $text = "guest_directory`tfile_name`tsha256`tbytes`n" +
        (($rows -join "`n") + "`n")
    Write-GswgfxOfflineAsciiFile $ManifestPath $text
}

function Write-GswgfxOfflineFixturePackage {
    param(
        [Parameter(Mandatory = $true)][string]$PackageDirectory,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    New-Item -ItemType Directory -Path $PackageDirectory -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllBytes(
        (Join-Path $PackageDirectory 'GSWGFX.EXE'),
        [byte[]](0x4D, 0x5A, 0x47, 0x53, 0x57, 0x47, 0x46, 0x58)
    )
    Write-GswgfxOfflineAsciiFile `
        (Join-Path $PackageDirectory 'GSWVBE.EXE') `
        ([Text.Encoding]::ASCII.GetString([byte[]](0x4D, 0x5A, 0x56, 0x42, 0x45)))
    Write-GswgfxOfflineFixtureManifest $PackageDirectory $ManifestPath
}

function Invoke-GswgfxOfflineWrapper {
    param([Parameter(Mandatory = $true)][string]$OutputDirectory)

    return @(& $script:Wrapper -ProfileRoot $script:ProfilePath `
        -PackageDirectory $script:PackagePath -StageManifest $script:ManifestPath `
        -OutputDirectory $OutputDirectory 2>&1)
}

function Assert-GswgfxOfflineGuestFile {
    param(
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [Parameter(Mandatory = $true)][byte[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $hostPath = Join-Path $script:TestRoot `
        ("observe-{0}.bin" -f [Guid]::NewGuid().ToString('N'))
    $result = Invoke-GswgfxOfflineProcess $script:CreatorPath `
        @('observe', $script:ImagePath, $GuestPath, $hostPath)
    Assert-GswgfxOfflineTestTrue ($result.ExitCode -eq 0) `
        "$Label observation failed: $($result.Stderr.Trim())"
    $actual = [IO.File]::ReadAllBytes($hostPath)
    Assert-GswgfxOfflineTestTrue `
        ([Convert]::ToHexString($actual) -ceq [Convert]::ToHexString($Expected)) `
        "$Label bytes changed."
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
$script:TestRoot = Join-Path $tempBase `
    ("retvrn99-gswgfx-offline-test-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TestRoot -ErrorAction Stop | Out-Null

try {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:Wrapper = Join-Path `
        $PSScriptRoot 'stage-win98-gsw-graphics-probe-offline.ps1'
    $creatorOutput = Join-Path $script:TestRoot 'creator'
    New-Item -ItemType Directory -Path $creatorOutput | Out-Null
    $script:CreatorPath = Join-Path $creatorOutput 'retvrn99-workload-image.exe'
    $creatorHelperPath = Join-Path $creatorOutput 'retvrn99-fat32.exe'
    $odin = Get-Command odin -CommandType Application -ErrorAction Stop
    $threads = [Math]::Max(1, [Math]::Min(64, [Environment]::ProcessorCount))
    & $odin.Source build (Join-Path $repositoryRoot 'tools\workload-image') `
        "-out:$script:CreatorPath" '-o:speed' "-thread-count:$threads"
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the workload image fixture tool.' }
    & $odin.Source build (Join-Path $repositoryRoot 'src\fat32_helper') `
        "-out:$creatorHelperPath" '-o:speed' "-thread-count:$threads"
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the fixture FAT32 helper.' }

    $seedRoot = Join-Path $script:TestRoot 'seed'
    $seedGswVga = Join-Path $seedRoot 'GSW-VGA'
    New-Item -ItemType Directory -Path $seedGswVga -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $seedRoot 'IO.SYS'), (New-Object byte[] 512))
    $markerBytes = [Text.Encoding]::ASCII.GetBytes("PRESERVE-GSW-VGA`r`n")
    [IO.File]::WriteAllBytes((Join-Path $seedGswVga 'KEEP.TXT'), $markerBytes)

    $script:ProfilePath = Join-Path $script:TestRoot 'profile'
    New-Item -ItemType Directory -Path $script:ProfilePath | Out-Null
    $script:ImagePath = Join-Path $script:ProfilePath 'c_drive.img'
    $stageSeed = Invoke-GswgfxOfflineProcess $script:CreatorPath `
        @('stage', $script:ImagePath, $seedRoot)
    if ($stageSeed.ExitCode -ne 0) {
        throw "Could not create the seeded fixture image: $($stageSeed.Stderr.Trim())"
    }
    $settingsPath = Join-Path $script:ProfilePath 'settings.json'
    $settings = '{"version":2,"hard_drive_path":' +
        (($script:ImagePath | ConvertTo-Json -Compress)) + "}`n"
    Write-GswgfxOfflineUtf8File $settingsPath $settings

    $script:PackagePath = Join-Path $script:TestRoot 'package'
    $script:ManifestPath = Join-Path $script:TestRoot 'stage-manifest.tsv'
    Write-GswgfxOfflineFixturePackage $script:PackagePath $script:ManifestPath
    $exePath = Join-Path $script:PackagePath 'GSWGFX.EXE'
    $companionPath = Join-Path $script:PackagePath 'GSWVBE.EXE'
    $originalExe = [IO.File]::ReadAllBytes($exePath)
    $originalCompanion = [IO.File]::ReadAllBytes($companionPath)

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects an extra package file before output creation' {
        $extra = Join-Path $script:PackagePath 'EXTRA.TXT'
        Write-GswgfxOfflineAsciiFile $extra "extra`n"
        try {
            $output = Join-Path $script:TestRoot 'extra-output'
            Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } `
                'exactly GSWGFX.EXE and GSWVBE.EXE'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Extra-file rejection created output.'
        }
        finally { Remove-Item -LiteralPath $extra -Force }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects a missing package file before output creation' {
        $held = Join-Path $script:TestRoot 'GSWVBE.HELD'
        Move-Item -LiteralPath $companionPath -Destination $held
        try {
            $output = Join-Path $script:TestRoot 'missing-output'
            Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } `
                'exactly GSWGFX.EXE and GSWVBE.EXE'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Missing-file rejection created output.'
        }
        finally { Move-Item -LiteralPath $held -Destination $companionPath }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects package tamper against the manifest' {
        [IO.File]::WriteAllBytes($companionPath, [Text.Encoding]::ASCII.GetBytes("tampered-companion`n"))
        try {
            $output = Join-Path $script:TestRoot 'tamper-output'
            Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } `
                'does not match the stage manifest'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Tamper rejection created output.'
        }
        finally { [IO.File]::WriteAllBytes($companionPath, $originalCompanion) }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects an active profile lock' {
        $lock = Join-Path $script:ProfilePath '.profile.lock'
        Write-GswgfxOfflineAsciiFile $lock "1234`n"
        try {
            $output = Join-Path $script:TestRoot 'profile-lock-output'
            Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } 'not stopped'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Profile-lock rejection created output.'
        }
        finally { Remove-Item -LiteralPath $lock -Force }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects an active RETVRN99 lock' {
        $lock = Join-Path $script:ProfilePath '.retvrn99.lock'
        Write-GswgfxOfflineAsciiFile $lock "1234`n"
        try {
            $output = Join-Path $script:TestRoot 'runtime-lock-output'
            Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } 'not stopped'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Runtime-lock rejection created output.'
        }
        finally { Remove-Item -LiteralPath $lock -Force }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects retained FAT32 companion state' {
        $companion = Join-Path $script:ProfilePath '.c_drive.img.retvrn99-fat32'
        New-Item -ItemType Directory -Path $companion | Out-Null
        try {
            $output = Join-Path $script:TestRoot 'companion-output'
            Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } 'companion state'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Companion rejection created output.'
        }
        finally { Remove-Item -LiteralPath $companion }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects settings image mismatch' {
        $original = [IO.File]::ReadAllText($settingsPath)
        $wrong = Join-Path $script:ProfilePath 'wrong.img'
        $wrongSettings = '{"version":2,"hard_drive_path":' +
            (($wrong | ConvertTo-Json -Compress)) + "}`n"
        Write-GswgfxOfflineUtf8File $settingsPath $wrongSettings
        try {
            $output = Join-Path $script:TestRoot 'settings-output'
            Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } 'must be exactly'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Settings rejection created output.'
        }
        finally { Write-GswgfxOfflineUtf8File $settingsPath $original }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects reparse input roots' {
        $packageJunction = Join-Path $script:TestRoot 'package-junction'
        New-Item -ItemType Junction -Path $packageJunction `
            -Target $script:PackagePath | Out-Null
        try {
            $output = Join-Path $script:TestRoot 'junction-package-output'
            Assert-GswgfxOfflineTestThrows {
                & $script:Wrapper -ProfileRoot $script:ProfilePath `
                    -PackageDirectory $packageJunction `
                    -StageManifest $script:ManifestPath `
                    -OutputDirectory $output
            } 'reparse point'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Package-junction rejection created output.'
        }
        finally { Remove-Item -LiteralPath $packageJunction -Force }

        $profileJunction = Join-Path $script:TestRoot 'profile-junction'
        New-Item -ItemType Junction -Path $profileJunction `
            -Target $script:ProfilePath | Out-Null
        try {
            $output = Join-Path $script:TestRoot 'junction-profile-output'
            Assert-GswgfxOfflineTestThrows {
                & $script:Wrapper -ProfileRoot $profileJunction `
                    -PackageDirectory $script:PackagePath `
                    -StageManifest $script:ManifestPath `
                    -OutputDirectory $output
            } 'reparse point'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Profile-junction rejection created output.'
        }
        finally { Remove-Item -LiteralPath $profileJunction -Force }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects unsafe output boundaries' {
        $existing = Join-Path $script:TestRoot 'existing-output'
        New-Item -ItemType Directory -Path $existing | Out-Null
        Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $existing } 'already exists'
        $missing = Join-Path $script:TestRoot 'missing-parent\output'
        Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $missing } `
            'parent does not exist'
        $overlap = Join-Path $script:ProfilePath 'nested-output'
        Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $overlap } 'must not overlap'

        $realParent = Join-Path $script:TestRoot 'real-output-parent'
        $linkedParent = Join-Path $script:TestRoot 'linked-output-parent'
        New-Item -ItemType Directory -Path $realParent | Out-Null
        New-Item -ItemType Junction -Path $linkedParent -Target $realParent | Out-Null
        try {
            Assert-GswgfxOfflineTestThrows {
                Invoke-GswgfxOfflineWrapper (Join-Path $linkedParent 'output')
            } 'reparse point'
        }
        finally { Remove-Item -LiteralPath $linkedParent -Force }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects a package alternate data stream' {
        $stream = "$companionPath`:GSWGFX_TEST"
        [IO.File]::WriteAllText($stream, 'hidden')
        try {
            $output = Join-Path $script:TestRoot 'stream-output'
            Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } `
                'alternate data streams'
            Assert-GswgfxOfflineTestTrue (-not (Test-Path -LiteralPath $output)) `
                'Alternate-stream rejection created output.'
        }
        finally { Remove-Item -LiteralPath $companionPath -Stream 'GSWGFX_TEST' -Force }
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper stages exact GSWGFX and preserves GSW-VGA' {
        $output = Join-Path $script:TestRoot 'success-output'
        $messages = Invoke-GswgfxOfflineWrapper $output
        Assert-GswgfxOfflineTestTrue `
            ((($messages | Out-String) -match 'guest_path=C:\\GSWGFX')) `
            'Success output did not report C:\GSWGFX.'
        Assert-GswgfxOfflineTestTrue `
            (Test-Path -LiteralPath (Join-Path $output 'retvrn99-gswgfx-offline-stage.exe') `
                -PathType Leaf) 'GSWGFX staging executable is absent.'
        Assert-GswgfxOfflineTestTrue `
            (Test-Path -LiteralPath (Join-Path $output 'retvrn99-fat32.exe') -PathType Leaf) `
            'Adjacent FAT32 helper is absent.'
        Assert-GswgfxOfflineTestTrue `
            (-not (Test-Path -LiteralPath `
                (Join-Path $script:ProfilePath '.c_drive.img.retvrn99-fat32'))) `
            'Successful stage left FAT32 companion state.'
        Assert-GswgfxOfflineGuestFile 'GSW-VGA/KEEP.TXT' $markerBytes 'GSW-VGA marker'
        Assert-GswgfxOfflineGuestFile 'GSWGFX/GSWGFX.EXE' $originalExe 'GSWGFX executable'
        Assert-GswgfxOfflineGuestFile 'GSWGFX/GSWVBE.EXE' $originalCompanion 'GSWVBE companion'
    }

    Invoke-GswgfxOfflineSelfTest 'wrapper rejects destination collision without mutation' {
        $output = Join-Path $script:TestRoot 'collision-output'
        Assert-GswgfxOfflineTestThrows { Invoke-GswgfxOfflineWrapper $output } `
            'destination already exists'
        Assert-GswgfxOfflineTestTrue `
            (-not (Test-Path -LiteralPath `
                (Join-Path $script:ProfilePath '.c_drive.img.retvrn99-fat32'))) `
            'Collision left FAT32 companion state.'
        Assert-GswgfxOfflineGuestFile 'GSW-VGA/KEEP.TXT' $markerBytes `
            'GSW-VGA marker after collision'
        Assert-GswgfxOfflineGuestFile 'GSWGFX/GSWGFX.EXE' $originalExe `
            'GSWGFX executable after collision'
        Assert-GswgfxOfflineGuestFile 'GSWGFX/GSWVBE.EXE' $originalCompanion `
            'GSWVBE companion after collision'
    }
}
finally {
    $verified = [IO.Path]::GetFullPath($script:TestRoot)
    $prefix = $tempBase + [IO.Path]::DirectorySeparatorChar
    if (-not $verified.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($verified) -notlike 'retvrn99-gswgfx-offline-test-*') {
        throw "Refusing unsafe test cleanup path: $verified"
    }
    if (Test-Path -LiteralPath $verified) {
        Remove-Item -LiteralPath $verified -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures of $script:Tests GSWGFX offline staging test(s) failed."
}

Write-Host "All $script:Tests GSWGFX offline staging PowerShell tests passed."

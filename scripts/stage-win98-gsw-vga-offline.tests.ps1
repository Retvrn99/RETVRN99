# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-OfflineStageTestTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-OfflineStageTestThrows {
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

function Invoke-OfflineStageSelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures += 1
        [Console]::Error.WriteLine("FAIL $Name`: $($_.Exception.Message)")
    }
}

function Invoke-OfflineStageProcess {
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

function Write-OfflineStageUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-OfflineStageFixturePackage {
    param(
        [Parameter(Mandatory = $true)][string]$PackageDirectory,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$InventoryPath,
        [switch]$Changed
    )

    New-Item -ItemType Directory -Path $PackageDirectory | Out-Null
    $files = @(
        [pscustomobject]@{ Name = 'gswmini.inf'; Source = 'vmdisp9x-gsw\gswmini.inf'; Kind = 'INF'; Bytes = [byte[]](0x5B, 0x56, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E, 0x5D, 0x0D, 0x0A) },
        [pscustomobject]@{ Name = 'gswmini.drv'; Source = 'vmdisp9x-gsw\gswmini.drv'; Kind = 'Binary'; Bytes = [byte[]](0x4D, 0x5A, 0x01, 0x10) },
        [pscustomobject]@{ Name = 'gswmini.vxd'; Source = 'vmdisp9x-gsw\gswmini.vxd'; Kind = 'Binary'; Bytes = [byte[]](0x4D, 0x5A, 0x02, 0x20, 0x21) },
        [pscustomobject]@{ Name = 'gswhal9x.dll'; Source = 'vmhal9x-gsw\gswhal9x.dll'; Kind = 'Binary'; Bytes = [byte[]](0x4D, 0x5A, 0x03, 0x30, 0x31, 0x32) },
        [pscustomobject]@{ Name = 'gswdd32.dll'; Source = 'vmhal9x-gsw\gswdd32.dll'; Kind = 'Binary'; Bytes = [byte[]](0x4D, 0x5A, 0x04, 0x40, 0x41, 0x42, 0x43) }
    )
    if ($Changed) {
        $files[4].Bytes = [byte[]](0x4D, 0x5A, 0x04, 0x40, 0x41, 0x42, 0x44)
    }
    $manifestRows = New-Object Collections.Generic.List[string]
    $inventoryRows = New-Object Collections.Generic.List[string]
    foreach ($file in $files) {
        $path = Join-Path $PackageDirectory $file.Name
        [IO.File]::WriteAllBytes($path, $file.Bytes)
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestRows.Add((
            "gsw-vga`t$($file.Source)`tGSW-VGA\$($file.Name)`t$($file.Kind)" +
            "`t$hash`t$($file.Bytes.Length)`tPCI\VEN_FFFE&DEV_0002`t0"
        ))
        $inventoryRows.Add((
            "gsw-vga`tGSW-VGA\$($file.Name)`t$($file.Kind)" +
            "`tPCI\VEN_FFFE&DEV_0002`t0"
        ))
    }
    $manifest = @(
        '# SPDX-License-Identifier: GPL-3.0-only',
        (@(
            'package_id', 'source_relative_path', 'destination_relative_path',
            'kind', 'sha256', 'bytes', 'hardware_id', 'run_once_order'
        ) -join "`t")
    ) + $manifestRows
    $inventory = @(
        '# SPDX-License-Identifier: GPL-3.0-only',
        (@(
            'package_id', 'destination_relative_path', 'kind', 'hardware_id',
            'run_once_order'
        ) -join "`t")
    ) + $inventoryRows
    Write-OfflineStageUtf8File $ManifestPath (($manifest -join "`n") + "`n")
    Write-OfflineStageUtf8File $InventoryPath (($inventory -join "`n") + "`n")
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
$script:TestRoot = Join-Path $tempBase `
    ("retvrn99-gsw-vga-offline-test-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TestRoot -ErrorAction Stop | Out-Null

try {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $wrapper = Join-Path $PSScriptRoot 'stage-win98-gsw-vga-offline.ps1'
    $priorManifestPath = Join-Path `
        $repositoryRoot 'drivers\win98\gsw-vga-prior-only-manifest.tsv'
    $currentManifestPath = Join-Path `
        $repositoryRoot 'drivers\win98\payload-manifest.schema.tsv'
    $currentInventoryPath = Join-Path `
        $repositoryRoot 'drivers\win98\payload-inventory.schema.tsv'
    $creatorOutput = Join-Path $script:TestRoot 'creator'
    New-Item -ItemType Directory -Path $creatorOutput | Out-Null
    $creatorPath = Join-Path $creatorOutput 'retvrn99-workload-image.exe'
    $creatorHelperPath = Join-Path $creatorOutput 'retvrn99-fat32.exe'
    $odin = Get-Command odin -CommandType Application -ErrorAction Stop
    $threads = [Math]::Max(1, [Math]::Min(64, [Environment]::ProcessorCount))
    & $odin.Source build (Join-Path $repositoryRoot 'tools\workload-image') `
        "-out:$creatorPath" '-o:speed' "-thread-count:$threads"
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the workload image fixture tool.' }
    & $odin.Source build (Join-Path $repositoryRoot 'src\fat32_helper') `
        "-out:$creatorHelperPath" '-o:speed' "-thread-count:$threads"
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the fixture FAT32 helper.' }

    $profilePath = Join-Path $script:TestRoot 'profile'
    New-Item -ItemType Directory -Path $profilePath | Out-Null
    $imagePath = Join-Path $profilePath 'c_drive.img'
    $create = Invoke-OfflineStageProcess $creatorPath @('create', $imagePath, '1')
    if ($create.ExitCode -ne 0) {
        throw "Could not create the fixture image: $($create.Stderr.Trim())"
    }
    $settings = '{"version":2,"hard_drive_path":' +
        (($imagePath | ConvertTo-Json -Compress)) + "}`n"
    Write-OfflineStageUtf8File (Join-Path $profilePath 'settings.json') $settings

    $packagePath = Join-Path $script:TestRoot 'package'
    $manifestPath = Join-Path $script:TestRoot 'manifest.tsv'
    $inventoryPath = Join-Path $script:TestRoot 'inventory.tsv'
    Write-OfflineStageFixturePackage $packagePath $manifestPath $inventoryPath
    Invoke-OfflineStageSelfTest 'production wrapper rejects self-consistent toy authority' {
        $outputPath = Join-Path $script:TestRoot 'stage-tools'
        Assert-OfflineStageTestThrows {
            & $wrapper -ProfileRoot $profilePath `
                -PackageDirectory $packagePath -OutputDirectory $outputPath `
                -PayloadManifest $manifestPath -PayloadInventory $inventoryPath
        } 'pinned current GSW-VGA package'
        Assert-OfflineStageTestTrue `
            (Test-Path -LiteralPath (Join-Path $outputPath 'retvrn99-gsw-vga-offline-stage.exe') -PathType Leaf) `
            'Offline staging executable was not built.'
        Assert-OfflineStageTestTrue `
            (Test-Path -LiteralPath (Join-Path $outputPath 'retvrn99-fat32.exe') -PathType Leaf) `
            'Adjacent RETVRN99-FAT32 executable was not built.'

        $alteredPriorPath = Join-Path $script:TestRoot 'altered-prior.tsv'
        $reviewedHash = '5b954dc86a1c4e2e4e06c7fd16f3ea8c93991e485f1bae5512121c371d39b8ea'
        $alteredHash = '8b954dc86a1c4e2e4e06c7fd16f3ea8c93991e485f1bae5512121c371d39b8ea'
        $priorText = [IO.File]::ReadAllText($priorManifestPath)
        $alteredPriorText = $priorText.Replace($reviewedHash, $alteredHash)
        Assert-OfflineStageTestTrue ($alteredPriorText -cne $priorText) `
            'Prior-manifest adversarial fixture did not alter the reviewed hash.'
        Write-OfflineStageUtf8File $alteredPriorPath $alteredPriorText
        $alteredPrior = Invoke-OfflineStageProcess `
            (Join-Path $outputPath 'retvrn99-gsw-vga-offline-stage.exe') `
            @(
                'stage', $imagePath, $packagePath, $currentManifestPath,
                $currentInventoryPath, $alteredPriorPath
            )
        Assert-OfflineStageTestTrue ($alteredPrior.ExitCode -ne 0) `
            'An altered prior-only manifest was accepted.'
        Assert-OfflineStageTestTrue `
            ($alteredPrior.Stderr -match 'prior-only manifest is invalid') `
            "Altered prior-manifest rejection was not explicit: $($alteredPrior.Stderr.Trim())"

        $toyPayload = Invoke-OfflineStageProcess `
            (Join-Path $outputPath 'retvrn99-gsw-vga-offline-stage.exe') `
            @(
                'stage', $imagePath, $packagePath, $currentManifestPath,
                $currentInventoryPath, $priorManifestPath
            )
        Assert-OfflineStageTestTrue ($toyPayload.ExitCode -ne 0) `
            'Toy bytes were accepted under the pinned current manifest.'
        Assert-OfflineStageTestTrue `
            ($toyPayload.Stderr -match 'package file size or type is invalid') `
            "Toy-byte rejection was not explicit: $($toyPayload.Stderr.Trim())"
        Assert-OfflineStageTestTrue `
            (-not (Test-Path -LiteralPath (Join-Path $profilePath '.c_drive.img.retvrn99-fat32'))) `
            'Rejected production-authority probes left FAT32 companion state.'
    }

    Invoke-OfflineStageSelfTest 'wrapper rejects active profile lock before output creation' {
        $lockPath = Join-Path $profilePath '.profile.lock'
        Write-OfflineStageUtf8File $lockPath "1234`ntest`n"
        try {
            $outputPath = Join-Path $script:TestRoot 'locked-output'
            Assert-OfflineStageTestThrows {
                & $wrapper -ProfileRoot $profilePath -PackageDirectory $packagePath `
                    -OutputDirectory $outputPath -PayloadManifest $manifestPath `
                    -PayloadInventory $inventoryPath
            } 'not stopped'
            Assert-OfflineStageTestTrue (-not (Test-Path -LiteralPath $outputPath)) `
                'Rejected locked profile created an output directory.'
        }
        finally {
            Remove-Item -LiteralPath $lockPath -Force
        }
    }

    Invoke-OfflineStageSelfTest 'wrapper rejects package reparse point before output creation' {
        $junctionPath = Join-Path $script:TestRoot 'package-junction'
        New-Item -ItemType Junction -Path $junctionPath -Target $packagePath | Out-Null
        try {
            $outputPath = Join-Path $script:TestRoot 'junction-output'
            Assert-OfflineStageTestThrows {
                & $wrapper -ProfileRoot $profilePath -PackageDirectory $junctionPath `
                    -OutputDirectory $outputPath -PayloadManifest $manifestPath `
                    -PayloadInventory $inventoryPath
            } 'reparse point'
            Assert-OfflineStageTestTrue (-not (Test-Path -LiteralPath $outputPath)) `
                'Rejected package junction created an output directory.'
        }
        finally {
            Remove-Item -LiteralPath $junctionPath -Force
        }
    }

    Invoke-OfflineStageSelfTest 'wrapper rejects retained FAT32 companion before output creation' {
        $companionPath = Join-Path $profilePath '.c_drive.img.retvrn99-fat32'
        New-Item -ItemType Directory -Path $companionPath | Out-Null
        try {
            $outputPath = Join-Path $script:TestRoot 'companion-output'
            Assert-OfflineStageTestThrows {
                & $wrapper -ProfileRoot $profilePath -PackageDirectory $packagePath `
                    -OutputDirectory $outputPath -PayloadManifest $manifestPath `
                    -PayloadInventory $inventoryPath
            } 'companion state'
            Assert-OfflineStageTestTrue (-not (Test-Path -LiteralPath $outputPath)) `
                'Rejected companion state created an output directory.'
        }
        finally {
            Remove-Item -LiteralPath $companionPath
        }
    }

    Invoke-OfflineStageSelfTest 'wrapper rejects mismatched settings and existing output' {
        $settingsPath = Join-Path $profilePath 'settings.json'
        $original = [IO.File]::ReadAllText($settingsPath)
        try {
            $wrongImage = Join-Path $profilePath 'wrong.img'
            $wrongSettings = '{"version":2,"hard_drive_path":' +
                (($wrongImage | ConvertTo-Json -Compress)) + "}`n"
            Write-OfflineStageUtf8File $settingsPath $wrongSettings
            Assert-OfflineStageTestThrows {
                & $wrapper -ProfileRoot $profilePath -PackageDirectory $packagePath `
                    -OutputDirectory (Join-Path $script:TestRoot 'wrong-settings-output') `
                    -PayloadManifest $manifestPath -PayloadInventory $inventoryPath
            } 'must be exactly'
        }
        finally {
            Write-OfflineStageUtf8File $settingsPath $original
        }

        $existingOutput = Join-Path $script:TestRoot 'existing-output'
        New-Item -ItemType Directory -Path $existingOutput | Out-Null
        Assert-OfflineStageTestThrows {
            & $wrapper -ProfileRoot $profilePath -PackageDirectory $packagePath `
                -OutputDirectory $existingOutput -PayloadManifest $manifestPath `
                -PayloadInventory $inventoryPath
        } 'already exists'
    }
}
finally {
    $verified = [IO.Path]::GetFullPath($script:TestRoot)
    $prefix = $tempBase + [IO.Path]::DirectorySeparatorChar
    if (-not $verified.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($verified) -notlike 'retvrn99-gsw-vga-offline-test-*') {
        throw "Refusing unsafe test cleanup path: $verified"
    }
    if (Test-Path -LiteralPath $verified) {
        Remove-Item -LiteralPath $verified -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures GSW-VGA offline staging test(s) failed."
}

Write-Host 'All GSW-VGA offline staging PowerShell tests passed.'

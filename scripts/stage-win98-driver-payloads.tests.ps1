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
        [Console]::Error.WriteLine(
            "FAIL $Name`: $($_.Exception.Message)$([Environment]::NewLine)$($_.ScriptStackTrace)"
        )
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

function New-DirectoryReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Target)
    $kind = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $kind -Path $Path -Target $Target | Out-Null
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

function Write-Tsv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    $lines = @('# SPDX-License-Identifier: GPL-3.0-only', ($Columns -join "`t"))
    foreach ($row in $Rows) {
        $values = @(
            foreach ($column in $Columns) {
                $value = [string]$row.$column
                if ($value -match "[`t`r`n]") { throw "Unsafe TSV fixture value in '$column'." }
                $value
            }
        )
        $lines += $values -join "`t"
    }
    [IO.File]::WriteAllText($Path, ($lines -join "`r`n") + "`r`n")
}

function New-InventoryRow {
    param(
        [string]$Package,
        [string]$Destination,
        [string]$Kind,
        [string]$HardwareId,
        [int]$Order
    )

    return [pscustomobject]@{
        package_id = $Package
        destination_relative_path = $Destination
        kind = $Kind
        hardware_id = $HardwareId
        run_once_order = $Order
    }
}

function New-ManifestRow {
    param(
        [Parameter(Mandatory = $true)]$InventoryRow,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$PayloadRoot
    )

    $path = Join-Path $PayloadRoot $Source
    $file = Get-Item -LiteralPath $path
    return [pscustomobject]@{
        package_id = $InventoryRow.package_id
        source_relative_path = $Source
        destination_relative_path = $InventoryRow.destination_relative_path
        kind = $InventoryRow.kind
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = $file.Length
        hardware_id = $InventoryRow.hardware_id
        run_once_order = $InventoryRow.run_once_order
    }
}

function Invoke-Staging {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Inventory,
        [Parameter(Mandatory = $true)][string]$Manifest,
        [AllowEmptyCollection()][string[]]$PackageIds
    )

    $arguments = @{
        SourceRoot = $script:SourceRoot
        PayloadRoot = $script:PayloadRoot
        PayloadManifest = $Manifest
        PayloadInventory = $Inventory
        LockFile = $script:LockPath
        OutputDirectory = Join-Path $script:TestRoot $Name
    }
    if ($PSBoundParameters.ContainsKey('PackageIds')) {
        $arguments.PackageId = $PackageIds
    }
    return @(& $script:StageScript @arguments)
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for the Windows 98 payload staging tests.'
}

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-win98-stage-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null

try {
    $script:StageScript = Join-Path $PSScriptRoot 'stage-win98-driver-payloads.ps1'
    $script:SourceRoot = Join-Path $script:TestRoot 'sources'
    $script:PayloadRoot = Join-Path $script:TestRoot 'payloads'
    New-Item -ItemType Directory -Path $script:SourceRoot | Out-Null
    New-Item -ItemType Directory -Path $script:PayloadRoot | Out-Null

    $displayOrigin = 'https://example.invalid/vmdisp9x.git'
    $displayCheckout = Join-Path $script:SourceRoot 'vmdisp9x'
    $displayCommit = New-PinnedCheckout -Path $displayCheckout -Origin $displayOrigin
    $halOrigin = 'https://example.invalid/vmhal9x.git'
    $halCheckout = Join-Path $script:SourceRoot 'vmhal9x'
    $halCommit = New-PinnedCheckout -Path $halCheckout -Origin $halOrigin
    $script:LockPath = Join-Path $script:TestRoot 'upstream.lock.tsv'
    $lockColumns = @(
        'name', 'source_directory', 'repository', 'commit',
        'upstream_license', 'disposition', 'scope'
    )
    $defaultLockRows = @(
        [pscustomobject]@{
            name = 'vmdisp9x'; source_directory = 'vmdisp9x'; repository = $displayOrigin
            commit = $displayCommit; upstream_license = 'MIT'; disposition = 'planned'
            scope = 'display-driver'
        },
        [pscustomobject]@{
            name = 'vmhal9x'; source_directory = 'vmhal9x'; repository = $halOrigin
            commit = $halCommit; upstream_license = 'MIT'; disposition = 'planned'
            scope = 'directdraw-hal'
        },
        [pscustomobject]@{
            name = 'wine9x'; source_directory = 'wine9x'; repository = 'https://example.invalid/wine9x.git'
            commit = '0123456789abcdef0123456789abcdef01234567'; upstream_license = 'LGPL-2.1-or-later'
            disposition = 'planned'; scope = 'dx9-compatibility'
        }
    )
    Write-Tsv -Path $script:LockPath -Columns $lockColumns -Rows $defaultLockRows

    $payloadFiles = [ordered]@{
        'build\vga\GSWVGA.INF' = 'display-inf'
        'build\vga\GSWVGA.DRV' = 'display-driver'
        'build\vga\GSWVGA.VXD' = 'display-mini-vdd'
        'build\vga\GSWHAL9X.DLL' = 'display-hal'
        'build\vga\GSWDD32.DLL' = 'display-bridge'
        'build\sound\GSWSOUND.INF' = 'sound-inf'
        'build\sound\GSWSOUND.DRV' = 'sound-wave-driver'
        'build\sound\GSWSOUND.VXD' = 'sound-virtual-device'
        'components\DX9REDIST.EXE' = 'directx-runtime'
        'components\GSWDX9.DLL' = 'dx9-compatibility'
    }
    foreach ($relativePath in $payloadFiles.Keys) {
        $path = Join-Path $script:PayloadRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, $payloadFiles[$relativePath])
    }

    $inventoryColumns = @(
        'package_id', 'destination_relative_path', 'kind', 'hardware_id', 'run_once_order'
    )
    $manifestColumns = @(
        'package_id', 'source_relative_path', 'destination_relative_path', 'kind',
        'sha256', 'bytes', 'hardware_id', 'run_once_order'
    )
    $vgaInf = New-InventoryRow 'gsw-vga' 'VGA\GSWVGA.INF' 'INF' 'PCI\VEN_FFFE&DEV_0002' 0
    $vgaDriver = New-InventoryRow 'gsw-vga' 'VGA\GSWVGA.DRV' 'Binary' 'PCI\VEN_FFFE&DEV_0002' 0
    $vgaVxd = New-InventoryRow 'gsw-vga' 'VGA\GSWVGA.VXD' 'Binary' 'PCI\VEN_FFFE&DEV_0002' 0
    $vgaHal = New-InventoryRow 'gsw-vga' 'VGA\GSWHAL9X.DLL' 'Binary' 'PCI\VEN_FFFE&DEV_0002' 0
    $vgaBridge = New-InventoryRow 'gsw-vga' 'VGA\GSWDD32.DLL' 'Binary' 'PCI\VEN_FFFE&DEV_0002' 0
    $soundInf = New-InventoryRow 'gsw-sound' 'SOUND\GSWSOUND.INF' 'INF' 'PCI\VEN_FFFE&DEV_0003' 0
    $soundDrv = New-InventoryRow 'gsw-sound' 'SOUND\GSWSOUND.DRV' 'Binary' 'PCI\VEN_FFFE&DEV_0003' 0
    $soundVxd = New-InventoryRow 'gsw-sound' 'SOUND\GSWSOUND.VXD' 'Binary' 'PCI\VEN_FFFE&DEV_0003' 0
    $directX = New-InventoryRow 'directx9-runtime' 'RUNONCE\DX9REDIST.EXE' 'Component' '' 100
    $compat = New-InventoryRow 'gsw-dx9-compat' 'RUNONCE\GSWDX9.DLL' 'Component' '' 200
    $allInventoryRows = @(
        $vgaInf, $vgaDriver, $vgaVxd, $vgaHal, $vgaBridge,
        $soundInf, $soundDrv, $soundVxd,
        $directX, $compat
    )
    $vgaManifestRows = @(
        New-ManifestRow $vgaInf 'build\vga\GSWVGA.INF' $script:PayloadRoot
        New-ManifestRow $vgaDriver 'build\vga\GSWVGA.DRV' $script:PayloadRoot
        New-ManifestRow $vgaVxd 'build\vga\GSWVGA.VXD' $script:PayloadRoot
        New-ManifestRow $vgaHal 'build\vga\GSWHAL9X.DLL' $script:PayloadRoot
        New-ManifestRow $vgaBridge 'build\vga\GSWDD32.DLL' $script:PayloadRoot
    )
    $soundManifestRows = @(
        New-ManifestRow $soundInf 'build\sound\GSWSOUND.INF' $script:PayloadRoot
        New-ManifestRow $soundDrv 'build\sound\GSWSOUND.DRV' $script:PayloadRoot
        New-ManifestRow $soundVxd 'build\sound\GSWSOUND.VXD' $script:PayloadRoot
    )
    $directXManifestRows = @(
        New-ManifestRow $directX 'components\DX9REDIST.EXE' $script:PayloadRoot
    )
    $compatManifestRows = @(
        New-ManifestRow $compat 'components\GSWDX9.DLL' $script:PayloadRoot
    )
    $allManifestRows = @(
        $vgaManifestRows + $soundManifestRows + $directXManifestRows + $compatManifestRows
    )
    $fullInventory = Join-Path $script:TestRoot 'full-inventory.tsv'
    $vgaInventory = Join-Path $script:TestRoot 'vga-inventory.tsv'
    $soundInventory = Join-Path $script:TestRoot 'sound-inventory.tsv'
    $vgaManifest = Join-Path $script:TestRoot 'vga-manifest.tsv'
    $soundManifest = Join-Path $script:TestRoot 'sound-manifest.tsv'
    $directXManifest = Join-Path $script:TestRoot 'directx-manifest.tsv'
    $compatManifest = Join-Path $script:TestRoot 'compat-manifest.tsv'
    $fullManifest = Join-Path $script:TestRoot 'full-manifest.tsv'
    Write-Tsv $fullInventory $inventoryColumns $allInventoryRows
    Write-Tsv $vgaInventory $inventoryColumns @($vgaInf, $vgaDriver, $vgaVxd, $vgaHal, $vgaBridge)
    Write-Tsv $soundInventory $inventoryColumns @($soundInf, $soundDrv, $soundVxd)
    Write-Tsv $vgaManifest $manifestColumns $vgaManifestRows
    Write-Tsv $soundManifest $manifestColumns $soundManifestRows
    Write-Tsv $directXManifest $manifestColumns $directXManifestRows
    Write-Tsv $compatManifest $manifestColumns $compatManifestRows
    Write-Tsv $fullManifest $manifestColumns $allManifestRows

    Invoke-SelfTest 'Explicit VGA selection stages only the complete selected package' {
        $output = Invoke-Staging 'explicit-vga' $fullInventory $vgaManifest @('gsw-vga')
        Assert-True (($output -join [Environment]::NewLine) -match 'Verified 2 immutable')
        Assert-True (($output -join [Environment]::NewLine) -match 'Staged 5 hash-verified')
        $files = @(Get-ChildItem (Join-Path $script:TestRoot 'explicit-vga') -File -Recurse)
        Assert-Equal $files.Count 5
        Assert-True (Test-Path (Join-Path $script:TestRoot 'explicit-vga\VGA\GSWVGA.INF'))
        Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'explicit-vga\SOUND')))
    }

    Invoke-SelfTest 'Omitted selection stages every inventory-declared package' {
        $output = Invoke-Staging -Name 'declared-vga' -Inventory $vgaInventory -Manifest $vgaManifest
        Assert-True (($output -join [Environment]::NewLine) -match 'Staged 5 hash-verified')
    }

    Invoke-SelfTest 'Explicit sound selection stages the complete INF DRV VXD fixture' {
        $output = Invoke-Staging 'explicit-sound' $soundInventory $soundManifest @('gsw-sound')
        Assert-True (($output -join [Environment]::NewLine) -match 'Staged 3 hash-verified')
        $outputRoot = Join-Path $script:TestRoot 'explicit-sound\SOUND'
        Assert-True (Test-Path (Join-Path $outputRoot 'GSWSOUND.INF'))
        Assert-True (Test-Path (Join-Path $outputRoot 'GSWSOUND.DRV'))
        Assert-True (Test-Path (Join-Path $outputRoot 'GSWSOUND.VXD'))
    }

    Invoke-SelfTest 'A source-free package stages without unrelated provenance' {
        $output = Invoke-Staging 'directx-only' $fullInventory $directXManifest @('directx9-runtime')
        Assert-True (($output -join [Environment]::NewLine) -notmatch 'Verified .* source checkouts')
        Assert-True (($output -join [Environment]::NewLine) -match 'Staged 1 hash-verified')
        Assert-True (Test-Path (Join-Path $script:TestRoot 'directx-only\RUNONCE\DX9REDIST.EXE'))
    }

    Invoke-SelfTest 'Explicit package selection is closed and unambiguous' {
        Assert-Throws {
            Invoke-Staging 'unknown' $fullInventory $vgaManifest @('unknown-package')
        } 'Unknown or invalid selected'
        Assert-Throws {
            Invoke-Staging 'duplicate' $fullInventory $vgaManifest @('gsw-vga', 'gsw-vga')
        } 'Duplicate selected'
        Assert-Throws {
            Invoke-Staging 'empty' $fullInventory $vgaManifest @()
        } 'without any package IDs'
        Assert-Throws {
            Invoke-Staging 'undeclared' $vgaInventory $vgaManifest @('gsw-sound')
        } 'is not declared in the reviewed inventory'
    }

    Invoke-SelfTest 'A selected package must have its complete reviewed shape and manifest' {
        $partialInventory = Join-Path $script:TestRoot 'partial-inventory.tsv'
        $partialManifest = Join-Path $script:TestRoot 'partial-manifest.tsv'
        Write-Tsv $partialInventory $inventoryColumns @($vgaInf)
        Write-Tsv $partialManifest $manifestColumns @($vgaManifestRows[0])
        Assert-Throws {
            Invoke-Staging 'partial-shape' $partialInventory $partialManifest @('gsw-vga')
        } 'exactly one INF, at least one binary'
        Assert-Throws {
            Invoke-Staging 'partial-manifest' $vgaInventory $partialManifest @('gsw-vga')
        } 'manifest is incomplete'
    }

    Invoke-SelfTest 'Selection does not admit manifest rows from another package' {
        $mixedManifest = Join-Path $script:TestRoot 'mixed-manifest.tsv'
        Write-Tsv $mixedManifest $manifestColumns @($vgaManifestRows + $soundManifestRows)
        Assert-Throws {
            Invoke-Staging 'mixed' $fullInventory $mixedManifest @('gsw-vga')
        } 'is not selected for staging'
    }

    Invoke-SelfTest 'Selected staging retains exact payload hashes' {
        $driverPath = Join-Path $script:PayloadRoot 'build\vga\GSWVGA.DRV'
        [IO.File]::AppendAllText($driverPath, 'changed')
        try {
            Assert-Throws {
                Invoke-Staging 'hash-mismatch' $vgaInventory $vgaManifest @('gsw-vga')
            } 'failed its exact size or SHA-256 check'
        }
        finally {
            [IO.File]::WriteAllText($driverPath, $payloadFiles['build\vga\GSWVGA.DRV'])
        }
    }

    Invoke-SelfTest 'VGA staging verifies its source provenance but not unrelated locks' {
        $fixturePath = Join-Path $displayCheckout 'fixture.txt'
        [IO.File]::AppendAllText($fixturePath, 'dirty')
        try {
            Assert-Throws {
                Invoke-Staging 'dirty-source' $vgaInventory $vgaManifest @('gsw-vga')
            } "Pinned source 'vmdisp9x' has local changes"
        }
        finally {
            [IO.File]::WriteAllText($fixturePath, 'pinned-source')
        }
        Assert-Equal (Invoke-Git @('-C', $displayCheckout, 'status', '--porcelain')) ''

        $halFixturePath = Join-Path $halCheckout 'fixture.txt'
        [IO.File]::AppendAllText($halFixturePath, 'dirty')
        try {
            Assert-Throws {
                Invoke-Staging 'dirty-hal-source' $vgaInventory $vgaManifest @('gsw-vga')
            } "Pinned source 'vmhal9x' has local changes"
        }
        finally {
            [IO.File]::WriteAllText($halFixturePath, 'pinned-source')
        }
        Assert-Equal (Invoke-Git @('-C', $halCheckout, 'status', '--porcelain')) ''
    }

    Invoke-SelfTest 'Reference-only provenance cannot authorize a selected package' {
        $defaultLockRows[0].disposition = 'reference-only'
        Write-Tsv $script:LockPath $lockColumns $defaultLockRows
        try {
            Assert-Throws {
                Invoke-Staging 'reference-only' $vgaInventory $vgaManifest @('gsw-vga')
            } 'exactly one planned, named lock row'
        }
        finally {
            $defaultLockRows[0].disposition = 'planned'
            Write-Tsv $script:LockPath $lockColumns $defaultLockRows
        }
    }

    Invoke-SelfTest 'Multi-source and full implicit selections verify their complete provenance' {
        $completeLockRows = @($defaultLockRows[0], $defaultLockRows[1])
        foreach ($source in @(
            [pscustomobject]@{
                Name = 'mesa9x'; License = 'MIT'; Scope = 'software-rasterizer'
            },
            [pscustomobject]@{
                Name = 'wine9x'; License = 'LGPL-2.1-or-later'; Scope = 'dx9-compatibility'
            }
        )) {
            $origin = "https://example.invalid/$($source.Name).git"
            $commit = New-PinnedCheckout `
                -Path (Join-Path $script:SourceRoot $source.Name) -Origin $origin
            $completeLockRows += [pscustomobject]@{
                name = $source.Name; source_directory = $source.Name; repository = $origin
                commit = $commit; upstream_license = $source.License; disposition = 'planned'
                scope = $source.Scope
            }
        }
        Write-Tsv $script:LockPath $lockColumns $completeLockRows

        $compatOutput = Invoke-Staging 'compat-only' $fullInventory $compatManifest @('gsw-dx9-compat')
        Assert-True (($compatOutput -join [Environment]::NewLine) -match 'Verified 2 immutable')
        Assert-True (($compatOutput -join [Environment]::NewLine) -match 'Staged 1 hash-verified')

        $fullOutput = Invoke-Staging -Name 'full-selection' -Inventory $fullInventory -Manifest $fullManifest
        Assert-True (($fullOutput -join [Environment]::NewLine) -match 'Verified 4 immutable')
        Assert-True (($fullOutput -join [Environment]::NewLine) -match 'Staged 10 hash-verified')
    }

    Invoke-SelfTest 'Staging rejects a reparse-point output ancestor' {
        $target = Join-Path $script:TestRoot 'reparse-target'
        $link = Join-Path $script:TestRoot 'reparse-parent'
        New-Item -ItemType Directory -Path $target | Out-Null
        New-DirectoryReparsePoint -Path $link -Target $target
        try {
            Assert-Throws {
                & $script:StageScript -SourceRoot $script:SourceRoot `
                    -PayloadRoot $script:PayloadRoot -PayloadManifest $vgaManifest `
                    -PayloadInventory $vgaInventory -LockFile $script:LockPath `
                    -OutputDirectory (Join-Path $link 'stage') -PackageId 'gsw-vga'
            } 'traverses reparse-point component'
        }
        finally {
            Remove-Item -LiteralPath $link -Force
        }
    }
}
finally {
    $verifiedTestRoot = [IO.Path]::GetFullPath($script:TestRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $verifiedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($verifiedTestRoot)).StartsWith('retvrn99-win98-stage-test-')) {
        throw "Refusing to remove unverified staging test path '$verifiedTestRoot'."
    }
    if (Test-Path -LiteralPath $verifiedTestRoot) {
        Remove-Item -LiteralPath $verifiedTestRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures Windows 98 payload staging test(s) failed."
}
Write-Host 'All Windows 98 payload staging tests passed.'

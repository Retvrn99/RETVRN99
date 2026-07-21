# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MesaCheckout = 'D:\src\retvrn99-win98\mesa9x',
    [string]$ToolchainRoot = 'D:\src\retvrn99-win98\toolchains'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Tests = 0
$script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ProductionModule = Join-Path $script:Root 'drivers\win98\mesa-gsw'
$script:Verifier = Join-Path $PSScriptRoot 'verify-win98-mesa-gsw-winsys-shell.ps1'

. $script:Verifier -MesaCheckout $MesaCheckout -ToolchainRoot $ToolchainRoot

function Invoke-SelfTest {
    param([string]$Name, [scriptblock]$Body)
    $script:Tests++
    try {
        & $Body
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Expected)
    try { & $Body }
    catch {
        if ($_.Exception.Message.IndexOf(
                $Expected, [StringComparison]::OrdinalIgnoreCase
            ) -lt 0) {
            throw "Expected '$Expected', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected failure containing '$Expected'."
}

function New-WinsysFixture {
    $root = Join-Path $script:TestRoot ([Guid]::NewGuid().ToString('N'))
    foreach ($directory in @('include', 'src')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $directory))
    }
    foreach ($relativePath in @(
        'winsys-interface-inputs.lock.json',
        'winsys-interface-inputs.schema.json',
        'include\gsw_svga_winsys.h',
        'src\gsw_svga_winsys.c'
    )) {
        [IO.File]::Copy(
            (Join-Path $script:ProductionModule $relativePath),
            (Join-Path $root $relativePath),
            $false
        )
    }
    return $root
}

function Set-FixtureSourceMutation {
    param([string]$Fixture, [string]$Before, [string]$After)
    $sourcePath = Join-Path $Fixture 'src\gsw_svga_winsys.c'
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $source = [IO.File]::ReadAllText($sourcePath, $utf8)
    if ($source.IndexOf($Before, [StringComparison]::Ordinal) -lt 0) {
        throw "Fixture mutation token '$Before' was not found."
    }
    $source = $source.Replace($Before, $After)
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
    $bytes = [IO.File]::ReadAllBytes($sourcePath)
    $lockPath = Join-Path $Fixture 'winsys-interface-inputs.lock.json'
    $lock = ConvertFrom-GswStrictJson `
        -Json ([IO.File]::ReadAllText($lockPath, $utf8)) -Source $lockPath
    $output = @($lock.outputs | Where-Object relative_path -ceq 'src/gsw_svga_winsys.c')
    if ($output.Count -ne 1) { throw 'Fixture source output binding is missing.' }
    $output[0].bytes = $bytes.Length
    $output[0].sha256 = Get-GswWinsysSha256 $bytes
    $json = ($lock | ConvertTo-Json -Depth 32) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($lockPath, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Invoke-Fixture {
    param([string]$Fixture)
    Invoke-GswWinsysShellVerification $Fixture $MesaCheckout $ToolchainRoot `
        (Join-Path $Fixture 'winsys-interface-inputs.lock.json') $false
}

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-gsw-winsys-tests-' + [Guid]::NewGuid().ToString('N')
)
[void][IO.Directory]::CreateDirectory($script:TestRoot)

try {
    Invoke-SelfTest 'Production shell validates and compiles without execution' {
        Invoke-GswWinsysShellVerification $script:ProductionModule $MesaCheckout `
            $ToolchainRoot (Join-Path $script:ProductionModule `
                'winsys-interface-inputs.lock.json') $true
    }

    Invoke-SelfTest 'Callback completeness is fail-closed' {
        $fixture = New-WinsysFixture
        Set-FixtureSourceMutation $fixture `
            'sws->host_log = gsw_host_log;' 'sws->host_log = NULL;'
        Assert-Throws { Invoke-Fixture $fixture } 'not populated exactly once'
    }

    Invoke-SelfTest 'Failed-create ownership is retained and released' {
        $fixture = New-WinsysFixture
        Set-FixtureSourceMutation $fixture `
            'sws->destroy(sws);' '(void)sws;'
        Assert-Throws { Invoke-Fixture $fixture } 'does not release retained winsys ownership'
    }

    Invoke-SelfTest 'Cleanup remains null-safe' {
        $fixture = New-WinsysFixture
        Set-FixtureSourceMutation $fixture `
            'if (sws != NULL)' 'if (sws == NULL)'
        Assert-Throws { Invoke-Fixture $fixture } 'is not null-safe'
    }

    Invoke-SelfTest 'Pre-WS8 hardware rejection is immutable' {
        $fixture = New-WinsysFixture
        Set-FixtureSourceMutation $fixture `
            'return SVGA3D_HWVERSION_WS65_B1;' `
            'return SVGA3D_HWVERSION_WS8_B1;'
        Assert-Throws { Invoke-Fixture $fixture } 'no longer rejects deterministically'
    }

    Invoke-SelfTest 'Resource and fence operations reject deterministically' {
        $fixture = New-WinsysFixture
        Set-FixtureSourceMutation $fixture `
            "gsw_get_fd(struct svga_winsys_screen *sws)`n{`n   (void)sws;`n   return -1;" `
            "gsw_get_fd(struct svga_winsys_screen *sws)`n{`n   (void)sws;`n   return 0;"
        Assert-Throws { Invoke-Fixture $fixture } 'no longer rejects deterministically'
    }

    Invoke-SelfTest 'Every capability field remains false' {
        $fixture = New-WinsysFixture
        Set-FixtureSourceMutation $fixture `
            'sws->have_vgpu10 = FALSE;' 'sws->have_vgpu10 = TRUE;'
        Assert-Throws { Invoke-Fixture $fixture } 'is not explicitly false'
    }

    Invoke-SelfTest 'ABI submission count cannot change' {
        $fixture = New-WinsysFixture
        Set-FixtureSourceMutation $fixture `
            'screen->context_leased = TRUE;' `
            "screen->context_leased = TRUE;`n   screen->abi_submission_count++;"
        Assert-Throws { Invoke-Fixture $fixture } 'ABI submission count is mutable'
    }

    Invoke-SelfTest 'Prohibited implementation boundary is immutable' {
        $fixture = New-WinsysFixture
        $path = Join-Path $fixture 'winsys-interface-inputs.lock.json'
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $lock = ConvertFrom-GswStrictJson `
            -Json ([IO.File]::ReadAllText($path, $utf8)) -Source $path
        $lock.prohibited_implementation_prefixes[0] = 'win9x/allowed/'
        [IO.File]::WriteAllText(
            $path,
            (($lock | ConvertTo-Json -Depth 32) -replace "`r`n", "`n") + "`n",
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Fixture $fixture } 'boundary changed'
    }
}
finally {
    $full = [IO.Path]::GetFullPath($script:TestRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]'\/'
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $full) -notlike 'retvrn99-gsw-winsys-tests-*') {
        throw "Refusing to remove unsafe test root '$full'."
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Tests) GSW winsys shell tests failed."
}
Write-Output "All $($script:Tests) GSW winsys shell tests passed."

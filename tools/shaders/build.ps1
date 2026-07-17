# SPDX-License-Identifier: GPL-3.0-only

param(
    [string]$Dxc = "dxc",
    [switch]$Verify
)

$ErrorActionPreference = "Stop"
$expectedVersion = "1.9.2602.24"

$compiler = Get-Command $Dxc -CommandType Application -ErrorAction SilentlyContinue
if (-not $compiler) {
    throw "The DXC shader compiler was not found: $Dxc"
}
$versionText = (& $compiler.Source --version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch [regex]::Escape($expectedVersion)) {
    throw "DXC $expectedVersion is required; '$($compiler.Source)' reported: $($versionText.Trim())"
}

$shaderRoot = Join-Path $PSScriptRoot "..\..\assets\shaders"
$jobs = @(
    @{
        Source = Join-Path $shaderRoot "retvrn99-crt.hlsl"
        Output = Join-Path $shaderRoot "retvrn99-crt.spv"
        Target = "ps_6_0"
        Entry = "main"
    },
    @{
        Source = Join-Path $shaderRoot "gsw3d-triangle.hlsl"
        Output = Join-Path $shaderRoot "gsw3d-triangle.vert.spv"
        Target = "vs_6_0"
        Entry = "vs_main"
    },
    @{
        Source = Join-Path $shaderRoot "gsw3d-triangle.hlsl"
        Output = Join-Path $shaderRoot "gsw3d-triangle.frag.spv"
        Target = "ps_6_0"
        Entry = "ps_main"
    }
)

foreach ($job in $jobs) {
    $output = $job.Output
    $temporary = $false
    if ($Verify) {
        if (-not (Test-Path -LiteralPath $job.Output -PathType Leaf)) {
            throw "Checked-in shader output is missing: $($job.Output)"
        }
        $output = [System.IO.Path]::GetTempFileName()
        $temporary = $true
    }
    try {
        & $compiler.Source -T $job.Target -E $job.Entry -O3 -spirv "-fspv-target-env=vulkan1.1" -fvk-use-dx-layout -Fo $output $job.Source
        if ($LASTEXITCODE -ne 0) {
            throw "DXC shader compilation failed for $($job.Source):$($job.Entry) with exit code $LASTEXITCODE."
        }
        if ($Verify) {
            $expectedHash = (Get-FileHash -LiteralPath $job.Output -Algorithm SHA256).Hash
            $actualHash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash) {
                throw "Shader output mismatch for $($job.Output): expected $expectedHash, rebuilt $actualHash"
            }
        }
    } finally {
        if ($temporary -and (Test-Path -LiteralPath $output)) {
            Remove-Item -LiteralPath $output -Force
        }
    }
}

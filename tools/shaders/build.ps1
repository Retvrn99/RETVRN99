# SPDX-License-Identifier: GPL-3.0-only

param(
    [string]$Dxc = "dxc"
)

$ErrorActionPreference = "Stop"

$source = Join-Path $PSScriptRoot "..\..\assets\shaders\retvrn99-crt.hlsl"
$spirv = Join-Path $PSScriptRoot "..\..\assets\shaders\retvrn99-crt.spv"
$compiler = Get-Command $Dxc -CommandType Application -ErrorAction SilentlyContinue
if (-not $compiler) {
    throw "The DXC shader compiler was not found: $Dxc"
}

& $compiler.Source -T ps_6_0 -E main -O3 -spirv "-fspv-target-env=vulkan1.1" -fvk-use-dx-layout -Fo $spirv $source
if ($LASTEXITCODE -ne 0) {
    throw "DXC shader compilation failed with exit code $LASTEXITCODE."
}

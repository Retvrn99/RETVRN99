# SPDX-License-Identifier: GPL-3.0-only

param(
    [string]$Dxc = "dxc"
)

$source = Join-Path $PSScriptRoot "..\..\assets\shaders\retvrn99-crt.hlsl"
$dxil = Join-Path $PSScriptRoot "..\..\assets\shaders\retvrn99-crt.dxil"
$spirv = Join-Path $PSScriptRoot "..\..\assets\shaders\retvrn99-crt.spv"

& $Dxc -T ps_6_0 -E main -O3 -Fo $dxil $source
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $Dxc -T ps_6_0 -E main -O3 -spirv "-fspv-target-env=vulkan1.1" -fvk-use-dx-layout -Fo $spirv $source
exit $LASTEXITCODE

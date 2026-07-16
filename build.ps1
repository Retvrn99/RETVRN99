# SPDX-License-Identifier: GPL-3.0-only

param(
    [switch]$Firmware,
    [string]$WslDistro = "Debian",
    [ValidateRange(1, 64)]
    [int]$ThreadCount = [Environment]::ProcessorCount
)

if ($Firmware) {
    & "$PSScriptRoot\tools\seabios\build.ps1" -WslDistro $WslDistro
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & "$PSScriptRoot\tools\vgabios\build.ps1" -WslDistro $WslDistro
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

odin build src\fat32_helper -out:retvrn99-fat32.exe -debug -thread-count:$ThreadCount
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
odin build src -out:retvrn99.exe -debug -thread-count:$ThreadCount
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

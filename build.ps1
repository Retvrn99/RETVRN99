# SPDX-License-Identifier: GPL-3.0-only

param(
    [switch]$Firmware,
    [string]$WslDistro = "Debian"
)

if ($Firmware) {
    & "$PSScriptRoot\tools\seabios\build.ps1" -WslDistro $WslDistro
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & "$PSScriptRoot\tools\vgabios\build.ps1" -WslDistro $WslDistro
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

odin build src -out:retvrn99.exe -debug

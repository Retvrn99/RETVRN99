# SPDX-License-Identifier: GPL-3.0-only

param(
    [string]$WslDistro = "Debian"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script = Join-Path $root "tools\vgabios\build.sh"
$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
)

if ($isWindowsHost) {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        throw "Rebuilding Bochs VGABIOS on Windows requires WSL with a Linux build toolchain."
    }
    if ($script -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "The Bochs VGABIOS WSL builder requires a workspace on a Windows drive."
    }
    $drive = $Matches[1].ToLowerInvariant()
    $relative = $Matches[2] -replace '\\', '/'
    $linuxScript = "/mnt/$drive/$relative"
    & $wsl.Source -d $WslDistro -- bash $linuxScript
} else {
    & bash $script
}

if ($LASTEXITCODE -ne 0) {
    throw "Bochs VGABIOS build failed with exit code $LASTEXITCODE."
}

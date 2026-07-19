# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DriverPath,
    [Parameter(Mandatory = $true)][string]$VxdPath,
    [Parameter(Mandatory = $true)][string]$WdumpPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-RegularFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is absent: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a reparse point: $Path"
    }
}

function Invoke-Wdump {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $text = (& $WdumpPath @Arguments 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Pinned wdump failed with exit code $LASTEXITCODE." }
    return $text
}

function Assert-Match {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Pattern)
    if ($Text -notmatch $Pattern) { throw "Executable structure is missing pattern '$Pattern'." }
}

function Test-BytePattern {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][byte[]]$Pattern
    )
    if ($Pattern.Length -eq 0 -or $Pattern.Length -gt $Bytes.Length) { return $false }
    for ($offset = 0; $offset -le $Bytes.Length - $Pattern.Length; $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $Pattern.Length; $index++) {
            if ($Bytes[$offset + $index] -ne $Pattern[$index]) {
                $matches = $false
                break
            }
        }
        if ($matches) { return $true }
    }
    return $false
}

function Assert-ExactExports {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Collections.Specialized.OrderedDictionary]$Expected
    )
    $text = Invoke-Wdump @('-q', '-x', $Path)
    Assert-Match $text '(?m)^LIBRARY GSWSOUND\s*$'
    $matches = @([regex]::Matches($text, '(?m)^\s+([A-Z0-9_]+)\s+@([0-9]+)\s*$'))
    if ($matches.Count -ne $Expected.Count) {
        throw "Executable has $($matches.Count) exports; expected $($Expected.Count)."
    }
    foreach ($match in $matches) {
        $name = $match.Groups[1].Value
        $ordinal = [int]$match.Groups[2].Value
        if (-not $Expected.Contains($name) -or [int]$Expected[$name] -ne $ordinal) {
            throw "Unexpected export '$name' at ordinal $ordinal."
        }
    }
}

Assert-RegularFile $WdumpPath 'Pinned Open Watcom wdump'
Assert-RegularFile $DriverPath 'GSWSOUND.DRV'
Assert-RegularFile $VxdPath 'GSWSOUND.VXD'

$driver = Invoke-Wdump @('-q', $DriverPath)
Assert-Match $driver '(?m)^\s*DOS EXE Header\s*$'
Assert-Match $driver '(?m)^\s*New EXE Header \(OS/2 or Windows\)\s*$'
Assert-Match $driver 'target OS \(1==OS/2, 2==Windows, 3==DOS4, 4==Win386\)\s*=\s*02H'
Assert-Match $driver 'expected Windows version \(Windows only\)\s*=\s*0400H'
Assert-Match $driver '(?m)^Module Flag Word = .*\bLIBRARY\b.*\bSINGLEDATA\b\s*$'
$driverExports = [ordered]@{WEP = 1; DRIVERPROC = 2; WODMESSAGE = 3; MXDMESSAGE = 4}
Assert-ExactExports $DriverPath $driverExports

$vxd = Invoke-Wdump @('-q', $VxdPath)
Assert-Match $vxd '(?m)^\s*DOS EXE Header\s*$'
Assert-Match $vxd '(?m)^\s*Linear EXE Header \(OS/2 V2\.x\) - LE\s*$'
Assert-Match $vxd 'os type \(1==OS/2, 2==Windows, 3==DOS4, 4==Win386\)\s*=\s*0004H'
Assert-Match $vxd '(?m)^Module Flags = PROGRAM \| PROTDLL\s*$'
Assert-Match $vxd '(?m)^\s*ordinal = 0001\s+flags = 03\s+offset = [0-9A-F]{8}\s+EXPORTED\s+SHARED DATA\s*$'
$vxdExports = [ordered]@{GSWSOUND_DDB = 1}
Assert-ExactExports $VxdPath $vxdExports
$vxdBytes = [IO.File]::ReadAllBytes($VxdPath)
# INT 20h, service 0000h, device 044Ah: MMDEVLDR_Register_Device_Driver.
if (-not (Test-BytePattern $vxdBytes ([byte[]](0xCD, 0x20, 0x00, 0x00, 0x4A, 0x04)))) {
    throw 'GSWSOUND.VXD does not call the MMDEVLDR device-driver registration service.'
}
# The obsolete direct ConfigMgr registration tail-call must not return.
if (Test-BytePattern $vxdBytes ([byte[]](0xCD, 0x20, 0x0E, 0x80, 0x33, 0x00))) {
    throw 'GSWSOUND.VXD still contains the direct ConfigMgr registration path.'
}

Write-Output 'Verified GSWSOUND.DRV as Windows 4.0 NE SINGLEDATA with ordinals 1-4.'
Write-Output 'Verified GSWSOUND.VXD as Win386 LE with shared-data GSWSOUND_DDB ordinal 1 and MMDEVLDR registration.'

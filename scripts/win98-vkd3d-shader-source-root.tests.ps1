# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vkd3d-shader-source-root.ps1')

$script:Passed = 0
$script:Failed = 0

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body, [bool]$ShouldPass)

    try {
        & $Body
        if (-not $ShouldPass) { throw 'Expected rejection.' }
        $script:Passed++
    }
    catch {
        if ($ShouldPass) {
            $script:Failed++
            Write-Host "FAIL: $Name - $($_.Exception.Message)"
        }
        else { $script:Passed++ }
    }
}

$utf8 = [Text.UTF8Encoding]::new($false)
$git = $utf8.GetBytes("first`nsecond`n")
$lf = ConvertTo-Vkd3dShaderCanonicalObservation $git $git lf 'a/source.c'
$crlf = ConvertTo-Vkd3dShaderCanonicalObservation `
    ($utf8.GetBytes("first`r`nsecond`r`n")) $git crlf 'a/source.c'

Invoke-Case 'exact canonical pair' {
    $pair = Resolve-Vkd3dShaderCanonicalPair $lf $crlf
    if (-not $pair.canonical_pair -or $pair.lf_count -ne 2 -or
        $pair.crlf_count -ne 2 -or $pair.bytes -ne $git.Length) {
        throw 'Canonical pair summary changed.'
    }
} $true

Invoke-Case 'LF checkout rejects CRLF' {
    ConvertTo-Vkd3dShaderCanonicalObservation `
        ($utf8.GetBytes("first`r`nsecond`r`n")) $git lf 'a/source.c'
} $false

Invoke-Case 'CRLF checkout rejects lone LF' {
    ConvertTo-Vkd3dShaderCanonicalObservation `
        ($utf8.GetBytes("first`r`nsecond`n")) $git crlf 'a/source.c'
} $false

Invoke-Case 'CRLF checkout rejects lone CR' {
    ConvertTo-Vkd3dShaderCanonicalObservation `
        ($utf8.GetBytes("first`rsecond`r`n")) $git crlf 'a/source.c'
} $false

Invoke-Case 'checkout content drift rejected' {
    ConvertTo-Vkd3dShaderCanonicalObservation `
        ($utf8.GetBytes("first`r`ndrift`r`n")) $git crlf 'a/source.c'
} $false

Invoke-Case 'Git CR rejected' {
    $bad = $utf8.GetBytes("first`r`n")
    ConvertTo-Vkd3dShaderCanonicalObservation $bad $bad lf 'a/source.c'
} $false

Invoke-Case 'Git BOM rejected' {
    [byte[]]$bad = 0xef, 0xbb, 0xbf, 0x61, 0x0a
    ConvertTo-Vkd3dShaderCanonicalObservation $bad $bad lf 'a/source.c'
} $false

Invoke-Case 'invalid relative path rejected' {
    ConvertTo-Vkd3dShaderCanonicalObservation $git $git lf '../source.c'
} $false

foreach ($badPath in @(
    'C:/private/source.c',
    'C:private/source.c',
    'a/./source.c',
    'a//source.c',
    'a\source.c',
    ('a/' + ('x' * 1024))
)) {
    Invoke-Case "unsafe relative path rejected: $badPath" {
        ConvertTo-Vkd3dShaderCanonicalObservation $git $git lf $badPath
    } $false
}

Invoke-Case 'pair path mismatch rejected' {
    $other = ConvertTo-Vkd3dShaderCanonicalObservation $git $git lf 'b/source.c'
    Resolve-Vkd3dShaderCanonicalPair $other $crlf
} $false

Write-Host "vkd3d-shader source-root tests: $script:Passed passed, $script:Failed failed"
if ($script:Failed -ne 0) { exit 1 }

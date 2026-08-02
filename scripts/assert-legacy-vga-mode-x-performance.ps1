# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'run-legacy-vga-evidence.ps1') -DefineFunctionsOnly

if ($SummaryPath.Count -ne 60) {
    throw 'Legacy VGA paired performance requires exactly 60 summary paths.'
}
$seen = @{}
$summaries = [Collections.Generic.List[object]]::new(60)
foreach ($path in $SummaryPath) {
    $full = [IO.Path]::GetFullPath($path)
    if ($seen.ContainsKey($full)) {
        throw "Legacy VGA paired performance summary path is duplicated: $full"
    }
    $seen.Add($full, $true)
    Assert-LegacyVgaEvidenceFile $full 'Legacy VGA performance summary'
    $summary = Get-Content -Raw -LiteralPath $full | ConvertFrom-Json
    [void]$summaries.Add($summary)
}

Assert-LegacyVgaEvidencePairedPerformance $summaries.ToArray()

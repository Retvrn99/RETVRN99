# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

function Get-MesaCanonicalSourceSha256 {
    param([byte[]]$Bytes)

    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function ConvertTo-MesaCanonicalSourceObservation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Int64]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][bool]$RequireLf,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name is not one ordinary file."
    }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($item.FullName)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Replace("`r`n", '').Contains("`r")) {
        throw "$Name contains an isolated carriage return."
    }
    $sawCrlf = $text.Contains("`r`n")
    if ($RequireLf -and $sawCrlf) {
        throw "$Name is not canonical LF."
    }
    $rawMatchesGitBlob = $bytes.Length -eq $ExpectedBytes -and
        (Get-MesaCanonicalSourceSha256 $bytes) -ceq $ExpectedSha256
    [byte[]]$canonical = [Text.UTF8Encoding]::new($false).GetBytes(
        $text.Replace("`r`n", "`n")
    )
    return [pscustomobject]@{
        Bytes = $canonical
        SawCrlf = $sawCrlf
        RawMatchesGitBlob = $rawMatchesGitBlob
    }
}

function Resolve-MesaCanonicalSourcePair {
    param(
        [Parameter(Mandatory = $true)][object]$LfObservation,
        [Parameter(Mandatory = $true)][object]$CrlfObservation,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $LfObservation.RawMatchesGitBlob -and
        -not $CrlfObservation.RawMatchesGitBlob) {
        throw "$Name has no observation matching the exact Git blob."
    }
    if ([Convert]::ToBase64String($LfObservation.Bytes) -cne
        [Convert]::ToBase64String($CrlfObservation.Bytes)) {
        throw "$Name canonical checkout bytes differ."
    }
    return [pscustomobject]@{
        Bytes = [byte[]]$LfObservation.Bytes
    }
}

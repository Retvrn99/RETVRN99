# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

function Get-Vkd3dShaderSourceSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function Test-Vkd3dShaderBytesEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$First,
        [Parameter(Mandatory = $true)][byte[]]$Second
    )

    if ($First.Length -ne $Second.Length) { return $false }
    for ($index = 0; $index -lt $First.Length; $index++) {
        if ($First[$index] -ne $Second[$index]) { return $false }
    }
    return $true
}

function ConvertTo-Vkd3dShaderCanonicalObservation {
    param(
        [Parameter(Mandatory = $true)][byte[]]$CheckoutBytes,
        [Parameter(Mandatory = $true)][byte[]]$GitBytes,
        [Parameter(Mandatory = $true)]
        [ValidateSet('lf', 'crlf')][string]$CheckoutMode,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $pathParts = $RelativePath.Split('/')
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or $RelativePath.StartsWith('/') -or
        [Text.Encoding]::UTF8.GetByteCount($RelativePath) -gt 1024 -or
        @($pathParts | Where-Object {
            [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..')
        }).Count -ne 0) {
        throw 'Canonical source observation has an invalid relative path.'
    }
    if ($GitBytes.Length -eq 0) {
        throw "Canonical Git blob '$RelativePath' is empty."
    }
    if ($GitBytes -contains [byte]0 -or $GitBytes -contains [byte]13) {
        throw "Canonical Git blob '$RelativePath' is not canonical LF text."
    }
    if ($GitBytes.Length -ge 3 -and $GitBytes[0] -eq 0xef -and
        $GitBytes[1] -eq 0xbb -and $GitBytes[2] -eq 0xbf) {
        throw "Canonical Git blob '$RelativePath' contains a UTF-8 BOM."
    }

    $lfCount = 0
    foreach ($value in $GitBytes) {
        if ($value -eq 10) { $lfCount++ }
    }

    [byte[]]$canonical = $CheckoutBytes
    $crlfCount = 0
    if ($CheckoutMode -ceq 'lf') {
        if ($CheckoutBytes -contains [byte]13 -or
            -not (Test-Vkd3dShaderBytesEqual $CheckoutBytes $GitBytes)) {
            throw "LF checkout bytes for '$RelativePath' differ from Git."
        }
    }
    else {
        $buffer = [Collections.Generic.List[byte]]::new($CheckoutBytes.Length)
        for ($index = 0; $index -lt $CheckoutBytes.Length; $index++) {
            $value = $CheckoutBytes[$index]
            if ($value -eq 13) {
                if ($index + 1 -ge $CheckoutBytes.Length -or
                    $CheckoutBytes[$index + 1] -ne 10) {
                    throw "CRLF checkout '$RelativePath' contains a lone CR."
                }
                $buffer.Add([byte]10)
                $crlfCount++
                $index++
            }
            elseif ($value -eq 10) {
                throw "CRLF checkout '$RelativePath' contains a lone LF."
            }
            else {
                $buffer.Add($value)
            }
        }
        $canonical = $buffer.ToArray()
        if ($lfCount -gt 0 -and $crlfCount -ne $lfCount) {
            throw "CRLF checkout '$RelativePath' did not convert every Git LF."
        }
        if (-not (Test-Vkd3dShaderBytesEqual $canonical $GitBytes)) {
            throw "CRLF checkout bytes for '$RelativePath' differ from Git after normalization."
        }
    }

    return [pscustomobject][ordered]@{
        RelativePath = $RelativePath
        CheckoutMode = $CheckoutMode
        CheckoutBytes = [UInt64]$CheckoutBytes.Length
        GitBytes = [UInt64]$GitBytes.Length
        GitLfCount = [UInt64]$lfCount
        CheckoutCrlfCount = [UInt64]$crlfCount
        CanonicalSha256 = Get-Vkd3dShaderSourceSha256 $canonical
        CanonicalBytes = $canonical
    }
}

function Resolve-Vkd3dShaderCanonicalPair {
    param(
        [Parameter(Mandatory = $true)][object]$LfObservation,
        [Parameter(Mandatory = $true)][object]$CrlfObservation
    )

    if ($LfObservation.CheckoutMode -cne 'lf' -or
        $CrlfObservation.CheckoutMode -cne 'crlf' -or
        $LfObservation.RelativePath -cne $CrlfObservation.RelativePath -or
        $LfObservation.GitBytes -ne $CrlfObservation.GitBytes -or
        $LfObservation.GitLfCount -ne $CrlfObservation.GitLfCount -or
        $LfObservation.CanonicalSha256 -cne
            $CrlfObservation.CanonicalSha256 -or
        -not (Test-Vkd3dShaderBytesEqual `
            $LfObservation.CanonicalBytes $CrlfObservation.CanonicalBytes)) {
        throw 'LF and CRLF source observations do not resolve to one Git blob.'
    }

    return [pscustomobject][ordered]@{
        relative_path = [string]$LfObservation.RelativePath
        bytes = [UInt64]$LfObservation.GitBytes
        lf_count = [UInt64]$LfObservation.GitLfCount
        crlf_count = [UInt64]$CrlfObservation.CheckoutCrlfCount
        sha256 = [string]$LfObservation.CanonicalSha256
        canonical_pair = $true
    }
}

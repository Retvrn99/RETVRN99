# SPDX-License-Identifier: GPL-3.0-only

. (Join-Path $PSScriptRoot 'strict-json.ps1')

function ConvertFrom-StrictTsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ExpectedHeader,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [ValidateRange(1, 100000)]
        [int]$MaximumRows = 4096,

        [ValidateRange(64, 1048576)]
        [int]$MaximumLineBytes = 65536,

        [ValidateRange(2, 100000)]
        [int]$MaximumPhysicalLines = 8192
    )

    if ($ExpectedHeader.Count -gt 64) {
        throw "$Name declares too many required columns."
    }
    $expectedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($column in $ExpectedHeader) {
        if ($column -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or
            -not $expectedNames.Add($column)) {
            throw "$Name declares an invalid or duplicate required column '$column'."
        }
    }

    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $tableLines = [Collections.Generic.List[string]]::new()
    $physicalLine = 0
    foreach ($lineValue in $Lines) {
        $physicalLine++
        if ($physicalLine -gt $MaximumPhysicalLines) {
            throw "$Name exceeds the $MaximumPhysicalLines-physical-line limit."
        }
        $line = [string]$lineValue
        try {
            $lineBytes = $encoding.GetByteCount($line)
        }
        catch {
            throw "$Name line $physicalLine is not valid Unicode text."
        }
        if ($lineBytes -gt $MaximumLineBytes) {
            throw "$Name line $physicalLine exceeds the $MaximumLineBytes-byte limit."
        }
        if ($line -match '[\u0000-\u0008\u000a-\u001f\u007f-\u009f]') {
            throw "$Name line $physicalLine contains a control character."
        }
        if ($line.Trim().Length -eq 0 -or $line.TrimStart().StartsWith('#')) {
            continue
        }
        if ($line.IndexOf([char]0x22) -ge 0) {
            throw "$Name line $physicalLine contains unsupported quoting."
        }
        [void]$tableLines.Add($line)
    }

    if ($tableLines.Count -lt 2) {
        throw "$Name must contain one exact header and at least one data row."
    }
    $rowCount = $tableLines.Count - 1
    if ($rowCount -gt $MaximumRows) {
        throw "$Name exceeds the $MaximumRows-row limit."
    }

    [string[]]$actualHeader = $tableLines[0].Split([char]"`t")
    $actualNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($column in $actualHeader) {
        if (-not $actualNames.Add($column)) {
            throw "$Name contains a duplicate header column '$column'."
        }
    }
    if ($actualHeader.Count -ne $ExpectedHeader.Count) {
        throw "$Name header must contain exactly $($ExpectedHeader.Count) ordered columns."
    }
    for ($index = 0; $index -lt $ExpectedHeader.Count; $index++) {
        if ($actualHeader[$index] -cne $ExpectedHeader[$index]) {
            throw "$Name header column $($index + 1) must be '$($ExpectedHeader[$index])'."
        }
    }

    $records = [Collections.Generic.List[object]]::new()
    for ($rowIndex = 1; $rowIndex -lt $tableLines.Count; $rowIndex++) {
        [string[]]$fields = $tableLines[$rowIndex].Split([char]"`t")
        if ($fields.Count -ne $ExpectedHeader.Count) {
            throw "$Name data row $rowIndex has $($fields.Count) fields; exactly $($ExpectedHeader.Count) are required."
        }
        $record = [ordered]@{}
        for ($columnIndex = 0; $columnIndex -lt $ExpectedHeader.Count; $columnIndex++) {
            $record[$ExpectedHeader[$columnIndex]] = $fields[$columnIndex]
        }
        [void]$records.Add([pscustomobject]$record)
    }
    return @($records)
}

function ConvertFrom-StrictTsvUtf8Bytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ExpectedHeader,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [ValidateRange(1, 67108864)]
        [int]$MaximumBytes = 1048576,

        [ValidateRange(1, 100000)]
        [int]$MaximumRows = 4096,

        [ValidateRange(64, 1048576)]
        [int]$MaximumLineBytes = 65536,

        [ValidateRange(2, 100000)]
        [int]$MaximumPhysicalLines = 8192
    )

    if ($Bytes.Length -gt $MaximumBytes) {
        throw "$Name exceeds the $MaximumBytes-byte limit."
    }
    try {
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $text = $encoding.GetString($Bytes)
    }
    catch {
        throw "$Name is not valid UTF-8."
    }
    # Preserve compatibility with one leading BOM in historical lock files.
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) {
        $text = $text.Substring(1)
    }
    if ($text.IndexOf([char]0xfeff) -ge 0) {
        throw "$Name contains an unsupported UTF-8 byte-order mark."
    }
    if ($text -match "`r(?!`n)") {
        throw "$Name contains a bare carriage return; only LF and CRLF line endings are supported."
    }

    [string[]]$lines = [regex]::Split($text, "`r`n|`n")
    return @(ConvertFrom-StrictTsv -Lines $lines -ExpectedHeader $ExpectedHeader `
        -Name $Name -MaximumRows $MaximumRows -MaximumLineBytes $MaximumLineBytes `
        -MaximumPhysicalLines $MaximumPhysicalLines)
}

function Read-StrictTsvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ExpectedHeader,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [ValidateRange(1, 67108864)]
        [int]$MaximumBytes = 1048576,

        [ValidateRange(1, 100000)]
        [int]$MaximumRows = 4096,

        [ValidateRange(64, 1048576)]
        [int]$MaximumLineBytes = 65536,

        [ValidateRange(2, 100000)]
        [int]$MaximumPhysicalLines = 8192,

        [scriptblock]$BeforePostReadCheck
    )

    try {
        $snapshot = Read-GswBoundedFileSnapshot -Path $Path -Name $Name `
            -MaximumBytes ([UInt64]$MaximumBytes) -AllowEmpty `
            -BeforePostReadCheck $BeforePostReadCheck
    }
    catch {
        $message = $_.Exception.Message
        if ($message -ceq "$Name exceeds the $MaximumBytes-byte bound.") {
            throw "$Name exceeds the $MaximumBytes-byte limit."
        }
        throw
    }

    return @(ConvertFrom-StrictTsvUtf8Bytes -Bytes $snapshot.Bytes `
        -ExpectedHeader $ExpectedHeader -Name $Name -MaximumBytes $MaximumBytes `
        -MaximumRows $MaximumRows -MaximumLineBytes $MaximumLineBytes `
        -MaximumPhysicalLines $MaximumPhysicalLines)
}

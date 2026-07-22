# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

$script:MesaObjectMachineI386 = [UInt16]0x014c
$script:MesaObjectHeaderBytes = 20
$script:MesaObjectSectionHeaderBytes = 40
$script:MesaObjectSymbolBytes = 18
$script:MesaObjectMaximumBytes = 67108864

function Get-MesaObjectSha256 {
    param([byte[]]$Bytes)

    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function ConvertTo-MesaObjectProcessArgument {
    param([string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
        }
        else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-MesaObjectProcessTree {
    param([Diagnostics.Process]$Process)

    if ($Process.HasExited) { return }
    $taskkill = Join-Path ([Environment]::GetFolderPath('Windows')) `
        'System32\taskkill.exe'
    & $taskkill /PID $Process.Id /T /F 2>&1 | Out-Null
    $taskkillExit = $LASTEXITCODE
    [void]$Process.WaitForExit(5000)
    if ($taskkillExit -ne 0 -and -not $Process.HasExited) {
        try { $Process.Kill($true) } catch { }
        [void]$Process.WaitForExit(5000)
    }
    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch { }
        [void]$Process.WaitForExit(5000)
    }
    if (-not $Process.HasExited) {
        throw "Compiler process $($Process.Id) survived owned-tree cleanup."
    }
}

function Invoke-MesaObjectCompiler {
    param(
        [Parameter(Mandatory = $true)][string]$Compiler,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ToolBin,
        [Parameter(Mandatory = $true)][string]$PrivateTemp,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 30
    )

    if ($TimeoutSeconds -ne 30) {
        throw 'Mesa object compiler timeout must remain exactly 30 seconds.'
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Compiler
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Arguments = (($Arguments | ForEach-Object {
        ConvertTo-MesaObjectProcessArgument ([string]$_)
    }) -join ' ')
    foreach ($ambient in @(
        'GCC_EXEC_PREFIX', 'COMPILER_PATH', 'LIBRARY_PATH', 'CPATH',
        'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
        'DEPENDENCIES_OUTPUT', 'SUNPRO_DEPENDENCIES', 'GCC_COMPARE_DEBUG',
        'GCC_COMPARE_DEBUG_EXEC'
    )) { [void]$info.EnvironmentVariables.Remove($ambient) }
    $info.EnvironmentVariables['PATH'] = $ToolBin + ';' +
        [Environment]::GetFolderPath('System')
    $info.EnvironmentVariables['TEMP'] = $PrivateTemp
    $info.EnvironmentVariables['TMP'] = $PrivateTemp
    $info.EnvironmentVariables['LC_ALL'] = 'C'
    $info.EnvironmentVariables['LANG'] = 'C'
    $info.EnvironmentVariables['TZ'] = 'UTC'
    $info.EnvironmentVariables['SOURCE_DATE_EPOCH'] = '0'

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = [bool]$process.Start()
        if (-not $started) { throw "$Name did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-MesaObjectProcessTree $process
            throw "$Name exceeded its $TimeoutSeconds-second bound."
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($stdout.Length -gt 1048576 -or $stderr.Length -gt 1048576) {
            throw "$Name exceeded its output bound."
        }
        if ($process.ExitCode -ne 0) {
            $detail = ($stderr + "`n" + $stdout).Trim()
            if ($detail.Length -gt 4096) { $detail = $detail.Substring(0, 4096) }
            throw "$Name failed with exit code $($process.ExitCode): $detail"
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            Stop-MesaObjectProcessTree $process
        }
        $process.Dispose()
    }
}

function Assert-MesaObjectRange {
    param(
        [UInt64]$Offset,
        [UInt64]$Length,
        [UInt64]$FileLength,
        [string]$Name
    )

    if ($Offset -gt $FileLength -or $Length -gt $FileLength -or
        $Offset -gt $FileLength - $Length) {
        throw "COFF $Name exceeds the object bounds."
    }
}

function Test-MesaObjectPrivatePath {
    param([byte[]]$Bytes, [string[]]$PrivateRoots)

    $views = [Collections.Generic.List[string]]::new()
    foreach ($view in @(
        [Text.Encoding]::ASCII.GetString($Bytes),
        [Text.UTF8Encoding]::new($false, $false).GetString($Bytes),
        [Text.Encoding]::Unicode.GetString($Bytes)
    )) {
        $views.Add($view)
    }
    if ($Bytes.Length -gt 1) {
        $views.Add([Text.Encoding]::Unicode.GetString(
            $Bytes, 1, $Bytes.Length - 1
        ))
    }
    foreach ($root in $PrivateRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $full = [IO.Path]::GetFullPath($root).TrimEnd([char[]]'\/')
        $spelling = $full.Replace('\', '/')
        foreach ($view in $views) {
            $normalizedView = $view.Replace('\', '/')
            if ($normalizedView.IndexOf(
                    $spelling, [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                return $spelling
            }
        }
    }
    return $null
}

function Get-MesaNormalizedCoffObject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$PrivateRoots
    )

    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt $script:MesaObjectHeaderBytes -or
        $bytes.Length -gt $script:MesaObjectMaximumBytes) {
        throw 'Compiler output is not a bounded COFF object.'
    }
    if ([BitConverter]::ToUInt16($bytes, 0) -ne
        $script:MesaObjectMachineI386) {
        throw 'Compiler output is not IMAGE_FILE_MACHINE_I386 COFF.'
    }
    $sectionCount = [BitConverter]::ToUInt16($bytes, 2)
    if ($sectionCount -lt 1) {
        throw 'Compiler output has an invalid COFF section count.'
    }
    $optionalBytes = [BitConverter]::ToUInt16($bytes, 16)
    if ($optionalBytes -ne 0) {
        throw 'Compiler output contains an unexpected optional header.'
    }
    [UInt64]$sectionTableBytes = [UInt64]$sectionCount *
        [UInt64]$script:MesaObjectSectionHeaderBytes
    Assert-MesaObjectRange ([UInt64]$script:MesaObjectHeaderBytes) `
        $sectionTableBytes ([UInt64]$bytes.Length) 'section table'
    for ($section = 0; $section -lt $sectionCount; $section++) {
        $offset = $script:MesaObjectHeaderBytes +
            $section * $script:MesaObjectSectionHeaderBytes
        [UInt64]$rawBytes = [BitConverter]::ToUInt32($bytes, $offset + 16)
        [UInt64]$rawOffset = [BitConverter]::ToUInt32($bytes, $offset + 20)
        [UInt64]$relocationOffset = [BitConverter]::ToUInt32($bytes, $offset + 24)
        [UInt64]$lineOffset = [BitConverter]::ToUInt32($bytes, $offset + 28)
        [UInt64]$relocationCount = [BitConverter]::ToUInt16($bytes, $offset + 32)
        [UInt64]$lineCount = [BitConverter]::ToUInt16($bytes, $offset + 34)
        [UInt64]$characteristics = [BitConverter]::ToUInt32($bytes, $offset + 36)
        if ($rawBytes -ne 0) {
            if ($rawOffset -eq 0) {
                if (($characteristics -band [UInt64]0x00000080) -eq 0) {
                    throw "COFF section $section has no raw-data offset."
                }
            }
            else {
                Assert-MesaObjectRange $rawOffset $rawBytes `
                    ([UInt64]$bytes.Length) "section $section raw data"
            }
        }
        if ($relocationCount -ne 0) {
            Assert-MesaObjectRange $relocationOffset `
                ($relocationCount * 10) ([UInt64]$bytes.Length) `
                "section $section relocations"
        }
        if ($lineCount -ne 0) {
            Assert-MesaObjectRange $lineOffset ($lineCount * 6) `
                ([UInt64]$bytes.Length) "section $section line records"
        }
    }
    [UInt64]$symbolOffset = [BitConverter]::ToUInt32($bytes, 8)
    [UInt64]$symbolCount = [BitConverter]::ToUInt32($bytes, 12)
    if (($symbolOffset -eq 0) -ne ($symbolCount -eq 0)) {
        throw 'Compiler output has an inconsistent COFF symbol table.'
    }
    if ($symbolCount -ne 0) {
        [UInt64]$symbolBytes = $symbolCount *
            [UInt64]$script:MesaObjectSymbolBytes
        Assert-MesaObjectRange $symbolOffset $symbolBytes `
            ([UInt64]$bytes.Length) 'symbol table'
        [UInt64]$stringOffset = $symbolOffset + $symbolBytes
        Assert-MesaObjectRange $stringOffset 4 ([UInt64]$bytes.Length) `
            'string-table length'
        [UInt64]$stringBytes = [BitConverter]::ToUInt32(
            $bytes, [int]$stringOffset
        )
        if ($stringBytes -lt 4) {
            throw 'Compiler output has an invalid COFF string table.'
        }
        Assert-MesaObjectRange $stringOffset $stringBytes `
            ([UInt64]$bytes.Length) 'string table'
    }
    $leak = Test-MesaObjectPrivatePath $bytes $PrivateRoots
    if ($null -ne $leak) {
        throw "Compiler output exposes private absolute path '$leak'."
    }

    $timestamp = [BitConverter]::ToUInt32($bytes, 4)
    $rawHash = Get-MesaObjectSha256 $bytes
    [byte[]]$normalized = [byte[]]$bytes.Clone()
    for ($index = 4; $index -le 7; $index++) { $normalized[$index] = 0 }
    return [pscustomobject]@{
        Bytes = [UInt64]$normalized.Length
        Timestamp = [UInt64]$timestamp
        RawSha256 = $rawHash
        NormalizedSha256 = Get-MesaObjectSha256 $normalized
        NormalizedBytes = $normalized
    }
}

function Get-MesaObjectAggregateSha256 {
    param([Parameter(Mandatory = $true)][object[]]$Objects)

    $builder = [Text.StringBuilder]::new()
    $previous = 0
    $identities = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($object in $Objects) {
        $ordinal = [int]$object.unit_ordinal
        $identity = [string]$object.object
        if ($ordinal -ne $previous + 1) {
            throw 'Object evidence is not in exact unit order.'
        }
        if (-not $identities.Add($identity)) {
            throw "Duplicate object identity '$identity'."
        }
        if ($identity -notmatch '^obj/.+\.o$' -or
            [string]$object.normalized_sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Invalid object evidence for unit $ordinal."
        }
        [void]$builder.Append($ordinal.ToString('D4'))
        [void]$builder.Append("`t")
        [void]$builder.Append($identity)
        [void]$builder.Append("`t")
        [void]$builder.Append(([UInt64]$object.bytes).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ))
        [void]$builder.Append("`t")
        [void]$builder.Append([string]$object.normalized_sha256)
        [void]$builder.Append("`n")
        $previous = $ordinal
    }
    return Get-MesaObjectSha256 (
        [Text.UTF8Encoding]::new($false).GetBytes($builder.ToString())
    )
}

function Assert-MesaObjectTwin {
    param(
        [Parameter(Mandatory = $true)][object]$First,
        [Parameter(Mandatory = $true)][object]$Second,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([UInt64]$First.Bytes -ne [UInt64]$Second.Bytes -or
        [string]$First.NormalizedSha256 -cne
            [string]$Second.NormalizedSha256 -or
        [Convert]::ToBase64String([byte[]]$First.NormalizedBytes) -cne
            [Convert]::ToBase64String([byte[]]$Second.NormalizedBytes)) {
        throw "$Name normalized COFF outputs differ between twin runs."
    }
}

function Remove-MesaObjectTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProofRoot
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $root = [IO.Path]::GetFullPath($ProofRoot).TrimEnd([char[]]'\/')
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove object tree outside proof root '$full'."
    }
    if ([IO.Directory]::Exists($full)) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to remove reparse object tree '$full'."
        }
        [IO.Directory]::Delete($full, $true)
    }
}

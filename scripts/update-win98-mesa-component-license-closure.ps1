# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MesaCheckout,

    [string]$ManifestPath,

    [string]$CompilerClosurePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'mesa-compiler-dependency-roles.ps1')

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repoRoot `
        'drivers\win98\component-closures\mesa9x-23.1.x.json'
}
if ([string]::IsNullOrWhiteSpace($CompilerClosurePath)) {
    $CompilerClosurePath = Join-Path $repoRoot `
        'drivers\win98\mesa-compiler-closure.json'
}
$MesaCheckout = [IO.Path]::GetFullPath($MesaCheckout)
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$CompilerClosurePath = [IO.Path]::GetFullPath($CompilerClosurePath)

function Invoke-GitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $priorGlobalConfig = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL')
    try {
        $env:GIT_CONFIG_GLOBAL = 'NUL'
        $output = @(& git -c "safe.directory=$MesaCheckout" `
            -C $MesaCheckout @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Arguments -join ' ') failed: $($output -join ' ')"
        }
        return @($output)
    }
    finally {
        if ($null -eq $priorGlobalConfig) {
            Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
        }
        else {
            $env:GIT_CONFIG_GLOBAL = $priorGlobalConfig
        }
    }
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return (([BitConverter]::ToString($sha256.ComputeHash($Bytes))) `
            -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-OrdinalSortedRows {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    [object[]]$copy = @($Rows)
    $comparer = [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.relative_path,
                [string]$right.relative_path
            )
        }
    )
    [Array]::Sort($copy, $comparer)
    return @($copy)
}

function Read-AsciiLine {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)

    $bytes = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) {
            throw 'Unexpected end of git cat-file output.'
        }
        if ($value -eq 0x0a) {
            break
        }
        if ($value -ne 0x0d) {
            [void]$bytes.Add([byte]$value)
        }
    }
    return [Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Start-GitBlobReader {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'git'
    [void]$info.ArgumentList.Add('-c')
    [void]$info.ArgumentList.Add("safe.directory=$MesaCheckout")
    [void]$info.ArgumentList.Add('-C')
    [void]$info.ArgumentList.Add($MesaCheckout)
    [void]$info.ArgumentList.Add('cat-file')
    [void]$info.ArgumentList.Add('--batch')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['GIT_CONFIG_GLOBAL'] = 'NUL'

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) {
        throw 'Failed to start git cat-file.'
    }
    $process.StandardInput.AutoFlush = $true
    return $process
}

function Read-GitBlob {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Reader,
        [Parameter(Mandatory = $true)][string]$ObjectId
    )

    $Reader.StandardInput.WriteLine($ObjectId)
    $header = Read-AsciiLine $Reader.StandardOutput.BaseStream
    if ($header -cnotmatch "^$ObjectId blob (?<bytes>[0-9]+)$") {
        throw "Unexpected git cat-file header '$header'."
    }
    [UInt64]$size = [UInt64]$Matches.bytes
    if ($size -gt [int]::MaxValue) {
        throw "Git blob '$ObjectId' exceeds the reader size bound."
    }
    $content = New-Object byte[] ([int]$size)
    $offset = 0
    while ($offset -lt $content.Length) {
        $read = $Reader.StandardOutput.BaseStream.Read(
            $content,
            $offset,
            $content.Length - $offset
        )
        if ($read -le 0) {
            throw "Unexpected end of git blob '$ObjectId'."
        }
        $offset += $read
    }
    if ($Reader.StandardOutput.BaseStream.ReadByte() -ne 0x0a) {
        throw "Git blob '$ObjectId' has an invalid batch terminator."
    }
    return ,$content
}

function Get-BlockRange {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Marker
    )

    $markerOffset = $Text.IndexOf($Marker, [StringComparison]::Ordinal)
    if ($markerOffset -lt 0) {
        throw "Missing curated license marker '$Marker'."
    }
    $blockStart = $Text.LastIndexOf('/*', $markerOffset, [StringComparison]::Ordinal)
    $previousEnd = $Text.LastIndexOf('*/', $markerOffset, [StringComparison]::Ordinal)
    if ($blockStart -ge 0 -and $blockStart -gt $previousEnd) {
        $blockEnd = $Text.IndexOf('*/', $markerOffset, [StringComparison]::Ordinal)
        if ($blockEnd -lt 0) {
            throw "Unterminated license comment for marker '$Marker'."
        }
        return [pscustomobject]@{
            Offset = $blockStart
            Count = $blockEnd + 2 - $blockStart
        }
    }

    $lineStart = $Text.LastIndexOf("`n", $markerOffset)
    if ($lineStart -lt 0) {
        $lineStart = 0
    }
    else {
        $lineStart++
    }
    $lineEnd = $Text.IndexOf("`n", $markerOffset)
    if ($lineEnd -lt 0) {
        $lineEnd = $Text.Length
    }
    return [pscustomobject]@{
        Offset = $lineStart
        Count = $lineEnd - $lineStart
    }
}

function Get-BisonRange {
    param([Parameter(Mandatory = $true)][string]$Text)

    $license = Get-BlockRange $Text 'This program is free software:'
    $exception = Get-BlockRange $Text 'This special exception was added'
    return [pscustomobject]@{
        Offset = $license.Offset
        Count = $exception.Offset + $exception.Count - $license.Offset
    }
}

function Get-SourcePrefixId {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if (-not $RelativePath.Contains('/')) {
        return 'root-files'
    }
    foreach ($mapping in @(
        @('mesa-23.1.x/', 'mesa-23-1-x'),
        @('win9x/eight/', 'win9x-eight'),
        @('win9x/nine/', 'win9x-nine'),
        @('win9x/', 'win9x-support')
    )) {
        if ($RelativePath.StartsWith($mapping[0], [StringComparison]::Ordinal)) {
            return $mapping[1]
        }
    }
    throw "Compiler dependency '$RelativePath' has no curated source prefix."
}

function Get-LicenseClassification {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    if ($RelativePath.StartsWith('win9x/eight/', [StringComparison]::Ordinal)) {
        return [pscustomobject]@{
            Declared = 'BSD-2-Clause'
            Selected = 'BSD-2-Clause'
            DocumentId = 'd3d8to9-bsd2'
            Range = $null
        }
    }
    if ($RelativePath -cin @(
        'mesa9x.h',
        'win9x/nine/mesa99.h',
        'win9x/nine/nine_present.h',
        'win9x/wgl/pipe_access.h'
    )) {
        return [pscustomobject]@{
            Declared = 'MIT'
            Selected = 'MIT'
            DocumentId = 'project-root-mit'
            Range = $null
        }
    }

    $special = switch -CaseSensitive ($RelativePath) {
        'mesa-23.1.x/include/GLES3/gl3ext.h' {
            @('SGI-B-2.0', 'SGI-B-2.0', 'SGI Free Software B License', $false)
            break
        }
        'mesa-23.1.x/src/mesa/x86/assyntax.h' {
            @('LicenseRef-Mesa-Vrije-Permissive',
                'LicenseRef-Mesa-Vrije-Permissive',
                'Copyright 1992 Vrije Universiteit', $false)
            break
        }
        'mesa-23.1.x/src/util/u_atomic.h' {
            @('LicenseRef-Mesa-U-Atomic-Public-Domain',
                'LicenseRef-Mesa-U-Atomic-Public-Domain',
                'No copyright claimed on this file.', $false)
            break
        }
        'mesa-23.1.x/src/gallium/auxiliary/util/dbghelp.h' {
            @('LicenseRef-Mesa-DbgHelp-Public-Domain',
                'LicenseRef-Mesa-DbgHelp-Public-Domain',
                'placed in the Public Domain', $false)
            break
        }
        'mesa-23.1.x/src/util/sha1/sha1.h' {
            @('LicenseRef-Mesa-SHA1-Public-Domain',
                'LicenseRef-Mesa-SHA1-Public-Domain',
                '100% Public Domain', $false)
            break
        }
        'mesa-23.1.x/src/c11/threads.h' {
            @('BSL-1.0', 'BSL-1.0', 'Boost Software License', $false)
            break
        }
        'mesa-23.1.x/src/util/softfloat.h' {
            @('BSD-3-Clause', 'BSD-3-Clause',
                'Redistribution and use in source and binary forms', $false)
            break
        }
        'mesa-23.1.x/src/util/xxhash.h' {
            @('BSD-2-Clause', 'BSD-2-Clause',
                'Redistribution and use in source and binary forms', $false)
            break
        }
        'mesa-23.1.x/src/compiler/glsl/glcpp/glcpp-parse.h' {
            @('GPL-3.0-or-later WITH Bison-exception-2.2',
                'GPL-3.0-or-later WITH Bison-exception-2.2', '', $true)
            break
        }
        'mesa-23.1.x/src/compiler/glsl/glsl_parser.h' {
            @('GPL-3.0-or-later WITH Bison-exception-2.2',
                'GPL-3.0-or-later WITH Bison-exception-2.2', '', $true)
            break
        }
        'mesa-23.1.x/src/mesa/program/program_parse.tab.h' {
            @('GPL-3.0-or-later WITH Bison-exception-2.2',
                'GPL-3.0-or-later WITH Bison-exception-2.2', '', $true)
            break
        }
        default { $null }
    }
    if ($null -ne $special) {
        $range = if ($special[3]) {
            Get-BisonRange $Text
        }
        else {
            Get-BlockRange $Text $special[2]
        }
        return [pscustomobject]@{
            Declared = $special[0]
            Selected = $special[1]
            DocumentId = ''
            Range = $range
        }
    }

    $spdx = [regex]::Matches(
        $Text,
        'SPDX-License-Identifier:\s*([^\r\n*]+)',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if ($spdx.Count -gt 0) {
        if ($spdx.Count -ne 1) {
            throw "Compiler dependency '$RelativePath' has multiple SPDX declarations."
        }
        $expression = $spdx[0].Groups[1].Value.Trim()
        $expression = $expression -creplace 'GPL-2\.0(?![-+])', 'GPL-2.0-only'
        $expression = $expression -creplace 'GPL-3\.0(?![-+])', 'GPL-3.0-only'
        if ($expression -cnotin @(
            'MIT',
            'Apache-2.0',
            'GPL-2.0-only OR MIT',
            'GPL-3.0-only OR MIT'
        )) {
            throw "Compiler dependency '$RelativePath' has uncurated SPDX expression '$expression'."
        }
        $selected = if ($expression.EndsWith(' OR MIT', [StringComparison]::Ordinal)) {
            'MIT'
        }
        else {
            $expression
        }
        return [pscustomobject]@{
            Declared = $expression
            Selected = $selected
            DocumentId = ''
            Range = Get-BlockRange $Text 'SPDX-License-Identifier:'
        }
    }

    if ($Text.Contains('Licensed under the Apache License, Version 2.0',
            [StringComparison]::Ordinal)) {
        return [pscustomobject]@{
            Declared = 'Apache-2.0'
            Selected = 'Apache-2.0'
            DocumentId = ''
            Range = Get-BlockRange $Text `
                'Licensed under the Apache License, Version 2.0'
        }
    }
    if ($Text.Contains('Permission is hereby granted', [StringComparison]::Ordinal)) {
        return [pscustomobject]@{
            Declared = 'MIT'
            Selected = 'MIT'
            DocumentId = ''
            Range = Get-BlockRange $Text 'Permission is hereby granted'
        }
    }

    if ($script:DefaultMesaLicensePaths.Contains($RelativePath)) {
        [void]$script:UsedDefaultMesaLicensePaths.Add($RelativePath)
        return [pscustomobject]@{
            Declared = 'MIT'
            Selected = 'MIT'
            DocumentId = 'mesa-default-mit'
            Range = $null
        }
    }
    throw "Compiler dependency '$RelativePath' has no curated license evidence."
}

function New-InlineEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$GitBlob,
        [Parameter(Mandatory = $true)][byte[]]$Content,
        [Parameter(Mandatory = $true)][string]$SourcePrefixId,
        [Parameter(Mandatory = $true)][object]$Classification
    )

    $range = New-Object byte[] $Classification.Range.Count
    [Array]::Copy(
        $Content,
        $Classification.Range.Offset,
        $range,
        0,
        $range.Length
    )
    return [ordered]@{
        id = $Id
        kind = 'inline'
        relative_path = $RelativePath
        git_blob = $GitBlob
        bytes = $Content.Length
        sha256 = Get-Sha256 $Content
        source_prefix_id = $SourcePrefixId
        locator = [ordered]@{
            kind = 'byte-range'
            byte_offset = $Classification.Range.Offset
            byte_count = $Classification.Range.Count
            sha256 = Get-Sha256 $range
        }
        observed_license_expression = $Classification.Declared
    }
}

function Write-CompactManifest {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $builder = [Text.StringBuilder]::new()
    [void]$builder.AppendLine('{')
    foreach ($name in @(
        '_spdx', 'schema', 'status', 'reason', 'upstream_name', 'owning_commit'
    )) {
        $json = $Manifest.$name | ConvertTo-Json -Compress
        [void]$builder.AppendLine("  `"$name`": $json,")
    }
    foreach ($section in @('source_prefixes', 'license_evidence', 'files')) {
        [void]$builder.AppendLine("  `"$section`": [")
        $rows = @($Manifest.$section)
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $suffix = if ($index + 1 -lt $rows.Count) { ',' } else { '' }
            $json = $rows[$index] | ConvertTo-Json -Depth 16 -Compress
            [void]$builder.AppendLine("    $json$suffix")
        }
        $suffix = if ($section -cne 'files') { ',' } else { '' }
        [void]$builder.AppendLine("  ]$suffix")
    }
    [void]$builder.AppendLine('}')
    [IO.File]::WriteAllText(
        $Path,
        $builder.ToString().Replace("`r`n", "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

$script:DefaultMesaLicensePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($path in @(
    'mesa-23.1.x/src/compiler/glsl/builtin_int64.h',
    'mesa-23.1.x/src/compiler/nir/nir_inline_helpers.h',
    'mesa-23.1.x/src/compiler/nir_builder_opcodes.h',
    'mesa-23.1.x/src/gallium/auxiliary/draw/draw_gs_tmp.h',
    'mesa-23.1.x/src/gallium/auxiliary/draw/draw_prim_assembler_tmp.h',
    'mesa-23.1.x/src/gallium/auxiliary/draw/draw_pt_decompose.h',
    'mesa-23.1.x/src/gallium/auxiliary/draw/draw_so_emit_tmp.h',
    'mesa-23.1.x/src/gallium/auxiliary/driver_trace/tr_util.h',
    'mesa-23.1.x/src/gallium/auxiliary/target-helpers/inline_debug_helper.h',
    'mesa-23.1.x/src/gallium/auxiliary/target-helpers/inline_sw_helper.h',
    'mesa-23.1.x/src/gallium/auxiliary/tgsi/tgsi_info_opcodes.h',
    'mesa-23.1.x/src/gallium/auxiliary/util/u_box.h',
    'mesa-23.1.x/src/gallium/auxiliary/util/u_threaded_context_calls.h',
    'mesa-23.1.x/src/gallium/auxiliary/util/u_transfer.h',
    'mesa-23.1.x/src/gallium/drivers/svga/include/includeCheck.h',
    'mesa-23.1.x/src/gallium/drivers/svga/include/vmware_pack_begin.h',
    'mesa-23.1.x/src/gallium/drivers/svga/include/vmware_pack_end.h',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_link.h',
    'mesa-23.1.x/src/gallium/frontends/nine/nine_dump.h',
    'mesa-23.1.x/src/gallium/frontends/nine/nine_ff.h',
    'mesa-23.1.x/src/gallium/frontends/nine/nine_flags.h',
    'mesa-23.1.x/src/gallium/frontends/nine/nine_pdata.h',
    'mesa-23.1.x/src/gallium/frontends/wgl/stw_nopfuncs.h',
    'mesa-23.1.x/src/gallium/include/frontend/drm_driver.h',
    'mesa-23.1.x/src/gallium/include/frontend/winsys_handle.h',
    'mesa-23.1.x/src/mapi/u_current.h',
    'mesa-23.1.x/src/mapi/u_execmem.h',
    'mesa-23.1.x/src/mesa/main/atifragshader.h',
    'mesa-23.1.x/src/mesa/main/extensions_table.h',
    'mesa-23.1.x/src/mesa/main/glconfig.h',
    'mesa-23.1.x/src/mesa/state_tracker/st_atom_list.h',
    'mesa-23.1.x/src/mesa/state_tracker/st_cb_drawtex.h'
)) {
    [void]$script:DefaultMesaLicensePaths.Add($path)
}
$script:UsedDefaultMesaLicensePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)

if (-not (Test-Path -LiteralPath (Join-Path $MesaCheckout '.git'))) {
    throw "Mesa checkout is not a Git checkout: $MesaCheckout"
}
$status = @(Invoke-GitText @('status', '--porcelain'))
if ($status.Count -ne 0) {
    throw 'Mesa checkout must be clean.'
}
$head = @(Invoke-GitText @('rev-parse', 'HEAD'))[0]
$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json -Depth 100
$compilerClosure = Get-Content -Raw -LiteralPath $CompilerClosurePath |
    ConvertFrom-Json -Depth 100
if ($head -cne $manifest.owning_commit -or
    $head -cne $compilerClosure.source.owning_commit) {
    throw 'Mesa checkout, component closure, and compiler closure commits differ.'
}

$tree = [Collections.Generic.Dictionary[string,string]]::new(
    [StringComparer]::Ordinal
)
foreach ($line in @(Invoke-GitText @('ls-tree', '-r', 'HEAD'))) {
    if ($line -cmatch '^160000 commit [0-9a-f]{40}\t') {
        continue
    }
    if ($line -cnotmatch '^(100644|100755) blob (?<hash>[0-9a-f]{40})\t(?<path>.+)$') {
        throw "Unexpected Git tree entry '$line'."
    }
    $tree.Add($Matches.path, $Matches.hash)
}

$dependencyRoles = Resolve-MesaCompilerDependencyRoles `
    @($compilerClosure.evidence.headers)
$dependencies = @($dependencyRoles.RolePaths | ForEach-Object {
    [pscustomobject]@{ relative_path = [string]$_ }
})

$filesByPath = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($file in @($manifest.files)) {
    $filesByPath.Add([string]$file.relative_path, $file)
}
$baseline = $filesByPath.Count -eq 1036 -and
    @($manifest.files | Where-Object {
        @($_.roles) -ccontains 'compiler-dependency'
    }).Count -eq 0
$complete = $filesByPath.Count -eq 1687 -and
    @($manifest.files | Where-Object {
        @($_.roles) -ccontains 'compiler-dependency'
    }).Count -eq 652
if (-not $baseline -and -not $complete) {
    throw 'The Mesa manifest is neither the expected baseline nor completed closure.'
}

if (-not @($manifest.source_prefixes | Where-Object {
    $_.id -ceq 'win9x-support'
})) {
    $manifest.source_prefixes = @($manifest.source_prefixes) + [pscustomobject][ordered]@{
        id = 'win9x-support'
        relative_path = 'win9x'
        mode = 'subtree'
    }
}

$evidence = [Collections.Generic.List[object]]::new()
foreach ($row in @($manifest.license_evidence)) {
    [void]$evidence.Add($row)
}
$files = [Collections.Generic.List[object]]::new()
foreach ($row in @($manifest.files)) {
    [void]$files.Add($row)
}

$reader = Start-GitBlobReader
try {
    $inlineIndex = 0
    foreach ($dependency in $dependencies) {
        $relativePath = [string]$dependency.relative_path
        if (-not $tree.ContainsKey($relativePath)) {
            throw "Compiler dependency '$relativePath' is absent from the pinned Git tree."
        }
        if ($filesByPath.ContainsKey($relativePath)) {
            $file = $filesByPath[$relativePath]
            if (@($file.roles) -cnotcontains 'compiler-dependency') {
                if ($relativePath -cne `
                    'mesa-23.1.x/src/gallium/include/pipe/p_defines.h') {
                    throw "Unexpected pre-existing compiler dependency '$relativePath'."
                }
                $file.roles = @('compiler-dependency', 'generator-input')
            }
            continue
        }

        $gitBlob = $tree[$relativePath]
        [byte[]]$content = Read-GitBlob $reader $gitBlob
        $text = [Text.Encoding]::Latin1.GetString($content)
        $classification = Get-LicenseClassification $relativePath $text
        $sourcePrefixId = Get-SourcePrefixId $relativePath
        if ([string]::IsNullOrEmpty($classification.DocumentId)) {
            $inlineIndex++
            $evidenceId = 'dependency-inline-{0:d4}' -f $inlineIndex
            [void]$evidence.Add((New-InlineEvidence $evidenceId $relativePath `
                $gitBlob $content $sourcePrefixId $classification))
        }
        else {
            $evidenceId = $classification.DocumentId
        }
        $file = [pscustomobject][ordered]@{
            relative_path = $relativePath
            git_blob = $gitBlob
            bytes = $content.Length
            sha256 = Get-Sha256 $content
            declared_license_expression = $classification.Declared
            selected_license_expression = $classification.Selected
            license_evidence_ids = @($evidenceId)
            source_prefix_id = $sourcePrefixId
            roles = @('compiler-dependency')
        }
        [void]$files.Add($file)
        $filesByPath.Add($relativePath, $file)
    }
}
finally {
    $reader.StandardInput.Close()
    $reader.WaitForExit()
    $errorText = $reader.StandardError.ReadToEnd()
    if ($reader.ExitCode -ne 0) {
        $reader.Dispose()
        throw "git cat-file failed: $errorText"
    }
    $reader.Dispose()
}

if ($baseline -and $script:UsedDefaultMesaLicensePaths.Count -ne
        $script:DefaultMesaLicensePaths.Count) {
    throw 'The curated Mesa project-license fallback set was not consumed exactly.'
}

$manifest.status = 'ready'
$manifest.reason = ''
$manifest.license_evidence = @($evidence)
$manifest.files = @(Get-OrdinalSortedRows @($files))

$compilerDependencies = @($manifest.files | Where-Object {
    @($_.roles) -ccontains 'compiler-dependency'
})
if (@($manifest.files).Count -ne 1687 -or
    @($manifest.files.relative_path | Sort-Object -Unique -CaseSensitive).Count -ne 1687 -or
    $compilerDependencies.Count -ne 652 -or
    @($manifest.license_evidence).Count -ne 1502) {
    throw 'The completed Mesa component closure has unexpected cardinality.'
}
$shadowedDependency = @($compilerDependencies | Where-Object {
    $_.relative_path -ceq $dependencyRoles.ShadowedPath
})
if ($shadowedDependency.Count -ne 1) {
    throw 'The completed Mesa component closure lacks the shadowed dependency role.'
}
Assert-MesaShadowedCompilerDependencyRole $shadowedDependency[0]
$expectedPartitions = [ordered]@{
    'MIT' = 1643
    'BSD-2-Clause' = 17
    'BSL-1.0' = 3
    'BSD-3-Clause' = 3
    'Apache-2.0' = 12
    'LicenseRef-Mesa-SHA1-Public-Domain' = 2
    'GPL-3.0-or-later WITH Bison-exception-2.2' = 3
    'LicenseRef-Mesa-DbgHelp-Public-Domain' = 1
    'SGI-B-2.0' = 1
    'LicenseRef-Mesa-Vrije-Permissive' = 1
    'LicenseRef-Mesa-U-Atomic-Public-Domain' = 1
}
$actualPartitions = @{}
foreach ($group in @($manifest.files | Group-Object selected_license_expression)) {
    $actualPartitions[$group.Name] = $group.Count
}
if ($actualPartitions.Count -ne $expectedPartitions.Count) {
    throw 'The completed Mesa component closure has unexpected license partitions.'
}
foreach ($entry in $expectedPartitions.GetEnumerator()) {
    if (-not $actualPartitions.ContainsKey($entry.Key) -or
        $actualPartitions[$entry.Key] -ne $entry.Value) {
        throw "Unexpected count for Mesa license partition '$($entry.Key)'."
    }
}

Write-CompactManifest $manifest $ManifestPath
$manifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "Wrote ready Mesa component closure with 1687 files, 652 compiler dependencies, 1502 evidence rows, and SHA-256 $manifestHash."

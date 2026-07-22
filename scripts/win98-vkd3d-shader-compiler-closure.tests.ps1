# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vkd3d-shader-compiler-evidence.ps1')
. (Join-Path $PSScriptRoot 'mesa-object-proof.ps1')

$script:TestCount = 0
$script:FailureCount = 0
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:DriversRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\drivers\win98')
)
$script:Verifier = Join-Path $PSScriptRoot `
    'verify-win98-vkd3d-shader-compiler-closure.ps1'
$script:Writer = Join-Path $PSScriptRoot `
    'write-win98-vkd3d-shader-compiler-closure.ps1'
$script:FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-vkd3d-compiler-closure-tests-' +
    [Guid]::NewGuid().ToString('N')
)
$script:FixtureOrdinal = 0

function Invoke-Vkd3dCompilerTest {
    param([string]$Name, [scriptblock]$Body)

    $script:TestCount++
    try {
        & $Body
        Write-Output "PASS: $Name"
    }
    catch {
        $script:FailureCount++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Assert-Vkd3dCompilerTestThrows {
    param([scriptblock]$Body, [string]$Expected)

    try { & $Body }
    catch {
        if ($_.Exception.Message.IndexOf(
                $Expected, [StringComparison]::OrdinalIgnoreCase
            ) -lt 0) {
            throw "Expected '$Expected', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected failure containing '$Expected'."
}

function Get-Vkd3dCompilerTestHash {
    param([string]$Text)

    return Get-Vkd3dEvidenceSha256 $script:Utf8.GetBytes($Text)
}

function Get-Vkd3dCompilerTestSnapshot {
    param([string]$RelativePath)

    $path = Join-Path $script:DriversRoot $RelativePath.Replace('/', '\')
    [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
    return [pscustomobject]@{
        relative_path = $RelativePath
        bytes = [UInt64]$bytes.Length
        sha256 = Get-Vkd3dEvidenceSha256 $bytes
    }
}

function Copy-Vkd3dCompilerTestValue {
    param([object]$Value)

    return ($Value | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json)
}

function Write-Vkd3dCompilerTestJson {
    param([object]$Value, [string]$Prefix = 'fixture')

    $script:FixtureOrdinal++
    $path = Join-Path $script:FixtureRoot (
        "$Prefix-$($script:FixtureOrdinal.ToString('D3')).json"
    )
    $json = ($Value | ConvertTo-Json -Depth 40) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($path, $json + "`n", $script:Utf8)
    return $path
}

function Expand-Vkd3dCompilerTestArguments {
    param([object[]]$Arguments, [hashtable]$Values)

    return @($Arguments | ForEach-Object {
        $value = [string]$_
        foreach ($key in $Values.Keys) {
            $value = $value.Replace('{' + $key + '}', [string]$Values[$key])
        }
        $value
    })
}

function Sort-Vkd3dCompilerTestRows {
    param([object[]]$Rows)

    [object[]]$copy = @($Rows)
    [Array]::Sort($copy, [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.relative_path,
                [string]$right.relative_path
            )
        }
    ))
    return @($copy)
}

function Set-Vkd3dCompilerTestGeneratedAggregates {
    param([object]$Run)

    [UInt64]$rawBytes = 0
    [UInt64]$canonicalBytes = 0
    $rawRows = @($Run.outputs | ForEach-Object {
        $rawBytes += [UInt64]$_.raw_bytes
        $canonicalBytes += [UInt64]$_.bytes
        [pscustomobject]@{
            relative_path = [string]$_.relative_path
            bytes = [UInt64]$_.raw_bytes
            sha256 = [string]$_.raw_sha256
        }
    })
    $Run.raw_aggregate_bytes = $rawBytes
    $Run.raw_aggregate_sha256 = Get-Vkd3dEvidenceAggregateSha256 $rawRows
    $Run.aggregate_bytes = $canonicalBytes
    $Run.aggregate_sha256 = Get-Vkd3dEvidenceAggregateSha256 @($Run.outputs)
}

function Set-Vkd3dCompilerTestDependencyFile {
    param([object]$DependencyFile)

    [UInt64]$occurrenceCount = 0
    foreach ($row in @($DependencyFile.files)) {
        $occurrenceCount += [UInt64]$row.occurrence_count
    }
    $DependencyFile.dependency_count = $occurrenceCount
    $DependencyFile.unique_dependency_count =
        [UInt64]@($DependencyFile.files).Count
    $DependencyFile.aggregate_sha256 =
        Get-Vkd3dEvidenceDependencyMultiplicitySha256 `
            @($DependencyFile.files)
}

function Get-Vkd3dCompilerTestDefinitions {
    return @(
        @('libs/vkd3d-shader/hlsl.yy.c', 'generated-c', 'flex-c', 'LGPL-2.1-or-later', 'flex-2.6.4-output-exception-and-lgpl-lexer', @('libs/vkd3d-shader/hlsl.l')),
        @('libs/vkd3d-shader/hlsl.tab.c', 'generated-c', 'bison-c-header', 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)', 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input', @('libs/vkd3d-shader/hlsl.y')),
        @('libs/vkd3d-shader/hlsl.tab.h', 'generated-header', 'bison-c-header', 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)', 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input', @('libs/vkd3d-shader/hlsl.y')),
        @('libs/vkd3d-shader/preproc.yy.c', 'generated-c', 'flex-c', 'LGPL-2.1-or-later', 'flex-2.6.4-output-exception-and-lgpl-lexer', @('libs/vkd3d-shader/preproc.l')),
        @('libs/vkd3d-shader/preproc.tab.c', 'generated-c', 'bison-c-header', 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)', 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input', @('libs/vkd3d-shader/preproc.y')),
        @('libs/vkd3d-shader/preproc.tab.h', 'generated-header', 'bison-c-header', 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)', 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input', @('libs/vkd3d-shader/preproc.y')),
        @('include/vkd3d_d3dcommon.h', 'generated-header', 'widl-header', 'LGPL-2.1-or-later', 'widl-11.0-rc1-from-exact-lgpl-idl', @('include/vkd3d_d3dcommon.idl', 'include/vkd3d_unknown.idl')),
        @('include/vkd3d_d3dx9shader.h', 'generated-header', 'widl-header', 'LGPL-2.1-or-later', 'widl-11.0-rc1-from-exact-lgpl-idl', @('include/vkd3d_d3dx9shader.idl', 'include/vkd3d_d3d9types.h')),
        @('include/private/spirv_grammar.h', 'generated-header', 'spirv-header', 'MIT', 'unchanged-make-spirv-from-exact-mit-grammar', @('libs/vkd3d-shader/make_spirv', 'include/private/spirv.core.grammar.json')),
        @('include/config.h', 'generated-header', 'reviewed-config-header', 'GPL-3.0-only', 'retvrn99-exact-configuration-recipe', @('configure.ac')),
        @('include/private/vkd3d_version.h', 'generated-header', 'reviewed-version-header', 'GPL-3.0-only', 'retvrn99-exact-version-recipe', @('Makefile.am'))
    )
}

function Get-Vkd3dCompilerTestUnits {
    return @(
        @('tracked', 'libs/vkd3d-shader/checksum.c'),
        @('tracked', 'libs/vkd3d-shader/d3d_asm.c'),
        @('tracked', 'libs/vkd3d-shader/d3dbc.c'),
        @('tracked', 'libs/vkd3d-shader/dxbc.c'),
        @('tracked', 'libs/vkd3d-shader/dxil.c'),
        @('tracked', 'libs/vkd3d-shader/fx.c'),
        @('tracked', 'libs/vkd3d-shader/glsl.c'),
        @('tracked', 'libs/vkd3d-shader/hlsl.c'),
        @('tracked', 'libs/vkd3d-shader/hlsl_codegen.c'),
        @('tracked', 'libs/vkd3d-shader/hlsl_constant_ops.c'),
        @('tracked', 'libs/vkd3d-shader/ir.c'),
        @('tracked', 'libs/vkd3d-shader/msl.c'),
        @('tracked', 'libs/vkd3d-shader/spirv.c'),
        @('tracked', 'libs/vkd3d-shader/tpf.c'),
        @('tracked', 'libs/vkd3d-shader/vkd3d_shader_main.c'),
        @('generated', 'libs/vkd3d-shader/hlsl.tab.c'),
        @('generated', 'libs/vkd3d-shader/hlsl.yy.c'),
        @('generated', 'libs/vkd3d-shader/preproc.tab.c'),
        @('generated', 'libs/vkd3d-shader/preproc.yy.c')
    )
}

function New-Vkd3dCompilerTestClosure {
    $component = Get-Content -LiteralPath (Join-Path $script:DriversRoot `
        'component-closures\vkd3d-shader.json') -Raw | ConvertFrom-Json
    $mesa = Get-Content -LiteralPath (Join-Path $script:DriversRoot `
        'component-closures\mesa9x-23.1.x.json') -Raw | ConvertFrom-Json
    $lock = Get-Content -LiteralPath (Join-Path $script:DriversRoot `
        'vkd3d-shader-toolchain-lock.json') -Raw | ConvertFrom-Json
    $schemaBinding = Get-Vkd3dCompilerTestSnapshot `
        'vkd3d-shader-compiler-closure.schema.json'
    $componentBinding = Get-Vkd3dCompilerTestSnapshot `
        'component-closures/vkd3d-shader.json'
    $mesaBinding = Get-Vkd3dCompilerTestSnapshot `
        'component-closures/mesa9x-23.1.x.json'
    $lockBinding = Get-Vkd3dCompilerTestSnapshot `
        'vkd3d-shader-toolchain-lock.json'

    $sourceFiles = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt @($component.files).Count; $index++) {
        $file = $component.files[$index]
        $sourceFiles.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]($index + 1)
            relative_path = [string]$file.relative_path
            git_blob = [string]$file.git_blob
            bytes = [UInt64]$file.bytes
            lf_count = [UInt64]1
            crlf_count = [UInt64]1
            sha256 = [string]$file.sha256
            declared_license_expression = `
                [string]$file.declared_license_expression
            selected_license_expression = `
                [string]$file.selected_license_expression
            license_evidence_ids = @($file.license_evidence_ids)
            roles = @($file.roles)
            canonical_pair = $true
        })
    }
    [UInt64]$sourceBytes = 0
    foreach ($row in $sourceFiles) { $sourceBytes += [UInt64]$row.bytes }

    $crossDefinitions = @(
        @('mesa-23.1.x/src/compiler/spirv/spirv.h',
            'include/spirv/unified1/spirv.h'),
        @('mesa-23.1.x/src/compiler/spirv/GLSL.std.450.h',
            'include/spirv/unified1/GLSL.std.450.h')
    )
    $crossFiles = [Collections.Generic.List[object]]::new()
    [UInt64]$crossBytes = 0
    for ($index = 0; $index -lt 2; $index++) {
        $sourcePath = $crossDefinitions[$index][0]
        $file = @($mesa.files | Where-Object relative_path -ceq $sourcePath)[0]
        $crossFiles.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]($index + 1)
            source_relative_path = $sourcePath
            target_relative_path = $crossDefinitions[$index][1]
            git_blob = [string]$file.git_blob
            bytes = [UInt64]$file.bytes
            sha256 = [string]$file.sha256
            license_expression = 'MIT'
        })
        $crossBytes += [UInt64]$file.bytes
    }
    $crossAggregate = @($crossFiles | ForEach-Object {
        [pscustomobject]@{
            relative_path = $_.target_relative_path
            bytes = $_.bytes
            sha256 = $_.sha256
        }
    })

    $probeRows = [Collections.Generic.List[object]]::new()
    foreach ($probe in @($lock.tool_probes)) {
        $text = (@($probe.expected_lines) -join "`n") + "`n"
        $probeRows.Add([pscustomobject][ordered]@{
            id = [string]$probe.id
            file_id = [string]$probe.file_id
            expected_lines = @($probe.expected_lines)
            observed_lines = @($probe.expected_lines)
            stdout_bytes = [UInt64]$script:Utf8.GetByteCount($text)
            stdout_sha256 = Get-Vkd3dCompilerTestHash $text
        })
    }

    $definitions = @(Get-Vkd3dCompilerTestDefinitions)
    $generatedPlans = [Collections.Generic.List[object]]::new()
    $generatedOutputs = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $definitions.Count; $index++) {
        $definition = $definitions[$index]
        $hash = Get-Vkd3dCompilerTestHash `
            ("generated-output-$($index + 1)-$($definition[0])")
        $isWidl = $index -in @(6, 7)
        if ($index -eq 6) {
            [UInt64]$rawBytes = 23406
            $rawHash = 'fb522341733698aefa4b52c7e1d8860cd9ddd63b533c81f49331afe9d6b55942'
            [UInt64]$newlineCount = 699
            [UInt64]$canonicalBytes = 22707
            $hash = 'c52dc8d4aa832294220b3684b4b011319523595d038eaa0a1c055a4028112482'
        }
        elseif ($index -eq 7) {
            [UInt64]$rawBytes = 2017
            $rawHash = '7a10933742f289060141d9366943817742f7c8efb6fb33a7ea54208165a55542'
            [UInt64]$newlineCount = 87
            [UInt64]$canonicalBytes = 1930
            $hash = '574e09c72ad2bb9f3182a38cb32dac70a25753d34f9f3d2454db514864e1c6d0'
        }
        else {
            [UInt64]$canonicalBytes = 256 + $index
            [UInt64]$rawBytes = $canonicalBytes
            $rawHash = $hash
            [UInt64]$newlineCount = 1
        }
        $generatedPlans.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]($index + 1)
            relative_path = [string]$definition[0]
            kind = [string]$definition[1]
            recipe_id = [string]$definition[2]
            inputs = @($definition[5])
        })
        $generatedOutputs.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]($index + 1)
            relative_path = [string]$definition[0]
            raw_bytes = $rawBytes
            raw_sha256 = $rawHash
            raw_lf_count = $newlineCount
            raw_crlf_count = if ($isWidl) { $newlineCount } else { [UInt64]0 }
            raw_lf_only_count = if ($isWidl) { [UInt64]0 } else { $newlineCount }
            raw_cr_only_count = [UInt64]0
            raw_utf8_bom = $false
            normalization = if ($isWidl) { 'crlf-to-lf' } else { 'none' }
            removed_cr_bytes = if ($isWidl) { $newlineCount } else { [UInt64]0 }
            normalization_proven = $true
            bytes = $canonicalBytes
            sha256 = $hash
            lf_count = $newlineCount
            crlf_count = [UInt64]0
            lf_only_count = $newlineCount
            cr_only_count = [UInt64]0
            utf8_bom = $false
            license_expression = [string]$definition[3]
            provenance = [string]$definition[4]
        })
    }
    [UInt64]$generatedBytes = 0
    [UInt64]$rawGeneratedBytes = 0
    foreach ($row in $generatedOutputs) { $generatedBytes += [UInt64]$row.bytes }
    foreach ($row in $generatedOutputs) {
        $rawGeneratedBytes += [UInt64]$row.raw_bytes
    }
    $recipesById = @{}
    foreach ($recipe in @($lock.recipes)) {
        $recipesById[[string]$recipe.id] = $recipe
    }
    $generatorPlans = @(
        @('flex-c', 'msys-flex', @{ output_c = '{generated}/libs/vkd3d-shader/hlsl.yy.c'; input_l = '{source}/libs/vkd3d-shader/hlsl.l' }),
        @('bison-c-header', 'msys-bison', @{ output_c = '{generated}/libs/vkd3d-shader/hlsl.tab.c'; input_y = '{source}/libs/vkd3d-shader/hlsl.y' }),
        @('flex-c', 'msys-flex', @{ output_c = '{generated}/libs/vkd3d-shader/preproc.yy.c'; input_l = '{source}/libs/vkd3d-shader/preproc.l' }),
        @('bison-c-header', 'msys-bison', @{ output_c = '{generated}/libs/vkd3d-shader/preproc.tab.c'; input_y = '{source}/libs/vkd3d-shader/preproc.y' }),
        @('widl-header', 'ucrt-widl', @{ source_include = '{source}/include'; output_h = '{generated}/include/vkd3d_d3dcommon.h'; input_idl = '{source}/include/vkd3d_d3dcommon.idl' }),
        @('widl-header', 'ucrt-widl', @{ source_include = '{source}/include'; output_h = '{generated}/include/vkd3d_d3dx9shader.h'; input_idl = '{source}/include/vkd3d_d3dx9shader.idl' }),
        @('spirv-header', 'git-perl', @{ make_spirv = '{source}/libs/vkd3d-shader/make_spirv'; grammar = '{source}/include/private/spirv.core.grammar.json' }),
        @('reviewed-config-header', 'retvrn99-reviewed-bytes', @{}),
        @('reviewed-version-header', 'retvrn99-reviewed-bytes', @{})
    )
    $generatorCommands = [Collections.Generic.List[object]]::new()
    $emptyHash = `
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    for ($index = 0; $index -lt 9; $index++) {
        $plan = $generatorPlans[$index]
        if ($index -lt 7) {
            $arguments = @(Expand-Vkd3dCompilerTestArguments `
                @($recipesById[$plan[0]].arguments) $plan[2])
        }
        elseif ($index -eq 7) { $arguments = @('write-exact', 'include/config.h') }
        else {
            $arguments = @('write-exact', 'include/private/vkd3d_version.h')
        }
        $stdoutBytes = if ($index -eq 6) {
            [UInt64]$generatedOutputs[8].bytes
        }
        else { [UInt64]0 }
        $stdoutHash = if ($index -eq 6) {
            [string]$generatedOutputs[8].sha256
        }
        else { $emptyHash }
        $generatorCommands.Add([pscustomobject][ordered]@{
            ordinal = [UInt64]($index + 1)
            recipe_id = [string]$plan[0]
            tool_file_id = [string]$plan[1]
            arguments = $arguments
            exit_code = [UInt64]0
            stdout_bytes = $stdoutBytes
            stdout_sha256 = $stdoutHash
            stderr_bytes = [UInt64]0
            stderr_sha256 = $emptyHash
        })
    }
    $generatedAggregate = Get-Vkd3dEvidenceAggregateSha256 `
        @($generatedOutputs)
    $rawGeneratedRows = @($generatedOutputs | ForEach-Object {
        [pscustomobject]@{
            relative_path = [string]$_.relative_path
            bytes = [UInt64]$_.raw_bytes
            sha256 = [string]$_.raw_sha256
        }
    })
    $rawGeneratedAggregate = Get-Vkd3dEvidenceAggregateSha256 `
        $rawGeneratedRows
    $generatedRuns = @(
        [pscustomobject][ordered]@{
            id = 'lf'; source_mode = 'lf'
            generator_commands = @(Copy-Vkd3dCompilerTestValue $generatorCommands)
            output_count = [UInt64]11
            raw_aggregate_bytes = $rawGeneratedBytes
            raw_aggregate_sha256 = $rawGeneratedAggregate
            aggregate_bytes = $generatedBytes
            aggregate_sha256 = $generatedAggregate
            outputs = @(Copy-Vkd3dCompilerTestValue $generatedOutputs)
        },
        [pscustomobject][ordered]@{
            id = 'crlf'; source_mode = 'crlf'
            generator_commands = @(Copy-Vkd3dCompilerTestValue $generatorCommands)
            output_count = [UInt64]11
            raw_aggregate_bytes = $rawGeneratedBytes
            raw_aggregate_sha256 = $rawGeneratedAggregate
            aggregate_bytes = $generatedBytes
            aggregate_sha256 = $generatedAggregate
            outputs = @(Copy-Vkd3dCompilerTestValue $generatedOutputs)
        }
    )

    $sourceByPath = @{}
    foreach ($row in $sourceFiles) { $sourceByPath[$row.relative_path] = $row }
    $generatedByPath = @{}
    foreach ($row in $generatedOutputs) {
        $generatedByPath[$row.relative_path] = $row
    }
    foreach ($row in $crossFiles) {
        $generatedByPath[$row.target_relative_path] = $row
    }
    $units = @(Get-Vkd3dCompilerTestUnits)
    $compilationUnits = [Collections.Generic.List[object]]::new()
    foreach ($index in 0..18) {
        $definition = $units[$index]
        $row = if ($definition[0] -ceq 'tracked') {
            $sourceByPath[$definition[1]]
        }
        else { $generatedByPath[$definition[1]] }
        $compilationUnits.Add([pscustomobject][ordered]@{
            unit_ordinal = [UInt64]($index + 1)
            input_kind = [string]$definition[0]
            input = [string]$definition[1]
            sha256 = [string]$row.sha256
        })
    }

    $dependencyRows = [Collections.Generic.List[object]]::new()
    foreach ($file in @($component.files | Where-Object {
        @($_.roles) -ccontains 'source-unit' -or
        @($_.roles) -ccontains 'compiler-dependency'
    })) {
        $dependencyRows.Add([pscustomobject]@{
            relative_path = '{source}/' + [string]$file.relative_path
            occurrence_count = [UInt64]1
            bytes = [UInt64]$file.bytes
            sha256 = [string]$file.sha256
        })
    }
    foreach ($row in $generatedByPath.Values) {
        $path = if ($row.PSObject.Properties.Name -contains 'relative_path') {
            [string]$row.relative_path
        }
        else { [string]$row.target_relative_path }
        $dependencyRows.Add([pscustomobject]@{
            relative_path = '{generated}/' + $path
            occurrence_count = [UInt64]1
            bytes = [UInt64]$row.bytes
            sha256 = [string]$row.sha256
        })
    }
    $dependencyRows.Add([pscustomobject]@{
        relative_path = '{ucrt64}/include/pshpack4.h'
        occurrence_count = [UInt64]2
        bytes = [UInt64]64
        sha256 = Get-Vkd3dCompilerTestHash 'synthetic-toolchain-header'
    })
    $dependencyRows = @(Sort-Vkd3dCompilerTestRows @($dependencyRows))
    [UInt64]$dependencyOccurrenceCount = 0
    foreach ($row in $dependencyRows) {
        $dependencyOccurrenceCount += [UInt64]$row.occurrence_count
    }
    $dependencyAggregate =
        Get-Vkd3dEvidenceDependencyMultiplicitySha256 $dependencyRows
    $globalDependencyRows = @($dependencyRows | ForEach-Object {
        [pscustomobject]@{
            relative_path = [string]$_.relative_path
            occurrence_count = [UInt64](19 * [UInt64]$_.occurrence_count)
            bytes = [UInt64]$_.bytes
            sha256 = [string]$_.sha256
        }
    })
    [UInt64]$globalDependencyOccurrenceCount =
        19 * $dependencyOccurrenceCount
    $globalDependencyAggregate =
        Get-Vkd3dEvidenceDependencyMultiplicitySha256 $globalDependencyRows

    $commands = [Collections.Generic.List[object]]::new()
    $objectRows = [Collections.Generic.List[object]]::new()
    foreach ($index in 0..18) {
        $unit = $compilationUnits[$index]
        $ordinal = $index + 1
        $leaf = Get-Vkd3dEvidenceObjectStem ([string]$unit.input)
        $stem = $ordinal.ToString('D2') + '-' + $leaf
        $objectPath = "obj/$stem.o"
        $depfilePath = "dep/$stem.d"
        $inputRoot = if ($unit.input_kind -ceq 'tracked') {
            '{source}'
        }
        else { '{generated}' }
        $arguments = @(Expand-Vkd3dCompilerTestArguments `
            @($recipesById['compile-c-object'].arguments) @{
                source_root = '{source}'; generated_root = '{generated}'
                temporary_root = '{temporary}'; unit_sha256 = $unit.sha256
                depfile = $depfilePath; object = $objectPath
                input_c = "$inputRoot/$($unit.input)"
            })
        $normalized = Get-Vkd3dCompilerTestHash "normalized-$ordinal"
        $runs = [Collections.Generic.List[object]]::new()
        foreach ($runId in @('lf', 'crlf')) {
            $raw = Get-Vkd3dCompilerTestHash "raw-$runId-$ordinal"
            $objdumpText = "synthetic-objdump-$ordinal`n"
            $runs.Add([pscustomobject][ordered]@{
                id = $runId
                dependency_file = [pscustomobject][ordered]@{
                    relative_path = $depfilePath
                    dependency_count = $dependencyOccurrenceCount
                    unique_dependency_count = [UInt64]$dependencyRows.Count
                    aggregate_sha256 = $dependencyAggregate
                    files = @(Copy-Vkd3dCompilerTestValue $dependencyRows)
                }
                object = [pscustomobject][ordered]@{
                    relative_path = $objectPath
                    machine = [UInt64]34404
                    machine_name = 'amd64'
                    bytes = [UInt64](1024 + $ordinal)
                    timestamp = [UInt64](100 + $ordinal)
                    raw_sha256 = $raw
                    normalized_sha256 = $normalized
                }
                objdump = [pscustomobject][ordered]@{
                    arguments = @('-f', '-h', '-t', $objectPath)
                    format = 'pe-x86-64'
                    architecture = 'i386:x86-64'
                    stdout_bytes = [UInt64]$script:Utf8.GetByteCount($objdumpText)
                    stdout_sha256 = Get-Vkd3dCompilerTestHash $objdumpText
                }
            })
        }
        $commands.Add([pscustomobject][ordered]@{
            unit_ordinal = [UInt64]$ordinal
            input_kind = [string]$unit.input_kind
            input = [string]$unit.input
            input_sha256 = [string]$unit.sha256
            arguments = $arguments
            runs = @($runs)
            twin = [pscustomobject][ordered]@{
                dependency_match = $true
                normalized_object_match = $true
                objdump_format_match = $true
            }
        })
        $objectRows.Add([pscustomobject]@{
            unit_ordinal = $ordinal
            object = $objectPath
            bytes = [UInt64](1024 + $ordinal)
            normalized_sha256 = $normalized
        })
    }
    $objectAggregate = Get-MesaObjectAggregateSha256 @($objectRows)
    $generatorChildren = 2 * 7
    $childProcesses = 9 + (2 * 5) + 40 + $generatorChildren + 38 + 38 +
        (2 * 4) + 40

    return [pscustomobject][ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = [UInt64]1
        schema_definition = $schemaBinding
        status = 'compile-proven'
        source = [pscustomobject][ordered]@{
            component = 'vkd3d-shader'
            repository = 'https://gitlab.winehq.org/wine/vkd3d.git'
            owning_commit = '1b0924d12c18df03912a8876ed17fd017ce9308e'
            component_manifest = [pscustomobject][ordered]@{
                relative_path = $componentBinding.relative_path
                bytes = $componentBinding.bytes; sha256 = $componentBinding.sha256
                status = 'ready'; file_count = [UInt64]40
            }
            git_tool = [pscustomobject][ordered]@{
                file_id = 'git-core'; bytes = [UInt64]4422544
                sha256 = 'cab4c4eea1d869cf9f7be73868dc9a90ad2df1b1b673e5f8c8714a576c25ea96'
                probe_id = 'git-version'; version = 'git version 2.54.0.windows.1'
            }
        }
        source_pair = [pscustomobject][ordered]@{
            status = 'canonical-lf-crlf-proven'
            checkouts = @(
                [pscustomobject][ordered]@{ id = 'lf'; checkout_mode = 'lf'; clean = $true; detached = $true; owning_commit = '1b0924d12c18df03912a8876ed17fd017ce9308e'; origin = 'https://gitlab.winehq.org/wine/vkd3d.git' },
                [pscustomobject][ordered]@{ id = 'crlf'; checkout_mode = 'crlf'; clean = $true; detached = $true; owning_commit = '1b0924d12c18df03912a8876ed17fd017ce9308e'; origin = 'https://gitlab.winehq.org/wine/vkd3d.git' }
            )
            file_count = [UInt64]40; aggregate_bytes = $sourceBytes
            aggregate_sha256 = Get-Vkd3dEvidenceAggregateSha256 @($sourceFiles)
            files = @($sourceFiles)
        }
        cross_component_inputs = [pscustomobject][ordered]@{
            status = 'ready'
            component_manifest = [pscustomobject][ordered]@{
                relative_path = $mesaBinding.relative_path; bytes = $mesaBinding.bytes
                sha256 = $mesaBinding.sha256; status = 'ready'; file_count = [UInt64]1687
            }
            owning_commit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
            file_count = [UInt64]2; aggregate_bytes = $crossBytes
            aggregate_sha256 = Get-Vkd3dEvidenceAggregateSha256 $crossAggregate
            files = @($crossFiles)
        }
        toolchain = [pscustomobject][ordered]@{
            status = 'ready'
            lock = [pscustomobject][ordered]@{
                relative_path = $lockBinding.relative_path; bytes = $lockBinding.bytes
                sha256 = $lockBinding.sha256; status = 'ready'
            }
            roots = @(
                [pscustomobject][ordered]@{ id = 'msys'; verified = $true },
                [pscustomobject][ordered]@{ id = 'ucrt64'; verified = $true },
                [pscustomobject][ordered]@{ id = 'git'; verified = $true }
            )
            files = @(Copy-Vkd3dCompilerTestValue $lock.files)
            trees = @(Copy-Vkd3dCompilerTestValue $lock.trees)
            probes = @($probeRows)
            environment = [pscustomobject][ordered]@{
                path_policy = 'executable-parent-directories-only'
                perl5lib_roots = @('git:usr/share/perl5/vendor_perl', 'git:usr/share/perl5/core_perl', 'git:usr/lib/perl5/core_perl')
                ambient_library_paths = $false
            }
            process_limits = [pscustomobject][ordered]@{
                no_shell = $true; maximum_top_level_processes = [UInt64]1
                maximum_process_tree_width = [UInt64]5; timeout_seconds = [UInt64]30
                termination_grace_seconds = [UInt64]5
                maximum_stdout_bytes = [UInt64]1048576
                maximum_stderr_bytes = [UInt64]1048576
                terminate_process_tree = $true
            }
        }
        recipe = [pscustomobject][ordered]@{
            status = 'exact-compile-only'; generated_output_count = [UInt64]11
            tracked_source_unit_count = [UInt64]15
            generated_source_unit_count = [UInt64]4
            compile_command_count = [UInt64]19
            generator_recipes = @('flex-c', 'bison-c-header', 'widl-header', 'spirv-header' | ForEach-Object { Copy-Vkd3dCompilerTestValue $recipesById[$_] })
            compile_arguments = @($recipesById['compile-c-object'].arguments)
            object_validation_arguments = @($recipesById['validate-object'].arguments)
            generated_outputs = @($generatedPlans)
            compilation_units = @($compilationUnits)
        }
        generated_runs = $generatedRuns
        commands = @($commands)
        comparison = [pscustomobject][ordered]@{
            raw_generated_outputs = [pscustomobject][ordered]@{ match = $true; count = [UInt64]11; aggregate_sha256 = $rawGeneratedAggregate }
            generated_outputs = [pscustomobject][ordered]@{ match = $true; count = [UInt64]11; aggregate_sha256 = $generatedAggregate }
            dependencies = [pscustomobject][ordered]@{ match = $true; occurrence_count = $globalDependencyOccurrenceCount; unique_count = [UInt64]$globalDependencyRows.Count; aggregate_sha256 = $globalDependencyAggregate }
            normalized_objects = [pscustomobject][ordered]@{ match = $true; count = [UInt64]19; aggregate_sha256 = $objectAggregate }
        }
        summary = [pscustomobject][ordered]@{
            source_files = [UInt64]40; generated_outputs = [UInt64]11
            tracked_source_units = [UInt64]15; generated_source_units = [UInt64]4
            compile_commands = [UInt64]19; twin_compile_invocations = [UInt64]38
            dependency_files = [UInt64]38; validated_amd64_coff_objects = [UInt64]38
            objdump_validations = [UInt64]38; child_processes = [UInt64]$childProcesses
            temporary_output_count = [UInt64]0; proof_root_removed = $true
            partial_evidence_removed = $true; linker_invocations = [UInt64]0
            failed_generator_commands = [UInt64]0; failed_compile_commands = [UInt64]0
            failed_dependency_validations = [UInt64]0; failed_object_validations = [UInt64]0
        }
        authorizations = [pscustomobject][ordered]@{
            fetch = $false; download = $false; production_build = $false
            link = $false; persistent_artifacts = $false; stage = $false
            install = $false; activate = $false; guest_execution = $false
            renderer_selection = $false; capability_advertisement = $false
            unreviewed_generator_execution = $false
        }
    }
}

function Invoke-Vkd3dCompilerMutationTest {
    param(
        [string]$Name,
        [object]$Baseline,
        [scriptblock]$Mutation,
        [string]$Expected
    )

    Invoke-Vkd3dCompilerTest $Name {
        $value = Copy-Vkd3dCompilerTestValue $Baseline
        & $Mutation $value
        $path = Write-Vkd3dCompilerTestJson $value 'mutation'
        Assert-Vkd3dCompilerTestThrows {
            & $script:Verifier -ClosureFile $path `
                -DriversRoot $script:DriversRoot | Out-Null
        } $Expected
    }
}

function Get-Vkd3dCompilerEncodedCommand {
    param([string]$Command)

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

. $script:Writer -EvidenceFile 'internal-test-seam-load' `
    -DriversRoot $script:DriversRoot

try {
    [void][IO.Directory]::CreateDirectory($script:FixtureRoot)
    $valid = New-Vkd3dCompilerTestClosure
    $validPath = Write-Vkd3dCompilerTestJson $valid 'valid-evidence'
    $schemaPath = Join-Path $script:DriversRoot `
        'vkd3d-shader-compiler-closure.schema.json'

    Invoke-Vkd3dCompilerTest 'Synthetic compile-proven closure verifies' {
        $result = @(& $script:Verifier -ClosureFile $validPath `
            -DriversRoot $script:DriversRoot)
        if ($result.Count -ne 1 -or
            $result[0] -cnotmatch '41 evidence-derived dependencies') {
            throw 'Synthetic verifier output changed.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Blank observed probe lines remain path-free' {
        $value = Copy-Vkd3dCompilerTestValue $valid
        $value.toolchain.probes[0].observed_lines = @(
            @($value.toolchain.probes[0].observed_lines) + @('')
        )
        $path = Write-Vkd3dCompilerTestJson $value 'blank-probe-line'
        if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $path) `
                -SchemaFile $schemaPath)) {
            throw 'Blank observed probe line failed the bound JSON Schema.'
        }
        $result = @(& $script:Verifier -ClosureFile $path `
            -DriversRoot $script:DriversRoot)
        if ($result.Count -ne 1 -or
            $result[0] -cnotmatch '41 evidence-derived dependencies') {
            throw 'Blank observed probe line failed private-path verification.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Synthetic closure satisfies JSON Schema' {
        if (-not (Test-Json -Json (Get-Content -Raw $validPath) `
                -SchemaFile $schemaPath)) {
            throw 'Synthetic compiler closure failed JSON Schema validation.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Compiler object stems preserve safe dotted C leaves' {
        foreach ($case in @(
            @('libs/vkd3d-shader/checksum.c', 'checksum'),
            @('libs/vkd3d-shader/hlsl.tab.c', 'hlsl.tab'),
            @('libs/vkd3d-shader/preproc.yy.c', 'preproc.yy')
        )) {
            $stem = Get-Vkd3dEvidenceObjectStem ([string]$case[0])
            if ($stem -cne [string]$case[1]) {
                throw "Object stem for '$($case[0])' changed."
            }
        }
        foreach ($path in @(
            'libs/vkd3d-shader/hlsl..tab.c',
            'libs/vkd3d-shader/hlsl-tab.c',
            'libs/vkd3d-shader/.c',
            'libs/vkd3d-shader/hlsl.tab.cc'
        )) {
            Assert-Vkd3dCompilerTestThrows {
                Get-Vkd3dEvidenceObjectStem $path | Out-Null
            } 'unsafe object stem'
        }
    }
    Invoke-Vkd3dCompilerTest 'Synthetic dependency multiplicity is explicit' {
        $depfile = $valid.commands[0].runs[0].dependency_file
        $repeated = @($depfile.files | Where-Object {
            $_.relative_path -ceq '{ucrt64}/include/pshpack4.h'
        })
        if ($repeated.Count -ne 1 -or
            [UInt64]$repeated[0].occurrence_count -ne 2 -or
            [UInt64]$depfile.dependency_count -ne
                ([UInt64]$depfile.unique_dependency_count + 1)) {
            throw 'Synthetic repeated dependency evidence changed.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Dependency multiplicity bounds are exact' {
        $schema = Get-Content -Raw -LiteralPath $schemaPath |
            ConvertFrom-Json
        if ([UInt64]$schema.'$defs'.dependency_row.properties.
                occurrence_count.maximum -ne 4096 -or
            [UInt64]$schema.'$defs'.dependency_file.properties.
                dependency_count.maximum -ne 4096 -or
            [UInt64]$schema.'$defs'.dependency_file.properties.
                unique_dependency_count.maximum -ne 4096 -or
            [UInt64]$schema.'$defs'.dependency_comparison.properties.
                occurrence_count.maximum -ne 77824 -or
            [UInt64]$schema.'$defs'.dependency_comparison.properties.
                unique_count.maximum -ne 77824) {
            throw 'Dependency multiplicity bounds changed.'
        }
        $rows = [Collections.Generic.List[object]]::new()
        $hash = Get-Vkd3dCompilerTestHash 'global-unique-bound'
        foreach ($index in 0..4096) {
            $rows.Add([pscustomobject][ordered]@{
                relative_path = '{ucrt64}/include/synthetic-' +
                    $index.ToString('D4') + '.h'
                occurrence_count = [UInt64]1
                bytes = [UInt64]1
                sha256 = $hash
            })
        }
        if ((Get-Vkd3dEvidenceDependencyMultiplicitySha256 @($rows)) `
                -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Global dependency aggregate rejected more than 4096 rows.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Repeated dependency identity drift is rejected' {
        $rows = [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
        $path = '{ucrt64}/include/pshpack4.h'
        $hash = Get-Vkd3dCompilerTestHash 'first-identity'
        [void](Add-Vkd3dEvidenceDependencyOccurrence -Rows $rows `
            -RelativePath $path -Bytes 64 -Sha256 $hash `
            -MaximumOccurrenceCount 4096)
        Assert-Vkd3dCompilerTestThrows {
            [void](Add-Vkd3dEvidenceDependencyOccurrence -Rows $rows `
                -RelativePath $path -Bytes 64 `
                -Sha256 (Get-Vkd3dCompilerTestHash 'changed-identity') `
                -MaximumOccurrenceCount 4096)
        } 'changed or overflowed'
        if ($rows.Count -ne 1 -or
            [UInt64]$rows[$path].occurrence_count -ne 1) {
            throw 'Rejected repeated dependency changed retained evidence.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Writer requires explicit promotion switch' {
        $output = Join-Path $script:FixtureRoot 'no-switch.json'
        Assert-Vkd3dCompilerTestThrows {
            & $script:Writer -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot | Out-Null
        } 'explicit -Promote'
        if ([IO.File]::Exists($output)) {
            throw 'Writer created output without explicit promotion.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Writer public parameters exclude test hooks' {
        $command = Get-Command -Name $script:Writer -CommandType ExternalScript
        $internalNames = @(
            'ExpectedPreviousBytes', 'BeforeEvidenceVerification',
            'BeforeCandidateCreate', 'AfterCandidateCreate',
            'BeforePromotion', 'BeforeFinalVerification',
            'AfterFinalVerification', 'ForwardReplaceFault',
            'RollbackReplaceFault'
        )
        foreach ($name in $internalNames) {
            if ($command.Parameters.ContainsKey($name)) {
                throw "Writer exposes test hook '$name'."
            }
        }
        $writerTokens = $null
        $writerErrors = $null
        $writerAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:Writer,
            [ref]$writerTokens,
            [ref]$writerErrors
        )
        $publicNames = @($writerAst.ParamBlock.Parameters | ForEach-Object {
            $_.Name.VariablePath.UserPath
        })
        if ($writerErrors.Count -ne 0 -or
            ($publicNames -join ',') -cne
                'EvidenceFile,OutputFile,DriversRoot,Promote') {
            throw 'Writer public parameter surface changed.'
        }
        $internal = Get-Command Invoke-Vkd3dWriterPromotionInternal `
            -CommandType Function
        foreach ($name in $internalNames) {
            $parameter = $internal.Parameters[$name]
            if ($null -eq $parameter) {
                throw "Writer internal seam '$name' is missing."
            }
            $hidden = @($parameter.Attributes | Where-Object {
                $_ -is [Management.Automation.ParameterAttribute] -and
                $_.DontShow
            })
            if ($hidden.Count -ne 1) {
                throw "Writer internal seam '$name' is not closed and hidden."
            }
        }
    }
    Invoke-Vkd3dCompilerTest 'Writer holds evidence identity across verification' {
        $value = Copy-Vkd3dCompilerTestValue $valid
        $value.summary.source_files = [UInt64]39
        $path = Write-Vkd3dCompilerTestJson $value 'evidence-swap-race'
        [byte[]]$before = [IO.File]::ReadAllBytes($path)
        $output = Join-Path $script:FixtureRoot 'evidence-swap-output.json'
        $swap = {
            param($heldEvidencePath)
            try {
                [IO.File]::Delete($heldEvidencePath)
                [IO.File]::Copy($validPath, $heldEvidencePath, $false)
            }
            catch { throw 'synthetic evidence swap was blocked' }
        }
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $path -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -BeforeEvidenceVerification $swap | Out-Null
        } 'evidence swap was blocked'
        [byte[]]$after = [IO.File]::ReadAllBytes($path)
        if (-not (Test-Vkd3dWriterExactBytes $before $after) -or
            [IO.File]::Exists($output) -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'evidence-swap-output.json.*-*'
            )).Count -ne 0) {
            throw 'Writer allowed an evidence swap or retained transaction state.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Writer verifies, atomically copies, and reverifies' {
        $output = Join-Path $script:FixtureRoot 'promoted.json'
        $result = @(& $script:Writer -EvidenceFile $validPath `
            -OutputFile $output -DriversRoot $script:DriversRoot -Promote)
        if ($result.Count -ne 1 -or -not [IO.File]::Exists($output)) {
            throw 'Writer did not produce one verified output.'
        }
        [byte[]]$before = [IO.File]::ReadAllBytes($validPath)
        [byte[]]$after = [IO.File]::ReadAllBytes($output)
        if ([Convert]::ToBase64String($before) -cne
            [Convert]::ToBase64String($after) -or
            $after -contains [byte]13 -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'promoted.json.*-*'
            )).Count -ne 0) {
            throw 'Writer changed LF bytes or retained a transaction output.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Writer preserves differing public output' {
        $output = Join-Path $script:FixtureRoot 'promoted-existing.json'
        [byte[]]$previous = $script:Utf8.GetBytes("previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $initialHandle = Open-Vkd3dEvidenceStableHandle `
            $output 'public drift initial output'
        try {
            $initialIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $initialHandle 'public drift initial output' 1024
        }
        finally { $initialHandle.Dispose() }
        Assert-Vkd3dCompilerTestThrows {
            & $script:Writer -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote | Out-Null
        } 'public overwrite refused'
        $finalHandle = Open-Vkd3dEvidenceStableHandle `
            $output 'public drift preserved output'
        try {
            $finalIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $finalHandle 'public drift preserved output' 1024
        }
        finally { $finalHandle.Dispose() }
        if (-not (Test-Vkd3dWriterExactBytes `
                ([IO.File]::ReadAllBytes($output)) $previous) -or
            $finalIdentity.file_identity -cne $initialIdentity.file_identity -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'promoted-existing.json.*-*'
            )).Count -ne 0) {
            throw 'Public writer changed or removed differing output.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Writer accepts identical public output' {
        $output = Join-Path $script:FixtureRoot 'promoted-identical.json'
        [byte[]]$expected = [IO.File]::ReadAllBytes($validPath)
        [IO.File]::WriteAllBytes($output, $expected)
        $result = @(& $script:Writer -EvidenceFile $validPath `
            -OutputFile $output -DriversRoot $script:DriversRoot -Promote)
        if ($result.Count -ne 1 -or
            -not (Test-Vkd3dWriterExactBytes `
                ([IO.File]::ReadAllBytes($output)) $expected) -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'promoted-identical.json.*-*'
            )).Count -ne 0) {
            throw 'Public writer rejected or changed identical output.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Writer replaces an exactly expected existing output' {
        $output = Join-Path $script:FixtureRoot 'promoted-expected.json'
        [byte[]]$previous = $script:Utf8.GetBytes("expected-previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $result = @(Invoke-Vkd3dWriterPromotionInternal `
            -EvidenceFile $validPath -OutputFile $output `
            -DriversRoot $script:DriversRoot -Promote `
            -ExpectedPreviousBytes $previous)
        [byte[]]$expected = [IO.File]::ReadAllBytes($validPath)
        if ($result.Count -ne 1 -or
            -not (Test-Vkd3dWriterExactBytes `
                ([IO.File]::ReadAllBytes($output)) $expected) -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'promoted-expected.json.*-*'
            )).Count -ne 0) {
            throw 'Expected-output atomic replacement or cleanup changed.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Writer rejects incomplete cleanup before writing' {
        $value = Copy-Vkd3dCompilerTestValue $valid
        $value.summary.temporary_output_count = 1
        $path = Write-Vkd3dCompilerTestJson $value 'dirty-evidence'
        $output = Join-Path $script:FixtureRoot 'dirty-output.json'
        Assert-Vkd3dCompilerTestThrows {
            & $script:Writer -EvidenceFile $path -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote | Out-Null
        } 'nonzero'
        if ([IO.File]::Exists($output)) {
            throw 'Writer promoted incomplete cleanup evidence.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Writer preserves a raced-in unowned candidate' {
        $output = Join-Path $script:FixtureRoot 'candidate-race-output.json'
        $race = {
            param($candidatePath)
            [IO.File]::WriteAllText(
                $candidatePath,
                'foreign-candidate',
                [Text.UTF8Encoding]::new($false)
            )
        }
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -BeforeCandidateCreate $race | Out-Null
        } 'fresh and absent'
        $partials = @([IO.Directory]::EnumerateFiles(
            $script:FixtureRoot,
            'candidate-race-output.json.partial-*'
        ))
        if ($partials.Count -ne 1 -or
            [IO.File]::ReadAllText($partials[0]) -cne 'foreign-candidate' -or
            [IO.File]::Exists($output)) {
            throw 'Writer changed or removed the raced-in candidate.'
        }
        [IO.File]::Delete($partials[0])
    }

    Invoke-Vkd3dCompilerTest 'Writer preserves a same-byte post-create replacement' {
        $output = Join-Path $script:FixtureRoot `
            'candidate-replacement-output.json'
        $replace = {
            param($candidatePath)
            [IO.File]::Delete($candidatePath)
            [IO.File]::WriteAllBytes(
                $candidatePath,
                [IO.File]::ReadAllBytes($validPath)
            )
        }
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -AfterCandidateCreate $replace | Out-Null
        } 'both failed'
        $partials = @([IO.Directory]::EnumerateFiles(
            $script:FixtureRoot,
            'candidate-replacement-output.json.partial-*'
        ))
        if ($partials.Count -ne 1 -or
            [Convert]::ToBase64String(
                [IO.File]::ReadAllBytes($partials[0])
            ) -cne [Convert]::ToBase64String(
                [IO.File]::ReadAllBytes($validPath)
            ) -or
            [IO.File]::Exists($output)) {
            throw 'Writer removed a same-byte post-create replacement.'
        }
        [IO.File]::Delete($partials[0])
    }

    Invoke-Vkd3dCompilerTest 'Absent-output promotion preserves a raced-in file' {
        $output = Join-Path $script:FixtureRoot 'absent-promotion-race.json'
        $race = {
            param($promotedPath, $backupPath, $hadPrevious)
            if ($hadPrevious -or $null -ne $backupPath) {
                throw 'Absent promotion race seam changed.'
            }
            [IO.File]::WriteAllText(
                $promotedPath,
                'foreign-absent-race',
                [Text.UTF8Encoding]::new($false)
            )
        }
        $observed = $null
        try {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -BeforePromotion $race | Out-Null
        }
        catch { $observed = $_.Exception }
        if ($null -eq $observed -or
            [IO.File]::ReadAllText($output) -cne 'foreign-absent-race' -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'absent-promotion-race.json.*-*'
            )).Count -ne 0) {
            throw 'Absent-output atomic move overwrote or leaked raced state.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Existing-output promotion restores a same-byte race' {
        $output = Join-Path $script:FixtureRoot 'existing-promotion-race.json'
        [byte[]]$initialBytes = $script:Utf8.GetBytes("initial`n")
        [IO.File]::WriteAllBytes($output, $initialBytes)
        $initialHandle = Open-Vkd3dEvidenceStableHandle `
            $output 'initial promotion-race output'
        try {
            $initialIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $initialHandle 'initial promotion-race output' 1024
        }
        finally { $initialHandle.Dispose() }
        $race = {
            param($promotedPath, $backupPath, $hadPrevious)
            if (-not $hadPrevious -or
                [string]::IsNullOrWhiteSpace($backupPath)) {
                throw 'Existing promotion race seam changed.'
            }
            [IO.File]::Delete($promotedPath)
            [IO.File]::WriteAllText(
                $promotedPath,
                "initial`n",
                [Text.UTF8Encoding]::new($false)
            )
        }
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $initialBytes `
                -BeforePromotion $race | Out-Null
        } 'atomic compiler-closure backup changed'
        $restoredHandle = Open-Vkd3dEvidenceStableHandle `
            $output 'restored promotion-race output'
        try {
            $restoredIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $restoredHandle 'restored promotion-race output' 1024
        }
        finally { $restoredHandle.Dispose() }
        if ([IO.File]::ReadAllText($output, $script:Utf8) -cne
                "initial`n" -or
            $restoredIdentity.file_identity -ceq
                $initialIdentity.file_identity -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'existing-promotion-race.json.*-*'
            )).Count -ne 0) {
            throw 'Existing-output atomic replace did not restore the raced file.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Forward ReplaceFile 1177 state restores prior output' {
        $output = Join-Path $script:FixtureRoot 'forward-1177-output.json'
        [byte[]]$previous = $script:Utf8.GetBytes("forward-previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $initialHandle = Open-Vkd3dEvidenceStableHandle `
            $output 'forward 1177 initial output'
        try {
            $initialIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $initialHandle 'forward 1177 initial output' 1024
        }
        finally { $initialHandle.Dispose() }
        $fault = {
            param($candidatePath, $promotedPath, $backupPath)
            [IO.File]::Move($promotedPath, $backupPath, $false)
            throw 'synthetic ReplaceFileW 1177 forward post-state'
        }
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $previous `
                -ForwardReplaceFault $fault | Out-Null
        } '1177 forward post-state'
        $restoredHandle = Open-Vkd3dEvidenceStableHandle `
            $output 'forward 1177 restored output'
        try {
            $restoredIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $restoredHandle 'forward 1177 restored output' 1024
        }
        finally { $restoredHandle.Dispose() }
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($output)) -cne
                [Convert]::ToBase64String($previous) -or
            $restoredIdentity.file_identity -cne
                $initialIdentity.file_identity -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'forward-1177-output.json.*-*'
            )).Count -ne 0) {
            throw 'Forward 1177 reconciliation lost prior state or leaked leaves.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Forward replace preserves a foreign backup leaf' {
        $output = Join-Path $script:FixtureRoot `
            'forward-foreign-backup-output.json'
        [byte[]]$previous = $script:Utf8.GetBytes("forward-previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $fault = {
            param($candidatePath, $promotedPath, $backupPath)
            [IO.File]::Move($promotedPath, $backupPath, $false)
            [byte[]]$bytes = [IO.File]::ReadAllBytes($backupPath)
            [IO.File]::Delete($backupPath)
            [IO.File]::WriteAllBytes($backupPath, $bytes)
            throw 'synthetic foreign forward backup'
        }
        $observed = $null
        try {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $previous `
                -ForwardReplaceFault $fault | Out-Null
        }
        catch { $observed = $_.Exception }
        $backups = @([IO.Directory]::EnumerateFiles(
            $script:FixtureRoot,
            'forward-foreign-backup-output.json.backup-*'
        ))
        $partials = @([IO.Directory]::EnumerateFiles(
            $script:FixtureRoot,
            'forward-foreign-backup-output.json.partial-*'
        ))
        if ($observed -isnot [AggregateException] -or
            [IO.File]::Exists($output) -or $backups.Count -ne 1 -or
            $partials.Count -ne 0 -or
            [Convert]::ToBase64String(
                [IO.File]::ReadAllBytes($backups[0])
            ) -cne [Convert]::ToBase64String($previous)) {
            throw 'Writer adopted, removed, or changed a foreign backup leaf.'
        }
        Assert-Vkd3dEvidenceNoPrivatePathText `
            $observed.ToString() 'foreign forward backup aggregate'
        [IO.File]::Delete($backups[0])
    }

    Invoke-Vkd3dCompilerTest 'Writer restores exact previous bytes after final failure' {
        $output = Join-Path $script:FixtureRoot 'rollback-output.json'
        [byte[]]$previous = $script:Utf8.GetBytes("previous-bytes`n")
        [IO.File]::WriteAllBytes($output, $previous)
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $previous `
                -BeforeFinalVerification { throw 'synthetic final failure' } |
                Out-Null
        } 'synthetic final failure'
        [byte[]]$restored = [IO.File]::ReadAllBytes($output)
        if ([Convert]::ToBase64String($restored) -cne
                [Convert]::ToBase64String($previous) -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot,
                'rollback-output.json.*-*'
            )).Count -ne 0) {
            throw 'Writer did not restore exact prior bytes and clean transactions.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Rollback ReplaceFile 1177 state restores prior output' {
        $output = Join-Path $script:FixtureRoot 'rollback-1177-output.json'
        [byte[]]$previous = $script:Utf8.GetBytes("rollback-previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $initialHandle = Open-Vkd3dEvidenceStableHandle `
            $output 'rollback 1177 initial output'
        try {
            $initialIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $initialHandle 'rollback 1177 initial output' 1024
        }
        finally { $initialHandle.Dispose() }
        $fault = {
            param($backupPath, $promotedPath, $displacedPath)
            [IO.File]::Move($promotedPath, $displacedPath, $false)
            throw 'synthetic ReplaceFileW 1177 rollback post-state'
        }
        $observed = $null
        try {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $previous `
                -BeforeFinalVerification {
                    throw 'synthetic final failure before 1177 rollback'
                } -RollbackReplaceFault $fault | Out-Null
        }
        catch { $observed = $_.Exception }
        if ($null -eq $observed -or
            $observed -isnot [AggregateException] -or
            $observed.InnerExceptions.Count -ne 2) {
            throw 'Rollback 1177 did not retain primary and replace failures.'
        }
        Assert-Vkd3dEvidenceNoPrivatePathText `
            $observed.ToString() 'rollback 1177 aggregate'
        $restoredHandle = Open-Vkd3dEvidenceStableHandle `
            $output 'rollback 1177 restored output'
        try {
            $restoredIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $restoredHandle 'rollback 1177 restored output' 1024
        }
        finally { $restoredHandle.Dispose() }
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($output)) -cne
                [Convert]::ToBase64String($previous) -or
            $restoredIdentity.file_identity -cne
                $initialIdentity.file_identity -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'rollback-1177-output.json.*-*'
            )).Count -ne 0) {
            throw 'Rollback 1177 reconciliation lost prior state or leaked leaves.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Writer rejects verifier-valid post-verification byte drift' {
        $output = Join-Path $script:FixtureRoot 'valid-byte-drift-output.json'
        [byte[]]$previous = $script:Utf8.GetBytes("previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $drift = {
            param($promotedPath)
            $value = Get-Content -Raw -LiteralPath $promotedPath |
                ConvertFrom-Json
            $compact = ($value | ConvertTo-Json -Depth 40 -Compress) + "`n"
            [IO.File]::WriteAllText(
                $promotedPath,
                $compact,
                [Text.UTF8Encoding]::new($false)
            )
            $verified = @(& $script:Verifier -ClosureFile $promotedPath `
                -DriversRoot $script:DriversRoot)
            if ($verified.Count -ne 1) {
                throw 'Verifier-valid drift fixture failed verification.'
            }
        }
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $previous `
                -AfterFinalVerification $drift | Out-Null
        } 'after final verification changed'
        $observedBytes = [IO.File]::ReadAllBytes($output)
        $evidenceBytes = [IO.File]::ReadAllBytes($validPath)
        if ([Convert]::ToBase64String($observedBytes) -ceq
                [Convert]::ToBase64String($evidenceBytes) -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'valid-byte-drift-output.json.*-*'
            )).Count -ne 0) {
            throw 'Writer accepted or failed to preserve verifier-valid byte drift.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Writer preserves drift and combines rollback failure' {
        $output = Join-Path $script:FixtureRoot 'rollback-drift-output.json'
        [byte[]]$previous = $script:Utf8.GetBytes("previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $drift = {
            param($promotedPath)
            [IO.File]::WriteAllText(
                $promotedPath,
                'foreign-drift',
                [Text.UTF8Encoding]::new($false)
            )
            throw 'synthetic primary C:\Users\private\failure'
        }
        $observed = $null
        try {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $previous `
                -BeforeFinalVerification $drift | Out-Null
        }
        catch { $observed = $_.Exception }
        if ($null -eq $observed -or
            $observed -isnot [AggregateException] -or
            $observed.InnerExceptions.Count -ne 2) {
            throw 'Writer did not preserve primary and rollback failures together.'
        }
        $rendered = $observed.ToString()
        Assert-Vkd3dEvidenceNoPrivatePathText `
            $rendered 'writer combined failure'
        if ([IO.File]::ReadAllText($output, $script:Utf8) -cne
                'foreign-drift' -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot,
                'rollback-drift-output.json.*-*'
            )).Count -ne 0) {
            throw 'Writer changed drifted output or retained a transaction file.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Writer preserves a same-byte replaced atomic backup' {
        $output = Join-Path $script:FixtureRoot 'backup-replacement-output.json'
        [byte[]]$previous = $script:Utf8.GetBytes("previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $replace = {
            param($promotedPath)
            $backup = @([IO.Directory]::EnumerateFiles(
                [IO.Path]::GetDirectoryName($promotedPath),
                ([IO.Path]::GetFileName($promotedPath) + '.backup-*')
            ))
            if ($backup.Count -ne 1) {
                throw 'Atomic backup replacement fixture changed.'
            }
            [IO.File]::Delete($backup[0])
            [IO.File]::WriteAllText(
                $backup[0],
                "previous`n",
                [Text.UTF8Encoding]::new($false)
            )
            throw 'synthetic backup replacement failure'
        }
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $previous `
                -BeforeFinalVerification $replace | Out-Null
        } 'both failed'
        $backups = @([IO.Directory]::EnumerateFiles(
            $script:FixtureRoot,
            'backup-replacement-output.json.backup-*'
        ))
        if ($backups.Count -ne 1 -or
            [IO.File]::ReadAllText($backups[0]) -cne "previous`n") {
            throw 'Writer removed a same-byte replaced atomic backup.'
        }
        [IO.File]::Delete($backups[0])
    }

    Invoke-Vkd3dCompilerTest 'Primary-only writer failure redacts private paths' {
        $output = Join-Path $script:FixtureRoot 'primary-private-output.json'
        [byte[]]$previous = $script:Utf8.GetBytes("previous`n")
        [IO.File]::WriteAllBytes($output, $previous)
        $observed = $null
        try {
            Invoke-Vkd3dWriterPromotionInternal `
                -EvidenceFile $validPath -OutputFile $output `
                -DriversRoot $script:DriversRoot -Promote `
                -ExpectedPreviousBytes $previous `
                -BeforeFinalVerification {
                    throw 'synthetic C:\Users\private\primary-only'
                } | Out-Null
        }
        catch { $observed = $_.Exception }
        if ($null -eq $observed -or $observed -is [AggregateException]) {
            throw 'Primary-only writer failure boundary changed.'
        }
        Assert-Vkd3dEvidenceNoPrivatePathText `
            $observed.ToString() 'primary-only writer failure'
        if ([IO.File]::ReadAllText($output, $script:Utf8) -cne
                "previous`n" -or
            @([IO.Directory]::EnumerateFiles(
                $script:FixtureRoot, 'primary-private-output.json.*-*'
            )).Count -ne 0) {
            throw 'Primary-only failure did not restore and clean exact state.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Writer lifecycle guards are explicit' {
        $writerText = [IO.File]::ReadAllText(
            $script:Writer,
            [Text.UTF8Encoding]::new($false, $true)
        )
        foreach ($required in @(
            '$candidateCreated = $false',
            '$promoted = $false',
            '$backupCreated = $false',
            '$displacedCreated = $false',
            '$candidateCreated = $true',
            '$backupCreated = $true',
            '$displacedCreated = $true',
            '[IO.FileMode]::CreateNew',
            '[IO.File]::Replace(',
            '[IO.File]::Move($temporaryPath, $outputPath, $false)',
            'Assert-Vkd3dEvidenceFreshMutationBoundary',
            'Remove-Vkd3dWriterExactOwnedLeaf',
            '-ExpectedFileIdentity $FileIdentity',
            'Test-Vkd3dWriterExactBytes',
            '$PSBoundParameters.ContainsKey(''ExpectedPreviousBytes'')',
            '$evidenceHandle = Open-Vkd3dEvidenceStableHandle',
            '$evidenceBeforeIdentity = Get-Vkd3dEvidenceHandleIdentity',
            'ConvertFrom-GswStrictJsonUtf8Bytes',
            '$evidenceAfterIdentity = Get-Vkd3dEvidenceHandleIdentity',
            '$evidenceAfterBytes',
            '$evidenceHandle.Dispose()',
            "'evidence; public overwrite refused.'",
            '$candidateFileIdentity = $candidateIdentity.file_identity',
            '$candidateObservation = Get-Vkd3dWriterLeafObservation',
            '$displacedObservation =',
            'ForwardReplaceFault',
            'RollbackReplaceFault',
            "'restored partial forward-replace destination'",
            "'restored partial rollback destination'",
            "'Forward replace left an unknown destination state.'",
            "'Rollback replace left an unknown destination state.'",
            "'promoted compiler closure before final verification'",
            "'promoted compiler closure after final verification'",
            'New-Vkd3dWriterPrimaryFailure',
            'New-Vkd3dEvidenceCombinedFailure'
        )) {
            if (-not $writerText.Contains(
                    $required,
                    [StringComparison]::Ordinal
                )) {
                throw "Writer is missing lifecycle fragment '$required'."
            }
        }
        $evidenceOpenAt = $writerText.IndexOf(
            '$evidenceHandle = Open-Vkd3dEvidenceStableHandle',
            [StringComparison]::Ordinal
        )
        $evidenceParseAt = $writerText.IndexOf(
            'ConvertFrom-GswStrictJsonUtf8Bytes',
            $evidenceOpenAt + 1,
            [StringComparison]::Ordinal
        )
        $evidenceVerifyAt = $writerText.IndexOf(
            '$preflight = @(& $verifier',
            $evidenceParseAt + 1,
            [StringComparison]::Ordinal
        )
        $evidenceAfterAt = $writerText.IndexOf(
            '$evidenceAfterIdentity = Get-Vkd3dEvidenceHandleIdentity',
            $evidenceVerifyAt + 1,
            [StringComparison]::Ordinal
        )
        $evidenceDisposeAt = $writerText.IndexOf(
            '$evidenceHandle.Dispose()',
            $evidenceAfterAt + 1,
            [StringComparison]::Ordinal
        )
        if ($evidenceOpenAt -lt 0 -or $evidenceParseAt -lt 0 -or
            $evidenceVerifyAt -lt 0 -or $evidenceAfterAt -lt 0 -or
            $evidenceDisposeAt -lt 0) {
            throw 'Writer does not hold evidence identity across verification.'
        }
        $forwardRethrowAt = $writerText.IndexOf(
            'throw $forwardReplaceFailure',
            [StringComparison]::Ordinal
        )
        $forwardCandidateAt = $writerText.IndexOf(
            '$candidateCreated = $false',
            $forwardRethrowAt + 1,
            [StringComparison]::Ordinal
        )
        $forwardPromotedAt = $writerText.IndexOf(
            '$promoted = $true',
            $forwardCandidateAt + 1,
            [StringComparison]::Ordinal
        )
        $forwardBackupAt = $writerText.IndexOf(
            '$backupCreated = $true',
            $forwardPromotedAt + 1,
            [StringComparison]::Ordinal
        )
        $forwardBackupReadAt = $writerText.IndexOf(
            '$backup = Read-Vkd3dWriterStableFile',
            $forwardBackupAt + 1,
            [StringComparison]::Ordinal
        )
        if ($forwardRethrowAt -lt 0 -or $forwardCandidateAt -lt 0 -or
            $forwardPromotedAt -lt 0 -or $forwardBackupAt -lt 0 -or
            $forwardBackupReadAt -lt 0) {
            throw 'Forward replacement validation remains inside reconciliation.'
        }
        $rollbackRethrowAt = $writerText.IndexOf(
            'throw $rollbackReplaceFailure',
            [StringComparison]::Ordinal
        )
        $rollbackBackupAt = $writerText.IndexOf(
            '$backupCreated = $false',
            $rollbackRethrowAt + 1,
            [StringComparison]::Ordinal
        )
        $rollbackPromotedAt = $writerText.IndexOf(
            '$promoted = $false',
            $rollbackBackupAt + 1,
            [StringComparison]::Ordinal
        )
        $rollbackDisplacedAt = $writerText.IndexOf(
            '$displacedCreated = $true',
            $rollbackPromotedAt + 1,
            [StringComparison]::Ordinal
        )
        $rollbackValidationAt = $writerText.IndexOf(
            "'restored compiler closure'",
            $rollbackDisplacedAt + 1,
            [StringComparison]::Ordinal
        )
        if ($rollbackRethrowAt -lt 0 -or $rollbackBackupAt -lt 0 -or
            $rollbackPromotedAt -lt 0 -or $rollbackDisplacedAt -lt 0 -or
            $rollbackValidationAt -lt 0) {
            throw 'Rollback validation remains inside reconciliation.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Generated normalization proves exact modes' {
        $noneBytes = $script:Utf8.GetBytes("alpha`nbeta`n")
        $none = Get-Vkd3dEvidenceGeneratedNormalization `
            'include/config.h' $noneBytes 'synthetic no-op output'
        if ($none.Mode -cne 'none' -or -not $none.Proven -or
            $none.Raw.sha256 -cne $none.Canonical.sha256 -or
            [UInt64]$none.RemovedCrBytes -ne 0) {
            throw 'No-op generated normalization proof changed.'
        }
        $widlBytes = $script:Utf8.GetBytes("alpha`r`nbeta`r`n")
        $widl = Get-Vkd3dEvidenceGeneratedNormalization `
            'include/vkd3d_d3dcommon.h' $widlBytes 'synthetic WIDL output'
        if ($widl.Mode -cne 'crlf-to-lf' -or -not $widl.Proven -or
            [UInt64]$widl.Raw.crlf_count -ne 2 -or
            [UInt64]$widl.Canonical.lf_only_count -ne 2 -or
            [UInt64]$widl.RemovedCrBytes -ne 2 -or
            [UInt64]$widl.Raw.bytes -ne
                ([UInt64]$widl.Canonical.bytes + 2)) {
            throw 'CRLF-to-LF generated normalization proof changed.'
        }
    }
    foreach ($case in @(
        @('WIDL mixed newlines', "alpha`r`nbeta`n", 'strict CRLF-only'),
        @('WIDL LF-only newlines', "alpha`nbeta`n", 'strict CRLF-only'),
        @('WIDL lone CR', "alpha`rbravo`r`n", 'strict CRLF-only'),
        @('No-op CRLF drift', "alpha`r`nbeta`r`n", 'unexpectedly requires newline normalization')
    )) {
        $name = [string]$case[0]
        $path = if ($name.StartsWith('No-op', [StringComparison]::Ordinal)) {
            'include/config.h'
        }
        else { 'include/vkd3d_d3dcommon.h' }
        Invoke-Vkd3dCompilerTest "$name is rejected" {
            [byte[]]$bytes = $script:Utf8.GetBytes([string]$case[1])
            Assert-Vkd3dCompilerTestThrows {
                Get-Vkd3dEvidenceGeneratedNormalization $path $bytes $name |
                    Out-Null
            } ([string]$case[2])
        }
    }
    foreach ($case in @(
        @('UTF-8 BOM', [byte[]](0xef, 0xbb, 0xbf, 0x61, 0x0d, 0x0a),
            'UTF-8 BOM'),
        @('NUL byte', [byte[]](0x61, 0x00, 0x0d, 0x0a), 'NUL bytes'),
        @('invalid UTF-8', [byte[]](0xff, 0x0d, 0x0a), 'strict UTF-8')
    )) {
        $name = [string]$case[0]
        Invoke-Vkd3dCompilerTest "WIDL $name is rejected" {
            Assert-Vkd3dCompilerTestThrows {
                Get-Vkd3dEvidenceGeneratedNormalization `
                    'include/vkd3d_d3dcommon.h' ([byte[]]$case[1]) $name |
                    Out-Null
            } ([string]$case[2])
        }
    }
    Invoke-Vkd3dCompilerTest 'Canonical HTTPS repository URLs are allowed' {
        Assert-Vkd3dEvidenceNoPrivatePathText `
            'https://gitlab.winehq.org/wine/vkd3d.git' 'repository URL'
    }

    Invoke-Vkd3dCompilerMutationTest 'Unknown top-level fields are rejected' `
        $valid { param($v) $v | Add-Member NoteProperty unknown $false } `
        'fields do not match'
    Invoke-Vkd3dCompilerMutationTest 'Schema binding drift is rejected' `
        $valid { param($v) $v.schema_definition.sha256 = '0' * 64 } `
        'schema binding changed'
    Invoke-Vkd3dCompilerMutationTest 'Component binding drift is rejected' `
        $valid { param($v) $v.source.component_manifest.sha256 = '0' * 64 } `
        'input binding drifted'
    Invoke-Vkd3dCompilerMutationTest 'Toolchain lock drift is rejected' `
        $valid { param($v) $v.toolchain.lock.bytes++ } `
        'input binding drifted'
    Invoke-Vkd3dCompilerMutationTest 'Mesa manifest drift is rejected' `
        $valid { param($v) $v.cross_component_inputs.component_manifest.sha256 = '0' * 64 } `
        'input binding drifted'
    Invoke-Vkd3dCompilerMutationTest 'Source checkout detachment is required' `
        $valid { param($v) $v.source_pair.checkouts[0].detached = $false } `
        'checkout 0 changed'
    Invoke-Vkd3dCompilerMutationTest 'Canonical LF CRLF pairing is required' `
        $valid { param($v) $v.source_pair.files[0].crlf_count++ } `
        'canonical source file 1 changed'
    Invoke-Vkd3dCompilerMutationTest 'Source file order is exact' `
        $valid { param($v) $v.source_pair.files[1] = $v.source_pair.files[0] } `
        'canonical source file 2 changed'
    Invoke-Vkd3dCompilerMutationTest 'Cross-component MIT licensing is exact' `
        $valid { param($v) $v.cross_component_inputs.files[0].license_expression = 'LGPL-2.1-or-later' } `
        'SPIR-V input 1 changed'
    Invoke-Vkd3dCompilerMutationTest 'Cross-component row order is exact' `
        $valid { param($v) $x=$v.cross_component_inputs.files[0]; $v.cross_component_inputs.files[0]=$v.cross_component_inputs.files[1]; $v.cross_component_inputs.files[1]=$x } `
        'SPIR-V input 1 changed'
    Invoke-Vkd3dCompilerMutationTest 'Tool roots cannot widen' `
        $valid { param($v) $v.toolchain.roots += [pscustomobject]@{ id='package_cache'; verified=$true } } `
        'toolchain evidence inventory changed'
    Invoke-Vkd3dCompilerMutationTest 'Tool probes remain bound to lock order' `
        $valid { param($v) $v.toolchain.probes[0].file_id = 'ucrt-gcc' } `
        'probe 0 changed'
    Invoke-Vkd3dCompilerMutationTest 'Compiler children remain sequential' `
        $valid { param($v) $v.toolchain.process_limits.maximum_top_level_processes = 2 } `
        'process limit'
    Invoke-Vkd3dCompilerMutationTest 'Ambient library paths remain absent' `
        $valid { param($v) $v.toolchain.environment.ambient_library_paths = $true } `
        'environment changed'
    Invoke-Vkd3dCompilerMutationTest 'Generated output licensing is exact' `
        $valid { param($v) $v.generated_runs[0].outputs[0].license_expression = 'MIT' } `
        'generated output 1 changed'
    Invoke-Vkd3dCompilerMutationTest 'Generated provenance is exact' `
        $valid { param($v) $v.generated_runs[0].outputs[8].provenance = 'unknown' } `
        'generated output 9 changed'
    Invoke-Vkd3dCompilerMutationTest 'WIDL raw identity is exact' `
        $valid { param($v) $v.generated_runs[0].outputs[6].raw_sha256 = 'f' * 64 } `
        'WIDL output 7 normalization changed'
    Invoke-Vkd3dCompilerMutationTest 'WIDL CRLF counts are exact' `
        $valid { param($v) $v.generated_runs[0].outputs[6].raw_crlf_count-- } `
        'generated output 7 changed'
    Invoke-Vkd3dCompilerMutationTest 'WIDL LF-only mixtures are rejected' `
        $valid { param($v) $v.generated_runs[0].outputs[6].raw_lf_only_count++; $v.generated_runs[0].outputs[6].raw_lf_count++ } `
        'WIDL output 7 normalization changed'
    Invoke-Vkd3dCompilerMutationTest 'WIDL lone CR bytes are rejected' `
        $valid { param($v) $v.generated_runs[0].outputs[6].raw_cr_only_count++ } `
        'WIDL output 7 normalization changed'
    Invoke-Vkd3dCompilerMutationTest 'WIDL removed-CR relation is exact' `
        $valid { param($v) $v.generated_runs[0].outputs[6].removed_cr_bytes-- } `
        'WIDL output 7 normalization changed'
    Invoke-Vkd3dCompilerMutationTest 'WIDL canonical identity is exact' `
        $valid { param($v) $v.generated_runs[0].outputs[6].sha256 = 'f' * 64 } `
        'WIDL output 7 normalization changed'
    Invoke-Vkd3dCompilerMutationTest 'WIDL normalization mode is exact' `
        $valid { param($v) $v.generated_runs[0].outputs[6].normalization = 'none' } `
        'normalization changed'
    Invoke-Vkd3dCompilerMutationTest 'Non-WIDL normalization remains none' `
        $valid { param($v) $v.generated_runs[0].outputs[0].normalization = 'crlf-to-lf' } `
        'normalization changed'
    Invoke-Vkd3dCompilerMutationTest 'Raw BOM evidence remains false' `
        $valid { param($v) $v.generated_runs[0].outputs[6].raw_utf8_bom = $true } `
        'generated output 7 changed'
    Invoke-Vkd3dCompilerMutationTest 'Canonical BOM evidence remains false' `
        $valid { param($v) $v.generated_runs[0].outputs[6].utf8_bom = $true } `
        'generated output 7 changed'
    Invoke-Vkd3dCompilerMutationTest 'Normalization proof is mandatory' `
        $valid { param($v) $v.generated_runs[0].outputs[6].normalization_proven = $false } `
        'generated output 7 changed'
    Invoke-Vkd3dCompilerMutationTest 'Raw generated aggregates are recomputed' `
        $valid { param($v) $v.generated_runs[0].raw_aggregate_sha256 = 'f' * 64 } `
        'raw aggregate changed'
    Invoke-Vkd3dCompilerMutationTest 'Twin raw and canonical outputs must match' `
        $valid {
            param($v)
            $v.generated_runs[1].outputs[0].raw_sha256 = 'f' * 64
            $v.generated_runs[1].outputs[0].sha256 = 'f' * 64
            Set-Vkd3dCompilerTestGeneratedAggregates $v.generated_runs[1]
        } `
        'Twin generated outputs'
    Invoke-Vkd3dCompilerMutationTest 'Generated command failures are rejected' `
        $valid { param($v) $v.generated_runs[0].generator_commands[0].exit_code = 1 } `
        'generated command 1 changed'
    Invoke-Vkd3dCompilerMutationTest 'Non-SPIR-V generator stdout hash is empty' `
        $valid { param($v) $v.generated_runs[0].generator_commands[0].stdout_sha256 = 'a' * 64 } `
        'unexpected output'
    Invoke-Vkd3dCompilerMutationTest 'Compile recipe requires dependency emission' `
        $valid { param($v) $v.recipe.compile_arguments = @($v.recipe.compile_arguments | Where-Object { $_ -cne '-MD' }) } `
        'compiler or objdump arguments changed'
    Invoke-Vkd3dCompilerMutationTest 'Compile recipe remains proof-only no-LTO' `
        $valid { param($v) $a=@($v.recipe.compile_arguments); $i=[Array]::IndexOf($a,'-fno-lto'); $a[$i]='-flto=auto'; $v.recipe.compile_arguments=$a } `
        'compiler or objdump arguments changed'
    Invoke-Vkd3dCompilerMutationTest 'Generated include precedence is exact' `
        $valid { param($v) $a=@($v.recipe.compile_arguments); $i=[Array]::IndexOf($a,'-I{generated_root}/include'); $j=[Array]::IndexOf($a,'-I{source_root}/include'); $x=$a[$i];$a[$i]=$a[$j];$a[$j]=$x;$v.recipe.compile_arguments=$a } `
        'compiler or objdump arguments changed'
    Invoke-Vkd3dCompilerMutationTest 'Compilation unit order is exact' `
        $valid { param($v) $v.recipe.compilation_units[0].input = 'libs/vkd3d-shader/d3d_asm.c' } `
        'compilation unit 1 changed'
    Invoke-Vkd3dCompilerMutationTest 'Command arguments remain deterministic' `
        $valid { param($v) $v.commands[0].arguments[0] = '-Wextra' } `
        'arguments changed'
    Invoke-Vkd3dCompilerMutationTest 'Twin depfile sets must match' `
        $valid { param($v) $v.commands[0].runs[1].dependency_file.files[0].sha256 = 'a' * 64 } `
        'changed from its reviewed input'
    Invoke-Vkd3dCompilerMutationTest 'Dependency counts are recomputed' `
        $valid { param($v) $v.commands[0].runs[0].dependency_file.dependency_count++ } `
        'dependency evidence changed'
    Invoke-Vkd3dCompilerMutationTest 'Dependency count decrements are rejected' `
        $valid { param($v) $v.commands[0].runs[0].dependency_file.dependency_count-- } `
        'dependency evidence changed'
    Invoke-Vkd3dCompilerMutationTest 'Unique dependency counts are recomputed' `
        $valid { param($v) $v.commands[0].runs[0].dependency_file.unique_dependency_count++ } `
        'dependency evidence changed'
    Invoke-Vkd3dCompilerMutationTest 'Unique dependency count decrements are rejected' `
        $valid { param($v) $v.commands[0].runs[0].dependency_file.unique_dependency_count-- } `
        'dependency evidence changed'
    Invoke-Vkd3dCompilerMutationTest 'Removed dependency rows are rejected' `
        $valid {
            param($v)
            $rows = @($v.commands[0].runs[0].dependency_file.files)
            $v.commands[0].runs[0].dependency_file.files =
                @($rows | Select-Object -Skip 1)
        } `
        'dependency evidence changed'
    Invoke-Vkd3dCompilerMutationTest 'Added dependency rows are rejected' `
        $valid {
            param($v)
            $v.commands[0].runs[0].dependency_file.files +=
                [pscustomobject][ordered]@{
                    relative_path = '{ucrt64}/include/zzzz.h'
                    occurrence_count = [UInt64]1
                    bytes = [UInt64]64
                    sha256 = Get-Vkd3dCompilerTestHash 'added-dependency'
                }
        } `
        'dependency evidence changed'
    Invoke-Vkd3dCompilerMutationTest 'Zero dependency multiplicity is rejected' `
        $valid { param($v) $v.commands[0].runs[0].dependency_file.files[0].occurrence_count = 0 } `
        'dependency multiplicity changed'
    Invoke-Vkd3dCompilerMutationTest 'Oversized dependency multiplicity is rejected' `
        $valid { param($v) $v.commands[0].runs[0].dependency_file.files[0].occurrence_count = 4097 } `
        'dependency multiplicity changed'
    Invoke-Vkd3dCompilerMutationTest 'Dependency multiplicity redistribution changes its aggregate' `
        $valid {
            param($v)
            $rows = @($v.commands[0].runs[0].dependency_file.files)
            $repeated = @($rows | Where-Object {
                $_.relative_path -ceq '{ucrt64}/include/pshpack4.h'
            })[0]
            $other = @($rows | Where-Object {
                $_.relative_path -cne '{ucrt64}/include/pshpack4.h'
            })[0]
            $repeated.occurrence_count--
            $other.occurrence_count++
        } `
        'dependency evidence changed'
    Invoke-Vkd3dCompilerMutationTest 'Twin-only dependency multiplicity drift is rejected' `
        $valid {
            param($v)
            $depfile = $v.commands[0].runs[1].dependency_file
            $depfile.files[0].occurrence_count++
            Set-Vkd3dCompilerTestDependencyFile $depfile
        } `
        'twin dependencies'
    Invoke-Vkd3dCompilerMutationTest 'Duplicate dependency rows are rejected' `
        $valid {
            param($v)
            $depfile = $v.commands[0].runs[0].dependency_file
            $depfile.files[1] = Copy-Vkd3dCompilerTestValue `
                $depfile.files[0]
        } `
        'not in ordinal order'
    Invoke-Vkd3dCompilerMutationTest 'Unknown dependency roots are rejected' `
        $valid {
            param($v)
            foreach ($run in @($v.commands[0].runs)) {
                $files = @($run.dependency_file.files)
                $files[$files.Count - 1].relative_path = '{zzzz}/secret.h'
                $run.dependency_file.aggregate_sha256 =
                    Get-Vkd3dEvidenceDependencyMultiplicitySha256 $files
            }
        } `
        'unknown logical root'
    Invoke-Vkd3dCompilerMutationTest 'Wrong COFF machines are rejected' `
        $valid { param($v) $v.commands[0].runs[0].object.machine = 332 } `
        'malformed AMD64 COFF'
    Invoke-Vkd3dCompilerMutationTest 'Twin normalized objects must match' `
        $valid { param($v) $v.commands[0].runs[1].object.normalized_sha256 = 'b' * 64 } `
        'twin object validation differs'
    Invoke-Vkd3dCompilerMutationTest 'Objdump format evidence is locked' `
        $valid { param($v) $v.commands[0].runs[0].objdump.format = 'pei-x86-64' } `
        'objdump evidence changed'
    Invoke-Vkd3dCompilerMutationTest 'Twin objdump byte counts must match' `
        $valid { param($v) $v.commands[0].runs[1].objdump.stdout_bytes++ } `
        'twin object validation differs'
    Invoke-Vkd3dCompilerMutationTest 'Twin objdump hashes must match' `
        $valid { param($v) $v.commands[0].runs[1].objdump.stdout_sha256 = 'b' * 64 } `
        'twin object validation differs'
    Invoke-Vkd3dCompilerMutationTest 'Object identities remain collision-free' `
        $valid { param($v) $v.commands[1].runs[0].object.relative_path = $v.commands[0].runs[0].object.relative_path; $v.commands[1].runs[1].object.relative_path = $v.commands[0].runs[0].object.relative_path } `
        'malformed AMD64 COFF'
    Invoke-Vkd3dCompilerMutationTest 'Object aggregate hashes are recomputed' `
        $valid { param($v) $v.comparison.normalized_objects.aggregate_sha256 = '0' * 64 } `
        'comparison aggregates changed'
    Invoke-Vkd3dCompilerMutationTest 'Dynamic dependency totals are recomputed' `
        $valid { param($v) $v.comparison.dependencies.unique_count++ } `
        'comparison aggregates changed'
    Invoke-Vkd3dCompilerMutationTest 'Dynamic dependency total decrements are rejected' `
        $valid { param($v) $v.comparison.dependencies.unique_count-- } `
        'comparison aggregates changed'
    Invoke-Vkd3dCompilerMutationTest 'Global dependency occurrences are recomputed' `
        $valid { param($v) $v.comparison.dependencies.occurrence_count++ } `
        'comparison aggregates changed'
    Invoke-Vkd3dCompilerMutationTest 'Global dependency occurrence decrements are rejected' `
        $valid { param($v) $v.comparison.dependencies.occurrence_count-- } `
        'comparison aggregates changed'
    Invoke-Vkd3dCompilerMutationTest 'Global dependency multiplicity aggregate is recomputed' `
        $valid { param($v) $v.comparison.dependencies.aggregate_sha256 = '0' * 64 } `
        'comparison aggregates changed'
    Invoke-Vkd3dCompilerMutationTest 'Raw generated comparison is bound' `
        $valid { param($v) $v.comparison.raw_generated_outputs.aggregate_sha256 = '0' * 64 } `
        'comparison aggregates changed'
    Invoke-Vkd3dCompilerMutationTest 'Temporary output retention is rejected' `
        $valid { param($v) $v.summary.temporary_output_count = 1 } `
        'summary or cleanup counts changed'
    Invoke-Vkd3dCompilerMutationTest 'Proof-root cleanup is required' `
        $valid { param($v) $v.summary.proof_root_removed = $false } `
        'summary or cleanup counts changed'
    Invoke-Vkd3dCompilerMutationTest 'Partial-output cleanup is required' `
        $valid { param($v) $v.summary.partial_evidence_removed = $false } `
        'summary or cleanup counts changed'
    Invoke-Vkd3dCompilerMutationTest 'Linker invocation count remains zero' `
        $valid { param($v) $v.summary.linker_invocations = 1 } `
        'summary or cleanup counts changed'
    Invoke-Vkd3dCompilerMutationTest 'Failed compile count remains zero' `
        $valid { param($v) $v.summary.failed_compile_commands = 1 } `
        'summary or cleanup counts changed'
    Invoke-Vkd3dCompilerMutationTest 'Child-process count is recomputed' `
        $valid { param($v) $v.summary.child_processes++ } `
        'summary or cleanup counts changed'
    Invoke-Vkd3dCompilerMutationTest 'Every authorization remains false' `
        $valid { param($v) $v.authorizations.production_build = $true } `
        'must remain false'
    Invoke-Vkd3dCompilerMutationTest 'Nested unknown fields are rejected' `
        $valid { param($v) $v.commands[0].runs[0].object | Add-Member NoteProperty optional_header 0 } `
        'fields do not match'
    Invoke-Vkd3dCompilerMutationTest 'Uppercase hashes are rejected' `
        $valid { param($v) $v.commands[0].runs[0].object.raw_sha256 = $v.commands[0].runs[0].object.raw_sha256.ToUpperInvariant() } `
        'lowercase SHA-256'
    Invoke-Vkd3dCompilerMutationTest 'Raw private drive paths are rejected' `
        $valid { param($v) $v.toolchain.probes[0].observed_lines[0] = 'C:\Users\private\tool' } `
        'private absolute path'
    Invoke-Vkd3dCompilerMutationTest 'JSON-escaped private paths are rejected' `
        $valid { param($v) $v.toolchain.probes[0].observed_lines[0] = 'C:\\Users\\private\\tool' } `
        'private absolute path'
    Invoke-Vkd3dCompilerMutationTest 'Private include-flag drive paths are rejected' `
        $valid { param($v) $v.commands[0].arguments[0] = '-IC:/Users/private/include' } `
        'private absolute path'
    Invoke-Vkd3dCompilerMutationTest 'Private prefix-map drive paths are rejected' `
        $valid { param($v) $v.commands[0].arguments[0] = '-ffile-prefix-map=C:/Users/private=source' } `
        'private absolute path'
    Invoke-Vkd3dCompilerMutationTest 'Private Unix include paths are rejected' `
        $valid { param($v) $v.commands[0].arguments[0] = '-I/tmp/private/include' } `
        'private absolute path'
    Invoke-Vkd3dCompilerMutationTest 'Private opt sysroots are rejected' `
        $valid { param($v) $v.commands[0].arguments[0] = '--sysroot=/opt/sdk' } `
        'private absolute path'
    Invoke-Vkd3dCompilerMutationTest 'Private mounted paths are rejected' `
        $valid { param($v) $v.commands[0].arguments[0] = '-I/mnt/c/sdk' } `
        'private absolute path'
    Invoke-Vkd3dCompilerMutationTest 'Private file URI drive paths are rejected' `
        $valid { param($v) $v.toolchain.probes[0].observed_lines[0] = 'file:///C:/Users/private/tool' } `
        'private absolute path'

    Invoke-Vkd3dCompilerTest 'Collector materializes collection helper results' {
        $collectorPath = Join-Path $PSScriptRoot `
            'collect-win98-vkd3d-shader-compiler-evidence.ps1'
        $tokens = $null
        $errors = $null
        $collectorAst = [Management.Automation.Language.Parser]::ParseFile(
            $collectorPath, [ref]$tokens, [ref]$errors
        )
        if ($errors.Count -ne 0) {
            throw 'Collector does not parse for collection-boundary inspection.'
        }
        foreach ($variable in @(
            'top',
            'actualGeneratedFiles', 'expectedGeneratedFiles',
            'actualSourceFiles', 'expectedSourceFiles',
            'sortedDependencyRows', 'rows', 'generatorRecipeEvidence'
        )) {
            $assignments = @($collectorAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is
                        [Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -ceq $variable
            }, $true))
            if ($assignments.Count -ne 1 -or
                $assignments[0].Right -isnot
                    [Management.Automation.Language.CommandExpressionAst] -or
                $assignments[0].Right.Expression -isnot
                    [Management.Automation.Language.ArrayExpressionAst]) {
                throw "Collector assignment '$variable' is not an explicit array."
            }
        }
    }

    Invoke-Vkd3dCompilerTest 'Collector does not shadow automatic input variable' {
        $collectorPath = Join-Path $PSScriptRoot `
            'collect-win98-vkd3d-shader-compiler-evidence.ps1'
        $tokens = $null
        $errors = $null
        $collectorAst = [Management.Automation.Language.Parser]::ParseFile(
            $collectorPath, [ref]$tokens, [ref]$errors
        )
        if ($errors.Count -ne 0) {
            throw 'Collector does not parse for reserved-variable inspection.'
        }
        $reservedInputReferences = @($collectorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.VariablePath.UserPath -ieq 'input'
        }, $true))
        if ($reservedInputReferences.Count -ne 0) {
            throw 'Collector shadows the automatic input variable.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Collector isolates byte and JSON snapshot variables' {
        $collectorPath = Join-Path $PSScriptRoot `
            'collect-win98-vkd3d-shader-compiler-evidence.ps1'
        $tokens = $null
        $errors = $null
        $collectorAst = [Management.Automation.Language.Parser]::ParseFile(
            $collectorPath, [ref]$tokens, [ref]$errors
        )
        if ($errors.Count -ne 0) {
            throw 'Collector does not parse for variable-isolation inspection.'
        }
        $collectorText = [IO.File]::ReadAllText(
            $collectorPath, [Text.UTF8Encoding]::new($false, $true)
        )
        foreach ($forbiddenAssignment in @(
            '[byte[]]$current = Read-Vkd3dEvidenceFileBytes',
            '$current = Read-GswStrictJsonFileSnapshot'
        )) {
            if ($collectorText.Contains(
                    $forbiddenAssignment, [StringComparison]::Ordinal
                )) {
                throw 'Collector reuses an ambiguous current-value variable.'
            }
        }
        foreach ($requiredVariable in @('currentMesaBytes', 'currentSnapshot')) {
            $assignments = @($collectorAst.FindAll({
                param($node)
                if ($node -isnot
                    [Management.Automation.Language.AssignmentStatementAst]) {
                    return $false
                }
                $leftVariable = $node.Left
                if ($leftVariable -is
                    [Management.Automation.Language.ConvertExpressionAst]) {
                    $leftVariable = $leftVariable.Child
                }
                return $leftVariable -is
                    [Management.Automation.Language.VariableExpressionAst] -and
                    $leftVariable.VariablePath.UserPath -ceq $requiredVariable
            }, $true))
            if ($assignments.Count -ne 1) {
                throw "Collector must assign '$requiredVariable' exactly once."
            }
        }
    }

    Invoke-Vkd3dCompilerTest 'Collector has no conflicting script type constraints' {
        $collectorPath = Join-Path $PSScriptRoot `
            'collect-win98-vkd3d-shader-compiler-evidence.ps1'
        $tokens = $null
        $errors = $null
        $collectorAst = [Management.Automation.Language.Parser]::ParseFile(
            $collectorPath, [ref]$tokens, [ref]$errors
        )
        if ($errors.Count -ne 0) {
            throw 'Collector does not parse for type-constraint inspection.'
        }
        $typed = @($collectorAst.FindAll({
            param($node)
            if ($node -isnot
                [Management.Automation.Language.AssignmentStatementAst] -or
                $node.Left -isnot
                [Management.Automation.Language.ConvertExpressionAst] -or
                $node.Left.Child -isnot
                [Management.Automation.Language.VariableExpressionAst]) {
                return $false
            }
            $parent = $node.Parent
            while ($null -ne $parent) {
                if ($parent -is
                    [Management.Automation.Language.FunctionDefinitionAst]) {
                    return $false
                }
                $parent = $parent.Parent
            }
            return $true
        }, $true) | ForEach-Object {
            [pscustomobject]@{
                name = $_.Left.Child.VariablePath.UserPath.ToLowerInvariant()
                type = $_.Left.Type.TypeName.FullName
            }
        })
        foreach ($group in @($typed | Group-Object name)) {
            if (@($group.Group.type | Sort-Object -Unique).Count -ne 1) {
                throw "Collector script variable '$($group.Name)' has conflicting types."
            }
        }
        $typedNames = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($row in $typed) { [void]$typedNames.Add($row.name) }
        $typedLoops = @($collectorAst.FindAll({
            param($node)
            if ($node -isnot
                [Management.Automation.Language.ForEachStatementAst]) {
                return $false
            }
            $parent = $node.Parent
            while ($null -ne $parent) {
                if ($parent -is
                    [Management.Automation.Language.FunctionDefinitionAst]) {
                    return $false
                }
                $parent = $parent.Parent
            }
            return $typedNames.Contains($node.Variable.VariablePath.UserPath)
        }, $true))
        if ($typedLoops.Count -ne 0) {
            throw 'Collector reuses a typed script variable as a foreach binding.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Collector retains exclusive proof ownership handles' {
        $collectorPath = Join-Path $PSScriptRoot `
            'collect-win98-vkd3d-shader-compiler-evidence.ps1'
        $collectorText = [IO.File]::ReadAllText(
            $collectorPath, [Text.UTF8Encoding]::new($false, $true)
        )
        $orderedFragments = @(
            '$proofOwnership = New-Vkd3dEvidenceOwnedDirectory',
            '$ownerToken = $proofOwnership.OwnerToken',
            '$proofRootHandle = $proofOwnership.RootHandle',
            '$ownerMarkerHandle = $proofOwnership.OwnerMarkerHandle'
        )
        $previous = -1
        foreach ($fragment in $orderedFragments) {
            $position = $collectorText.IndexOf(
                $fragment,
                [StringComparison]::Ordinal
            )
            if ($position -le $previous) {
                throw "Collector ownership fragment '$fragment' is missing or unordered."
            }
            $previous = $position
        }
        foreach ($required in @(
            '$proofRootHandle = $null',
            '$ownerMarkerHandle = $null',
            '-RootHandle $proofRootHandle',
            '-OwnerMarkerHandle $ownerMarkerHandle',
            '$proofRootHandle.IsInvalid',
            '$ownerMarkerHandle.IsInvalid',
            '$proofRootHandle.IsClosed',
            '$ownerMarkerHandle.IsClosed',
            'Proof ownership handles are incomplete; recursive cleanup refused.',
            '$partialCreated = $false',
            '$partialCreated = $true',
            'if ($partialCreated) {',
            '[IO.FileAccess]::ReadWrite',
            '$partialFileIdentity = $createdPartialIdentity.file_identity',
            '-ExpectedFileIdentity $partialFileIdentity',
            '[IO.File]::Move($partialOutput, $output, $false)',
            '[IO.Directory]::Exists($partialOutput)',
            'New-Vkd3dEvidenceCombinedFailure',
            '$cleanupPrivateRoots = @(',
            '$primaryFailure = $_.Exception',
            'throw $primaryFailure',
            'Get-Vkd3dEvidenceSanitizedFailureText'
        )) {
            if (-not $collectorText.Contains(
                    $required,
                    [StringComparison]::Ordinal
                )) {
                throw "Collector is missing lifecycle fragment '$required'."
            }
        }
        foreach ($forbidden in @(
            '$proofDirectoryCreated', '$ownerMarkerCreated', '$proofOwned',
            'Remove-Vkd3dEvidenceBootstrapTree',
            '[void][IO.Directory]::CreateDirectory($proof)',
            '$ownerStream', '$ownerReadback'
        )) {
            if ($collectorText.Contains(
                    $forbidden,
                    [StringComparison]::Ordinal
                )) {
                throw "Collector retains obsolete ownership fragment '$forbidden'."
            }
        }
        $ownedAt = $collectorText.IndexOf(
            '$ownerMarkerHandle = $proofOwnership.OwnerMarkerHandle',
            [StringComparison]::Ordinal
        )
        $cleanupCalls = [regex]::Matches(
            $collectorText,
            'Remove-Vkd3dEvidenceOwnedTree \$proof \$ownerToken'
        )
        if ($cleanupCalls.Count -ne 2) {
            throw 'Collector must have two handle-bound proof cleanup paths.'
        }
        foreach ($match in $cleanupCalls) {
            if ($match.Index -le $ownedAt) {
                throw 'Collector removes the proof tree before ownership is committed.'
            }
        }
    }

    Invoke-Vkd3dCompilerTest 'Exclusive owned proof directory cleans through retained handles' {
        $root = Join-Path $script:FixtureRoot 'exclusive-owned-proof'
        $owned = New-Vkd3dEvidenceOwnedDirectory `
            $root 'exclusive owned proof fixture'
        $rootHandle = $owned.RootHandle
        $markerHandle = $owned.OwnerMarkerHandle
        try {
            [IO.File]::WriteAllText(
                (Join-Path $root 'ordinary.bin'),
                'payload',
                $script:Utf8
            )
            Remove-Vkd3dEvidenceOwnedTree $root $owned.OwnerToken `
                -RootHandle $rootHandle `
                -OwnerMarkerHandle $markerHandle
            $rootHandle = $null
            $markerHandle = $null
        }
        finally {
            if ($null -ne $markerHandle -and -not $markerHandle.IsClosed) {
                $markerHandle.Dispose()
            }
            if ($null -ne $rootHandle -and -not $rootHandle.IsClosed) {
                $rootHandle.Dispose()
            }
        }
        if ([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)) {
            throw 'Handle-bound exclusive proof root survived cleanup.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Exclusive proof creation preserves a preexisting root' {
        $root = Join-Path $script:FixtureRoot 'exclusive-proof-race'
        [void][IO.Directory]::CreateDirectory($root)
        $foreign = Join-Path $root 'foreign.txt'
        [IO.File]::WriteAllText($foreign, 'preserve', $script:Utf8)
        Assert-Vkd3dCompilerTestThrows {
            New-Vkd3dEvidenceOwnedDirectory `
                $root 'exclusive proof race fixture' | Out-Null
        } 'exclusive ownership'
        if ([IO.File]::ReadAllText($foreign, $script:Utf8) -cne 'preserve') {
            throw 'Exclusive proof creation changed a preexisting root.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Bootstrap cleanup removes only its empty root' {
        $root = Join-Path $script:FixtureRoot 'bootstrap-empty'
        [void][IO.Directory]::CreateDirectory($root)
        Remove-Vkd3dEvidenceBootstrapTree $root $false
        if ([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)) {
            throw 'Empty bootstrap proof root survived cleanup.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Bootstrap cleanup removes only its created marker' {
        $root = Join-Path $script:FixtureRoot 'bootstrap-marker'
        [void][IO.Directory]::CreateDirectory($root)
        $marker = Join-Path $root '.retvrn99-vkd3d-proof-owner'
        [IO.File]::WriteAllText($marker, 'partial-owner', $script:Utf8)
        Remove-Vkd3dEvidenceBootstrapTree $root $true
        if ([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)) {
            throw 'Marker-only bootstrap proof root survived cleanup.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Bootstrap cleanup refuses foreign entries' {
        $root = Join-Path $script:FixtureRoot 'bootstrap-foreign'
        [void][IO.Directory]::CreateDirectory($root)
        $marker = Join-Path $root '.retvrn99-vkd3d-proof-owner'
        $foreign = Join-Path $root 'foreign.txt'
        [IO.File]::WriteAllText($marker, 'partial-owner', $script:Utf8)
        [IO.File]::WriteAllText($foreign, 'preserve', $script:Utf8)
        Assert-Vkd3dCompilerTestThrows {
            Remove-Vkd3dEvidenceBootstrapTree $root $true
        } 'foreign entries'
        if (-not [IO.File]::Exists($marker) -or
            -not [IO.File]::Exists($foreign)) {
            throw 'Bootstrap cleanup changed a root containing foreign entries.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Bootstrap cleanup refuses an unclaimed marker' {
        $root = Join-Path $script:FixtureRoot 'bootstrap-unclaimed-marker'
        [void][IO.Directory]::CreateDirectory($root)
        $marker = Join-Path $root '.retvrn99-vkd3d-proof-owner'
        [IO.File]::WriteAllText($marker, 'foreign-owner', $script:Utf8)
        Assert-Vkd3dCompilerTestThrows {
            Remove-Vkd3dEvidenceBootstrapTree $root $false
        } 'foreign entry'
        if (-not [IO.File]::Exists($marker)) {
            throw 'Bootstrap cleanup removed an unclaimed marker.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Owned cleanup requires and rechecks its marker' {
        $root = Join-Path $script:FixtureRoot 'owned-proof'
        $child = Join-Path $root 'temp'
        [void][IO.Directory]::CreateDirectory($child)
        $token = [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText(
            (Join-Path $root '.retvrn99-vkd3d-proof-owner'),
            $token,
            $script:Utf8
        )
        [IO.File]::WriteAllText(
            (Join-Path $child 'ordinary.bin'),
            'payload',
            $script:Utf8
        )
        Remove-Vkd3dEvidenceOwnedTree $root $token
        if ([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)) {
            throw 'Verified owned proof root survived cleanup.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Owned cleanup refuses a mismatched marker' {
        $root = Join-Path $script:FixtureRoot 'owned-proof-mismatch'
        [void][IO.Directory]::CreateDirectory($root)
        $marker = Join-Path $root '.retvrn99-vkd3d-proof-owner'
        [IO.File]::WriteAllText($marker, 'foreign-owner', $script:Utf8)
        Assert-Vkd3dCompilerTestThrows {
            Remove-Vkd3dEvidenceOwnedTree $root 'expected-owner'
        } 'different owner token'
        if (-not [IO.File]::Exists($marker)) {
            throw 'Owned cleanup removed a mismatched marker.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Combined failures retain roles without private paths' {
        $primaryRoot = 'C:\Users\private\source'
        $cleanupRoot = 'C:\tmp\private-proof'
        $primary = [InvalidOperationException]::new(
            "primary failed at $primaryRoot\input.c"
        )
        $cleanup = [Exception[]]@(
            [IO.IOException]::new("cleanup failed at $cleanupRoot\marker"),
            [UnauthorizedAccessException]::new(
                "cleanup denied at $cleanupRoot\partial"
            )
        )
        $combined = New-Vkd3dEvidenceCombinedFailure `
            -Primary $primary -Cleanup $cleanup `
            -PrivateRoots @($primaryRoot, $cleanupRoot)
        if ($combined -isnot [AggregateException] -or
            $combined.InnerExceptions.Count -ne 3) {
            throw 'Combined failure did not retain primary and cleanup roles.'
        }
        $rendered = $combined.ToString()
        Assert-Vkd3dEvidenceNoPrivatePathText `
            $rendered 'combined failure regression'
        if ($rendered.IndexOf(
                'Primary failure:',
                [StringComparison]::Ordinal
            ) -lt 0 -or $rendered.IndexOf(
                'Cleanup failure 1:',
                [StringComparison]::Ordinal
            ) -lt 0 -or $rendered.IndexOf(
                'Cleanup failure 2:',
                [StringComparison]::Ordinal
            ) -lt 0) {
            throw 'Combined failure lost a failure role.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Fresh boundary rejects raced-in leaf without deleting it' {
        $parent = Join-Path $script:FixtureRoot 'leaf-drift'
        $leaf = Join-Path $parent 'evidence.json.partial'
        [void][IO.Directory]::CreateDirectory($parent)
        Assert-Vkd3dEvidenceFreshMutationBoundary `
            $parent @($leaf) 'leaf drift fixture'
        [IO.File]::WriteAllText($leaf, 'foreign', $script:Utf8)
        Assert-Vkd3dCompilerTestThrows {
            Assert-Vkd3dEvidenceFreshMutationBoundary `
                $parent @($leaf) 'leaf drift fixture'
        } 'fresh and absent'
        if ([IO.File]::ReadAllText($leaf, $script:Utf8) -cne 'foreign') {
            throw 'Fresh-boundary rejection changed the raced-in leaf.'
        }
    }

    Invoke-Vkd3dCompilerTest 'Cleanup rejects a drifted reparse parent' {
        if (-not [OperatingSystem]::IsWindows()) { return }
        $parent = Join-Path $script:FixtureRoot 'stable-output-parent'
        $parked = Join-Path $script:FixtureRoot 'parked-output-parent'
        $target = Join-Path $script:FixtureRoot 'redirected-output-parent'
        $leaf = Join-Path $parent 'evidence.json.partial'
        $targetLeaf = Join-Path $target 'evidence.json.partial'
        [void][IO.Directory]::CreateDirectory($parent)
        [void][IO.Directory]::CreateDirectory($target)
        Assert-Vkd3dEvidenceFreshMutationBoundary `
            $parent @($leaf) 'reparse drift fixture'
        [IO.File]::WriteAllText($targetLeaf, 'preserve', $script:Utf8)
        [IO.Directory]::Move($parent, $parked)
        $junctionCreated = $false
        try {
            [void](New-Item -ItemType Junction -Path $parent -Target $target)
            $junctionCreated = $true
            Assert-Vkd3dCompilerTestThrows {
                Assert-Vkd3dEvidenceFreshMutationBoundary `
                    $parent @($leaf) 'reparse drift fixture'
            } 'reparse point'
            Assert-Vkd3dCompilerTestThrows {
                Remove-Vkd3dEvidenceOwnedLeaf `
                    $parent $leaf 'reparse drift fixture leaf'
            } 'reparse point'
            if ([IO.File]::ReadAllText($targetLeaf, $script:Utf8) -cne
                'preserve') {
                throw 'Cleanup changed a leaf through a reparse parent.'
            }
        }
        finally {
            if ($junctionCreated -and [IO.Directory]::Exists($parent)) {
                [IO.Directory]::Delete($parent, $false)
            }
            if ([IO.Directory]::Exists($parked) -and
                -not [IO.Directory]::Exists($parent)) {
                [IO.Directory]::Move($parked, $parent)
            }
        }
    }

    Invoke-Vkd3dCompilerTest 'Collector uses stable generator paths and logical evidence' {
        $collectorPath = Join-Path $PSScriptRoot `
            'collect-win98-vkd3d-shader-compiler-evidence.ps1'
        $collectorText = [IO.File]::ReadAllText(
            $collectorPath, [Text.UTF8Encoding]::new($false, $true)
        )
        $executionMaps = [regex]::Matches(
            $collectorText, '(?m)^\s*execution_values = @\{\r?$'
        )
        $logicalMaps = [regex]::Matches(
            $collectorText, '(?m)^\s*logical_values = @\{\r?$'
        )
        if ($executionMaps.Count -ne 7 -or $logicalMaps.Count -ne 7) {
            throw 'Collector does not define seven explicit generator value pairs.'
        }
        foreach ($required in @(
            "output_c = '../generated/libs/vkd3d-shader/hlsl.yy.c'",
            "input_l = 'libs/vkd3d-shader/hlsl.l'",
            "output_c = '../generated/libs/vkd3d-shader/hlsl.tab.c'",
            "input_y = 'libs/vkd3d-shader/hlsl.y'",
            "output_h = '../generated/include/vkd3d_d3dcommon.h'",
            "input_idl = 'include/vkd3d_d3dcommon.idl'",
            "output_h = '../generated/include/vkd3d_d3dx9shader.h'",
            "input_idl = 'include/vkd3d_d3dx9shader.idl'",
            "make_spirv = 'libs/vkd3d-shader/make_spirv'",
            "grammar = 'include/private/spirv.core.grammar.json'",
            '$plan.recipe $plan.execution_values',
            '$plan.recipe $plan.logical_values -AllowLogicalRoots'
        )) {
            if (-not $collectorText.Contains(
                    $required, [StringComparison]::Ordinal
                )) {
                throw "Collector is missing stable generator fragment '$required'."
            }
        }
        foreach ($forbidden in @(
            '$sourceForward', '$generatedForward', '$runTempForward',
            '$plan.values'
        )) {
            if ($collectorText.Contains(
                    $forbidden, [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "Collector retains private generator value '$forbidden'."
            }
        }
    }

    Invoke-Vkd3dCompilerTest 'Collector binds generated licenses to exact reviewed inputs' {
        $collectorPath = Join-Path $PSScriptRoot `
            'collect-win98-vkd3d-shader-compiler-evidence.ps1'
        $collectorText = [IO.File]::ReadAllText(
            $collectorPath, [Text.UTF8Encoding]::new($false, $true)
        )
        foreach ($required in @(
            '$expectedGeneratorInputLicenses.Count -ne 12',
            '$licensedGeneratorInputPaths.Count -ne',
            '[string]$matches[0].declared_license_expression -cne',
            '[string]$matches[0].selected_license_expression -cne',
            '-InputRelativePaths ([string[]]@($definition.inputs))'
        )) {
            if (-not $collectorText.Contains(
                    $required, [StringComparison]::Ordinal
                )) {
                throw "Collector is missing license-binding fragment '$required'."
            }
        }
    }

    Invoke-Vkd3dCompilerTest 'Process stream selection preserves empty byte arrays' {
        [byte[]]$empty = [byte[]]::new(0)
        [byte[]]$payload = [Text.Encoding]::UTF8.GetBytes('probe')
        $stdoutSelection = Select-Vkd3dEvidenceProcessStreams `
            ([pscustomobject]@{ stdout = $payload; stderr = $empty }) stdout
        $stderrSelection = Select-Vkd3dEvidenceProcessStreams `
            ([pscustomobject]@{ stdout = $empty; stderr = $payload }) stderr
        foreach ($selection in @($stdoutSelection, $stderrSelection)) {
            if ($selection.selected -isnot [byte[]] -or
                $selection.other -isnot [byte[]] -or
                $selection.selected.Length -ne $payload.Length -or
                $selection.other.Length -ne 0 -or
                (Get-Vkd3dEvidenceSha256 $selection.selected) -cne
                    (Get-Vkd3dEvidenceSha256 $payload)) {
                throw 'Empty process stream was not preserved as a byte array.'
            }
        }
    }

    $pwshPath = (Get-Process -Id $PID).Path
    $pwshBin = [IO.Path]::GetDirectoryName($pwshPath)
    Invoke-Vkd3dCompilerTest 'Bounded launcher rejects stdout over 1 MiB' {
        $marker = Join-Path $script:FixtureRoot 'stdout-survivor.txt'
        $late = "Start-Sleep -Seconds 3; [IO.File]::WriteAllText('$marker','late')"
        $lateEncoded = Get-Vkd3dCompilerEncodedCommand $late
        $outer = "Start-Process -FilePath '$pwshPath' -WindowStyle Hidden -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand','$lateEncoded'); [Console]::Out.Write('x' * 1049600); Start-Sleep -Seconds 10"
        $count = 0
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dEvidenceProcess -File $pwshPath -Arguments @(
                '-NoProfile', '-NonInteractive', '-EncodedCommand',
                (Get-Vkd3dCompilerEncodedCommand $outer)
            ) -WorkingDirectory $script:FixtureRoot `
                -PathDirectories @($pwshBin) -PrivateTemp $script:FixtureRoot `
                -Name 'stdout-bound-test' -ChildCount ([ref]$count) | Out-Null
        } 'output bound'
        Start-Sleep -Milliseconds 3500
        if ($count -ne 1 -or [IO.File]::Exists($marker)) {
            throw 'Stdout overflow left a surviving process tree.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Bounded launcher rejects stderr over 1 MiB' {
        $count = 0
        $code = "[Console]::Error.Write('x' * 1049600); Start-Sleep -Seconds 10"
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dEvidenceProcess -File $pwshPath -Arguments @(
                '-NoProfile', '-NonInteractive', '-EncodedCommand',
                (Get-Vkd3dCompilerEncodedCommand $code)
            ) -WorkingDirectory $script:FixtureRoot `
                -PathDirectories @($pwshBin) -PrivateTemp $script:FixtureRoot `
                -Name 'stderr-bound-test' -ChildCount ([ref]$count) | Out-Null
        } 'output bound'
        if ($count -ne 1) { throw 'Stderr overflow child cleanup was not counted.' }
    }
    Invoke-Vkd3dCompilerTest 'Bounded launcher rejects timeout with tree cleanup' {
        $marker = Join-Path $script:FixtureRoot 'timeout-survivor.txt'
        $late = "Start-Sleep -Seconds 3; [IO.File]::WriteAllText('$marker','late')"
        $lateEncoded = Get-Vkd3dCompilerEncodedCommand $late
        $outer = "Start-Process -FilePath '$pwshPath' -WindowStyle Hidden -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand','$lateEncoded'); Start-Sleep -Seconds 10"
        $count = 0
        Assert-Vkd3dCompilerTestThrows {
            Invoke-Vkd3dEvidenceProcess -File $pwshPath -Arguments @(
                '-NoProfile', '-NonInteractive', '-EncodedCommand',
                (Get-Vkd3dCompilerEncodedCommand $outer)
            ) -WorkingDirectory $script:FixtureRoot `
                -PathDirectories @($pwshBin) -PrivateTemp $script:FixtureRoot `
                -Name 'timeout-test' -ChildCount ([ref]$count) `
                -TimeoutSeconds 1 | Out-Null
        } '1-second bound'
        Start-Sleep -Milliseconds 3500
        if ($count -ne 1 -or [IO.File]::Exists($marker)) {
            throw 'Timeout left a surviving process tree.'
        }
    }
    Invoke-Vkd3dCompilerTest 'Bounded launcher clears ambient Git and compiler poison' {
        $oldGit = $env:GIT_DIR
        $oldGcc = $env:GCC_EXEC_PREFIX
        try {
            $env:GIT_DIR = 'C:\Users\private\poison.git'
            $env:GCC_EXEC_PREFIX = 'C:\Users\private\gcc'
            $count = 0
            $code = '[Console]::Out.Write(([string]$env:GIT_DIR) + "|" + ([string]$env:GCC_EXEC_PREFIX))'
            $result = Invoke-Vkd3dEvidenceProcess -File $pwshPath -Arguments @(
                '-NoProfile', '-NonInteractive', '-EncodedCommand',
                (Get-Vkd3dCompilerEncodedCommand $code)
            ) -WorkingDirectory $script:FixtureRoot `
                -PathDirectories @($pwshBin) -PrivateTemp $script:FixtureRoot `
                -Name 'environment-test' -ChildCount ([ref]$count)
            $text = [Text.Encoding]::UTF8.GetString([byte[]]$result.stdout)
            if ($text -cne '|' -or $count -ne 1) {
                throw 'Ambient poison reached the child process.'
            }
        }
        finally {
            if ($null -eq $oldGit) { Remove-Item Env:GIT_DIR -ErrorAction SilentlyContinue }
            else { $env:GIT_DIR = $oldGit }
            if ($null -eq $oldGcc) { Remove-Item Env:GCC_EXEC_PREFIX -ErrorAction SilentlyContinue }
            else { $env:GCC_EXEC_PREFIX = $oldGcc }
        }
    }
    Invoke-Vkd3dCompilerTest 'Private child stderr never enters thrown detail' {
        $count = 0
        $private = 'C:\Users\private\compiler-secret'
        $code = "[Console]::Error.Write('$private'); exit 7"
        try {
            Invoke-Vkd3dEvidenceProcess -File $pwshPath -Arguments @(
                '-NoProfile', '-NonInteractive', '-EncodedCommand',
                (Get-Vkd3dCompilerEncodedCommand $code)
            ) -WorkingDirectory $script:FixtureRoot `
                -PathDirectories @($pwshBin) -PrivateTemp $script:FixtureRoot `
                -Name 'private-stderr-test' -ChildCount ([ref]$count) | Out-Null
            throw 'Expected the child failure.'
        }
        catch {
            if ($_.Exception.Message -notmatch 'exit code 7' -or
                $_.Exception.Message.Contains($private) -or $count -ne 1) {
                throw 'Private child stderr leaked into the failure boundary.'
            }
        }
    }
}
finally {
    if ([IO.Directory]::Exists($script:FixtureRoot)) {
        [IO.Directory]::Delete($script:FixtureRoot, $true)
    }
}

if ($script:FailureCount -ne 0) {
    throw "$($script:FailureCount) of $($script:TestCount) vkd3d-shader compiler-closure tests failed."
}
Write-Output (
    "All $($script:TestCount) vkd3d-shader compiler-closure tests passed."
)

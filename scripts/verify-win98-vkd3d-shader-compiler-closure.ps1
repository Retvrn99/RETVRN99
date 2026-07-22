# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$ClosureFile,
    [string]$DriversRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'vkd3d-shader-compiler-evidence.ps1')
. (Join-Path $PSScriptRoot 'mesa-object-proof.ps1')

$script:Vkd3dCompilerCommit = '1b0924d12c18df03912a8876ed17fd017ce9308e'
$script:Vkd3dCompilerRepository = 'https://gitlab.winehq.org/wine/vkd3d.git'
$script:Vkd3dCompilerMesaCommit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$script:Vkd3dCompilerUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Assert-Vkd3dCompilerExactProperties {
    param([object]$Value, [string[]]$Expected, [string]$Name)

    Assert-GswJsonExactProperties $Value $Expected $Name
}

function Assert-Vkd3dCompilerFalseValues {
    param([object]$Value, [string]$Name)

    foreach ($property in $Value.PSObject.Properties) {
        Assert-GswJsonBoolean $property.Value "$Name.$($property.Name)"
        if ($property.Value) {
            throw "$Name.$($property.Name) must remain false."
        }
    }
}

function Assert-Vkd3dCompilerSha256 {
    param([object]$Value, [string]$Name)

    if ($Value -isnot [string] -or
        [string]$Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name is not one lowercase SHA-256."
    }
}

function Assert-Vkd3dCompilerRelativePath {
    param([object]$Value, [string]$Name)

    if ($Value -isnot [string]) { throw "$Name is not a string." }
    Assert-Vkd3dEvidenceRelativePath ([string]$Value) $Name
}

function Assert-Vkd3dCompilerNoPrivatePaths {
    param([object]$Value, [string]$Name)

    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if ($Value.Length -eq 0) { return }
        Assert-Vkd3dEvidenceNoPrivatePathText $Value $Name
        return
    }
    if ($Value -is [Collections.IEnumerable] -and
        $Value -isnot [Management.Automation.PSCustomObject]) {
        $index = 0
        foreach ($item in $Value) {
            Assert-Vkd3dCompilerNoPrivatePaths $item "$Name[$index]"
            $index++
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        Assert-Vkd3dCompilerNoPrivatePaths $property.Value `
            "$Name.$($property.Name)"
    }
}

function Test-Vkd3dCompilerStringArrayEqual {
    param([object[]]$First, [object[]]$Second)

    if ($First.Count -ne $Second.Count) { return $false }
    for ($index = 0; $index -lt $First.Count; $index++) {
        if ([string]$First[$index] -cne [string]$Second[$index]) {
            return $false
        }
    }
    return $true
}

function Assert-Vkd3dCompilerDeepEqual {
    param([object]$First, [object]$Second, [string]$Name)

    $firstJson = $First | ConvertTo-Json -Depth 32 -Compress
    $secondJson = $Second | ConvertTo-Json -Depth 32 -Compress
    if ($firstJson -cne $secondJson) { throw "$Name changed." }
}

function Read-Vkd3dCompilerBoundJson {
    param(
        [string]$Root,
        [object]$Binding,
        [string]$Name,
        [UInt64]$MaximumBytes
    )

    Assert-Vkd3dCompilerExactProperties $Binding @(
        'relative_path', 'bytes', 'sha256', 'status', 'file_count'
    ) "$Name binding"
    Assert-Vkd3dCompilerRelativePath $Binding.relative_path "$Name path"
    Assert-Vkd3dCompilerSha256 $Binding.sha256 "$Name hash"
    $path = [IO.Path]::GetFullPath((Join-Path $Root `
        ([string]$Binding.relative_path).Replace('/', '\')))
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
    if (-not $path.StartsWith(
            $rootPath + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name path escapes the drivers root."
    }
    $snapshot = Read-GswStrictJsonFileSnapshot -Path $path -Name $Name `
        -MaximumBytes $MaximumBytes
    if ([UInt64]$snapshot.Bytes.Length -ne [UInt64]$Binding.bytes -or
        [string]$snapshot.Sha256 -cne [string]$Binding.sha256) {
        throw "$Name input binding drifted."
    }
    return $snapshot.Value
}

function Get-Vkd3dCompilerRowMap {
    param([object[]]$Rows, [string]$Property, [string]$Name)

    $map = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($row in $Rows) {
        $key = [string]$row.$Property
        if ([string]::IsNullOrWhiteSpace($key) -or -not $map.TryAdd($key, $row)) {
            throw "$Name repeats or omits '$key'."
        }
    }
    return $map
}

function Get-Vkd3dCompilerSortedDependencyRows {
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

function Assert-Vkd3dCompilerAggregate {
    param(
        [object[]]$Rows,
        [object]$ExpectedCount,
        [object]$ExpectedBytes,
        [object]$ExpectedSha256,
        [string]$Name
    )

    [UInt64]$bytes = 0
    foreach ($row in $Rows) { $bytes += [UInt64]$row.bytes }
    if ([UInt64]$ExpectedCount -ne [UInt64]$Rows.Count -or
        [UInt64]$ExpectedBytes -ne $bytes -or
        [string]$ExpectedSha256 -cne
            (Get-Vkd3dEvidenceAggregateSha256 $Rows)) {
        throw "$Name aggregate changed."
    }
}

function Assert-Vkd3dCompilerSourcePair {
    param([object]$Closure, [object]$Component)

    $pair = $Closure.source_pair
    Assert-Vkd3dCompilerExactProperties $pair @(
        'status', 'checkouts', 'file_count', 'aggregate_bytes',
        'aggregate_sha256', 'files'
    ) 'source_pair'
    if ($pair.status -cne 'canonical-lf-crlf-proven' -or
        @($pair.checkouts).Count -ne 2 -or @($pair.files).Count -ne 40) {
        throw 'Canonical source-pair inventory changed.'
    }
    $expectedCheckouts = @(
        @('lf', 'lf'),
        @('crlf', 'crlf')
    )
    for ($index = 0; $index -lt 2; $index++) {
        $checkout = $pair.checkouts[$index]
        Assert-Vkd3dCompilerExactProperties $checkout @(
            'id', 'checkout_mode', 'clean', 'detached', 'owning_commit',
            'origin'
        ) "source checkout $index"
        Assert-GswJsonBoolean $checkout.clean "source checkout $index clean"
        Assert-GswJsonBoolean $checkout.detached `
            "source checkout $index detached"
        if ($checkout.id -cne $expectedCheckouts[$index][0] -or
            $checkout.checkout_mode -cne $expectedCheckouts[$index][1] -or
            -not $checkout.clean -or -not $checkout.detached -or
            $checkout.owning_commit -cne $script:Vkd3dCompilerCommit -or
            $checkout.origin -cne $script:Vkd3dCompilerRepository) {
            throw "Source checkout $index changed."
        }
    }
    for ($index = 0; $index -lt 40; $index++) {
        $actual = $pair.files[$index]
        $expected = $Component.files[$index]
        Assert-Vkd3dCompilerExactProperties $actual @(
            'ordinal', 'relative_path', 'git_blob', 'bytes', 'lf_count',
            'crlf_count', 'sha256', 'declared_license_expression',
            'selected_license_expression', 'license_evidence_ids', 'roles',
            'canonical_pair'
        ) "source_pair.files[$index]"
        Assert-GswJsonBoolean $actual.canonical_pair `
            "source_pair.files[$index].canonical_pair"
        if ([UInt64]$actual.ordinal -ne [UInt64]($index + 1) -or
            $actual.relative_path -cne $expected.relative_path -or
            $actual.git_blob -cne $expected.git_blob -or
            [UInt64]$actual.bytes -ne [UInt64]$expected.bytes -or
            [UInt64]$actual.lf_count -lt 1 -or
            [UInt64]$actual.crlf_count -ne [UInt64]$actual.lf_count -or
            $actual.sha256 -cne $expected.sha256 -or
            $actual.declared_license_expression -cne
                $expected.declared_license_expression -or
            $actual.selected_license_expression -cne
                $expected.selected_license_expression -or
            -not (Test-Vkd3dCompilerStringArrayEqual `
                @($actual.license_evidence_ids) `
                @($expected.license_evidence_ids)) -or
            -not (Test-Vkd3dCompilerStringArrayEqual `
                @($actual.roles) @($expected.roles)) -or
            -not $actual.canonical_pair) {
            throw "Canonical source file $($index + 1) changed."
        }
    }
    Assert-Vkd3dCompilerAggregate @($pair.files) $pair.file_count `
        $pair.aggregate_bytes $pair.aggregate_sha256 'Canonical source pair'
}

function Assert-Vkd3dCompilerCrossComponentInputs {
    param([object]$Closure, [object]$Mesa)

    $cross = $Closure.cross_component_inputs
    Assert-Vkd3dCompilerExactProperties $cross @(
        'status', 'component_manifest', 'owning_commit', 'file_count',
        'aggregate_bytes', 'aggregate_sha256', 'files'
    ) 'cross_component_inputs'
    if ($cross.status -cne 'ready' -or
        $cross.owning_commit -cne $script:Vkd3dCompilerMesaCommit -or
        @($cross.files).Count -ne 2) {
        throw 'Cross-component SPIR-V input inventory changed.'
    }
    $expected = @(
        @(
            'mesa-23.1.x/src/compiler/spirv/spirv.h',
            'include/spirv/unified1/spirv.h'
        ),
        @(
            'mesa-23.1.x/src/compiler/spirv/GLSL.std.450.h',
            'include/spirv/unified1/GLSL.std.450.h'
        )
    )
    $mesaRows = Get-Vkd3dCompilerRowMap @($Mesa.files) `
        'relative_path' 'Mesa component files'
    for ($index = 0; $index -lt 2; $index++) {
        $row = $cross.files[$index]
        Assert-Vkd3dCompilerExactProperties $row @(
            'ordinal', 'source_relative_path', 'target_relative_path',
            'git_blob', 'bytes', 'sha256', 'license_expression'
        ) "cross_component_inputs.files[$index]"
        $sourcePath = $expected[$index][0]
        if (-not $mesaRows.ContainsKey($sourcePath)) {
            throw "Mesa SPIR-V input '$sourcePath' is absent."
        }
        $mesaRow = $mesaRows[$sourcePath]
        if ([UInt64]$row.ordinal -ne [UInt64]($index + 1) -or
            $row.source_relative_path -cne $sourcePath -or
            $row.target_relative_path -cne $expected[$index][1] -or
            $row.git_blob -cne $mesaRow.git_blob -or
            [UInt64]$row.bytes -ne [UInt64]$mesaRow.bytes -or
            $row.sha256 -cne $mesaRow.sha256 -or
            $row.license_expression -cne 'MIT' -or
            $mesaRow.declared_license_expression -cne 'MIT' -or
            $mesaRow.selected_license_expression -cne 'MIT' -or
            @($mesaRow.roles) -cnotcontains 'compiler-dependency') {
            throw "Cross-component SPIR-V input $($index + 1) changed."
        }
    }
    Assert-Vkd3dCompilerAggregate @($cross.files | ForEach-Object {
        [pscustomobject]@{
            relative_path = $_.target_relative_path
            bytes = $_.bytes
            sha256 = $_.sha256
        }
    }) $cross.file_count $cross.aggregate_bytes $cross.aggregate_sha256 `
        'Cross-component inputs'
}

function Assert-Vkd3dCompilerToolchain {
    param([object]$Closure, [object]$Lock)

    $toolchain = $Closure.toolchain
    Assert-Vkd3dCompilerExactProperties $toolchain @(
        'status', 'lock', 'roots', 'files', 'trees', 'probes',
        'environment', 'process_limits'
    ) 'toolchain'
    if ($toolchain.status -cne 'ready' -or
        @($toolchain.roots).Count -ne 3 -or
        @($toolchain.files).Count -ne @($Lock.files).Count -or
        @($toolchain.trees).Count -ne @($Lock.trees).Count -or
        @($toolchain.probes).Count -ne @($Lock.tool_probes).Count) {
        throw 'Toolchain evidence inventory changed.'
    }
    for ($index = 0; $index -lt 3; $index++) {
        $actual = $toolchain.roots[$index]
        Assert-Vkd3dCompilerExactProperties $actual @('id', 'verified') `
            "toolchain.roots[$index]"
        Assert-GswJsonBoolean $actual.verified "toolchain.roots[$index].verified"
        if ($actual.id -cne $Lock.roots[$index].id -or -not $actual.verified) {
            throw "Toolchain root $index changed."
        }
    }
    for ($index = 0; $index -lt @($Lock.files).Count; $index++) {
        Assert-Vkd3dCompilerDeepEqual $toolchain.files[$index] `
            $Lock.files[$index] "Toolchain file $index"
    }
    for ($index = 0; $index -lt @($Lock.trees).Count; $index++) {
        Assert-Vkd3dCompilerDeepEqual $toolchain.trees[$index] `
            $Lock.trees[$index] "Toolchain tree $index"
    }
    for ($index = 0; $index -lt @($Lock.tool_probes).Count; $index++) {
        $actual = $toolchain.probes[$index]
        $expected = $Lock.tool_probes[$index]
        Assert-Vkd3dCompilerExactProperties $actual @(
            'id', 'file_id', 'expected_lines', 'observed_lines',
            'stdout_bytes', 'stdout_sha256'
        ) "toolchain.probes[$index]"
        Assert-Vkd3dCompilerSha256 $actual.stdout_sha256 `
            "toolchain.probes[$index].stdout_sha256"
        if ($actual.id -cne $expected.id -or
            $actual.file_id -cne $expected.file_id -or
            -not (Test-Vkd3dCompilerStringArrayEqual `
                @($actual.expected_lines) @($expected.expected_lines)) -or
            @($actual.observed_lines).Count -lt @($expected.expected_lines).Count -or
            [UInt64]$actual.stdout_bytes -gt
                [UInt64]$expected.maximum_output_bytes) {
            throw "Toolchain probe $index changed."
        }
        for ($line = 0; $line -lt @($expected.expected_lines).Count; $line++) {
            if ($actual.observed_lines[$line] -cne $expected.expected_lines[$line]) {
                throw "Toolchain probe $index output changed."
            }
        }
    }
    Assert-Vkd3dCompilerExactProperties $toolchain.process_limits @(
        'no_shell', 'maximum_top_level_processes',
        'maximum_process_tree_width', 'timeout_seconds',
        'termination_grace_seconds', 'maximum_stdout_bytes',
        'maximum_stderr_bytes', 'terminate_process_tree'
    ) 'toolchain.process_limits'
    foreach ($name in @(
        'no_shell', 'maximum_top_level_processes',
        'maximum_process_tree_width', 'timeout_seconds',
        'termination_grace_seconds', 'maximum_stdout_bytes',
        'maximum_stderr_bytes', 'terminate_process_tree'
    )) {
        if ($toolchain.process_limits.$name -cne $Lock.process_limits.$name) {
            throw "Toolchain process limit '$name' changed."
        }
    }
}

function Get-Vkd3dCompilerGeneratedDefinitions {
    return @(
        [pscustomobject]@{ path = 'libs/vkd3d-shader/hlsl.yy.c'; kind = 'generated-c'; recipe = 'flex-c'; inputs = @('libs/vkd3d-shader/hlsl.l'); license = 'LGPL-2.1-or-later'; provenance = 'flex-2.6.4-output-exception-and-lgpl-lexer' },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/hlsl.tab.c'; kind = 'generated-c'; recipe = 'bison-c-header'; inputs = @('libs/vkd3d-shader/hlsl.y'); license = 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)'; provenance = 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input' },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/hlsl.tab.h'; kind = 'generated-header'; recipe = 'bison-c-header'; inputs = @('libs/vkd3d-shader/hlsl.y'); license = 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)'; provenance = 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input' },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/preproc.yy.c'; kind = 'generated-c'; recipe = 'flex-c'; inputs = @('libs/vkd3d-shader/preproc.l'); license = 'LGPL-2.1-or-later'; provenance = 'flex-2.6.4-output-exception-and-lgpl-lexer' },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/preproc.tab.c'; kind = 'generated-c'; recipe = 'bison-c-header'; inputs = @('libs/vkd3d-shader/preproc.y'); license = 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)'; provenance = 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input' },
        [pscustomobject]@{ path = 'libs/vkd3d-shader/preproc.tab.h'; kind = 'generated-header'; recipe = 'bison-c-header'; inputs = @('libs/vkd3d-shader/preproc.y'); license = 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)'; provenance = 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input' },
        [pscustomobject]@{ path = 'include/vkd3d_d3dcommon.h'; kind = 'generated-header'; recipe = 'widl-header'; inputs = @('include/vkd3d_d3dcommon.idl', 'include/vkd3d_unknown.idl'); license = 'LGPL-2.1-or-later'; provenance = 'widl-11.0-rc1-from-exact-lgpl-idl' },
        [pscustomobject]@{ path = 'include/vkd3d_d3dx9shader.h'; kind = 'generated-header'; recipe = 'widl-header'; inputs = @('include/vkd3d_d3dx9shader.idl', 'include/vkd3d_d3d9types.h'); license = 'LGPL-2.1-or-later'; provenance = 'widl-11.0-rc1-from-exact-lgpl-idl' },
        [pscustomobject]@{ path = 'include/private/spirv_grammar.h'; kind = 'generated-header'; recipe = 'spirv-header'; inputs = @('libs/vkd3d-shader/make_spirv', 'include/private/spirv.core.grammar.json'); license = 'MIT'; provenance = 'unchanged-make-spirv-from-exact-mit-grammar' },
        [pscustomobject]@{ path = 'include/config.h'; kind = 'generated-header'; recipe = 'reviewed-config-header'; inputs = @('configure.ac'); license = 'GPL-3.0-only'; provenance = 'retvrn99-exact-configuration-recipe' },
        [pscustomobject]@{ path = 'include/private/vkd3d_version.h'; kind = 'generated-header'; recipe = 'reviewed-version-header'; inputs = @('Makefile.am'); license = 'GPL-3.0-only'; provenance = 'retvrn99-exact-version-recipe' }
    )
}

function Get-Vkd3dCompilerUnitDefinitions {
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

function Expand-Vkd3dCompilerRecipeArguments {
    param([object]$Recipe, [hashtable]$Values)

    $result = [Collections.Generic.List[string]]::new()
    foreach ($template in @($Recipe.arguments)) {
        $value = [string]$template
        foreach ($key in $Values.Keys) {
            $value = $value.Replace('{' + $key + '}', [string]$Values[$key])
        }
        $unresolved = $value.Replace('{source}', '').Replace(
            '{generated}', ''
        ).Replace('{temporary}', '')
        if ($unresolved -match '\{[a-z_]+\}') {
            throw "Recipe '$($Recipe.id)' retains a placeholder."
        }
        $result.Add($value)
    }
    return @($result)
}

function Get-Vkd3dCompilerGeneratorPlans {
    param([object]$Lock)

    $recipes = Get-Vkd3dCompilerRowMap @($Lock.recipes) 'id' `
        'toolchain recipes'
    return @(
        [pscustomobject]@{ recipe = $recipes['flex-c']; tool = 'msys-flex'; values = @{ output_c = '{generated}/libs/vkd3d-shader/hlsl.yy.c'; input_l = '{source}/libs/vkd3d-shader/hlsl.l' } },
        [pscustomobject]@{ recipe = $recipes['bison-c-header']; tool = 'msys-bison'; values = @{ output_c = '{generated}/libs/vkd3d-shader/hlsl.tab.c'; input_y = '{source}/libs/vkd3d-shader/hlsl.y' } },
        [pscustomobject]@{ recipe = $recipes['flex-c']; tool = 'msys-flex'; values = @{ output_c = '{generated}/libs/vkd3d-shader/preproc.yy.c'; input_l = '{source}/libs/vkd3d-shader/preproc.l' } },
        [pscustomobject]@{ recipe = $recipes['bison-c-header']; tool = 'msys-bison'; values = @{ output_c = '{generated}/libs/vkd3d-shader/preproc.tab.c'; input_y = '{source}/libs/vkd3d-shader/preproc.y' } },
        [pscustomobject]@{ recipe = $recipes['widl-header']; tool = 'ucrt-widl'; values = @{ source_include = '{source}/include'; output_h = '{generated}/include/vkd3d_d3dcommon.h'; input_idl = '{source}/include/vkd3d_d3dcommon.idl' } },
        [pscustomobject]@{ recipe = $recipes['widl-header']; tool = 'ucrt-widl'; values = @{ source_include = '{source}/include'; output_h = '{generated}/include/vkd3d_d3dx9shader.h'; input_idl = '{source}/include/vkd3d_d3dx9shader.idl' } },
        [pscustomobject]@{ recipe = $recipes['spirv-header']; tool = 'git-perl'; values = @{ make_spirv = '{source}/libs/vkd3d-shader/make_spirv'; grammar = '{source}/include/private/spirv.core.grammar.json' } },
        [pscustomobject]@{ recipe = [pscustomobject]@{ id = 'reviewed-config-header'; arguments = @('write-exact', 'include/config.h') }; tool = 'retvrn99-reviewed-bytes'; values = @{} },
        [pscustomobject]@{ recipe = [pscustomobject]@{ id = 'reviewed-version-header'; arguments = @('write-exact', 'include/private/vkd3d_version.h') }; tool = 'retvrn99-reviewed-bytes'; values = @{} }
    )
}

function Assert-Vkd3dCompilerGeneratedRuns {
    param([object]$Closure, [object]$Lock)

    $runs = @($Closure.generated_runs)
    $definitions = @(Get-Vkd3dCompilerGeneratedDefinitions)
    $plans = @(Get-Vkd3dCompilerGeneratorPlans $Lock)
    $expectedWidl = @{
        'include/vkd3d_d3dcommon.h' = [pscustomobject]@{
            raw_bytes = [UInt64]23406
            raw_sha256 = 'fb522341733698aefa4b52c7e1d8860cd9ddd63b533c81f49331afe9d6b55942'
            newline_count = [UInt64]699
            bytes = [UInt64]22707
            sha256 = 'c52dc8d4aa832294220b3684b4b011319523595d038eaa0a1c055a4028112482'
        }
        'include/vkd3d_d3dx9shader.h' = [pscustomobject]@{
            raw_bytes = [UInt64]2017
            raw_sha256 = '7a10933742f289060141d9366943817742f7c8efb6fb33a7ea54208165a55542'
            newline_count = [UInt64]87
            bytes = [UInt64]1930
            sha256 = '574e09c72ad2bb9f3182a38cb32dac70a25753d34f9f3d2454db514864e1c6d0'
        }
    }
    if ($runs.Count -ne 2) { throw 'Exactly two generated runs are required.' }
    for ($runIndex = 0; $runIndex -lt 2; $runIndex++) {
        $run = $runs[$runIndex]
        $expectedId = @('lf', 'crlf')[$runIndex]
        Assert-Vkd3dCompilerExactProperties $run @(
            'id', 'source_mode', 'generator_commands', 'output_count',
            'raw_aggregate_bytes', 'raw_aggregate_sha256',
            'aggregate_bytes', 'aggregate_sha256', 'outputs'
        ) "generated_runs[$runIndex]"
        Assert-Vkd3dCompilerSha256 $run.raw_aggregate_sha256 `
            "generated run '$expectedId' raw aggregate"
        if ($run.id -cne $expectedId -or $run.source_mode -cne $expectedId -or
            @($run.generator_commands).Count -ne 9 -or
            @($run.outputs).Count -ne 11) {
            throw "Generated run '$expectedId' inventory changed."
        }
        for ($index = 0; $index -lt 9; $index++) {
            $command = $run.generator_commands[$index]
            $plan = $plans[$index]
            Assert-Vkd3dCompilerExactProperties $command @(
                'ordinal', 'recipe_id', 'tool_file_id', 'arguments',
                'exit_code', 'stdout_bytes', 'stdout_sha256', 'stderr_bytes',
                'stderr_sha256'
            ) "generated run '$expectedId' command $index"
            Assert-Vkd3dCompilerSha256 $command.stdout_sha256 `
                "generated run '$expectedId' command $index stdout"
            Assert-Vkd3dCompilerSha256 $command.stderr_sha256 `
                "generated run '$expectedId' command $index stderr"
            $expectedArguments = @(Expand-Vkd3dCompilerRecipeArguments `
                $plan.recipe $plan.values)
            if ([UInt64]$command.ordinal -ne [UInt64]($index + 1) -or
                $command.recipe_id -cne $plan.recipe.id -or
                $command.tool_file_id -cne $plan.tool -or
                -not (Test-Vkd3dCompilerStringArrayEqual `
                    @($command.arguments) $expectedArguments) -or
                [UInt64]$command.exit_code -ne 0 -or
                [UInt64]$command.stderr_bytes -ne 0 -or
                $command.stderr_sha256 -cne
                    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') {
                throw "Generated command $($index + 1) changed."
            }
            if ($index -ne 6 -and
                ([UInt64]$command.stdout_bytes -ne 0 -or
                    $command.stdout_sha256 -cne
                        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')) {
                throw "Generated command $($index + 1) wrote unexpected output."
            }
            if ($index -eq 6 -and [UInt64]$command.stdout_bytes -lt 1) {
                throw 'SPIR-V generator produced no output evidence.'
            }
        }
        for ($index = 0; $index -lt 11; $index++) {
            $output = $run.outputs[$index]
            $definition = $definitions[$index]
            Assert-Vkd3dCompilerExactProperties $output @(
                'ordinal', 'relative_path', 'raw_bytes', 'raw_sha256',
                'raw_lf_count', 'raw_crlf_count', 'raw_lf_only_count',
                'raw_cr_only_count', 'raw_utf8_bom', 'normalization',
                'removed_cr_bytes', 'normalization_proven', 'bytes',
                'sha256', 'lf_count', 'crlf_count', 'lf_only_count',
                'cr_only_count', 'utf8_bom', 'license_expression',
                'provenance'
            ) "generated run '$expectedId' output $index"
            Assert-Vkd3dCompilerSha256 $output.raw_sha256 `
                "generated run '$expectedId' output $index raw hash"
            Assert-Vkd3dCompilerSha256 $output.sha256 `
                "generated run '$expectedId' output $index hash"
            foreach ($booleanName in @(
                'raw_utf8_bom', 'normalization_proven', 'utf8_bom'
            )) {
                Assert-GswJsonBoolean $output.$booleanName `
                    "generated run '$expectedId' output $index $booleanName"
            }
            if ([UInt64]$output.ordinal -ne [UInt64]($index + 1) -or
                $output.relative_path -cne $definition.path -or
                [UInt64]$output.raw_bytes -lt 1 -or
                [UInt64]$output.bytes -lt 1 -or
                $output.raw_utf8_bom -or $output.utf8_bom -or
                -not $output.normalization_proven -or
                [UInt64]$output.raw_lf_count -ne
                    ([UInt64]$output.raw_crlf_count +
                        [UInt64]$output.raw_lf_only_count) -or
                [UInt64]$output.lf_count -ne
                    [UInt64]$output.lf_only_count -or
                [UInt64]$output.crlf_count -ne 0 -or
                [UInt64]$output.cr_only_count -ne 0 -or
                $output.license_expression -cne $definition.license -or
                $output.provenance -cne $definition.provenance) {
                throw "Generated output $($index + 1) changed."
            }
            $expectedMode = if ($definition.recipe -ceq 'widl-header') {
                'crlf-to-lf'
            }
            else { 'none' }
            if ($output.normalization -cne $expectedMode) {
                throw "Generated output $($index + 1) normalization changed."
            }
            if ($expectedMode -ceq 'none') {
                if ([UInt64]$output.raw_bytes -ne [UInt64]$output.bytes -or
                    $output.raw_sha256 -cne $output.sha256 -or
                    [UInt64]$output.raw_lf_count -ne
                        [UInt64]$output.lf_count -or
                    [UInt64]$output.raw_crlf_count -ne 0 -or
                    [UInt64]$output.raw_lf_only_count -ne
                        [UInt64]$output.lf_only_count -or
                    [UInt64]$output.raw_cr_only_count -ne 0 -or
                    [UInt64]$output.removed_cr_bytes -ne 0) {
                    throw "Generated output $($index + 1) no-op normalization changed bytes."
                }
            }
            else {
                $expected = $expectedWidl[$definition.path]
                if ($null -eq $expected -or
                    [UInt64]$output.raw_bytes -ne [UInt64]$expected.raw_bytes -or
                    $output.raw_sha256 -cne $expected.raw_sha256 -or
                    [UInt64]$output.raw_lf_count -ne
                        [UInt64]$expected.newline_count -or
                    [UInt64]$output.raw_crlf_count -ne
                        [UInt64]$expected.newline_count -or
                    [UInt64]$output.raw_lf_only_count -ne 0 -or
                    [UInt64]$output.raw_cr_only_count -ne 0 -or
                    [UInt64]$output.bytes -ne [UInt64]$expected.bytes -or
                    $output.sha256 -cne $expected.sha256 -or
                    [UInt64]$output.lf_count -ne
                        [UInt64]$expected.newline_count -or
                    [UInt64]$output.lf_only_count -ne
                        [UInt64]$expected.newline_count -or
                    [UInt64]$output.removed_cr_bytes -ne
                        [UInt64]$expected.newline_count -or
                    [UInt64]$output.raw_bytes -ne
                        ([UInt64]$output.bytes +
                            [UInt64]$output.removed_cr_bytes) -or
                    $output.raw_sha256 -ceq $output.sha256) {
                    throw "Generated WIDL output $($index + 1) normalization changed."
                }
            }
        }
        $rawRows = @($run.outputs | ForEach-Object {
            [pscustomobject]@{
                relative_path = [string]$_.relative_path
                bytes = [UInt64]$_.raw_bytes
                sha256 = [string]$_.raw_sha256
            }
        })
        Assert-Vkd3dCompilerAggregate $rawRows $run.output_count `
            $run.raw_aggregate_bytes $run.raw_aggregate_sha256 `
            "Generated run '$expectedId' raw"
        Assert-Vkd3dCompilerAggregate @($run.outputs) $run.output_count `
            $run.aggregate_bytes $run.aggregate_sha256 `
            "Generated run '$expectedId'"
        $spirv = @($run.outputs | Where-Object relative_path -ceq `
            'include/private/spirv_grammar.h')[0]
        if ($run.generator_commands[6].stdout_bytes -ne $spirv.bytes -or
            $run.generator_commands[6].stdout_sha256 -cne $spirv.sha256) {
            throw 'SPIR-V stdout evidence differs from its generated output.'
        }
    }
    Assert-Vkd3dCompilerDeepEqual $runs[0].generator_commands `
        $runs[1].generator_commands 'Twin generator commands'
    Assert-Vkd3dCompilerDeepEqual $runs[0].outputs $runs[1].outputs `
        'Twin generated outputs'
    if ($runs[0].raw_aggregate_bytes -ne $runs[1].raw_aggregate_bytes -or
        $runs[0].raw_aggregate_sha256 -cne
            $runs[1].raw_aggregate_sha256 -or
        $runs[0].aggregate_sha256 -cne $runs[1].aggregate_sha256) {
        throw 'Twin raw or canonical generated-output aggregates differ.'
    }
}

function Assert-Vkd3dCompilerRecipe {
    param([object]$Closure, [object]$Component, [object]$Lock)

    $recipe = $Closure.recipe
    Assert-Vkd3dCompilerExactProperties $recipe @(
        'status', 'generated_output_count', 'tracked_source_unit_count',
        'generated_source_unit_count', 'compile_command_count',
        'generator_recipes', 'compile_arguments',
        'object_validation_arguments', 'generated_outputs',
        'compilation_units'
    ) 'recipe'
    if ($recipe.status -cne 'exact-compile-only' -or
        [UInt64]$recipe.generated_output_count -ne 11 -or
        [UInt64]$recipe.tracked_source_unit_count -ne 15 -or
        [UInt64]$recipe.generated_source_unit_count -ne 4 -or
        [UInt64]$recipe.compile_command_count -ne 19 -or
        @($recipe.generator_recipes).Count -ne 4 -or
        @($recipe.generated_outputs).Count -ne 11 -or
        @($recipe.compilation_units).Count -ne 19) {
        throw 'Exact compile-only recipe inventory changed.'
    }
    $lockedRecipes = Get-Vkd3dCompilerRowMap @($Lock.recipes) 'id' `
        'toolchain recipes'
    $generatorIds = @('flex-c', 'bison-c-header', 'widl-header', 'spirv-header')
    for ($index = 0; $index -lt $generatorIds.Count; $index++) {
        Assert-Vkd3dCompilerDeepEqual $recipe.generator_recipes[$index] `
            $lockedRecipes[$generatorIds[$index]] `
            "Generator recipe $($generatorIds[$index])"
    }
    if (-not (Test-Vkd3dCompilerStringArrayEqual `
            @($recipe.compile_arguments) `
            @($lockedRecipes['compile-c-object'].arguments)) -or
        -not (Test-Vkd3dCompilerStringArrayEqual `
            @($recipe.object_validation_arguments) `
            @($lockedRecipes['validate-object'].arguments))) {
        throw 'Locked compiler or objdump arguments changed.'
    }
    $compileArguments = @($recipe.compile_arguments)
    foreach ($required in @(
        '-fno-lto', '-MD', '-MF', '-MT', '-c', '-o',
        '-ffile-prefix-map={source_root}=source',
        '-fdebug-prefix-map={source_root}=source',
        '-fmacro-prefix-map={source_root}=source',
        '-ffile-prefix-map={generated_root}=generated',
        '-fdebug-prefix-map={generated_root}=generated',
        '-fmacro-prefix-map={generated_root}=generated',
        '-frandom-seed={unit_sha256}'
    )) {
        if (@($compileArguments | Where-Object { [string]$_ -ceq $required }).Count -ne 1) {
            throw "Compile recipe lacks one exact '$required'."
        }
    }
    if ($compileArguments -contains '-MG') {
        throw 'Compile recipe must reject dependency -MG mode.'
    }
    if (@($compileArguments | Where-Object {
            [string]$_ -match '^-flto(?:=|$)'
        }).Count -ne 0) {
        throw 'Compile recipe must remain proof-only no-LTO.'
    }
    $expectedIncludes = @(
        '-I{generated_root}/include',
        '-I{generated_root}/include/private',
        '-I{source_root}/include',
        '-I{source_root}/include/private',
        '-I{source_root}/libs/vkd3d-shader'
    )
    $includePositions = @($expectedIncludes | ForEach-Object {
        [Array]::IndexOf([object[]]$compileArguments, [object]$_)
    })
    if ($includePositions -contains -1) {
        throw 'Compile recipe lacks an exact include root.'
    }
    for ($index = 1; $index -lt $includePositions.Count; $index++) {
        if ($includePositions[$index] -le $includePositions[$index - 1]) {
            throw 'Compile recipe include precedence changed.'
        }
    }

    $definitions = @(Get-Vkd3dCompilerGeneratedDefinitions)
    for ($index = 0; $index -lt $definitions.Count; $index++) {
        $actual = $recipe.generated_outputs[$index]
        $expected = $definitions[$index]
        Assert-Vkd3dCompilerExactProperties $actual @(
            'ordinal', 'relative_path', 'kind', 'recipe_id', 'inputs'
        ) "recipe.generated_outputs[$index]"
        if ([UInt64]$actual.ordinal -ne [UInt64]($index + 1) -or
            $actual.relative_path -cne $expected.path -or
            $actual.kind -cne $expected.kind -or
            $actual.recipe_id -cne $expected.recipe -or
            -not (Test-Vkd3dCompilerStringArrayEqual `
                @($actual.inputs) @($expected.inputs))) {
            throw "Generated recipe output $($index + 1) changed."
        }
    }

    $sourceRows = Get-Vkd3dCompilerRowMap @($Closure.source_pair.files) `
        'relative_path' 'canonical source files'
    $generatedRows = Get-Vkd3dCompilerRowMap `
        @($Closure.generated_runs[0].outputs) 'relative_path' `
        'generated output files'
    $unitDefinitions = @(Get-Vkd3dCompilerUnitDefinitions)
    for ($index = 0; $index -lt $unitDefinitions.Count; $index++) {
        $unit = $recipe.compilation_units[$index]
        $expected = $unitDefinitions[$index]
        Assert-Vkd3dCompilerExactProperties $unit @(
            'unit_ordinal', 'input_kind', 'input', 'sha256'
        ) "recipe.compilation_units[$index]"
        $map = if ($expected[0] -ceq 'tracked') { $sourceRows } else { $generatedRows }
        if (-not $map.ContainsKey($expected[1]) -or
            [UInt64]$unit.unit_ordinal -ne [UInt64]($index + 1) -or
            $unit.input_kind -cne $expected[0] -or
            $unit.input -cne $expected[1] -or
            $unit.sha256 -cne $map[$expected[1]].sha256) {
            throw "Compilation unit $($index + 1) changed."
        }
    }
    $componentTracked = @($Component.files | Where-Object {
        @($_.roles) -ccontains 'source-unit'
    } | ForEach-Object relative_path)
    $expectedTracked = @($unitDefinitions | Where-Object { $_[0] -ceq 'tracked' } |
        ForEach-Object { $_[1] })
    if (-not (Test-Vkd3dCompilerStringArrayEqual `
            $componentTracked $expectedTracked)) {
        throw 'Makefile-derived tracked source-unit order changed.'
    }
}

function Assert-Vkd3dCompilerCommandEvidence {
    param([object]$Closure, [object]$Component, [object]$Lock)

    $commands = @($Closure.commands)
    $units = @($Closure.recipe.compilation_units)
    if ($commands.Count -ne 19 -or $units.Count -ne 19) {
        throw 'Compiler command inventory changed.'
    }
    $lockedRecipes = Get-Vkd3dCompilerRowMap @($Lock.recipes) 'id' `
        'toolchain recipes'
    $compileRecipe = $lockedRecipes['compile-c-object']
    $objdumpRecipe = $lockedRecipes['validate-object']
    $sourceRows = Get-Vkd3dCompilerRowMap @($Closure.source_pair.files) `
        'relative_path' 'canonical source files'
    $generatedRows = Get-Vkd3dCompilerRowMap `
        @($Closure.generated_runs[0].outputs) 'relative_path' `
        'generated output files'
    foreach ($row in @($Closure.cross_component_inputs.files)) {
        if (-not $generatedRows.TryAdd([string]$row.target_relative_path, $row)) {
            throw "Generated logical root repeats '$($row.target_relative_path)'."
        }
    }
    $allDependencies = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $dependenciesByRun = @{
        lf = [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
        crlf = [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
    }
    $objectIdentities = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $objectAggregateRows = [Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt 19; $index++) {
        $command = $commands[$index]
        $unit = $units[$index]
        $ordinal = $index + 1
        Assert-Vkd3dCompilerExactProperties $command @(
            'unit_ordinal', 'input_kind', 'input', 'input_sha256',
            'arguments', 'runs', 'twin'
        ) "commands[$index]"
        if ([UInt64]$command.unit_ordinal -ne [UInt64]$ordinal -or
            $command.input_kind -cne $unit.input_kind -or
            $command.input -cne $unit.input -or
            $command.input_sha256 -cne $unit.sha256 -or
            @($command.runs).Count -ne 2) {
            throw "Compiler command $ordinal changed."
        }
        $leaf = Get-Vkd3dEvidenceObjectStem ([string]$command.input)
        $stem = $ordinal.ToString('D2') + '-' + $leaf
        $objectPath = "obj/$stem.o"
        $depfilePath = "dep/$stem.d"
        $inputRoot = if ($command.input_kind -ceq 'tracked') {
            '{source}'
        }
        else { '{generated}' }
        $expectedArguments = @(Expand-Vkd3dCompilerRecipeArguments `
            $compileRecipe @{
                source_root = '{source}'
                generated_root = '{generated}'
                temporary_root = '{temporary}'
                unit_sha256 = [string]$command.input_sha256
                depfile = $depfilePath
                object = $objectPath
                input_c = "$inputRoot/$($command.input)"
            })
        if (-not (Test-Vkd3dCompilerStringArrayEqual `
                @($command.arguments) $expectedArguments)) {
            throw "Compiler command $ordinal arguments changed."
        }

        for ($runIndex = 0; $runIndex -lt 2; $runIndex++) {
            $run = $command.runs[$runIndex]
            $expectedRun = @('lf', 'crlf')[$runIndex]
            Assert-Vkd3dCompilerExactProperties $run @(
                'id', 'dependency_file', 'object', 'objdump'
            ) "command $ordinal run $runIndex"
            if ($run.id -cne $expectedRun) {
                throw "Compiler command $ordinal run order changed."
            }
            $depfile = $run.dependency_file
            Assert-Vkd3dCompilerExactProperties $depfile @(
                'relative_path', 'dependency_count',
                'unique_dependency_count', 'aggregate_sha256', 'files'
            ) "command $ordinal $expectedRun dependency file"
            $dependencyRows = @($depfile.files)
            if ($depfile.relative_path -cne $depfilePath -or
                $dependencyRows.Count -lt 1 -or
                $dependencyRows.Count -gt 4096) {
                throw "Compiler command $ordinal dependency evidence changed."
            }
            $previous = ''
            [UInt64]$derivedOccurrenceCount = 0
            foreach ($dependency in $dependencyRows) {
                Assert-Vkd3dCompilerExactProperties $dependency @(
                    'relative_path', 'occurrence_count', 'bytes', 'sha256'
                ) "command $ordinal dependency"
                $path = [string]$dependency.relative_path
                Assert-Vkd3dCompilerSha256 $dependency.sha256 `
                    "command $ordinal dependency '$path'"
                if ([UInt64]$dependency.occurrence_count -lt 1 -or
                    [UInt64]$dependency.occurrence_count -gt 4096 -or
                    $derivedOccurrenceCount -gt
                        ([UInt64]4096 - [UInt64]$dependency.occurrence_count)) {
                    throw "Compiler command $ordinal dependency multiplicity changed."
                }
                $derivedOccurrenceCount +=
                    [UInt64]$dependency.occurrence_count
                if ($previous.Length -ne 0 -and
                    [StringComparer]::Ordinal.Compare($previous, $path) -ge 0) {
                    throw "Compiler command $ordinal dependencies are not in ordinal order."
                }
                $previous = $path
                $expectedRow = $null
                if ($path.StartsWith('{source}/', [StringComparison]::Ordinal)) {
                    $relative = $path.Substring(9)
                    if (-not $sourceRows.ContainsKey($relative)) {
                        throw "Unknown source dependency '$path'."
                    }
                    $expectedRow = $sourceRows[$relative]
                }
                elseif ($path.StartsWith(
                        '{generated}/', [StringComparison]::Ordinal
                    )) {
                    $relative = $path.Substring(12)
                    if (-not $generatedRows.ContainsKey($relative)) {
                        throw "Unknown generated dependency '$path'."
                    }
                    $expectedRow = $generatedRows[$relative]
                }
                elseif (-not $path.StartsWith(
                        '{gcc_tool}/', [StringComparison]::Ordinal
                    ) -and -not $path.StartsWith(
                        '{ucrt64}/', [StringComparison]::Ordinal
                    )) {
                    throw "Dependency '$path' has an unknown logical root."
                }
                if ($null -ne $expectedRow -and
                    ([UInt64]$dependency.bytes -ne [UInt64]$expectedRow.bytes -or
                        $dependency.sha256 -cne $expectedRow.sha256)) {
                    throw "Dependency '$path' changed from its reviewed input."
                }
                if ($allDependencies.ContainsKey($path)) {
                    $observed = $allDependencies[$path]
                    if ([UInt64]$observed.bytes -ne [UInt64]$dependency.bytes -or
                        $observed.sha256 -cne $dependency.sha256) {
                        throw "Dependency '$path' differs between commands or runs."
                    }
                }
                else { $allDependencies.Add($path, $dependency) }

                $runDependencies = $dependenciesByRun[$expectedRun]
                if ($runDependencies.ContainsKey($path)) {
                    $global = $runDependencies[$path]
                    if ([UInt64]$global.bytes -ne [UInt64]$dependency.bytes -or
                        $global.sha256 -cne $dependency.sha256 -or
                        [UInt64]$global.occurrence_count -gt
                            ([UInt64]77824 -
                                [UInt64]$dependency.occurrence_count)) {
                        throw "Dependency '$path' differs within run '$expectedRun'."
                    }
                    $global.occurrence_count =
                        [UInt64]$global.occurrence_count +
                        [UInt64]$dependency.occurrence_count
                }
                else {
                    $runDependencies.Add($path, [pscustomobject][ordered]@{
                        relative_path = $path
                        occurrence_count =
                            [UInt64]$dependency.occurrence_count
                        bytes = [UInt64]$dependency.bytes
                        sha256 = [string]$dependency.sha256
                    })
                }
            }
            if ([UInt64]$depfile.dependency_count -ne
                    $derivedOccurrenceCount -or
                [UInt64]$depfile.unique_dependency_count -ne
                    [UInt64]$dependencyRows.Count -or
                $depfile.aggregate_sha256 -cne
                    (Get-Vkd3dEvidenceDependencyMultiplicitySha256 `
                        $dependencyRows)) {
                throw "Compiler command $ordinal dependency evidence changed."
            }

            $object = $run.object
            Assert-Vkd3dCompilerExactProperties $object @(
                'relative_path', 'machine', 'machine_name', 'bytes',
                'timestamp', 'raw_sha256', 'normalized_sha256'
            ) "command $ordinal $expectedRun object"
            Assert-Vkd3dCompilerSha256 $object.raw_sha256 `
                "command $ordinal $expectedRun raw object"
            Assert-Vkd3dCompilerSha256 $object.normalized_sha256 `
                "command $ordinal $expectedRun normalized object"
            if ($object.relative_path -cne $objectPath -or
                [UInt64]$object.machine -ne 34404 -or
                $object.machine_name -cne 'amd64' -or
                [UInt64]$object.bytes -lt 20 -or
                [UInt64]$object.bytes -gt 67108864 -or
                [UInt64]$object.timestamp -gt 4294967295) {
                throw "Compiler command $ordinal has malformed AMD64 COFF evidence."
            }
            $objdump = $run.objdump
            Assert-Vkd3dCompilerExactProperties $objdump @(
                'arguments', 'format', 'architecture', 'stdout_bytes',
                'stdout_sha256'
            ) "command $ordinal $expectedRun objdump"
            $expectedObjdump = @(Expand-Vkd3dCompilerRecipeArguments `
                $objdumpRecipe @{ object = $objectPath })
            Assert-Vkd3dCompilerSha256 $objdump.stdout_sha256 `
                "command $ordinal $expectedRun objdump"
            if (-not (Test-Vkd3dCompilerStringArrayEqual `
                    @($objdump.arguments) $expectedObjdump) -or
                $objdump.format -cne 'pe-x86-64' -or
                $objdump.architecture -cne 'i386:x86-64' -or
                [UInt64]$objdump.stdout_bytes -lt 1 -or
                [UInt64]$objdump.stdout_bytes -gt 1048576) {
                throw "Compiler command $ordinal objdump evidence changed."
            }
        }

        Assert-Vkd3dCompilerExactProperties $command.twin @(
            'dependency_match', 'normalized_object_match',
            'objdump_format_match'
        ) "command $ordinal twin"
        foreach ($name in @(
            'dependency_match', 'normalized_object_match',
            'objdump_format_match'
        )) {
            Assert-GswJsonBoolean $command.twin.$name `
                "command $ordinal twin.$name"
            if (-not $command.twin.$name) {
                throw "Compiler command $ordinal twin evidence differs."
            }
        }
        Assert-Vkd3dCompilerDeepEqual `
            $command.runs[0].dependency_file `
            $command.runs[1].dependency_file `
            "Compiler command $ordinal twin dependencies"
        $firstObject = $command.runs[0].object
        $secondObject = $command.runs[1].object
        if ([UInt64]$firstObject.bytes -ne [UInt64]$secondObject.bytes -or
            $firstObject.normalized_sha256 -cne
                $secondObject.normalized_sha256 -or
            $command.runs[0].objdump.format -cne
                $command.runs[1].objdump.format -or
            $command.runs[0].objdump.architecture -cne
                $command.runs[1].objdump.architecture -or
            [UInt64]$command.runs[0].objdump.stdout_bytes -ne
                [UInt64]$command.runs[1].objdump.stdout_bytes -or
            $command.runs[0].objdump.stdout_sha256 -cne
                $command.runs[1].objdump.stdout_sha256) {
            throw "Compiler command $ordinal twin object validation differs."
        }
        if (-not $objectIdentities.Add($objectPath)) {
            throw "Duplicate object identity '$objectPath'."
        }
        $objectAggregateRows.Add([pscustomobject]@{
            unit_ordinal = $ordinal
            object = $objectPath
            bytes = [UInt64]$firstObject.bytes
            normalized_sha256 = [string]$firstObject.normalized_sha256
        })
    }

    $requiredSourcePaths = @($Component.files | Where-Object {
        @($_.roles) -ccontains 'source-unit' -or
        @($_.roles) -ccontains 'compiler-dependency'
    } | ForEach-Object { '{source}/' + [string]$_.relative_path })
    foreach ($path in $requiredSourcePaths) {
        if (-not $allDependencies.ContainsKey($path)) {
            throw "Required component dependency '$path' was not observed."
        }
    }
    foreach ($path in $generatedRows.Keys) {
        if (-not $allDependencies.ContainsKey("{generated}/$path")) {
            throw "Required generated dependency '$path' was not observed."
        }
    }
    if (@($allDependencies.Keys | Where-Object {
            $_.StartsWith('{gcc_tool}/', [StringComparison]::Ordinal) -or
            $_.StartsWith('{ucrt64}/', [StringComparison]::Ordinal)
        }).Count -lt 1) {
        throw 'No locked toolchain dependency was observed.'
    }

    $dependencyRows = @(Get-Vkd3dCompilerSortedDependencyRows `
        @($dependenciesByRun.lf.Values))
    $crlfDependencyRows = @(Get-Vkd3dCompilerSortedDependencyRows `
        @($dependenciesByRun.crlf.Values))
    Assert-Vkd3dCompilerDeepEqual $dependencyRows $crlfDependencyRows `
        'Twin global dependency multiplicity'
    [UInt64]$dependencyOccurrenceCount = 0
    foreach ($row in $dependencyRows) {
        if ($dependencyOccurrenceCount -gt
            ([UInt64]77824 - [UInt64]$row.occurrence_count)) {
            throw 'Global dependency occurrence count overflowed.'
        }
        $dependencyOccurrenceCount += [UInt64]$row.occurrence_count
    }
    $comparison = $Closure.comparison
    Assert-Vkd3dCompilerExactProperties $comparison @(
        'raw_generated_outputs', 'generated_outputs', 'dependencies',
        'normalized_objects'
    ) 'comparison'
    foreach ($name in @(
        'raw_generated_outputs', 'generated_outputs', 'dependencies',
        'normalized_objects'
    )) {
        Assert-GswJsonBoolean $comparison.$name.match "comparison.$name.match"
        if (-not $comparison.$name.match) {
            throw "Comparison '$name' must match."
        }
    }
    Assert-Vkd3dCompilerExactProperties $comparison.raw_generated_outputs @(
        'match', 'count', 'aggregate_sha256'
    ) 'comparison.raw_generated_outputs'
    Assert-Vkd3dCompilerExactProperties $comparison.generated_outputs @(
        'match', 'count', 'aggregate_sha256'
    ) 'comparison.generated_outputs'
    Assert-Vkd3dCompilerExactProperties $comparison.dependencies @(
        'match', 'occurrence_count', 'unique_count', 'aggregate_sha256'
    ) 'comparison.dependencies'
    Assert-Vkd3dCompilerExactProperties $comparison.normalized_objects @(
        'match', 'count', 'aggregate_sha256'
    ) 'comparison.normalized_objects'
    $objectAggregate = Get-MesaObjectAggregateSha256 @($objectAggregateRows)
    if ([UInt64]$comparison.raw_generated_outputs.count -ne 11 -or
        $comparison.raw_generated_outputs.aggregate_sha256 -cne
            $Closure.generated_runs[0].raw_aggregate_sha256 -or
        [UInt64]$comparison.generated_outputs.count -ne 11 -or
        $comparison.generated_outputs.aggregate_sha256 -cne
            $Closure.generated_runs[0].aggregate_sha256 -or
        [UInt64]$comparison.dependencies.occurrence_count -ne
            $dependencyOccurrenceCount -or
        [UInt64]$comparison.dependencies.unique_count -ne
            [UInt64]$dependencyRows.Count -or
        $comparison.dependencies.aggregate_sha256 -cne
            (Get-Vkd3dEvidenceDependencyMultiplicitySha256 `
                $dependencyRows) -or
        [UInt64]$comparison.normalized_objects.count -ne 19 -or
        $comparison.normalized_objects.aggregate_sha256 -cne
            $objectAggregate) {
        throw 'Twin comparison aggregates changed.'
    }
    return [pscustomobject]@{
        DependencyCount = [UInt64]$dependencyRows.Count
        DependencyOccurrenceCount = $dependencyOccurrenceCount
        ObjectAggregate = $objectAggregate
    }
}

function Assert-Vkd3dCompilerSummary {
    param([object]$Closure, [object]$CommandResult)

    $summary = $Closure.summary
    Assert-Vkd3dCompilerExactProperties $summary @(
        'source_files', 'generated_outputs', 'tracked_source_units',
        'generated_source_units', 'compile_commands',
        'twin_compile_invocations', 'dependency_files',
        'validated_amd64_coff_objects', 'objdump_validations',
        'child_processes', 'temporary_output_count', 'proof_root_removed',
        'partial_evidence_removed', 'linker_invocations',
        'failed_generator_commands', 'failed_compile_commands',
        'failed_dependency_validations', 'failed_object_validations'
    ) 'summary'
    Assert-GswJsonBoolean $summary.proof_root_removed `
        'summary.proof_root_removed'
    Assert-GswJsonBoolean $summary.partial_evidence_removed `
        'summary.partial_evidence_removed'
    $generatorChildren = @($Closure.generated_runs | ForEach-Object {
        @($_.generator_commands | Where-Object {
            $_.tool_file_id -cne 'retvrn99-reviewed-bytes'
        }).Count
    } | Measure-Object -Sum).Sum
    $expectedChildren = @($Closure.toolchain.probes).Count +
        (2 * 5) + @($Closure.source_pair.files).Count +
        [UInt64]$generatorChildren +
        (2 * @($Closure.commands).Count) +
        (2 * @($Closure.commands).Count) +
        (2 * 4) + @($Closure.source_pair.files).Count
    if ([UInt64]$summary.source_files -ne
            [UInt64]$Closure.source_pair.files.Count -or
        [UInt64]$summary.generated_outputs -ne
            [UInt64]$Closure.generated_runs[0].outputs.Count -or
        [UInt64]$summary.tracked_source_units -ne 15 -or
        [UInt64]$summary.generated_source_units -ne 4 -or
        [UInt64]$summary.compile_commands -ne
            [UInt64]$Closure.commands.Count -or
        [UInt64]$summary.twin_compile_invocations -ne
            [UInt64](2 * $Closure.commands.Count) -or
        [UInt64]$summary.dependency_files -ne
            [UInt64](2 * $Closure.commands.Count) -or
        [UInt64]$summary.validated_amd64_coff_objects -ne
            [UInt64](2 * $Closure.commands.Count) -or
        [UInt64]$summary.objdump_validations -ne
            [UInt64](2 * $Closure.commands.Count) -or
        [UInt64]$summary.child_processes -ne [UInt64]$expectedChildren -or
        [UInt64]$summary.temporary_output_count -ne 0 -or
        -not $summary.proof_root_removed -or
        -not $summary.partial_evidence_removed -or
        [UInt64]$summary.linker_invocations -ne 0 -or
        [UInt64]$summary.failed_generator_commands -ne 0 -or
        [UInt64]$summary.failed_compile_commands -ne 0 -or
        [UInt64]$summary.failed_dependency_validations -ne 0 -or
        [UInt64]$summary.failed_object_validations -ne 0) {
        throw 'Compiler evidence summary or cleanup counts changed.'
    }
}

function Read-Vkd3dCompilerLockBinding {
    param([string]$Root, [object]$Binding)

    Assert-Vkd3dCompilerExactProperties $Binding @(
        'relative_path', 'bytes', 'sha256', 'status'
    ) 'toolchain lock binding'
    if ($Binding.relative_path -cne 'vkd3d-shader-toolchain-lock.json' -or
        $Binding.status -cne 'ready') {
        throw 'Toolchain lock binding identity changed.'
    }
    Assert-Vkd3dCompilerRelativePath $Binding.relative_path `
        'toolchain lock binding path'
    Assert-Vkd3dCompilerSha256 $Binding.sha256 `
        'toolchain lock binding hash'
    $snapshot = Read-GswStrictJsonFileSnapshot `
        -Path (Join-Path $Root ([string]$Binding.relative_path)) `
        -Name 'bound vkd3d-shader toolchain lock' -MaximumBytes 1048576
    if ([UInt64]$snapshot.Bytes.Length -ne [UInt64]$Binding.bytes -or
        $snapshot.Sha256 -cne $Binding.sha256) {
        throw 'Toolchain lock input binding drifted.'
    }
    return $snapshot.Value
}

if ([string]::IsNullOrWhiteSpace($DriversRoot)) {
    $DriversRoot = Join-Path $PSScriptRoot '..\drivers\win98'
}
$drivers = [IO.Path]::GetFullPath($DriversRoot)
if ([string]::IsNullOrWhiteSpace($ClosureFile)) {
    $ClosureFile = Join-Path $drivers `
        'vkd3d-shader-compiler-closure.json'
}
$snapshot = Read-GswStrictJsonFileSnapshot -Path $ClosureFile `
    -Name 'vkd3d-shader compiler closure' -MaximumBytes 16777216
$closure = $snapshot.Value
Assert-Vkd3dCompilerExactProperties $closure @(
    '_spdx', 'schema', 'schema_definition', 'status', 'source',
    'source_pair', 'cross_component_inputs', 'toolchain', 'recipe',
    'generated_runs', 'commands', 'comparison', 'summary',
    'authorizations'
) 'vkd3d-shader compiler closure'
if ($closure._spdx -cne 'GPL-3.0-only' -or $closure.schema -ne 1 -or
    $closure.status -cne 'compile-proven') {
    throw 'vkd3d-shader compiler closure identity or status changed.'
}
Assert-Vkd3dCompilerNoPrivatePaths $closure 'vkd3d-shader compiler closure'

Assert-Vkd3dCompilerExactProperties $closure.schema_definition @(
    'relative_path', 'bytes', 'sha256'
) 'schema_definition'
if ($closure.schema_definition.relative_path -cne
    'vkd3d-shader-compiler-closure.schema.json') {
    throw 'Compiler-closure schema path changed.'
}
$schemaPath = Join-Path $drivers `
    ([string]$closure.schema_definition.relative_path)
$schemaSnapshot = Read-GswStrictJsonFileSnapshot -Path $schemaPath `
    -Name 'bound vkd3d-shader compiler schema' -MaximumBytes 1048576
if ([UInt64]$schemaSnapshot.Bytes.Length -ne
        [UInt64]$closure.schema_definition.bytes -or
    $schemaSnapshot.Sha256 -cne $closure.schema_definition.sha256 -or
    $schemaSnapshot.Value._spdx -cne 'GPL-3.0-only' -or
    $schemaSnapshot.Value.'$id' -cne
        'vkd3d-shader-compiler-closure.schema.json' -or
    $schemaSnapshot.Value.properties.schema.const -ne 1 -or
    $schemaSnapshot.Value.properties.status.const -cne 'compile-proven') {
    throw 'Compiler-closure schema binding changed.'
}

Assert-Vkd3dCompilerExactProperties $closure.source @(
    'component', 'repository', 'owning_commit', 'component_manifest',
    'git_tool'
) 'source'
if ($closure.source.component -cne 'vkd3d-shader' -or
    $closure.source.repository -cne $script:Vkd3dCompilerRepository -or
    $closure.source.owning_commit -cne $script:Vkd3dCompilerCommit -or
    $closure.source.component_manifest.relative_path -cne
        'component-closures/vkd3d-shader.json' -or
    $closure.source.component_manifest.status -cne 'ready' -or
    [UInt64]$closure.source.component_manifest.file_count -ne 40) {
    throw 'Pinned vkd3d-shader source binding changed.'
}
$component = Read-Vkd3dCompilerBoundJson $drivers `
    $closure.source.component_manifest 'bound vkd3d-shader component manifest' `
    1048576
if ($component.schema -ne 2 -or $component.status -cne 'ready' -or
    $component.upstream_name -cne 'vkd3d-shader' -or
    $component.owning_commit -cne $script:Vkd3dCompilerCommit -or
    @($component.files).Count -ne 40) {
    throw 'Bound vkd3d-shader component manifest is not ready and exact.'
}

if ($closure.cross_component_inputs.component_manifest.relative_path -cne
        'component-closures/mesa9x-23.1.x.json' -or
    $closure.cross_component_inputs.component_manifest.status -cne 'ready' -or
    [UInt64]$closure.cross_component_inputs.component_manifest.file_count -ne
        1687) {
    throw 'Mesa component input binding changed.'
}
$mesa = Read-Vkd3dCompilerBoundJson $drivers `
    $closure.cross_component_inputs.component_manifest `
    'bound Mesa component manifest' 2097152
if ($mesa.schema -ne 2 -or $mesa.status -cne 'ready' -or
    $mesa.owning_commit -cne $script:Vkd3dCompilerMesaCommit -or
    @($mesa.files).Count -ne 1687) {
    throw 'Bound Mesa component manifest is not ready and exact.'
}
$lock = Read-Vkd3dCompilerLockBinding $drivers $closure.toolchain.lock
if ($lock.schema -ne 1 -or $lock.status -cne 'ready') {
    throw 'Bound vkd3d-shader toolchain lock is not ready.'
}

Assert-Vkd3dCompilerExactProperties $closure.source.git_tool @(
    'file_id', 'bytes', 'sha256', 'probe_id', 'version'
) 'source.git_tool'
$lockFiles = Get-Vkd3dCompilerRowMap @($lock.files) 'id' 'locked tool files'
$lockProbes = Get-Vkd3dCompilerRowMap @($lock.tool_probes) 'id' `
    'locked tool probes'
$gitRow = $lockFiles['git-core']
$gitProbe = $lockProbes['git-version']
if ($closure.source.git_tool.file_id -cne 'git-core' -or
    [UInt64]$closure.source.git_tool.bytes -ne [UInt64]$gitRow.bytes -or
    $closure.source.git_tool.sha256 -cne $gitRow.sha256 -or
    $closure.source.git_tool.probe_id -cne 'git-version' -or
    $closure.source.git_tool.version -cne $gitProbe.expected_lines[0]) {
    throw 'Pinned Git tool evidence changed.'
}

Assert-Vkd3dCompilerSourcePair $closure $component
Assert-Vkd3dCompilerCrossComponentInputs $closure $mesa
Assert-Vkd3dCompilerToolchain $closure $lock
Assert-Vkd3dCompilerExactProperties $closure.toolchain.environment @(
    'path_policy', 'perl5lib_roots', 'ambient_library_paths'
) 'toolchain.environment'
Assert-GswJsonBoolean $closure.toolchain.environment.ambient_library_paths `
    'toolchain.environment.ambient_library_paths'
if ($closure.toolchain.environment.path_policy -cne
        'executable-parent-directories-only' -or
    -not (Test-Vkd3dCompilerStringArrayEqual `
        @($closure.toolchain.environment.perl5lib_roots) @(
            'git:usr/share/perl5/vendor_perl',
            'git:usr/share/perl5/core_perl',
            'git:usr/lib/perl5/core_perl'
        )) -or $closure.toolchain.environment.ambient_library_paths) {
    throw 'Compiler evidence environment changed.'
}
Assert-Vkd3dCompilerGeneratedRuns $closure $lock
Assert-Vkd3dCompilerRecipe $closure $component $lock
$commandResult = Assert-Vkd3dCompilerCommandEvidence `
    $closure $component $lock
Assert-Vkd3dCompilerSummary $closure $commandResult
Assert-Vkd3dCompilerExactProperties $closure.authorizations @(
    'fetch', 'download', 'production_build', 'link',
    'persistent_artifacts', 'stage', 'install', 'activate',
    'guest_execution', 'renderer_selection', 'capability_advertisement',
    'unreviewed_generator_execution'
) 'authorizations'
Assert-Vkd3dCompilerFalseValues $closure.authorizations 'authorizations'

Write-Output (
    'Verified vkd3d-shader compiler closure: 40 canonical source files, ' +
    '11 twin generated outputs, 19 twin AMD64 COFF objects, ' +
    "$($commandResult.DependencyCount) evidence-derived dependencies, " +
    'complete temporary cleanup, authorizations=false.'
)

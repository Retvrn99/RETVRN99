# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$ClosureFile,
    [string]$SourceRoot,
    [string]$GeneratedRoot,
    [string]$ToolchainRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'mesa-object-proof.ps1')
. (Join-Path $PSScriptRoot 'mesa-compiler-dependency-roles.ps1')

function Get-CompilerClosureHash {
    param([byte[]]$Bytes)

    return Get-MesaObjectSha256 $Bytes
}

function Assert-CompilerClosureFalseValues {
    param([object]$Value, [string]$Label)

    foreach ($property in $Value.PSObject.Properties) {
        Assert-GswJsonBoolean $property.Value "$Label.$($property.Name)"
        if ($property.Value) { throw "$Label.$($property.Name) must remain false." }
    }
}

function Read-CompilerClosureInput {
    param([string]$Root, [object]$Binding)

    $path = Join-Path $Root ([string]$Binding.relative_path)
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ne [int64]$Binding.bytes -or
        (Get-CompilerClosureHash $bytes) -cne $Binding.sha256) {
        throw "Compiler-closure input '$($Binding.id)' changed."
    }
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

function Assert-ExternalHeader {
    param([object]$Header, [hashtable]$Roots)

    $root = $Roots[[string]$Header.root]
    $path = Join-Path $root ($Header.relative_path.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Header '$($Header.root)/$($Header.relative_path)' is absent."
    }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ne [int64]$Header.bytes -or
        (Get-CompilerClosureHash $bytes) -cne $Header.sha256) {
        throw "Header '$($Header.root)/$($Header.relative_path)' changed."
    }
}

function Assert-NoCompilerPrivatePaths {
    param([object]$Value, [string]$Label)

    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if ($Value -match '(?i)(^|[=\s"])[a-z]:[\\/]' -or
            $Value.StartsWith('\\')) {
            throw "$Label contains a private absolute path."
        }
        return
    }
    if ($Value -is [Collections.IEnumerable] -and
        $Value -isnot [Management.Automation.PSCustomObject]) {
        $index = 0
        foreach ($item in $Value) {
            Assert-NoCompilerPrivatePaths $item "$Label[$index]"
            $index++
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        Assert-NoCompilerPrivatePaths $property.Value `
            "$Label.$($property.Name)"
    }
}

function Assert-ExactStringArray {
    param([object[]]$Actual, [string[]]$Expected, [string]$Name)

    if ($Actual.Count -ne $Expected.Count) {
        throw "$Name has the wrong item count."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$Actual[$index] -cne $Expected[$index]) {
            throw "$Name item $index changed."
        }
    }
}

function Assert-ExactCompilerTargetDefines {
    param([object[]]$Arguments, [string]$Name)

    foreach ($expected in @(
        '-DWINVER=0x0400',
        '-D_WIN32_WINNT=0x0400',
        '-D_WIN32_WINDOWS=0x0410'
    )) {
        $prefix = $expected.Substring(0, $expected.IndexOf('=') + 1)
        $matches = @($Arguments | Where-Object {
            ([string]$_).StartsWith($prefix, [StringComparison]::Ordinal)
        })
        if ($matches.Count -ne 1 -or [string]$matches[0] -cne $expected) {
            throw "$Name must contain one exact '$expected' target definition."
        }
    }
}

function Assert-ExactCompilerUnitOverrides {
    param([object]$Actual, [string]$Name)

    $overrides = @($Actual)
    $expected = @(
        [pscustomobject]@{
            CommandId = 'cmd-0002'
            Source = '{source}/mesa-23.1.x/src/c11/impl/threads_posix.c'
            Arguments = '-DHAVE_PTHREAD'
        }
        [pscustomobject]@{
            CommandId = 'cmd-0792'
            Source = '{source}/mesa-23.1.x/src/util/rwlock.c'
            Arguments = '-DHAVE_PTHREAD'
        }
        [pscustomobject]@{
            CommandId = 'cmd-0852'
            Source = '{generated}/mesa-23.1.x/src/mapi/glapi/gen/glapi_x86.S'
            Arguments = '-DUSE_X86_ASM|-DGLX_X86_READONLY_TEXT'
        }
    )
    if ($overrides.Count -ne $expected.Count) {
        throw "$Name must contain three exact ordered unit overrides."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $override = $overrides[$index]
        Assert-GswJsonExactProperties $override @(
            'command_id', 'source', 'profiles', 'insertion', 'arguments', 'mode'
        ) "$Name unit override $index"
        if ($override.command_id -cne $expected[$index].CommandId -or
            $override.source -cne $expected[$index].Source -or
            (@($override.profiles) -join '|') -cne
                'mesa-dependency-v1|mesa-object-v1' -or
            $override.insertion -cne 'after-common-before-language' -or
            (@($override.arguments) -join '|') -cne
                $expected[$index].Arguments -or
            $override.mode -cne 'compile-context-only-no-link') {
            throw "$Name unit override $index changed."
        }
    }
}

function Assert-CompilerIncludePrecedence {
    param([object[]]$Arguments, [string]$Name)

    $generated = [Collections.Generic.Dictionary[string,int]]::new(
        [StringComparer]::Ordinal
    )
    $source = [Collections.Generic.Dictionary[string,int]]::new(
        [StringComparer]::Ordinal
    )
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        if ($argument.StartsWith('{generated}/', [StringComparison]::Ordinal)) {
            $generated.Add($argument.Substring(12), $index)
        }
        elseif ($argument.StartsWith('{source}/', [StringComparison]::Ordinal)) {
            $source.Add($argument.Substring(9), $index)
        }
    }
    if ($generated.Count -eq 0 -or $generated.Count -ne $source.Count) {
        throw "$Name generated/source include inventory changed."
    }
    foreach ($relative in $generated.Keys) {
        if (-not $source.ContainsKey($relative) -or
            $generated[$relative] -ge $source[$relative]) {
            throw "$Name does not prioritize reviewed generated inputs."
        }
    }
    if (($generated.Values | Measure-Object -Maximum).Maximum -ge
        ($source.Values | Measure-Object -Minimum).Minimum) {
        throw "$Name interleaves generated and source include roots."
    }
}

if ([string]::IsNullOrWhiteSpace($ClosureFile)) {
    $ClosureFile = Join-Path $PSScriptRoot `
        '..\drivers\win98\mesa-compiler-closure.json'
}
$snapshot = Read-GswStrictJsonFileSnapshot -Path $ClosureFile `
    -Name 'Mesa compiler closure' -MaximumBytes ([UInt64]4194304)
$closure = $snapshot.Value
$driversRoot = Split-Path -Parent $snapshot.Path

Assert-GswJsonExactProperties $closure @(
    '_spdx', 'schema', 'schema_definition', 'status', 'reason', 'source',
    'inputs', 'direct_recipe', 'depfile_contract', 'object_contract',
    'exclusions', 'evidence', 'scope'
) 'Mesa compiler closure'
if ($closure._spdx -cne 'GPL-3.0-only' -or $closure.schema -ne 3 -or
    $closure.status -cne 'compile-proven') {
    throw 'Mesa compiler closure identity or status changed.'
}
Assert-NoCompilerPrivatePaths $closure 'Mesa compiler closure'

$schemaPath = Join-Path $driversRoot $closure.schema_definition.relative_path
$schemaBytes = [IO.File]::ReadAllBytes($schemaPath)
if ($schemaBytes.Length -ne [int64]$closure.schema_definition.bytes -or
    (Get-CompilerClosureHash $schemaBytes) -cne
        $closure.schema_definition.sha256) {
    throw 'Mesa compiler closure schema binding changed.'
}
$schemaText = [Text.UTF8Encoding]::new($false, $true).GetString($schemaBytes)
$schema = ConvertFrom-GswStrictJson -Json $schemaText -Source $schemaPath
if ($schema._spdx -cne 'GPL-3.0-only' -or
    $schema.'$id' -cne 'mesa-compiler-closure.schema.json' -or
    $schema.properties.schema.const -ne 3 -or
    $schema.properties.status.const -cne 'compile-proven') {
    throw 'Mesa compiler closure schema contract changed.'
}

$expectedInputs = @(
    @('mesa-direct-build-plan', 'metadata-only-exact-874-units'),
    @('mesa-component-closure', 'ready-compiler-role-complete'),
    @('mesa-generated-output-lock', 'reviewed-generated-source'),
    @('mesa-generated-reproducibility', 'proven'),
    @('original-gsw-memory-source', 'reviewed-original-source'),
    @('original-gsw-winsys-source', 'capability-disabled-shell'),
    @('gsw-disabled-software-winsys-sentinel', 'capability-disabled-empty-sentinel'),
    @('guest-cpu-profile', 'immutable-profile'),
    @('mingw32-toolchain', 'extracted-tree-locked')
)
if ($closure.inputs.Count -ne $expectedInputs.Count) {
    throw 'Mesa compiler closure must bind nine ordered inputs.'
}
$inputTexts = @()
for ($index = 0; $index -lt $expectedInputs.Count; $index++) {
    $binding = $closure.inputs[$index]
    if ($binding.id -cne $expectedInputs[$index][0] -or
        $binding.required_state -cne $expectedInputs[$index][1] -or
        $binding.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Compiler-closure input $index changed."
    }
    $inputTexts += Read-CompilerClosureInput $driversRoot $binding
}
$plan = ConvertFrom-GswStrictJson -Json $inputTexts[0] `
    -Source 'bound direct-build plan'
$component = ConvertFrom-GswStrictJson -Json $inputTexts[1] `
    -Source 'bound component closure'
$cpuProfile = ConvertFrom-GswStrictJson -Json $inputTexts[7] `
    -Source 'bound guest CPU profile'
if ($plan.inventory.total_source_units -ne 874 -or
    $plan.inventory.direct_compile_units -ne 869 -or
    $plan.inventory.support_only_units -ne 5) {
    throw 'Bound direct-build plan inventory changed.'
}
foreach ($name in @(
    'compiler_commands', 'headers', 'depfiles', 'exports', 'link_steps',
    'artifacts'
)) {
    if ($plan.empty_evidence.$name.Count -ne 0) {
        throw "Direct-build plan $name evidence must remain empty."
    }
}
if ($component.schema -ne 2 -or $component.status -cne 'ready' -or
    $component.owning_commit -cne $closure.source.owning_commit -or
    @($component.files).Count -ne 1687) {
    throw 'Bound Mesa component closure is not ready and complete.'
}
$componentDependencies = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($file in $component.files) {
    if (@($file.roles) -ccontains 'compiler-dependency') {
        $componentDependencies.Add([string]$file.relative_path, $file)
    }
}
if ($componentDependencies.Count -ne 652) {
    throw 'Bound Mesa component closure lacks 652 compiler dependencies.'
}

$recipe = $closure.direct_recipe
if ($recipe.status -cne 'exact-metadata-with-compiler-object-evidence' -or
    $recipe.inventory_units -ne 874 -or $recipe.compile_units -ne 869 -or
    $recipe.support_only_units -ne 5 -or
    $recipe.compiler_command_count -ne 869 -or
    $recipe.upstream_makefile_command_consumption) {
    throw 'Exact direct recipe summary changed.'
}
$contract = $closure.depfile_contract
if ($contract.mode -cne 'gcc-M-MF-MT' -or
    $contract.missing_header_mode -cne 'reject-no-MG' -or
    -not $contract.include_system_headers -or
    -not $contract.one_depfile_per_command -or
    -not $contract.twin_run_required -or
    $contract.proof_source_root -cne
        'exact-materialized-1489-file-canonical-lf-root' -or
    $contract.include_precedence -cne
        'reviewed-generated-before-canonical-source' -or
    ($contract.logical_roots -join '|') -cne
        'source|generated|original|toolchain') {
    throw 'Depfile contract changed.'
}
$objectContract = $closure.object_contract
if ($objectContract.format -cne 'coff-i386' -or
    $objectContract.machine -ne 332 -or
    $objectContract.optional_header_bytes -ne 0 -or
    $objectContract.timestamp_offset -ne 4 -or
    $objectContract.timestamp_bytes -ne 4 -or
    ($objectContract.normalized_byte_offsets -join '|') -cne '4|5|6|7' -or
    $objectContract.maximum_object_bytes -ne 67108864 -or
    -not $objectContract.twin_run_required -or
    -not $objectContract.object_identity_collision_free -or
    $objectContract.private_path_policy -cne
        'reject-bound-roots-ascii-utf8-utf16le-before-hash' -or
    $objectContract.aggregate_algorithm -cne 'sha256-utf8-tab-records-v1' -or
    $objectContract.temporary_outputs_retained -or
    $objectContract.linker_invocations -ne 0 -or
    $objectContract.include_precedence -cne
        'reviewed-generated-before-canonical-source') {
    throw 'Object normalization contract changed.'
}

$supportOnly = @($closure.exclusions.support_only_generated_sources)
Assert-GswJsonExactProperties $closure.exclusions @(
    'source_path_fragments', 'include_path_fragments', 'common_define_names',
    'define_prefixes',
    'support_only_generated_sources'
) 'Compiler exclusions'
if (($supportOnly -join '|') -cne (
    'mesa-23.1.x/src/gallium/auxiliary/util/u_tracepoints.c|' +
    'mesa-23.1.x/src/mapi/glapi/gen/indirect.c|' +
    'mesa-23.1.x/src/mapi/glapi/gen/indirect_init.c|' +
    'mesa-23.1.x/src/mapi/glapi/gen/indirect_size.c|' +
    'mesa-23.1.x/src/mapi/glapi/glapi_gentable.c'
)) { throw 'Support-only generated-source set changed.' }
$expectedCommonDefineNames = @(
    'GALLIUM_SOFTPIPE', 'HAVE_PTHREAD', 'USE_X86_ASM',
    'GLX_X86_READONLY_TEXT', 'HAVE_LLVM', 'HAVE_GALLIUM_LLVMPIPE',
    'GALLIUM_LLVMPIPE', 'HAVE_LLVMPIPE', 'DRAW_LLVM_AVAILABLE'
)
Assert-ExactStringArray @($closure.exclusions.common_define_names) `
    $expectedCommonDefineNames 'Compiler common define exclusions'

Assert-GswJsonExactProperties $closure.evidence @(
    'profile', 'object_profile', 'unit_argument_overrides', 'commands',
    'headers', 'objects', 'summary'
) 'Compiler evidence'
$profile = $closure.evidence.profile
Assert-GswJsonExactProperties $profile @(
    'id', 'mode', 'missing_header_mode', 'include_system_headers',
    'timeout_seconds', 'maximum_concurrent_children', 'batch_size',
    'batch_quiescence_milliseconds', 'common_arguments', 'language_arguments'
) 'Compiler dependency profile'
if ($profile.id -cne 'mesa-dependency-v1' -or
    $profile.mode -cne 'gcc-M-MF-MT' -or
    $profile.missing_header_mode -cne 'reject-no-MG' -or
    -not $profile.include_system_headers -or
    $profile.timeout_seconds -ne 30 -or
    $profile.maximum_concurrent_children -ne 1 -or
    $profile.batch_size -ne 25 -or
    $profile.batch_quiescence_milliseconds -ne 1000 -or
    $profile.common_arguments -contains '-MG') {
    throw 'Compiler dependency profile changed.'
}
$objectProfile = $closure.evidence.object_profile
Assert-GswJsonExactProperties $objectProfile @(
    'id', 'mode', 'timeout_seconds', 'common_arguments',
    'maximum_concurrent_children', 'batch_size',
    'batch_quiescence_milliseconds', 'language_arguments',
    'per_unit_arguments',
    'working_directory', 'linker_invocations'
) 'Compiler object profile'
if ($objectProfile.id -cne 'mesa-object-v1' -or
    $objectProfile.mode -cne 'compile-only-no-link' -or
    $objectProfile.timeout_seconds -ne 30 -or
    $objectProfile.maximum_concurrent_children -ne 1 -or
    $objectProfile.batch_size -ne 25 -or
    $objectProfile.batch_quiescence_milliseconds -ne 1000 -or
    $objectProfile.working_directory -cne '{proof}' -or
    $objectProfile.linker_invocations -ne 0) {
    throw 'Compiler object profile changed.'
}
Assert-ExactCompilerUnitOverrides $closure.evidence.unit_argument_overrides `
    'Compiler evidence'
$expectedPerUnit = @(
    '-frandom-seed=retvrn99-mesa-{command-id}-v1',
    '-ffile-prefix-map={source}=retvrn99/source',
    '-fmacro-prefix-map={source}=retvrn99/source',
    '-ffile-prefix-map={generated}=retvrn99/generated',
    '-fmacro-prefix-map={generated}=retvrn99/generated',
    '-ffile-prefix-map={original}=retvrn99/original',
    '-fmacro-prefix-map={original}=retvrn99/original',
    '-ffile-prefix-map={toolchain}=retvrn99/toolchain',
    '-fmacro-prefix-map={toolchain}=retvrn99/toolchain',
    '-ffile-prefix-map={proof}=retvrn99/proof',
    '-fmacro-prefix-map={proof}=retvrn99/proof',
    '-c', '{source-file}', '-o', '{object-file}'
)
Assert-ExactStringArray @($objectProfile.per_unit_arguments) `
    $expectedPerUnit 'Object per-unit arguments'
$common = @($profile.common_arguments)
$objectCommon = @($objectProfile.common_arguments)
Assert-ExactCompilerTargetDefines $common 'Compiler dependency profile'
Assert-ExactCompilerTargetDefines $objectCommon 'Compiler object profile'
Assert-CompilerIncludePrecedence $common 'Compiler dependency profile'
Assert-CompilerIncludePrecedence $objectCommon 'Compiler object profile'
foreach ($flag in $cpuProfile.toolchains.mingw.cpu_flags) {
    if ($common -cnotcontains [string]$flag -or
        $objectCommon -cnotcontains [string]$flag) {
        throw "Compiler profiles lack CPU flag '$flag'."
    }
}
foreach ($flag in @(
    '-fno-ident', '-fno-asynchronous-unwind-tables', '-fno-unwind-tables',
    '-fno-stack-protector'
)) {
    if ($objectCommon -cnotcontains $flag) {
        throw "Object profile lacks deterministic flag '$flag'."
    }
}
$combinedCommonText = ($common + $objectCommon) -join "`n"
foreach ($fragment in $closure.exclusions.include_path_fragments) {
    if ($combinedCommonText.IndexOf(
            $fragment, [StringComparison]::OrdinalIgnoreCase
        ) -ge 0) {
        throw "Compiler profile contains forbidden include fragment '$fragment'."
    }
}
foreach ($name in $closure.exclusions.common_define_names) {
    foreach ($arguments in @($common, $objectCommon)) {
        if ($arguments -contains "-D$name" -or
            @($arguments | Where-Object {
                $_.StartsWith("-D$name=", [StringComparison]::Ordinal)
            }).Count -ne 0) {
            throw "Compiler profile contains forbidden define '$name'."
        }
    }
}
foreach ($argument in ($common + $objectCommon)) {
    if ($argument.StartsWith('-DVBOX_', [StringComparison]::Ordinal)) {
        throw 'Compiler profile contains a forbidden VBOX define.'
    }
}

$compileUnits = @($plan.units | Where-Object {
    $_.disposition -cne 'reviewed-generated-support-metadata-only'
})
$commands = @($closure.evidence.commands)
if ($commands.Count -ne 869 -or $compileUnits.Count -ne 869) {
    throw 'Compiler command count changed.'
}
$commandIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
for ($index = 0; $index -lt $commands.Count; $index++) {
    $command = $commands[$index]
    $unit = $compileUnits[$index]
    $id = 'cmd-' + ($index + 1).ToString('D4')
    $root = switch ($unit.source_kind) {
        'upstream' { '{source}' }
        'generated' { '{generated}' }
        'original-gsw' { '{original}' }
    }
    $compiler = if ($unit.language -ceq 'cxx-gnu++14') {
        '{toolchain}/bin/i686-w64-mingw32-g++.exe'
    }
    else { '{toolchain}/bin/i686-w64-mingw32-gcc.exe' }
    if (-not $commandIds.Add([string]$command.id) -or
        $command.id -cne $id -or $command.unit_ordinal -ne $index + 1 -or
        $command.language -cne $unit.language -or
        $command.compiler -cne $compiler -or
        $command.source -cne "$root/$($unit.relative_path)" -or
        $command.object -cne $unit.object_identity -or
        $command.depfile -cne "dep/$id.d" -or
        $command.profile -cne 'mesa-dependency-v1' -or
        $command.dependency_count -lt 1 -or
        $command.twin_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Compiler command '$id' is not exact."
    }
    foreach ($fragment in $closure.exclusions.source_path_fragments) {
        if ($command.source.IndexOf(
                $fragment, [StringComparison]::OrdinalIgnoreCase
            ) -ge 0) {
            throw "Compiler command '$id' selects forbidden source '$fragment'."
        }
    }
}

$headers = @($closure.evidence.headers)
$headerIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$counts = @{ source = 0; generated = 0; original = 0; toolchain = 0 }
$previous = ''
foreach ($header in $headers) {
    $identity = "{$($header.root)}/$($header.relative_path)"
    if ($previous.Length -ne 0 -and
        [StringComparer]::Ordinal.Compare($previous, $identity) -ge 0) {
        throw 'Compiler header evidence is not in exact ordinal order.'
    }
    $previous = $identity
    if (-not $headerIds.Add($identity) -or
        -not $counts.ContainsKey([string]$header.root) -or
        $header.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid compiler header '$identity'."
    }
    $counts[[string]$header.root]++
    if ($header.root -ceq 'source') {
        if (-not $componentDependencies.ContainsKey(
                [string]$header.relative_path
            )) {
            throw "Source dependency '$($header.relative_path)' lacks component closure."
        }
        Assert-MesaCanonicalCompilerDependencyEvidence -Header $header `
            -File $componentDependencies[[string]$header.relative_path]
        foreach ($fragment in $closure.exclusions.source_path_fragments) {
            if ($header.relative_path.IndexOf(
                    $fragment, [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                throw "Header evidence contains forbidden source '$fragment'."
            }
        }
    }
}
$dependencyRoles = Resolve-MesaCompilerDependencyRoles $headers
if ($counts.source -ne 651 -or
    $dependencyRoles.Mode -cne 'generated-replacement-observed') {
    throw 'Compiler headers changed the generated-shadowed dependency role.'
}
foreach ($path in $dependencyRoles.RolePaths) {
    if (-not $componentDependencies.ContainsKey($path)) {
        throw "Compiler dependency role '$path' lacks component closure."
    }
}
Assert-MesaShadowedCompilerDependencyRole `
    $componentDependencies[$dependencyRoles.ShadowedPath]

$objects = @($closure.evidence.objects)
if ($objects.Count -ne 869) { throw 'Compiler object count changed.' }
$objectIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
for ($index = 0; $index -lt $objects.Count; $index++) {
    $object = $objects[$index]
    $ordinal = $index + 1
    $objectId = 'object-' + $ordinal.ToString('D4')
    $commandId = 'cmd-' + $ordinal.ToString('D4')
    Assert-GswJsonExactProperties $object @(
        'id', 'command_id', 'unit_ordinal', 'object', 'random_seed', 'bytes',
        'run_a', 'run_b', 'normalized_sha256', 'twin_byte_identical'
    ) "object evidence $objectId"
    foreach ($runName in @('run_a', 'run_b')) {
        $run = $object.$runName
        Assert-GswJsonExactProperties $run @(
            'raw_sha256', 'timestamp', 'normalized_sha256'
        ) "object evidence $objectId $runName"
        if ($run.raw_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $run.normalized_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $run.timestamp -lt 0 -or $run.timestamp -gt 4294967295) {
            throw "Object evidence '$objectId' has an invalid run."
        }
    }
    if ($object.id -cne $objectId -or
        $object.command_id -cne $commandId -or
        $object.unit_ordinal -ne $ordinal -or
        $object.object -cne $commands[$index].object -or
        $object.object -cne $compileUnits[$index].object_identity -or
        $object.random_seed -cne "retvrn99-mesa-$commandId-v1" -or
        $object.bytes -lt 20 -or $object.bytes -gt 67108864 -or
        -not $object.twin_byte_identical -or
        $object.normalized_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $object.run_a.normalized_sha256 -cne $object.normalized_sha256 -or
        $object.run_b.normalized_sha256 -cne $object.normalized_sha256 -or
        -not $objectIds.Add([string]$object.object)) {
        throw "Object evidence '$objectId' is not exact."
    }
}
$aggregate = Get-MesaObjectAggregateSha256 $objects
$summary = $closure.evidence.summary
if ($summary.command_count -ne 869 -or
    $summary.twin_depfile_count -ne 1738 -or
    $summary.unique_dependency_count -ne 1070 -or
    $headers.Count -ne 1070 -or
    -not $summary.twin_byte_identical -or
    $summary.failed_command_count -ne 0 -or
    -not $summary.exact_source_root -or
    $summary.exact_source_root_file_count -ne 1489 -or
    $summary.object_compile_count -ne 1738 -or
    $summary.unique_object_count -ne 869 -or
    -not $summary.twin_objects_byte_identical -or
    $summary.object_identity_collision_count -ne 0 -or
    $summary.failed_object_compile_count -ne 0 -or
    $summary.temporary_object_count -ne 0 -or
    $summary.aggregate_object_sha256 -cne $aggregate) {
    throw 'Compiler evidence summary changed.'
}
foreach ($rootName in $counts.Keys) {
    if ($summary.dependency_root_counts.$rootName -ne $counts[$rootName]) {
        throw "Compiler dependency count for '$rootName' changed."
    }
}
if ($counts.source -ne 651 -or $counts.generated -ne 29 -or
    $counts.original -ne 4 -or $counts.toolchain -ne 386) {
    throw 'Compiler dependency root inventory changed.'
}

$claims = $closure.scope.claims
Assert-GswJsonExactProperties $claims @(
    'direct_recipe_reviewed', 'compiler_commands_complete',
    'depfiles_reproducible', 'header_dependency_set_complete',
    'exact_materialized_source_root',
    'backend_source_include_exclusions_proven',
    'common_define_exclusions_proven',
    'unit_compile_context_exception_bound',
    'project_header_license_closure', 'object_compilation_complete',
    'object_compilation_reproducible', 'object_identity_collision_free',
    'upstream_recipe_reproduced', 'pthread_link_abi_proven',
    'build_closure', 'graphics_stack_integrated'
) 'scope.claims'
if (-not $claims.direct_recipe_reviewed -or
    -not $claims.compiler_commands_complete -or
    -not $claims.depfiles_reproducible -or
    -not $claims.header_dependency_set_complete -or
    -not $claims.exact_materialized_source_root -or
    -not $claims.backend_source_include_exclusions_proven -or
    -not $claims.common_define_exclusions_proven -or
    -not $claims.unit_compile_context_exception_bound -or
    -not $claims.project_header_license_closure -or
    -not $claims.object_compilation_complete -or
    -not $claims.object_compilation_reproducible -or
    -not $claims.object_identity_collision_free -or
    $claims.upstream_recipe_reproduced -or
    $claims.pthread_link_abi_proven -or
    $claims.build_closure -or $claims.graphics_stack_integrated) {
    throw 'Compiler closure claims changed.'
}
Assert-GswJsonExactProperties $closure.scope.authorizations @(
    'production_build', 'link', 'stage', 'guest_install', 'dll_activation',
    'renderer_selection', 'capability_advertisement'
) 'scope.authorizations'
Assert-CompilerClosureFalseValues $closure.scope.authorizations `
    'scope.authorizations'

$externalValues = @($SourceRoot, $GeneratedRoot, $ToolchainRoot)
$externalCount = @($externalValues | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
}).Count
if ($externalCount -notin @(0, 3)) {
    throw 'External header verification requires source, generated, and toolchain roots together.'
}
if ($externalCount -eq 3) {
    $roots = @{
        source = [IO.Path]::GetFullPath($SourceRoot)
        generated = [IO.Path]::GetFullPath($GeneratedRoot)
        original = [IO.Path]::GetFullPath($driversRoot)
        toolchain = [IO.Path]::GetFullPath($ToolchainRoot)
    }
    foreach ($header in $headers) { Assert-ExternalHeader $header $roots }
}

Write-Output (
    'Verified Mesa compiler closure: 869 exact commands, 1,738 twin ' +
    'depfiles, 869 twin normalized i386 COFF objects, aggregate ' +
    "$aggregate, authorizations=false."
)

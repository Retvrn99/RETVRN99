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

function Get-CompilerClosureHash {
    param([byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
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

if ([string]::IsNullOrWhiteSpace($ClosureFile)) {
    $ClosureFile = Join-Path $PSScriptRoot '..\drivers\win98\mesa-compiler-closure.json'
}
$snapshot = Read-GswStrictJsonFileSnapshot -Path $ClosureFile `
    -Name 'Mesa compiler closure' -MaximumBytes ([UInt64]2097152)
$closure = $snapshot.Value
$driversRoot = Split-Path -Parent $snapshot.Path

Assert-GswJsonExactProperties $closure @(
    '_spdx', 'schema', 'schema_definition', 'status', 'reason', 'source',
    'inputs', 'direct_recipe', 'depfile_contract', 'exclusions', 'evidence',
    'scope'
) 'Mesa compiler closure'
if ($closure._spdx -cne 'GPL-3.0-only' -or $closure.schema -ne 2 -or
    $closure.status -cne 'evidence-only') {
    throw 'Mesa compiler closure identity or status changed.'
}
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
    $schema.properties.schema.const -ne 2 -or
    $schema.properties.status.const -cne 'evidence-only') {
    throw 'Mesa compiler closure schema contract changed.'
}

$expectedInputs = @(
    @('mesa-direct-build-plan', 'metadata-only-exact-874-units'),
    @('mesa-component-closure', 'blocked-audited'),
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

$recipe = $closure.direct_recipe
if ($recipe.status -cne 'exact-metadata-with-compiler-evidence' -or
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
    $contract.proof_source_root -cne 'exact-materialized-1489-file-root' -or
    ($contract.logical_roots -join '|') -cne 'source|generated|original|toolchain') {
    throw 'Depfile contract changed.'
}

$supportOnly = @($closure.exclusions.support_only_generated_sources)
if (($supportOnly -join '|') -cne (
    'mesa-23.1.x/src/gallium/auxiliary/util/u_tracepoints.c|' +
    'mesa-23.1.x/src/mapi/glapi/gen/indirect.c|' +
    'mesa-23.1.x/src/mapi/glapi/gen/indirect_init.c|' +
    'mesa-23.1.x/src/mapi/glapi/gen/indirect_size.c|' +
    'mesa-23.1.x/src/mapi/glapi/glapi_gentable.c'
)) { throw 'Support-only generated-source set changed.' }

$profile = $closure.evidence.profile
if ($profile.id -cne 'mesa-dependency-v1' -or
    $profile.mode -cne 'gcc-M-MF-MT' -or
    $profile.missing_header_mode -cne 'reject-no-MG' -or
    -not $profile.include_system_headers -or $profile.timeout_seconds -ne 10 -or
    $profile.common_arguments -contains '-MG') {
    throw 'Compiler evidence profile changed.'
}
$common = @($profile.common_arguments)
foreach ($flag in $cpuProfile.toolchains.mingw.cpu_flags) {
    if ($common -cnotcontains [string]$flag) {
        throw "Compiler profile lacks CPU flag '$flag'."
    }
}
$commonText = $common -join "`n"
foreach ($fragment in $closure.exclusions.include_path_fragments) {
    if ($commonText.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Compiler profile contains forbidden include fragment '$fragment'."
    }
}
foreach ($name in $closure.exclusions.define_names) {
    if ($common -contains "-D$name" -or
        @($common | Where-Object { $_.StartsWith("-D$name=", [StringComparison]::Ordinal) }).Count -ne 0) {
        throw "Compiler profile contains forbidden define '$name'."
    }
}
foreach ($argument in $common) {
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
$commandIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
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
$headerIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
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
        foreach ($fragment in $closure.exclusions.source_path_fragments) {
            if ($header.relative_path.IndexOf(
                    $fragment, [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                throw "Header evidence contains forbidden source '$fragment'."
            }
        }
    }
}
$summary = $closure.evidence.summary
if ($summary.command_count -ne 869 -or $summary.twin_depfile_count -ne 1738 -or
    $summary.unique_dependency_count -ne 1070 -or $headers.Count -ne 1070 -or
    -not $summary.twin_byte_identical -or $summary.failed_command_count -ne 0 -or
    -not $summary.exact_source_root -or
    $summary.exact_source_root_file_count -ne 1489) {
    throw 'Compiler evidence summary changed.'
}
foreach ($rootName in $counts.Keys) {
    if ($summary.dependency_root_counts.$rootName -ne $counts[$rootName]) {
        throw "Compiler dependency count for '$rootName' changed."
    }
}
if ($counts.source -ne 652 -or $counts.generated -ne 28 -or
    $counts.original -ne 4 -or $counts.toolchain -ne 386) {
    throw 'Compiler dependency root inventory changed.'
}

$claims = $closure.scope.claims
if (-not $claims.direct_recipe_reviewed -or
    -not $claims.compiler_commands_complete -or
    -not $claims.depfiles_reproducible -or
    -not $claims.header_dependency_set_complete -or
    -not $claims.exact_materialized_source_root -or
    -not $claims.backend_exclusions_proven -or
    $claims.project_header_license_closure -or $claims.build_closure -or
    $claims.graphics_stack_integrated) {
    throw 'Compiler closure claims changed.'
}
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
    "Verified Mesa compiler evidence: 869 exact commands, 1,738 " +
    "byte-identical twin depfiles, $($headers.Count) unique dependencies, " +
    'forbidden backends absent, authorizations=false.'
)

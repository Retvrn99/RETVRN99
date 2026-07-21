# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$ClosureFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')

$script:ExpectedSchemaSha256 = `
    'cea82369561ada333da633aa02e136bbb1a45eb3d16aca10a9d583ecfc1ae0a2'
$script:ExpectedCommit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$script:ExpectedRepository = 'https://github.com/JHRobotics/mesa9x.git'
$script:MaximumJsonBytes = [UInt64]1048576

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Label
    )

    if ($Actual -is [string] -and $Expected -is [string]) {
        if ($Actual -cne $Expected) {
            throw "$Label must be '$Expected'."
        }
        return
    }
    if ($Actual -ne $Expected) {
        throw "$Label must be '$Expected'."
    }
}

function Assert-BoundedString {
    param(
        [object]$Value,
        [int]$MaximumLength,
        [string]$Label,
        [switch]$AllowEmpty
    )

    Assert-GswJsonString $Value $Label
    if ($Value.Length -gt $MaximumLength -or
        (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        throw "$Label must be a bounded JSON string."
    }
}

function Assert-IntegerValue {
    param(
        [object]$Value,
        [Int64]$Expected,
        [string]$Label
    )

    Assert-GswJsonInteger $Value $Label
    if ([Int64]$Value -ne $Expected) {
        throw "$Label must be the JSON integer $Expected."
    }
}

function Assert-FalseValue {
    param(
        [object]$Value,
        [string]$Label
    )

    Assert-GswJsonBoolean $Value $Label
    if ($Value) {
        throw "$Label must remain false."
    }
}

function Assert-TrueValue {
    param(
        [object]$Value,
        [string]$Label
    )

    Assert-GswJsonBoolean $Value $Label
    if (-not $Value) {
        throw "$Label must remain true."
    }
}

function Assert-OrderedStrings {
    param(
        [object]$Value,
        [string[]]$Expected,
        [string]$Label
    )

    Assert-GswJsonArray $Value $Label
    if ($Value.Count -ne $Expected.Count) {
        throw "$Label must contain $($Expected.Count) ordered values."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-BoundedString $Value[$index] 512 "$Label[$index]"
        if ($Value[$index] -cne $Expected[$index]) {
            throw "$Label must contain the canonical ordered values."
        }
    }
}

function Assert-InputBinding {
    param(
        [object]$Binding,
        [object]$Expected,
        [int]$Index
    )

    $label = "inputs[$Index]"
    Assert-GswJsonExactProperties -Value $Binding -Expected `
        @('id', 'relative_path', 'bytes', 'sha256', 'required_state') `
        -Label $label
    Assert-BoundedString $Binding.id 64 "$label.id"
    Assert-BoundedString $Binding.relative_path 256 "$label.relative_path"
    Assert-IntegerValue $Binding.bytes $Expected.Bytes "$label.bytes"
    Assert-BoundedString $Binding.sha256 64 "$label.sha256"
    Assert-BoundedString $Binding.required_state 64 "$label.required_state"
    Assert-Equal $Binding.id $Expected.Id "$label.id"
    Assert-Equal $Binding.relative_path $Expected.Path "$label.relative_path"
    Assert-Equal $Binding.sha256 $Expected.Sha256 "$label.sha256"
    Assert-Equal $Binding.required_state $Expected.State "$label.required_state"
    if ($Binding.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "$label.sha256 must be a lowercase SHA-256 digest."
    }
}

function Read-BoundInput {
    param(
        [string]$Root,
        [object]$Binding,
        [string]$Label
    )

    $path = Join-Path $Root ([string]$Binding.relative_path)
    $snapshot = Read-GswStrictJsonFileSnapshot -Path $path -Name $Label `
        -MaximumBytes $script:MaximumJsonBytes
    if ([UInt64]$snapshot.Length -ne [UInt64]$Binding.bytes) {
        throw "$Label byte count does not match its canonical binding."
    }
    if ($snapshot.Sha256 -cne $Binding.sha256) {
        throw "$Label digest does not match its canonical binding."
    }
    return $snapshot
}

function Assert-NoAuthorization {
    param(
        [object]$Value,
        [string[]]$Names,
        [string]$Label
    )

    Assert-GswJsonExactProperties -Value $Value -Expected $Names -Label $Label
    foreach ($name in $Names) {
        Assert-FalseValue $Value.$name "$Label.$name"
    }
}

if ([string]::IsNullOrWhiteSpace($ClosureFile)) {
    $ClosureFile = Join-Path (Split-Path -Parent $PSScriptRoot) `
        'drivers\win98\mesa-compiler-closure.json'
}

$closureSnapshot = Read-GswStrictJsonFileSnapshot -Path $ClosureFile `
    -Name 'Mesa compiler closure' -MaximumBytes ([UInt64]65536)
$closure = $closureSnapshot.Value
$closureRoot = Split-Path -Parent $closureSnapshot.Path

Assert-GswJsonExactProperties -Value $closure -Expected @(
    '_spdx', 'schema', 'schema_definition', 'status', 'reason', 'source',
    'inputs', 'blocked_prerequisites', 'direct_recipe', 'observed_selection',
    'depfile_contract', 'exclusions', 'evidence', 'scope'
) -Label 'Mesa compiler closure'
Assert-Equal $closure._spdx 'GPL-3.0-only' 'closure._spdx'
Assert-IntegerValue $closure.schema 1 'closure.schema'
Assert-BoundedString $closure.status 32 'closure.status'
Assert-Equal $closure.status 'blocked' 'closure.status'
Assert-BoundedString $closure.reason 1024 'closure.reason'

Assert-GswJsonExactProperties -Value $closure.schema_definition `
    -Expected @('relative_path', 'sha256') -Label 'closure.schema_definition'
Assert-Equal $closure.schema_definition.relative_path `
    'mesa-compiler-closure.schema.json' `
    'closure.schema_definition.relative_path'
Assert-Equal $closure.schema_definition.sha256 $script:ExpectedSchemaSha256 `
    'closure.schema_definition.sha256'

$schemaPath = Join-Path $closureRoot $closure.schema_definition.relative_path
$schemaSnapshot = Read-GswStrictJsonFileSnapshot -Path $schemaPath `
    -Name 'Mesa compiler closure schema' -MaximumBytes ([UInt64]65536)
if ($schemaSnapshot.Sha256 -cne $script:ExpectedSchemaSha256) {
    throw 'Mesa compiler closure schema content does not match its canonical digest.'
}
$schema = $schemaSnapshot.Value
Assert-Equal $schema._spdx 'GPL-3.0-only' 'schema._spdx'
Assert-Equal $schema.'$id' 'mesa-compiler-closure.schema.json' 'schema.$id'
Assert-Equal $schema.properties.status.const 'blocked' 'schema status'
Assert-IntegerValue $schema.properties.evidence.properties.compiler_commands.maxItems `
    0 'schema compiler-command maximum'
Assert-IntegerValue $schema.properties.evidence.properties.depfiles.maxItems `
    0 'schema depfile maximum'
Assert-IntegerValue $schema.properties.evidence.properties.headers.maxItems `
    0 'schema header maximum'
Assert-Equal $schema.properties.direct_recipe.properties.status.const `
    'absent' 'schema direct recipe status'
Assert-FalseValue $schema.properties.scope.properties.authorizations.properties.`
    compiler_execution.const 'schema compiler execution authorization'

Assert-GswJsonExactProperties -Value $closure.source -Expected @(
    'upstream_name', 'repository', 'owning_commit', 'mesa_version', 'mesa_subtree'
) -Label 'closure.source'
Assert-Equal $closure.source.upstream_name 'mesa9x' 'source.upstream_name'
Assert-Equal $closure.source.repository $script:ExpectedRepository 'source.repository'
Assert-Equal $closure.source.owning_commit $script:ExpectedCommit `
    'source.owning_commit'
Assert-Equal $closure.source.mesa_version '23.1.9' 'source.mesa_version'
Assert-Equal $closure.source.mesa_subtree 'mesa-23.1.x' 'source.mesa_subtree'

$expectedInputs = @(
    [pscustomobject]@{
        Id = 'mesa-component-closure'
        Path = 'component-closures/mesa9x-23.1.x.json'
        Bytes = 815285
        Sha256 = 'd93a476656ec9f18c1d257a65ae6461111c7e85ec0b704360bcc42b836dbefc5'
        State = 'blocked-audited'
    },
    [pscustomobject]@{
        Id = 'mesa-generated-output-lock'
        Path = 'generated-output-locks/mesa-23.1.9.json'
        Bytes = 84159
        Sha256 = '8274e5dd8cc50b41e4f0e510e87e9a2d669248bd69ae988e6dbdb48ce28390e5'
        State = 'reviewed-generated-source'
    },
    [pscustomobject]@{
        Id = 'mesa-generated-source-reproducibility'
        Path = 'mesa-generated-source-reproducibility.json'
        Bytes = 4418
        Sha256 = 'd37322e969730fb71d2663c19752728802631cb9bd55b3d294824e3ac4ca2f0b'
        State = 'proven'
    },
    [pscustomobject]@{
        Id = 'original-gsw-source'
        Path = 'mesa-gsw/interface-inputs.lock.json'
        Bytes = 4336
        Sha256 = '8b64bed0e4b110b1526ff1bae136b38f23c8441c9a0a64d1d35ff74ebce77f22'
        State = 'reviewed-permissive-interfaces'
    },
    [pscustomobject]@{
        Id = 'guest-cpu-profile'
        Path = 'guest-cpu-profile.json'
        Bytes = 3537
        Sha256 = '969b45df75c6e1d8366e6ef7468a51f04c42441914ce564ae19f62a07cad0f57'
        State = 'compile-proof-blocked'
    },
    [pscustomobject]@{
        Id = 'mingw32-toolchain'
        Path = 'mingw32-toolchain.lock.json'
        Bytes = 792
        Sha256 = 'db3a84b7388937a5ffd5ab3e30429bae4c3ca5d8d17f095a491a42bc82413a12'
        State = 'extracted-tree-locked'
    }
)
Assert-GswJsonArray $closure.inputs 'closure.inputs'
if ($closure.inputs.Count -ne $expectedInputs.Count) {
    throw 'closure.inputs must contain six canonical input bindings.'
}
$inputSnapshots = @()
for ($index = 0; $index -lt $expectedInputs.Count; $index++) {
    Assert-InputBinding $closure.inputs[$index] $expectedInputs[$index] $index
    $inputSnapshots += Read-BoundInput $closureRoot $closure.inputs[$index] `
        "bound input '$($closure.inputs[$index].id)'"
}

$component = $inputSnapshots[0].Value
Assert-IntegerValue $component.schema 2 'component closure schema'
Assert-Equal $component.status 'blocked' 'component closure status'
Assert-Equal $component.upstream_name 'mesa9x' 'component closure source'
Assert-Equal $component.owning_commit $script:ExpectedCommit `
    'component closure commit'
Assert-GswJsonArray $component.files 'component closure files'
if ($component.files.Count -ne 1036) {
    throw 'Component closure must bind exactly 1036 selected files.'
}
$sourceUnits = @()
$generatorInputs = 0
$buildDescriptions = 0
$headerLike = 0
foreach ($file in $component.files) {
    if ([string]$file.relative_path -cmatch '\.(h|hpp|inc)$') {
        $headerLike += 1
    }
    foreach ($role in $file.roles) {
        switch -CaseSensitive ($role) {
            'source-unit' { $sourceUnits += [string]$file.relative_path }
            'generator-input' { $generatorInputs += 1 }
            'build-description' { $buildDescriptions += 1 }
        }
    }
}
$cUnits = @($sourceUnits | Where-Object { $_ -cmatch '\.c$' }).Count
$cxxUnits = @($sourceUnits | Where-Object { $_ -cmatch '\.cpp$' }).Count
if ($sourceUnits.Count -ne 837 -or $cUnits -ne 742 -or $cxxUnits -ne 95 -or
    $generatorInputs -ne 198 -or $buildDescriptions -ne 1 -or
    $headerLike -ne 1) {
    throw 'Component closure selection counts do not match the canonical audit.'
}
$forbiddenSelectedPrefixes = @(
    'winpthreads',
    'mesa-23.1.x/src/gallium/drivers/llvmpipe',
    'mesa-23.1.x/src/gallium/drivers/softpipe',
    'mesa-23.1.x/src/gallium/drivers/zink',
    'mesa-23.1.x/src/gallium/winsys/sw',
    'mesa-23.1.x/src/gallium/winsys/svga/drm',
    'mesa-23.1.x/src/gallium/winsys/virgl',
    'mesa-23.1.x/src/virtio'
)
foreach ($path in $sourceUnits) {
    foreach ($prefix in $forbiddenSelectedPrefixes) {
        if ($path -ceq $prefix -or $path.StartsWith($prefix + '/', `
                [StringComparison]::Ordinal)) {
            throw "Component closure selected forbidden source unit '$path'."
        }
    }
}

$generated = $inputSnapshots[1].Value
Assert-IntegerValue $generated.schema 2 'generated output lock schema'
Assert-Equal $generated.status 'reviewed-generated-source' `
    'generated output lock status'
if ($generated.outputs.Count -ne 67) {
    throw 'Generated output lock must bind exactly 67 outputs.'
}
Assert-TrueValue $generated.scope.claims.generated_source_bytes_reviewed `
    'generated output byte review'
Assert-TrueValue $generated.scope.claims.file_license_evidence_complete `
    'generated output license evidence'
Assert-FalseValue $generated.scope.claims.build_closure `
    'generated output build closure'
Assert-NoAuthorization -Value $generated.scope.authorizations -Names @(
    'generator_execution', 'build', 'stage', 'guest_install',
    'capability_advertisement'
) -Label 'generated output authorizations'

$reproducibility = $inputSnapshots[2].Value
Assert-Equal $reproducibility.status 'proven' 'generated reproducibility status'
Assert-TrueValue $reproducibility.scope.claims.normalized_output_reproducibility `
    'normalized output reproducibility'
Assert-FalseValue $reproducibility.scope.claims.build_closure `
    'reproducibility build closure'
Assert-NoAuthorization -Value $reproducibility.scope.authorizations -Names @(
    'generator_execution', 'build', 'stage', 'guest_install', 'dll_activation',
    'capability_advertisement'
) -Label 'reproducibility authorizations'

$original = $inputSnapshots[3].Value
Assert-Equal $original.status 'reviewed-permissive-interfaces' `
    'original GSW source status'
if ($original.outputs.Count -ne 3) {
    throw 'Original GSW source lock must bind exactly three outputs.'
}
Assert-OrderedStrings -Value $original.excluded_implementation_paths -Expected @(
    'include/git_sha1.h', 'win9x/nine/nine_memory_helper.c'
) -Label 'original GSW excluded implementations'
Assert-NoAuthorization -Value $original.claims -Names @(
    'build_authorized', 'compile_proven', 'staging_authorized',
    'guest_install_authorized', 'capability_advertisement_authorized'
) -Label 'original GSW claims'

$cpu = $inputSnapshots[4].Value
Assert-Equal $cpu.cpu_persona.name 'GSW-886' 'CPU persona name'
Assert-Equal $cpu.cpu_persona.architecture 'i686' 'CPU architecture'
Assert-Equal $cpu.toolchains.mingw.target 'i686-w64-mingw32' 'compiler target'
Assert-Equal $cpu.proof.status 'blocked' 'CPU compile proof status'
Assert-Equal $cpu.proof.evidence_status 'absent' 'CPU compile evidence status'

$toolchain = $inputSnapshots[5].Value
Assert-Equal $toolchain.name 'msys2-mingw32-gcc-15.2.0-rev13' `
    'toolchain identity'
Assert-Equal $toolchain.extracted.sha256 `
    '08491a4bf273920ff9078f444addffe7e08f0d0b77d34d74cc2c742c84bb614a' `
    'toolchain extracted tree digest'

Assert-OrderedStrings -Value $closure.blocked_prerequisites -Expected @(
    'reviewed-direct-recipe',
    'exact-compiler-command-registry',
    'deterministic-project-and-toolchain-depfiles',
    'exact-header-license-closure',
    'original-gsw-winsys-source'
) -Label 'closure.blocked_prerequisites'

Assert-GswJsonExactProperties -Value $closure.direct_recipe -Expected @(
    'required_relative_path', 'status', 'schema', 'bytes', 'sha256',
    'compiler_command_count', 'upstream_makefile_consumption'
) -Label 'closure.direct_recipe'
Assert-Equal $closure.direct_recipe.required_relative_path `
    'mesa-gsw-direct-compile-plan.json' 'direct recipe path'
Assert-Equal $closure.direct_recipe.status 'absent' 'direct recipe status'
Assert-IntegerValue $closure.direct_recipe.schema 0 'direct recipe schema'
Assert-IntegerValue $closure.direct_recipe.bytes 0 'direct recipe bytes'
Assert-Equal $closure.direct_recipe.sha256 '' 'direct recipe digest'
Assert-IntegerValue $closure.direct_recipe.compiler_command_count 0 `
    'direct recipe command count'
Assert-FalseValue $closure.direct_recipe.upstream_makefile_consumption `
    'upstream Makefile consumption'
$directRecipePath = Join-Path $closureRoot `
    $closure.direct_recipe.required_relative_path
if (Test-Path -LiteralPath $directRecipePath) {
    throw 'Schema 1 requires the unreviewed direct recipe to remain absent.'
}

Assert-GswJsonExactProperties -Value $closure.observed_selection -Expected @(
    'manifest_file_count', 'upstream_source_unit_count', 'c_source_unit_count',
    'cxx_source_unit_count', 'generator_input_count', 'build_description_count',
    'selected_header_like_count', 'original_gsw_output_count',
    'generated_output_count'
) -Label 'closure.observed_selection'
$selectionValues = [ordered]@{
    manifest_file_count = 1036
    upstream_source_unit_count = 837
    c_source_unit_count = 742
    cxx_source_unit_count = 95
    generator_input_count = 198
    build_description_count = 1
    selected_header_like_count = 1
    original_gsw_output_count = 3
    generated_output_count = 67
}
foreach ($name in $selectionValues.Keys) {
    Assert-IntegerValue $closure.observed_selection.$name `
        $selectionValues[$name] "observed_selection.$name"
}

Assert-GswJsonExactProperties -Value $closure.depfile_contract -Expected @(
    'compiler_identity', 'execution_mode', 'dependency_mode',
    'missing_header_mode', 'one_depfile_per_command', 'include_system_headers',
    'discovery_source_root', 'proof_source_root', 'generated_source_root',
    'original_source_root',
    'toolchain_root', 'path_identity', 'twin_run_required'
) -Label 'closure.depfile_contract'
$depfileStrings = [ordered]@{
    compiler_identity = 'guest-cpu-profile-pinned-mingw-gcc'
    execution_mode = 'preprocess-dependency-only'
    dependency_mode = 'gcc-M-MF-MT'
    missing_header_mode = 'reject-no-MG'
    discovery_source_root = 'pinned-clean-checkout-non-authoritative'
    proof_source_root = 'exact-materialized-component-closure'
    generated_source_root = 'reviewed-normalized-root'
    original_source_root = 'reviewed-original-gsw-module'
    toolchain_root = 'full-tree-locked-extraction'
    path_identity = 'logical-root-forward-slash-ordinal-case-sensitive'
}
foreach ($name in $depfileStrings.Keys) {
    Assert-Equal $closure.depfile_contract.$name $depfileStrings[$name] `
        "depfile_contract.$name"
}
Assert-TrueValue $closure.depfile_contract.one_depfile_per_command `
    'depfile_contract.one_depfile_per_command'
Assert-TrueValue $closure.depfile_contract.include_system_headers `
    'depfile_contract.include_system_headers'
Assert-TrueValue $closure.depfile_contract.twin_run_required `
    'depfile_contract.twin_run_required'

Assert-GswJsonExactProperties -Value $closure.exclusions -Expected @(
    'upstream_recipe_inputs', 'upstream_path_prefixes',
    'include_path_fragments', 'define_names', 'define_prefixes'
) -Label 'closure.exclusions'
Assert-OrderedStrings -Value $closure.exclusions.upstream_recipe_inputs -Expected @(
    'Makefile', 'config.mk', 'generator/mesa-23.1.x-gen.mk',
    'mesa-23.1.x.deps', 'mesa-23.1.x.mk', 'pthread.mk'
) -Label 'exclusions.upstream_recipe_inputs'
Assert-OrderedStrings -Value $closure.exclusions.upstream_path_prefixes -Expected @(
    'include/git_sha1.h',
    'win9x/nine/nine_memory_helper.c',
    'winpthreads',
    'mesa-23.1.x/include/winddk',
    'mesa-23.1.x/src/gallium/drivers/llvmpipe',
    'mesa-23.1.x/src/gallium/drivers/softpipe',
    'mesa-23.1.x/src/gallium/drivers/zink',
    'mesa-23.1.x/src/gallium/winsys/sw',
    'mesa-23.1.x/src/gallium/winsys/svga/drm',
    'mesa-23.1.x/src/gallium/winsys/virgl',
    'mesa-23.1.x/src/virtio'
) -Label 'exclusions.upstream_path_prefixes'
Assert-OrderedStrings -Value $closure.exclusions.include_path_fragments -Expected @(
    'winpthreads/include', 'include/winddk', 'gallium/winsys/sw',
    'gallium/winsys/svga/drm', 'gallium/winsys/virgl', 'LLVM_DIR/include'
) -Label 'exclusions.include_path_fragments'
Assert-OrderedStrings -Value $closure.exclusions.define_names -Expected @(
    'GALLIUM_SOFTPIPE', 'HAVE_PTHREAD', 'HAVE_LLVM',
    'HAVE_GALLIUM_LLVMPIPE', 'GALLIUM_LLVMPIPE', 'HAVE_LLVMPIPE',
    'DRAW_LLVM_AVAILABLE'
) -Label 'exclusions.define_names'
Assert-OrderedStrings -Value $closure.exclusions.define_prefixes `
    -Expected @('VBOX_') -Label 'exclusions.define_prefixes'

Assert-GswJsonExactProperties -Value $closure.evidence -Expected @(
    'compiler_commands', 'depfiles', 'headers', 'twin_run_descriptor'
) -Label 'closure.evidence'
foreach ($name in @('compiler_commands', 'depfiles', 'headers')) {
    Assert-GswJsonArray $closure.evidence.$name "evidence.$name"
    if ($closure.evidence.$name.Count -ne 0) {
        throw "evidence.$name must remain empty in schema 1."
    }
}
if ($null -ne $closure.evidence.twin_run_descriptor) {
    throw 'evidence.twin_run_descriptor must remain null in schema 1.'
}

Assert-GswJsonExactProperties -Value $closure.scope -Expected @(
    'classification', 'claims', 'authorizations'
) -Label 'closure.scope'
Assert-Equal $closure.scope.classification 'blocked-compiler-closure-design' `
    'scope.classification'
Assert-NoAuthorization -Value $closure.scope.claims -Names @(
    'direct_recipe_reviewed', 'compiler_commands_complete',
    'depfiles_reproducible', 'project_header_closure',
    'toolchain_header_closure', 'backend_exclusions_proven', 'build_closure'
) -Label 'scope.claims'
Assert-NoAuthorization -Value $closure.scope.authorizations -Names @(
    'compiler_execution', 'build', 'stage', 'guest_install', 'dll_activation',
    'capability_advertisement'
) -Label 'scope.authorizations'

$finalClosure = Read-GswBoundedFileSnapshot -Path $closureSnapshot.Path `
    -Name 'Mesa compiler closure final stability check' -MaximumBytes ([UInt64]65536)
$finalSchema = Read-GswBoundedFileSnapshot -Path $schemaSnapshot.Path `
    -Name 'Mesa compiler closure schema final stability check' `
    -MaximumBytes ([UInt64]65536)
if ($finalClosure.Sha256 -cne $closureSnapshot.Sha256 -or
    $finalSchema.Sha256 -cne $schemaSnapshot.Sha256) {
    throw 'Mesa compiler closure metadata changed during verification.'
}
for ($index = 0; $index -lt $inputSnapshots.Count; $index++) {
    $finalInput = Read-GswBoundedFileSnapshot -Path $inputSnapshots[$index].Path `
        -Name "bound input '$($closure.inputs[$index].id)' final stability check" `
        -MaximumBytes $script:MaximumJsonBytes
    if ($finalInput.Sha256 -cne $inputSnapshots[$index].Sha256 -or
        [UInt64]$finalInput.Length -ne [UInt64]$inputSnapshots[$index].Length -or
        $finalInput.Sha256 -cne $expectedInputs[$index].Sha256) {
        throw "Bound input '$($closure.inputs[$index].id)' changed during verification."
    }
}

Write-Output (
    'Verified blocked Mesa compiler closure design: 837 selected upstream ' +
    'source units, 0 compiler commands, 0 depfiles, 0 headers; ' +
    'compiler execution=false, build=false.'
)

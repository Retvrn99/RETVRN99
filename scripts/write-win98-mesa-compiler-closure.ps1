# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceFile,
    [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'mesa-object-proof.ps1')
. (Join-Path $PSScriptRoot 'mesa-compiler-dependency-roles.ps1')
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-CompilerClosureSha256 {
    param([byte[]]$Bytes)

    return Get-MesaObjectSha256 $Bytes
}

function New-CompilerClosureBinding {
    param(
        [string]$Root,
        [string]$Id,
        [string]$RelativePath,
        [string]$RequiredState
    )

    $path = Join-Path $Root $RelativePath
    $bytes = [IO.File]::ReadAllBytes($path)
    return [pscustomobject][ordered]@{
        id = $Id
        relative_path = $RelativePath.Replace('\', '/')
        bytes = $bytes.Length
        sha256 = Get-CompilerClosureSha256 $bytes
        required_state = $RequiredState
    }
}

function Assert-CompilerEvidenceSummary {
    param([object]$Evidence)

    $summary = $Evidence.summary
    if ($Evidence._spdx -cne 'GPL-3.0-only' -or $Evidence.schema -ne 2 -or
        $summary.command_count -ne 869 -or
        $summary.twin_depfile_count -ne 1738 -or
        $summary.unique_dependency_count -ne 1070 -or
        $summary.dependency_root_counts.source -ne 651 -or
        $summary.dependency_root_counts.generated -ne 29 -or
        $summary.dependency_root_counts.original -ne 4 -or
        $summary.dependency_root_counts.toolchain -ne 386 -or
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
        $summary.aggregate_object_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Compiler evidence is incomplete or malformed.'
    }
    if (@($Evidence.commands).Count -ne 869 -or
        @($Evidence.headers).Count -ne 1070 -or
        @($Evidence.objects).Count -ne 869 -or
        (Get-MesaObjectAggregateSha256 @($Evidence.objects)) -cne
            [string]$summary.aggregate_object_sha256) {
        throw 'Compiler evidence object inventory or aggregate changed.'
    }
}

function Assert-CompilerEvidenceTargetDefines {
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

function Assert-CompilerEvidenceUnitOverrides {
    param([object]$Evidence)

    $overrides = @($Evidence.unit_argument_overrides)
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
        throw 'Compiler evidence must contain three exact ordered unit overrides.'
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $override = $overrides[$index]
        Assert-GswJsonExactProperties $override @(
            'command_id', 'source', 'profiles', 'insertion', 'arguments', 'mode'
        ) "Compiler evidence unit override $index"
        if ($override.command_id -cne $expected[$index].CommandId -or
            $override.source -cne $expected[$index].Source -or
            (@($override.profiles) -join '|') -cne
                'mesa-dependency-v1|mesa-object-v1' -or
            $override.insertion -cne 'after-common-before-language' -or
            (@($override.arguments) -join '|') -cne
                $expected[$index].Arguments -or
            $override.mode -cne 'compile-context-only-no-link') {
            throw "Compiler evidence unit override $index changed."
        }
    }
    foreach ($entry in @(
        [pscustomobject]@{ Profile = $Evidence.profile; Label = 'Dependency' }
        [pscustomobject]@{ Profile = $Evidence.object_profile; Label = 'Object' }
    )) {
        $commonArguments = @($entry.Profile.common_arguments)
        Assert-CompilerEvidenceTargetDefines $commonArguments `
            "$($entry.Label) profile"
        foreach ($argument in @(
            '-DHAVE_PTHREAD', '-DUSE_X86_ASM', '-DGLX_X86_READONLY_TEXT'
        )) {
            if ($commonArguments -contains $argument -or
                @($commonArguments | Where-Object {
                    ([string]$_).StartsWith(
                        $argument + '=', [StringComparison]::Ordinal
                    )
                }).Count -ne 0) {
                throw "$($entry.Label) profile promoted $argument to common arguments."
            }
        }
    }
}

function Assert-ReadyComponentDependencies {
    param([object]$Evidence, [object]$Component)

    if ($Component.schema -ne 2 -or $Component.status -cne 'ready' -or
        @($Component.files).Count -ne 1687) {
        throw 'Mesa component closure is not ready and complete.'
    }
    $dependencies = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($file in $Component.files) {
        if (@($file.roles) -ccontains 'compiler-dependency') {
            $dependencies.Add([string]$file.relative_path, $file)
        }
    }
    if ($dependencies.Count -ne 652) {
        throw 'Mesa component closure lacks 652 dependency-role files.'
    }
    $observed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($header in @($Evidence.headers | Where-Object root -ceq 'source')) {
        $path = [string]$header.relative_path
        if (-not $observed.Add($path) -or
            -not $dependencies.ContainsKey($path)) {
            throw "Compiler source dependency '$path' lacks ready closure."
        }
        Assert-MesaCanonicalCompilerDependencyEvidence `
            -Header $header -File $dependencies[$path]
    }
    $dependencyRoles = Resolve-MesaCompilerDependencyRoles @($Evidence.headers)
    if ($observed.Count -ne 651 -or
        $dependencyRoles.Mode -cne 'generated-replacement-observed') {
        throw 'Compiler evidence changed the generated-shadowed dependency role.'
    }
    foreach ($path in $dependencyRoles.RolePaths) {
        if (-not $dependencies.ContainsKey($path)) {
            throw "Compiler dependency role '$path' lacks ready closure."
        }
    }
    Assert-MesaShadowedCompilerDependencyRole `
        $dependencies[$dependencyRoles.ShadowedPath]
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$driversRoot = Join-Path $repoRoot 'drivers\win98'
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $driversRoot 'mesa-compiler-closure.json'
}
$evidencePath = [IO.Path]::GetFullPath($EvidenceFile)
$evidenceBytes = [IO.File]::ReadAllBytes($evidencePath)
$evidence = ConvertFrom-GswStrictJson `
    -Json $script:Utf8.GetString($evidenceBytes) -Source $evidencePath
Assert-CompilerEvidenceSummary $evidence
Assert-CompilerEvidenceUnitOverrides $evidence

$directPlanBytes = [IO.File]::ReadAllBytes(
    (Join-Path $driversRoot 'mesa-gsw-direct-build-plan.json')
)
if ($evidence.direct_plan.bytes -ne $directPlanBytes.Length -or
    $evidence.direct_plan.sha256 -cne
        (Get-CompilerClosureSha256 $directPlanBytes) -or
    $evidence.direct_plan.unit_count -ne 874) {
    throw 'Compiler evidence does not bind the current direct-build plan.'
}
$componentPath = Join-Path $driversRoot `
    'component-closures\mesa9x-23.1.x.json'
$componentBytes = [IO.File]::ReadAllBytes($componentPath)
$component = ConvertFrom-GswStrictJson `
    -Json $script:Utf8.GetString($componentBytes) -Source $componentPath
Assert-ReadyComponentDependencies $evidence $component

$schemaPath = Join-Path $driversRoot 'mesa-compiler-closure.schema.json'
$schemaBytes = [IO.File]::ReadAllBytes($schemaPath)
$schemaHash = Get-CompilerClosureSha256 $schemaBytes
$inputs = @(
    New-CompilerClosureBinding $driversRoot 'mesa-direct-build-plan' `
        'mesa-gsw-direct-build-plan.json' 'metadata-only-exact-874-units'
    New-CompilerClosureBinding $driversRoot 'mesa-component-closure' `
        'component-closures\mesa9x-23.1.x.json' `
        'ready-compiler-role-complete'
    New-CompilerClosureBinding $driversRoot 'mesa-generated-output-lock' `
        'generated-output-locks\mesa-23.1.9.json' 'reviewed-generated-source'
    New-CompilerClosureBinding $driversRoot 'mesa-generated-reproducibility' `
        'mesa-generated-source-reproducibility.json' 'proven'
    New-CompilerClosureBinding $driversRoot 'original-gsw-memory-source' `
        'mesa-gsw\interface-inputs.lock.json' 'reviewed-original-source'
    New-CompilerClosureBinding $driversRoot 'original-gsw-winsys-source' `
        'mesa-gsw\winsys-interface-inputs.lock.json' 'capability-disabled-shell'
    New-CompilerClosureBinding $driversRoot `
        'gsw-disabled-software-winsys-sentinel' `
        'mesa-gsw\include\gdi\gdi_sw_winsys.h' `
        'capability-disabled-empty-sentinel'
    New-CompilerClosureBinding $driversRoot 'guest-cpu-profile' `
        'guest-cpu-profile.json' 'immutable-profile'
    New-CompilerClosureBinding $driversRoot 'mingw32-toolchain' `
        'mingw32-toolchain.lock.json' 'extracted-tree-locked'
)
$supportOnly = @(
    'mesa-23.1.x/src/gallium/auxiliary/util/u_tracepoints.c',
    'mesa-23.1.x/src/mapi/glapi/gen/indirect.c',
    'mesa-23.1.x/src/mapi/glapi/gen/indirect_init.c',
    'mesa-23.1.x/src/mapi/glapi/gen/indirect_size.c',
    'mesa-23.1.x/src/mapi/glapi/glapi_gentable.c'
)
$closure = [pscustomobject][ordered]@{
    _spdx = 'GPL-3.0-only'
    schema = 3
    schema_definition = [pscustomobject][ordered]@{
        relative_path = 'mesa-compiler-closure.schema.json'
        bytes = $schemaBytes.Length
        sha256 = $schemaHash
    }
    status = 'compile-proven'
    reason = 'The ready 1,687-file Mesa component closure covers all 652 upstream dependency-role files. The compiler observes 651 of those roles; the reviewed generated nir_builder_opcodes.h correctly shadows its zero-byte source placeholder. The exact direct recipe has 869 compile units whose dependency commands and normalized i386 COFF objects were reproduced in twin runs. Two compile-only HAVE_PTHREAD overrides are bound to threads_posix.c and rwlock.c, and one compile-only x86 assembly override is bound to glapi_x86.S; all remain absent from common arguments. The winpthreads source and include tree remain excluded. Only COFF TimeDateStamp bytes 4-7 were normalized. Linking, persistent artifacts, staging, installation, activation, renderer selection, and graphics capability remain incomplete and unauthorized.'
    source = [pscustomobject][ordered]@{
        repository = 'https://github.com/JHRobotics/mesa9x.git'
        owning_commit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
        mesa_version = '23.1.9'
        mesa_subtree = 'mesa-23.1.x'
    }
    inputs = $inputs
    direct_recipe = [pscustomobject][ordered]@{
        status = 'exact-metadata-with-compiler-object-evidence'
        inventory_units = 874
        compile_units = 869
        support_only_units = 5
        compiler_command_count = 869
        upstream_makefile_command_consumption = $false
    }
    depfile_contract = [pscustomobject][ordered]@{
        mode = 'gcc-M-MF-MT'
        missing_header_mode = 'reject-no-MG'
        include_system_headers = $true
        one_depfile_per_command = $true
        twin_run_required = $true
        path_identity = 'logical-root-forward-slash-ordinal-case-sensitive'
        proof_source_root = 'exact-materialized-1489-file-canonical-lf-root'
        include_precedence = 'reviewed-generated-before-canonical-source'
        logical_roots = @('source', 'generated', 'original', 'toolchain')
    }
    object_contract = [pscustomobject][ordered]@{
        format = 'coff-i386'
        machine = 332
        optional_header_bytes = 0
        timestamp_offset = 4
        timestamp_bytes = 4
        normalized_byte_offsets = @(4, 5, 6, 7)
        maximum_object_bytes = 67108864
        twin_run_required = $true
        object_identity_collision_free = $true
        private_path_policy = `
            'reject-bound-roots-ascii-utf8-utf16le-before-hash'
        aggregate_algorithm = 'sha256-utf8-tab-records-v1'
        temporary_outputs_retained = $false
        linker_invocations = 0
        include_precedence = 'reviewed-generated-before-canonical-source'
    }
    exclusions = [pscustomobject][ordered]@{
        source_path_fragments = @(
            'winpthreads', 'mesa-23.1.x/include/winddk',
            'mesa-23.1.x/src/gallium/drivers/llvmpipe',
            'mesa-23.1.x/src/gallium/drivers/softpipe',
            'mesa-23.1.x/src/gallium/drivers/zink',
            'mesa-23.1.x/src/gallium/winsys/sw',
            'mesa-23.1.x/src/gallium/winsys/svga/drm',
            'mesa-23.1.x/src/gallium/winsys/virgl',
            'mesa-23.1.x/src/virtio'
        )
        include_path_fragments = @(
            'winpthreads/include', 'include/winddk', 'gallium/winsys/sw',
            'gallium/winsys/svga/drm', 'gallium/winsys/virgl',
            'LLVM_DIR/include'
        )
        common_define_names = @(
            'GALLIUM_SOFTPIPE', 'HAVE_PTHREAD', 'USE_X86_ASM',
            'GLX_X86_READONLY_TEXT', 'HAVE_LLVM',
            'HAVE_GALLIUM_LLVMPIPE', 'GALLIUM_LLVMPIPE',
            'HAVE_LLVMPIPE', 'DRAW_LLVM_AVAILABLE'
        )
        define_prefixes = @('VBOX_')
        support_only_generated_sources = $supportOnly
    }
    evidence = [pscustomobject][ordered]@{
        profile = $evidence.profile
        object_profile = $evidence.object_profile
        unit_argument_overrides = $evidence.unit_argument_overrides
        commands = $evidence.commands
        headers = $evidence.headers
        objects = $evidence.objects
        summary = $evidence.summary
    }
    scope = [pscustomobject][ordered]@{
        classification = 'compiler-dependency-and-twin-object-proof'
        claims = [pscustomobject][ordered]@{
            direct_recipe_reviewed = $true
            compiler_commands_complete = $true
            depfiles_reproducible = $true
            header_dependency_set_complete = $true
            exact_materialized_source_root = $true
            backend_source_include_exclusions_proven = $true
            common_define_exclusions_proven = $true
            unit_compile_context_exception_bound = $true
            project_header_license_closure = $true
            object_compilation_complete = $true
            object_compilation_reproducible = $true
            object_identity_collision_free = $true
            upstream_recipe_reproduced = $false
            pthread_link_abi_proven = $false
            build_closure = $false
            graphics_stack_integrated = $false
        }
        authorizations = [pscustomobject][ordered]@{
            production_build = $false
            link = $false
            stage = $false
            guest_install = $false
            dll_activation = $false
            renderer_selection = $false
            capability_advertisement = $false
        }
    }
}
$json = ($closure | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
[IO.File]::WriteAllText(
    [IO.Path]::GetFullPath($OutputFile),
    $json + "`n",
    [Text.UTF8Encoding]::new($false)
)
Write-Host (
    'Wrote compile-proven Mesa compiler closure with 869 twin normalized ' +
    'i386 COFF objects.'
)

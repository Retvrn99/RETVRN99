# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceFile,
    [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-CompilerClosureSha256 {
    param([byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
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

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$driversRoot = Join-Path $repoRoot 'drivers\win98'
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $driversRoot 'mesa-compiler-closure.json'
}
$evidencePath = [IO.Path]::GetFullPath($EvidenceFile)
$evidenceBytes = [IO.File]::ReadAllBytes($evidencePath)
$evidence = $script:Utf8.GetString($evidenceBytes) | ConvertFrom-Json
if ($evidence._spdx -cne 'GPL-3.0-only' -or $evidence.schema -ne 1 -or
    $evidence.summary.command_count -ne 869 -or
    $evidence.summary.twin_depfile_count -ne 1738 -or
    $evidence.summary.unique_dependency_count -ne 1070 -or
    $evidence.summary.dependency_root_counts.source -ne 652 -or
    $evidence.summary.dependency_root_counts.generated -ne 28 -or
    $evidence.summary.dependency_root_counts.original -ne 4 -or
    $evidence.summary.dependency_root_counts.toolchain -ne 386 -or
    -not $evidence.summary.twin_byte_identical -or
    $evidence.summary.failed_command_count -ne 0 -or
    -not $evidence.summary.exact_source_root -or
    $evidence.summary.exact_source_root_file_count -ne 1489) {
    throw 'Compiler evidence is incomplete or malformed.'
}
$directPlanBytes = [IO.File]::ReadAllBytes(
    (Join-Path $driversRoot 'mesa-gsw-direct-build-plan.json')
)
if ($evidence.direct_plan.bytes -ne $directPlanBytes.Length -or
    $evidence.direct_plan.sha256 -cne
        (Get-CompilerClosureSha256 $directPlanBytes) -or
    $evidence.direct_plan.unit_count -ne 874) {
    throw 'Compiler evidence does not bind the current direct-build plan.'
}
$schemaPath = Join-Path $driversRoot 'mesa-compiler-closure.schema.json'
$schemaBytes = [IO.File]::ReadAllBytes($schemaPath)
$schemaHash = Get-CompilerClosureSha256 $schemaBytes

$inputs = @(
    New-CompilerClosureBinding $driversRoot 'mesa-direct-build-plan' `
        'mesa-gsw-direct-build-plan.json' 'metadata-only-exact-874-units'
    New-CompilerClosureBinding $driversRoot 'mesa-component-closure' `
        'component-closures\mesa9x-23.1.x.json' 'blocked-audited'
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
    schema = 2
    schema_definition = [pscustomobject][ordered]@{
        relative_path = 'mesa-compiler-closure.schema.json'
        bytes = $schemaBytes.Length
        sha256 = $schemaHash
    }
    status = 'evidence-only'
    reason = 'The exact direct recipe has 874 inventoried units, 869 dependency-only compiler commands, five support-only generated sources, an exact 1,489-file materialized upstream proof root, 1,738 byte-identical twin depfiles, and 1,070 unique dependencies. This proves command and dependency closure only. Project-header license review, object compilation, linking, artifacts, installation, activation, and graphics capability remain incomplete and unauthorized.'
    source = [pscustomobject][ordered]@{
        repository = 'https://github.com/JHRobotics/mesa9x.git'
        owning_commit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
        mesa_version = '23.1.9'
        mesa_subtree = 'mesa-23.1.x'
    }
    inputs = $inputs
    direct_recipe = [pscustomobject][ordered]@{
        status = 'exact-metadata-with-compiler-evidence'
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
        proof_source_root = 'exact-materialized-1489-file-root'
        logical_roots = @('source', 'generated', 'original', 'toolchain')
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
        define_names = @(
            'GALLIUM_SOFTPIPE', 'HAVE_PTHREAD', 'HAVE_LLVM',
            'HAVE_GALLIUM_LLVMPIPE', 'GALLIUM_LLVMPIPE',
            'HAVE_LLVMPIPE', 'DRAW_LLVM_AVAILABLE'
        )
        define_prefixes = @('VBOX_')
        support_only_generated_sources = $supportOnly
    }
    evidence = [pscustomobject][ordered]@{
        profile = $evidence.profile
        commands = $evidence.commands
        headers = $evidence.headers
        summary = $evidence.summary
    }
    scope = [pscustomobject][ordered]@{
        classification = 'compiler-command-header-depfile-evidence-only'
        claims = [pscustomobject][ordered]@{
            direct_recipe_reviewed = $true
            compiler_commands_complete = $true
            depfiles_reproducible = $true
            header_dependency_set_complete = $true
            exact_materialized_source_root = $true
            backend_exclusions_proven = $true
            project_header_license_closure = $false
            build_closure = $false
            graphics_stack_integrated = $false
        }
        authorizations = [pscustomobject][ordered]@{
            production_build = $false
            link = $false
            stage = $false
            guest_install = $false
            dll_activation = $false
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
Write-Host "Wrote Mesa compiler closure with 869 commands and 1,070 dependencies."

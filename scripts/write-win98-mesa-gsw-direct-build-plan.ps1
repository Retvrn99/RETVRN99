# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceRoot = 'D:\src\retvrn99-win98',
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requestedSourceRoot = $SourceRoot
. (Join-Path $PSScriptRoot 'verify-win98-mesa-source-seed.ps1') `
    -SourceRoot $requestedSourceRoot
$SourceRoot = $requestedSourceRoot

$script:DirectPlanSchemaSha256 = `
    'df4190adea3cab75809a113878c5a65b92d9654de67395cee8ed6c17b305dd60'
$script:DirectPlanVariables = @(
    'MesaUtilLib_SRC',
    'MesaLib_SRC',
    'MesaWglLib_SRC',
    'MesaGalliumAuxLib_SRC',
    'MesaNineLib_SRC',
    'MesaSVGALib_SRC',
    'eight_SRC'
)
$script:DirectPlanVariableMap = @{
    MesaUtilLib_SRC = @('mesa-core', 'mesa-util')
    MesaLib_SRC = @('mesa-core', 'mesa-core')
    MesaWglLib_SRC = @('wgl', 'mesa-wgl')
    MesaGalliumAuxLib_SRC = @('gallium-auxiliary', 'gallium-auxiliary')
    MesaNineLib_SRC = @('nine', 'nine')
    MesaSVGALib_SRC = @('svga-gallium', 'svga-gallium')
    eight_SRC = @('d3d8to9', 'd3d8to9')
}
$script:DirectPlanArtifacts = @(
    'mesa-util',
    'mesa-core',
    'mesa-wgl',
    'gallium-auxiliary',
    'nine',
    'svga-gallium',
    'd3d8to9'
)

function Get-DirectPlanSha256 {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Read-DirectPlanJson {
    param([string]$Path, [UInt64]$MaximumBytes = 2097152)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or [UInt64]$item.Length -eq 0 -or
        [UInt64]$item.Length -gt $MaximumBytes) {
        throw "Invalid direct-plan input '$Path'."
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Contains("`r") -or -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "Direct-plan input '$Path' is not normalized LF text."
    }
    return ConvertFrom-GswStrictJson -Json $text -Source $Path
}

function New-DirectPlanBinding {
    param([string]$Id, [string]$Path, [string]$RelativePath)
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [pscustomobject][ordered]@{
        id = $Id
        relative_path = $RelativePath
        bytes = $bytes.Length
        sha256 = Get-DirectPlanSha256 $bytes
    }
}

function Get-DirectPlanLanguage {
    param([string]$RelativePath)
    if ($RelativePath.EndsWith('.c', [StringComparison]::Ordinal)) {
        return 'c-gnu99'
    }
    if ($RelativePath.EndsWith('.cpp', [StringComparison]::Ordinal)) {
        return 'cxx-gnu++14'
    }
    if ($RelativePath.EndsWith('.S', [StringComparison]::Ordinal)) {
        return 'assembler-with-cpp'
    }
    throw "Unsupported source language '$RelativePath'."
}

function Get-DirectPlanGeneratedMembership {
    param([string]$RelativePath)
    if ($RelativePath.StartsWith(
            'mesa-23.1.x/src/gallium/auxiliary/',
            [StringComparison]::Ordinal
        )) {
        return @('gallium-auxiliary', 'gallium-auxiliary')
    }
    if ($RelativePath.StartsWith(
            'mesa-23.1.x/src/util/',
            [StringComparison]::Ordinal
        )) {
        return @('mesa-core', 'mesa-util')
    }
    return @('mesa-core', 'mesa-core')
}

function New-DirectPlanUnit {
    param(
        [string]$SourceKind,
        [string]$RelativePath,
        [string]$Language,
        [string]$Family,
        [string]$Disposition,
        [string]$Artifact
    )
    $extension = $RelativePath.LastIndexOf('.')
    if ($extension -le 0) { throw "Source path '$RelativePath' has no extension." }
    $stem = $RelativePath.Substring(0, $extension)
    $leafStem = [IO.Path]::GetFileNameWithoutExtension($RelativePath)
    return [pscustomobject][ordered]@{
        source_kind = $SourceKind
        relative_path = $RelativePath
        language = $Language
        family = $Family
        disposition = $Disposition
        artifact = $Artifact
        object_identity = "obj/$Artifact/$SourceKind/$stem.o"
        leaf_object_name = "$leafStem.o"
    }
}

function Write-GswDirectBuildPlan {
    param([string]$SourceRootPath, [string]$DestinationPath)

    $driversRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\drivers\win98'))
    $seedPath = Join-Path $driversRoot 'mesa-source-seed.json'
    $closurePath = Join-Path $driversRoot 'component-closures\mesa9x-23.1.x.json'
    $generatedPath = Join-Path $driversRoot 'generated-output-locks\mesa-23.1.9.json'
    $originalPath = Join-Path $driversRoot 'mesa-gsw\interface-inputs.lock.json'
    $winsysPath = Join-Path $driversRoot 'mesa-gsw\winsys-interface-inputs.lock.json'
    $schemaPath = Join-Path $driversRoot 'mesa-gsw-direct-build-plan.schema.json'
    $schemaBytes = [IO.File]::ReadAllBytes($schemaPath)
    if ((Get-DirectPlanSha256 $schemaBytes) -cne $script:DirectPlanSchemaSha256) {
        throw 'Direct-build plan schema binding changed.'
    }

    [void]@(Invoke-MesaSourceSeedVerification -SourceRootPath $SourceRootPath `
        -ProfilePath $seedPath -AuditPolicy)
    $checkout = Join-Path ([IO.Path]::GetFullPath($SourceRootPath)) 'mesa9x'
    $commit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
    $makeBlob = Get-MesaSeedGitBlob $checkout (
        (Invoke-MesaSeedGitText $checkout @('rev-parse', "$commit`:Makefile")).Trim()
    )
    $mesaBlob = Get-MesaSeedGitBlob $checkout (
        (Invoke-MesaSeedGitText $checkout @('rev-parse', "$commit`:mesa-23.1.x.mk")).Trim()
    )
    $makeText = ConvertFrom-MesaSeedUtf8 $makeBlob.Bytes 'pinned Makefile'
    $mesaText = ConvertFrom-MesaSeedUtf8 $mesaBlob.Bytes 'pinned mesa-23.1.x.mk'
    $entries = @(
        Read-MesaSeedAssignments $mesaText 'mesa-23.1.x.mk' `
            $script:DirectPlanVariables[0..5]
        Read-MesaSeedAssignments $makeText 'Makefile' @('eight_SRC')
    )
    $memberships = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($entry in $entries) {
        $path = [string]$entry.RelativePath
        $variable = [string]$entry.Variable
        if ($memberships.ContainsKey($path)) {
            if ([string]$memberships[$path] -cne $variable) {
                throw "Source '$path' belongs to multiple artifacts."
            }
        }
        else {
            $memberships.Add($path, $variable)
        }
    }

    $closure = Read-DirectPlanJson $closurePath
    $generated = Read-DirectPlanJson $generatedPath
    $units = [Collections.Generic.List[object]]::new()
    $upstream = @($closure.files | Where-Object { $_.roles -contains 'source-unit' })
    foreach ($file in $upstream) {
        $path = [string]$file.relative_path
        if (-not $memberships.ContainsKey($path)) {
            throw "Upstream source '$path' has no artifact membership."
        }
        $mapping = $script:DirectPlanVariableMap[[string]$memberships[$path]]
        $units.Add((New-DirectPlanUnit 'upstream' $path `
            (Get-DirectPlanLanguage $path) $mapping[0] `
            'upstream-direct-compile-metadata-only' $mapping[1]))
    }
    $generatedSources = @($generated.outputs | Where-Object {
        $_.relative_path -cmatch '\.(c|cpp|S)$'
    })
    foreach ($file in $generatedSources) {
        $path = [string]$file.relative_path
        if ($memberships.ContainsKey($path) -or $path -ceq
            'mesa-23.1.x/src/mapi/glapi/gen/glapi_x86.S') {
            $mapping = if ($memberships.ContainsKey($path)) {
                $script:DirectPlanVariableMap[[string]$memberships[$path]]
            }
            else { @('mesa-core', 'mesa-core') }
            $disposition = 'reviewed-generated-direct-compile-metadata-only'
        }
        else {
            $mapping = Get-DirectPlanGeneratedMembership $path
            $disposition = 'reviewed-generated-support-metadata-only'
        }
        $units.Add((New-DirectPlanUnit 'generated' $path `
            (Get-DirectPlanLanguage $path) $mapping[0] `
            $disposition $mapping[1]))
    }
    $units.Add((New-DirectPlanUnit 'original-gsw' `
        'mesa-gsw/src/gsw_svga_winsys.c' 'c-gnu99' 'svga-gallium' `
        'retvrn99-original-direct-compile-metadata-only' 'svga-gallium'))
    $units.Add((New-DirectPlanUnit 'original-gsw' `
        'mesa-gsw/src/nine_memory_helper.c' 'c-gnu99' 'nine' `
        'retvrn99-original-direct-compile-metadata-only' 'nine'))

    if ($units.Count -ne 874) { throw "Expected 874 source units, observed $($units.Count)." }
    $objectSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($unit in $units) {
        if (-not $objectSet.Add([string]$unit.object_identity)) {
            throw "Final object identity collision '$($unit.object_identity)'."
        }
    }
    $collisionGroups = [Collections.Generic.List[object]]::new()
    $leafGroups = @($units | Group-Object -CaseSensitive -Property leaf_object_name |
        Where-Object Count -gt 1 | Sort-Object -CaseSensitive -Property Name)
    $collisionUnitCount = 0
    foreach ($group in $leafGroups) {
        $collisionUnits = [Collections.Generic.List[object]]::new()
        foreach ($unit in @($group.Group | Sort-Object -CaseSensitive `
                -Property source_kind, relative_path)) {
            $collisionUnits.Add([ordered]@{
                source_kind = $unit.source_kind
                relative_path = $unit.relative_path
                object_identity = $unit.object_identity
            })
        }
        $collisionUnitCount += $collisionUnits.Count
        $collisionGroups.Add([ordered]@{
            leaf_object_name = $group.Name
            count = $collisionUnits.Count
            units = @($collisionUnits)
        })
    }
    $artifactCounts = [ordered]@{}
    foreach ($artifact in $script:DirectPlanArtifacts) {
        $artifactCounts[$artifact] = @($units | Where-Object artifact -ceq $artifact).Count
    }
    $plan = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        schema_definition = [ordered]@{
            relative_path = 'mesa-gsw-direct-build-plan.schema.json'
            bytes = $schemaBytes.Length
            sha256 = $script:DirectPlanSchemaSha256
        }
        status = 'metadata-only'
        reason = 'Every source has an exact language, family, disposition, artifact, and collision-free object identity, but compiler commands, headers, depfiles, exports, links, artifacts, activation, and graphics capabilities remain unproven and unauthorized.'
        source = [ordered]@{
            repository = 'https://github.com/JHRobotics/mesa9x.git'
            commit = $commit
            mesa_version = '23.1.9'
        }
        inputs = @(
            New-DirectPlanBinding 'mesa-component-closure' $closurePath `
                'component-closures/mesa9x-23.1.x.json'
            New-DirectPlanBinding 'mesa-generated-output-lock' $generatedPath `
                'generated-output-locks/mesa-23.1.9.json'
            New-DirectPlanBinding 'original-gsw-memory-source' $originalPath `
                'mesa-gsw/interface-inputs.lock.json'
            New-DirectPlanBinding 'original-gsw-winsys-source' $winsysPath `
                'mesa-gsw/winsys-interface-inputs.lock.json'
        )
        classification = [ordered]@{
            unit_order = 'source-kind-then-relative-path-ordinal-case-sensitive'
            object_identity_algorithm = 'obj/artifact/source-kind/full-path-without-extension.o'
            leaf_collision_algorithm = 'case-sensitive-leaf-without-extension.o'
            artifacts = $script:DirectPlanArtifacts
        }
        inventory = [ordered]@{
            upstream_source_units = 837
            upstream_c = 742
            upstream_cxx = 95
            generated_source_units = 35
            generated_c = 32
            generated_cxx = 2
            generated_assembly = 1
            original_source_units = 2
            total_source_units = 874
            direct_compile_units = 869
            support_only_units = 5
            artifact_counts = $artifactCounts
        }
        units = @($units)
        object_collisions = [ordered]@{
            leaf_collision_group_count = $collisionGroups.Count
            leaf_collision_unit_count = $collisionUnitCount
            leaf_collision_groups = @($collisionGroups)
            final_identity_collision_count = 0
            final_identity_collisions = @()
        }
        empty_evidence = [ordered]@{
            compiler_commands = @()
            headers = @()
            depfiles = @()
            exports = @()
            link_steps = @()
            artifacts = @()
        }
        scope = [ordered]@{
            claims = [ordered]@{
                source_assignment_complete = $true
                object_identity_collision_free = $true
                compiler_commands_complete = $false
                header_closure_complete = $false
                depfiles_reproducible = $false
                graphics_stack_integrated = $false
            }
            authorizations = [ordered]@{
                production_build = $false
                link = $false
                stage = $false
                guest_install = $false
                dll_activation = $false
                capability_advertisement = $false
            }
        }
    }
    $json = ($plan | ConvertTo-Json -Depth 16) -replace "`r`n", "`n"
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($DestinationPath),
        $json + "`n",
        [Text.UTF8Encoding]::new($false)
    )
    Write-Output (
        "Wrote metadata-only direct-build plan: $($units.Count) units, " +
        "$($collisionGroups.Count) leaf collision groups, zero final collisions."
    )
}

if ($MyInvocation.InvocationName -cne '.') {
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path $PSScriptRoot `
            '..\drivers\win98\mesa-gsw-direct-build-plan.json'
    }
    Write-GswDirectBuildPlan $SourceRoot ([IO.Path]::GetFullPath($OutputPath))
}

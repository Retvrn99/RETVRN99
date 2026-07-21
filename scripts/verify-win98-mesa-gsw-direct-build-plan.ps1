# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceRoot = 'D:\src\retvrn99-win98',
    [string]$PlanFile,
    [switch]$SkipRegeneration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requestedSourceRoot = $SourceRoot
. (Join-Path $PSScriptRoot 'write-win98-mesa-gsw-direct-build-plan.ps1') `
    -SourceRoot $requestedSourceRoot
$SourceRoot = $requestedSourceRoot

function Read-GswDirectPlanFile {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -eq 0 -or $item.Length -gt 2097152) {
        throw "Invalid direct-build plan '$Path'."
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Contains("`r") -or -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "Direct-build plan '$Path' is not normalized LF text."
    }
    return [pscustomobject]@{
        Bytes = $bytes
        Value = ConvertFrom-GswStrictJson -Json $text -Source $Path
    }
}

function Assert-GswDirectPlanBinding {
    param([object]$Binding, [string]$DriversRoot)
    $path = Join-Path $DriversRoot $Binding.relative_path
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ne [int64]$Binding.bytes -or
        (Get-DirectPlanSha256 $bytes) -cne $Binding.sha256) {
        throw "Direct-plan input binding '$($Binding.id)' changed."
    }
}

function Assert-GswDirectBuildPlan {
    param(
        [string]$SourceRootPath,
        [string]$MetadataPath,
        [bool]$Regenerate
    )

    $read = Read-GswDirectPlanFile $MetadataPath
    $plan = $read.Value
    $driversRoot = Split-Path -Parent ([IO.Path]::GetFullPath($MetadataPath))
    if ($plan._spdx -cne 'GPL-3.0-only' -or $plan.schema -ne 1 -or
        $plan.status -cne 'metadata-only') {
        throw 'Direct-build plan identity or status changed.'
    }
    $schemaPath = Join-Path $driversRoot $plan.schema_definition.relative_path
    $schemaBytes = [IO.File]::ReadAllBytes($schemaPath)
    if ($schemaBytes.Length -ne [int64]$plan.schema_definition.bytes -or
        (Get-DirectPlanSha256 $schemaBytes) -cne $plan.schema_definition.sha256 -or
        $plan.schema_definition.sha256 -cne $script:DirectPlanSchemaSha256) {
        throw 'Direct-build plan schema binding changed.'
    }
    if ($plan.inputs.Count -ne 4) { throw 'Direct-build plan input count changed.' }
    foreach ($binding in $plan.inputs) {
        Assert-GswDirectPlanBinding $binding $driversRoot
    }
    if ([string]::Join('|', @($plan.classification.artifacts)) -cne
        [string]::Join('|', $script:DirectPlanArtifacts)) {
        throw 'Direct-build artifact order changed.'
    }
    if ($plan.units.Count -ne 874) {
        throw "Direct-build plan must assign exactly 874 sources."
    }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $objects = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $kindCounts = @{'upstream'=0; 'generated'=0; 'original-gsw'=0}
    $languageCounts = @{'c-gnu99'=0; 'cxx-gnu++14'=0; 'assembler-with-cpp'=0}
    $artifactCounts = @{}
    $directCompileCount = 0
    $supportOnlyCount = 0
    foreach ($artifact in $script:DirectPlanArtifacts) { $artifactCounts[$artifact] = 0 }
    $previousKey = ''
    foreach ($unit in $plan.units) {
        $key = switch ($unit.source_kind) {
            'upstream' { '0|' + $unit.relative_path }
            'generated' { '1|' + $unit.relative_path }
            'original-gsw' { '2|' + $unit.relative_path }
            default { throw "Invalid source kind '$($unit.source_kind)'." }
        }
        if ($previousKey.Length -ne 0 -and
            [StringComparer]::Ordinal.Compare($previousKey, $key) -ge 0) {
            throw 'Direct-build units are not in exact ordinal source-kind order.'
        }
        $previousKey = $key
        $pathKey = $unit.source_kind + '|' + $unit.relative_path
        if (-not $paths.Add($pathKey)) { throw "Duplicate source assignment '$pathKey'." }
        $extension = [IO.Path]::GetExtension([string]$unit.relative_path)
        $expectedLanguage = switch -CaseSensitive ($extension) {
            '.c' { 'c-gnu99' }
            '.cpp' { 'cxx-gnu++14' }
            '.S' { 'assembler-with-cpp' }
            default { throw "Unsupported source extension '$extension'." }
        }
        if ($unit.language -cne $expectedLanguage) {
            throw "Language assignment mismatch for '$($unit.relative_path)'."
        }
        $expectedDisposition = switch ($unit.source_kind) {
            'upstream' { 'upstream-direct-compile-metadata-only' }
            'generated' {
                if ($unit.relative_path -cin @(
                    'mesa-23.1.x/src/gallium/auxiliary/util/u_tracepoints.c',
                    'mesa-23.1.x/src/mapi/glapi/gen/indirect.c',
                    'mesa-23.1.x/src/mapi/glapi/gen/indirect_init.c',
                    'mesa-23.1.x/src/mapi/glapi/gen/indirect_size.c',
                    'mesa-23.1.x/src/mapi/glapi/glapi_gentable.c'
                )) { 'reviewed-generated-support-metadata-only' }
                else { 'reviewed-generated-direct-compile-metadata-only' }
            }
            'original-gsw' { 'retvrn99-original-direct-compile-metadata-only' }
        }
        if ($unit.disposition -cne $expectedDisposition) {
            throw "Disposition mismatch for '$($unit.relative_path)'."
        }
        if (-not $artifactCounts.ContainsKey([string]$unit.artifact)) {
            throw "Unknown artifact '$($unit.artifact)'."
        }
        $stem = $unit.relative_path.Substring(
            0, $unit.relative_path.Length - $extension.Length
        )
        $expectedObject = "obj/$($unit.artifact)/$($unit.source_kind)/$stem.o"
        if ($unit.object_identity -cne $expectedObject -or
            -not $objects.Add([string]$unit.object_identity)) {
            throw "Object identity is invalid or colliding for '$pathKey'."
        }
        $expectedLeaf = [IO.Path]::GetFileNameWithoutExtension(
            [string]$unit.relative_path
        ) + '.o'
        if ($unit.leaf_object_name -cne $expectedLeaf) {
            throw "Leaf object name mismatch for '$pathKey'."
        }
        $kindCounts[[string]$unit.source_kind]++
        $languageCounts[[string]$unit.language]++
        $artifactCounts[[string]$unit.artifact]++
        if ($unit.disposition -ceq 'reviewed-generated-support-metadata-only') {
            $supportOnlyCount++
        }
        else { $directCompileCount++ }
    }
    if ($kindCounts.upstream -ne 837 -or $kindCounts.generated -ne 35 -or
        $kindCounts.'original-gsw' -ne 2 -or
        $languageCounts.'c-gnu99' -ne 776 -or
        $languageCounts.'cxx-gnu++14' -ne 97 -or
        $languageCounts.'assembler-with-cpp' -ne 1) {
        throw 'Direct-build source-kind or language inventory changed.'
    }
    if ($directCompileCount -ne 869 -or $supportOnlyCount -ne 5 -or
        $plan.inventory.direct_compile_units -ne 869 -or
        $plan.inventory.support_only_units -ne 5) {
        throw 'Direct-build compile disposition inventory changed.'
    }
    foreach ($artifact in $script:DirectPlanArtifacts) {
        if ([int]$plan.inventory.artifact_counts.$artifact -ne $artifactCounts[$artifact]) {
            throw "Artifact count mismatch for '$artifact'."
        }
    }
    $leafGroups = @($plan.units | Group-Object -CaseSensitive leaf_object_name |
        Where-Object Count -gt 1 | Sort-Object -CaseSensitive Name)
    if ($plan.object_collisions.leaf_collision_group_count -ne $leafGroups.Count -or
        $plan.object_collisions.final_identity_collision_count -ne 0 -or
        $plan.object_collisions.final_identity_collisions.Count -ne 0) {
        throw 'Direct-build object collision summary changed.'
    }
    if ($plan.object_collisions.leaf_collision_groups.Count -ne $leafGroups.Count) {
        throw 'Direct-build leaf collision table is not exact.'
    }
    for ($index = 0; $index -lt $leafGroups.Count; $index++) {
        $expected = $leafGroups[$index]
        $observed = $plan.object_collisions.leaf_collision_groups[$index]
        if ($observed.leaf_object_name -cne $expected.Name -or
            $observed.count -ne $expected.Count) {
            throw 'Direct-build leaf collision table entry changed.'
        }
    }
    foreach ($property in $plan.empty_evidence.PSObject.Properties) {
        if ($property.Value.Count -ne 0) {
            throw "Direct-build '$($property.Name)' evidence is not empty."
        }
    }
    foreach ($claim in $plan.scope.claims.PSObject.Properties) {
        $expected = $claim.Name -in @(
            'source_assignment_complete', 'object_identity_collision_free'
        )
        if ($claim.Value -isnot [bool] -or $claim.Value -ne $expected) {
            throw "Direct-build claim '$($claim.Name)' changed."
        }
    }
    foreach ($authorization in $plan.scope.authorizations.PSObject.Properties) {
        if ($authorization.Value -isnot [bool] -or $authorization.Value) {
            throw "Direct-build authorization '$($authorization.Name)' is not false."
        }
    }
    if ($Regenerate) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) (
            'retvrn99-mesa-direct-plan-' + [Guid]::NewGuid().ToString('N') + '.json'
        )
        try {
            [void]@(Write-GswDirectBuildPlan $SourceRootPath $temp)
            $generatedBytes = [IO.File]::ReadAllBytes($temp)
            if ($generatedBytes.Length -ne $read.Bytes.Length -or
                (Get-DirectPlanSha256 $generatedBytes) -cne
                    (Get-DirectPlanSha256 $read.Bytes)) {
                throw 'Direct-build plan is not byte-reproducible.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }
    Write-Output (
        'Verified metadata-only Mesa direct-build plan: 837 upstream, 35 ' +
        'generated, and 2 original sources; exact assignments and object ' +
        'identities; commands, headers, depfiles, links, artifacts, and ' +
        'authorizations remain empty.'
    )
}

if ($MyInvocation.InvocationName -cne '.') {
    if ([string]::IsNullOrWhiteSpace($PlanFile)) {
        $PlanFile = Join-Path $PSScriptRoot `
            '..\drivers\win98\mesa-gsw-direct-build-plan.json'
    }
    Assert-GswDirectBuildPlan $SourceRoot ([IO.Path]::GetFullPath($PlanFile)) `
        (-not $SkipRegeneration)
}

# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$TemplateClosureFile,
    [switch]$SkipTemplateRoundTrip,
    [switch]$SkipClosureMutations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'mesa-object-proof.ps1')
. (Join-Path $PSScriptRoot 'mesa-compiler-dependency-roles.ps1')

$driversRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\drivers\win98')
)
if ([string]::IsNullOrWhiteSpace($TemplateClosureFile)) {
    $templatePath = Join-Path $driversRoot 'mesa-compiler-closure.json'
}
else {
    $templatePath = [IO.Path]::GetFullPath($TemplateClosureFile)
}
$old = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
$component = Get-Content -Raw (
    Join-Path $driversRoot 'component-closures\mesa9x-23.1.x.json'
) | ConvertFrom-Json
$componentByPath = @{}
foreach ($file in $component.files) {
    $componentByPath[[string]$file.relative_path] = $file
}

function ConvertTo-GeneratedFirstArguments {
    param([object[]]$Arguments)

    $base = [Collections.Generic.List[object]]::new()
    $original = [Collections.Generic.List[object]]::new()
    $generated = [Collections.Generic.List[object]]::new()
    $source = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        if ($argument -cne '-I' -or $index + 1 -ge $Arguments.Count) {
            $base.Add($Arguments[$index])
            continue
        }
        $value = [string]$Arguments[++$index]
        if ($value.StartsWith('{generated}/')) {
            $generated.Add('-I')
            $generated.Add($value)
        }
        elseif ($value.StartsWith('{source}/')) {
            $source.Add('-I')
            $source.Add($value)
        }
        else {
            $original.Add('-I')
            $original.Add($value)
        }
    }
    return @($base) + @($original) + @($generated) + @($source)
}

if ($old.schema -eq 2 -and $old.status -ceq 'evidence-only') {
    $profile = $old.evidence.profile
    $profile.timeout_seconds = 30
    $profile | Add-Member NoteProperty maximum_concurrent_children 1 -Force
    $profile | Add-Member NoteProperty batch_size 25 -Force
    $profile | Add-Member NoteProperty batch_quiescence_milliseconds 1000 -Force
    $profile.common_arguments = ConvertTo-GeneratedFirstArguments `
        @($profile.common_arguments)
    $objectCommon = @($profile.common_arguments[5..(
        $profile.common_arguments.Count - 1
    )]) + @(
        '-fno-ident', '-fno-asynchronous-unwind-tables', '-fno-unwind-tables',
        '-fno-stack-protector'
    )
    $perUnit = @(
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
    $objectProfile = [pscustomobject][ordered]@{
        id = 'mesa-object-v1'
        mode = 'compile-only-no-link'
        timeout_seconds = 30
        maximum_concurrent_children = 1
        batch_size = 25
        batch_quiescence_milliseconds = 1000
        common_arguments = $objectCommon
        language_arguments = $profile.language_arguments
        per_unit_arguments = $perUnit
        working_directory = '{proof}'
        linker_invocations = 0
    }
    $unitArgumentOverrides = @(
        [pscustomobject][ordered]@{
            command_id = 'cmd-0002'
            source = '{source}/mesa-23.1.x/src/c11/impl/threads_posix.c'
            profiles = [string[]]@('mesa-dependency-v1', 'mesa-object-v1')
            insertion = 'after-common-before-language'
            arguments = [string[]]@('-DHAVE_PTHREAD')
            mode = 'compile-context-only-no-link'
        }
        [pscustomobject][ordered]@{
            command_id = 'cmd-0792'
            source = '{source}/mesa-23.1.x/src/util/rwlock.c'
            profiles = [string[]]@('mesa-dependency-v1', 'mesa-object-v1')
            insertion = 'after-common-before-language'
            arguments = [string[]]@('-DHAVE_PTHREAD')
            mode = 'compile-context-only-no-link'
        }
        [pscustomobject][ordered]@{
            command_id = 'cmd-0852'
            source = '{generated}/mesa-23.1.x/src/mapi/glapi/gen/glapi_x86.S'
            profiles = [string[]]@('mesa-dependency-v1', 'mesa-object-v1')
            insertion = 'after-common-before-language'
            arguments = [string[]]@(
                '-DUSE_X86_ASM', '-DGLX_X86_READONLY_TEXT'
            )
            mode = 'compile-context-only-no-link'
        }
    )
    $headers = @($old.evidence.headers | Where-Object {
        -not ($_.root -ceq 'source' -and $_.relative_path -ceq
            'mesa-23.1.x/src/compiler/nir_builder_opcodes.h')
    })
    foreach ($header in $headers) {
        if ($header.root -ceq 'source') {
            $file = $componentByPath[[string]$header.relative_path]
            $canonical = Get-MesaCanonicalCompilerDependencyDescriptor $file
            $header.bytes = $canonical.Bytes
            $header.sha256 = $canonical.Sha256
            $header.license_scope = 'reviewed-component-closure'
        }
    }
    $generatedLock = Get-Content -Raw (
        Join-Path $driversRoot 'generated-output-locks\mesa-23.1.9.json'
    ) | ConvertFrom-Json
    $generatedBuilder = @($generatedLock.outputs | Where-Object {
        $_.relative_path -ceq
            'mesa-23.1.x/src/compiler/nir/nir_builder_opcodes.h'
    })[0]
    $headers += [pscustomobject][ordered]@{
        root = 'generated'
        relative_path = [string]$generatedBuilder.relative_path
        bytes = [int64]$generatedBuilder.bytes
        sha256 = [string]$generatedBuilder.sha256
        license_scope = 'reviewed-generated-output-lock'
    }
    $headerByIdentity =
        [Collections.Generic.SortedDictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
    foreach ($header in $headers) {
        $headerByIdentity.Add(
            "{$($header.root)}/$($header.relative_path)", $header
        )
    }
    $headers = @($headerByIdentity.Values)
}
elseif ($old.schema -eq 3 -and $old.status -ceq 'compile-proven') {
    $profile = $old.evidence.profile
    $objectProfile = $old.evidence.object_profile
    $unitArgumentOverrides = @($old.evidence.unit_argument_overrides)
    $headers = @($old.evidence.headers)
}
else {
    throw "Unsupported compiler-closure template '$templatePath'."
}
$objects = @()
for ($index = 0; $index -lt $old.evidence.commands.Count; $index++) {
    $ordinal = $index + 1
    $commandId = 'cmd-' + $ordinal.ToString('D4')
    $hash = Get-MesaObjectSha256 (
        [Text.Encoding]::UTF8.GetBytes("synthetic-$commandId")
    )
    $objects += [pscustomobject][ordered]@{
        id = 'object-' + $ordinal.ToString('D4')
        command_id = $commandId
        unit_ordinal = $ordinal
        object = [string]$old.evidence.commands[$index].object
        random_seed = "retvrn99-mesa-$commandId-v1"
        bytes = 64
        run_a = [pscustomobject][ordered]@{
            raw_sha256 = $hash
            timestamp = 0
            normalized_sha256 = $hash
        }
        run_b = [pscustomobject][ordered]@{
            raw_sha256 = $hash
            timestamp = 0
            normalized_sha256 = $hash
        }
        normalized_sha256 = $hash
        twin_byte_identical = $true
    }
}
$evidence = [pscustomobject][ordered]@{
    _spdx = 'GPL-3.0-only'
    schema = 2
    direct_plan = $old.PSObject.Copy().evidence.PSObject.Copy()
}
$planBytes = [IO.File]::ReadAllBytes(
    (Join-Path $driversRoot 'mesa-gsw-direct-build-plan.json')
)
$evidence.direct_plan = [pscustomobject][ordered]@{
    bytes = $planBytes.Length
    sha256 = Get-MesaObjectSha256 $planBytes
    unit_count = 874
}
$evidence | Add-Member NoteProperty profile $profile
$evidence | Add-Member NoteProperty object_profile $objectProfile
$evidence | Add-Member NoteProperty unit_argument_overrides `
    $unitArgumentOverrides
$evidence | Add-Member NoteProperty commands $old.evidence.commands
$evidence | Add-Member NoteProperty headers $headers
$evidence | Add-Member NoteProperty objects $objects
$summary = $old.evidence.summary
$summary.dependency_root_counts.source = 651
$summary.dependency_root_counts.generated = 29
$summary | Add-Member NoteProperty object_compile_count 1738 -Force
$summary | Add-Member NoteProperty unique_object_count 869 -Force
$summary | Add-Member NoteProperty twin_objects_byte_identical $true -Force
$summary | Add-Member NoteProperty object_identity_collision_count 0 -Force
$summary | Add-Member NoteProperty failed_object_compile_count 0 -Force
$summary | Add-Member NoteProperty temporary_object_count 0 -Force
$summary | Add-Member NoteProperty aggregate_object_sha256 `
    (Get-MesaObjectAggregateSha256 $objects) -Force
$evidence | Add-Member NoteProperty summary $summary

$id = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "retvrn99-mesa-compiler-v3-test-$id"
$evidencePath = Join-Path $fixtureRoot 'evidence.json'
$closurePath = Join-Path $fixtureRoot 'mesa-compiler-closure.json'
try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $json = ($evidence | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
    [IO.File]::WriteAllText(
        $evidencePath, $json + "`n", [Text.UTF8Encoding]::new($false)
    )
    & (Join-Path $PSScriptRoot 'write-win98-mesa-compiler-closure.ps1') `
        -EvidenceFile $evidencePath -OutputFile $closurePath | Out-Null
    $fixtureInputs = @(
        'mesa-compiler-closure.schema.json',
        'mesa-gsw-direct-build-plan.json',
        'component-closures/mesa9x-23.1.x.json',
        'generated-output-locks/mesa-23.1.9.json',
        'mesa-generated-source-reproducibility.json',
        'mesa-gsw/interface-inputs.lock.json',
        'mesa-gsw/winsys-interface-inputs.lock.json',
        'mesa-gsw/include/gdi/gdi_sw_winsys.h',
        'guest-cpu-profile.json',
        'mingw32-toolchain.lock.json'
    )
    foreach ($relative in $fixtureInputs) {
        $target = Join-Path $fixtureRoot ($relative.Replace('/', '\'))
        [void][IO.Directory]::CreateDirectory(
            [IO.Path]::GetDirectoryName($target)
        )
        [IO.File]::WriteAllBytes(
            $target,
            [IO.File]::ReadAllBytes((Join-Path $driversRoot `
                ($relative.Replace('/', '\'))))
        )
    }
    & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
        -ClosureFile $closurePath | Out-Null
    if (-not (Test-Json -Json (Get-Content -Raw $closurePath) `
            -SchemaFile (Join-Path $driversRoot `
                'mesa-compiler-closure.schema.json'))) {
        throw 'Synthetic schema-v3 closure failed JSON Schema validation.'
    }
    if (-not $SkipClosureMutations) {
        & (Join-Path $PSScriptRoot 'win98-mesa-compiler-closure.tests.ps1') `
            -ClosureFile $closurePath | Out-Host
    }
    Write-Output 'PASS: synthetic schema-v3 writer, verifier, and JSON Schema'
    if ($old.schema -eq 2 -and -not $SkipTemplateRoundTrip) {
        & $PSCommandPath -TemplateClosureFile $closurePath `
            -SkipTemplateRoundTrip -SkipClosureMutations | Out-Host
        Write-Output 'PASS: schema-v2 and schema-v3 template compatibility'
    }
}
finally {
    if ([IO.Directory]::Exists($fixtureRoot)) {
        [IO.Directory]::Delete($fixtureRoot, $true)
    }
}

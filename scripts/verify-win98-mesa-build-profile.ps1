# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$ProfileFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')

$script:MaximumJsonBytes = [UInt64]65536
$script:MaximumEvidenceJsonBytes = [UInt64]4194304
$script:ExpectedSchemaSha256 = 'de12369b6640a83880ac187478853f981e14df907ff6152c8dde024ba3e74e26'
$script:AllowedFamilies = @(
    'mesa-core',
    'wgl',
    'svga-gallium',
    'nine',
    'd3d8to9'
)
$script:ForbiddenFeatures = @(
    'alternate-mesa-generations',
    'bochs-3d',
    'd3d10',
    'final-dll-activation',
    'llvm',
    'llvmpipe',
    'osmesa',
    'qemu-3dfx',
    'renderer-selection',
    'softgpu-dependency',
    'softgpu-device-identity',
    'softgpu-installer',
    'softgpu-runtime',
    'softpipe',
    'svga9-production',
    'user-selectable-renderer',
    'vesa-3d',
    'virgl',
    'virtualbox-memory-helpers',
    'virtualbox-winsys',
    'vmware-branding',
    'vmware-device-emulation',
    'vmware-memory-helpers',
    'vmware-winsys',
    'windows-95-payloads',
    'windows-me-payloads',
    'wine9x-runtime',
    'wined3d',
    'zink'
)
$script:DependencyBindings = @(
    [pscustomobject]@{
        Id = 'mesa-file-license-closure'
        RelativePath = 'component-closures/mesa9x-23.1.x.json'
    },
    [pscustomobject]@{
        Id = 'mesa-generator-output-lock'
        RelativePath = 'generated-output-locks/mesa-23.1.9.json'
    },
    [pscustomobject]@{
        Id = 'mesa-generated-source-reproducibility'
        RelativePath = 'mesa-generated-source-reproducibility.json'
    },
    [pscustomobject]@{
        Id = 'direct-pruned-build-recipe'
        RelativePath = 'mesa-gsw-direct-build-plan.json'
    },
    [pscustomobject]@{
        Id = 'gsw-886-win98-i686-v1'
        RelativePath = 'mesa-compiler-closure.json'
    },
    [pscustomobject]@{
        Id = 'original-gsw-winsys'
        RelativePath = 'mesa-gsw/winsys-interface-inputs.lock.json'
    },
    [pscustomobject]@{
        Id = 'original-gsw-memory-helpers'
        RelativePath = 'mesa-gsw/interface-inputs.lock.json'
    },
    [pscustomobject]@{
        Id = 'backend-exclusion-proof'
        RelativePath = 'mesa-compiler-closure.json'
    },
    [pscustomobject]@{
        Id = 'compile-output-reproducibility'
        RelativePath = 'mesa-compiler-closure.json'
    }
)

if ([string]::IsNullOrWhiteSpace($ProfileFile)) {
    $ProfileFile = Join-Path $PSScriptRoot '..\drivers\win98\mesa-gsw-build-profile.json'
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Assert-RegularBoundedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be a regular file."
    }
    if ([UInt64]$item.Length -gt $script:MaximumJsonBytes) {
        throw "$Name exceeds the $($script:MaximumJsonBytes)-byte bound."
    }
}

function Skip-ProfileJsonWhitespace {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position
    )

    while ($Position.Value -lt $Json.Length) {
        if ($Json[$Position.Value] -notin @(' ', "`t", "`r", "`n")) {
            return
        }
        $Position.Value++
    }
}

function Read-ProfileJsonString {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source
    )

    if ($Position.Value -ge $Json.Length -or $Json[$Position.Value] -ne '"') {
        throw "Invalid JSON string in $Source."
    }
    $Position.Value++
    $builder = [Text.StringBuilder]::new()
    while ($Position.Value -lt $Json.Length) {
        $character = $Json[$Position.Value]
        $Position.Value++
        if ($character -eq '"') {
            return $builder.ToString()
        }
        if ([int][char]$character -lt 0x20) {
            throw "Invalid control character in JSON string in $Source."
        }
        if ($character -ne '\') {
            [void]$builder.Append($character)
            continue
        }
        if ($Position.Value -ge $Json.Length) {
            throw "Incomplete JSON escape in $Source."
        }
        $escaped = $Json[$Position.Value]
        $Position.Value++
        switch ($escaped) {
            '"' { [void]$builder.Append('"') }
            '\' { [void]$builder.Append('\') }
            '/' { [void]$builder.Append('/') }
            'b' { [void]$builder.Append([char]0x08) }
            'f' { [void]$builder.Append([char]0x0c) }
            'n' { [void]$builder.Append([char]0x0a) }
            'r' { [void]$builder.Append([char]0x0d) }
            't' { [void]$builder.Append([char]0x09) }
            'u' {
                if ($Position.Value + 4 -gt $Json.Length) {
                    throw "Incomplete JSON Unicode escape in $Source."
                }
                $hex = $Json.Substring($Position.Value, 4)
                if ($hex -cnotmatch '^[0-9a-fA-F]{4}$') {
                    throw "Invalid JSON Unicode escape in $Source."
                }
                [void]$builder.Append([char][Convert]::ToInt32($hex, 16))
                $Position.Value += 4
            }
            default { throw "Invalid JSON escape in $Source." }
        }
    }
    throw "Unterminated JSON string in $Source."
}

function Read-ProfileJsonValue {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    if ($Depth -gt 16) {
        throw "JSON nesting exceeds the depth bound in $Source."
    }
    Skip-ProfileJsonWhitespace $Json $Position
    if ($Position.Value -ge $Json.Length) {
        throw "Incomplete JSON value in $Source."
    }
    switch ($Json[$Position.Value]) {
        '{' { Read-ProfileJsonObject $Json $Position $Source $Depth; return }
        '[' { Read-ProfileJsonArray $Json $Position $Source $Depth; return }
        '"' { $null = Read-ProfileJsonString $Json $Position $Source; return }
    }
    $start = $Position.Value
    while ($Position.Value -lt $Json.Length -and
        $Json[$Position.Value] -notin @(',', ']', '}', ' ', "`t", "`r", "`n")) {
        $Position.Value++
    }
    if ($Position.Value -eq $start) {
        throw "Invalid JSON value in $Source."
    }
}

function Read-ProfileJsonObject {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    $Position.Value++
    $properties = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    Skip-ProfileJsonWhitespace $Json $Position
    if ($Position.Value -lt $Json.Length -and $Json[$Position.Value] -eq '}') {
        $Position.Value++
        return
    }
    while ($Position.Value -lt $Json.Length) {
        Skip-ProfileJsonWhitespace $Json $Position
        $name = [string](Read-ProfileJsonString $Json $Position $Source)
        if (-not $properties.Add($name)) {
            throw "Duplicate JSON property '$name' in $Source."
        }
        Skip-ProfileJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length -or $Json[$Position.Value] -ne ':') {
            throw "Missing JSON property separator in $Source."
        }
        $Position.Value++
        Read-ProfileJsonValue $Json $Position $Source ($Depth + 1)
        Skip-ProfileJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length) {
            throw "Unterminated JSON object in $Source."
        }
        if ($Json[$Position.Value] -eq '}') {
            $Position.Value++
            return
        }
        if ($Json[$Position.Value] -ne ',') {
            throw "Invalid JSON object separator in $Source."
        }
        $Position.Value++
    }
    throw "Unterminated JSON object in $Source."
}

function Read-ProfileJsonArray {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    $Position.Value++
    Skip-ProfileJsonWhitespace $Json $Position
    if ($Position.Value -lt $Json.Length -and $Json[$Position.Value] -eq ']') {
        $Position.Value++
        return
    }
    while ($Position.Value -lt $Json.Length) {
        Read-ProfileJsonValue $Json $Position $Source ($Depth + 1)
        Skip-ProfileJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length) {
            throw "Unterminated JSON array in $Source."
        }
        if ($Json[$Position.Value] -eq ']') {
            $Position.Value++
            return
        }
        if ($Json[$Position.Value] -ne ',') {
            throw "Invalid JSON array separator in $Source."
        }
        $Position.Value++
    }
    throw "Unterminated JSON array in $Source."
}

function Read-StrictJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        return Read-GswStrictJsonFile -Path $Path -Name $Name `
            -MaximumBytes $script:MaximumJsonBytes
    }
    catch {
        throw "Malformed $Name JSON: $($_.Exception.Message)"
    }
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object -or $Object -is [string] -or $Object -is [Array] -or
        $Object.GetType().IsValueType) {
        throw "$Name must be a JSON object."
    }
    $actual = @($Object.PSObject.Properties.Name)
    foreach ($property in $actual) {
        if ($Expected -cnotcontains $property) {
            throw "Unexpected property '$property' in $Name."
        }
    }
    foreach ($property in $Expected) {
        if ($actual -cnotcontains $property) {
            throw "Missing property '$property' in $Name."
        }
    }
}

function Assert-JsonString {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$MaximumBytes = 1024
    )

    if ($Value -isnot [string] -or
        [Text.Encoding]::UTF8.GetByteCount($Value) -gt $MaximumBytes) {
        throw "$Name must be a bounded JSON string."
    }
    return [string]$Value
}

function Assert-JsonStringEquals {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $text = Assert-JsonString $Value $Name
    if ($text -cne $Expected) {
        throw "$Name must be '$Expected'."
    }
}

function Assert-JsonBoolean {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [bool]) {
        throw "$Name must be a JSON boolean."
    }
    return [bool]$Value
}

function Assert-JsonIntegerEquals {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][Int64]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value -or
        @([byte], [uint16], [uint32], [uint64], [sbyte], [int16], [int32], [int64]) `
            -cnotcontains $Value.GetType() -or [Int64]$Value -ne $Expected) {
        throw "$Name must be the JSON integer $Expected."
    }
}

function Assert-JsonArray {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [Array] -or $Value.Count -ne $Count) {
        throw "$Name must be a $Count-item JSON array."
    }
    return ,@($Value)
}

function Assert-ExactStringSequence {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $values = Assert-JsonArray $Value $Expected.Count $Name
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($values[$index] -isnot [string] -or
            $values[$index] -cne $Expected[$index]) {
            throw "$Name must contain only the canonical ordered values."
        }
    }
}

function Assert-LowercaseSha256 {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256 digest."
    }
}

function Assert-FalseJsonProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-ExactProperties $Value $Expected $Name
    foreach ($property in $Expected) {
        if (Assert-JsonBoolean $Value.$property "$Name.$property") {
            throw "$Name.$property must remain false."
        }
    }
}

$profilePath = Get-FullPath $ProfileFile
$profile = Read-StrictJson $profilePath 'Mesa GSW build profile'
Assert-ExactProperties $profile @(
    '_spdx', 'schema', 'schema_definition', 'status', 'reason', 'source',
    'generation_strategy', 'target', 'allowed_families', 'required_support_families',
    'forbidden_features', 'dependencies'
) 'Mesa GSW build profile'
Assert-JsonStringEquals $profile._spdx 'GPL-3.0-only' '_spdx'
Assert-JsonIntegerEquals $profile.schema 2 'schema'

Assert-ExactProperties $profile.schema_definition @('relative_path', 'sha256') `
    'schema_definition'
Assert-JsonStringEquals $profile.schema_definition.relative_path `
    'mesa-gsw-build-profile.schema.json' 'schema_definition.relative_path'
Assert-LowercaseSha256 $profile.schema_definition.sha256 'schema_definition.sha256'
if ($profile.schema_definition.sha256 -cne $script:ExpectedSchemaSha256) {
    throw 'The profile does not bind the canonical Mesa GSW build-profile schema.'
}
$schemaPath = Join-Path (Split-Path -Parent $profilePath) `
    $profile.schema_definition.relative_path
$schema = Read-StrictJson $schemaPath 'Mesa GSW build-profile schema'
$schemaHash = (Get-FileHash -LiteralPath $schemaPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($schemaHash -cne $script:ExpectedSchemaSha256) {
    throw 'Mesa GSW build-profile schema content does not match the canonical digest.'
}
Assert-ExactProperties $schema @(
    '_spdx', '$schema', '$id', 'title', 'type', 'additionalProperties',
    'required', 'properties', '$defs'
) 'Mesa GSW build-profile schema'
Assert-JsonStringEquals $schema._spdx 'GPL-3.0-only' 'schema _spdx'
Assert-JsonStringEquals $schema.'$schema' `
    'https://json-schema.org/draft/2020-12/schema' 'schema dialect'
Assert-JsonStringEquals $schema.'$id' 'mesa-gsw-build-profile.schema.json' 'schema id'
Assert-JsonStringEquals $schema.type 'object' 'schema root type'
if ((Assert-JsonBoolean $schema.additionalProperties 'schema additionalProperties')) {
    throw 'The Mesa GSW build-profile schema root must reject additional properties.'
}

Assert-JsonStringEquals $profile.status 'compile-proven' 'status'
$reason = Assert-JsonString $profile.reason 'reason'
if ([string]::IsNullOrWhiteSpace($reason)) {
    throw 'The compile-proven Mesa GSW build profile must explain its authority boundary.'
}

Assert-ExactProperties $profile.source @(
    'upstream_name', 'repository', 'owning_commit', 'mesa_version', 'mesa_subtree'
) 'source'
Assert-JsonStringEquals $profile.source.upstream_name 'mesa9x' 'source.upstream_name'
Assert-JsonStringEquals $profile.source.repository `
    'https://github.com/JHRobotics/mesa9x.git' 'source.repository'
Assert-JsonStringEquals $profile.source.owning_commit `
    '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f' 'source.owning_commit'
Assert-JsonStringEquals $profile.source.mesa_version '23.1.9' 'source.mesa_version'
Assert-JsonStringEquals $profile.source.mesa_subtree 'mesa-23.1.x' 'source.mesa_subtree'
Assert-JsonStringEquals $profile.generation_strategy `
    'hash-locked-generated-outputs' 'generation_strategy'

Assert-ExactProperties $profile.target @(
    'id', 'kind', 'guest_os', 'architecture', 'command_ir', 'host_renderer',
    'winsys_implementation', 'memory_helper_implementation', 'artifact_class',
    'compile_only', 'build_authorized', 'link_authorized', 'staging_authorized',
    'guest_install_authorized', 'dll_activation_authorized', 'renderer_selection',
    'capability_advertisement'
) 'target'
Assert-JsonStringEquals $profile.target.id 'mesa-23-1-9-gsw-i686-win98se' 'target.id'
Assert-JsonStringEquals $profile.target.kind 'direct-pruned-compile-only' 'target.kind'
Assert-JsonStringEquals $profile.target.guest_os 'windows-98-se' 'target.guest_os'
Assert-JsonStringEquals $profile.target.architecture 'i686' 'target.architecture'
Assert-JsonStringEquals $profile.target.command_ir 'svga10-internal-only' 'target.command_ir'
Assert-JsonStringEquals $profile.target.host_renderer `
    'sdl-gpu-vulkan-only' 'target.host_renderer'
Assert-JsonStringEquals $profile.target.winsys_implementation `
    'retvrn99-original-gsw' 'target.winsys_implementation'
Assert-JsonStringEquals $profile.target.memory_helper_implementation `
    'retvrn99-original-gsw' 'target.memory_helper_implementation'
Assert-JsonStringEquals $profile.target.artifact_class `
    'non-package-compile-evidence' 'target.artifact_class'
$compileOnly = Assert-JsonBoolean $profile.target.compile_only 'target.compile_only'
$buildAuthorized = Assert-JsonBoolean `
    $profile.target.build_authorized 'target.build_authorized'
$linkAuthorized = Assert-JsonBoolean `
    $profile.target.link_authorized 'target.link_authorized'
$stagingAuthorized = Assert-JsonBoolean `
    $profile.target.staging_authorized 'target.staging_authorized'
$guestInstallAuthorized = Assert-JsonBoolean `
    $profile.target.guest_install_authorized 'target.guest_install_authorized'
$dllActivationAuthorized = Assert-JsonBoolean `
    $profile.target.dll_activation_authorized 'target.dll_activation_authorized'
$rendererSelection = Assert-JsonBoolean `
    $profile.target.renderer_selection 'target.renderer_selection'
$capabilityAdvertisement = Assert-JsonBoolean `
    $profile.target.capability_advertisement 'target.capability_advertisement'
if (-not $compileOnly -or $buildAuthorized -or $linkAuthorized -or $stagingAuthorized -or
    $guestInstallAuthorized -or
    $dllActivationAuthorized -or $rendererSelection -or $capabilityAdvertisement) {
    throw 'The Mesa GSW target must remain compile-only and non-activating.'
}

Assert-ExactStringSequence $profile.allowed_families $script:AllowedFamilies `
    'allowed_families'
Assert-ExactStringSequence $profile.required_support_families `
    @('gallium-auxiliary') 'required_support_families'
Assert-ExactStringSequence $profile.forbidden_features $script:ForbiddenFeatures `
    'forbidden_features'

$dependencies = Assert-JsonArray $profile.dependencies $script:DependencyBindings.Count `
    'dependencies'
$evidenceSnapshots = @{}
for ($index = 0; $index -lt $script:DependencyBindings.Count; $index++) {
    $dependency = $dependencies[$index]
    $binding = $script:DependencyBindings[$index]
    Assert-ExactProperties $dependency @(
        'id', 'proven', 'evidence_relative_path', 'evidence_sha256'
    ) `
        "dependency[$index]"
    Assert-JsonStringEquals $dependency.id $binding.Id `
        "dependency[$index].id"
    Assert-JsonStringEquals $dependency.evidence_relative_path $binding.RelativePath `
        "dependency[$index].evidence_relative_path"
    $proven = Assert-JsonBoolean $dependency.proven "dependency[$index].proven"
    if (-not $proven) {
        throw "Dependency '$($dependency.id)' must remain proven."
    }
    Assert-LowercaseSha256 $dependency.evidence_sha256 `
        "dependency[$index].evidence_sha256"

    $schemaContract = $schema.properties.dependencies.prefixItems[$index].allOf[1].properties
    Assert-JsonStringEquals $schemaContract.id.const $binding.Id `
        "schema dependency[$index].id"
    if (-not (Assert-JsonBoolean $schemaContract.proven.const `
            "schema dependency[$index].proven")) {
        throw "Schema dependency '$($dependency.id)' must remain proven."
    }
    Assert-JsonStringEquals $schemaContract.evidence_relative_path.const `
        $binding.RelativePath "schema dependency[$index].evidence_relative_path"
    Assert-LowercaseSha256 $schemaContract.evidence_sha256.const `
        "schema dependency[$index].evidence_sha256"
    if ($dependency.evidence_sha256 -cne $schemaContract.evidence_sha256.const) {
        throw "Dependency '$($dependency.id)' does not bind the canonical evidence digest."
    }

    $evidencePath = Join-Path (Split-Path -Parent $profilePath) `
        $dependency.evidence_relative_path
    if (-not $evidenceSnapshots.ContainsKey($dependency.evidence_relative_path)) {
        $evidenceSnapshots[$dependency.evidence_relative_path] = `
            Read-GswBoundedFileSnapshot -Path $evidencePath `
                -Name "dependency '$($dependency.id)' evidence" `
                -MaximumBytes $script:MaximumEvidenceJsonBytes
    }
    if ($evidenceSnapshots[$dependency.evidence_relative_path].Sha256 -cne
        $dependency.evidence_sha256) {
        throw "Dependency '$($dependency.id)' evidence digest mismatch."
    }
}

$componentClosurePath = $evidenceSnapshots[
    'component-closures/mesa9x-23.1.x.json'
].Path
$componentClosure = Read-GswStrictJsonFile -Path $componentClosurePath `
    -Name 'Mesa component closure evidence' `
    -MaximumBytes $script:MaximumEvidenceJsonBytes
if ($componentClosure.schema -ne 2 -or $componentClosure.status -cne 'ready' -or
    $componentClosure.reason -isnot [string] -or
    $componentClosure.reason.Length -ne 0 -or
    $componentClosure.files -isnot [Array] -or
    $componentClosure.files.Count -ne 1687 -or
    $componentClosure.license_evidence -isnot [Array] -or
    $componentClosure.license_evidence.Count -ne 1502) {
    throw 'Mesa component closure evidence is not the ready 1,687-file closure.'
}
$compilerDependencyFiles = @($componentClosure.files | Where-Object {
    $_.roles -is [Array] -and $_.roles -ccontains 'compiler-dependency'
})
if ($compilerDependencyFiles.Count -ne 652) {
    throw 'Mesa component closure evidence must bind 652 compiler-dependency files.'
}
$inlineEvidence = @($componentClosure.license_evidence | Where-Object {
    $_.kind -ceq 'inline'
})
$documentEvidence = @($componentClosure.license_evidence | Where-Object {
    $_.kind -ceq 'license-document'
})
if ($inlineEvidence.Count -ne 1499 -or $documentEvidence.Count -ne 3) {
    throw 'Mesa component closure evidence inventory changed.'
}

$directPlanPath = $evidenceSnapshots['mesa-gsw-direct-build-plan.json'].Path
$directPlan = Read-GswStrictJsonFile -Path $directPlanPath `
    -Name 'Mesa direct-build plan evidence' `
    -MaximumBytes $script:MaximumEvidenceJsonBytes
if ($directPlan.status -cne 'metadata-only' -or
    $directPlan.inventory.total_source_units -ne 874 -or
    $directPlan.inventory.direct_compile_units -ne 869 -or
    $directPlan.inventory.support_only_units -ne 5 -or
    $directPlan.object_collisions.final_identity_collision_count -ne 0 -or
    $directPlan.object_collisions.final_identity_collisions.Count -ne 0) {
    throw 'Mesa direct-build plan evidence changed.'
}
Assert-FalseJsonProperties $directPlan.scope.authorizations @(
    'production_build', 'link', 'stage', 'guest_install', 'dll_activation',
    'capability_advertisement'
) 'direct-build plan authorizations'

$compilerClosurePath = $evidenceSnapshots['mesa-compiler-closure.json'].Path
$compilerVerifier = Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1'
$compilerOutput = @(& $compilerVerifier -ClosureFile $compilerClosurePath)
if ($compilerOutput.Count -ne 1 -or
    $compilerOutput[0] -notlike '*authorizations=false.*') {
    throw 'Mesa compiler-closure evidence verification failed.'
}

$generatedOutputLockPath = $evidenceSnapshots[
    'generated-output-locks/mesa-23.1.9.json'
].Path
$generatedOutputLockSnapshot = Read-GswBoundedFileSnapshot `
    -Path $generatedOutputLockPath -Name 'Mesa generated-output lock evidence' `
    -MaximumBytes $script:MaximumEvidenceJsonBytes
if ($generatedOutputLockSnapshot.Sha256 -cne $dependencies[1].evidence_sha256) {
    throw 'Mesa generated-output lock evidence digest mismatch.'
}
$generatedOutputLock = Read-GswStrictJsonFile `
    -Path $generatedOutputLockPath -Name 'Mesa generated-output lock evidence' `
    -MaximumBytes $script:MaximumEvidenceJsonBytes
Assert-ExactProperties $generatedOutputLock @(
    '_spdx', 'schema', 'status', 'reason', 'component', 'provenance',
    'license_evidence', 'outputs', 'validation_only_side_outputs',
    'output_tree', 'scope'
) 'Mesa generated-output lock evidence'
Assert-JsonStringEquals $generatedOutputLock._spdx 'GPL-3.0-only' `
    'generated-output lock _spdx'
if ($null -eq $generatedOutputLock.schema -or
    @([byte], [uint16], [uint32], [uint64], [sbyte], [int16], [int32], [int64]) `
        -cnotcontains $generatedOutputLock.schema.GetType() -or
    [Int64]$generatedOutputLock.schema -ne 2) {
    throw 'Mesa generated-output lock evidence must use schema 2.'
}
Assert-JsonStringEquals $generatedOutputLock.status 'reviewed-generated-source' `
    'generated-output lock status'
if ($generatedOutputLock.reason -isnot [string] -or
    $generatedOutputLock.reason.Length -ne 0) {
    throw 'Mesa reviewed generated-output lock reason must be empty.'
}
if ($generatedOutputLock.license_evidence -isnot [Array] -or
    $generatedOutputLock.license_evidence.Count -ne 77 -or
    $generatedOutputLock.outputs -isnot [Array] -or
    $generatedOutputLock.outputs.Count -ne 67) {
    throw 'Mesa generated-output lock evidence has unexpected exact bounds.'
}
Assert-ExactProperties $generatedOutputLock.scope @(
    'classification', 'claims', 'authorizations'
) 'generated-output lock scope'
Assert-JsonStringEquals $generatedOutputLock.scope.classification `
    'reviewed-generated-source' 'generated-output lock classification'
Assert-ExactProperties $generatedOutputLock.scope.claims @(
    'generated_source_bytes_reviewed', 'output_reproducibility',
    'file_license_evidence_complete', 'generator_input_closure',
    'component_closure', 'build_closure'
) 'generated-output lock claims'
foreach ($claim in @(
    'generated_source_bytes_reviewed', 'output_reproducibility',
    'file_license_evidence_complete'
)) {
    if (-not (Assert-JsonBoolean $generatedOutputLock.scope.claims.$claim `
            "generated-output lock claim $claim")) {
        throw "Generated-output lock claim '$claim' must be proven."
    }
}
foreach ($claim in @(
    'generator_input_closure', 'component_closure', 'build_closure'
)) {
    if (Assert-JsonBoolean $generatedOutputLock.scope.claims.$claim `
            "generated-output lock claim $claim") {
        throw "Generated-output lock claim '$claim' must remain false."
    }
}
Assert-ExactProperties $generatedOutputLock.scope.authorizations @(
    'generator_execution', 'build', 'stage', 'guest_install',
    'capability_advertisement'
) 'generated-output lock authorizations'
foreach ($authorization in @(
    'generator_execution', 'build', 'stage', 'guest_install',
    'capability_advertisement'
)) {
    if (Assert-JsonBoolean $generatedOutputLock.scope.authorizations.$authorization `
            "generated-output lock authorization $authorization") {
        throw "Generated-output lock authorization '$authorization' must remain false."
    }
}

$reproducibilityEvidencePath = $evidenceSnapshots[
    'mesa-generated-source-reproducibility.json'
].Path
$reproducibilityEvidence = Read-GswBoundedFileSnapshot `
    -Path $reproducibilityEvidencePath `
    -Name 'Mesa generated-source reproducibility evidence' `
    -MaximumBytes $script:MaximumJsonBytes
if ($reproducibilityEvidence.Sha256 -cne $dependencies[2].evidence_sha256) {
    throw 'Mesa generated-source reproducibility evidence digest mismatch.'
}
$reproducibilityVerifier = Join-Path $PSScriptRoot `
    'verify-win98-mesa-generated-source-reproducibility.ps1'
$reproducibilityOutput = @(
    & $reproducibilityVerifier -EvidenceFile $reproducibilityEvidencePath
)
if ($reproducibilityOutput.Count -ne 1 -or
    $reproducibilityOutput[0] -notlike `
        '*as proven; roots=not-requested; authorizations=false.*') {
    throw 'Mesa generated-source reproducibility evidence verification failed.'
}

Write-Output (
    (
        "Verified Mesa GSW build profile '{0}' as {1}; compile-only=true, " +
        'production-build=false, link=false, staging=false, installation=false, ' +
        'activation=false, capabilities=false.'
    ) -f $profile.target.id, $profile.status
)

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
$script:ExpectedSchemaSha256 = 'bc3a10912a7b4c582e25b06b7d82ccea5fcf37c4bee8b2e383b16eda2a21e692'
$script:ExpectedGeneratedOutputLockSha256 = `
    '8274e5dd8cc50b41e4f0e510e87e9a2d669248bd69ae988e6dbdb48ce28390e5'
$script:ExpectedReproducibilityEvidenceSha256 = `
    'd37322e969730fb71d2663c19752728802631cb9bd55b3d294824e3ac4ca2f0b'
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
$script:DependencyIds = @(
    'mesa-file-license-closure',
    'mesa-generator-output-lock',
    'mesa-generated-source-reproducibility',
    'direct-pruned-build-recipe',
    'gsw-886-win98-i686-v1',
    'original-gsw-winsys',
    'original-gsw-memory-helpers',
    'backend-exclusion-proof',
    'compile-output-reproducibility'
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

function Assert-JsonIntegerOne {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value -or
        @([byte], [uint16], [uint32], [uint64], [sbyte], [int16], [int32], [int64]) `
            -cnotcontains $Value.GetType() -or [Int64]$Value -ne 1) {
        throw "$Name must be the JSON integer 1."
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

$profilePath = Get-FullPath $ProfileFile
$profile = Read-StrictJson $profilePath 'Mesa GSW build profile'
Assert-ExactProperties $profile @(
    '_spdx', 'schema', 'schema_definition', 'status', 'reason', 'source',
    'generation_strategy', 'target', 'allowed_families', 'required_support_families',
    'forbidden_features', 'dependencies'
) 'Mesa GSW build profile'
Assert-JsonStringEquals $profile._spdx 'GPL-3.0-only' '_spdx'
Assert-JsonIntegerOne $profile.schema 'schema'

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

Assert-JsonStringEquals $profile.status 'blocked' 'status'
$reason = Assert-JsonString $profile.reason 'reason'
if ([string]::IsNullOrWhiteSpace($reason)) {
    throw 'The blocked Mesa GSW build profile must explain the block.'
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
    'compile_only', 'build_authorized', 'staging_authorized',
    'guest_install_authorized', 'dll_activation_authorized', 'renderer_selection'
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
$stagingAuthorized = Assert-JsonBoolean `
    $profile.target.staging_authorized 'target.staging_authorized'
$guestInstallAuthorized = Assert-JsonBoolean `
    $profile.target.guest_install_authorized 'target.guest_install_authorized'
$dllActivationAuthorized = Assert-JsonBoolean `
    $profile.target.dll_activation_authorized 'target.dll_activation_authorized'
$rendererSelection = Assert-JsonBoolean `
    $profile.target.renderer_selection 'target.renderer_selection'
if (-not $compileOnly -or $buildAuthorized -or $stagingAuthorized -or
    $guestInstallAuthorized -or
    $dllActivationAuthorized -or $rendererSelection) {
    throw 'The Mesa GSW target must remain compile-only and non-activating.'
}

Assert-ExactStringSequence $profile.allowed_families $script:AllowedFamilies `
    'allowed_families'
Assert-ExactStringSequence $profile.required_support_families `
    @('gallium-auxiliary') 'required_support_families'
Assert-ExactStringSequence $profile.forbidden_features $script:ForbiddenFeatures `
    'forbidden_features'

$dependencies = Assert-JsonArray $profile.dependencies $script:DependencyIds.Count `
    'dependencies'
for ($index = 0; $index -lt $script:DependencyIds.Count; $index++) {
    $dependency = $dependencies[$index]
    Assert-ExactProperties $dependency @('id', 'proven', 'evidence_sha256') `
        "dependency[$index]"
    Assert-JsonStringEquals $dependency.id $script:DependencyIds[$index] `
        "dependency[$index].id"
    $proven = Assert-JsonBoolean $dependency.proven "dependency[$index].proven"
    $evidence = Assert-JsonString $dependency.evidence_sha256 `
        "dependency[$index].evidence_sha256" 64
    if ($index -eq 1) {
        if (-not $proven -or
            $evidence -cne $script:ExpectedGeneratedOutputLockSha256) {
            throw "Dependency '$($dependency.id)' must bind the canonical reviewed evidence."
        }
    }
    elseif ($index -eq 2) {
        if (-not $proven -or
            $evidence -cne $script:ExpectedReproducibilityEvidenceSha256) {
            throw "Dependency '$($dependency.id)' must bind the canonical proven evidence."
        }
    }
    elseif ($proven -or $evidence.Length -ne 0) {
        throw "Dependency '$($dependency.id)' must remain unproven with no evidence."
    }
}

$generatedOutputLockPath = Join-Path (Split-Path -Parent $profilePath) `
    'generated-output-locks\mesa-23.1.9.json'
$generatedOutputLockSnapshot = Read-GswBoundedFileSnapshot `
    -Path $generatedOutputLockPath -Name 'Mesa generated-output lock evidence' `
    -MaximumBytes $script:MaximumEvidenceJsonBytes
if ($generatedOutputLockSnapshot.Sha256 -cne
    $script:ExpectedGeneratedOutputLockSha256) {
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

$reproducibilityEvidencePath = Join-Path (Split-Path -Parent $profilePath) `
    'mesa-generated-source-reproducibility.json'
$reproducibilityEvidence = Read-GswBoundedFileSnapshot `
    -Path $reproducibilityEvidencePath `
    -Name 'Mesa generated-source reproducibility evidence' `
    -MaximumBytes $script:MaximumJsonBytes
if ($reproducibilityEvidence.Sha256 -cne
    $script:ExpectedReproducibilityEvidenceSha256) {
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
    "Verified Mesa GSW build profile '{0}' as {1}; build={2}, staging=false, activation=false." -f `
        $profile.target.id, $profile.status, $buildAuthorized.ToString().ToLowerInvariant()
)

# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$NameFilter,
    [switch]$DetailedFailures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:TestCount = 0
$script:NameFilter = [string]$NameFilter
$script:DetailedFailures = [bool]$DetailedFailures

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    if (-not [string]::IsNullOrWhiteSpace($script:NameFilter) -and
        $Name -notlike "*$($script:NameFilter)*") {
        return
    }
    $script:TestCount++
    try {
        & $Body
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
        if ($script:DetailedFailures) {
            Write-Output "  $($_.ScriptStackTrace)"
        }
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected
    )

    if ($Actual -cne $Expected) {
        throw "Expected '$Expected', observed '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [Parameter(Mandatory = $true)][string]$ExpectedText
    )

    try {
        & $Body | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedText*") {
            throw "Expected error containing '$ExpectedText', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error containing '$ExpectedText'."
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText(
        $Path,
        $json + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function Copy-JsonObject {
    param([Parameter(Mandatory = $true)][object]$Value)

    return ($Value | ConvertTo-Json -Depth 16) | ConvertFrom-Json
}

function Reset-Fixture {
    foreach ($name in @(
            'mesa-gsw-build-profile.schema.json',
            'component-closures/mesa9x-23.1.x.json',
            'generated-output-locks/mesa-23.1.9.json',
            'mesa-generated-source-reproducibility.json',
            'mesa-generated-source-reproducibility.schema.json',
            'mesa-generated-source-plan.json',
            'mesa-generated-source-plan.schema.json',
            'mesa-source-seed.json',
            'mesa-gsw-direct-build-plan.json',
            'mesa-compiler-closure.json',
            'mesa-compiler-closure.schema.json',
            'mesa-gsw/interface-inputs.lock.json',
            'mesa-gsw/winsys-interface-inputs.lock.json',
            'mesa-gsw/include/gdi/gdi_sw_winsys.h',
            'guest-cpu-profile.json',
            'mingw32-toolchain.lock.json'
        )) {
        $destination = Join-Path $testRoot $name
        $destinationDirectory = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:CanonicalMetadataDirectory $name) `
            -Destination $destination -Force
    }
    Write-JsonFile $script:FixtureProfilePath `
        (Copy-JsonObject $script:CanonicalProfile)
}

function Invoke-Verification {
    & $script:VerifyScript -ProfileFile $script:FixtureProfilePath
}

function Invoke-FixtureTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $fixtureBody = $Body
    Invoke-SelfTest $Name {
        Reset-Fixture
        & $fixtureBody
    }
}

function Invoke-MutationTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Mutation,
        [Parameter(Mandatory = $true)][string]$ExpectedText
    )

    Invoke-FixtureTest $Name {
        $profile = Copy-JsonObject $script:CanonicalProfile
        & $Mutation $profile
        Write-JsonFile $script:FixtureProfilePath $profile
        Assert-Throws { Invoke-Verification } $ExpectedText
    }
}

function Remove-TestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]'\/'
    )
    $expectedPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $fullPath
    if (-not $fullPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Parent $fullPath) -cne $temporaryRoot -or
        $leaf -cnotmatch '^retvrn99-mesa-build-profile-test-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected test root '$fullPath'."
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-build-profile-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $script:VerifyScript = Join-Path $PSScriptRoot 'verify-win98-mesa-build-profile.ps1'
    $script:CanonicalMetadataDirectory = Join-Path $PSScriptRoot '..\drivers\win98'
    $script:CanonicalProfilePath = Join-Path $script:CanonicalMetadataDirectory `
        'mesa-gsw-build-profile.json'
    $script:CanonicalSchemaPath = Join-Path $script:CanonicalMetadataDirectory `
        'mesa-gsw-build-profile.schema.json'
    $script:FixtureProfilePath = Join-Path $testRoot 'mesa-gsw-build-profile.json'
    $script:FixtureSchemaPath = Join-Path $testRoot `
        'mesa-gsw-build-profile.schema.json'
    $script:CanonicalProfile = Get-Content -Raw -LiteralPath `
        $script:CanonicalProfilePath | ConvertFrom-Json

    Invoke-SelfTest 'Canonical schema is bounded and rejects unknown root properties' {
        $schemaItem = Get-Item -LiteralPath $script:CanonicalSchemaPath
        if ($schemaItem.Length -gt 65536) {
            throw 'Canonical schema exceeds the verifier bound.'
        }
        $schema = Get-Content -Raw -LiteralPath $script:CanonicalSchemaPath | `
            ConvertFrom-Json
        Assert-Equal $schema._spdx 'GPL-3.0-only'
        Assert-Equal $schema.type 'object'
        Assert-Equal $schema.additionalProperties $false
        Assert-Equal $schema.properties.target.additionalProperties $false
        Assert-Equal $schema.properties.source.additionalProperties $false
        Assert-Equal $schema.'$defs'.dependency.additionalProperties $false
        Assert-Equal $schema.properties.schema.const 2
        Assert-Equal $schema.properties.status.const 'compile-proven'
        Assert-Equal $schema.properties.generation_strategy.const `
            'hash-locked-generated-outputs'
        Assert-Equal $schema.properties.target.properties.build_authorized.const $false
        Assert-Equal $schema.properties.target.properties.link_authorized.const $false
        Assert-Equal $schema.properties.target.properties.capability_advertisement.const `
            $false
        Assert-Equal $schema.'$defs'.dependency.properties.proven.type 'boolean'
        Assert-Equal $schema.'$defs'.dependency.properties.evidence_sha256.pattern `
            '^[0-9a-f]{64}$'
        Assert-Equal $schema.'$defs'.dependency.properties.evidence_relative_path.type `
            'string'
        foreach ($dependency in $schema.properties.dependencies.prefixItems) {
            Assert-Equal $dependency.allOf[1].properties.proven.const $true
        }
        Assert-Equal $schema.properties.dependencies.prefixItems[0].allOf[1].`
            properties.evidence_relative_path.const `
            'component-closures/mesa9x-23.1.x.json'
        Assert-Equal $schema.properties.dependencies.prefixItems[4].allOf[1].`
            properties.evidence_relative_path.const 'mesa-compiler-closure.json'
        Assert-Equal $schema.properties.dependencies.prefixItems[7].allOf[1].`
            properties.evidence_relative_path.const 'mesa-compiler-closure.json'
        Assert-Equal $schema.properties.dependencies.prefixItems[8].allOf[1].`
            properties.evidence_relative_path.const 'mesa-compiler-closure.json'
    }

    Invoke-SelfTest 'Compile-proven profile authorizes no production mutation' {
        $output = @(& $script:VerifyScript -ProfileFile $script:CanonicalProfilePath)
        Assert-Equal $output.Count 1
        if ($output[0] -notlike `
            '*as compile-proven; compile-only=true, production-build=false, link=false,*') {
            throw "Unexpected verifier output '$($output[0])'."
        }
        $profile = Get-Content -Raw -LiteralPath $script:CanonicalProfilePath | `
            ConvertFrom-Json
        Assert-Equal $profile.status 'compile-proven'
        Assert-Equal $profile.generation_strategy 'hash-locked-generated-outputs'
        Assert-Equal $profile.target.compile_only $true
        Assert-Equal $profile.target.build_authorized $false
        Assert-Equal $profile.target.link_authorized $false
        Assert-Equal $profile.target.staging_authorized $false
        Assert-Equal $profile.target.guest_install_authorized $false
        Assert-Equal $profile.target.dll_activation_authorized $false
        Assert-Equal $profile.target.renderer_selection $false
        Assert-Equal $profile.target.capability_advertisement $false
        foreach ($dependency in $profile.dependencies) {
            Assert-Equal $dependency.proven $true
            if ($dependency.evidence_relative_path -isnot [string] -or
                $dependency.evidence_relative_path.Length -eq 0 -or
                $dependency.evidence_sha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw "Dependency '$($dependency.id)' lacks exact evidence."
            }
        }
        if (@($profile.dependencies.id) -ccontains 'mesa-generator-toolchain-locks') {
            throw 'Production profile consumes the generator toolchain audit.'
        }
        Assert-Equal $profile.dependencies[4].id 'gsw-886-win98-i686-v1'
        Assert-Equal $profile.dependencies[4].evidence_relative_path `
            'mesa-compiler-closure.json'
        Assert-Equal $profile.dependencies[7].evidence_sha256 `
            $profile.dependencies[4].evidence_sha256
        Assert-Equal $profile.dependencies[8].evidence_sha256 `
            $profile.dependencies[4].evidence_sha256
    }

    Invoke-MutationTest 'Only compile-proven status is accepted' {
        param($profile)
        $profile.status = 'ready'
    } "status must be 'compile-proven'"

    Invoke-MutationTest 'Every dependency remains proven' {
        param($profile)
        $profile.dependencies[2].proven = $false
    } 'must remain proven'

    Invoke-MutationTest 'Dependency evidence paths are exact' {
        param($profile)
        $profile.dependencies[0].evidence_relative_path = `
            'component-closures/another.json'
    } 'evidence_relative_path must be'

    Invoke-MutationTest 'Dependency digests bind canonical evidence' {
        param($profile)
        $profile.dependencies[1].evidence_sha256 = '1' * 64
    } 'does not bind the canonical evidence digest'

    Invoke-FixtureTest 'Generated-output lock bytes cannot mutate after binding' {
        $path = Join-Path $testRoot 'generated-output-locks\mesa-23.1.9.json'
        [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Invoke-Verification } 'evidence digest mismatch'
    }

    Invoke-FixtureTest 'Reproducibility evidence bytes cannot mutate after binding' {
        $path = Join-Path $testRoot 'mesa-generated-source-reproducibility.json'
        [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Invoke-Verification } 'evidence digest mismatch'
    }

    Invoke-FixtureTest 'Component closure bytes cannot mutate after binding' {
        $path = Join-Path $testRoot 'component-closures\mesa9x-23.1.x.json'
        [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Invoke-Verification } 'evidence digest mismatch'
    }

    Invoke-FixtureTest 'Compiler closure bytes cannot mutate after binding' {
        $path = Join-Path $testRoot 'mesa-compiler-closure.json'
        [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Invoke-Verification } 'evidence digest mismatch'
    }

    Invoke-FixtureTest 'Direct-plan bytes cannot mutate after binding' {
        $path = Join-Path $testRoot 'mesa-gsw-direct-build-plan.json'
        [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Invoke-Verification } 'evidence digest mismatch'
    }

    foreach ($relativePath in @(
        'mesa-gsw/winsys-interface-inputs.lock.json',
        'mesa-gsw/interface-inputs.lock.json'
    )) {
        Invoke-FixtureTest "Source lock '$relativePath' cannot mutate after binding" {
            $path = Join-Path $testRoot $relativePath
            [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
            Assert-Throws { Invoke-Verification } 'evidence digest mismatch'
        }
    }

    Invoke-FixtureTest 'Reproducibility evidence cannot be cross-wired to another manifest' {
        Copy-Item -LiteralPath (Join-Path $testRoot 'mesa-generated-source-plan.json') `
            -Destination (Join-Path $testRoot `
                'mesa-generated-source-reproducibility.json') -Force
        Assert-Throws { Invoke-Verification } 'evidence digest mismatch'
    }

    Invoke-FixtureTest 'An authorization mutation cannot replace proven evidence' {
        $path = Join-Path $testRoot 'mesa-generated-source-reproducibility.json'
        $evidence = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $evidence.scope.authorizations.build = $true
        Write-JsonFile $path $evidence
        $profile = Copy-JsonObject $script:CanonicalProfile
        $profile.dependencies[2].evidence_sha256 = `
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-JsonFile $script:FixtureProfilePath $profile
        Assert-Throws { Invoke-Verification } 'does not bind the canonical evidence digest'
    }

    Invoke-MutationTest 'Unknown root properties fail closed' {
        param($profile)
        $profile | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    } 'Unexpected property'

    Invoke-MutationTest 'Unknown target properties fail closed' {
        param($profile)
        $profile.target | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    } 'Unexpected property'

    Invoke-MutationTest 'Unknown dependency properties fail closed' {
        param($profile)
        $profile.dependencies[0] | Add-Member `
            -NotePropertyName unexpected -NotePropertyValue $true
    } 'Unexpected property'

    Invoke-FixtureTest 'Case-folded duplicate root properties are rejected' {
        $json = [IO.File]::ReadAllText($script:FixtureProfilePath).Replace(
            '"status":  "compile-proven"',
            '"STATUS":  "compile-proven",' + "`n    " +
                '"status":  "compile-proven"'
        )
        if ($json -ceq [IO.File]::ReadAllText($script:FixtureProfilePath)) {
            $json = [IO.File]::ReadAllText($script:FixtureProfilePath).Replace(
                '"status": "compile-proven"',
                '"STATUS": "compile-proven",' + "`n  " +
                    '"status": "compile-proven"'
            )
        }
        [IO.File]::WriteAllText(
            $script:FixtureProfilePath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'Duplicate JSON property'
    }

    Invoke-FixtureTest 'Case-folded duplicate nested properties are rejected' {
        $json = [IO.File]::ReadAllText($script:FixtureProfilePath).Replace(
            '"kind":  "direct-pruned-compile-only"',
            '"KIND":  "direct-pruned-compile-only",' + "`n        " +
                '"kind":  "direct-pruned-compile-only"'
        )
        if ($json -ceq [IO.File]::ReadAllText($script:FixtureProfilePath)) {
            $json = [IO.File]::ReadAllText($script:FixtureProfilePath).Replace(
                '"kind": "direct-pruned-compile-only"',
                '"KIND": "direct-pruned-compile-only",' + "`n    " +
                    '"kind": "direct-pruned-compile-only"'
            )
        }
        [IO.File]::WriteAllText(
            $script:FixtureProfilePath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'Duplicate JSON property'
    }

    Invoke-FixtureTest 'Malformed profile JSON is rejected' {
        [IO.File]::WriteAllText(
            $script:FixtureProfilePath,
            '{',
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'Malformed Mesa GSW build profile JSON'
    }

    Invoke-FixtureTest 'Trailing JSON content is rejected' {
        [IO.File]::AppendAllText($script:FixtureProfilePath, '{}')
        Assert-Throws { Invoke-Verification } 'Unexpected trailing JSON content'
    }

    Invoke-FixtureTest 'Oversized profile JSON is rejected before parsing' {
        [IO.File]::AppendAllText($script:FixtureProfilePath, ' ' * 65536)
        Assert-Throws { Invoke-Verification } 'exceeds the 65536-byte bound'
    }

    Invoke-FixtureTest 'A mutated schema is rejected by its canonical digest' {
        [IO.File]::AppendAllText($script:FixtureSchemaPath, "`n")
        Assert-Throws { Invoke-Verification } 'schema content does not match'
    }

    Invoke-FixtureTest 'Duplicate schema properties are rejected before hashing' {
        $json = [IO.File]::ReadAllText($script:FixtureSchemaPath).Replace(
            '"title": "RETVRN99 Mesa GSW compile profile",',
            '"TITLE": "RETVRN99 Mesa GSW compile profile",' + "`n  " +
                '"title": "RETVRN99 Mesa GSW compile profile",'
        )
        [IO.File]::WriteAllText(
            $script:FixtureSchemaPath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'Duplicate JSON property'
    }

    Invoke-MutationTest 'The profile cannot select a different schema path' {
        param($profile)
        $profile.schema_definition.relative_path = '../profile.schema.json'
    } "must be 'mesa-gsw-build-profile.schema.json'"

    Invoke-MutationTest 'The profile cannot select a different schema digest' {
        param($profile)
        $profile.schema_definition.sha256 = '0' * 64
    } 'does not bind the canonical'

    Invoke-MutationTest 'Uppercase schema digests are rejected' {
        param($profile)
        $profile.schema_definition.sha256 = `
            $profile.schema_definition.sha256.ToUpperInvariant()
    } 'lowercase SHA-256'

    Invoke-MutationTest 'An array cannot impersonate a schema digest string' {
        param($profile)
        $profile.schema_definition.sha256 = @('0' * 64)
    } 'lowercase SHA-256'

    Invoke-MutationTest 'The SPDX marker is immutable' {
        param($profile)
        $profile._spdx = 'MIT'
    } "must be 'GPL-3.0-only'"

    Invoke-MutationTest 'The schema version must be an integer' {
        param($profile)
        $profile.schema = '2'
    } 'must be the JSON integer 2'

    Invoke-MutationTest 'Status must be a string' {
        param($profile)
        $profile.status = $true
    } 'must be a bounded JSON string'

    Invoke-MutationTest 'Reason must be a string' {
        param($profile)
        $profile.reason = $true
    } 'must be a bounded JSON string'

    Invoke-MutationTest 'The compile proof authority boundary cannot be whitespace' {
        param($profile)
        $profile.reason = '   '
    } 'must explain its authority boundary'

    Invoke-MutationTest 'The Mesa9x repository is immutable' {
        param($profile)
        $profile.source.repository = 'http://github.com/JHRobotics/mesa9x.git'
    } "source.repository must be"

    Invoke-MutationTest 'The Mesa9x owning commit is immutable' {
        param($profile)
        $profile.source.owning_commit = '0' * 40
    } "source.owning_commit must be"

    Invoke-MutationTest 'Alternate Mesa versions are rejected' {
        param($profile)
        $profile.source.mesa_version = '24.1.0'
    } "source.mesa_version must be '23.1.9'"

    Invoke-MutationTest 'Alternate Mesa generation subtrees are rejected' {
        param($profile)
        $profile.source.mesa_subtree = 'mesa-24.1.x'
    } "source.mesa_subtree must be 'mesa-23.1.x'"

    Invoke-MutationTest 'Only hash-locked generated outputs can feed the build' {
        param($profile)
        $profile.generation_strategy = 'run-pinned-generators'
    } "generation_strategy must be 'hash-locked-generated-outputs'"

    Invoke-MutationTest 'Only the direct pruned target kind is accepted' {
        param($profile)
        $profile.target.kind = 'multi-backend-package'
    } "target.kind must be 'direct-pruned-compile-only'"

    foreach ($guestOs in @('windows-95', 'windows-me')) {
        Invoke-MutationTest "The $guestOs payload target is rejected" {
            param($profile)
            $profile.target.guest_os = $guestOs
        } "target.guest_os must be 'windows-98-se'"
    }

    Invoke-MutationTest 'Non-i686 guest targets are rejected' {
        param($profile)
        $profile.target.architecture = 'x86_64'
    } "target.architecture must be 'i686'"

    Invoke-MutationTest 'SVGA9 cannot replace the internal SVGA10 command IR' {
        param($profile)
        $profile.target.command_ir = 'svga9'
    } "target.command_ir must be 'svga10-internal-only'"

    Invoke-MutationTest 'Softpipe cannot replace the single host renderer' {
        param($profile)
        $profile.target.host_renderer = 'softpipe'
    } "target.host_renderer must be 'sdl-gpu-vulkan-only'"

    Invoke-MutationTest 'A VMware winsys implementation is rejected' {
        param($profile)
        $profile.target.winsys_implementation = 'vmware-winsys'
    } "target.winsys_implementation must be 'retvrn99-original-gsw'"

    Invoke-MutationTest 'A VirtualBox memory helper implementation is rejected' {
        param($profile)
        $profile.target.memory_helper_implementation = 'virtualbox-memory-helpers'
    } "target.memory_helper_implementation must be 'retvrn99-original-gsw'"

    Invoke-MutationTest 'Final DLLs cannot become compile-profile artifacts' {
        param($profile)
        $profile.target.artifact_class = 'guest-dll-package'
    } "target.artifact_class must be 'non-package-compile-evidence'"

    Invoke-MutationTest 'The target cannot stop being compile-only' {
        param($profile)
        $profile.target.compile_only = $false
    } 'must remain compile-only and non-activating'

    Invoke-MutationTest 'The compile proof cannot authorize a production build' {
        param($profile)
        $profile.target.build_authorized = $true
    } 'must remain compile-only and non-activating'

    Invoke-MutationTest 'Build authorization must be a JSON boolean' {
        param($profile)
        $profile.target.build_authorized = 0
    } 'must be a JSON boolean'

    foreach ($field in @(
        'link_authorized',
        'staging_authorized',
        'guest_install_authorized',
        'dll_activation_authorized',
        'renderer_selection',
        'capability_advertisement'
    )) {
        Invoke-MutationTest "$field cannot be enabled by the compile profile" {
            param($profile)
            $profile.target.$field = $true
        } 'must remain compile-only and non-activating'
    }

    Invoke-MutationTest 'Allowed families cannot be supplied as an object' {
        param($profile)
        $profile.allowed_families = [pscustomobject]@{ family = 'mesa-core' }
    } 'must be a 5-item JSON array'

    Invoke-MutationTest 'Allowed family order is deterministic' {
        param($profile)
        $temporary = $profile.allowed_families[0]
        $profile.allowed_families[0] = $profile.allowed_families[1]
        $profile.allowed_families[1] = $temporary
    } 'canonical ordered values'

    Invoke-MutationTest 'An additional Mesa family is rejected' {
        param($profile)
        $profile.allowed_families = @($profile.allowed_families) + @('softpipe')
    } 'must be a 5-item JSON array'

    Invoke-MutationTest 'Gallium auxiliary support is mandatory' {
        param($profile)
        $profile.required_support_families = @()
    } 'must be a 1-item JSON array'

    Invoke-MutationTest 'Gallium auxiliary support cannot select another backend' {
        param($profile)
        $profile.required_support_families[0] = 'gallium-softpipe'
    } 'canonical ordered values'

    foreach ($feature in @(
        'softpipe',
        'llvmpipe',
        'llvm',
        'virgl',
        'zink',
        'd3d10',
        'osmesa',
        'qemu-3dfx',
        'bochs-3d',
        'vesa-3d',
        'vmware-winsys',
        'vmware-memory-helpers',
        'vmware-device-emulation',
        'vmware-branding',
        'virtualbox-winsys',
        'virtualbox-memory-helpers',
        'renderer-selection',
        'user-selectable-renderer',
        'softgpu-dependency',
        'softgpu-device-identity',
        'softgpu-installer',
        'softgpu-runtime',
        'svga9-production',
        'wine9x-runtime',
        'wined3d'
    )) {
        Invoke-MutationTest "Forbidden feature $feature cannot enter the allowlist" {
            param($profile)
            $profile.allowed_families[4] = $feature
        } 'canonical ordered values'
    }

    Invoke-MutationTest 'A forbidden feature cannot be omitted' {
        param($profile)
        $profile.forbidden_features = @($profile.forbidden_features[0..27])
    } 'must be a 29-item JSON array'

    Invoke-MutationTest 'Forbidden feature order is deterministic' {
        param($profile)
        $temporary = $profile.forbidden_features[0]
        $profile.forbidden_features[0] = $profile.forbidden_features[1]
        $profile.forbidden_features[1] = $temporary
    } 'canonical ordered values'

    Invoke-MutationTest 'Dependencies cannot be supplied as an object' {
        param($profile)
        $profile.dependencies = [pscustomobject]@{ id = 'mesa-file-license-closure' }
    } 'must be a 9-item JSON array'

    Invoke-MutationTest 'A dependency gate cannot be omitted' {
        param($profile)
        $profile.dependencies = @($profile.dependencies[0..7])
    } 'must be a 9-item JSON array'

    Invoke-MutationTest 'Dependency gate order is deterministic' {
        param($profile)
        $temporary = $profile.dependencies[0]
        $profile.dependencies[0] = $profile.dependencies[1]
        $profile.dependencies[1] = $temporary
    } "must be 'mesa-file-license-closure'"

    Invoke-MutationTest 'Unknown dependency gates are rejected' {
        param($profile)
        $profile.dependencies[0].id = 'renderer-choice'
    } "must be 'mesa-file-license-closure'"

    Invoke-MutationTest 'Generator toolchain audit cannot authorize production' {
        param($profile)
        $profile.dependencies[2].id = 'mesa-generator-toolchain-locks'
    } "must be 'mesa-generated-source-reproducibility'"

    Invoke-MutationTest 'Dependency proof state must be a JSON boolean' {
        param($profile)
        $profile.dependencies[0].proven = 'false'
    } 'must be a JSON boolean'

    Invoke-MutationTest 'Uppercase evidence digests are rejected' {
        param($profile)
        $profile.dependencies[1].evidence_sha256 = `
            $profile.dependencies[1].evidence_sha256.ToUpperInvariant()
    } 'lowercase SHA-256'

    Invoke-MutationTest 'Evidence paths cannot be empty' {
        param($profile)
        $profile.dependencies[0].evidence_relative_path = ''
    } 'evidence_relative_path must be'

    Invoke-MutationTest 'A dependency cannot omit its evidence path' {
        param($profile)
        $profile.dependencies[0].PSObject.Properties.Remove('evidence_relative_path')
    } "Missing property 'evidence_relative_path'"

    Invoke-MutationTest 'CPU proof cannot be cross-wired to the winsys lock' {
        param($profile)
        $profile.dependencies[4].evidence_relative_path = `
            'mesa-gsw/winsys-interface-inputs.lock.json'
        $profile.dependencies[4].evidence_sha256 = `
            $profile.dependencies[5].evidence_sha256
    } 'evidence_relative_path must be'
}
finally {
    Remove-TestRoot $testRoot
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:TestCount) Mesa GSW build-profile tests failed."
}
Write-Output "All $($script:TestCount) Windows 98 Mesa GSW build-profile tests passed."

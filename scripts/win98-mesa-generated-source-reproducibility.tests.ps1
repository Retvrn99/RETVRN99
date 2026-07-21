# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$LfGeneratedRoot,
    [string]$CrlfGeneratedRoot,
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

    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText(
        $Path,
        $json + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function Copy-JsonObject {
    param([Parameter(Mandatory = $true)][object]$Value)

    return ($Value | ConvertTo-Json -Depth 20) | ConvertFrom-Json
}

function Reset-Fixture {
    foreach ($name in @(
            'mesa-generated-source-reproducibility.schema.json',
            'mesa-generated-source-plan.json',
            'mesa-generated-source-plan.schema.json',
            'mesa-source-seed.json'
        )) {
        Copy-Item -LiteralPath (Join-Path $script:CanonicalMetadataDirectory $name) `
            -Destination (Join-Path $script:FixtureDirectory $name) -Force
    }
    Write-JsonFile $script:FixtureEvidencePath `
        (Copy-JsonObject $script:CanonicalEvidence)
}

function Invoke-Verification {
    & $script:VerifyScript -EvidenceFile $script:FixtureEvidencePath
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
        $evidence = Copy-JsonObject $script:CanonicalEvidence
        & $Mutation $evidence
        Write-JsonFile $script:FixtureEvidencePath $evidence
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
    if (-not $fullPath.StartsWith(
            $expectedPrefix, [StringComparison]::OrdinalIgnoreCase
        ) -or
        (Split-Path -Parent $fullPath) -cne $temporaryRoot -or
        $leaf -cnotmatch '^retvrn99-mesa-generated-repro-test-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected test root '$fullPath'."
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-generated-repro-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $script:VerifyScript = Join-Path $PSScriptRoot `
        'verify-win98-mesa-generated-source-reproducibility.ps1'
    $script:CanonicalMetadataDirectory = Join-Path $PSScriptRoot '..\drivers\win98'
    $script:CanonicalEvidencePath = Join-Path $script:CanonicalMetadataDirectory `
        'mesa-generated-source-reproducibility.json'
    $script:CanonicalSchemaPath = Join-Path $script:CanonicalMetadataDirectory `
        'mesa-generated-source-reproducibility.schema.json'
    $script:CanonicalEvidence = Get-Content -Raw -LiteralPath `
        $script:CanonicalEvidencePath | ConvertFrom-Json
    $script:FixtureDirectory = Join-Path $testRoot 'fixture'
    New-Item -ItemType Directory -Path $script:FixtureDirectory | Out-Null
    $script:FixtureEvidencePath = Join-Path $script:FixtureDirectory `
        'mesa-generated-source-reproducibility.json'

    Invoke-SelfTest 'Canonical evidence schema is bounded and fail closed' {
        $schemaItem = Get-Item -LiteralPath $script:CanonicalSchemaPath
        if ($schemaItem.Length -gt 1048576) {
            throw 'Canonical evidence schema exceeds its byte bound.'
        }
        $schema = Get-Content -Raw -LiteralPath $script:CanonicalSchemaPath | `
            ConvertFrom-Json
        Assert-Equal $schema._spdx 'GPL-3.0-only'
        Assert-Equal $schema.type 'object'
        Assert-Equal $schema.additionalProperties $false
        Assert-Equal $schema.properties.status.const 'proven'
        Assert-Equal $schema.properties.scope.properties.authorizations.`
            properties.build.const $false
        Assert-Equal $schema.properties.scope.properties.claims.properties.`
            normalized_output_reproducibility.const $true
        Assert-Equal $schema.'$defs'.tree_descriptor.properties.file_count.const 67
        Assert-Equal $schema.'$defs'.tree_descriptor.properties.aggregate_bytes.const `
            34876554
    }

    Invoke-SelfTest 'Production evidence is path independent and grants no authority' {
        $text = Get-Content -Raw -LiteralPath $script:CanonicalEvidencePath
        if ($text.IndexOf('.scratch', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $text -match '(?m)"[A-Za-z]:[\\/]' -or
            $text -match '(?m)"\\\\') {
            throw 'Production evidence contains an absolute generated-root path.'
        }
        $output = @(& $script:VerifyScript `
            -EvidenceFile $script:CanonicalEvidencePath)
        Assert-Equal $output.Count 1
        if ($output[0] -notlike '*roots=not-requested; authorizations=false.*') {
            throw "Unexpected verifier output '$($output[0])'."
        }
        foreach ($authorization in $script:CanonicalEvidence.scope.authorizations.`
                PSObject.Properties) {
            Assert-Equal $authorization.Value $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LfGeneratedRoot) -and
        -not [string]::IsNullOrWhiteSpace($CrlfGeneratedRoot)) {
        Invoke-SelfTest 'Two independent production roots reproduce exactly' {
            $output = @(& $script:VerifyScript `
                -EvidenceFile $script:CanonicalEvidencePath `
                -LfGeneratedRoot $LfGeneratedRoot `
                -CrlfGeneratedRoot $CrlfGeneratedRoot)
            Assert-Equal $output.Count 1
            if ($output[0] -notlike `
                '*roots=verified-distinct-byte-identical; authorizations=false.*') {
                throw "Unexpected root verifier output '$($output[0])'."
            }
        }
    }

    Invoke-FixtureTest 'LF and CRLF roots must be supplied as a pair' {
        Assert-Throws {
            & $script:VerifyScript -EvidenceFile $script:FixtureEvidencePath `
                -LfGeneratedRoot $script:FixtureDirectory
        } 'must be supplied together'
    }

    Invoke-FixtureTest 'LF and CRLF roots must be different directories' {
        $root = Join-Path $testRoot 'same-root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Assert-Throws {
            & $script:VerifyScript -EvidenceFile $script:FixtureEvidencePath `
                -LfGeneratedRoot $root -CrlfGeneratedRoot $root
        } 'must be distinct'
    }

    Invoke-FixtureTest 'LF and CRLF roots must not be nested' {
        $outer = Join-Path $testRoot 'outer-root'
        $inner = Join-Path $outer 'inner-root'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        Assert-Throws {
            & $script:VerifyScript -EvidenceFile $script:FixtureEvidencePath `
                -LfGeneratedRoot $outer -CrlfGeneratedRoot $inner
        } 'must not be nested'
    }

    Invoke-FixtureTest 'Mutated generated roots fail before any claim is emitted' {
        $lf = Join-Path $testRoot 'mutated-lf'
        $crlf = Join-Path $testRoot 'mutated-crlf'
        New-Item -ItemType Directory -Path $lf,$crlf -Force | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $lf 'unexpected.c'),
            "x`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            (Join-Path $crlf 'unexpected.c'),
            "x`n",
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws {
            & $script:VerifyScript -EvidenceFile $script:FixtureEvidencePath `
                -LfGeneratedRoot $lf -CrlfGeneratedRoot $crlf
        } 'entry counts do not match'
    }

    Invoke-MutationTest 'Unknown evidence fields fail closed' {
        param($evidence)
        $evidence | Add-Member -NotePropertyName output_root `
            -NotePropertyValue 'D:\scratch\generated'
    } 'fields do not match'

    Invoke-MutationTest 'Evidence status cannot overstate another state' {
        param($evidence)
        $evidence.status = 'ready'
    } "status must be 'proven'"

    Invoke-MutationTest 'LF and CRLF source modes cannot be cross-wired' {
        param($evidence)
        $evidence.runs[0].source_mode = 'crlf'
        $evidence.runs[0].core_autocrlf = $true
    } "source_mode must be 'lf'"

    Invoke-MutationTest 'Run binding digests cannot be cross-wired' {
        param($evidence)
        $temporary = $evidence.runs[0].run_binding_sha256
        $evidence.runs[0].run_binding_sha256 = $evidence.runs[1].run_binding_sha256
        $evidence.runs[1].run_binding_sha256 = $temporary
    } 'run_binding_sha256 must be'

    Invoke-MutationTest 'Pinned plan identity cannot be cross-wired' {
        param($evidence)
        $evidence.inputs.generated_source_plan.sha256 = '1' * 64
    } 'inputs.generated_source_plan.sha256'

    Invoke-MutationTest 'Pinned recipe identity cannot be cross-wired' {
        param($evidence)
        $evidence.inputs.generator_recipe.git_blob = '1' * 40
    } 'inputs.generator_recipe.git_blob'

    Invoke-MutationTest 'Pinned source seed identity cannot be cross-wired' {
        param($evidence)
        $evidence.inputs.source_seed.sha256 = '2' * 64
    } 'inputs.source_seed.sha256'

    Invoke-MutationTest 'Root descriptor mutations fail closed' {
        param($evidence)
        $evidence.runs[1].descriptor.aggregate_bytes++
    } 'descriptor.aggregate_bytes must be'

    Invoke-MutationTest 'Validation side outputs cannot enter a published root' {
        param($evidence)
        $evidence.runs[0].validation_side_output_count = 1
    } 'validation_side_output_count must be'

    Invoke-MutationTest 'Comparison cannot claim non-identical normalized outputs' {
        param($evidence)
        $evidence.comparison.normalized_outputs_byte_identical = $false
    } 'comparison.normalized_outputs_byte_identical'

    Invoke-MutationTest 'Scratch paths cannot enter evidence prose' {
        param($evidence)
        $evidence.reason = 'D:\dev\RETVRN99\.scratch\generated'
    } 'must not contain scratch-root paths'

    foreach ($authorizationName in @(
            'generator_execution', 'build', 'stage', 'guest_install',
            'dll_activation', 'capability_advertisement'
        )) {
        Invoke-MutationTest "Authorization '$authorizationName' remains false" {
            param($evidence)
            $evidence.scope.authorizations.$authorizationName = $true
        } "scope.authorizations.$authorizationName"
    }

    foreach ($claimName in @(
            'generator_execution', 'generator_trust', 'package_trust',
            'generated_output_lock', 'file_license_closure', 'build_closure'
        )) {
        Invoke-MutationTest "Unproven claim '$claimName' remains false" {
            param($evidence)
            $evidence.scope.claims.$claimName = $true
        } "scope.claims.$claimName"
    }

    Invoke-FixtureTest 'A mutated evidence schema is rejected by digest' {
        $path = Join-Path $script:FixtureDirectory `
            'mesa-generated-source-reproducibility.schema.json'
        [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Invoke-Verification } 'schema digest mismatch'
    }

    Invoke-FixtureTest 'A mutated preparation plan is rejected by byte identity' {
        $path = Join-Path $script:FixtureDirectory 'mesa-generated-source-plan.json'
        [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Invoke-Verification } 'does not match its pinned byte identity'
    }

    Invoke-FixtureTest 'Duplicate JSON properties are rejected before verification' {
        $text = Get-Content -Raw -LiteralPath $script:FixtureEvidencePath
        $text = $text.Replace(
            '"status":  "proven",',
            '"status":  "proven",' + "`n    " + '"STATUS":  "proven",'
        )
        if ($text -ceq (Get-Content -Raw -LiteralPath $script:FixtureEvidencePath)) {
            $text = $text.Replace(
                '"status": "proven",',
                '"status": "proven",' + "`n  " + '"STATUS": "proven",'
            )
        }
        [IO.File]::WriteAllText(
            $script:FixtureEvidencePath,
            $text,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'Duplicate JSON property'
    }
}
finally {
    Remove-TestRoot $testRoot
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:TestCount) Mesa generated-source reproducibility tests failed."
}
Write-Output (
    "All $($script:TestCount) Windows 98 Mesa generated-source reproducibility tests passed."
)

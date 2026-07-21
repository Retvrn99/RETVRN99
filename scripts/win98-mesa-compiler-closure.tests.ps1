# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Verifier = Join-Path $PSScriptRoot `
    'verify-win98-mesa-compiler-closure.ps1'
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:CanonicalRoot = Join-Path $script:RepositoryRoot 'drivers\win98'
$script:CanonicalClosure = Join-Path $script:CanonicalRoot `
    'mesa-compiler-closure.json'
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('retvrn99-mesa-compiler-closure-tests-' + [Guid]::NewGuid().ToString('N'))
$script:FixtureRoot = Join-Path $script:TestRoot 'drivers\win98'
$script:FixtureClosure = Join-Path $script:FixtureRoot `
    'mesa-compiler-closure.json'
$script:TestCount = 0
$script:Failures = 0

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Copy-CanonicalFixture {
    if (Test-Path -LiteralPath $script:TestRoot) {
        [IO.Directory]::Delete($script:TestRoot, $true)
    }
    [void][IO.Directory]::CreateDirectory($script:FixtureRoot)
    foreach ($directory in @('component-closures', 'generated-output-locks', 'mesa-gsw')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:FixtureRoot $directory))
    }
    foreach ($path in @(
        'mesa-compiler-closure.json',
        'mesa-compiler-closure.schema.json',
        'mesa-generated-source-reproducibility.json',
        'guest-cpu-profile.json',
        'mingw32-toolchain.lock.json',
        'component-closures/mesa9x-23.1.x.json',
        'generated-output-locks/mesa-23.1.9.json',
        'mesa-gsw/interface-inputs.lock.json'
    )) {
        $source = Join-Path $script:CanonicalRoot $path
        $destination = Join-Path $script:FixtureRoot $path
        Copy-Item -LiteralPath $source -Destination $destination
    }
}

function Invoke-Verification {
    return @(& $script:Verifier -ClosureFile $script:FixtureClosure)
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$Expected
    )

    try {
        & $Action | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") {
            throw "Expected error containing '$Expected', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected error containing '$Expected', but verification succeeded."
}

function Invoke-Test {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    $script:TestCount += 1
    try {
        & $Action
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failures += 1
        Write-Output "FAIL: $Name - $($_.Exception.Message)"
    }
}

function Invoke-ClosureMutationTest {
    param(
        [string]$Name,
        [scriptblock]$Mutation,
        [string]$Expected
    )

    Invoke-Test $Name {
        Copy-CanonicalFixture
        $closure = Get-Content -Raw -LiteralPath $script:FixtureClosure | `
            ConvertFrom-Json
        & $Mutation $closure
        Write-JsonFile $script:FixtureClosure $closure
        Assert-Throws { Invoke-Verification } $Expected
    }
}

try {
    Invoke-Test 'Canonical closure is metadata-only and blocked' {
        Copy-CanonicalFixture
        $output = @(Invoke-Verification)
        if ($output.Count -ne 1 -or
            $output[0] -notlike '*0 compiler commands, 0 depfiles, 0 headers*') {
            throw "Unexpected verifier output '$($output -join ' ')'."
        }
    }

    Invoke-Test 'Schema v1 structurally forbids evidence and authority' {
        $schema = Get-Content -Raw -LiteralPath `
            (Join-Path $script:CanonicalRoot 'mesa-compiler-closure.schema.json') | `
            ConvertFrom-Json
        if ($schema.properties.status.const -cne 'blocked' -or
            $schema.properties.evidence.properties.depfiles.maxItems -ne 0 -or
            $schema.properties.evidence.properties.headers.maxItems -ne 0 -or
            $schema.properties.scope.properties.authorizations.properties.`
                compiler_execution.const -ne $false) {
            throw 'Schema 1 is not fail-closed.'
        }
    }

    Invoke-ClosureMutationTest 'Ready status is rejected' {
        param($closure)
        $closure.status = 'proven'
    } "closure.status must be 'blocked'"

    Invoke-ClosureMutationTest 'Input order cannot change' {
        param($closure)
        $temporary = $closure.inputs[0]
        $closure.inputs[0] = $closure.inputs[1]
        $closure.inputs[1] = $temporary
    } 'JSON integer 815285'

    Invoke-ClosureMutationTest 'A fabricated command cannot enter schema v1' {
        param($closure)
        $closure.evidence.compiler_commands = @([pscustomobject]@{ command = 'gcc' })
    } 'evidence.compiler_commands must remain empty'

    Invoke-ClosureMutationTest 'A fabricated depfile cannot enter schema v1' {
        param($closure)
        $closure.evidence.depfiles = @('unit.d')
    } 'evidence.depfiles must remain empty'

    Invoke-ClosureMutationTest 'A fabricated header cannot enter schema v1' {
        param($closure)
        $closure.evidence.headers = @('unreviewed.h')
    } 'evidence.headers must remain empty'

    Invoke-ClosureMutationTest 'Compiler execution cannot be authorized' {
        param($closure)
        $closure.scope.authorizations.compiler_execution = $true
    } 'scope.authorizations.compiler_execution must remain false'

    Invoke-ClosureMutationTest 'The clean checkout cannot become proof source' {
        param($closure)
        $closure.depfile_contract.proof_source_root = 'pinned-clean-checkout'
    } "depfile_contract.proof_source_root must be 'exact-materialized-component-closure'"

    Invoke-ClosureMutationTest 'Discovery cannot become authoritative' {
        param($closure)
        $closure.depfile_contract.discovery_source_root = 'pinned-clean-checkout'
    } "depfile_contract.discovery_source_root must be 'pinned-clean-checkout-non-authoritative'"

    Invoke-ClosureMutationTest 'Missing headers cannot be tolerated' {
        param($closure)
        $closure.depfile_contract.missing_header_mode = 'allow-MG'
    } "depfile_contract.missing_header_mode must be 'reject-no-MG'"

    Invoke-ClosureMutationTest 'The generator recipe cannot become a build input' {
        param($closure)
        $closure.exclusions.upstream_recipe_inputs[2] = 'allowed'
    } 'exclusions.upstream_recipe_inputs must contain the canonical ordered values'

    Invoke-ClosureMutationTest 'VMware winsys include leakage is rejected' {
        param($closure)
        $closure.exclusions.include_path_fragments[3] = 'allowed'
    } 'exclusions.include_path_fragments must contain the canonical ordered values'

    Invoke-ClosureMutationTest 'Softpipe define leakage is rejected' {
        param($closure)
        $closure.exclusions.define_names[0] = 'ALLOWED'
    } 'exclusions.define_names must contain the canonical ordered values'

    Invoke-ClosureMutationTest 'DRAW LLVM define leakage is rejected' {
        param($closure)
        $closure.exclusions.define_names[6] = 'ALLOWED'
    } 'exclusions.define_names must contain the canonical ordered values'

    Invoke-ClosureMutationTest 'VBOX define-prefix leakage is rejected' {
        param($closure)
        $closure.exclusions.define_prefixes[0] = 'ALLOWED_'
    } 'exclusions.define_prefixes must contain the canonical ordered values'

    Invoke-Test 'An unreviewed direct recipe cannot silently appear' {
        Copy-CanonicalFixture
        [IO.File]::WriteAllText(
            (Join-Path $script:FixtureRoot 'mesa-gsw-direct-compile-plan.json'),
            "{}`n",
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } `
            'requires the unreviewed direct recipe to remain absent'
    }

    Invoke-Test 'A generated-output mutation breaks the exact input binding' {
        Copy-CanonicalFixture
        $path = Join-Path $script:FixtureRoot `
            'generated-output-locks/mesa-23.1.9.json'
        $json = [IO.File]::ReadAllText($path).Replace(
            'reviewed-generated-source',
            'reviewed-generated-sourcf'
        )
        [IO.File]::WriteAllText(
            $path,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'digest does not match its canonical binding'
    }

    Invoke-Test 'A schema mutation breaks the canonical digest' {
        Copy-CanonicalFixture
        [IO.File]::AppendAllText(
            (Join-Path $script:FixtureRoot 'mesa-compiler-closure.schema.json'),
            "`n",
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } `
            'schema content does not match its canonical digest'
    }

    Invoke-Test 'Case-folded duplicate JSON properties are rejected' {
        Copy-CanonicalFixture
        $json = [IO.File]::ReadAllText($script:FixtureClosure).Replace(
            '"status": "blocked",',
            '"STATUS": "blocked",' + "`n  " + '"status": "blocked",'
        )
        [IO.File]::WriteAllText(
            $script:FixtureClosure,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'Duplicate JSON property'
    }
}
finally {
    if (Test-Path -LiteralPath $script:TestRoot) {
        [IO.Directory]::Delete($script:TestRoot, $true)
    }
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:TestCount) Mesa compiler closure tests failed."
}
Write-Output "All $($script:TestCount) Windows 98 Mesa compiler closure tests passed."

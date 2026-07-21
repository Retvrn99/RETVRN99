# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MesaCheckout = 'D:\src\retvrn99-win98\mesa9x',
    [string]$ToolchainRoot = 'D:\src\retvrn99-win98\toolchains',
    [string]$NameFilter,
    [switch]$SkipCompileIntegration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Tests = 0
$script:NameFilter = [string]$NameFilter
$script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ModuleRoot = Join-Path $script:Root 'drivers\win98\mesa-gsw'
$script:PlanPath = Join-Path $script:ModuleRoot 'compile-plan.json'
$script:SchemaPath = Join-Path $script:ModuleRoot 'compile-plan.schema.json'
$script:CpuProfilePath = Join-Path $script:Root 'drivers\win98\guest-cpu-profile.json'
$script:CpuVerifier = Join-Path $PSScriptRoot 'verify-win98-guest-cpu-profile.ps1'
$script:Builder = Join-Path $PSScriptRoot `
    'build-win98-mesa-gsw-original-source.ps1'
$requestedMesaCheckout = [IO.Path]::GetFullPath($MesaCheckout)
$requestedToolchainRoot = [IO.Path]::GetFullPath($ToolchainRoot)

. $script:Builder

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    if (-not [string]::IsNullOrWhiteSpace($script:NameFilter) -and
        $Name -notlike "*$($script:NameFilter)*") {
        return
    }
    $script:Tests++
    try {
        & $Body
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if (-not [regex]::IsMatch(
            $Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline
        )) {
        throw $Message
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$ExpectedText)
    try { & $Body }
    catch {
        if ($_.Exception.Message.IndexOf(
                $ExpectedText, [StringComparison]::OrdinalIgnoreCase
            ) -lt 0) {
            throw "Expected '$ExpectedText', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error containing '$ExpectedText'."
}

function Read-TestText {
    param([string]$Path)

    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    Assert-True ($bytes.Length -gt 0) "$Path is empty."
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)) "$Path has a UTF-8 BOM."
    Assert-True (-not ($bytes -contains 0)) "$Path contains NUL."
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    Assert-True (-not $text.Contains("`r")) "$Path is not LF-normalized."
    Assert-True ($text.EndsWith("`n", [StringComparison]::Ordinal)) `
        "$Path lacks a terminal newline."
    return $text
}

function Copy-TestValue {
    param([object]$Value)
    return ConvertFrom-GswStrictJson -Json ($Value | ConvertTo-Json -Depth 32) `
        -Source 'copied test value'
}

function Write-TestJson {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 32) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function New-TestFixture {
    $fixture = Join-Path $script:TestRoot ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixture)
    [IO.File]::Copy($script:PlanPath, (Join-Path $fixture 'compile-plan.json'))
    [IO.File]::Copy($script:SchemaPath, (Join-Path $fixture 'compile-plan.schema.json'))
    return $fixture
}

function New-CpuProfileFixture {
    $fixture = Join-Path $script:TestRoot ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixture)
    foreach ($name in @(
        'guest-cpu-profile.json', 'guest-cpu-profile.schema.json',
        'mingw32-toolchain.lock.json', 'toolchain.lock.json'
    )) {
        [IO.File]::Copy(
            (Join-Path $script:Root "drivers\win98\$name"),
            (Join-Path $fixture $name)
        )
    }
    return $fixture
}

function Assert-ExceptionCleanupShape {
    param([string]$Text)

    foreach ($pattern in @(
        '\$started = \$false',
        '\$started = \[bool\]\(Start-GswCompileSuppressedProcess \$process\)',
        'finally\s*\{\s*try\s*\{\s*if \(\$started\) \{ Stop-GswCompileProcessTree \$process \}',
        'finally\s*\{\s*\$process\.Dispose\(\)',
        'catch\s*\{\s*# Parent fallback below remains mandatory\.',
        'try \{ \$Process\.Kill\(\) \}',
        'WaitForExit\(5000\)'
    )) {
        if (-not [regex]::IsMatch($Text, $pattern)) {
            throw "Exception cleanup shape is missing '$pattern'."
        }
    }
}

function Remove-TestRoot {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]'\/'
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
            $tempRoot, [StringComparison]::OrdinalIgnoreCase
        ) -or (Split-Path -Leaf $fullPath) -notlike
            'retvrn99-mesa-gsw-original-build-tests-*') {
        throw "Refusing to remove unsafe test root '$fullPath'."
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-gsw-original-build-tests-' + [Guid]::NewGuid().ToString('N')
)
[void][IO.Directory]::CreateDirectory($script:TestRoot)

$planText = Read-TestText $script:PlanPath
$schemaText = Read-TestText $script:SchemaPath
$builderText = Read-TestText $script:Builder
$probeText = Read-TestText (Join-Path $script:ModuleRoot 'probes\compile_probe.c')
$readmeText = Read-TestText (Join-Path $script:ModuleRoot 'README.md')
$plan = ConvertFrom-GswStrictJson -Json $planText -Source 'production compile plan'
$schema = ConvertFrom-GswStrictJson -Json $schemaText -Source 'production compile schema'
$cpuProfileText = Read-TestText $script:CpuProfilePath
$cpuProfile = ConvertFrom-GswStrictJson -Json $cpuProfileText `
    -Source 'production guest CPU profile'
$profileText = Read-TestText (
    Join-Path $script:Root 'drivers\win98\mesa-gsw-build-profile.json'
)
$profile = ConvertFrom-GswStrictJson -Json $profileText `
    -Source 'production Mesa build profile'

try {
Invoke-SelfTest 'Compile proof files are normalized GPL-3.0-only sources' {
    Assert-True ($plan._spdx -ceq 'GPL-3.0-only' -and
        $schema._spdx -ceq 'GPL-3.0-only') `
        'Compile metadata SPDX policy changed.'
    Assert-Match $builderText '\A# SPDX-License-Identifier: GPL-3\.0-only\n' `
        'Build verifier lacks GPL-3.0-only SPDX.'
    Assert-Match $probeText '\A/\* SPDX-License-Identifier: GPL-3\.0-only \*/\n' `
        'Compile probe lacks GPL-3.0-only SPDX.'
    Assert-Match $readmeText '\A<!-- SPDX-License-Identifier: GPL-3\.0-only -->\n' `
        'README lacks GPL-3.0-only SPDX.'
}

Invoke-SelfTest 'Compile plan is closed and hash binds its schema' {
    Assert-GswCompilePlan $plan
    Assert-True ($schema.additionalProperties -eq $false) `
        'Compile schema root is not closed.'
    foreach ($name in @(
        'guest_cpu_profile', 'source_module', 'toolchain', 'compile',
        'normalization', 'claims'
    )) {
        Assert-True ($schema.properties.$name.additionalProperties -eq $false) `
            "Compile schema '$name' is not closed."
    }
    $schemaHash = (Get-FileHash -LiteralPath $script:SchemaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($schemaHash -ceq $plan.schema_definition.sha256) `
        'Compile plan does not bind the production schema digest.'
}

Invoke-SelfTest 'Compile inputs are exact and include identity and Nine headers' {
    foreach ($descriptor in $plan.source_module.inputs) {
        $path = Join-Path $script:ModuleRoot `
            ([string]$descriptor.relative_path).Replace('/', '\')
        $item = Get-Item -LiteralPath $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ([UInt64]$item.Length -eq [UInt64]$descriptor.bytes -and
            $hash -ceq $descriptor.sha256) `
            "Compile input '$($descriptor.relative_path)' drifted."
    }
    Assert-Match $probeText '^#include "git_sha1\.h"$' `
        'Compile probe omits the original identity header.'
    Assert-Match $probeText '^#include "nine_memory_helper\.h"$' `
        'Compile probe omits the original Nine header.'
    Assert-Match $probeText 'sizeof\(PACKAGE_VERSION\)' `
        'Compile probe does not consume the package identity.'
    Assert-Match $probeText 'sizeof\(MESA_GIT_SHA1\)' `
        'Compile probe does not consume the pinned source identity.'
}

Invoke-SelfTest 'Guest CPU contract is exact and self-checking' {
    $profileItem = Get-Item -LiteralPath $script:CpuProfilePath
    $profileHash = (Get-FileHash -LiteralPath $script:CpuProfilePath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ([UInt64]$profileItem.Length -eq
            [UInt64]$plan.guest_cpu_profile.profile.bytes -and
        $profileHash -ceq $plan.guest_cpu_profile.profile.sha256) `
        'Compile plan guest CPU profile descriptor drifted.'
    $policyEvidence = @(& $script:CpuVerifier `
        -ProfileFile $script:CpuProfilePath -PolicyAudit)
    Assert-True ($policyEvidence.Count -eq 1 -and
        [string]$policyEvidence[0] -like 'Policy-audited blocked guest CPU profile*') `
        'Canonical guest CPU profile policy audit failed.'
    Assert-GswCompileArray $plan.compile.prefix_flags `
        $script:GswCompileExpectedPrefixFlags 'test compile prefix flags'
    Assert-GswCompileArray $plan.compile.suffix_flags `
        $script:GswCompileExpectedSuffixFlags 'test compile suffix flags'
    Assert-True ($plan.compile.cpu_flags_source -ceq
        'guest_cpu_profile.toolchains.mingw.cpu_flags' -and
        $plan.guest_cpu_profile.cpu_flags_source -ceq
        $plan.compile.cpu_flags_source) `
        'Compile plan does not derive MinGW cpu_flags from the guest CPU Interface.'
    Assert-True ($null -eq $plan.compile.PSObject.Properties['base_flags']) `
        'Compile plan retains a shallow duplicate base_flags array.'
    $cpuFlags = @($cpuProfile.toolchains.mingw.cpu_flags)
    Assert-True ($cpuFlags.Count -gt 40) `
        'Canonical guest CPU profile lost its complete disable sequence.'
    foreach ($required in @('-march=i686', '-mmmx', '-msse', '-msse2', '-msse3')) {
        Assert-True ($cpuFlags -ccontains $required) `
            "Required flag '$required' is absent."
    }
    foreach ($disabled in @(
        '-mno-cx16', '-mno-ssse3', '-mno-sse4a', '-mno-avx512f',
        '-mno-fma', '-mno-bmi', '-mno-bmi2', '-mno-xsave',
        '-mno-movdir64b', '-mno-amx-tile'
    )) {
        Assert-True ($cpuFlags -ccontains $disabled) `
            "Canonical disabled flag '$disabled' is absent."
    }
    foreach ($macro in $plan.compile.required_macros + $plan.compile.forbidden_macros) {
        Assert-True ($probeText.Contains([string]$macro)) `
            "Compile probe does not guard '$macro'."
    }
}

Invoke-SelfTest 'Proof remains disconnected from build and delivery authority' {
    foreach ($claim in @(
        'dll_link_authorized', 'production_build_authorized',
        'build_profile_dependency_satisfied', 'staging_authorized',
        'guest_install_authorized', 'capability_advertisement_authorized'
    )) {
        Assert-True ($plan.claims.$claim -eq $false) `
            "Compile plan claim '$claim' became true."
    }
    Assert-True ($profile.status -ceq 'blocked') `
        'Mesa build profile is no longer blocked.'
    $dependency = @($profile.dependencies | Where-Object {
        $_.id -ceq 'compile-output-reproducibility'
    })
    Assert-True ($dependency.Count -eq 1 -and $dependency[0].proven -eq $false -and
        [string]::IsNullOrEmpty([string]$dependency[0].evidence_sha256)) `
        'Compile proof changed build-profile dependency truth.'
}

Invoke-SelfTest 'Compile surface excludes alternate graphics backends' {
    Assert-GswCompileArray $plan.forbidden_backend_tokens `
        $script:GswCompileExpectedForbiddenBackends 'test forbidden backends'
    foreach ($descriptor in $plan.source_module.inputs) {
        $text = Read-TestText (Join-Path $script:ModuleRoot `
            ([string]$descriptor.relative_path).Replace('/', '\'))
        foreach ($token in $plan.forbidden_backend_tokens) {
            Assert-True ($text.IndexOf(
                    [string]$token, [StringComparison]::OrdinalIgnoreCase
                ) -lt 0) `
                "Compile input references forbidden backend '$token'."
        }
    }
}

Invoke-SelfTest 'Verifier is temporary compile-only and fail-closed' {
    Assert-Match $builderText "'-fsyntax-only'" `
        'Verifier does not compile the Interface probe.'
    Assert-Match $builderText "'-c'.*temporary_output" `
        'Verifier does not use compile-only output.'
    Assert-Match $builderText 'Normalize-GswCompileObject' `
        'Verifier does not normalize COFF metadata.'
    Assert-Match $builderText 'architecture: i386' `
        'Verifier does not inspect the COFF architecture.'
    Assert-Match $builderText 'Remove-GswCompileTempRoot' `
        'Verifier does not clean private output roots.'
    Assert-Match $builderText 'process_timeout_seconds' `
        'Verifier does not enforce the fixed process timeout.'
    Assert-True (-not [regex]::IsMatch(
        $builderText, '(?i)\b(shared|dll|linker|ld\.exe)\b.*-o'
    )) 'Verifier contains an apparent link recipe.'
}

Invoke-SelfTest 'Windows child launch policy suppresses crash dialogs' {
    Assert-True ($script:GswCompileChildErrorMode -eq [UInt32]0x8003) `
        'Child error mode does not combine all three required flags.'
    foreach ($name in @(
        'GswSemFailCriticalErrors', 'GswSemNoGpFaultErrorBox',
        'GswSemNoOpenFileErrorBox'
    )) {
        Assert-Match $builderText ('\$script:' + $name) `
            "Verifier does not name required error-mode flag '$name'."
    }
    Assert-Match $builderText 'DefinePInvokeMethod\(' `
        'Verifier does not define SetErrorMode without an external compiler.'
    Assert-Match $builderText "'SetErrorMode'" `
        'Verifier does not bind the Windows error-mode API.'
    Assert-Match $builderText 'Start-GswCompileSuppressedProcess \$process' `
        'Compiler process does not start under the suppressed error mode.'
    Assert-True (-not $builderText.Contains('Add-Type')) `
        'Verifier may invoke an ambient C# compiler through Add-Type.'
}

Invoke-SelfTest 'Child launch policy fixes PATH timeout and tree cleanup' {
    Assert-Match $builderText '\$childPath = \$ToolBin \+ '';'' \+ \$systemDirectory' `
        'Compiler PATH is not built exclusively from toolchain bin and System32.'
    Assert-Match $builderText '\$process\.WaitForExit\(\$TimeoutSeconds \* 1000\)' `
        'Compiler process does not enforce its internal timeout.'
    Assert-Match $builderText '\$terminationSwitches = ''/T /F''' `
        'Timeout cleanup does not bind child-tree termination switches.'
    Assert-Match $builderText 'taskkill\.exe' `
        'Timeout cleanup does not use bounded Windows child-tree termination.'
    Assert-Match $builderText 'WaitForExit\(5000\)' `
        'Timeout cleanup does not bound the tree terminator.'
    Assert-ExceptionCleanupShape $builderText
}

Invoke-SelfTest 'Child launch policy mutations fail closed' {
    $toolBin = 'C:\pinned\bin'
    $pathValue = $toolBin + ';' + [Environment]::GetFolderPath('System')
    Assert-GswCompileProcessPolicy -ErrorMode ([UInt32]0x8003) `
        -PathValue $pathValue -ToolBin $toolBin -TimeoutSeconds 10 `
        -TerminationSwitches '/T /F'
    Assert-Throws {
        Assert-GswCompileProcessPolicy -ErrorMode ([UInt32]0x0001) `
            -PathValue $pathValue -ToolBin $toolBin -TimeoutSeconds 10 `
            -TerminationSwitches '/T /F'
    } 'error mode'
    Assert-Throws {
        Assert-GswCompileProcessPolicy -ErrorMode ([UInt32]0x8003) `
            -PathValue ($pathValue + ';C:\ambient') -ToolBin $toolBin `
            -TimeoutSeconds 10 -TerminationSwitches '/T /F'
    } 'PATH'
    Assert-Throws {
        Assert-GswCompileProcessPolicy -ErrorMode ([UInt32]0x8003) `
            -PathValue $pathValue -ToolBin $toolBin -TimeoutSeconds 60 `
            -TerminationSwitches '/T /F'
    } 'timeout'
    Assert-Throws {
        Assert-GswCompileProcessPolicy -ErrorMode ([UInt32]0x8003) `
            -PathValue $pathValue -ToolBin $toolBin -TimeoutSeconds 10 `
            -TerminationSwitches '/F'
    } 'child tree'
}

Invoke-SelfTest 'Exception cleanup mutations fail closed' {
    $withoutStartedGuard = $builderText.Replace(
        'if ($started) { Stop-GswCompileProcessTree $process }',
        'if ($false) { Stop-GswCompileProcessTree $process }'
    )
    Assert-Throws {
        Assert-ExceptionCleanupShape $withoutStartedGuard
    } 'Exception cleanup shape'
    $withoutParentFallback = $builderText.Replace(
        'try { $Process.Kill() }',
        'try { $null = $Process.Id }'
    )
    Assert-Throws {
        Assert-ExceptionCleanupShape $withoutParentFallback
    } 'Exception cleanup shape'
    $withoutKillerWait = $builderText.Replace('WaitForExit(5000)', 'WaitForExit(0)')
    Assert-Throws {
        Assert-ExceptionCleanupShape $withoutKillerWait
    } 'Exception cleanup shape'
}

Invoke-SelfTest 'Unknown plan properties fail closed' {
    $mutated = Copy-TestValue $plan
    $mutated | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    Assert-Throws { Assert-GswCompilePlan $mutated } 'fields do not match'
}

Invoke-SelfTest 'Duplicate plan properties fail strict parsing' {
    $mutated = $planText.Replace(
        '  "schema": 1,',
        "  `"Schema`": 1,`n  `"schema`": 1,"
    )
    Assert-Throws {
        ConvertFrom-GswStrictJson -Json $mutated -Source 'duplicate compile plan'
    } 'Duplicate JSON property'
}

Invoke-SelfTest 'CPU profile descriptor mutation fails closed' {
    $mutated = Copy-TestValue $plan
    $mutated.guest_cpu_profile.profile.sha256 = '0' * 64
    Assert-Throws { Assert-GswCompilePlan $mutated } `
        'guest_cpu_profile.profile.sha256'
    $mutated = Copy-TestValue $plan
    $mutated.compile.cpu_flags_source = 'compile.cpu_flags'
    Assert-Throws { Assert-GswCompilePlan $mutated } 'cpu_flags_source'
}

Invoke-SelfTest 'Canonical CPU flag drift fails policy audit' {
    $fixture = New-CpuProfileFixture
    try {
        $fixtureProfile = Join-Path $fixture 'guest-cpu-profile.json'
        $mutated = ConvertFrom-GswStrictJson `
            -Json (Read-TestText $fixtureProfile) -Source 'CPU flag fixture'
        $mutated.toolchains.mingw.cpu_flags[6] = '-mno-sse3'
        Write-TestJson $fixtureProfile $mutated
        Assert-Throws {
            & $script:CpuVerifier -ProfileFile $fixtureProfile -PolicyAudit
        } 'toolchains.mingw.cpu_flags'
    }
    finally {
        if (Test-Path -LiteralPath $fixture) {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        }
    }
}

Invoke-SelfTest 'Output descriptor mutation fails closed' {
    $mutated = Copy-TestValue $plan
    $mutated.normalization.normalized_output.sha256 = '0' * 64
    Assert-Throws { Assert-GswCompilePlan $mutated } `
        'normalized_output.sha256'
}

Invoke-SelfTest 'Tool identity mutation fails closed' {
    $mutated = Copy-TestValue $plan
    $mutated.toolchain.compiler.sha256 = '0' * 64
    Assert-Throws { Assert-GswCompilePlan $mutated } 'toolchain.compiler.sha256'
}

Invoke-SelfTest 'Authority mutation fails closed' {
    $mutated = Copy-TestValue $plan
    $mutated.claims.staging_authorized = $true
    Assert-Throws { Assert-GswCompilePlan $mutated } 'staging_authorized'
}

if (-not $SkipCompileIntegration) {
    Invoke-SelfTest 'Final metadata drift cancels and cleans the compile proof' {
        $fixture = New-TestFixture
        $fixturePlan = Join-Path $fixture 'compile-plan.json'
        $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) `
            -Directory -Filter 'retvrn99-mesa-gsw-compile-*' |
            ForEach-Object { $_.FullName })
        try {
            Assert-Throws {
                Invoke-GswMesaOriginalCompileProof `
                    -MesaCheckoutPath $requestedMesaCheckout `
                    -ToolchainRootPath $requestedToolchainRoot `
                    -PlanPath $fixturePlan `
                    -BeforeFinalCheck {
                        [IO.File]::AppendAllText(
                            $fixturePlan,
                            "`n",
                            [Text.UTF8Encoding]::new($false)
                        )
                    }
            } 'compile metadata changed'
            $after = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) `
                -Directory -Filter 'retvrn99-mesa-gsw-compile-*' |
                ForEach-Object { $_.FullName })
            $newRoots = @($after | Where-Object { $before -notcontains $_ })
            Assert-True ($newRoots.Count -eq 0) `
                'Final-drift rejection left a private compile root behind.'
        }
        finally {
            if (Test-Path -LiteralPath $fixture) {
                Remove-Item -LiteralPath $fixture -Recurse -Force
            }
        }
    }
}
}
finally {
    Remove-TestRoot $script:TestRoot
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Tests) original GSW build tests failed."
}
Write-Output "All $($script:Tests) original GSW build tests passed."

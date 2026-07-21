# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$NameFilter,
    [switch]$DetailedFailures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Executed = 0
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
    $script:Executed++
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
        if ($_.Exception.Message.IndexOf(
            $ExpectedText,
            [StringComparison]::Ordinal
        ) -lt 0) {
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
        $json + [char]10,
        [Text.UTF8Encoding]::new($false)
    )
}

function New-Profile {
    return (
        Get-Content -Raw -LiteralPath $script:ProductionProfile |
            ConvertFrom-Json |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json
    )
}

function Set-BlockedFixture {
    Copy-Item -LiteralPath $script:SchemaPath -Destination (
        Join-Path $script:FixtureRoot 'guest-cpu-profile.schema.json'
    ) -Force
    Copy-Item -LiteralPath (
        Join-Path $script:ProductionRoot 'mingw32-toolchain.lock.json'
    ) -Destination (
        Join-Path $script:FixtureRoot 'mingw32-toolchain.lock.json'
    ) -Force
    Copy-Item -LiteralPath (
        Join-Path $script:ProductionRoot 'toolchain.lock.json'
    ) -Destination (
        Join-Path $script:FixtureRoot 'toolchain.lock.json'
    ) -Force
    $profile = New-Profile
    Write-JsonFile $script:FixtureProfile $profile
    return $profile
}

function Invoke-FixtureVerifier {
    param(
        [switch]$PolicyAudit,
        [switch]$CandidateEvidenceAudit,
        [string]$EvidenceRoot
    )

    $arguments = @{ ProfileFile = $script:FixtureProfile }
    if ($PolicyAudit) { $arguments.PolicyAudit = $true }
    if ($CandidateEvidenceAudit) { $arguments.CandidateEvidenceAudit = $true }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $arguments.EvidenceRoot = $EvidenceRoot
    }
    & $script:Verifier @arguments
}

function Remove-TestJunction {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $expectedPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar +
        'retvrn99-win98-guest-cpu-profile-link-'
    if (-not $fullPath.StartsWith(
        $expectedPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to remove unexpected junction path: $fullPath"
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "Refusing to remove non-junction path: $fullPath"
    }
    [IO.Directory]::Delete($fullPath)
}

$script:Verifier = Join-Path $PSScriptRoot 'verify-win98-guest-cpu-profile.ps1'
$script:ProductionRoot = Join-Path $PSScriptRoot '..\drivers\win98'
$script:ProductionProfile = Join-Path $script:ProductionRoot 'guest-cpu-profile.json'
$script:SchemaPath = Join-Path $script:ProductionRoot 'guest-cpu-profile.schema.json'
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$script:FixtureRoot = Join-Path $temporaryRoot (
    'retvrn99-win98-guest-cpu-profile-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
$script:FixtureProfile = Join-Path $script:FixtureRoot 'profile.json'
$script:Junctions = [Collections.Generic.List[string]]::new()
New-Item -ItemType Directory -Path $script:FixtureRoot -Force | Out-Null

try {
    Invoke-SelfTest 'Production policy audit preserves a blocked proof' {
        $output = @(& $script:Verifier -ProfileFile $script:ProductionProfile -PolicyAudit)
        Assert-Equal $output.Count 1
        Assert-Equal ($output[0] -like 'Policy-audited blocked guest CPU profile*') $true
    }

    Invoke-SelfTest 'Production proof cannot verify as active' {
        Assert-Throws {
            & $script:Verifier -ProfileFile $script:ProductionProfile
        } 'Guest CPU proof is blocked'
    }

    Invoke-SelfTest 'CandidateEvidenceAudit is unavailable in schema v1' {
        Assert-Throws {
            & $script:Verifier -ProfileFile $script:ProductionProfile -CandidateEvidenceAudit
        } 'schema v1 has no candidate-evidence acceptance path'
    }

    Invoke-SelfTest 'Audit switches remain mutually exclusive' {
        Assert-Throws {
            & $script:Verifier -ProfileFile $script:ProductionProfile -PolicyAudit -CandidateEvidenceAudit
        } 'mutually exclusive'
    }

    Invoke-SelfTest 'Schema v1 is absent-only with no candidate definitions' {
        $schemaText = [IO.File]::ReadAllText($script:SchemaPath)
        $schema = $schemaText | ConvertFrom-Json
        Assert-Equal $schema.'$defs'.proof.properties.status.const 'blocked'
        Assert-Equal $schema.'$defs'.proof.properties.evidence_status.const 'absent'
        Assert-Equal $schema.'$defs'.proof.properties.compiler_feature_report.type 'null'
        Assert-Equal $schema.'$defs'.proof.properties.final_pe_outputs.maxItems 0
        Assert-Equal $schema.'$defs'.proof.properties.final_binary_objdump_evidence.maxItems 0
        Assert-Equal ($schemaText -match 'candidateCaptureContract|objdumpEvidence|evidencePin') $false
    }

    Invoke-SelfTest 'Later-schema capture requirements are immutable annotations' {
        $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
        $comment = [string]$schema.'$defs'.proof.'$comment'
        foreach ($required in @(
            'hash-pinned capture publisher',
            'pinned empty translation unit',
            'canonical compile/query arguments',
            'deterministic environment',
            '30000 ms timeout',
            'exit code zero',
            'raw stdout and stderr byte counts and SHA-256 digests',
            'authoritative final build inventory',
            'complete executable-section opcode classification'
        )) {
            if ($comment.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
                throw "Missing later-schema requirement '$required'."
            }
        }
    }

    Invoke-SelfTest 'Verifier invokes no compiler or disassembler tools' {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:Verifier,
            [ref]$tokens,
            [ref]$errors
        )
        Assert-Equal $errors.Count 0
        foreach ($command in @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true))) {
            $name = $command.GetCommandName()
            if ($name -in @('gcc', 'gcc.exe', 'objdump', 'objdump.exe')) {
                throw "Verifier invokes forbidden native tool '$name'."
            }
        }
        $source = [IO.File]::ReadAllText($script:Verifier)
        Assert-Equal (
            $source -match 'Assert-ObjdumpReport|Test-ForbiddenMnemonic|compiler feature report'
        ) $false
    }

    Invoke-SelfTest 'Schema locks persona CPUID and toolchains' {
        $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
        Assert-Equal $schema.properties.profile_id.const 'gsw-886-win98-i686-v1'
        Assert-Equal $schema.properties.cpuid.properties.policy.const 'unchanged'
        Assert-Equal $schema.properties.cpuid.properties.changes_allowed.const $false
        Assert-Equal $schema.'$defs'.mingw.properties.architecture.const 'i686'
        Assert-Equal $schema.'$defs'.openWatcom.properties.floating_point.const 'x87'
        Assert-Equal (
            $schema.'$defs'.mingw.properties.toolchain_lock.allOf[1].properties.relative_path.const
        ) 'mingw32-toolchain.lock.json'
        Assert-Equal (
            $schema.'$defs'.openWatcom.properties.toolchain_lock.allOf[1].properties.relative_path.const
        ) 'toolchain.lock.json'
    }

    Invoke-SelfTest 'Schema definition pin is immutable' {
        $profile = Set-BlockedFixture
        $profile.schema_definition.relative_path = 'other.schema.json'
        $profile.schema_definition.sha256 = ('0' * 64)
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'schema definition pin is immutable'
    }

    Invoke-SelfTest 'Schema definition bytes are verified' {
        [void](Set-BlockedFixture)
        [IO.File]::AppendAllText(
            (Join-Path $script:FixtureRoot 'guest-cpu-profile.schema.json'),
            ' ' + [char]10,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'schema definition SHA-256 mismatch'
    }

    Invoke-SelfTest 'Ready status is impossible' {
        $profile = Set-BlockedFixture
        $profile.proof.status = 'ready'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'schema v1 is blocked-only'
    }

    Invoke-SelfTest 'Candidate status is impossible under PolicyAudit' {
        $profile = Set-BlockedFixture
        $profile.proof.evidence_status = 'candidate'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'does not accept candidate evidence'
    }

    foreach ($mnemonic in @(
        'phminposuw', 'endbr32', 'xacquire', 'xrelease', 'ldtilecfg',
        'sttilecfg', 'xsusldtrk', 'xresldtrk', 'future_gsw886_opcode'
    )) {
        Invoke-SelfTest "Candidate instruction '$mnemonic' cannot enter schema v1" {
            $profile = Set-BlockedFixture
            $profile.proof.evidence_status = 'candidate'
            $profile.proof.compiler_feature_report = [ordered]@{
                relative_path = 'reports/features.json'
                bytes = 1
                sha256 = ('0' * 64)
            }
            $profile.proof.final_pe_outputs = @(
                [ordered]@{
                    relative_path = 'bin/candidate.dll'
                    bytes = 1
                    sha256 = ('0' * 64)
                }
            )
            $profile.proof.final_binary_objdump_evidence = @(
                [ordered]@{
                    instructions = @(
                        [ordered]@{
                            address = '0'
                            mnemonic = $mnemonic
                            operands = ''
                        }
                    )
                }
            )
            Write-JsonFile $script:FixtureProfile $profile
            Assert-Throws {
                Invoke-FixtureVerifier -CandidateEvidenceAudit
            } 'does not accept candidate evidence'
        }
    }

    Invoke-SelfTest 'Absent proof cannot carry artifacts' {
        $profile = Set-BlockedFixture
        $profile.proof.compiler_feature_report = [ordered]@{ relative_path = 'report.json' }
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'cannot carry proof artifacts'

        $profile = Set-BlockedFixture
        $profile.proof.final_pe_outputs = @([ordered]@{ relative_path = 'candidate.dll' })
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'cannot carry proof artifacts'
    }

    Invoke-SelfTest 'Schema v1 rejects an evidence root' {
        [void](Set-BlockedFixture)
        Assert-Throws {
            Invoke-FixtureVerifier -PolicyAudit -EvidenceRoot $script:FixtureRoot
        } 'does not accept an evidence root'
    }

    Invoke-SelfTest 'Root properties are exact' {
        $profile = Set-BlockedFixture
        $profile | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } "Unexpected property 'unexpected'"
    }

    Invoke-SelfTest 'Missing root properties fail closed' {
        $profile = Set-BlockedFixture
        $profile.PSObject.Properties.Remove('cpuid')
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } "Missing property 'cpuid'"
    }

    Invoke-SelfTest 'Schema and CPUID JSON types are exact' {
        $profile = Set-BlockedFixture
        $profile.schema = '1'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'must be a JSON integer'

        $profile = Set-BlockedFixture
        $profile.cpuid.changes_allowed = 'false'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'must be a JSON boolean'
    }

    Invoke-SelfTest 'CPUID and GSW-886 persona remain immutable' {
        $profile = Set-BlockedFixture
        $profile.cpuid.changes_allowed = $true
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'cannot alter CPUID'

        $profile = Set-BlockedFixture
        $profile.cpu_persona.name = 'other'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws {
            Invoke-FixtureVerifier -PolicyAudit
        } 'GSW-886 i686 guest CPU persona is immutable'
    }

    Invoke-SelfTest 'MinGW feature lists cannot be weakened' {
        $profile = Set-BlockedFixture
        $profile.toolchains.mingw.required_features = @('mmx', 'sse', 'sse2')
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'required_features must be exactly'

        $profile = Set-BlockedFixture
        $profile.toolchains.mingw.disabled_features = @('cx16', 'ssse3', 'sse4')
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'disabled_features must be exactly'
    }

    Invoke-SelfTest 'MinGW CPU flags cannot be weakened or extended' {
        $profile = Set-BlockedFixture
        $profile.toolchains.mingw.cpu_flags = @(
            $profile.toolchains.mingw.cpu_flags | Where-Object { $_ -cne '-mno-avx' }
        )
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'cpu_flags must be exactly'

        $profile = Set-BlockedFixture
        $profile.toolchains.mingw.cpu_flags = @(
            $profile.toolchains.mingw.cpu_flags
        ) + @('-mavx')
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'cpu_flags must be exactly'
    }

    Invoke-SelfTest 'MinGW compiler and objdump pins are exact' {
        $profile = Set-BlockedFixture
        $profile.toolchains.mingw.compiler.sha256 = ('a' * 64)
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws {
            Invoke-FixtureVerifier -PolicyAudit
        } 'pinned MinGW compiler identity is immutable'

        $profile = Set-BlockedFixture
        $profile.toolchains.mingw.objdump.relative_path = 'bin/other.exe'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws {
            Invoke-FixtureVerifier -PolicyAudit
        } 'pinned MinGW objdump identity is immutable'
    }

    Invoke-SelfTest 'MinGW lock cannot be laundered through a self-declared path' {
        $profile = Set-BlockedFixture
        Copy-Item -LiteralPath (
            Join-Path $script:FixtureRoot 'mingw32-toolchain.lock.json'
        ) -Destination (
            Join-Path $script:FixtureRoot 'other-mingw-lock.json'
        ) -Force
        $profile.toolchains.mingw.toolchain_lock.relative_path = 'other-mingw-lock.json'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws {
            Invoke-FixtureVerifier -PolicyAudit
        } 'pinned MinGW toolchain lock identity is immutable'
    }

    Invoke-SelfTest 'Open Watcom lock cannot be laundered through a self-declared path' {
        $profile = Set-BlockedFixture
        Copy-Item -LiteralPath (
            Join-Path $script:FixtureRoot 'toolchain.lock.json'
        ) -Destination (
            Join-Path $script:FixtureRoot 'other-watcom-lock.json'
        ) -Force
        $profile.toolchains.open_watcom.toolchain_lock.relative_path = 'other-watcom-lock.json'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws {
            Invoke-FixtureVerifier -PolicyAudit
        } 'pinned Open Watcom toolchain lock identity is immutable'
    }

    Invoke-SelfTest 'Toolchain lock paths and bytes fail closed' {
        $profile = Set-BlockedFixture
        $profile.toolchains.mingw.toolchain_lock.relative_path = '../mingw32-toolchain.lock.json'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws {
            Invoke-FixtureVerifier -PolicyAudit
        } 'Unsafe path component'

        [void](Set-BlockedFixture)
        [IO.File]::AppendAllText(
            (Join-Path $script:FixtureRoot 'toolchain.lock.json'),
            ' ' + [char]10,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'toolchain_lock SHA-256 mismatch'
    }

    Invoke-SelfTest 'Open Watcom processor and x87 contracts are immutable' {
        $profile = Set-BlockedFixture
        $profile.toolchains.open_watcom.processor_switch = '-5'
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws {
            Invoke-FixtureVerifier -PolicyAudit
        } 'declared -6 i686 and x87 subset'

        $profile = Set-BlockedFixture
        $profile.toolchains.open_watcom.cpu_flags = @('-6s', '-fpi87', '-fpi87em')
        Write-JsonFile $script:FixtureProfile $profile
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'cpu_flags must be exactly'
    }

    Invoke-SelfTest 'Duplicate JSON properties are rejected' {
        [void](Set-BlockedFixture)
        $json = [IO.File]::ReadAllText($script:FixtureProfile)
        $pattern = [regex]'"schema"\s*:\s*1\s*,'
        $mutated = $pattern.Replace($json, '"schema": 1,"Schema": 1,', 1)
        if ($mutated -ceq $json) {
            throw 'Unable to create duplicate-property fixture.'
        }
        [IO.File]::WriteAllText(
            $script:FixtureProfile,
            $mutated,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-FixtureVerifier -PolicyAudit } 'Duplicate JSON property'
    }

    Invoke-SelfTest 'Profile paths cannot cross a junction ancestor' {
        [void](Set-BlockedFixture)
        $junction = Join-Path $temporaryRoot (
            'retvrn99-win98-guest-cpu-profile-link-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        New-Item -ItemType Junction -Path $junction -Target $script:FixtureRoot | Out-Null
        $script:Junctions.Add($junction)
        Assert-Throws {
            & $script:Verifier -ProfileFile (Join-Path $junction 'profile.json') -PolicyAudit
        } 'cannot cross a reparse point'
        Remove-TestJunction $junction
        [void]$script:Junctions.Remove($junction)
    }

    Invoke-SelfTest 'Pinned reads reassert ancestry around the open handle' {
        $source = [IO.File]::ReadAllText($script:Verifier)
        $start = $source.IndexOf('function Read-BoundedFile {', [StringComparison]::Ordinal)
        $end = $source.IndexOf(
            'function Skip-GuestCpuJsonWhitespace {',
            [StringComparison]::Ordinal
        )
        if ($start -lt 0 -or $end -le $start) {
            throw 'Unable to locate Read-BoundedFile.'
        }
        $body = $source.Substring($start, $end - $start)
        $checks = [regex]::Matches(
            $body,
            'Assert-NoReparseAncestor\s+\$Path\s+\$Name'
        ).Count
        Assert-Equal ($checks -ge 3) $true
        Assert-Equal ($body -match '\[IO\.FileShare\]::Read') $true
    }
}
finally {
    foreach ($junction in @($script:Junctions)) {
        if (Test-Path -LiteralPath $junction) {
            $item = Get-Item -LiteralPath $junction -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Remove-TestJunction $junction
            }
        }
    }
    $fixturePath = [IO.Path]::GetFullPath($script:FixtureRoot)
    $expectedPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar +
        'retvrn99-win98-guest-cpu-profile-test-'
    if ($fixturePath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $fixturePath)) {
        Remove-Item -LiteralPath $fixturePath -Recurse -Force
    }
}

if ($script:Executed -eq 0) {
    throw "No guest CPU profile tests matched '$($script:NameFilter)'."
}
if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Executed) guest CPU profile tests failed."
}
Write-Output "All $($script:Executed) Windows 98 guest CPU profile tests passed."

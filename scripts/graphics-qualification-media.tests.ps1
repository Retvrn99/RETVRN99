# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'strict-json.ps1')

$verifier = Join-Path $PSScriptRoot 'verify-graphics-qualification-media.ps1'
$productionLock = Join-Path $PSScriptRoot '..\qualification\graphics\media.lock.json'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-graphics-media-' + [Guid]::NewGuid().ToString('N')
)
$mediaRoot = Join-Path $testRoot 'media'
$lockPath = Join-Path $testRoot 'media.lock.json'
$script:tests = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:tests += 1
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $script:tests += 1
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message Observed: $($_.Exception.Message)"
        }
        return
    }
    throw $Message
}

function Write-TestLock {
    param(
        [string]$Id = 'fixture-demo',
        [string]$RelativePath = 'fixture.bin',
        [long]$Bytes = 13,
        [string]$Sha256,
        [string]$SourceUrl = 'https://example.invalid/fixture.bin',
        [bool]$External = $true,
        [bool]$Redistribution = $false,
        [bool]$GuestGate = $true,
        [switch]$Duplicate
    )
    $entry = [ordered]@{
        id = $Id
        title = 'Fixture demo'
        relative_path = $RelativePath
        bytes = $Bytes
        sha256 = $Sha256
        source_url = $SourceUrl
    }
    $media = @($entry)
    if ($Duplicate) { $media += [ordered]@{} + $entry }
    $lock = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        policy = [ordered]@{
            payloads_are_external = $External
            redistribution_allowed = $Redistribution
            guest_install_requires_explicit_authorization = $GuestGate
        }
        media = $media
    }
    [IO.File]::WriteAllText(
        $lockPath,
        ($lock | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

function Write-DuplicatePropertyLock {
    param([long]$Bytes, [string]$Sha256)

    Write-TestLock -Bytes $Bytes -Sha256 $Sha256
    $json = Get-Content -Raw -LiteralPath $lockPath
    $mutated = $json -creplace '"payloads_are_external"\s*:\s*true\s*,', `
        '"payloads_are_external": true, "PAYLOADS_ARE_EXTERNAL": false,'
    if ($mutated -ceq $json) {
        throw 'The duplicate media property mutation did not apply.'
    }
    [IO.File]::WriteAllText($lockPath, $mutated, [Text.UTF8Encoding]::new($false))
}

function Write-WrongTypeLock {
    param([long]$Bytes, [string]$Sha256, [string]$Mutation)

    Write-TestLock -Bytes $Bytes -Sha256 $Sha256
    $json = Get-Content -Raw -LiteralPath $lockPath
    switch ($Mutation) {
        'policy' {
            $json = $json -creplace '"payloads_are_external"\s*:\s*true', `
                '"payloads_are_external": "true"'
        }
        'bytes' {
            $json = $json -creplace ('"bytes"\s*:\s*' + $Bytes), `
                ('"bytes": "' + $Bytes + '"')
        }
        'title' {
            $json = $json -creplace '"title"\s*:\s*"Fixture demo"', `
                '"title": true'
        }
        default { throw "Unknown wrong-type mutation: $Mutation" }
    }
    [IO.File]::WriteAllText($lockPath, $json, [Text.UTF8Encoding]::new($false))
}

New-Item -ItemType Directory -Path $mediaRoot -Force | Out-Null
try {
    $payload = [Text.Encoding]::UTF8.GetBytes('qualification')
    $payloadPath = Join-Path $mediaRoot 'fixture.bin'
    [IO.File]::WriteAllBytes($payloadPath, $payload)
    $sha256 = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()

    Write-TestLock -Bytes $payload.Length -Sha256 $sha256
    $success = @(& $verifier -MediaRoot $mediaRoot -LockFile $lockPath -RequireAll)
    Assert-True ($success -contains 'PASS graphics qualification media verified=1 missing=0 locked=1') `
        'A hash-locked external media payload should verify.'
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath -RequireAll `
            -LockSnapshot ([pscustomobject]@{})
    } 'LockSnapshot' `
        'The standalone media verifier must not accept a caller-supplied snapshot.'

    $replacementPayload = Join-Path $mediaRoot 'replacement.bin'
    [IO.File]::WriteAllBytes(
        $replacementPayload,
        [Text.Encoding]::UTF8.GetBytes('QUALIFICATION')
    )
    Assert-Throws {
        Read-GswBoundedFileSnapshot -Path $payloadPath `
            -Name 'Mutable graphics qualification payload' `
            -MaximumBytes ([UInt64]$payload.Length) `
            -BeforePostReadCheck {
                param($openedPath)
                Move-Item -LiteralPath $replacementPayload -Destination $openedPath -Force
            }
    } 'changed during its bounded read' `
        'A payload replacement during its stability window must fail closed.'
    [IO.File]::WriteAllBytes($payloadPath, $payload)

    $reparseTarget = Join-Path $testRoot 'reparse-media-target'
    $reparseRoot = Join-Path $testRoot 'reparse-media-root'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $reparseTarget 'fixture.bin'), $payload)
    $reparseCreated = $false
    try {
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            New-Item -ItemType Junction -Path $reparseRoot -Target $reparseTarget |
                Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $reparseRoot -Target $reparseTarget |
                Out-Null
        }
        $reparseCreated = $true
    } catch {
        $reparseCreated = $false
    }
    if ($reparseCreated) {
        Assert-Throws {
            & $verifier -MediaRoot $reparseRoot -LockFile $lockPath -RequireAll
        } 'reparse point' 'A payload reached through a reparse point must fail closed.'
    }

    [IO.File]::WriteAllBytes($lockPath, [byte[]]::new(1048577))
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath -RequireAll
    } 'exceeds the 1048576-byte bound' `
        'An oversized media lock must fail before JSON parsing.'

    Write-TestLock -Bytes $payload.Length -Sha256 ('0' * 64)
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath -RequireAll
    } 'SHA-256 does not match' 'A payload hash mutation must fail closed.'

    Write-TestLock -RelativePath 'missing.bin' -Bytes $payload.Length -Sha256 $sha256
    $optional = @(& $verifier -MediaRoot $mediaRoot -LockFile $lockPath)
    Assert-True ($optional -contains 'PASS graphics qualification media verified=0 missing=1 locked=1') `
        'An optional cache check should report a missing payload without downloading it.'
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath -RequireAll
    } 'is missing' 'A required cache check must fail on missing media.'

    Write-TestLock -RelativePath '..\fixture.bin' -Bytes $payload.Length -Sha256 $sha256
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath
    } 'Invalid or duplicate.*path' 'A traversal path must fail before filesystem access.'

    Write-TestLock -Bytes $payload.Length -Sha256 $sha256 -Redistribution $true
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath
    } 'external-only and guest-gated' 'The no-redistribution policy must be immutable.'

    Write-TestLock -Bytes $payload.Length -Sha256 $sha256 -GuestGate $false
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath
    } 'external-only and guest-gated' 'The guest-install authorization gate must be immutable.'

    Write-WrongTypeLock -Bytes $payload.Length -Sha256 $sha256 -Mutation policy
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath
    } 'JSON Boolean' 'A string media policy value must fail closed.'

    Write-WrongTypeLock -Bytes $payload.Length -Sha256 $sha256 -Mutation bytes
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath
    } 'JSON integer' 'A string media byte count must fail closed.'

    Write-WrongTypeLock -Bytes $payload.Length -Sha256 $sha256 -Mutation title
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath
    } 'JSON string' 'A Boolean media title must fail closed.'

    Write-TestLock -Bytes $payload.Length -Sha256 $sha256 -Duplicate
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath
    } 'Invalid or duplicate.*id' 'Duplicate media identities must fail closed.'

    Write-DuplicatePropertyLock -Bytes $payload.Length -Sha256 $sha256
    Assert-Throws {
        & $verifier -MediaRoot $mediaRoot -LockFile $lockPath
    } 'Duplicate JSON property.*PAYLOADS_ARE_EXTERNAL' `
        'A nested case-insensitive duplicate media property must fail before conversion.'

    $production = @(& $verifier -MediaRoot (Join-Path $testRoot 'empty') -LockFile $productionLock)
    Assert-True ($production -contains 'PASS graphics qualification media verified=0 missing=11 locked=11') `
        'The production lock should satisfy the closed manifest policy.'

    $verifierText = Get-Content -Raw -LiteralPath $verifier
    Assert-True ($verifierText -match 'Read-GswBoundedFileSnapshot -Path \$path' -and
        $verifierText -notmatch 'Get-FileHash') `
        'Payload verification must use one bounded stable snapshot instead of split metadata and hash reads.'

    Write-Output "PASS graphics qualification media verifier ($script:tests assertions)."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

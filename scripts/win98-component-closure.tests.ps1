# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [string]$Pattern = ''
    )

    try {
        & $Body | Out-Null
    }
    catch {
        if ($Pattern.Length -ne 0 -and $_.Exception.Message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $($_.Exception.Message)"
        }
        return
    }
    throw 'Expected an exception.'
}

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures++
        [Console]::Error.WriteLine("FAIL $Name`: $($_.Exception.Message)")
    }
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-TrackedDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $line = Invoke-Git @('-C', $Checkout, 'ls-files', '--stage', '--', $RelativePath)
    if ($line -notmatch '^(?<mode>100644|100755) (?<hash>[0-9a-f]{40}) 0\t(?<path>.+)$' -or
        $Matches.path -cne $RelativePath) {
        throw "Missing test fixture path '$RelativePath'."
    }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Checkout (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return [pscustomobject]@{
        RelativePath = $RelativePath
        GitBlob = $Matches.hash
        Bytes = [UInt64]$bytes.Length
        Sha256 = ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
}

function New-NoticeRow {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [string]$Id = 'fixture-notice',
        [string]$LicenseExpression = 'MIT'
    )

    return [ordered]@{
        id = $Id
        relative_path = $Descriptor.RelativePath
        git_blob = $Descriptor.GitBlob
        bytes = $Descriptor.Bytes
        sha256 = $Descriptor.Sha256
        license_expression = $LicenseExpression
    }
}

function New-FileRow {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Role,
        [string]$SourcePrefixId = 'fixture-core',
        [string]$NoticeId = 'fixture-notice',
        [string]$LicenseExpression = 'MIT'
    )

    return [ordered]@{
        relative_path = $Descriptor.RelativePath
        git_blob = $Descriptor.GitBlob
        bytes = $Descriptor.Bytes
        sha256 = $Descriptor.Sha256
        license_expression = $LicenseExpression
        notice_id = $NoticeId
        source_prefix_id = $SourcePrefixId
        role = $Role
    }
}

function New-ReadyManifest {
    return [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        status = 'ready'
        reason = ''
        upstream_name = 'fixture'
        owning_commit = $script:Commit
        source_prefixes = @(
            [ordered]@{
                id = 'fixture-core'
                relative_path = 'component'
                mode = 'subtree'
            }
        )
        notices = @(
            (New-NoticeRow $script:LicenseDescriptor)
        )
        files = @(
            (New-FileRow $script:SourceDescriptor 'source')
        )
    }
}

function Write-TestLock {
    param(
        [string]$Disposition = 'planned-component',
        [string]$ManifestRelativePath = 'closures/fixture.json',
        [string]$ManifestHash
    )

    if (-not $PSBoundParameters.ContainsKey('ManifestHash')) {
        $ManifestHash = (Get-FileHash -LiteralPath $script:ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $contents = @(
        '# SPDX-License-Identifier: GPL-3.0-only'
        '# Source-provenance lock only. These rows do not identify shipped or install-ready payloads.'
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
        "fixture`tfixture`t$($script:Origin)`t$($script:Commit)`tMIT`t$Disposition`t$ManifestRelativePath`t$ManifestHash`tfixture-component"
    ) -join "`n"
    [IO.File]::WriteAllText(
        $script:LockPath,
        $contents + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function Set-ReadyFixture {
    $manifest = New-ReadyManifest
    Write-JsonFile $script:ManifestPath $manifest
    Write-TestLock
    return $manifest
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for the component closure tests.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99 win98-component-closure-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $script:VerifyScript = Join-Path $PSScriptRoot 'verify-win98-component-closure.ps1'
    $script:SourceVerifyScript = Join-Path $PSScriptRoot 'verify-win98-driver-sources.ps1'
    $script:SchemaPath = Join-Path $PSScriptRoot '..\drivers\win98\component-closure.schema.json'
    $script:SourceRoot = Join-Path $testRoot 'sources'
    $script:Checkout = Join-Path $script:SourceRoot 'fixture'
    $metadataRoot = Join-Path $testRoot 'metadata'
    $manifestRoot = Join-Path $metadataRoot 'closures'
    $script:ManifestPath = Join-Path $manifestRoot 'fixture.json'
    $script:LockPath = Join-Path $metadataRoot 'upstream.lock.tsv'
    $script:Origin = 'https://example.invalid/fixture.git'

    New-Item -ItemType Directory -Path (Join-Path $script:Checkout 'component') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Checkout 'common') -Force | Out-Null
    New-Item -ItemType Directory -Path $manifestRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'LICENSE'), "fixture license`n")
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\main.c'), "int main(void) { return 0; }`n")
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\include.h'), "#define FIXTURE 1`n")
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'common\shared.c'), "int shared;`n")
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'outside.c'), "int outside;`n")
    Invoke-Git @('init', '-q', $script:Checkout) | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'user.name', 'RETVRN99 Test') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'user.email', 'test@retvrn99.invalid') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'core.autocrlf', 'false') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'add', '.') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'commit', '-q', '-m', 'Pinned fixture') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'remote', 'add', 'origin', $script:Origin) | Out-Null
    $script:Commit = Invoke-Git @('-C', $script:Checkout, 'rev-parse', 'HEAD')
    $script:LicenseDescriptor = Get-TrackedDescriptor $script:Checkout 'LICENSE'
    $script:SourceDescriptor = Get-TrackedDescriptor $script:Checkout 'component/main.c'
    $script:HeaderDescriptor = Get-TrackedDescriptor $script:Checkout 'component/include.h'
    $script:CommonDescriptor = Get-TrackedDescriptor $script:Checkout 'common/shared.c'
    $script:OutsideDescriptor = Get-TrackedDescriptor $script:Checkout 'outside.c'

    Invoke-SelfTest 'The schema exposes the same closed license allowlist for notices and files' {
        $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
        $noticeLicenses = @(
            $schema.properties.notices.items.properties.license_expression.enum |
                Sort-Object -CaseSensitive
        ) -join ','
        $fileLicenses = @(
            $schema.properties.files.items.properties.license_expression.enum |
                Sort-Object -CaseSensitive
        ) -join ','
        Assert-Equal $noticeLicenses 'LGPL-2.1-or-later,MIT'
        Assert-Equal $fileLicenses $noticeLicenses
    }

    Invoke-SelfTest 'A ready file-level component closure verifies exact Git blobs' {
        [void](Set-ReadyFixture)
        $output = @(& $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath)
        Assert-Equal ($output -join [Environment]::NewLine) `
            'Verified 1 ready Windows 98 component source closures.'
    }

    Invoke-SelfTest 'Component verification rejects surplus upstream TSV fields' {
        [void](Set-ReadyFixture)
        $originalLock = [IO.File]::ReadAllText($script:LockPath)
        try {
            $lines = @([IO.File]::ReadAllLines($script:LockPath))
            $lines[3] += "`textra"
            [IO.File]::WriteAllLines($script:LockPath, $lines)
            Assert-Throws {
                & $script:VerifyScript -SourceRoot $script:SourceRoot `
                    -LockFile $script:LockPath
            } 'upstream lock data row 1 has 10 fields'
        }
        finally {
            [IO.File]::WriteAllText($script:LockPath, $originalLock)
        }
    }

    Invoke-SelfTest 'Exact-root mode admits only explicitly listed root files' {
        $manifest = New-ReadyManifest
        $manifest.source_prefixes = @([ordered]@{
            id = 'root-files'
            relative_path = '.'
            mode = 'exact-root-files'
        })
        $manifest.files = @(
            (New-FileRow $script:OutsideDescriptor 'source' 'root-files')
        )
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath | Out-Null
    }

    Invoke-SelfTest 'Multiple exact prefixes admit reviewed transitive files' {
        $manifest = New-ReadyManifest
        $manifest.source_prefixes += [ordered]@{
            id = 'fixture-common'
            relative_path = 'common'
            mode = 'subtree'
        }
        $manifest.files += New-FileRow $script:CommonDescriptor 'source' 'fixture-common'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath | Out-Null
    }

    Invoke-SelfTest 'A ready manifest cannot retain an unused source prefix' {
        $manifest = New-ReadyManifest
        $manifest.source_prefixes += [ordered]@{
            id = 'unused-common'
            relative_path = 'common'
            mode = 'subtree'
        }
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'unused notice or source prefix'
    }

    Invoke-SelfTest 'Blocked manifests fail closed outside explicit policy audit' {
        $manifest = New-ReadyManifest
        $manifest.status = 'blocked'
        $manifest.reason = 'The fixture closure is incomplete.'
        $manifest.notices = @()
        $manifest.files = @()
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'is blocked'
        $output = @(
            & $script:VerifyScript -SourceRoot $script:SourceRoot `
                -LockFile $script:LockPath -PolicyAudit
        )
        Assert-Equal ($output -join [Environment]::NewLine) `
            'Policy-audited 1 Windows 98 component closure manifests; 1 remain blocked and unusable.'
    }

    Invoke-SelfTest 'A raw manifest mutation breaks its lock linkage' {
        [void](Set-ReadyFixture)
        [IO.File]::AppendAllText($script:ManifestPath, ' ')
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'manifest hash mismatch'
    }

    Invoke-SelfTest 'Case-folded duplicate JSON properties are rejected before conversion' {
        $manifest = New-ReadyManifest
        Write-JsonFile $script:ManifestPath $manifest
        $json = [IO.File]::ReadAllText($script:ManifestPath).Replace(
            '"schema":',
            '"SCHEMA": 1,' + "`n  " + '"schema":'
        )
        [IO.File]::WriteAllText(
            $script:ManifestPath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'Duplicate JSON property'
    }

    Invoke-SelfTest 'Excessive JSON nesting is rejected before conversion' {
        $manifest = New-ReadyManifest
        Write-JsonFile $script:ManifestPath $manifest
        $nested = ('[' * 17) + '0' + (']' * 17)
        $json = [IO.File]::ReadAllText($script:ManifestPath).Replace(
            '"GPL-3.0-only"',
            $nested
        )
        [IO.File]::WriteAllText(
            $script:ManifestPath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'depth bound'
    }

    Invoke-SelfTest 'A lock manifest path cannot use a Windows backslash separator' {
        [void](Set-ReadyFixture)
        Write-TestLock -ManifestRelativePath 'closures\fixture.json'
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'Unsafe relative path'
        Assert-Throws {
            & $script:SourceVerifyScript -SourceRoot $script:SourceRoot `
                -LockFile $script:LockPath -SourceName fixture
        } 'Unsafe component closure manifest'
    }

    Invoke-SelfTest 'A manifest cannot claim a different owning commit' {
        $manifest = New-ReadyManifest
        $manifest.owning_commit = '0000000000000000000000000000000000000000'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'owning commit mismatch'
    }

    Invoke-SelfTest 'A mutated Git blob identity is rejected' {
        $manifest = New-ReadyManifest
        $manifest.files[0].git_blob = '0000000000000000000000000000000000000000'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'git blob mismatch'
    }

    Invoke-SelfTest 'A mutated byte count is rejected' {
        $manifest = New-ReadyManifest
        $manifest.files[0].bytes = [UInt64]$manifest.files[0].bytes + 1
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'byte count mismatch'
    }

    Invoke-SelfTest 'A mutated file SHA-256 is rejected' {
        $manifest = New-ReadyManifest
        $manifest.files[0].sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'SHA-256 mismatch'
    }

    Invoke-SelfTest 'A source file outside its selected prefix is rejected' {
        $manifest = New-ReadyManifest
        $manifest.files[0] = New-FileRow $script:OutsideDescriptor 'source'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'escapes its source prefix'
    }

    Invoke-SelfTest 'Exact-root mode cannot admit a nested file' {
        $manifest = New-ReadyManifest
        $manifest.source_prefixes = @([ordered]@{
            id = 'root-files'
            relative_path = '.'
            mode = 'exact-root-files'
        })
        $manifest.files[0].source_prefix_id = 'root-files'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'escapes its exact-root prefix'
    }

    Invoke-SelfTest 'Exact-root mode rejects a nested Windows backslash path' {
        $manifest = New-ReadyManifest
        $manifest.source_prefixes = @([ordered]@{
            id = 'root-files'
            relative_path = '.'
            mode = 'exact-root-files'
        })
        $manifest.files[0].relative_path = 'component\main.c'
        $manifest.files[0].source_prefix_id = 'root-files'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'Unsafe relative path'
    }

    Invoke-SelfTest 'Every ready file must bind to an approved notice' {
        $manifest = New-ReadyManifest
        $manifest.files[0].notice_id = 'missing-notice'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'invalid notice binding'
    }

    Invoke-SelfTest 'A notice binding must cover the file license expression' {
        $manifest = New-ReadyManifest
        $manifest.notices[0].license_expression = 'LGPL-2.1-or-later'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'invalid notice binding'
    }

    Invoke-SelfTest 'A syntactically valid but unapproved license expression is rejected' {
        $manifest = New-ReadyManifest
        $manifest.files[0].license_expression = 'BSD-3-Clause'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'invalid metadata'
    }

    Invoke-SelfTest 'Case-folded duplicate file rows are rejected' {
        $manifest = New-ReadyManifest
        $manifest.files = @($manifest.files[0], $manifest.files[0])
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'duplicate path'
    }

    Invoke-SelfTest 'A file cannot reference an unknown source prefix' {
        $manifest = New-ReadyManifest
        $manifest.files[0].source_prefix_id = 'missing-prefix'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'unknown source prefix'
    }

    Invoke-SelfTest 'Subtree mode cannot become an implicit repository-root prefix' {
        $manifest = New-ReadyManifest
        $manifest.source_prefixes[0].relative_path = '.'
        Write-JsonFile $script:ManifestPath $manifest
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
        } 'Unsafe path component'
    }

    Invoke-SelfTest 'Only planned-component rows can use closure linkage' {
        [void](Set-ReadyFixture)
        Write-TestLock -Disposition 'reference-only'
        Assert-Throws {
            & $script:SourceVerifyScript -SourceRoot $script:SourceRoot `
                -LockFile $script:LockPath -SourceName fixture
        } 'cannot link a component closure manifest'
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot `
                -LockFile $script:LockPath -SourceName fixture
        } 'is not a planned component'
    }

    Invoke-SelfTest 'A planned component without closure linkage is rejected' {
        [void](Set-ReadyFixture)
        Write-TestLock -ManifestRelativePath '' -ManifestHash ''
        Assert-Throws {
            & $script:SourceVerifyScript -SourceRoot $script:SourceRoot `
                -LockFile $script:LockPath -SourceName fixture
        } 'invalid component closure linkage'
    }

    Invoke-SelfTest 'Disposition casing cannot bypass component linkage policy' {
        [void](Set-ReadyFixture)
        Write-TestLock -Disposition 'Planned-Component'
        Assert-Throws {
            & $script:SourceVerifyScript -SourceRoot $script:SourceRoot `
                -LockFile $script:LockPath -SourceName fixture
        } 'invalid disposition'
    }

    Invoke-SelfTest 'A dirty pinned checkout invalidates a ready closure' {
        [void](Set-ReadyFixture)
        $sourcePath = Join-Path $script:Checkout 'component\main.c'
        $original = [IO.File]::ReadAllBytes($sourcePath)
        try {
            [IO.File]::AppendAllText($sourcePath, 'dirty')
            Assert-Throws {
                & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath
            } 'has local changes'
        }
        finally {
            [IO.File]::WriteAllBytes($sourcePath, $original)
        }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) component closure tests failed."
}
Write-Output 'All Windows 98 component closure tests passed.'

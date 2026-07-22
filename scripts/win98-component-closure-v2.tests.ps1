# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bounded-git-process.ps1')
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
        [Console]::Error.WriteLine(
            "FAIL $Name`: $($_.Exception.Message) [$($_.ScriptStackTrace)]"
        )
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

function New-ComponentSyntheticGitInfo {
    param([Parameter(Mandatory = $true)][string]$Command)

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($Command)
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Process -Id $PID).Path
    foreach ($argument in @(
        '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
    )) {
        [void]$info.ArgumentList.Add($argument)
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    return $info
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-TrackedDescriptor {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $line = Invoke-Git @('-C', $script:Checkout, 'ls-files', '--stage', '--', $RelativePath)
    if ($line -notmatch '^(?<mode>100644|100755) (?<hash>[0-9a-f]{40}) 0\t(?<path>.+)$' -or
        $Matches.path -cne $RelativePath) {
        throw "Missing test fixture path '$RelativePath'."
    }
    $path = Join-Path $script:Checkout (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )
    $bytes = [IO.File]::ReadAllBytes($path)
    return [pscustomobject]@{
        RelativePath = $RelativePath
        GitBlob = $Matches.hash
        Bytes = [UInt64]$bytes.Length
        Sha256 = Get-Sha256 $bytes
        Content = $bytes
    }
}

function Get-LineRange {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [int]$Line = 0
    )

    $starts = [Collections.Generic.List[int]]::new()
    [void]$starts.Add(0)
    for ($index = 0; $index -lt $Descriptor.Content.Length; $index++) {
        if ($Descriptor.Content[$index] -eq 0x0a -and
            $index + 1 -lt $Descriptor.Content.Length) {
            [void]$starts.Add($index + 1)
        }
    }
    if ($Line -lt 0 -or $Line -ge $starts.Count) {
        throw 'Requested line is absent from the test fixture.'
    }
    $start = $starts[$Line]
    $end = $Descriptor.Content.Length
    for ($index = $start; $index -lt $Descriptor.Content.Length; $index++) {
        if ($Descriptor.Content[$index] -in @(0x0a, 0x0d)) {
            $end = $index
            break
        }
    }
    $count = $end - $start
    $range = New-Object byte[] $count
    [Array]::Copy($Descriptor.Content, $start, $range, 0, $count)
    return [pscustomobject]@{
        Offset = [UInt64]$start
        Count = [UInt64]$count
        Sha256 = Get-Sha256 $range
    }
}

function New-Prefix {
    param([string]$Id, [string]$Path, [string]$Mode = 'subtree')
    return [ordered]@{id = $Id; relative_path = $Path; mode = $Mode}
}

function New-InlineEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Expression,
        [Parameter(Mandatory = $true)][object]$Range,
        [string]$PrefixId = 'component'
    )

    return [ordered]@{
        id = $Id
        kind = 'inline'
        relative_path = $Descriptor.RelativePath
        git_blob = $Descriptor.GitBlob
        bytes = $Descriptor.Bytes
        sha256 = $Descriptor.Sha256
        source_prefix_id = $PrefixId
        locator = [ordered]@{
            kind = 'byte-range'
            byte_offset = $Range.Offset
            byte_count = $Range.Count
            sha256 = $Range.Sha256
        }
        observed_license_expression = $Expression
    }
}

function New-DocumentEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Expression,
        [string]$PrefixId = 'root-files'
    )

    return [ordered]@{
        id = $Id
        kind = 'license-document'
        relative_path = $Descriptor.RelativePath
        git_blob = $Descriptor.GitBlob
        bytes = $Descriptor.Bytes
        sha256 = $Descriptor.Sha256
        source_prefix_id = $PrefixId
        locator = [ordered]@{kind = 'whole-file'}
        observed_license_expression = $Expression
    }
}

function New-DocumentRangeEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Expression,
        [Parameter(Mandatory = $true)][object]$Range,
        [string]$PrefixId = 'root-files'
    )

    $evidence = New-DocumentEvidence $Descriptor $Id $Expression $PrefixId
    $evidence.locator = [ordered]@{
        kind = 'byte-range'
        byte_offset = $Range.Offset
        byte_count = $Range.Count
        sha256 = $Range.Sha256
    }
    return $evidence
}

function New-FileRow {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Declared,
        [Parameter(Mandatory = $true)][string]$Selected,
        [Parameter(Mandatory = $true)][string[]]$EvidenceIds,
        [string]$PrefixId = 'component',
        [string[]]$Roles = @('source-unit')
    )

    return [ordered]@{
        relative_path = $Descriptor.RelativePath
        git_blob = $Descriptor.GitBlob
        bytes = $Descriptor.Bytes
        sha256 = $Descriptor.Sha256
        declared_license_expression = $Declared
        selected_license_expression = $Selected
        license_evidence_ids = @($EvidenceIds)
        source_prefix_id = $PrefixId
        roles = @($Roles)
    }
}

function New-BaseManifest {
    $evidence = New-InlineEvidence $script:MainDescriptor 'main-spdx' `
        'GPL-2.0-only OR MIT' $script:MainRange
    return [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 2
        status = 'ready'
        reason = ''
        upstream_name = 'fixture'
        owning_commit = $script:Commit
        source_prefixes = @((New-Prefix 'component' 'component'))
        license_evidence = @($evidence)
        files = @((New-FileRow $script:MainDescriptor `
            'GPL-2.0-only OR MIT' 'MIT' @('main-spdx')))
    }
}

function New-AndManifest {
    $mit = New-InlineEvidence $script:PlainDescriptor 'plain-mit' 'MIT' $script:PlainRange
    $bsd = New-InlineEvidence $script:PlainDescriptor 'plain-bsd' 'BSD-3-Clause' $script:PlainRange
    $manifest = New-BaseManifest
    $manifest.license_evidence = @($mit, $bsd)
    $manifest.files = @((New-FileRow $script:PlainDescriptor `
        'MIT AND BSD-3-Clause' 'MIT AND BSD-3-Clause' @('plain-mit', 'plain-bsd')))
    return $manifest
}

function New-MitApacheManifest {
    $mit = New-InlineEvidence $script:ApacheDescriptor `
        'apache-mit' 'MIT' $script:ApacheRange
    $apache = New-InlineEvidence $script:ApacheDescriptor `
        'apache-20' 'Apache-2.0' $script:ApacheRange
    $manifest = New-BaseManifest
    $manifest.license_evidence = @($mit, $apache)
    $manifest.files = @((New-FileRow $script:ApacheDescriptor `
        'MIT AND Apache-2.0' 'MIT AND Apache-2.0' @('apache-mit', 'apache-20')))
    return $manifest
}

function New-LgplMitManifest {
    $lgpl = New-InlineEvidence $script:ApacheDescriptor `
        'apache-lgpl' 'LGPL-2.1-or-later' $script:ApacheRange
    $mit = New-InlineEvidence $script:ApacheDescriptor `
        'apache-mit' 'MIT' $script:ApacheRange
    $manifest = New-BaseManifest
    $manifest.license_evidence = @($lgpl, $mit)
    $manifest.files = @((New-FileRow $script:ApacheDescriptor `
        'LGPL-2.1-or-later AND MIT' 'LGPL-2.1-or-later AND MIT' `
        @('apache-lgpl', 'apache-mit')))
    return $manifest
}

function New-AtomicManifest {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][object]$Range,
        [Parameter(Mandatory = $true)][string]$Expression
    )

    $evidence = New-InlineEvidence $Descriptor 'atomic-inline' $Expression $Range
    $manifest = New-BaseManifest
    $manifest.license_evidence = @($evidence)
    $manifest.files = @((New-FileRow $Descriptor $Expression $Expression @('atomic-inline')))
    return $manifest
}

function Write-TestLock {
    $manifestHash = (Get-FileHash -LiteralPath $script:ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $contents = @(
        '# SPDX-License-Identifier: GPL-3.0-only'
        '# Source-provenance lock only. These rows do not identify shipped or install-ready payloads.'
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
        "fixture`tfixture`t$($script:Origin)`t$($script:Commit)`tLicenseRef-Mixed-File-Level`tplanned-component`tclosures/fixture.json`t$manifestHash`tfixture-component"
    ) -join "`n"
    [IO.File]::WriteAllText($script:LockPath, $contents + "`n", [Text.UTF8Encoding]::new($false))
}

function Invoke-Manifest {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [switch]$PolicyAudit
    )

    Write-JsonFile $script:ManifestPath $Manifest
    Write-TestLock
    $arguments = @{
        SourceRoot = $script:SourceRoot
        LockFile = $script:LockPath
    }
    if ($PolicyAudit) {
        $arguments.PolicyAudit = $true
    }
    return @(& $script:VerifyScript @arguments)
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for the component closure v2 tests.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99 win98-component-closure-v2-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $script:VerifyScript = Join-Path $PSScriptRoot 'verify-win98-component-closure.ps1'
    $script:SchemaPath = Join-Path $PSScriptRoot '..\drivers\win98\component-closure-v2.schema.json'
    $script:V1SchemaPath = Join-Path $PSScriptRoot '..\drivers\win98\component-closure.schema.json'
    $script:SourceRoot = Join-Path $testRoot 'sources'
    $script:Checkout = Join-Path $script:SourceRoot 'fixture'
    $metadataRoot = Join-Path $testRoot 'metadata'
    $manifestRoot = Join-Path $metadataRoot 'closures'
    $script:ManifestPath = Join-Path $manifestRoot 'fixture.json'
    $script:LockPath = Join-Path $metadataRoot 'upstream.lock.tsv'
    $script:Origin = 'https://example.invalid/fixture.git'

    foreach ($directory in @(
        'component', 'include', 'include/winddk', 'win9x'
    )) {
        New-Item -ItemType Directory -Path (Join-Path $script:Checkout $directory) -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $manifestRoot -Force | Out-Null
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'LICENSE'), "MIT`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'LICENSE-OR'), "GPL-2.0-only OR MIT`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'LICENSE-SPDX'), "# SPDX-License-Identifier: GPL-2.0-only`n", $utf8)
    [IO.File]::WriteAllBytes(
        (Join-Path $script:Checkout 'EMPTY-LICENSE'),
        (New-Object byte[] 0)
    )
    [IO.File]::WriteAllBytes(
        (Join-Path $script:Checkout 'LARGE-LICENSE'),
        (New-Object byte[] 1048576)
    )
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\main.c'), "/* SPDX-License-Identifier: GPL-2.0 OR MIT */`nint main(void);`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\plain.c'), "MIT BSD-3-Clause`nint plain;`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\apache.c'), "MIT Apache-2.0`nint apache;`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\bison.c'), "/* SPDX-License-Identifier: GPL-3.0+ WITH Bison-exception-2.2 */`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\mlaa.c'), "LicenseRef-Mesa-Jimenez-MLAA`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\multi.c'), "/* SPDX-License-Identifier: MIT */`n/* SPDX-License-Identifier: BSD-3-Clause */`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\prose.c'), "This file is distributed under version 2 of the GNU General Public License.`nPermission is hereby granted, free of charge, to use and modify this software.`n", $utf8)
    $manySpdx = ((1..129 | ForEach-Object {
        '/* SPDX-License-Identifier: MIT */'
    }) -join "`n") + "`n"
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'component\many.c'), $manySpdx, $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'include\git_sha1.h'), "int git_sha1;`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'include\winddk\ddk.h'), "int ddk;`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:Checkout 'win9x\wddm_screen.h'), "int wddm;`n", $utf8)
    Invoke-Git @('init', '-q', $script:Checkout) | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'user.name', 'RETVRN99 Test') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'user.email', 'test@retvrn99.invalid') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'core.autocrlf', 'false') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'add', '.') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'commit', '-q', '-m', 'Pinned fixture') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'remote', 'add', 'origin', $script:Origin) | Out-Null
    $script:Commit = Invoke-Git @('-C', $script:Checkout, 'rev-parse', 'HEAD')

    $script:LicenseDescriptor = Get-TrackedDescriptor 'LICENSE'
    $script:LicenseOrDescriptor = Get-TrackedDescriptor 'LICENSE-OR'
    $script:LicenseSpdxDescriptor = Get-TrackedDescriptor 'LICENSE-SPDX'
    $script:EmptyLicenseDescriptor = Get-TrackedDescriptor 'EMPTY-LICENSE'
    $script:LargeLicenseDescriptor = Get-TrackedDescriptor 'LARGE-LICENSE'
    $script:MainDescriptor = Get-TrackedDescriptor 'component/main.c'
    $script:PlainDescriptor = Get-TrackedDescriptor 'component/plain.c'
    $script:ApacheDescriptor = Get-TrackedDescriptor 'component/apache.c'
    $script:BisonDescriptor = Get-TrackedDescriptor 'component/bison.c'
    $script:MlaaDescriptor = Get-TrackedDescriptor 'component/mlaa.c'
    $script:MultiDescriptor = Get-TrackedDescriptor 'component/multi.c'
    $script:ProseDescriptor = Get-TrackedDescriptor 'component/prose.c'
    $script:ManyDescriptor = Get-TrackedDescriptor 'component/many.c'
    $script:MainRange = Get-LineRange $script:MainDescriptor
    $script:LicenseRange = Get-LineRange $script:LicenseDescriptor
    $script:LargeLicenseRange = [pscustomobject]@{
        Offset = [UInt64]0
        Count = $script:LargeLicenseDescriptor.Bytes
        Sha256 = $script:LargeLicenseDescriptor.Sha256
    }
    $script:PlainRange = Get-LineRange $script:PlainDescriptor
    $script:ApacheRange = Get-LineRange $script:ApacheDescriptor
    $script:BisonRange = Get-LineRange $script:BisonDescriptor
    $script:MlaaRange = Get-LineRange $script:MlaaDescriptor
    $script:MultiFirstRange = Get-LineRange $script:MultiDescriptor 0
    $script:ProseGplRange = Get-LineRange $script:ProseDescriptor 0
    $script:ProseMitRange = Get-LineRange $script:ProseDescriptor 1
    $script:ManyRange = [pscustomobject]@{
        Offset = [UInt64]0
        Count = $script:ManyDescriptor.Bytes
        Sha256 = $script:ManyDescriptor.Sha256
    }

    Invoke-SelfTest 'Schema v2 is separate and leaves schema v1 on version 1' {
        $v1 = Get-Content -Raw -LiteralPath $script:V1SchemaPath | ConvertFrom-Json
        $v2 = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
        Assert-Equal $v1.properties.schema.const 1
        Assert-Equal $v2.properties.schema.const 2
        Assert-Equal $v2._spdx 'GPL-3.0-only'
        Assert-Equal (@($v2.'$defs'.declaredLicenseExpression.enum) -ccontains `
            'GPL-2.0-only') $false
        Assert-Equal (@($v2.'$defs'.observedLicenseExpression.enum) -ccontains `
            'GPL-2.0-only') $true
        Assert-Equal (@($v2.'$defs'.declaredLicenseExpression.enum) -ccontains `
            'MIT AND Apache-2.0') $true
        Assert-Equal (@($v2.'$defs'.observedLicenseExpression.enum) -ccontains `
            'MIT AND Apache-2.0') $true
        Assert-Equal (@($v2.'$defs'.selectedLicenseExpression.enum) -ccontains `
            'MIT AND Apache-2.0') $true
        Assert-Equal (@($v2.'$defs'.declaredLicenseExpression.enum) -ccontains `
            'LGPL-2.1-or-later AND MIT') $true
        Assert-Equal (@($v2.'$defs'.observedLicenseExpression.enum) -ccontains `
            'LGPL-2.1-or-later AND MIT') $true
        Assert-Equal (@($v2.'$defs'.selectedLicenseExpression.enum) -ccontains `
            'LGPL-2.1-or-later AND MIT') $true
        foreach ($expression in @(
            'SGI-B-2.0',
            'LicenseRef-Mesa-U-Atomic-Public-Domain',
            'LicenseRef-Mesa-Vrije-Permissive'
        )) {
            Assert-Equal (@($v2.'$defs'.declaredLicenseExpression.enum) `
                -ccontains $expression) $true
            Assert-Equal (@($v2.'$defs'.observedLicenseExpression.enum) `
                -ccontains $expression) $true
            Assert-Equal (@($v2.'$defs'.selectedLicenseExpression.enum) `
                -ccontains $expression) $true
        }
        Assert-Equal (@($v2.'$defs'.declaredLicenseExpression.enum) -ccontains `
            'Apache-2.0 AND MIT') $false
        Assert-Equal (@($v2.'$defs'.observedLicenseExpression.enum) -ccontains `
            'Apache-2.0 AND MIT') $false
        Assert-Equal (@($v2.'$defs'.selectedLicenseExpression.enum) -ccontains `
            'Apache-2.0 AND MIT') $false
        Assert-Equal $v2.'$defs'.licenseEvidenceBytes.minimum 1
        Assert-Equal $v2.'$defs'.licenseEvidence.properties.bytes.'$ref' `
            '#/$defs/licenseEvidenceBytes'
    }

    Invoke-SelfTest 'Synthetic Git timeout removes the owned process tree' {
        $pwsh = (Get-Process -Id $PID).Path
        $pidFile = Join-Path $testRoot 'component-timeout-descendant.pid'
        $sentinel = Join-Path $testRoot 'component-timeout-survived.txt'
        $quotedPidFile = $pidFile.Replace("'", "''")
        $quotedSentinel = $sentinel.Replace("'", "''")
        $descendantCommand = @"
[IO.File]::WriteAllText('$quotedPidFile', `$PID.ToString())
Start-Sleep -Seconds 4
[IO.File]::WriteAllText('$quotedSentinel', 'survived')
"@
        $descendantEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($descendantCommand)
        )
        $quotedPwsh = $pwsh.Replace("'", "''")
        $parentCommand = @"
`$child = Start-Process -FilePath '$quotedPwsh' -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-EncodedCommand', '$descendantEncoded'
) -WindowStyle Hidden -PassThru
for (`$index = 0; `$index -lt 100 -and
    -not [IO.File]::Exists('$quotedPidFile'); `$index++) {
    Start-Sleep -Milliseconds 20
}
Start-Sleep -Seconds 30
"@
        $info = New-ComponentSyntheticGitInfo $parentCommand
        Assert-Throws {
            Invoke-GswBoundedProcess -StartInfo $info `
                -Name 'component-verifier git' -TimeoutMilliseconds 1000 `
                -MaximumStdoutBytes 4096 -MaximumStderrBytes 4096
        } '^component-verifier git exceeded its process timeout\.$'
        if (-not [IO.File]::Exists($pidFile)) {
            throw 'Synthetic Git descendant did not publish its PID fixture.'
        }
        $descendantPid = [int][IO.File]::ReadAllText($pidFile)
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        do {
            $descendant = Get-Process -Id $descendantPid `
                -ErrorAction SilentlyContinue
            if ($null -eq $descendant) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -ne (Get-Process -Id $descendantPid `
                -ErrorAction SilentlyContinue)) {
            throw 'Synthetic Git descendant survived process-tree cleanup.'
        }
        if ([IO.File]::Exists($sentinel)) {
            throw 'Synthetic Git descendant executed after cleanup.'
        }
    }

    Invoke-SelfTest 'A complete OR disjunct can select MIT in a ready closure' {
        $output = Invoke-Manifest (New-BaseManifest)
        Assert-Equal ($output -join [Environment]::NewLine) `
            'Verified 1 ready Windows 98 component source closures.'
    }

    Invoke-SelfTest 'Curated Mesa dependency licenses are ready-compatible' {
        foreach ($expression in @(
            'SGI-B-2.0',
            'LicenseRef-Mesa-U-Atomic-Public-Domain',
            'LicenseRef-Mesa-Vrije-Permissive'
        )) {
            $manifest = New-AtomicManifest $script:PlainDescriptor `
                $script:PlainRange $expression
            $output = Invoke-Manifest $manifest
            Assert-Equal ($output -join [Environment]::NewLine) `
                'Verified 1 ready Windows 98 component source closures.'
        }
    }

    Invoke-SelfTest 'Same-path evidence and file rows require and accept identical blob identity' {
        & $script:VerifyScript -SourceRoot $script:SourceRoot -LockFile $script:LockPath | Out-Null
        $manifest = New-BaseManifest
        $manifest.license_evidence[0].bytes = [UInt64]$manifest.license_evidence[0].bytes + 1
        Assert-Throws { Invoke-Manifest $manifest } 'same-path whole-blob identity mismatch'
    }

    Invoke-SelfTest 'MIT cannot be selected from a conjunctive declaration' {
        $manifest = New-AndManifest
        $manifest.files[0].selected_license_expression = 'MIT'
        Assert-Throws { Invoke-Manifest $manifest } 'invalid structural license selection'
    }

    Invoke-SelfTest 'Conflicting evidence is represented by its curated canonical AND expression' {
        & { Invoke-Manifest (New-AndManifest) } | Out-Null
        $manifest = New-AndManifest
        $manifest.files[0].declared_license_expression = 'MIT'
        $manifest.files[0].selected_license_expression = 'MIT'
        Assert-Throws { Invoke-Manifest $manifest } 'declared license does not match all bound evidence'
    }

    Invoke-SelfTest 'MIT and Apache evidence derives the ready conjunction in either evidence order' {
        & { Invoke-Manifest (New-MitApacheManifest) } | Out-Null
        $manifest = New-MitApacheManifest
        $manifest.license_evidence = @(
            $manifest.license_evidence[1],
            $manifest.license_evidence[0]
        )
        $manifest.files[0].license_evidence_ids = @('apache-20', 'apache-mit')
        & { Invoke-Manifest $manifest } | Out-Null
    }

    Invoke-SelfTest 'MIT and Apache evidence rejects mismatched declarations and selections' {
        $manifest = New-MitApacheManifest
        $manifest.files[0].declared_license_expression = 'MIT'
        $manifest.files[0].selected_license_expression = 'MIT'
        Assert-Throws { Invoke-Manifest $manifest } `
            'declared license does not match all bound evidence'

        $manifest = New-MitApacheManifest
        $manifest.files[0].selected_license_expression = 'MIT'
        Assert-Throws { Invoke-Manifest $manifest } 'invalid structural license selection'
    }

    Invoke-SelfTest 'MIT and Apache evidence rejects noncanonical expression order' {
        $manifest = New-MitApacheManifest
        $manifest.files[0].declared_license_expression = 'Apache-2.0 AND MIT'
        $manifest.files[0].selected_license_expression = 'Apache-2.0 AND MIT'
        Assert-Throws { Invoke-Manifest $manifest } 'invalid metadata'
    }

    Invoke-SelfTest 'MIT and Apache evidence rejects an omitted license row' {
        $manifest = New-MitApacheManifest
        $manifest.license_evidence = @($manifest.license_evidence[0])
        $manifest.files[0].license_evidence_ids = @('apache-mit')
        Assert-Throws { Invoke-Manifest $manifest } `
            'declared license does not match all bound evidence'
    }

    Invoke-SelfTest 'LGPL and MIT evidence derives one canonical ready conjunction' {
        & { Invoke-Manifest (New-LgplMitManifest) } | Out-Null
        $manifest = New-LgplMitManifest
        $manifest.license_evidence = @(
            $manifest.license_evidence[1],
            $manifest.license_evidence[0]
        )
        $manifest.files[0].license_evidence_ids = @(
            'apache-mit',
            'apache-lgpl'
        )
        & { Invoke-Manifest $manifest } | Out-Null
    }

    Invoke-SelfTest 'LGPL and MIT conjunction cannot omit or strip either grant' {
        $manifest = New-LgplMitManifest
        $manifest.license_evidence = @($manifest.license_evidence[0])
        $manifest.files[0].license_evidence_ids = @('apache-lgpl')
        Assert-Throws { Invoke-Manifest $manifest } `
            'declared license does not match all bound evidence'

        $manifest = New-LgplMitManifest
        $manifest.files[0].selected_license_expression = 'LGPL-2.1-or-later'
        Assert-Throws { Invoke-Manifest $manifest } `
            'invalid structural license selection'
    }

    Invoke-SelfTest 'LGPL and MIT conjunction rejects noncanonical expression order' {
        $manifest = New-LgplMitManifest
        $manifest.files[0].declared_license_expression = `
            'MIT AND LGPL-2.1-or-later'
        $manifest.files[0].selected_license_expression = `
            'MIT AND LGPL-2.1-or-later'
        Assert-Throws { Invoke-Manifest $manifest } 'invalid metadata'
    }

    Invoke-SelfTest 'A WITH exception cannot be stripped by selection' {
        $manifest = New-AtomicManifest $script:BisonDescriptor $script:BisonRange `
            'GPL-3.0-or-later WITH Bison-exception-2.2'
        & { Invoke-Manifest $manifest } | Out-Null
        $manifest.files[0].selected_license_expression = 'GPL-3.0-or-later'
        Assert-Throws { Invoke-Manifest $manifest } 'invalid structural license selection'
    }

    Invoke-SelfTest 'Document evidence cannot override a different inline declaration' {
        $manifest = New-BaseManifest
        $document = New-DocumentEvidence $script:LicenseDescriptor 'mit-document' 'MIT'
        $manifest.source_prefixes = @(
            (New-Prefix 'root-files' '.' 'exact-root-files'),
            (New-Prefix 'component' 'component')
        )
        $manifest.license_evidence += $document
        $manifest.files[0].license_evidence_ids += 'mit-document'
        Assert-Throws { Invoke-Manifest $manifest } 'uncurated license-evidence combination'
    }

    Invoke-SelfTest 'Whole-file license evidence must not be empty' {
        $document = New-DocumentEvidence $script:EmptyLicenseDescriptor `
            'empty-document' 'MIT'
        $manifest = New-BaseManifest
        $manifest.source_prefixes = @(
            (New-Prefix 'root-files' '.' 'exact-root-files'),
            (New-Prefix 'component' 'component')
        )
        $manifest.license_evidence = @($document)
        $manifest.files = @((New-FileRow $script:PlainDescriptor 'MIT' 'MIT' `
            @('empty-document')))
        Assert-Throws { Invoke-Manifest $manifest } 'license evidence must not be empty'
    }

    Invoke-SelfTest 'License-document SPDX must match its observed expression' {
        $document = New-DocumentEvidence $script:LicenseSpdxDescriptor `
            'mislabeled-document' 'MIT'
        $manifest = New-BaseManifest
        $manifest.source_prefixes = @(
            (New-Prefix 'root-files' '.' 'exact-root-files'),
            (New-Prefix 'component' 'component')
        )
        $manifest.license_evidence = @($document)
        $manifest.files = @((New-FileRow $script:PlainDescriptor 'MIT' 'MIT' `
            @('mislabeled-document')))
        Assert-Throws { Invoke-Manifest $manifest } `
            'SPDX declaration does not match its observed license expression'
    }

    Invoke-SelfTest 'Byte ranges for one blob are verified as one group' {
        $first = New-DocumentRangeEvidence $script:LicenseDescriptor `
            'mit-range-a' 'MIT' $script:LicenseRange
        $second = New-DocumentRangeEvidence $script:LicenseDescriptor `
            'mit-range-b' 'MIT' $script:LicenseRange
        $manifest = New-BaseManifest
        $manifest.source_prefixes = @(
            (New-Prefix 'root-files' '.' 'exact-root-files'),
            (New-Prefix 'component' 'component')
        )
        $manifest.license_evidence = @($first, $second)
        $manifest.files = @((New-FileRow $script:PlainDescriptor 'MIT' 'MIT' `
            @('mit-range-a', 'mit-range-b')))
        & { Invoke-Manifest $manifest } | Out-Null
    }

    Invoke-SelfTest 'Aggregate byte-range proof work is bounded before Git reads' {
        $evidence = [Collections.Generic.List[object]]::new()
        foreach ($index in 0..16) {
            [void]$evidence.Add((New-DocumentRangeEvidence `
                $script:LargeLicenseDescriptor "large-range-$index" 'MIT' `
                $script:LargeLicenseRange))
        }
        $manifest = New-BaseManifest
        $manifest.source_prefixes = @(
            (New-Prefix 'root-files' '.' 'exact-root-files'),
            (New-Prefix 'component' 'component')
        )
        $manifest.license_evidence = @($evidence)
        $manifest.files = @((New-FileRow $script:PlainDescriptor 'MIT' 'MIT' `
            @($evidence | ForEach-Object { $_.id })))
        Assert-Throws { Invoke-Manifest $manifest } `
            'aggregate license-evidence byte-range work bound'
    }

    Invoke-SelfTest 'Every SPDX declaration requires matching normalized inline evidence' {
        $manifest = New-BaseManifest
        $document = New-DocumentEvidence $script:LicenseOrDescriptor 'or-document' `
            'GPL-2.0-only OR MIT'
        $manifest.source_prefixes = @(
            (New-Prefix 'root-files' '.' 'exact-root-files'),
            (New-Prefix 'component' 'component')
        )
        $manifest.license_evidence = @($document)
        $manifest.files[0].license_evidence_ids = @('or-document')
        Assert-Throws { Invoke-Manifest $manifest } 'SPDX declaration without matching bound inline evidence'
    }

    Invoke-SelfTest 'Every SPDX occurrence is checked rather than only the first' {
        $first = New-InlineEvidence $script:MultiDescriptor 'multi-mit' 'MIT' `
            $script:MultiFirstRange
        $manifest = New-BaseManifest
        $manifest.license_evidence = @($first)
        $manifest.files = @((New-FileRow $script:MultiDescriptor 'MIT' 'MIT' @('multi-mit')))
        Assert-Throws { Invoke-Manifest $manifest } 'SPDX declaration without matching bound inline evidence'
    }

    Invoke-SelfTest 'SPDX normalization must match the reviewed observed expression' {
        $manifest = New-BaseManifest
        $manifest.license_evidence[0].observed_license_expression = `
            'GPL-3.0-only OR MIT'
        $manifest.files[0].declared_license_expression = 'GPL-3.0-only OR MIT'
        Assert-Throws { Invoke-Manifest $manifest } `
            'SPDX declaration does not match its observed license expression'
    }

    Invoke-SelfTest 'Raw byte-range mutation is rejected from the pinned Git blob' {
        $manifest = New-BaseManifest
        $manifest.license_evidence[0].locator.sha256 = '0' * 64
        Assert-Throws { Invoke-Manifest $manifest } 'byte-range SHA-256 mismatch'
    }

    Invoke-SelfTest 'Blocked policy audit still verifies exact byte ranges' {
        $manifest = New-BaseManifest
        $manifest.status = 'blocked'
        $manifest.reason = 'Reviewed rows remain incompatible.'
        $manifest.license_evidence[0].locator.sha256 = '0' * 64
        Assert-Throws { Invoke-Manifest $manifest -PolicyAudit } 'byte-range SHA-256 mismatch'
    }

    Invoke-SelfTest 'Blocked policy audit still verifies exact whole-blob identity' {
        $manifest = New-BaseManifest
        $manifest.status = 'blocked'
        $manifest.reason = 'Reviewed rows remain incompatible.'
        $manifest.license_evidence[0].sha256 = '0' * 64
        $manifest.files[0].sha256 = '0' * 64
        Assert-Throws { Invoke-Manifest $manifest -PolicyAudit } 'SHA-256 mismatch'
    }

    Invoke-SelfTest 'Blocked audit can describe incompatible reviewed MLAA rows but normal use rejects them' {
        $manifest = New-AtomicManifest $script:MlaaDescriptor $script:MlaaRange `
            'LicenseRef-Mesa-Jimenez-MLAA'
        $manifest.status = 'blocked'
        $manifest.reason = 'MLAA terms are excluded from the ready closure.'
        $output = Invoke-Manifest $manifest -PolicyAudit
        Assert-Equal ($output -join [Environment]::NewLine) `
            'Policy-audited 1 Windows 98 component closure manifests; 1 remain blocked and unusable.'
        Assert-Throws { Invoke-Manifest $manifest } 'is blocked'
    }

    Invoke-SelfTest 'Blocked audit accepts hashed prose evidence and derives GPL2 AND MIT' {
        $gpl = New-InlineEvidence $script:ProseDescriptor 'prose-gpl2' `
            'GPL-2.0-only' $script:ProseGplRange
        $mit = New-InlineEvidence $script:ProseDescriptor 'prose-mit' `
            'MIT' $script:ProseMitRange
        $manifest = New-BaseManifest
        $manifest.status = 'blocked'
        $manifest.reason = 'GPL-2.0-only AND MIT is incompatible with ready policy.'
        $manifest.license_evidence = @($gpl, $mit)
        $manifest.files = @((New-FileRow $script:ProseDescriptor `
            'GPL-2.0-only AND MIT' 'GPL-2.0-only AND MIT' `
            @('prose-gpl2', 'prose-mit')))
        $output = Invoke-Manifest $manifest -PolicyAudit
        Assert-Equal ($output -join [Environment]::NewLine) `
            'Policy-audited 1 Windows 98 component closure manifests; 1 remain blocked and unusable.'
        Assert-Throws { Invoke-Manifest $manifest } 'is blocked'
    }

    Invoke-SelfTest 'MLAA is incompatible with ready policy' {
        $manifest = New-AtomicManifest $script:MlaaDescriptor $script:MlaaRange `
            'LicenseRef-Mesa-Jimenez-MLAA'
        Assert-Throws { Invoke-Manifest $manifest } 'incompatible license selection'
    }

    Invoke-SelfTest 'Unknown and unused evidence IDs fail closed' {
        $manifest = New-BaseManifest
        $manifest.files[0].license_evidence_ids = @('unknown')
        Assert-Throws { Invoke-Manifest $manifest } 'unknown license-evidence ID'
        $manifest = New-BaseManifest
        $extra = New-InlineEvidence $script:MainDescriptor 'unused' `
            'GPL-2.0-only OR MIT' $script:MainRange
        $manifest.license_evidence += $extra
        Assert-Throws { Invoke-Manifest $manifest } 'unused license evidence'
    }

    Invoke-SelfTest 'Unknown and unused source prefixes fail closed' {
        $manifest = New-BaseManifest
        $manifest.files[0].source_prefix_id = 'unknown-prefix'
        Assert-Throws { Invoke-Manifest $manifest } 'unknown source prefix'
        $manifest = New-BaseManifest
        $manifest.source_prefixes += New-Prefix 'unused-prefix' 'include'
        Assert-Throws { Invoke-Manifest $manifest } 'unused license evidence or source prefix'
    }

    Invoke-SelfTest 'Duplicate evidence IDs and duplicate file bindings fail closed' {
        $manifest = New-BaseManifest
        $manifest.license_evidence += $manifest.license_evidence[0]
        Assert-Throws { Invoke-Manifest $manifest } 'invalid license-evidence metadata'
        $manifest = New-BaseManifest
        $manifest.files[0].license_evidence_ids = @('main-spdx', 'main-spdx')
        Assert-Throws { Invoke-Manifest $manifest } 'duplicate or invalid license-evidence ID'
    }

    Invoke-SelfTest 'Roles are unique and in canonical order' {
        $manifest = New-BaseManifest
        $manifest.files[0].roles = @('source-unit', 'source-unit')
        Assert-Throws { Invoke-Manifest $manifest } 'duplicate, unknown, or unordered roles'
        $manifest = New-BaseManifest
        $manifest.files[0].roles = @('resource', 'source-unit')
        Assert-Throws { Invoke-Manifest $manifest } 'duplicate, unknown, or unordered roles'
    }

    Invoke-SelfTest 'Byte-range bounds are enforced before Git reads' {
        $manifest = New-BaseManifest
        $manifest.license_evidence[0].locator.byte_count = [UInt64]$manifest.license_evidence[0].bytes + 1
        Assert-Throws { Invoke-Manifest $manifest } 'invalid byte range'
        $manifest = New-BaseManifest
        $manifest.license_evidence[0].locator = [ordered]@{kind = 'whole-file'}
        Assert-Throws { Invoke-Manifest $manifest } 'must use a byte-range locator'
    }

    Invoke-SelfTest 'SPDX collection is bounded to 128 declarations per blob' {
        $manifest = New-AtomicManifest $script:ManyDescriptor $script:ManyRange 'MIT'
        Assert-Throws { Invoke-Manifest $manifest } 'SPDX declaration-count bound'
    }

    Invoke-SelfTest 'Schema dispatch accepts only exact JSON integers 1 and 2' {
        $manifest = New-BaseManifest
        Write-JsonFile $script:ManifestPath $manifest
        $json = [IO.File]::ReadAllText($script:ManifestPath) -replace `
            '"schema"\s*:\s*2(?=\s*[,}])', '"schema": 2.0'
        [IO.File]::WriteAllText(
            $script:ManifestPath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Write-TestLock
        Assert-Throws {
            & $script:VerifyScript -SourceRoot $script:SourceRoot `
                -LockFile $script:LockPath
        } 'must be a JSON integer'
        $manifest = New-BaseManifest
        $manifest.schema = 3
        Assert-Throws { Invoke-Manifest $manifest } 'Unsupported component closure schema'
        $manifest = New-BaseManifest
        $manifest.schema = '2'
        Assert-Throws { Invoke-Manifest $manifest } 'must be a JSON integer'
    }

    Invoke-SelfTest 'Ready v2 rejects each known Mesa forbidden path' {
        foreach ($relativePath in @(
            'include/git_sha1.h',
            'win9x/wddm_screen.h',
            'include/winddk/ddk.h'
        )) {
            $descriptor = Get-TrackedDescriptor $relativePath
            $document = New-DocumentEvidence $script:LicenseDescriptor 'mit-document' 'MIT'
            $prefixPath = Split-Path -Parent $relativePath
            $prefixPath = $prefixPath.Replace('\', '/')
            $manifest = New-BaseManifest
            $manifest.source_prefixes = @(
                (New-Prefix 'root-files' '.' 'exact-root-files'),
                (New-Prefix 'forbidden' $prefixPath)
            )
            $manifest.license_evidence = @($document)
            $manifest.files = @((New-FileRow $descriptor 'MIT' 'MIT' `
                @('mit-document') 'forbidden'))
            Assert-Throws { Invoke-Manifest $manifest } 'forbidden Mesa path'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) component closure v2 tests failed."
}
Write-Output 'All Windows 98 component closure v2 tests passed.'

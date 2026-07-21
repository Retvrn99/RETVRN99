# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$NameFilter,
    [switch]$DetailedFailures,
    [switch]$V2Only,
    [string]$GeneratedRootLf,
    [string]$GeneratedRootCrlf,
    [string]$V2SourceRoot,
    [ValidateRange(1, 64)][int]$TestShardCount = 1,
    [ValidateRange(0, 63)][int]$TestShardIndex = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:TestNameFilter = [string]$NameFilter
$script:TestDetailedFailures = [bool]$DetailedFailures
$script:TestGitExecutable = ''
$script:DiscoveredTests = 0
$script:ExecutedTests = 0
if ($TestShardIndex -ge $TestShardCount) {
    throw 'TestShardIndex must be less than TestShardCount.'
}

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $ordinal = $script:DiscoveredTests
    $script:DiscoveredTests++
    if (-not [string]::IsNullOrWhiteSpace($script:TestNameFilter) -and
        $Name -notlike "*$($script:TestNameFilter)*") {
        return
    }
    if (($ordinal % $TestShardCount) -ne $TestShardIndex) {
        return
    }
    $script:ExecutedTests++
    try {
        & $Body
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
        if ($script:TestDetailedFailures) {
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
        & $Body
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedText*") {
            throw "Expected error containing '$ExpectedText', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error containing '$ExpectedText'."
}

function Get-TestGitExecutable {
    if (-not [string]::IsNullOrWhiteSpace($script:TestGitExecutable)) {
        return $script:TestGitExecutable
    }
    $discovered = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $installationRoot = Split-Path -Parent (Split-Path -Parent $discovered)
    $direct = Join-Path $installationRoot 'mingw64\bin\git.exe'
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        $script:TestGitExecutable = [IO.Path]::GetFullPath($direct)
    }
    else {
        $script:TestGitExecutable = [IO.Path]::GetFullPath($discovered)
    }
    return $script:TestGitExecutable
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $git = Get-TestGitExecutable
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $git
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $childEnvironment = $startInfo.EnvironmentVariables
    if ($null -eq $childEnvironment) {
        throw 'Parent environment contains case-colliding keys and cannot be sanitized for Git.'
    }
    foreach ($variable in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )) {
        $childEnvironment.Remove($variable)
    }
    $allArguments = @(
        '-c', 'maintenance.auto=false', '-c', 'gc.auto=0',
        '-c', 'core.fsmonitor=false'
    ) + $Arguments
    $escaped = [Collections.Generic.List[string]]::new()
    foreach ($argument in $allArguments) {
        if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') {
            $escaped.Add($argument)
            continue
        }
        $builder = [Text.StringBuilder]::new()
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') {
                $backslashes++
                continue
            }
            if ($character -eq '"') {
                [void]$builder.Append(('\' * (2 * $backslashes + 1)))
                [void]$builder.Append('"')
            }
            else {
                [void]$builder.Append(('\' * $backslashes))
                [void]$builder.Append($character)
            }
            $backslashes = 0
        }
        [void]$builder.Append(('\' * (2 * $backslashes)))
        [void]$builder.Append('"')
        $escaped.Add($builder.ToString())
    }
    $startInfo.Arguments = $escaped -join ' '
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $ownedProcessId = -1
    try {
        if (-not $process.Start()) {
            throw "Unable to start git $($Arguments -join ' ')."
        }
        $started = $true
        $ownedProcessId = $process.Id
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "git $($Arguments -join ' ') timed out."
        }
        $tasks = [Threading.Tasks.Task[]]@($outputTask, $errorTask)
        if (-not [Threading.Tasks.Task]::WaitAll($tasks, 30000)) {
            throw "git $($Arguments -join ' ') output collection timed out."
        }
        $outputText = $outputTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed: $errorText"
        }
        if ($outputText.Length -gt 1048576 -or $errorText.Length -gt 65536) {
            throw "git $($Arguments -join ' ') exceeded its output bound."
        }
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            return @()
        }
        return @($outputText.Trim() -split '\r?\n')
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        if ($started -and -not $process.HasExited) {
            throw "Owned test Git process $ownedProcessId did not exit."
        }
        $process.Dispose()
    }
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

function Write-UpstreamLock {
    param(
        [string]$Name = 'fixture',
        [string]$SourceDirectory = 'fixture',
        [string]$Repository = $script:Origin,
        [string]$Commit = $script:Commit,
        [string]$Disposition = 'planned-component',
        [string]$ClosureRelativePath = 'component-closures/fixture.json',
        [string]$ClosureHash
    )

    if ([string]::IsNullOrWhiteSpace($ClosureHash)) {
        $ClosureHash = (Get-FileHash -LiteralPath $script:ClosurePath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $lines = @(
        '# SPDX-License-Identifier: GPL-3.0-only',
        '# Test-only authoritative source provenance.',
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope",
        "$Name`t$SourceDirectory`t$Repository`t$Commit`tMIT`t$Disposition`t$ClosureRelativePath`t$ClosureHash`tfixture-component"
    )
    [IO.File]::WriteAllText(
        $script:UpstreamLockPath,
        ($lines -join "`n") + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function Write-Closure {
    param([Parameter(Mandatory = $true)][object]$Value)

    Write-JsonFile $script:ClosurePath $Value
    Write-UpstreamLock
}

function Convert-HexToBytes {
    param([Parameter(Mandatory = $true)][string]$Hex)

    if ($Hex.Length -ne 64 -or $Hex -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid test SHA-256 '$Hex'."
    }
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return $bytes
}

function Get-BigEndianBytes {
    param(
        [Parameter(Mandatory = $true)][UInt64]$Value,
        [Parameter(Mandatory = $true)][int]$Width
    )

    if ($Width -eq 4) {
        $bytes = [BitConverter]::GetBytes([UInt32]$Value)
    }
    else {
        $bytes = [BitConverter]::GetBytes($Value)
    }
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }
    return ,$bytes
}

function Add-TestDigestBlock {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Cryptography.HashAlgorithm]$Digest,
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    [void]$Digest.TransformBlock($Bytes, 0, $Bytes.Length, $Bytes, 0)
}

function Get-TrackedDescriptor {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $pathspec = ":(top,literal)$RelativePath"
    $lines = @(Invoke-Git @(
        '-c', 'core.quotePath=false', '-C', $script:Checkout,
        'ls-files', '--stage', '--', $pathspec
    ))
    if ($lines.Count -ne 1 -or
        $lines[0] -notmatch '^(?<mode>[0-9]{6}) (?<hash>[0-9a-f]{40}) 0\t(?<path>.+)$' -or
        $Matches.path -cne $RelativePath) {
        throw "Unable to describe tracked fixture '$RelativePath'."
    }
    $path = Join-Path $script:Checkout (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )
    $bytes = [IO.File]::ReadAllBytes($path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return [pscustomobject]@{
        RelativePath = $RelativePath
        GitBlob = [string]$Matches.hash
        Bytes = [UInt64]$bytes.Length
        Sha256 = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
}

function New-ClosureNotice {
    return [ordered]@{
        id = 'fixture-license'
        relative_path = $script:LicenseDescriptor.RelativePath
        git_blob = $script:LicenseDescriptor.GitBlob
        bytes = $script:LicenseDescriptor.Bytes
        sha256 = $script:LicenseDescriptor.Sha256
        license_expression = 'MIT'
    }
}

function New-ClosureFile {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Role
    )

    return [ordered]@{
        relative_path = $Descriptor.RelativePath
        git_blob = $Descriptor.GitBlob
        bytes = $Descriptor.Bytes
        sha256 = $Descriptor.Sha256
        license_expression = 'MIT'
        notice_id = 'fixture-license'
        source_prefix_id = $Prefix
        role = $Role
    }
}

function New-ReadyClosure {
    return [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        status = 'ready'
        reason = ''
        upstream_name = 'fixture'
        owning_commit = $script:Commit
        source_prefixes = @(
            [ordered]@{
                id = 'generator'
                relative_path = 'generator'
                mode = 'subtree'
            },
            [ordered]@{
                id = 'templates'
                relative_path = 'templates'
                mode = 'subtree'
            }
        )
        notices = @((New-ClosureNotice))
        files = @(
            (New-ClosureFile $script:GeneratorDescriptor 'generator' 'generator'),
            (New-ClosureFile $script:TemplateDescriptor 'templates' 'template')
        )
    }
}

function Get-OutputDescriptor {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $script:GeneratedRoot (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )
    $item = Get-Item -LiteralPath $path
    return [ordered]@{
        relative_path = $RelativePath
        bytes = [UInt64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        license_expression = 'MIT'
        notice_id = 'fixture-license'
    }
}

function Get-LockedTree {
    param([Parameter(Mandatory = $true)][object[]]$Outputs)

    if ($Outputs.Count -ne 2) {
        throw "Expected exactly two fixture outputs, observed $($Outputs.Count)."
    }
    $records = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    [UInt64]$aggregateBytes = 0
    [UInt64]$maximumFileBytes = 0
    [UInt64]$maximumPathBytes = 0
    foreach ($output in $Outputs) {
        $pathBytes = $utf8.GetByteCount($output.relative_path)
        if ($pathBytes -gt $maximumPathBytes) { $maximumPathBytes = $pathBytes }
        $aggregateBytes += [UInt64]$output.bytes
        if ([UInt64]$output.bytes -gt $maximumFileBytes) {
            $maximumFileBytes = [UInt64]$output.bytes
        }
        [byte[]]$hashBytes = @(Convert-HexToBytes $output.sha256)
        $records.Add($output.relative_path, [pscustomobject]@{
            Bytes = [UInt64]$output.bytes
            Hash = $hashBytes
        })
        $parts = $output.relative_path.Split('/')
        for ($count = 1; $count -lt $parts.Count; $count++) {
            $directory = [string]::Join('/', $parts[0..($count - 1)])
            [void]$directories.Add($directory)
            $directoryBytes = $utf8.GetByteCount($directory)
            if ($directoryBytes -gt $maximumPathBytes) {
                $maximumPathBytes = $directoryBytes
            }
        }
    }
    [string[]]$paths = @($records.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $digest = [Security.Cryptography.SHA256]::Create()
    try {
        $header = $utf8.GetBytes("RETVRN99-WIN98-TREE-SHA256-V1`0")
        Add-TestDigestBlock $digest $header
        Add-TestDigestBlock $digest (
            Get-BigEndianBytes -Value ([UInt64]$paths.Count) -Width 8
        )
        Add-TestDigestBlock $digest (
            Get-BigEndianBytes -Value $aggregateBytes -Width 8
        )
        foreach ($path in $paths) {
            $pathBytes = $utf8.GetBytes($path)
            $record = $records[$path]
            Add-TestDigestBlock $digest (
                Get-BigEndianBytes -Value ([UInt64]$pathBytes.Length) -Width 4
            )
            Add-TestDigestBlock $digest $pathBytes
            Add-TestDigestBlock $digest (
                Get-BigEndianBytes -Value ([UInt64]$record.Bytes) -Width 8
            )
            Add-TestDigestBlock $digest ([byte[]]($record.Hash))
        }
        [void]$digest.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $treeHash = ([BitConverter]::ToString($digest.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $digest.Dispose()
    }
    return [ordered]@{
        file_count = [UInt64]$paths.Count
        directory_count = [UInt64]$directories.Count
        total_entries = [UInt64]($paths.Count + $directories.Count)
        aggregate_bytes = $aggregateBytes
        maximum_file_bytes = $maximumFileBytes
        maximum_path_bytes = $maximumPathBytes
        digest_algorithm = 'retvrn99-file-tree-sha256-v1'
        sha256 = $treeHash
    }
}

function New-GeneratedLock {
    $inputs = @(
        (New-ClosureFile $script:GeneratorDescriptor 'generator' 'generator'),
        (New-ClosureFile $script:TemplateDescriptor 'templates' 'template')
    )
    $outputs = @(
        (Get-OutputDescriptor 'include/generated.h'),
        (Get-OutputDescriptor 'src/generated.c')
    )
    return [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        component = [ordered]@{
            component_id = 'fixture-generated'
            upstream_name = 'fixture'
            source_directory = 'fixture'
            repository = $script:Origin
            owning_commit = $script:Commit
            closure_manifest = [ordered]@{
                relative_path = 'component-closures/fixture.json'
                sha256 = (Get-FileHash -LiteralPath $script:ClosurePath `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        generator_inputs = $inputs
        notices = @((New-ClosureNotice))
        outputs = $outputs
        output_tree = Get-LockedTree $outputs
    }
}

function Write-FixtureOutputs {
    param([switch]$ReverseCreation)

    if (Test-Path -LiteralPath $script:GeneratedRoot) {
        [IO.Directory]::Delete($script:GeneratedRoot, $true)
    }
    New-Item -ItemType Directory -Path $script:GeneratedRoot | Out-Null
    $files = @(
        [pscustomobject]@{
            RelativePath = 'include/generated.h'
            Contents = "/* generated fixture */`n#define FIXTURE_VALUE 7`n"
        },
        [pscustomobject]@{
            RelativePath = 'src/generated.c'
            Contents = "/* generated fixture */`nint fixture_value = 7;`n"
        }
    )
    if ($ReverseCreation) { [Array]::Reverse($files) }
    foreach ($file in $files) {
        $path = Join-Path $script:GeneratedRoot (
            $file.RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        )
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText(
            $path,
            $file.Contents,
            [Text.UTF8Encoding]::new($false)
        )
    }
}

function Reset-Fixture {
    Write-FixtureOutputs
    Write-Closure (New-ReadyClosure)
    Write-JsonFile $script:LockPath (New-GeneratedLock)
}

function Invoke-Verification {
    param([scriptblock]$BeforeFinalCheckoutCheck)

    $parameters = @{
        SourceRoot = $script:SourceRoot
        GeneratedRoot = $script:GeneratedRoot
        LockFile = $script:LockPath
        MetadataRoot = $script:MetadataRoot
    }
    if ($null -ne $BeforeFinalCheckoutCheck) {
        $parameters.BeforeFinalCheckoutCheck = $BeforeFinalCheckoutCheck
    }
    & $script:Verifier @parameters
}

function Invoke-FixtureTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    if (-not [string]::IsNullOrWhiteSpace($script:TestNameFilter) -and
        $Name -notlike "*$($script:TestNameFilter)*") {
        return
    }
    $fixtureBody = $Body
    Invoke-SelfTest $Name {
        Reset-Fixture
        & $fixtureBody
    }
}

function Remove-TestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]'\/'
    )
    if ((Split-Path -Parent $fullPath) -cne $temporaryRoot -or
        -not (Split-Path -Leaf $fullPath).StartsWith(
            'retvrn99-generated-output-lock-test-',
            [StringComparison]::Ordinal
        )) {
        throw "Refusing to remove unverified test root '$fullPath'."
    }
    if (-not (Test-Path -LiteralPath $fullPath)) { return }
    foreach ($entry in @(Get-ChildItem -LiteralPath $fullPath -Recurse -Force)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Test cleanup found a reparse point: $($entry.FullName)"
        }
        if ($entry -is [IO.FileInfo] -and
            ($entry.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
            $entry.Attributes = $entry.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    }
    [IO.Directory]::Delete($fullPath, $true)
}

function Invoke-V2Tests {
    $v2TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'retvrn99-generated-output-lock-test-{0}' -f
            [Guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $v2TestRoot | Out-Null
    try {
        $verifier = Join-Path $PSScriptRoot `
            'verify-win98-generated-output-lock.ps1'
        $repositoryMetadataRoot = Join-Path $PSScriptRoot '..\drivers\win98'
        $metadataRoot = Join-Path $v2TestRoot 'metadata'
        New-Item -ItemType Directory -Path $metadataRoot | Out-Null
        $sourceLock = Join-Path $repositoryMetadataRoot `
            'generated-output-locks\mesa-23.1.9.json'
        $testLock = Join-Path $v2TestRoot 'mesa-23.1.9.json'
        $proofName = 'mesa-generated-source-reproducibility.json'
        $proofPath = Join-Path $metadataRoot $proofName
        $emptyGeneratedRoot = Join-Path $v2TestRoot 'empty-generated-root'
        New-Item -ItemType Directory -Path $emptyGeneratedRoot | Out-Null

        $lfRootInput = [string]$GeneratedRootLf
        $crlfRootInput = [string]$GeneratedRootCrlf
        $hasLfRoot = -not [string]::IsNullOrWhiteSpace($lfRootInput)
        $hasCrlfRoot = -not [string]::IsNullOrWhiteSpace($crlfRootInput)
        if ($hasLfRoot -ne $hasCrlfRoot) {
            throw 'GeneratedRootLf and GeneratedRootCrlf must be supplied together.'
        }
        $hasExternalRoots = $hasLfRoot -and $hasCrlfRoot
        $sourceRootInput = [string]$V2SourceRoot
        $hasSourceRoot = -not [string]::IsNullOrWhiteSpace($sourceRootInput)
        if ($hasExternalRoots -and -not $hasSourceRoot) {
            throw 'V2SourceRoot is required with generated roots.'
        }
        $evidenceSourceRoot = $metadataRoot
        if ($hasSourceRoot) {
            $evidenceSourceRoot = [IO.Path]::GetFullPath($sourceRootInput)
            if (-not (Test-Path -LiteralPath $evidenceSourceRoot -PathType Container)) {
                throw "Mesa evidence source root not found: $evidenceSourceRoot"
            }
        }
        $generatedRoot = $emptyGeneratedRoot
        $generatedRootCrlf = $null
        if ($hasExternalRoots) {
            $generatedRoot = [IO.Path]::GetFullPath($lfRootInput)
            $generatedRootCrlf = [IO.Path]::GetFullPath($crlfRootInput)
            foreach ($externalRoot in @($generatedRoot, $generatedRootCrlf)) {
                if (-not (Test-Path -LiteralPath $externalRoot -PathType Container)) {
                    throw "Published Mesa generated root not found: $externalRoot"
                }
            }
            $lfPrefix = $generatedRoot.TrimEnd([char[]]'\/') +
                [IO.Path]::DirectorySeparatorChar
            $crlfPrefix = $generatedRootCrlf.TrimEnd([char[]]'\/') +
                [IO.Path]::DirectorySeparatorChar
            if ($generatedRoot.Equals(
                    $generatedRootCrlf,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                $generatedRoot.StartsWith(
                    $crlfPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                $generatedRootCrlf.StartsWith(
                    $lfPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'GeneratedRootLf and GeneratedRootCrlf must be distinct non-nested roots.'
            }
        }

        $resetLock = {
            [IO.File]::Copy($sourceLock, $testLock, $true)
            foreach ($name in @(
                'mesa-generated-source-plan.json', 'mesa-source-seed.json',
                $proofName
            )) {
                [IO.File]::Copy(
                    (Join-Path $repositoryMetadataRoot $name),
                    (Join-Path $metadataRoot $name),
                    $true
                )
            }
            $closureDirectory = Join-Path $metadataRoot 'component-closures'
            New-Item -ItemType Directory -Path $closureDirectory -Force | Out-Null
            [IO.File]::Copy(
                (Join-Path $repositoryMetadataRoot `
                    'component-closures\mesa9x-23.1.x.json'),
                (Join-Path $closureDirectory 'mesa9x-23.1.x.json'),
                $true
            )
        }
        $readLock = {
            Get-Content -Raw -LiteralPath $testLock | ConvertFrom-Json
        }
        $verify = {
            & $verifier -GeneratedRoot $generatedRoot -LockFile $testLock `
                -MetadataRoot $metadataRoot -SourceRoot $evidenceSourceRoot
        }
        $readProof = {
            Get-Content -Raw -LiteralPath $proofPath | ConvertFrom-Json
        }
        $writeProofAndRefreshLock = {
            param(
                [Parameter(Mandatory = $true)][object]$Proof,
                [Parameter(Mandatory = $true)][object]$Lock
            )

            Write-JsonFile $proofPath $Proof
            $proofItem = Get-Item -LiteralPath $proofPath
            $Lock.provenance.generated_source_reproducibility.bytes =
                [long]$proofItem.Length
            $Lock.provenance.generated_source_reproducibility.sha256 =
                (Get-FileHash -LiteralPath $proofPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-JsonFile $testLock $Lock
        }
        $writeSkip = {
            param([Parameter(Mandatory = $true)][string]$Name)

            if ([string]::IsNullOrWhiteSpace($script:TestNameFilter) -or
                $Name -like "*$($script:TestNameFilter)*") {
                Write-Output "SKIP: $Name (supply -GeneratedRootLf and -GeneratedRootCrlf)"
            }
        }

        Invoke-SelfTest 'V2 schema fixes review and authorization semantics' {
            $schemaPath = Join-Path $repositoryMetadataRoot `
                'generated-output-lock.schema.json'
            $schema = Get-Content -Raw -LiteralPath $schemaPath |
                ConvertFrom-Json
            Assert-Equal $schema._spdx 'GPL-3.0-only'
            Assert-Equal $schema.properties.schema.const 2
            Assert-Equal (
                $schema.'$defs'.licenseExpression.enum -join '|'
            ) (
                'MIT|MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)|' +
                'MIT AND BSD-3-Clause|MIT AND Apache-2.0'
            )
            Assert-Equal $schema.'$defs'.scope.properties.authorizations.properties.build.const $false
            if ($schema.'$defs'.output.required -cnotcontains
                'license_evidence_ids' -or
                $schema.'$defs'.output.required -ccontains 'notice_id' -or
                $schema.properties.provenance.required -cnotcontains
                    'generated_source_reproducibility') {
                throw 'V2 output evidence fields are not closed.'
            }
        }

        $blockedAuditName =
            'V2 reviewed source audits the exact root without authorization'
        if ($hasExternalRoots) {
            Invoke-SelfTest $blockedAuditName {
                & $resetLock
                $result = @(& $verify)
                if ($result -notlike '*67 exact outputs*') {
                    throw 'Reviewed source verification did not report its exact output count.'
                }
            }
        }
        else {
            & $writeSkip $blockedAuditName
        }

        $dualRootName =
            'V2 LF and CRLF preparations bind the same normalized root'
        if ($hasExternalRoots) {
            Invoke-SelfTest $dualRootName {
                & $resetLock
                $result = @(& $verifier -GeneratedRoot $generatedRootCrlf `
                    -LockFile $testLock -MetadataRoot $metadataRoot `
                    -SourceRoot $evidenceSourceRoot)
                if ($result -notlike '*67 exact outputs*') {
                    throw 'CRLF source preparation did not match the normalized lock.'
                }
            }
        }
        else {
            & $writeSkip $dualRootName
        }

        $outputMutationName = 'V2 rejects an output digest mutation'
        if ($hasExternalRoots) {
            Invoke-SelfTest $outputMutationName {
                & $resetLock
                $lock = & $readLock
                $lock.outputs[0].sha256 = '0' * 64
                Write-JsonFile $testLock $lock
                Assert-Throws { & $verify } 'content mismatch'
            }
        }
        else {
            & $writeSkip $outputMutationName
        }

        $proofStabilityName =
            'V2 rechecks reproducibility proof at the final stability seam'
        if ($hasExternalRoots) {
            Invoke-SelfTest $proofStabilityName {
                & $resetLock
                $proofPathForCallback = $proofPath
                $beforeFinal = {
                    [IO.File]::AppendAllText(
                        $proofPathForCallback,
                        ' ',
                        [Text.UTF8Encoding]::new($false)
                    )
                }.GetNewClosure()
                Assert-Throws {
                    & $verifier -GeneratedRoot $generatedRoot `
                        -LockFile $testLock -MetadataRoot $metadataRoot `
                        -SourceRoot $evidenceSourceRoot `
                        -BeforeFinalCheckoutCheck $beforeFinal
                } 'metadata changed during verification'
            }
        }
        else {
            & $writeSkip $proofStabilityName
        }

        Invoke-SelfTest 'V2 rejects an omitted output' {
            & $resetLock
            $lock = & $readLock
            $lock.outputs = @($lock.outputs | Select-Object -Skip 1)
            Write-JsonFile $testLock $lock
            Assert-Throws { & $verify } 'exact bounds'
        }

        Invoke-SelfTest 'V2 rejects a wrong canonical output expression' {
            & $resetLock
            $lock = & $readLock
            $lock.outputs[0].license_expression = 'MIT AND Apache-2.0'
            Write-JsonFile $testLock $lock
            Assert-Throws { & $verify } 'Invalid license classification'
        }

        $evidenceOrderName = 'V2 rejects non-canonical ordered license evidence'
        if ($hasSourceRoot) {
            Invoke-SelfTest $evidenceOrderName {
            & $resetLock
            $lock = & $readLock
            $output = $lock.outputs | Where-Object {
                $_.relative_path -ceq 'mesa-23.1.x/src/mapi/glapi/enums.c'
            }
            [Array]::Reverse($output.license_evidence_ids)
            Write-JsonFile $testLock $lock
            Assert-Throws { & $verify } 'non-canonical license evidence order'
            }
        }
        else {
            & $writeSkip $evidenceOrderName
        }

        Invoke-SelfTest 'V2 rejects a validation-only side output in the manifest' {
            & $resetLock
            $lock = & $readLock
            $lock.validation_only_side_outputs[0] =
                $lock.outputs[0].relative_path
            Write-JsonFile $testLock $lock
            Assert-Throws { & $verify } 'not exactly excluded'
        }

        Invoke-SelfTest 'V2 rejects every attempted build authorization' {
            & $resetLock
            $lock = & $readLock
            $lock.scope.authorizations.build = $true
            Write-JsonFile $testLock $lock
            Assert-Throws { & $verify } 'must remain false'
        }

        Invoke-SelfTest 'V2 binds the reproducibility proof bytes' {
            & $resetLock
            $proof = & $readProof
            $proof.reason = "$($proof.reason) tampered"
            Write-JsonFile $proofPath $proof
            Assert-Throws { & $verify } 'reproducibility proof content mismatch'
        }

        Invoke-SelfTest 'V2 requires proven reproducibility status' {
            & $resetLock
            $lock = & $readLock
            $proof = & $readProof
            $proof.status = 'draft'
            & $writeProofAndRefreshLock $proof $lock
            Assert-Throws { & $verify } 'reproducibility proof is not proven'
        }

        Invoke-SelfTest 'V2 requires distinct LF and CRLF run identities' {
            & $resetLock
            $lock = & $readLock
            $proof = & $readProof
            $proof.runs[1].id = $proof.runs[0].id
            & $writeProofAndRefreshLock $proof $lock
            Assert-Throws { & $verify } 'reproducibility run identity mismatch'
        }

        Invoke-SelfTest 'V2 requires the proven normalized tree digest' {
            & $resetLock
            $lock = & $readLock
            $proof = & $readProof
            $proof.runs[1].descriptor.sha256 = '0' * 64
            & $writeProofAndRefreshLock $proof $lock
            Assert-Throws { & $verify } 'tree Sha256 mismatch'
        }

        Invoke-SelfTest 'V2 rejects reproducibility proof authorization' {
            & $resetLock
            $lock = & $readLock
            $proof = & $readProof
            $proof.scope.authorizations.build = $true
            & $writeProofAndRefreshLock $proof $lock
            Assert-Throws { & $verify } 'authorization build must remain false'
        }

        Invoke-SelfTest 'V2 reviewed status requires file-level evidence' {
            & $resetLock
            $lock = & $readLock
            $lock.outputs[0].license_evidence_ids = @()
            Write-JsonFile $testLock $lock
            Assert-Throws { & $verify } 'lacks license evidence'
        }
    }
    finally {
        Remove-TestRoot $v2TestRoot
    }
}

Invoke-V2Tests
if ($V2Only) {
    if ($script:Failures -ne 0) {
        throw "$($script:Failures) generated-output lock v2 tests failed."
    }
    Write-Output (
        'All {0} Windows 98 generated-output lock v2 tests passed (shard {1}/{2}).' -f
            $script:ExecutedTests, ($TestShardIndex + 1), $TestShardCount
    )
    return
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for generated-output lock tests.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-generated-output-lock-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $script:Verifier = Join-Path $PSScriptRoot 'verify-win98-generated-output-lock.ps1'
    $script:SchemaPath = Join-Path $PSScriptRoot `
        '..\drivers\win98\generated-output-lock.schema.json'
    $script:SourceRoot = Join-Path $testRoot 'sources'
    $script:Checkout = Join-Path $script:SourceRoot 'fixture'
    $script:MetadataRoot = Join-Path $testRoot 'metadata'
    $closureDirectory = Join-Path $script:MetadataRoot 'component-closures'
    $script:ClosurePath = Join-Path $closureDirectory 'fixture.json'
    $script:UpstreamLockPath = Join-Path $script:MetadataRoot 'upstream.lock.tsv'
    $script:LockPath = Join-Path $script:MetadataRoot 'fixture-generated.json'
    $script:GeneratedRoot = Join-Path $testRoot 'generated'
    $script:Origin = 'https://example.invalid/fixture.git'

    New-Item -ItemType Directory -Path (Join-Path $script:Checkout 'generator') `
        -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Checkout 'templates') `
        -Force | Out-Null
    New-Item -ItemType Directory -Path $closureDirectory -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $script:Checkout 'LICENSE'),
        "fixture MIT license`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $script:Checkout 'NOTICE'),
        "fixture secondary notice`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $script:Checkout 'generator\build.py'),
        "print('fixture')`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $script:Checkout 'templates\main.in'),
        "fixture={{ value }}`n",
        [Text.UTF8Encoding]::new($false)
    )
    Invoke-Git @('init', '-q', $script:Checkout) | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'user.name', 'RETVRN99 Test') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'user.email', 'test@retvrn99.invalid') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'config', 'core.autocrlf', 'false') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'add', '.') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'commit', '-q', '-m', 'Pinned fixture') | Out-Null
    Invoke-Git @('-C', $script:Checkout, 'remote', 'add', 'origin', $script:Origin) | Out-Null
    $script:Commit = @(Invoke-Git @('-C', $script:Checkout, 'rev-parse', 'HEAD'))[0]
    $script:LicenseDescriptor = Get-TrackedDescriptor 'LICENSE'
    $script:NoticeDescriptor = Get-TrackedDescriptor 'NOTICE'
    $script:GeneratorDescriptor = Get-TrackedDescriptor 'generator/build.py'
    $script:TemplateDescriptor = Get-TrackedDescriptor 'templates/main.in'

    Invoke-SelfTest 'The schema is GPL-3.0-only and closes every object shape' {
        $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
        Assert-Equal $schema._spdx 'GPL-3.0-only'
        Assert-Equal $schema.additionalProperties $false
        Assert-Equal $schema.properties.component.additionalProperties $false
        Assert-Equal $schema.properties.provenance.additionalProperties $false
        Assert-Equal $schema.'$defs'.licenseEvidence.oneOf.Count 2
        Assert-Equal $schema.'$defs'.generatedOutputEvidence.additionalProperties $false
        Assert-Equal $schema.'$defs'.componentSourceEvidence.additionalProperties $false
        Assert-Equal $schema.'$defs'.output.additionalProperties $false
        Assert-Equal $schema.'$defs'.tree.additionalProperties $false
        Assert-Equal $schema.'$defs'.scope.additionalProperties $false
    }

    Invoke-SelfTest 'Production component closures remain blocked by schema' {
        $closureRoot = Join-Path $PSScriptRoot '..\drivers\win98\component-closures'
        $files = @(Get-ChildItem -LiteralPath $closureRoot -Filter '*.json' -File)
        Assert-Equal $files.Count 3
        foreach ($file in $files) {
            $manifest = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            Assert-Equal $manifest.status 'blocked'
            switch ([int]$manifest.schema) {
                1 {
                    Assert-Equal @($manifest.notices).Count 0
                    Assert-Equal @($manifest.files).Count 0
                }
                2 {
                    if ([string]::IsNullOrWhiteSpace([string]$manifest.reason) -or
                        $manifest.source_prefixes -isnot [Array] -or
                        $manifest.license_evidence -isnot [Array] -or
                        $manifest.files -isnot [Array]) {
                        throw "Blocked schema-2 closure '$($file.Name)' has invalid reviewed rows."
                    }
                    $expectedProperties = @(
                        '_spdx', 'schema', 'status', 'reason', 'upstream_name',
                        'owning_commit', 'source_prefixes', 'license_evidence',
                        'files'
                    )
                    $actualProperties = @($manifest.PSObject.Properties.Name)
                    if ($actualProperties.Count -ne $expectedProperties.Count) {
                        throw "Blocked schema-2 closure '$($file.Name)' has an unexpected root shape."
                    }
                    foreach ($property in $expectedProperties) {
                        if ($actualProperties -cnotcontains $property) {
                            throw "Blocked schema-2 closure '$($file.Name)' is missing root property '$property'."
                        }
                    }
                }
                default {
                    throw "Unsupported production component-closure schema '$($manifest.schema)'."
                }
            }
        }
    }

    Invoke-FixtureTest 'A complete generated-output lock verifies' {
        $output = @(Invoke-Verification)
        Assert-Equal ($output -join [Environment]::NewLine) `
            "Verified generated-output lock 'fixture-generated' with 2 generator inputs and 2 outputs."
    }

    Invoke-FixtureTest 'The canonical tree digest is creation-order independent' {
        $firstHash = (Get-Content -Raw $script:LockPath | ConvertFrom-Json).output_tree.sha256
        Write-FixtureOutputs -ReverseCreation
        $lock = New-GeneratedLock
        Assert-Equal $lock.output_tree.sha256 $firstHash
        Write-JsonFile $script:LockPath $lock
        Invoke-Verification | Out-Null
    }

    Invoke-FixtureTest 'The canonical tree digest matches a fixed known-answer vector' {
        [IO.File]::WriteAllBytes(
            (Join-Path $script:GeneratedRoot 'include\generated.h'),
            (New-Object byte[] 0)
        )
        [IO.File]::WriteAllBytes(
            (Join-Path $script:GeneratedRoot 'src\generated.c'),
            [Text.Encoding]::ASCII.GetBytes('abc')
        )
        $lock = New-GeneratedLock
        $lock.outputs = @(
            [ordered]@{
                relative_path = 'include/generated.h'
                bytes = [UInt64]0
                sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
                license_expression = 'MIT'
                notice_id = 'fixture-license'
            },
            [ordered]@{
                relative_path = 'src/generated.c'
                bytes = [UInt64]3
                sha256 = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
                license_expression = 'MIT'
                notice_id = 'fixture-license'
            }
        )
        $lock.output_tree = [ordered]@{
            file_count = [UInt64]2
            directory_count = [UInt64]2
            total_entries = [UInt64]4
            aggregate_bytes = [UInt64]3
            maximum_file_bytes = [UInt64]3
            maximum_path_bytes = [UInt64]19
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'
            sha256 = '0b2691b4a30d1e1eaa421b9ad14eeb40752cf28b82cf9f613f7cbc9baca196fe'
        }
        Write-JsonFile $script:LockPath $lock
        Invoke-Verification | Out-Null
    }

    Invoke-FixtureTest 'A blocked component closure fails closed' {
        $closure = New-ReadyClosure
        $closure.status = 'blocked'
        $closure.reason = 'Review incomplete.'
        $closure.notices = @()
        $closure.files = @()
        Write-Closure $closure
        Write-JsonFile $script:LockPath (New-GeneratedLock)
        Assert-Throws { Invoke-Verification } 'not ready'
    }

    Invoke-FixtureTest 'The component closure SHA-256 is binding' {
        $lock = New-GeneratedLock
        $lock.component.closure_manifest.sha256 = '0' * 64
        Write-JsonFile $script:LockPath $lock
        Write-UpstreamLock -ClosureHash ('0' * 64)
        Assert-Throws { Invoke-Verification } 'manifest SHA-256 mismatch'
    }

    Invoke-FixtureTest 'The component upstream identity is binding' {
        $lock = New-GeneratedLock
        $lock.component.upstream_name = 'different'
        Write-JsonFile $script:LockPath $lock
        Write-UpstreamLock -Name 'different'
        Assert-Throws { Invoke-Verification } 'upstream identity mismatch'
    }

    Invoke-FixtureTest 'The component owning commit is binding' {
        $lock = New-GeneratedLock
        $lock.component.owning_commit = '0' * 40
        Write-JsonFile $script:LockPath $lock
        Write-UpstreamLock -Commit ('0' * 40)
        Assert-Throws { Invoke-Verification } 'owning commit mismatch'
    }

    Invoke-FixtureTest 'The component repository origin is binding' {
        $lock = New-GeneratedLock
        $lock.component.repository = 'https://example.invalid/different.git'
        Write-JsonFile $script:LockPath $lock
        Write-UpstreamLock -Repository $lock.component.repository
        Assert-Throws { Invoke-Verification } 'origin does not match'
    }

    Invoke-FixtureTest 'The authoritative upstream row binds component provenance' {
        $contents = [IO.File]::ReadAllText($script:UpstreamLockPath).Replace(
            'component-closures/fixture.json',
            'component-closures/different.json'
        )
        [IO.File]::WriteAllText(
            $script:UpstreamLockPath,
            $contents,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } `
            'does not match its authoritative upstream lock row'
    }

    Invoke-FixtureTest 'Authoritative upstream rows require exactly nine fields' {
        $contents = [IO.File]::ReadAllText($script:UpstreamLockPath).Replace(
            "`tfixture-component`n",
            "`tfixture-component`textra-field`n"
        )
        [IO.File]::WriteAllText(
            $script:UpstreamLockPath,
            $contents,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } `
            'data row 1 has 10 fields; exactly 9 are required'
    }

    Invoke-FixtureTest 'Only plain HTTPS component repositories are accepted' {
        $lock = New-GeneratedLock
        $lock.component.repository = 'file:///C:/fixture'
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'plain HTTPS URL'
    }

    Invoke-FixtureTest 'A dirty component checkout is rejected' {
        $path = Join-Path $script:Checkout 'generator\build.py'
        $original = [IO.File]::ReadAllBytes($path)
        try {
            [IO.File]::AppendAllText($path, 'dirty')
            Assert-Throws { Invoke-Verification } 'has local changes'
        }
        finally {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }

    Invoke-FixtureTest 'A final origin recheck detects checkout mutation' {
        $checkout = $script:Checkout
        $originalOrigin = $script:Origin
        $changedOrigin = 'https://example.invalid/changed-during-verification.git'
        $configPath = Join-Path $checkout '.git\config'
        $originalConfig = [IO.File]::ReadAllBytes($configPath)
        $callback = {
            $config = [IO.File]::ReadAllText($configPath)
            $changedConfig = $config.Replace($originalOrigin, $changedOrigin)
            if ($changedConfig -ceq $config) {
                throw 'Unable to locate the fixture origin in Git config.'
            }
            [IO.File]::WriteAllText(
                $configPath,
                $changedConfig,
                [Text.UTF8Encoding]::new($false)
            )
        }.GetNewClosure()
        try {
            Assert-Throws {
                Invoke-Verification -BeforeFinalCheckoutCheck $callback
            } 'checkout changed during generated-output verification'
        }
        finally {
            [IO.File]::WriteAllBytes($configPath, $originalConfig)
        }
    }

    Invoke-FixtureTest 'The final output recheck detects output mutation' {
        $path = Join-Path $script:GeneratedRoot 'src\generated.c'
        $original = [IO.File]::ReadAllBytes($path)
        $callback = {
            [IO.File]::AppendAllText($path, 'changed-during-verification')
        }.GetNewClosure()
        try {
            Assert-Throws {
                Invoke-Verification -BeforeFinalCheckoutCheck $callback
            } 'Generated tree stability'
        }
        finally {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }

    Invoke-FixtureTest 'The final root recheck rejects a substituted generated-root junction' {
        $generatedRoot = $script:GeneratedRoot
        $backup = Join-Path $testRoot 'generated-original'
        $target = Join-Path $testRoot 'generated-junction-target'
        Copy-Item -LiteralPath $generatedRoot -Destination $target -Recurse
        $callback = {
            [IO.Directory]::Move($generatedRoot, $backup)
            New-Item -ItemType Junction -Path $generatedRoot -Target $target | Out-Null
        }.GetNewClosure()
        try {
            Assert-Throws {
                Invoke-Verification -BeforeFinalCheckoutCheck $callback
            } 'reparse point'
        }
        finally {
            if (Test-Path -LiteralPath $backup -PathType Container) {
                if (Test-Path -LiteralPath $generatedRoot) {
                    $junction = Get-Item -LiteralPath $generatedRoot -Force
                    if (($junction.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        throw "Refusing to replace non-junction test path '$generatedRoot'."
                    }
                    [IO.Directory]::Delete($generatedRoot)
                }
                [IO.Directory]::Move($backup, $generatedRoot)
            }
            if (Test-Path -LiteralPath $target -PathType Container) {
                [IO.Directory]::Delete($target, $true)
            }
        }
    }

    Invoke-FixtureTest 'The final root recheck rejects a substituted metadata-root junction' {
        $metadataRoot = $script:MetadataRoot
        $backup = Join-Path $testRoot 'metadata-original'
        $target = Join-Path $testRoot 'metadata-junction-target'
        Copy-Item -LiteralPath $metadataRoot -Destination $target -Recurse
        $callback = {
            [IO.Directory]::Move($metadataRoot, $backup)
            New-Item -ItemType Junction -Path $metadataRoot -Target $target | Out-Null
        }.GetNewClosure()
        try {
            Assert-Throws {
                Invoke-Verification -BeforeFinalCheckoutCheck $callback
            } 'reparse point'
        }
        finally {
            if (Test-Path -LiteralPath $backup -PathType Container) {
                if (Test-Path -LiteralPath $metadataRoot) {
                    $junction = Get-Item -LiteralPath $metadataRoot -Force
                    if (($junction.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        throw "Refusing to replace non-junction test path '$metadataRoot'."
                    }
                    [IO.Directory]::Delete($metadataRoot)
                }
                [IO.Directory]::Move($backup, $metadataRoot)
            }
            if (Test-Path -LiteralPath $target -PathType Container) {
                [IO.Directory]::Delete($target, $true)
            }
        }
    }

    Invoke-FixtureTest 'The final metadata recheck detects lock mutation' {
        $path = $script:LockPath
        $original = [IO.File]::ReadAllBytes($path)
        $callback = {
            [IO.File]::AppendAllText($path, "`n")
        }.GetNewClosure()
        try {
            Assert-Throws {
                Invoke-Verification -BeforeFinalCheckoutCheck $callback
            } 'Generated-output lock changed during verification'
        }
        finally {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }

    Invoke-FixtureTest 'The final metadata recheck detects closure mutation' {
        $path = $script:ClosurePath
        $original = [IO.File]::ReadAllBytes($path)
        $callback = {
            [IO.File]::AppendAllText($path, "`n")
        }.GetNewClosure()
        try {
            Assert-Throws {
                Invoke-Verification -BeforeFinalCheckoutCheck $callback
            } 'Component closure manifest changed during verification'
        }
        finally {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }

    Invoke-FixtureTest 'The final metadata recheck detects upstream mutation' {
        $path = $script:UpstreamLockPath
        $original = [IO.File]::ReadAllBytes($path)
        $callback = {
            [IO.File]::AppendAllText($path, "`n")
        }.GetNewClosure()
        try {
            Assert-Throws {
                Invoke-Verification -BeforeFinalCheckoutCheck $callback
            } 'Authoritative upstream lock changed during verification'
        }
        finally {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }

    Invoke-FixtureTest 'Every generator input must exactly match its closure row' {
        $lock = New-GeneratedLock
        $lock.generator_inputs[0].bytes = [UInt64]$lock.generator_inputs[0].bytes + 1
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'does not exactly match'
    }

    Invoke-FixtureTest 'Every output notice must exactly match its closure row' {
        $lock = New-GeneratedLock
        $lock.notices[0].sha256 = '0' * 64
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'does not exactly match'
    }

    Invoke-FixtureTest 'A closure file cannot escape its source prefix' {
        $closure = New-ReadyClosure
        $closure.files[0].source_prefix_id = 'templates'
        Write-Closure $closure
        Write-JsonFile $script:LockPath (New-GeneratedLock)
        Assert-Throws { Invoke-Verification } 'escapes its source prefix'
    }

    Invoke-FixtureTest 'A ready closure cannot retain an unused source prefix' {
        $closure = New-ReadyClosure
        $closure.source_prefixes += [ordered]@{
            id = 'unused'
            relative_path = 'unused'
            mode = 'subtree'
        }
        Write-Closure $closure
        Write-JsonFile $script:LockPath (New-GeneratedLock)
        Assert-Throws { Invoke-Verification } 'unused notice or source prefix'
    }

    Invoke-FixtureTest 'A ready closure cannot retain an unused notice' {
        $closure = New-ReadyClosure
        $closure.notices += [ordered]@{
            id = 'unused-notice'
            relative_path = $script:NoticeDescriptor.RelativePath
            git_blob = $script:NoticeDescriptor.GitBlob
            bytes = $script:NoticeDescriptor.Bytes
            sha256 = $script:NoticeDescriptor.Sha256
            license_expression = 'MIT'
        }
        Write-Closure $closure
        Write-JsonFile $script:LockPath (New-GeneratedLock)
        Assert-Throws { Invoke-Verification } 'unused notice or source prefix'
    }

    Invoke-FixtureTest 'The canonical verifier checks non-input closure rows' {
        $closure = New-ReadyClosure
        $closure.source_prefixes += [ordered]@{
            id = 'root-files'
            relative_path = '.'
            mode = 'exact-root-files'
        }
        $fabricated = New-ClosureFile $script:NoticeDescriptor `
            'root-files' 'support'
        $fabricated.sha256 = '0' * 64
        $closure.files += $fabricated
        Write-Closure $closure
        Write-JsonFile $script:LockPath (New-GeneratedLock)
        Assert-Throws { Invoke-Verification } "SHA-256 mismatch for 'NOTICE'"
    }

    Invoke-FixtureTest 'A generated output content mutation is rejected' {
        [IO.File]::AppendAllText(
            (Join-Path $script:GeneratedRoot 'src\generated.c'),
            'mutation'
        )
        Assert-Throws { Invoke-Verification } 'content mismatch'
    }

    Invoke-FixtureTest 'A missing generated output is rejected' {
        [IO.File]::Delete((Join-Path $script:GeneratedRoot 'src\generated.c'))
        Assert-Throws { Invoke-Verification } 'is missing'
    }

    Invoke-FixtureTest 'An unpinned generated file is rejected' {
        [IO.File]::WriteAllText(
            (Join-Path $script:GeneratedRoot 'extra.txt'),
            'extra',
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'missing or unpinned output files'
    }

    Invoke-FixtureTest 'An unpinned empty directory is rejected' {
        New-Item -ItemType Directory -Path (
            Join-Path $script:GeneratedRoot 'empty-extra'
        ) | Out-Null
        Assert-Throws { Invoke-Verification } 'missing or unpinned directories'
    }

    Invoke-FixtureTest 'A non-regular output is rejected' {
        $path = Join-Path $script:GeneratedRoot 'include\generated.h'
        [IO.File]::Delete($path)
        New-Item -ItemType Directory -Path $path | Out-Null
        Assert-Throws { Invoke-Verification } 'not a regular file'
    }

    Invoke-FixtureTest 'A reparse point in the generated tree is rejected' {
        $target = Join-Path $testRoot 'junction-target'
        $link = Join-Path $script:GeneratedRoot 'junction-extra'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try {
            Assert-Throws { Invoke-Verification } 'reparse point'
        }
        finally {
            if (Test-Path -LiteralPath $link) {
                Remove-Item -LiteralPath $link -Force
            }
        }
    }

    Invoke-FixtureTest 'The aggregate canonical tree digest is binding' {
        $lock = New-GeneratedLock
        $lock.output_tree.sha256 = '0' * 64
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Sha256 mismatch'
    }

    Invoke-FixtureTest 'Tree counts must agree with the exact output set' {
        $lock = New-GeneratedLock
        $lock.output_tree.file_count = 3
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'violates the declared output set'
    }

    Invoke-FixtureTest 'Output licenses must match their locked notices' {
        $lock = New-GeneratedLock
        $lock.outputs[0].license_expression = 'LGPL-2.1-or-later'
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Invalid license or notice binding'
    }

    Invoke-FixtureTest 'Traversal in an output path is rejected' {
        $lock = New-GeneratedLock
        $lock.outputs[0].relative_path = '../escape.c'
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Unsafe path component'
    }

    Invoke-FixtureTest 'Windows backslashes in portable paths are rejected' {
        $lock = New-GeneratedLock
        $lock.outputs[0].relative_path = 'include\generated.h'
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Unsafe relative path'
    }

    Invoke-FixtureTest 'Exact duplicate output paths are rejected' {
        $lock = New-GeneratedLock
        $lock.outputs = @($lock.outputs[0], $lock.outputs[0])
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Duplicate path'
    }

    Invoke-FixtureTest 'Case-folded output path collisions are rejected' {
        $lock = New-GeneratedLock
        $second = Get-OutputDescriptor 'src/generated.c'
        $second.relative_path = 'INCLUDE/GENERATED.H'
        $lock.outputs = @($lock.outputs[0], $second)
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Case-folded path collision'
    }

    Invoke-FixtureTest 'Windows 9x short-name suffixes are allocated per directory' {
        $lock = New-GeneratedLock
        $first = Get-OutputDescriptor 'include/generated.h'
        $second = Get-OutputDescriptor 'src/generated.c'
        $first.relative_path = 'abcdefghi.c'
        $second.relative_path = 'abcdefgjk.c'
        $lock.outputs = @($first, $second)
        [IO.File]::Move(
            (Join-Path $script:GeneratedRoot 'include\generated.h'),
            (Join-Path $script:GeneratedRoot 'abcdefghi.c')
        )
        [IO.File]::Move(
            (Join-Path $script:GeneratedRoot 'src\generated.c'),
            (Join-Path $script:GeneratedRoot 'abcdefgjk.c')
        )
        [IO.Directory]::Delete((Join-Path $script:GeneratedRoot 'include'))
        [IO.Directory]::Delete((Join-Path $script:GeneratedRoot 'src'))
        $lock.output_tree = Get-LockedTree $lock.outputs
        Write-JsonFile $script:LockPath $lock
        Invoke-Verification | Out-Null
    }

    Invoke-FixtureTest 'File and ancestor output path collisions are rejected' {
        $lock = New-GeneratedLock
        $first = Get-OutputDescriptor 'include/generated.h'
        $second = Get-OutputDescriptor 'src/generated.c'
        $first.relative_path = 'tree'
        $second.relative_path = 'tree/child.c'
        $lock.outputs = @($first, $second)
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'File/ancestor path collision'
    }

    Invoke-FixtureTest 'Generator input case collisions are rejected' {
        $lock = New-GeneratedLock
        $duplicate = New-ClosureFile $script:TemplateDescriptor 'templates' 'template'
        $duplicate.relative_path = 'GENERATOR/build.py'
        $lock.generator_inputs = @($lock.generator_inputs[0], $duplicate)
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Case-folded path collision'
    }

    Invoke-FixtureTest 'Traversal in the component closure link is rejected' {
        $lock = New-GeneratedLock
        $lock.component.closure_manifest.relative_path = `
            'component-closures/../component-closures/fixture.json'
        Write-JsonFile $script:LockPath $lock
        Write-UpstreamLock -ClosureRelativePath `
            $lock.component.closure_manifest.relative_path
        Assert-Throws { Invoke-Verification } 'Unsafe path component'
    }

    Invoke-FixtureTest 'Case-folded duplicate JSON properties are rejected' {
        $json = [IO.File]::ReadAllText($script:LockPath).Replace(
            '"schema":',
            '"SCHEMA": 1,' + "`n  " + '"schema":'
        )
        [IO.File]::WriteAllText(
            $script:LockPath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'Duplicate JSON property'
    }

    Invoke-FixtureTest 'Unknown root properties are rejected' {
        $lock = New-GeneratedLock
        $lock['unexpected'] = $true
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Unexpected property'
    }

    Invoke-FixtureTest 'Unknown nested properties are rejected' {
        $lock = New-GeneratedLock
        $lock.outputs[0]['unexpected'] = $true
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Unexpected property'
    }

    Invoke-FixtureTest 'A string cannot impersonate an integer byte count' {
        $lock = New-GeneratedLock
        $lock.outputs[0].bytes = '49'
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'must be a JSON integer'
    }

    Invoke-FixtureTest 'An object cannot impersonate the output array' {
        $lock = New-GeneratedLock
        $lock.outputs = [ordered]@{ relative_path = 'src/generated.c' }
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'bounded non-empty JSON array'
    }

    Invoke-FixtureTest 'A repository array cannot impersonate a string' {
        $lock = New-GeneratedLock
        $lock.component.repository = @($script:Origin)
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'Invalid component repository'
    }

    Invoke-FixtureTest 'Empty generator inputs fail closed' {
        $lock = New-GeneratedLock
        $lock.generator_inputs = @()
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'bounded non-empty JSON array'
    }

    Invoke-FixtureTest 'Uppercase digests are rejected' {
        $lock = New-GeneratedLock
        $lock.outputs[0].sha256 = $lock.outputs[0].sha256.ToUpperInvariant()
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'lowercase 64-character'
    }

    Invoke-FixtureTest 'Generator inputs must use deterministic ordinal order' {
        $lock = New-GeneratedLock
        [Array]::Reverse($lock.generator_inputs)
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'strict ordinal path order'
    }

    Invoke-FixtureTest 'Generated outputs must use deterministic ordinal order' {
        $lock = New-GeneratedLock
        [Array]::Reverse($lock.outputs)
        Write-JsonFile $script:LockPath $lock
        Assert-Throws { Invoke-Verification } 'strict ordinal path order'
    }

    Invoke-FixtureTest 'Unknown fields in the component closure are rejected' {
        $closure = New-ReadyClosure
        $closure['unexpected'] = $true
        Write-Closure $closure
        Write-JsonFile $script:LockPath (New-GeneratedLock)
        Assert-Throws { Invoke-Verification } 'Unexpected property'
    }

    Invoke-FixtureTest 'Malformed generated-output JSON is rejected' {
        [IO.File]::WriteAllText(
            $script:LockPath,
            '{',
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws { Invoke-Verification } 'Malformed generated-output lock JSON'
    }
}
finally {
    Remove-TestRoot $testRoot
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) generated-output lock tests failed."
}
Write-Output (
    'All {0} Windows 98 generated-output lock tests passed (shard {1}/{2}).' -f
        $script:ExecutedTests, ($TestShardIndex + 1), $TestShardCount
)

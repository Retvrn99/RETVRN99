# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$LockFile,
    [string]$PackageRoot,
    [string]$MesaCheckout = 'D:\src\retvrn99-win98\mesa9x',
    [switch]$PolicyAudit,
    [scriptblock]$BeforeFinalMetadataCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolchainMaximumJsonBytes = [UInt64](1024 * 1024)
$script:ToolchainMaximumArchiveBytes = [UInt64](32 * 1024 * 1024)
$script:ToolchainMaximumSignatureBytes = [UInt64](64 * 1024)
$script:ToolchainMaximumPathBytes = 512
$script:ToolchainExpectedManifestSha256 = `
    '57ce0f2b144925889b2d03093e9dc5aba09654f8ef8f6d1758496528e39e9b38'
$script:ToolchainExpectedSchemaSha256 = `
    'a45920aa309e945b5cb316308ed9e8e6268528e3ec8f7893a80a65ac9adeb6c3'
$script:ToolchainExpectedRepository = `
    'https://github.com/JHRobotics/mesa9x.git'
$script:ToolchainExpectedCommit = `
    '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$script:ToolchainExpectedRecipeBlob = `
    '68b2fd13d08ae0ce4276cb1f720ee9bbb1cd54e9'
$script:ToolchainExpectedRecipeSha256 = `
    '9ad77b1fe55e4097621dbefeffe989fb00f3c354320ce6521d69f8efd8a44dce'

. (Join-Path $PSScriptRoot 'strict-json.ps1')

function Assert-ToolchainSafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][object]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$RequireLeaf
    )

    if ($RelativePath -isnot [string] -or
        [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        [Text.Encoding]::UTF8.GetByteCount($RelativePath) -gt
            $script:ToolchainMaximumPathBytes) {
        throw "Unsafe relative path '$RelativePath' in $Name."
    }
    if ($RequireLeaf -and $RelativePath.Contains('/')) {
        throw "$Name must be one package-directory filename."
    }
    foreach ($component in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -in @('.', '..') -or
            $component -match '[\x00-\x1f:*?"<>|]' -or
            $component.EndsWith('.') -or
            $component.EndsWith(' ') -or
            $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "Unsafe path component '$component' in $Name."
        }
    }
}

function Assert-ToolchainDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-GswNoReparseAncestor -Path $fullPath -Name $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one ordinary directory."
    }
    return $item.FullName
}

function ConvertTo-ToolchainProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
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
    return $builder.ToString()
}

function Get-ToolchainNormalizedRepository {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $normalized = $Repository.TrimEnd('/')
    if ($normalized.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized.ToLowerInvariant()
}

function Get-ToolchainNulItems {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Text.Length -eq 0) {
        return @()
    }
    if ($Text[$Text.Length - 1] -ne [char]0) {
        throw "$Name is not NUL terminated."
    }
    $items = @($Text.Substring(0, $Text.Length - 1).Split([char]0))
    if (@($items | Where-Object { $_.Length -eq 0 }).Count -ne 0) {
        throw "$Name contains an empty value."
    }
    return @($items)
}

function Get-ToolchainEnvironmentEntry {
    param([Parameter(Mandatory = $true)][string]$Name)

    $item = Get-Item -LiteralPath ('Env:' + $Name) -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [pscustomobject]@{ Present = $false; Name = $Name; Value = $null }
    }
    return [pscustomobject]@{
        Present = $true
        Name = [string]$item.Name
        Value = [string]$item.Value
    }
}

function Restore-ToolchainEnvironmentEntry {
    param(
        [Parameter(Mandatory = $true)][string]$LookupName,
        [Parameter(Mandatory = $true)]$Entry
    )

    Remove-Item -LiteralPath ('Env:' + $LookupName) -ErrorAction SilentlyContinue
    if ($Entry.Present) {
        Set-Item -LiteralPath ('Env:' + [string]$Entry.Name) `
            -Value ([string]$Entry.Value)
    }
}

function Start-ToolchainGitProcess {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $effectivePath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
        [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
        [Environment]::SetEnvironmentVariable('Path', $null, 'Process')
        if ($null -ne $effectivePath) {
            [Environment]::SetEnvironmentVariable('PATH', $effectivePath, 'Process')
        }
    }
    $removeNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE', 'GIT_CONFIG_COUNT',
        'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL',
        'GIT_CONFIG_NOSYSTEM', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_SHALLOW_FILE',
        'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE', 'GIT_NAMESPACE',
        'GIT_ATTR_SOURCE', 'GIT_EXEC_PATH', 'GIT_LITERAL_PATHSPECS',
        'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS',
        'GIT_ICASE_PATHSPECS', 'GIT_REDIRECT_STDERR'
    )) {
        [void]$removeNames.Add($name)
    }
    foreach ($item in @(Get-ChildItem Env:)) {
        if ($item.Name.StartsWith('GIT_CONFIG_KEY_',
                [StringComparison]::OrdinalIgnoreCase) -or
            $item.Name.StartsWith('GIT_CONFIG_VALUE_',
                [StringComparison]::OrdinalIgnoreCase) -or
            $item.Name.StartsWith('GIT_TRACE',
                [StringComparison]::OrdinalIgnoreCase)) {
            [void]$removeNames.Add([string]$item.Name)
        }
    }
    $childValues = [ordered]@{
        GIT_OPTIONAL_LOCKS = '0'
        GIT_NO_REPLACE_OBJECTS = '1'
        GIT_NO_LAZY_FETCH = '1'
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            'NUL'
        } else {
            '/dev/null'
        }
    }
    $saved = @{}
    foreach ($name in @($removeNames) + @($childValues.Keys)) {
        if (-not $saved.ContainsKey($name)) {
            $saved[$name] = Get-ToolchainEnvironmentEntry $name
        }
    }
    try {
        foreach ($name in $removeNames) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        }
        foreach ($entry in $childValues.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable(
                [string]$entry.Key, [string]$entry.Value, 'Process'
            )
        }
        return $Process.Start()
    }
    finally {
        foreach ($name in $saved.Keys) {
            Restore-ToolchainEnvironmentEntry $name $saved[$name]
        }
    }
}

function Invoke-ToolchainGit {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $gitCommands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($gitCommands.Count -eq 0) {
        throw 'git is unavailable for the local Mesa identity audit.'
    }
    $gitPath = [IO.Path]::GetFullPath($gitCommands[0].Source)
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $gitPath)
        $directPath = Join-Path $gitRoot 'mingw64\bin\git.exe'
        if (Test-Path -LiteralPath $directPath -PathType Leaf) {
            $gitPath = [IO.Path]::GetFullPath($directPath)
        }
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $gitPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (@(
        '--no-pager', '--no-replace-objects',
        '-c', 'core.quotePath=false',
        '-c', 'core.fsmonitor=false',
        '-c', 'core.untrackedCache=false',
        '-c', "safe.directory=$Checkout",
        '-C', $Checkout
    ) + $Arguments | ForEach-Object {
        ConvertTo-ToolchainProcessArgument ([string]$_)
    }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not (Start-ToolchainGitProcess $process)) {
            throw 'Unable to start git for the local Mesa identity audit.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw "git $($Arguments -join ' ') exceeded its five-second bound."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed: $($stderr.Trim())"
        }
        if ([Text.Encoding]::UTF8.GetByteCount($stdout) -gt 1048576 -or
            [Text.Encoding]::UTF8.GetByteCount($stderr) -gt 1048576) {
            throw "git $($Arguments -join ' ') exceeded its output bound."
        }
        return $stdout.TrimEnd("`r", "`n")
    }
    finally {
        $process.Dispose()
    }
}

function Assert-ToolchainMesaIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][object]$Recipe
    )

    $checkoutPath = Assert-ToolchainDirectory $Checkout 'Mesa checkout'
    $gitDirectoryPath = Assert-ToolchainDirectory (
        Join-Path $checkoutPath '.git'
    ) 'Mesa Git directory'
    $worktreeConfigs = @(Get-ChildItem -LiteralPath $gitDirectoryPath -Force |
        Where-Object { $_.Name -ieq 'config.worktree' })
    if ($worktreeConfigs.Count -ne 0) {
        throw 'Mesa checkout cannot use worktree-specific Git config.'
    }
    $localConfigPath = Join-Path $gitDirectoryPath 'config'
    $configBefore = Read-GswBoundedFileSnapshot -Path $localConfigPath `
        -Name 'Mesa local Git config' -MaximumBytes 1048576
    $originText = Invoke-ToolchainGit $checkoutPath @(
        'config', '--file', $localConfigPath, '--no-includes', '--null',
        '--get-all', 'remote.origin.url'
    )
    $origins = @(Get-ToolchainNulItems $originText 'Mesa local origin list')
    if ($origins.Count -ne 1 -or
        $origins[0] -cne $origins[0].Trim() -or
        [string]::IsNullOrWhiteSpace($origins[0]) -or
        (Get-ToolchainNormalizedRepository $origins[0]) -cne
        (Get-ToolchainNormalizedRepository $script:ToolchainExpectedRepository)) {
        throw 'Mesa checkout must have exactly one unpadded local origin URL.'
    }
    $configNameText = Invoke-ToolchainGit $checkoutPath @(
        'config', '--file', $localConfigPath, '--no-includes', '--null',
        '--name-only', '--list'
    )
    foreach ($configName in @(
        Get-ToolchainNulItems $configNameText 'Mesa local config-name list'
    )) {
        if ($configName -match
            '^(?i:include\.path|includeif\..*\.path|filter\..*\.(?:clean|smudge|process|required)|extensions\.(?:partialclone|worktreeconfig)|remote\..*\.(?:partialclonefilter|promisor|receivepack|uploadpack|vcs)|url\..*\.(?:insteadof|pushinsteadof)|protocol\..*\.allow|core\.gitproxy)$') {
            throw "Mesa local Git config contains forbidden key '$configName'."
        }
    }
    $root = Invoke-ToolchainGit $checkoutPath @('rev-parse', '--show-toplevel')
    if ([IO.Path]::GetFullPath($root) -cne $checkoutPath) {
        throw "Mesa checkout root mismatch: $root"
    }
    $head = Invoke-ToolchainGit $checkoutPath @('rev-parse', '--verify', 'HEAD')
    if ($head -cne $script:ToolchainExpectedCommit) {
        throw "Mesa checkout HEAD '$head' is not the pinned commit."
    }
    $status = Invoke-ToolchainGit $checkoutPath @(
        'status', '--porcelain=v1', '--untracked-files=all',
        '--ignored=matching',
        '--ignore-submodules=all'
    )
    if ($status.Length -ne 0) {
        throw 'Mesa checkout is not clean.'
    }
    $recipeIndexState = Invoke-ToolchainGit $checkoutPath @(
        'ls-files', '-v', '--', [string]$Recipe.relative_path
    )
    if ($recipeIndexState -cne "H $($Recipe.relative_path)") {
        throw 'Mesa generator recipe has hidden or unexpected index state.'
    }
    $blob = Invoke-ToolchainGit $checkoutPath @(
        'rev-parse', "HEAD:$($Recipe.relative_path)"
    )
    if ($blob -cne $script:ToolchainExpectedRecipeBlob -or
        $blob -cne [string]$Recipe.git_blob) {
        throw 'Mesa generator recipe blob identity does not match the lock.'
    }

    Assert-ToolchainSafeRelativePath $Recipe.relative_path `
        'component.generator_recipe.relative_path'
    $recipePath = [IO.Path]::GetFullPath((Join-Path $checkoutPath (
        ([string]$Recipe.relative_path).Replace(
            '/', [IO.Path]::DirectorySeparatorChar
        )
    )))
    $checkoutPrefix = $checkoutPath.TrimEnd([char[]]'\/') +
        [IO.Path]::DirectorySeparatorChar
    if (-not $recipePath.StartsWith(
            $checkoutPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Mesa generator recipe escapes its checkout.'
    }
    $snapshot = Read-GswBoundedFileSnapshot -Path $recipePath `
        -Name 'Mesa generator recipe' -MaximumBytes 1048576
    if ($snapshot.Length -ne [UInt64]$Recipe.bytes -or
        $snapshot.Length -ne 13288 -or
        $snapshot.Sha256 -cne [string]$Recipe.sha256 -or
        $snapshot.Sha256 -cne $script:ToolchainExpectedRecipeSha256) {
        throw 'Mesa generator recipe bytes do not match the lock.'
    }
    $configAfter = Read-GswBoundedFileSnapshot -Path $localConfigPath `
        -Name 'Mesa local Git config' -MaximumBytes 1048576
    if ($configBefore.Length -ne $configAfter.Length -or
        $configBefore.Sha256 -cne $configAfter.Sha256) {
        throw 'Mesa local Git config changed during verification.'
    }
}

function Assert-ToolchainManifestPaths {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    Assert-ToolchainSafeRelativePath `
        $Manifest.schema_definition.relative_path 'schema_definition.relative_path' `
        -RequireLeaf
    Assert-ToolchainSafeRelativePath `
        $Manifest.component.generator_recipe.relative_path `
        'component.generator_recipe.relative_path'

    $declaredNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($package in @($Manifest.packages)) {
        Assert-ToolchainSafeRelativePath $package.archive.relative_path `
            "package '$($package.name)' archive" -RequireLeaf
        if (-not $declaredNames.Add([string]$package.archive.relative_path)) {
            throw "Duplicate package filename '$($package.archive.relative_path)'."
        }
        Assert-ToolchainSafeRelativePath $package.signature.relative_path `
            "package '$($package.name)' signature" -RequireLeaf
        if ([string]$package.signature.relative_path -cne
            ([string]$package.archive.relative_path + '.sig')) {
            throw "Package '$($package.name)' signature path is not canonical."
        }
        if ([bool]$package.signature.present) {
            if (-not $declaredNames.Add([string]$package.signature.relative_path)) {
                throw "Duplicate package filename '$($package.signature.relative_path)'."
            }
        }
    }
    foreach ($provider in @($Manifest.package_policy.virtual_providers)) {
        Assert-ToolchainSafeRelativePath $provider.relative_path `
            "virtual provider '$($provider.dependency)'"
    }
    foreach ($tool in @($Manifest.expected_tools)) {
        Assert-ToolchainSafeRelativePath $tool.relative_path `
            "expected tool '$($tool.name)'"
    }
}

function Read-ToolchainManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $manifestSnapshot = Read-GswStrictJsonFileSnapshot -Path $Path `
        -Name 'Mesa generator toolchain lock' `
        -MaximumBytes $script:ToolchainMaximumJsonBytes
    $manifest = $manifestSnapshot.Value

    Assert-ToolchainManifestPaths $manifest
    if ($manifestSnapshot.Sha256 -cne $script:ToolchainExpectedManifestSha256) {
        throw 'Mesa generator toolchain lock does not match its immutable semantic contract.'
    }

    $manifestDirectory = Split-Path -Parent $manifestSnapshot.Path
    $schemaPath = [IO.Path]::GetFullPath((Join-Path $manifestDirectory (
        [string]$manifest.schema_definition.relative_path
    )))
    $directoryPrefix = [IO.Path]::GetFullPath($manifestDirectory).TrimEnd(
        [char[]]'\/'
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $schemaPath.StartsWith(
            $directoryPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Schema definition escapes the lock directory.'
    }
    $schemaSnapshot = Read-GswStrictJsonFileSnapshot -Path $schemaPath `
        -Name 'Mesa generator toolchain schema' `
        -MaximumBytes $script:ToolchainMaximumJsonBytes
    if ($schemaSnapshot.Sha256 -cne
            [string]$manifest.schema_definition.sha256 -or
        $schemaSnapshot.Sha256 -cne $script:ToolchainExpectedSchemaSha256) {
        throw 'Mesa generator toolchain schema hash does not match the lock.'
    }
    return $manifest
}

function Assert-ToolchainPackageInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $rootPath = Assert-ToolchainDirectory $Root 'Package root'
    $expected = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($package in @($Manifest.packages)) {
        $archiveName = [string]$package.archive.relative_path
        if ($expected.ContainsKey($archiveName)) {
            throw "Duplicate declared package file '$archiveName'."
        }
        $expected.Add($archiveName, [pscustomobject]@{
            Name = "package '$($package.name)' archive"
            MaximumBytes = $script:ToolchainMaximumArchiveBytes
            Bytes = [UInt64]$package.archive.bytes
            Sha256 = [string]$package.archive.sha256
        })
        if ([bool]$package.signature.present) {
            $signatureName = [string]$package.signature.relative_path
            if ($expected.ContainsKey($signatureName)) {
                throw "Duplicate declared package file '$signatureName'."
            }
            $expected.Add($signatureName, [pscustomobject]@{
                Name = "package '$($package.name)' signature"
                MaximumBytes = $script:ToolchainMaximumSignatureBytes
                Bytes = [UInt64]$package.signature.bytes
                Sha256 = [string]$package.signature.sha256
            })
        }
        else {
            $undeclaredSignature = Join-Path $rootPath (
                [string]$package.signature.relative_path
            )
            if (Test-Path -LiteralPath $undeclaredSignature) {
                throw "Missing signature for package '$($package.name)' must remain absent."
            }
        }
    }

    foreach ($auditPass in 1..2) {
        $actual = [Collections.Generic.Dictionary[string, string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($entry in Get-ChildItem -LiteralPath $rootPath -Force) {
            if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($entry.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "Package root contains non-file entry '$($entry.Name)'."
            }
            Assert-ToolchainSafeRelativePath $entry.Name 'package-root entry' `
                -RequireLeaf
            if ($actual.ContainsKey($entry.Name)) {
                throw "Package root contains duplicate filename '$($entry.Name)'."
            }
            if (-not $expected.ContainsKey($entry.Name)) {
                throw "Package root contains undeclared file '$($entry.Name)'."
            }
            $actual.Add($entry.Name, $entry.FullName)
        }
        if ($actual.Count -ne $expected.Count) {
            $missing = @($expected.Keys | Where-Object {
                -not $actual.ContainsKey($_)
            })
            throw "Package root is missing declared file '$($missing[0])'."
        }

        foreach ($name in $expected.Keys) {
            $declaration = $expected[$name]
            $snapshot = Read-GswBoundedFileSnapshot -Path $actual[$name] `
                -Name $declaration.Name -MaximumBytes $declaration.MaximumBytes
            if ($snapshot.Length -ne $declaration.Bytes -or
                $snapshot.Sha256 -cne $declaration.Sha256) {
                throw "$($declaration.Name) bytes do not match the lock."
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot `
        '..\drivers\win98\mesa-generator-toolchain-lock.json'
}
$toolchainLock = Read-ToolchainManifest $LockFile

if (-not $PolicyAudit) {
    throw 'Mesa generator toolchain is blocked; only -PolicyAudit is permitted.'
}
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    throw '-PackageRoot is required for the blocked policy audit.'
}

Assert-ToolchainMesaIdentity -Checkout $MesaCheckout `
    -Recipe $toolchainLock.component.generator_recipe
Assert-ToolchainPackageInventory -Root $PackageRoot -Manifest $toolchainLock
if ($null -ne $BeforeFinalMetadataCheck) {
    & $BeforeFinalMetadataCheck
}
$toolchainLock = Read-ToolchainManifest $LockFile
Assert-ToolchainMesaIdentity -Checkout $MesaCheckout `
    -Recipe $toolchainLock.component.generator_recipe
Assert-ToolchainPackageInventory -Root $PackageRoot -Manifest $toolchainLock

$required = @($toolchainLock.packages | Where-Object role -CEQ 'required').Count
$reserved = @(
    $toolchainLock.packages | Where-Object role -CEQ 'reserved-unselected'
).Count
$signaturesPresent = @(
    $toolchainLock.packages | Where-Object { [bool]$_.signature.present }
).Count
$signaturesMissing = $toolchainLock.packages.Count - $signaturesPresent
$proofNames = @(
    'trust_root', 'extractor', 'extracted_tree',
    'runtime', 'commands', 'generated_outputs'
)
$proofsProven = @($proofNames | Where-Object {
    [bool]$toolchainLock.proofs.$_.proven
}).Count

Write-Output (
    'Policy-audited blocked Mesa generator toolchain lock: ' +
    "packages=$($toolchainLock.packages.Count) required=$required " +
    "reserved=$reserved signatures_present=$signaturesPresent " +
    "signatures_missing=$signaturesMissing proofs=$proofsProven/6; unusable."
)

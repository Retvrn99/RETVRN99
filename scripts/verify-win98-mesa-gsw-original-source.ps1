# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MesaCheckout,
    [string]$LockFile,
    [scriptblock]$BeforeFinalStabilityCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GswMesaExpectedRepository = 'https://github.com/JHRobotics/mesa9x.git'
$script:GswMesaExpectedCommit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$script:GswMesaExpectedSchemaSha256 = `
    'a7c0520ed4ae206f8b5fd5bad971005d0e57e067b114ba45ac444f9d9324ced8'
$script:GswMesaMaximumMetadataBytes = [UInt64]65536
$script:GswMesaMaximumInputBytes = [UInt64]1048576
$script:GswMesaMaximumOutputBytes = [UInt64]65536
$script:GswMesaUtf8 = [Text.UTF8Encoding]::new($false, $true)

. (Join-Path $PSScriptRoot 'strict-json.ps1')

$script:GswMesaExpectedInputs = @(
    [pscustomobject]@{
        source_relative_path = 'mesa-23.1.x/src/gallium/frontends/nine/nine_memory_helper.h'
        git_blob = '8e4cde122369b91e02f205f6d7884121dea2046f'
        bytes = [UInt64]3407
        sha256 = '882c8bb2598f1beb3de9fb4733f80a9340e9ab4418304ae7eee64230e3f7ec74'
        license_expression = 'MIT'
        role = 'nine-interface-declarations'
    },
    [pscustomobject]@{
        source_relative_path = 'mesa-23.1.x/src/gallium/frontends/nine/device9.c'
        git_blob = '10f2e7733e2aa2ebc34ab50a01f260b5996a0364'
        bytes = [UInt64]156589
        sha256 = '67fc2f66e192c32c7e89634556c571e3dcf7b2735344fb0df1cc5630f9b8d968'
        license_expression = 'MIT'
        role = 'nine-allocator-lifecycle-caller'
    },
    [pscustomobject]@{
        source_relative_path = 'mesa-23.1.x/src/gallium/frontends/nine/surface9.c'
        git_blob = '93d5d6577395752e4e0ff851d58850d38dc165fa'
        bytes = [UInt64]33934
        sha256 = 'c2698c513b1c0994de826265ac3408b2a0da8ae85923ed64c2b9fbe1bf279191'
        license_expression = 'MIT'
        role = 'nine-pointer-lifetime-caller'
    },
    [pscustomobject]@{
        source_relative_path = 'mesa-23.1.x/src/gallium/frontends/nine/texture9.c'
        git_blob = '5843e900dddffd6d11f8bb14b9123212728555ac'
        bytes = [UInt64]14606
        sha256 = '95ce21274e423f764895efe27356f7036e0b29354b9efd5776225443831dd10c'
        license_expression = 'MIT'
        role = 'nine-suballocation-caller'
    },
    [pscustomobject]@{
        source_relative_path = 'mesa-23.1.x/src/gallium/frontends/nine/cubetexture9.c'
        git_blob = 'b78da40239e5de99fab453679244bfbb2dc9728f'
        bytes = [UInt64]13856
        sha256 = 'c77f7bd87194e4dde5eca93ed9c5584c8e8ae15198acd49bafe998e698d98dea'
        license_expression = 'MIT'
        role = 'nine-suballocation-caller'
    },
    [pscustomobject]@{
        source_relative_path = 'mesa-23.1.x/src/gallium/drivers/svga/svga_screen.c'
        git_blob = 'dd26934198d3ed3e7174bed0a44fd3e76eb4be34'
        bytes = [UInt64]46069
        sha256 = '98f9990a1dce6607ea353e4bb9209411855beddc0ed5b8d592b8f3f2e2569bc8'
        license_expression = 'MIT'
        role = 'mesa-identity-caller'
    },
    [pscustomobject]@{
        source_relative_path = 'mesa-23.1.x/src/mesa/main/context.c'
        git_blob = '9763f4de35ea01582ca2584931312e717c64f1ac'
        bytes = [UInt64]53798
        sha256 = '50b7d1c67677dfbd74b02bacfcc0dc7254ed407c5239c3e7f8d813b06df39527'
        license_expression = 'MIT'
        role = 'mesa-version-caller'
    },
    [pscustomobject]@{
        source_relative_path = 'mesa-23.1.x/src/mesa/main/version.c'
        git_blob = '25cc619b0ba8d3d74f5e74abd1217ff44c88352e'
        bytes = [UInt64]29474
        sha256 = 'ddc513f9f7edfed471183662df60be2873ce31622a988694d1ce2916d6229424'
        license_expression = 'MIT'
        role = 'mesa-version-caller'
    }
)

$script:GswMesaExpectedOutputs = @(
    [pscustomobject]@{
        relative_path = 'include/git_sha1.h'
        bytes = [UInt64]525
        sha256 = 'a9fbd8a78d0ac9ae5c12f1ef6528e99f6bf9067284a3b3119ed7c9ae86a63c91'
        license_expression = 'GPL-3.0-only'
        role = 'mesa-build-identity'
    },
    [pscustomobject]@{
        relative_path = 'include/nine_memory_helper.h'
        bytes = [UInt64]1473
        sha256 = 'e7aff0715a4f98a2d3aa29bdf0efd43fea8cdb2d9b70ac6b310d8a528b72cade'
        license_expression = 'GPL-3.0-only'
        role = 'nine-memory-interface'
    },
    [pscustomobject]@{
        relative_path = 'src/nine_memory_helper.c'
        bytes = [UInt64]9301
        sha256 = 'b1e2f213d6cf2ced951d526e31cf74430ab0b0ce6942fe5a77f898bc65b8b0ef'
        license_expression = 'GPL-3.0-only'
        role = 'nine-resident-memory-adapter'
    }
)

function Assert-GswMesaString {
    param([object]$Value, [string]$Expected, [string]$Name)

    Assert-GswJsonString $Value $Name
    if ($Value -cne $Expected) { throw "$Name does not match its fixed value." }
}

function Assert-GswMesaInteger {
    param([object]$Value, [UInt64]$Expected, [string]$Name)

    Assert-GswJsonInteger $Value $Name
    if ([UInt64]$Value -ne $Expected) { throw "$Name does not match its fixed value." }
}

function Assert-GswMesaFalse {
    param([object]$Value, [string]$Name)

    Assert-GswJsonBoolean $Value $Name
    if ($Value) { throw "$Name must remain false." }
}

function Assert-GswMesaSafeRelativePath {
    param([string]$RelativePath, [string]$Name)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        $RelativePath.IndexOf([char]0) -ge 0 -or
        $script:GswMesaUtf8.GetByteCount($RelativePath) -gt 512) {
        throw "$Name contains an unsafe relative path."
    }
    foreach ($segment in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or
            $segment -in @('.', '..') -or
            $segment.IndexOf(':') -ge 0 -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal) -or
            $segment.EndsWith('.', [StringComparison]::Ordinal)) {
            throw "$Name contains an unsafe path segment."
        }
    }
}

function Assert-GswMesaOrdinaryDirectory {
    param([string]$Path, [string]$Name)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-GswNoReparseAncestor $fullPath $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one ordinary directory."
    }
    return $fullPath.TrimEnd([char[]]'\/')
}

function Resolve-GswMesaExactFile {
    param([string]$Root, [string]$RelativePath, [string]$Name)

    Assert-GswMesaSafeRelativePath $RelativePath $Name
    $rootPath = Assert-GswMesaOrdinaryDirectory $Root "$Name root"
    $current = $rootPath
    $segments = $RelativePath.Split('/')
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $matches = @([IO.Directory]::EnumerateFileSystemEntries($current) |
            Where-Object {
                [IO.Path]::GetFileName($_).Equals(
                    $segments[$index], [StringComparison]::OrdinalIgnoreCase
                )
            })
        if ($matches.Count -ne 1 -or
            [IO.Path]::GetFileName($matches[0]) -cne $segments[$index]) {
            throw "$Name '$RelativePath' is absent or has non-exact casing."
        }
        $attributes = [IO.File]::GetAttributes($matches[0])
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "$Name '$RelativePath' crosses a reparse point or device."
        }
        $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
        if (($index -lt $segments.Count - 1 -and -not $isDirectory) -or
            ($index -eq $segments.Count - 1 -and $isDirectory)) {
            throw "$Name '$RelativePath' has an invalid filesystem type."
        }
        $current = [IO.Path]::GetFullPath($matches[0])
    }
    return $current
}

function ConvertTo-GswMesaProcessArgument {
    param([string]$Argument)

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

function New-GswMesaGitStartInfo {
    param([string]$Checkout, [string[]]$Arguments)

    $commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($commands.Count -eq 0) { throw 'git is required for GSW source verification.' }
    $gitPath = [IO.Path]::GetFullPath($commands[0].Source)
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
    foreach ($name in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_PREFIX',
        'GIT_INDEX_FILE', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS',
        'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM',
        'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_SHALLOW_FILE',
        'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE', 'GIT_NAMESPACE',
        'GIT_ATTR_SOURCE', 'GIT_EXEC_PATH', 'GIT_LITERAL_PATHSPECS',
        'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS',
        'GIT_ICASE_PATHSPECS', 'GIT_REDIRECT_STDERR'
    )) {
        $startInfo.EnvironmentVariables.Remove($name)
    }
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        if ($name.StartsWith('GIT_CONFIG_KEY_', [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith('GIT_CONFIG_VALUE_', [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith('GIT_TRACE', [StringComparison]::OrdinalIgnoreCase)) {
            $startInfo.EnvironmentVariables.Remove($name)
        }
    }
    $startInfo.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $startInfo.EnvironmentVariables['GIT_NO_REPLACE_OBJECTS'] = '1'
    $startInfo.EnvironmentVariables['GIT_NO_LAZY_FETCH'] = '1'
    $startInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = if (
        [IO.Path]::DirectorySeparatorChar -eq '\'
    ) { 'NUL' } else { '/dev/null' }
    $allArguments = @(
        '--no-pager', '--no-replace-objects',
        '-c', 'core.quotePath=false',
        '-c', 'core.fsmonitor=false',
        '-c', 'core.untrackedCache=false',
        '-c', "safe.directory=$Checkout",
        '-C', $Checkout
    ) + $Arguments
    $startInfo.Arguments = ($allArguments | ForEach-Object {
        ConvertTo-GswMesaProcessArgument ([string]$_)
    }) -join ' '
    return $startInfo
}

function Invoke-GswMesaGitText {
    param([string]$Checkout, [string[]]$Arguments)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-GswMesaGitStartInfo $Checkout $Arguments
    $started = $false
    try {
        if (-not $process.Start()) { throw 'Unable to start git.' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw "git $($Arguments -join ' ') exceeded five seconds."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed: $($stderr.Trim())"
        }
        if ($script:GswMesaUtf8.GetByteCount($stdout) -gt 1048576 -or
            $script:GswMesaUtf8.GetByteCount($stderr) -gt 1048576) {
            throw "git $($Arguments -join ' ') exceeded its output bound."
        }
        return $stdout
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Read-GswMesaGitBlob {
    param([string]$Checkout, [string]$Blob)

    if ($Blob -cnotmatch '^[0-9a-f]{40}$') { throw "Invalid Git blob '$Blob'." }
    $sizeText = (Invoke-GswMesaGitText $Checkout @('cat-file', '-s', $Blob)).Trim()
    [UInt64]$announcedLength = 0
    if (-not [UInt64]::TryParse(
            $sizeText,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$announcedLength
        ) -or $announcedLength -eq 0 -or
        $announcedLength -gt $script:GswMesaMaximumInputBytes -or
        $announcedLength -gt [int]::MaxValue) {
        throw "Git blob '$Blob' has an invalid announced size."
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-GswMesaGitStartInfo $Checkout @('cat-file', 'blob', $Blob)
    $started = $false
    try {
        if (-not $process.Start()) { throw "Unable to read Git blob '$Blob'." }
        $started = $true
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $memory = [IO.MemoryStream]::new([int]$announcedLength)
        try {
            $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
            if (-not $process.WaitForExit(5000)) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
                throw "git cat-file for '$Blob' exceeded five seconds."
            }
            [void]$copyTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) {
                throw "git cat-file failed for '$Blob': $stderr"
            }
            if ([UInt64]$memory.Length -ne $announcedLength) {
                throw "Git blob '$Blob' length differs from cat-file -s."
            }
            return ,([byte[]]$memory.ToArray())
        }
        finally { $memory.Dispose() }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Get-GswMesaGitBlobSha1 {
    param([byte[]]$Bytes)

    $header = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $digest = [Security.Cryptography.SHA1]::Create()
    try {
        [void]$digest.TransformBlock($header, 0, $header.Length, $header, 0)
        [void]$digest.TransformFinalBlock($Bytes, 0, $Bytes.Length)
        return ([BitConverter]::ToString($digest.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally { $digest.Dispose() }
}

function Assert-GswMesaLocalConfig {
    param([string]$Checkout)

    $gitDirectory = Assert-GswMesaOrdinaryDirectory (Join-Path $Checkout '.git') `
        'Mesa Git directory'
    if (Test-Path -LiteralPath (Join-Path $gitDirectory 'config.worktree')) {
        throw 'Mesa checkout cannot use worktree-specific Git config.'
    }
    $configPath = Resolve-GswMesaExactFile $gitDirectory 'config' `
        'Mesa local Git config'
    $snapshot = Read-GswBoundedFileSnapshot -Path $configPath `
        -Name 'Mesa local Git config' -MaximumBytes 1048576
    $origins = @((Invoke-GswMesaGitText $Checkout @(
        'config', '--file', $configPath, '--no-includes', '--get-all',
        'remote.origin.url'
    )).Replace("`r`n", "`n").TrimEnd("`n").Split([char]10))
    if ($origins.Count -ne 1 -or $origins[0] -cne $script:GswMesaExpectedRepository) {
        throw 'Mesa checkout must have exactly the canonical local origin.'
    }
    $namesText = (Invoke-GswMesaGitText $Checkout @(
        'config', '--file', $configPath, '--no-includes', '--name-only', '--list'
    )).Replace("`r`n", "`n").TrimEnd("`n")
    $names = if ($namesText.Length -eq 0) { @() } else { @($namesText.Split([char]10)) }
    foreach ($name in $names) {
        if ($name -match
            '^(?i:include\.path|includeif\..*\.path|filter\..*\.(?:clean|smudge|process|required)|extensions\.(?:partialclone|worktreeconfig)|remote\..*\.(?:partialclonefilter|promisor|receivepack|uploadpack|vcs)|url\..*\.(?:insteadof|pushinsteadof)|protocol\..*\.allow|core\.gitproxy)$') {
            throw "Mesa local Git config contains forbidden key '$name'."
        }
    }
    return $snapshot
}

function Assert-GswMesaCleanCheckout {
    param([string]$Checkout)

    $checkoutPath = Assert-GswMesaOrdinaryDirectory $Checkout 'Mesa checkout'
    $configSnapshot = Assert-GswMesaLocalConfig $checkoutPath
    $root = (Invoke-GswMesaGitText $checkoutPath @(
        'rev-parse', '--show-toplevel'
    )).TrimEnd("`r", "`n")
    if (-not [IO.Path]::GetFullPath($root).Equals(
            $checkoutPath, [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Mesa checkout root mismatch.'
    }
    $head = (Invoke-GswMesaGitText $checkoutPath @(
        'rev-parse', '--verify', 'HEAD'
    )).TrimEnd("`r", "`n")
    if ($head -cne $script:GswMesaExpectedCommit) {
        throw "Mesa checkout HEAD '$head' is not pinned."
    }
    $origin = (Invoke-GswMesaGitText $checkoutPath @(
        'remote', 'get-url', '--all', 'origin'
    )).Replace("`r`n", "`n").TrimEnd("`n")
    if ($origin -cne $script:GswMesaExpectedRepository) {
        throw 'Mesa checkout effective origin is not canonical.'
    }
    $status = Invoke-GswMesaGitText $checkoutPath @(
        'status', '--porcelain=v1', '-z', '--untracked-files=all',
        '--ignored=matching', '--ignore-submodules=none'
    )
    if ($status.Length -ne 0) { throw 'Mesa checkout has local or ignored changes.' }
    return [pscustomobject]@{
        Checkout = $checkoutPath
        Config = $configSnapshot
    }
}

function Assert-GswMesaInput {
    param([string]$Checkout, [object]$Expected)

    $path = [string]$Expected.source_relative_path
    $indexState = (Invoke-GswMesaGitText $Checkout @(
        'ls-files', '-v', '--', $path
    )).TrimEnd("`r", "`n")
    if ($indexState -cne "H $path") {
        throw "Input '$path' has hidden or unexpected index state."
    }
    $treeState = Invoke-GswMesaGitText $Checkout @('ls-tree', '-z', 'HEAD', '--', $path)
    $expectedTreeState = "100644 blob $($Expected.git_blob)`t$path`0"
    if ($treeState -cne $expectedTreeState) {
        throw "Input '$path' does not match its pinned regular Git blob."
    }
    $bytes = Read-GswMesaGitBlob $Checkout $Expected.git_blob
    if ([UInt64]$bytes.Length -ne [UInt64]$Expected.bytes -or
        (Get-GswSha256Hex $bytes) -cne [string]$Expected.sha256 -or
        (Get-GswMesaGitBlobSha1 $bytes) -cne [string]$Expected.git_blob) {
        throw "Input '$path' content descriptor mismatch."
    }
}

function Assert-GswMesaOutput {
    param([string]$ModuleRoot, [object]$Expected)

    $path = Resolve-GswMesaExactFile $ModuleRoot $Expected.relative_path `
        'Original GSW output'
    $snapshot = Read-GswBoundedFileSnapshot -Path $path `
        -Name "Original GSW output '$($Expected.relative_path)'" `
        -MaximumBytes $script:GswMesaMaximumOutputBytes
    if ($snapshot.Length -ne [UInt64]$Expected.bytes -or
        $snapshot.Sha256 -cne [string]$Expected.sha256) {
        throw "Original GSW output '$($Expected.relative_path)' descriptor mismatch."
    }
    $text = ConvertFrom-GswStrictUtf8Bytes -Bytes $snapshot.Bytes `
        -Source "Original GSW output '$($Expected.relative_path)'"
    if ($text.IndexOf([char]0) -ge 0 -or $text.IndexOf([char]13) -ge 0 -or
        -not $text.StartsWith(
            "/* SPDX-License-Identifier: GPL-3.0-only */`n",
            [StringComparison]::Ordinal
        )) {
        throw "Original GSW output '$($Expected.relative_path)' is not normalized GPL-3.0-only source."
    }
    if ($text -match '(?i:VirtualBox|VMware|VBOX_|SVGA3D|GMR|MOB)') {
        throw "Original GSW output '$($Expected.relative_path)' contains an excluded device token."
    }
}

function Assert-GswMesaDescriptor {
    param([object]$Actual, [object]$Expected, [string]$PathProperty, [string]$Name)

    $properties = if ($PathProperty -ceq 'source_relative_path') {
        @('source_relative_path', 'git_blob', 'bytes', 'sha256',
          'license_expression', 'role')
    }
    else {
        @('relative_path', 'bytes', 'sha256', 'license_expression', 'role')
    }
    Assert-GswJsonExactProperties $Actual $properties $Name
    Assert-GswMesaString $Actual.$PathProperty $Expected.$PathProperty "$Name.$PathProperty"
    if ($PathProperty -ceq 'source_relative_path') {
        Assert-GswMesaString $Actual.git_blob $Expected.git_blob "$Name.git_blob"
    }
    Assert-GswMesaInteger $Actual.bytes ([UInt64]$Expected.bytes) "$Name.bytes"
    Assert-GswMesaString $Actual.sha256 $Expected.sha256 "$Name.sha256"
    Assert-GswMesaString $Actual.license_expression $Expected.license_expression `
        "$Name.license_expression"
    Assert-GswMesaString $Actual.role $Expected.role "$Name.role"
}

function Invoke-GswMesaOriginalSourceVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CheckoutPath,
        [Parameter(Mandatory = $true)][string]$MetadataPath,
        [scriptblock]$BeforeFinalCheck
    )

    $lockPath = [IO.Path]::GetFullPath($MetadataPath)
    $lockSnapshot = Read-GswStrictJsonFileSnapshot -Path $lockPath `
        -Name 'Original GSW source lock' `
        -MaximumBytes $script:GswMesaMaximumMetadataBytes
    $lock = $lockSnapshot.Value
    Assert-GswJsonExactProperties $lock @(
        '_spdx', 'schema', 'schema_definition', 'status', 'source', 'inputs',
        'excluded_implementation_paths', 'outputs', 'claims'
    ) 'Original GSW source lock'
    Assert-GswMesaString $lock._spdx 'GPL-3.0-only' '_spdx'
    Assert-GswMesaInteger $lock.schema 1 'schema'
    Assert-GswJsonExactProperties $lock.schema_definition @(
        'relative_path', 'sha256'
    ) 'schema_definition'
    Assert-GswMesaString $lock.schema_definition.relative_path `
        'interface-inputs.schema.json' 'schema_definition.relative_path'
    Assert-GswMesaString $lock.schema_definition.sha256 `
        $script:GswMesaExpectedSchemaSha256 'schema_definition.sha256'

    $moduleRoot = Assert-GswMesaOrdinaryDirectory (Split-Path -Parent $lockPath) `
        'Original GSW source Module root'
    $schemaPath = Resolve-GswMesaExactFile $moduleRoot `
        $lock.schema_definition.relative_path 'Original GSW source schema'
    $schemaSnapshot = Read-GswStrictJsonFileSnapshot -Path $schemaPath `
        -Name 'Original GSW source schema' `
        -MaximumBytes $script:GswMesaMaximumMetadataBytes
    if ($schemaSnapshot.Sha256 -cne $script:GswMesaExpectedSchemaSha256) {
        throw 'Original GSW source schema digest mismatch.'
    }
    Assert-GswJsonExactProperties $schemaSnapshot.Value @(
        '_spdx', '$schema', '$id', 'title', 'type', 'additionalProperties',
        'required', 'properties', '$defs'
    ) 'Original GSW source schema'
    Assert-GswMesaString $schemaSnapshot.Value._spdx 'GPL-3.0-only' `
        'Original GSW source schema._spdx'
    Assert-GswMesaString $schemaSnapshot.Value.'$id' `
        'interface-inputs.schema.json' 'Original GSW source schema.$id'

    Assert-GswMesaString $lock.status 'reviewed-permissive-interfaces' 'status'
    Assert-GswJsonExactProperties $lock.source @(
        'source_lock', 'source_name', 'repository', 'commit', 'mesa_version',
        'mesa_subtree'
    ) 'source'
    Assert-GswMesaString $lock.source.source_lock '../upstream.lock.tsv' `
        'source.source_lock'
    Assert-GswMesaString $lock.source.source_name 'mesa9x' 'source.source_name'
    Assert-GswMesaString $lock.source.repository `
        $script:GswMesaExpectedRepository 'source.repository'
    Assert-GswMesaString $lock.source.commit $script:GswMesaExpectedCommit `
        'source.commit'
    Assert-GswMesaString $lock.source.mesa_version '23.1.9' 'source.mesa_version'
    Assert-GswMesaString $lock.source.mesa_subtree 'mesa-23.1.x' `
        'source.mesa_subtree'

    Assert-GswJsonArray $lock.inputs 'inputs'
    if ($lock.inputs.Count -ne $script:GswMesaExpectedInputs.Count) {
        throw 'inputs must contain exactly eight ordered descriptors.'
    }
    for ($index = 0; $index -lt $script:GswMesaExpectedInputs.Count; $index++) {
        Assert-GswMesaDescriptor $lock.inputs[$index] `
            $script:GswMesaExpectedInputs[$index] 'source_relative_path' `
            "inputs[$index]"
    }

    Assert-GswJsonArray $lock.excluded_implementation_paths `
        'excluded_implementation_paths'
    $expectedExcluded = @(
        'include/git_sha1.h',
        'win9x/nine/nine_memory_helper.c'
    )
    if ($lock.excluded_implementation_paths.Count -ne $expectedExcluded.Count) {
        throw 'excluded_implementation_paths must contain exactly two paths.'
    }
    for ($index = 0; $index -lt $expectedExcluded.Count; $index++) {
        Assert-GswMesaString $lock.excluded_implementation_paths[$index] `
            $expectedExcluded[$index] "excluded_implementation_paths[$index]"
    }

    Assert-GswJsonArray $lock.outputs 'outputs'
    if ($lock.outputs.Count -ne $script:GswMesaExpectedOutputs.Count) {
        throw 'outputs must contain exactly three ordered descriptors.'
    }
    for ($index = 0; $index -lt $script:GswMesaExpectedOutputs.Count; $index++) {
        Assert-GswMesaDescriptor $lock.outputs[$index] `
            $script:GswMesaExpectedOutputs[$index] 'relative_path' `
            "outputs[$index]"
    }

    Assert-GswJsonExactProperties $lock.claims @(
        'build_authorized', 'compile_proven', 'staging_authorized',
        'guest_install_authorized', 'capability_advertisement_authorized'
    ) 'claims'
    foreach ($claim in $lock.claims.PSObject.Properties) {
        Assert-GswMesaFalse $claim.Value "claims.$($claim.Name)"
    }

    $checkout = Assert-GswMesaCleanCheckout $CheckoutPath
    foreach ($input in $script:GswMesaExpectedInputs) {
        Assert-GswMesaInput $checkout.Checkout $input
    }
    foreach ($output in $script:GswMesaExpectedOutputs) {
        Assert-GswMesaOutput $moduleRoot $output
    }

    if ($null -ne $BeforeFinalCheck) { & $BeforeFinalCheck }

    $finalLock = Read-GswStrictJsonFileSnapshot -Path $lockPath `
        -Name 'Original GSW source lock final recheck' `
        -MaximumBytes $script:GswMesaMaximumMetadataBytes
    $finalSchema = Read-GswStrictJsonFileSnapshot -Path $schemaPath `
        -Name 'Original GSW source schema final recheck' `
        -MaximumBytes $script:GswMesaMaximumMetadataBytes
    if ($finalLock.Length -ne $lockSnapshot.Length -or
        $finalLock.Sha256 -cne $lockSnapshot.Sha256 -or
        $finalSchema.Length -ne $schemaSnapshot.Length -or
        $finalSchema.Sha256 -cne $schemaSnapshot.Sha256) {
        throw 'Original GSW source metadata changed during verification.'
    }
    $finalCheckout = Assert-GswMesaCleanCheckout $checkout.Checkout
    if ($finalCheckout.Config.Length -ne $checkout.Config.Length -or
        $finalCheckout.Config.Sha256 -cne $checkout.Config.Sha256) {
        throw 'Mesa local Git configuration changed during verification.'
    }
    foreach ($input in $script:GswMesaExpectedInputs) {
        Assert-GswMesaInput $finalCheckout.Checkout $input
    }
    foreach ($output in $script:GswMesaExpectedOutputs) {
        Assert-GswMesaOutput $moduleRoot $output
    }

    Write-Output (
        'Verified original GSW Mesa source Module: 8 immutable MIT Interface ' +
        'inputs and 3 GPL-3.0-only outputs; build, compile, stage, install, ' +
        'and capability claims remain false.'
    )
}

if ($MyInvocation.InvocationName -cne '.') {
    if ([string]::IsNullOrWhiteSpace($MesaCheckout)) {
        throw 'MesaCheckout is required.'
    }
    if ([string]::IsNullOrWhiteSpace($LockFile)) {
        $LockFile = Join-Path $PSScriptRoot `
            '..\drivers\win98\mesa-gsw\interface-inputs.lock.json'
    }
    Invoke-GswMesaOriginalSourceVerification -CheckoutPath $MesaCheckout `
        -MetadataPath $LockFile `
        -BeforeFinalCheck $BeforeFinalStabilityCheck
}

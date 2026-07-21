# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$LfSourceCheckout,
    [string]$CrlfSourceCheckout,
    [string]$NameFilter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Tests = 0
$script:ExpectedCommit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Preparer = Join-Path $PSScriptRoot `
    'prepare-win98-mesa-generated-sources.ps1'
$script:Plan = Join-Path $repoRoot `
    'drivers\win98\mesa-generated-source-plan.json'
$script:Schema = Join-Path $repoRoot `
    'drivers\win98\mesa-generated-source-plan.schema.json'
$script:Utf8 = New-Object Text.UTF8Encoding($false, $true)

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Assert-True {
    param([bool]$Value, [string]$Message)

    if (-not $Value) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)

    try { & $Body | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $($_.Exception.Message)"
        }
        return
    }
    throw 'Expected an exception.'
}

function Invoke-SelfTest {
    param([string]$Name, [scriptblock]$Body)

    if (-not [string]::IsNullOrWhiteSpace($NameFilter) -and
        $Name -notlike "*$NameFilter*") {
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

function ConvertTo-TestProcessArgument {
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

function Invoke-TestGit {
    param(
        [string[]]$Arguments,
        [int]$TimeoutMilliseconds = 10000
    )

    if ($TimeoutMilliseconds -le 0 -or $TimeoutMilliseconds -gt 30000) {
        throw 'Test Git timeout must be between 1 and 30000 milliseconds.'
    }

    $commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
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
        if ($name.StartsWith('GIT_CONFIG_KEY_',
                [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith('GIT_CONFIG_VALUE_',
                [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith('GIT_TRACE',
                [StringComparison]::OrdinalIgnoreCase)) {
            $startInfo.EnvironmentVariables.Remove($name)
        }
    }
    $startInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = if (
        [IO.Path]::DirectorySeparatorChar -eq '\'
    ) { 'NUL' } else { '/dev/null' }
    $startInfo.EnvironmentVariables['GIT_NO_REPLACE_OBJECTS'] = '1'
    $startInfo.EnvironmentVariables['GIT_NO_LAZY_FETCH'] = '1'
    $startInfo.Arguments = (@('--no-pager', '--no-replace-objects') +
        $Arguments | ForEach-Object {
            ConvertTo-TestProcessArgument ([string]$_)
        }) -join ' '
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) { throw 'Unable to start test Git.' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw "git $($Arguments -join ' ') exceeded $TimeoutMilliseconds milliseconds."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($script:Utf8.GetByteCount($stdout) -gt 4194304 -or
            $script:Utf8.GetByteCount($stderr) -gt 4194304) {
            throw "git $($Arguments -join ' ') exceeded its output bound."
        }
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed: $($stderr.Trim())"
        }
        return @($stdout.TrimEnd("`r", "`n").Split("`n") |
            ForEach-Object { $_.TrimEnd("`r") })
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Resolve-GenerationCheckout {
    param([string]$Explicit, [string]$EnvironmentName, [string]$Leaf)

    $environmentPath = [Environment]::GetEnvironmentVariable(
        $EnvironmentName,
        'Process'
    )
    foreach ($candidate in @(
        $Explicit,
        $environmentPath,
        (Join-Path $repoRoot ".scratch\graphics-source-tools\$Leaf"),
        (Join-Path 'D:\dev\RETVRN99\.scratch\graphics-source-tools' $Leaf)
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Container)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "Generated Mesa fixture '$Leaf' is unavailable."
}

function Get-RecipePaths {
    param([string]$Checkout)

    $path = Join-Path $Checkout 'generator\mesa-23.1.x-gen.mk'
    $lines = [IO.File]::ReadAllLines($path, $script:Utf8)
    $start = [Array]::IndexOf($lines, 'GENERATE_FILES = \')
    if ($start -lt 0) { throw 'Fixture recipe has no GENERATE_FILES block.' }
    $paths = @()
    for ($index = $start + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Length -eq 0) { break }
        $match = [regex]::Match(
            $lines[$index],
            '^\t\$\(MESA_VER\)/(?<path>[^\s\\]+)(?: \\)?$'
        )
        if (-not $match.Success) { throw 'Malformed fixture recipe row.' }
        $paths += "mesa-23.1.x/$($match.Groups['path'].Value)"
    }
    Assert-Equal $paths.Count 67 'Fixture recipe count differs.'
    return @($paths)
}

function Get-SidePaths {
    $planObject = Get-Content -LiteralPath $script:Plan -Raw | ConvertFrom-Json
    return @($planObject.selection.validation_side_outputs | ForEach-Object {
        [string]$_.relative_path
    })
}

function Copy-GeneratedState {
    param([string]$Source, [string]$Destination)

    $paths = @(Get-RecipePaths $Source) + @(Get-SidePaths)
    foreach ($relativePath in $paths) {
        $sourcePath = Join-Path $Source ($relativePath.Replace('/', '\'))
        $targetPath = Join-Path $Destination ($relativePath.Replace('/', '\'))
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($targetPath))
        [IO.File]::Copy($sourcePath, $targetPath, $true)
    }
}

function Reset-Fixture {
    param([string]$GeneratedSource)

    $checkoutPrefix = [IO.Path]::GetFullPath($script:Checkout).TrimEnd(
        [char[]]'\/'
    ) + [IO.Path]::DirectorySeparatorChar
    $paths = @(Get-RecipePaths $GeneratedSource) + @(Get-SidePaths) + @(
        'unexpected-generated-source.tmp'
    )
    foreach ($relativePath in $paths) {
        $path = [IO.Path]::GetFullPath((Join-Path $script:Checkout (
            $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        )))
        if (-not $path.StartsWith(
                $checkoutPrefix, [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Fixture reset path escapes checkout: $relativePath"
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -and
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                throw "Fixture reset leaf unexpectedly became a directory: $relativePath"
            }
            if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                [IO.Directory]::Delete($path, $false)
            }
            else {
                [IO.File]::Delete($path)
            }
        }
    }
    Copy-GeneratedState $GeneratedSource $script:Checkout
}

function Remove-TestRoot {
    param([string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporaryPrefix = [IO.Path]::GetFullPath(
        [IO.Path]::GetTempPath()
    ).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
            $temporaryPrefix, [StringComparison]::OrdinalIgnoreCase
        ) -or
        (Split-Path -Leaf $fullPath) -notlike
            'retvrn99-mesa-generated-source-*') {
        throw "Refusing to remove unsafe test root '$fullPath'."
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not (Test-Path -LiteralPath $fullPath)) { return }
        try {
            Remove-Item -LiteralPath $fullPath -Recurse -Force
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Milliseconds 200 }
        }
    }
    throw "Test-root cleanup failed after three attempts: $($lastError.Exception.Message)"
}

function New-FileReparsePoint {
    param([string]$Path, [string]$Target)

    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    }
    else {
        New-Item -ItemType SymbolicLink -Path $Path -Target $Target | Out-Null
    }
}

$lfSource = Resolve-GenerationCheckout $LfSourceCheckout `
    'RETVRN99_MESA_GENERATION_LF' 'mesa-generation-lf'
$crlfSource = Resolve-GenerationCheckout $CrlfSourceCheckout `
    'RETVRN99_MESA_GENERATION_CRLF' 'mesa-generation-crlf'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-generated-source-' + [Guid]::NewGuid().ToString('N')
)
$script:Checkout = Join-Path $testRoot 'mesa9x'
$script:HeadTrUtil = Join-Path $testRoot 'head-tr-util.h'
$emptyTemplate = Join-Path $testRoot 'empty-git-template'
$script:CleanupError = $null

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    [void][IO.Directory]::CreateDirectory($emptyTemplate)
    $oldTemplate = [Environment]::GetEnvironmentVariable('GIT_TEMPLATE_DIR', 'Process')
    [Environment]::SetEnvironmentVariable('GIT_TEMPLATE_DIR', $emptyTemplate, 'Process')
    try {
        Invoke-TestGit -Arguments @(
            'clone', '--shared', '--no-checkout', $lfSource, $script:Checkout
        ) -TimeoutMilliseconds 30000 | Out-Null
        Invoke-TestGit -Arguments @(
            '-C', $script:Checkout, 'checkout', '--force', $script:ExpectedCommit
        ) -TimeoutMilliseconds 30000 | Out-Null
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'GIT_TEMPLATE_DIR', $oldTemplate, 'Process'
        )
    }
    Invoke-TestGit @(
        '-C', $script:Checkout, 'remote', 'set-url', 'origin',
        'https://github.com/JHRobotics/mesa9x.git'
    ) | Out-Null
    [IO.File]::Copy(
        (Join-Path $script:Checkout (
            'mesa-23.1.x/src/gallium/auxiliary/driver_trace/tr_util.h'.Replace(
                '/', '\'
            )
        )),
        $script:HeadTrUtil,
        $true
    )

    Invoke-SelfTest 'draft plan validates against its JSON schema' {
        if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) { return }
        $valid = Get-Content -LiteralPath $script:Plan -Raw |
            Test-Json -SchemaFile $script:Schema
        Assert-True $valid 'Draft generated-source plan failed schema validation.'
    }

    Invoke-SelfTest 'LF and CRLF fixtures publish identical 67-file trees' {
        Reset-Fixture $lfSource
        $lfOutput = Join-Path $testRoot 'out-lf'
        $lf = & $script:Preparer -MesaCheckout $script:Checkout `
            -OutputRoot $lfOutput -Describe
        Reset-Fixture $crlfSource
        $crlfOutput = Join-Path $testRoot 'out-crlf'
        $crlf = & $script:Preparer -MesaCheckout $script:Checkout `
            -OutputRoot $crlfOutput -Describe
        Assert-Equal $lf.files.Count 67 'LF descriptor file count differs.'
        Assert-Equal $crlf.files.Count 67 'CRLF descriptor file count differs.'
        Assert-Equal $lf.tree.sha256 $crlf.tree.sha256 `
            'Normalized tree digests differ.'
        Assert-Equal $lf.tree.aggregate_bytes $crlf.tree.aggregate_bytes `
            'Normalized aggregate byte counts differ.'
        foreach ($sidePath in Get-SidePaths) {
            Assert-True (-not (Test-Path -LiteralPath (
                Join-Path $lfOutput ($sidePath.Replace('/', '\'))
            ))) "Validation-only side output '$sidePath' was published."
        }
    }

    Invoke-SelfTest 'pinned Bison comment and blank-line deltas are accepted' {
        Reset-Fixture $lfSource
        $descriptor = & $script:Preparer -MesaCheckout $script:Checkout `
            -OutputRoot (Join-Path $testRoot 'out-bison-comments') -Describe
        Assert-Equal $descriptor.files.Count 67 `
            'Pinned Bison validation changed the published file count.'
    }

    Invoke-SelfTest 'blob-equivalent tr_util side output may be status-clean' {
        Reset-Fixture $lfSource
        $sidePath = (Get-SidePaths)[2]
        [IO.File]::Copy(
            $script:HeadTrUtil,
            (Join-Path $script:Checkout ($sidePath.Replace('/', '\'))),
            $true
        )
        $descriptor = & $script:Preparer -MesaCheckout $script:Checkout `
            -OutputRoot (Join-Path $testRoot 'out-tr-util-clean') -Describe
        Assert-Equal $descriptor.files.Count 67 `
            'Status-clean tr_util changed the published file count.'
    }

    Invoke-SelfTest 'missing recipe output fails closed' {
        Reset-Fixture $lfSource
        $missing = (Get-RecipePaths $lfSource)[0]
        Remove-Item -LiteralPath (
            Join-Path $script:Checkout ($missing.Replace('/', '\'))
        ) -Force
        Assert-Throws {
            & $script:Preparer -MesaCheckout $script:Checkout `
                -OutputRoot (Join-Path $testRoot 'out-missing')
        } 'missing|exact ignored-present state'
    }

    Invoke-SelfTest 'extra untracked output fails closed' {
        Reset-Fixture $lfSource
        [IO.File]::WriteAllText(
            (Join-Path $script:Checkout 'unexpected-generated-source.tmp'),
            "unexpected`n",
            $script:Utf8
        )
        Assert-Throws {
            & $script:Preparer -MesaCheckout $script:Checkout `
                -OutputRoot (Join-Path $testRoot 'out-extra')
        } 'unsupported state|missing or extra|unexpected changed'
    }

    Invoke-SelfTest 'unsafe output root fails closed' {
        Reset-Fixture $lfSource
        Assert-Throws {
            & $script:Preparer -MesaCheckout $script:Checkout `
                -OutputRoot (Join-Path $testRoot 'NUL')
        } 'Unsafe|reserved|component'
    }

    Invoke-SelfTest 'reparse-point generated source fails closed' {
        Reset-Fixture $lfSource
        $relativePath = (Get-RecipePaths $lfSource)[0]
        $sourcePath = Join-Path $script:Checkout ($relativePath.Replace('/', '\'))
        $target = Join-Path $testRoot 'reparse-file-target'
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            [void][IO.Directory]::CreateDirectory($target)
        }
        else {
            [IO.File]::Copy($sourcePath, $target, $true)
        }
        Remove-Item -LiteralPath $sourcePath -Force
        New-FileReparsePoint $sourcePath $target
        Assert-Throws {
            & $script:Preparer -MesaCheckout $script:Checkout `
                -OutputRoot (Join-Path $testRoot 'out-reparse')
        } 'reparse point|filesystem type|Unsafe path component'
    }

    Invoke-SelfTest 'source mutation before publication fails closed' {
        Reset-Fixture $lfSource
        $relativePath = (Get-RecipePaths $lfSource)[0]
        $sourcePath = Join-Path $script:Checkout ($relativePath.Replace('/', '\'))
        $watchParent = $testRoot
        $job = Start-Job -ScriptBlock {
            param($Parent, $SourcePath)
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            do {
                $temporary = @(Get-ChildItem -LiteralPath $Parent -Directory -Force |
                    Where-Object {
                        $_.Name.StartsWith('.retvrn99-generated-source-')
                    })
                if ($temporary.Count -ne 0) {
                    [IO.File]::AppendAllText($SourcePath, "`nmutation`n")
                    return
                }
                Start-Sleep -Milliseconds 10
            } while ([DateTime]::UtcNow -lt $deadline)
            throw 'Mutation watcher timed out.'
        } -ArgumentList $watchParent, $sourcePath
        try {
            Assert-Throws {
                & $script:Preparer -MesaCheckout $script:Checkout `
                    -OutputRoot (Join-Path $testRoot 'out-mutation')
            } 'changed during preparation|changed during its bounded read'
            Wait-Job $job -Timeout 12 | Out-Null
            Receive-Job $job -ErrorAction Stop | Out-Null
        }
        finally {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-SelfTest 'tracked side-output blob drift fails closed' {
        Reset-Fixture $lfSource
        $sidePath = (Get-SidePaths)[2]
        [IO.File]::AppendAllText(
            (Join-Path $script:Checkout ($sidePath.Replace('/', '\'))),
            "/* drift */`n",
            $script:Utf8
        )
        Assert-Throws {
            & $script:Preparer -MesaCheckout $script:Checkout `
                -OutputRoot (Join-Path $testRoot 'out-side-drift')
        } 'generated blob mismatch|HEAD-blob equivalent'
    }

    Invoke-SelfTest 'Bison side-output token drift fails closed' {
        Reset-Fixture $lfSource
        $sidePath = (Get-SidePaths)[0]
        $sideFile = Join-Path $script:Checkout ($sidePath.Replace('/', '\'))
        $text = [IO.File]::ReadAllText($sideFile, $script:Utf8)
        Assert-True ($text.Contains('int glcpp_parser_parse')) `
            'Pinned Bison fixture lacks its expected declaration.'
        [IO.File]::WriteAllText(
            $sideFile,
            $text.Replace('int glcpp_parser_parse', 'intglcpp_parser_parse'),
            $script:Utf8
        )
        Assert-Throws {
            & $script:Preparer -MesaCheckout $script:Checkout `
                -OutputRoot (Join-Path $testRoot 'out-token-drift')
        } 'non-comment C tokens'
    }

    Invoke-SelfTest 'preparation never launches generator tools' {
        Reset-Fixture $lfSource
        $shimRoot = Join-Path $testRoot 'generator-shims'
        [void][IO.Directory]::CreateDirectory($shimRoot)
        $sentinels = @()
        foreach ($tool in @('make', 'python', 'python3', 'flex', 'bison')) {
            $sentinel = Join-Path $shimRoot "$tool.executed"
            $sentinels += $sentinel
            if ([IO.Path]::DirectorySeparatorChar -eq '\') {
                [IO.File]::WriteAllText(
                    (Join-Path $shimRoot "$tool.cmd"),
                    "@echo executed>`"$sentinel`"`r`n@exit /b 97`r`n",
                    [Text.Encoding]::ASCII
                )
            }
            else {
                $shim = Join-Path $shimRoot $tool
                [IO.File]::WriteAllText(
                    $shim,
                    "#!/bin/sh`nprintf executed > '$sentinel'`nexit 97`n",
                    [Text.Encoding]::ASCII
                )
                & chmod +x $shim
            }
        }
        $oldPath = $env:PATH
        try {
            $env:PATH = $shimRoot + [IO.Path]::PathSeparator + $oldPath
            & $script:Preparer -MesaCheckout $script:Checkout `
                -OutputRoot (Join-Path $testRoot 'out-no-execution') | Out-Null
        }
        finally { $env:PATH = $oldPath }
        foreach ($sentinel in $sentinels) {
            Assert-True (-not (Test-Path -LiteralPath $sentinel)) `
                "Generator shim executed: $sentinel"
        }
    }

    Invoke-SelfTest 'preparer parses under Windows PowerShell 5' {
        $windowsPowerShell = Get-Command powershell.exe -CommandType Application `
            -ErrorAction Stop
        $environmentName = 'RETVRN99_GENERATED_SOURCE_PARSE_FILE'
        $oldValue = [Environment]::GetEnvironmentVariable(
            $environmentName,
            'Process'
        )
        [Environment]::SetEnvironmentVariable(
            $environmentName,
            $script:Preparer,
            'Process'
        )
        try {
            $parseCommand = @'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $env:RETVRN99_GENERATED_SOURCE_PARSE_FILE,
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { [Console]::Error.WriteLine($_.ToString()) }
    exit 1
}
'@
            & $windowsPowerShell.Source -NoLogo -NoProfile -Command $parseCommand
            Assert-Equal $LASTEXITCODE 0 'Windows PowerShell parser rejected preparer.'
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                $environmentName,
                $oldValue,
                'Process'
            )
        }
    }
}
finally {
    try { Remove-TestRoot $testRoot }
    catch {
        $script:CleanupError = $_
        Write-Warning "Generated-source test cleanup failed: $($_.Exception.Message)"
    }
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Tests) generated-source tests failed."
}
if ($null -ne $script:CleanupError) {
    throw "Generated-source tests passed, but cleanup failed: $($script:CleanupError.Exception.Message)"
}
Write-Output "All $($script:Tests) generated-source tests passed."

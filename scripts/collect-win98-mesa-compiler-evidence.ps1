# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$GeneratedRootA,
    [Parameter(Mandatory = $true)][string]$GeneratedRootB,
    [Parameter(Mandatory = $true)][string]$ToolchainRoot,
    [Parameter(Mandatory = $true)][string]$ProofRoot,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [string]$GitSourceRoot,
    [switch]$ReuseProof,
    [switch]$RequireExactSourceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'mesa-object-proof.ps1')
. (Join-Path $PSScriptRoot 'mesa-compiler-source-root.ps1')
. (Join-Path $PSScriptRoot 'mesa-compiler-dependency-roles.ps1')

$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:TimeoutSeconds = 30

function Get-FullPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Get-Sha256 {
    param([byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function ConvertTo-ProcessArgument {
    param([string]$Argument)
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
        }
        else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-OwnedProcessTree {
    param([Diagnostics.Process]$Process)

    Stop-MesaObjectProcessTree $Process
}

function Invoke-DependencyCommand {
    param(
        [string]$Compiler,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$ToolBin,
        [string]$PrivateTemp,
        [string]$Name
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Compiler
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Arguments = (($Arguments | ForEach-Object {
        ConvertTo-ProcessArgument ([string]$_)
    }) -join ' ')
    foreach ($nameValue in @(
        'GCC_EXEC_PREFIX', 'COMPILER_PATH', 'LIBRARY_PATH', 'CPATH',
        'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
        'DEPENDENCIES_OUTPUT', 'SUNPRO_DEPENDENCIES'
    )) { [void]$info.EnvironmentVariables.Remove($nameValue) }
    $info.EnvironmentVariables['PATH'] = $ToolBin + ';' +
        [Environment]::GetFolderPath('System')
    $info.EnvironmentVariables['TEMP'] = $PrivateTemp
    $info.EnvironmentVariables['TMP'] = $PrivateTemp
    $info.EnvironmentVariables['LC_ALL'] = 'C'
    $info.EnvironmentVariables['LANG'] = 'C'
    $info.EnvironmentVariables['TZ'] = 'UTC'
    $info.EnvironmentVariables['SOURCE_DATE_EPOCH'] = '0'

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = [bool]$process.Start()
        if (-not $started) { throw "$Name did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($script:TimeoutSeconds * 1000)) {
            Stop-OwnedProcessTree $process
            throw "$Name exceeded its $($script:TimeoutSeconds)-second bound."
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($stdout.Length -gt 1048576 -or $stderr.Length -gt 1048576) {
            throw "$Name exceeded its output bound."
        }
        if ($process.ExitCode -ne 0) {
            $detail = ($stderr + "`n" + $stdout).Trim()
            if ($detail.Length -gt 4096) { $detail = $detail.Substring(0, 4096) }
            throw "$Name failed with exit code $($process.ExitCode): $detail"
        }
    }
    finally {
        if ($started -and -not $process.HasExited) { Stop-OwnedProcessTree $process }
        $process.Dispose()
    }
}

function ConvertTo-LogicalText {
    param([string]$Text, [hashtable]$Roots)
    $result = $Text.Replace("`r`n", "`n")
    foreach ($entry in @(
        @($Roots.generated, '{generated}'),
        @($Roots.original, '{original}'),
        @($Roots.toolchain, '{toolchain}'),
        @($Roots.source, '{source}')
    )) {
        $forward = $entry[0].Replace('\', '/')
        $backward = $entry[0].Replace('/', '\')
        $replacement = $entry[1]
        $result = [Text.RegularExpressions.Regex]::Replace(
            $result,
            [Text.RegularExpressions.Regex]::Escape($forward),
            $replacement,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $result = [Text.RegularExpressions.Regex]::Replace(
            $result,
            [Text.RegularExpressions.Regex]::Escape($backward),
            $replacement,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    return $result.Replace('\', '/')
}

function Get-DependencyTokens {
    param([string]$LogicalDepfile)
    $joined = [Text.RegularExpressions.Regex]::Replace(
        $LogicalDepfile, '[\\/]\n', ' '
    )
    $colon = $joined.IndexOf(':')
    if ($colon -lt 1) { throw 'Dependency file has no target separator.' }
    $body = $joined.Substring($colon + 1).Trim()
    $tokens = @($body -split '\s+' | Where-Object { $_.Length -ne 0 })
    if ($tokens.Count -eq 0) { throw 'Dependency file has no dependencies.' }
    return @($tokens)
}

$repoRoot = Get-FullPath (Join-Path $PSScriptRoot '..')
$source = Get-FullPath $SourceRoot
$gitSource = if ([string]::IsNullOrWhiteSpace($GitSourceRoot)) {
    $null
}
else {
    Get-FullPath $GitSourceRoot
}
$generatedA = Get-FullPath $GeneratedRootA
$generatedB = Get-FullPath $GeneratedRootB
$original = Get-FullPath (Join-Path $repoRoot 'drivers\win98')
$toolchainBase = Get-FullPath $ToolchainRoot
$toolchainLockPath = Join-Path $repoRoot `
    'drivers\win98\mingw32-toolchain.lock.json'
$toolchainLock = Get-Content -Raw -LiteralPath $toolchainLockPath |
    ConvertFrom-Json
$toolchain = Get-FullPath (Join-Path $toolchainBase `
    ([string]$toolchainLock.extracted.relative_path))
$proof = Get-FullPath $ProofRoot
$output = Get-FullPath $OutputFile
foreach ($root in @($source, $generatedA, $generatedB, $original, $toolchain)) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Required compiler root '$root' is absent."
    }
}
if ($ReuseProof) {
    if (-not (Test-Path -LiteralPath $proof -PathType Container)) {
        throw 'Reusable proof root is absent.'
    }
}
else {
    if (Test-Path -LiteralPath $proof) { throw 'Proof root must be fresh and absent.' }
    [void][IO.Directory]::CreateDirectory($proof)
}
$temp = Join-Path $proof 'temp'
if (-not (Test-Path -LiteralPath $temp -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($temp)
}
if ($RequireExactSourceRoot) {
    if ($null -eq $gitSource -or
        -not (Test-Path -LiteralPath $gitSource -PathType Container) -or
        $gitSource -ceq $source) {
        throw 'Exact source verification requires a distinct clean Git checkout.'
    }
    $gitHead = @(& git -C $gitSource rev-parse HEAD 2>$null)
    $gitStatus = @(& git -C $gitSource status --porcelain=v1 `
        --untracked-files=no 2>$null)
    if ($LASTEXITCODE -ne 0 -or $gitHead.Count -ne 1 -or
        $gitHead[0] -cne '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f' -or
        $gitStatus.Count -ne 0) {
        throw 'Exact source Git checkout is not clean at the owning commit.'
    }
}
$objectRoots = @(
    (Join-Path $proof 'objects-a'),
    (Join-Path $proof 'objects-b')
)
foreach ($objectRoot in $objectRoots) {
    if (Test-Path -LiteralPath $objectRoot) {
        throw "Object proof root must be fresh and absent: '$objectRoot'."
    }
}
$generatedEvidence = @(& (Join-Path $PSScriptRoot `
    'verify-win98-mesa-generated-source-reproducibility.ps1') `
    -LfGeneratedRoot $generatedA -CrlfGeneratedRoot $generatedB)
if ($generatedEvidence.Count -ne 1 -or
    [string]$generatedEvidence[0] -notlike
        'Verified Mesa generated-source reproducibility evidence as proven; roots=verified-distinct-byte-identical;*') {
    throw 'Generated-source verifier returned unexpected evidence.'
}
$toolchainEvidence = @(& (Join-Path $PSScriptRoot `
    'verify-win98-driver-toolchain.ps1') -ToolchainRoot $toolchainBase `
    -LockFile $toolchainLockPath)
if ($toolchainEvidence.Count -ne 1 -or
    [string]$toolchainEvidence[0] -notlike 'Verified Windows 98 toolchain*') {
    throw 'Pinned MinGW32 toolchain verifier returned unexpected evidence.'
}

try {
$planPath = Join-Path $repoRoot 'drivers\win98\mesa-gsw-direct-build-plan.json'
$planBytes = [IO.File]::ReadAllBytes($planPath)
$plan = $script:Utf8.GetString($planBytes) | ConvertFrom-Json
if ($plan.inventory.total_source_units -ne 874 -or $plan.units.Count -ne 874 -or
    $plan.inventory.direct_compile_units -ne 869) {
    throw 'Direct-build plan does not contain 874 exact source units.'
}
$compileUnits = @($plan.units | Where-Object {
    $_.disposition -cne 'reviewed-generated-support-metadata-only'
})
if ($compileUnits.Count -ne 869) {
    throw 'Direct-build plan does not contain 869 compile dispositions.'
}
$componentPath = Join-Path $repoRoot `
    'drivers\win98\component-closures\mesa9x-23.1.x.json'
$component = Get-Content -Raw -LiteralPath $componentPath | ConvertFrom-Json
if ($component.schema -ne 2 -or $component.status -cne 'ready' -or
    $component.files.Count -ne 1687) {
    throw 'Mesa component closure is not ready and complete.'
}
$componentFiles = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
$componentDependencies = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($file in $component.files) {
    $componentFiles.Add([string]$file.relative_path, $file)
    if (@($file.roles) -ccontains 'compiler-dependency') {
        [void]$componentDependencies.Add([string]$file.relative_path)
    }
}
if ($componentDependencies.Count -ne 652) {
    throw 'Mesa component closure lacks 652 compiler-dependency files.'
}
if (-not $RequireExactSourceRoot) {
    throw 'Twin object proof requires the exact canonical-LF source root.'
}
$requiredSourcePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($unit in @($compileUnits | Where-Object source_kind -ceq 'upstream')) {
    [void]$requiredSourcePaths.Add([string]$unit.relative_path)
}
foreach ($path in $componentDependencies) { [void]$requiredSourcePaths.Add($path) }
if ($requiredSourcePaths.Count -ne 1489) {
    throw 'Ready source and dependency roles do not select 1,489 files.'
}
$sourcePrefix = $source.TrimEnd([char[]]'\/') +
    [IO.Path]::DirectorySeparatorChar
$actualSourcePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$canonicalSourceDescriptors = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($filePath in [IO.Directory]::EnumerateFiles(
        $source, '*', [IO.SearchOption]::AllDirectories
    )) {
    $item = Get-Item -LiteralPath $filePath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Exact source root contains reparse point '$filePath'."
    }
    $relative = $item.FullName.Substring($sourcePrefix.Length).Replace('\', '/')
    if (-not $actualSourcePaths.Add($relative) -or
        -not $requiredSourcePaths.Contains($relative) -or
        -not $componentFiles.ContainsKey($relative)) {
        throw "Exact source root contains unexpected file '$relative'."
    }
    $expectedSource = $componentFiles[$relative]
    $materializedObservation = ConvertTo-MesaCanonicalSourceObservation `
        -Path $item.FullName -ExpectedBytes ([int64]$expectedSource.bytes) `
        -ExpectedSha256 ([string]$expectedSource.sha256) -RequireLf $true `
        -Name "Exact source root file '$relative'"
    $gitObservation = ConvertTo-MesaCanonicalSourceObservation `
        -Path (Join-Path $gitSource ($relative.Replace('/', '\'))) `
        -ExpectedBytes ([int64]$expectedSource.bytes) `
        -ExpectedSha256 ([string]$expectedSource.sha256) -RequireLf $false `
        -Name "Exact source Git file '$relative'"
    $canonicalPair = Resolve-MesaCanonicalSourcePair `
        -LfObservation $materializedObservation -CrlfObservation $gitObservation `
        -Name "Exact source file '$relative'"
    [byte[]]$sourceBytes = $canonicalPair.Bytes
    $canonicalSourceDescriptors.Add($relative, [pscustomobject]@{
        Bytes = $sourceBytes.Length
        Sha256 = Get-Sha256 $sourceBytes
    })
}
if ($actualSourcePaths.Count -ne 1489) {
    throw 'Exact source root does not contain 1,489 canonical files.'
}
$profile = Get-Content (Join-Path $repoRoot 'drivers\win98\guest-cpu-profile.json') `
    -Raw | ConvertFrom-Json
$cpuFlags = @($profile.toolchains.mingw.cpu_flags | ForEach-Object { [string]$_ })

$defines = @(
    '-D__i386__', '-D_X86_', '-D_WIN32', '-DWIN32', '-DWIN9X',
    '-DWINVER=0x0400', '-D_WIN32_WINNT=0x0400',
    '-D_WIN32_WINDOWS=0x0410', '-DBUILD_GL32', '-D_GDI32_',
    '-DGL_API=GLAPI', '-DGL_APIENTRY=GLAPIENTRY',
    '-D_FILE_OFFSET_BITS=64', '-D_LARGEFILE_SOURCE', '-DMAPI_MODE_UTIL',
    '-D_GLAPI_NO_EXPORTS', '-DCOBJMACROS', '-DINC_OLE2',
    '-DPACKAGE_VERSION="23.1.9"', '-DPACKAGE_BUGREPORT="RETVRN99"',
    '-DMALLOC_IS_ALIGNED', '-DHAVE_CRTEX', '-DHAVE_OPENGL=1',
    '-DHAVE_OPENGL_ES_2=1', '-DHAVE_OPENGL_ES_1=1',
    '-DWINDOWS_NO_FUTEX', '-DGLX_USE_WINDOWSGL',
    '-DTHREAD_SANITIZER=0', '-DNO_REGEX', '-DWITH_XMLCONFIG=0',
    '-DBLAKE3_NO_SSE2', '-DBLAKE3_NO_SSE41', '-DBLAKE3_NO_AVX2',
    '-DBLAKE3_NO_AVX512', '-DMESA_MAJOR=23', '-DNDEBUG',
    '-DMESA_DEBUG=0', '-DD3D8TO9NOLOG'
)
$includePaths = @(
    'include', 'mesa-23.1.x/include', 'mesa-23.1.x/include/GL',
    'mesa-23.1.x/src/mapi', 'mesa-23.1.x/src/util',
    'mesa-23.1.x/src', 'mesa-23.1.x/src/mesa',
    'mesa-23.1.x/src/mesa/main', 'mesa-23.1.x/src/compiler',
    'mesa-23.1.x/src/compiler/nir',
    'mesa-23.1.x/src/compiler/glsl',
    'mesa-23.1.x/src/compiler/glsl/glcpp',
    'mesa-23.1.x/src/compiler/spirv',
    'mesa-23.1.x/src/mapi/glapi',
    'mesa-23.1.x/src/mapi/glapi/gen',
    'mesa-23.1.x/src/mesa/program',
    'mesa-23.1.x/src/gallium/state_trackers/wgl',
    'mesa-23.1.x/src/gallium/auxiliary',
    'mesa-23.1.x/src/gallium/auxiliary/util',
    'mesa-23.1.x/src/gallium/auxiliary/driver_trace',
    'mesa-23.1.x/src/gallium/auxiliary/indices',
    'mesa-23.1.x/src/gallium/include',
    'mesa-23.1.x/src/gallium/drivers/svga',
    'mesa-23.1.x/src/gallium/drivers/svga/include',
    'mesa-23.1.x/src/gallium/winsys',
    'mesa-23.1.x/src/gallium/drivers',
    'mesa-23.1.x/src/util/format',
    'mesa-23.1.x/src/gallium/frontends/wgl',
    'mesa-23.1.x/include/D3D9',
    'mesa-23.1.x/src/gallium/frontends',
    'mesa-23.1.x/src/gallium/frontends/nine', 'win9x', 'win9x/eight'
)
$logicalIncludes = @('-I', '{original}/mesa-gsw/include')
foreach ($path in $includePaths) {
    $logicalIncludes += @('-I', "{generated}/$path")
}
foreach ($path in $includePaths) {
    $logicalIncludes += @('-I', "{source}/$path")
}
$logicalCommon = @('-M', '-MF', '{depfile}', '-MT', '{object}') +
    $cpuFlags + $defines + $logicalIncludes
$objectDeterminism = @(
    '-fno-ident', '-fno-asynchronous-unwind-tables', '-fno-unwind-tables',
    '-fno-stack-protector'
)
$logicalObjectCommon = $cpuFlags + $defines + $logicalIncludes +
    $objectDeterminism
$logicalObjectPerUnit = @(
    '-frandom-seed=retvrn99-mesa-{command-id}-v1',
    '-ffile-prefix-map={source}=retvrn99/source',
    '-fmacro-prefix-map={source}=retvrn99/source',
    '-ffile-prefix-map={generated}=retvrn99/generated',
    '-fmacro-prefix-map={generated}=retvrn99/generated',
    '-ffile-prefix-map={original}=retvrn99/original',
    '-fmacro-prefix-map={original}=retvrn99/original',
    '-ffile-prefix-map={toolchain}=retvrn99/toolchain',
    '-fmacro-prefix-map={toolchain}=retvrn99/toolchain',
    '-ffile-prefix-map={proof}=retvrn99/proof',
    '-fmacro-prefix-map={proof}=retvrn99/proof',
    '-c', '{source-file}', '-o', '{object-file}'
)
$unitArgumentOverrides = @(
    [pscustomobject][ordered]@{
        command_id = 'cmd-0002'
        source = '{source}/mesa-23.1.x/src/c11/impl/threads_posix.c'
        profiles = [string[]]@('mesa-dependency-v1', 'mesa-object-v1')
        insertion = 'after-common-before-language'
        arguments = [string[]]@('-DHAVE_PTHREAD')
        mode = 'compile-context-only-no-link'
    }
    [pscustomobject][ordered]@{
        command_id = 'cmd-0792'
        source = '{source}/mesa-23.1.x/src/util/rwlock.c'
        profiles = [string[]]@('mesa-dependency-v1', 'mesa-object-v1')
        insertion = 'after-common-before-language'
        arguments = [string[]]@('-DHAVE_PTHREAD')
        mode = 'compile-context-only-no-link'
    }
    [pscustomobject][ordered]@{
        command_id = 'cmd-0852'
        source = '{generated}/mesa-23.1.x/src/mapi/glapi/gen/glapi_x86.S'
        profiles = [string[]]@('mesa-dependency-v1', 'mesa-object-v1')
        insertion = 'after-common-before-language'
        arguments = [string[]]@(
            '-DUSE_X86_ASM', '-DGLX_X86_READONLY_TEXT'
        )
        mode = 'compile-context-only-no-link'
    }
)
$unitOverrideByCommand = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($override in $unitArgumentOverrides) {
    $unitOverrideByCommand.Add([string]$override.command_id, $override)
}
$languageFlags = [ordered]@{
    'c-gnu99' = @('-std=gnu99')
    'cxx-gnu++14' = @('-std=gnu++14')
    'assembler-with-cpp' = @(
        '-x', 'assembler-with-cpp', '-DGNU_ASSEMBLER', '-DSTDCALL_API',
        '-D__MINGW32__'
    )
}
$compilerNames = [ordered]@{
    'c-gnu99' = 'i686-w64-mingw32-gcc.exe'
    'cxx-gnu++14' = 'i686-w64-mingw32-g++.exe'
    'assembler-with-cpp' = 'i686-w64-mingw32-gcc.exe'
}

$commands = @()
$objects = @()
$headerSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$objectIdentities = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$appliedUnitOverrideIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$toolBin = Join-Path $toolchain 'bin'
$compilerSnapshots = @{}
foreach ($compilerName in @($compilerNames.Values | Select-Object -Unique)) {
    $compilerPath = Join-Path $toolBin $compilerName
    [byte[]]$compilerBytes = [IO.File]::ReadAllBytes($compilerPath)
    $compilerSnapshots[$compilerName] = [pscustomobject]@{
        bytes = $compilerBytes.Length
        sha256 = Get-Sha256 $compilerBytes
    }
}
for ($index = 0; $index -lt $compileUnits.Count; $index++) {
    $unit = $compileUnits[$index]
    $id = 'cmd-' + ($index + 1).ToString('D4')
    $logicalSourceRoot = switch ($unit.source_kind) {
        'upstream' { '{source}' }
        'generated' { '{generated}' }
        'original-gsw' { '{original}' }
        default { throw "Unsupported source kind '$($unit.source_kind)'." }
    }
    $logicalSource = $logicalSourceRoot + '/' + $unit.relative_path
    $logicalDepfile = 'dep/' + $id + '.d'
    $unitOverrideArguments = @()
    if ($unitOverrideByCommand.ContainsKey($id)) {
        $override = $unitOverrideByCommand[$id]
        $expectedOverrideArguments = switch ($id) {
            'cmd-0002' { '-DHAVE_PTHREAD' }
            'cmd-0792' { '-DHAVE_PTHREAD' }
            'cmd-0852' { '-DUSE_X86_ASM|-DGLX_X86_READONLY_TEXT' }
            default { throw "Unexpected compile-context override '$id'." }
        }
        if (-not $appliedUnitOverrideIds.Add($id)) {
            throw "Compile-context override '$id' was applied more than once."
        }
        if ($logicalSource -cne [string]$override.source -or
            (@($override.profiles) -join '|') -cne
                'mesa-dependency-v1|mesa-object-v1' -or
            $override.insertion -cne 'after-common-before-language' -or
            $override.mode -cne 'compile-context-only-no-link' -or
            (@($override.arguments) -join '|') -cne
                $expectedOverrideArguments) {
            throw 'The compile-context override lost its exact binding.'
        }
        $unitOverrideArguments = @($override.arguments)
    }
    $normalizedRuns = @()
    $dependencyRuns = @()
    $objectRuns = @()
    foreach ($run in @('a', 'b')) {
        $generated = if ($run -ceq 'a') { $generatedA } else { $generatedB }
        $roots = @{
            source = $source
            generated = $generated
            original = $original
            toolchain = $toolchain
        }
        $actualSourceRoot = switch ($unit.source_kind) {
            'upstream' { $source }
            'generated' { $generated }
            'original-gsw' { $original }
        }
        $actualSource = Join-Path $actualSourceRoot (
            $unit.relative_path.Replace('/', '\')
        )
        if (-not (Test-Path -LiteralPath $actualSource -PathType Leaf)) {
            throw "$id source is absent: $actualSource"
        }
        $runRoot = Join-Path $proof $run
        [void][IO.Directory]::CreateDirectory($runRoot)
        $depfile = Join-Path $runRoot ($id + '.d')
        $arguments = @('-M', '-MF', $depfile, '-MT', $unit.object_identity) +
            $cpuFlags + $defines
        $arguments += @('-I', (Join-Path $original 'mesa-gsw\include'))
        foreach ($path in $includePaths) {
            $arguments += @('-I', (Join-Path $generated $path))
        }
        foreach ($path in $includePaths) {
            $arguments += @('-I', (Join-Path $source $path))
        }
        $arguments += $unitOverrideArguments
        $arguments += @($languageFlags[$unit.language])
        $arguments += $actualSource
        $compiler = Join-Path $toolBin $compilerNames[$unit.language]
        if (-not $ReuseProof) {
            Invoke-DependencyCommand -Compiler $compiler -Arguments $arguments `
                -WorkingDirectory $source -ToolBin $toolBin -PrivateTemp $temp `
                -Name "$id run $run"
        }
        elseif (-not (Test-Path -LiteralPath $depfile -PathType Leaf)) {
            throw "$id run $run reusable depfile is absent."
        }
        $raw = [IO.File]::ReadAllText($depfile)
        $logical = ConvertTo-LogicalText $raw $roots
        $tokens = @(Get-DependencyTokens $logical)
        foreach ($token in $tokens) {
            if ($token -cne $logicalSource) { [void]$headerSet.Add($token) }
        }
        $normalizedRuns += $logical
        $dependencyRuns += [pscustomobject]@{
            sha256 = Get-Sha256 $script:Utf8.GetBytes($logical)
            dependency_count = $tokens.Count
        }

        $objectRoot = if ($run -ceq 'a') {
            $objectRoots[0]
        }
        else { $objectRoots[1] }
        $objectPath = Join-Path $objectRoot (
            ([string]$unit.object_identity).Replace('/', '\')
        )
        [void][IO.Directory]::CreateDirectory(
            [IO.Path]::GetDirectoryName($objectPath)
        )
        $prefixRoots = [ordered]@{
            source = $source
            generated = $generated
            original = $original
            toolchain = $toolchain
            proof = $proof
        }
        $objectArguments = $cpuFlags + $defines
        $objectArguments += @('-I', (Join-Path $original 'mesa-gsw\include'))
        foreach ($path in $includePaths) {
            $objectArguments += @('-I', (Join-Path $generated $path))
        }
        foreach ($path in $includePaths) {
            $objectArguments += @('-I', (Join-Path $source $path))
        }
        $objectArguments += $objectDeterminism
        $objectArguments += $unitOverrideArguments
        $objectArguments += @($languageFlags[$unit.language])
        $randomSeed = "retvrn99-mesa-$id-v1"
        $objectArguments += "-frandom-seed=$randomSeed"
        foreach ($entry in $prefixRoots.GetEnumerator()) {
            $prefix = ([string]$entry.Value).Replace('\', '/')
            $objectArguments += "-ffile-prefix-map=$prefix=retvrn99/$($entry.Key)"
            $objectArguments += "-fmacro-prefix-map=$prefix=retvrn99/$($entry.Key)"
        }
        $objectArguments += @('-c', $actualSource, '-o', $objectPath)
        try {
            Invoke-MesaObjectCompiler -Compiler $compiler `
                -Arguments $objectArguments -WorkingDirectory $proof `
                -ToolBin $toolBin -PrivateTemp $temp `
                -Name "$id object run $run" `
                -TimeoutSeconds $script:TimeoutSeconds
            $objectRuns += Get-MesaNormalizedCoffObject $objectPath `
                (@($prefixRoots.Values) + @($temp))
        }
        finally {
            if ([IO.File]::Exists($objectPath)) {
                [IO.File]::Delete($objectPath)
            }
        }
    }
    if ($normalizedRuns[0] -cne $normalizedRuns[1]) {
        throw "$id dependency output differs between twin runs."
    }
    $commands += [pscustomobject][ordered]@{
        id = $id
        unit_ordinal = $index + 1
        language = [string]$unit.language
        compiler = '{toolchain}/bin/' + $compilerNames[$unit.language]
        source = $logicalSource
        object = [string]$unit.object_identity
        depfile = $logicalDepfile
        profile = 'mesa-dependency-v1'
        dependency_count = $dependencyRuns[0].dependency_count
        twin_sha256 = $dependencyRuns[0].sha256
    }
    Assert-MesaObjectTwin $objectRuns[0] $objectRuns[1] $id
    if (-not $objectIdentities.Add([string]$unit.object_identity)) {
        throw "$id repeats object identity '$($unit.object_identity)'."
    }
    $objects += [pscustomobject][ordered]@{
        id = 'object-' + ($index + 1).ToString('D4')
        command_id = $id
        unit_ordinal = $index + 1
        object = [string]$unit.object_identity
        random_seed = "retvrn99-mesa-$id-v1"
        bytes = $objectRuns[0].Bytes
        run_a = [pscustomobject][ordered]@{
            raw_sha256 = $objectRuns[0].RawSha256
            timestamp = $objectRuns[0].Timestamp
            normalized_sha256 = $objectRuns[0].NormalizedSha256
        }
        run_b = [pscustomobject][ordered]@{
            raw_sha256 = $objectRuns[1].RawSha256
            timestamp = $objectRuns[1].Timestamp
            normalized_sha256 = $objectRuns[1].NormalizedSha256
        }
        normalized_sha256 = $objectRuns[0].NormalizedSha256
        twin_byte_identical = $true
    }
    if (($index + 1) % 25 -eq 0 -or $index + 1 -eq $compileUnits.Count) {
        Write-Host (
            "Completed twin dependency and object proof for " +
            "$($index + 1)/$($compileUnits.Count) units."
        )
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [Threading.Thread]::Sleep(1000)
    }
}

$headers = @()
$headerPaths = @($headerSet)
[Array]::Sort($headerPaths, [StringComparer]::Ordinal)
foreach ($logical in $headerPaths) {
    if ($logical -notmatch '^\{(source|generated|original|toolchain)\}/(.+)$') {
        throw "Dependency '$logical' is outside the four locked roots."
    }
    $rootName = $Matches[1]
    $relative = $Matches[2]
    $actualRoot = switch ($rootName) {
        'source' { $source }
        'generated' { $generatedA }
        'original' { $original }
        'toolchain' { $toolchain }
    }
    $actual = Join-Path $actualRoot ($relative.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $actual -PathType Leaf)) {
        throw "Dependency '$logical' is absent from its locked root."
    }
    $bytes = [IO.File]::ReadAllBytes($actual)
    $licenseScope = switch ($rootName) {
        'source' { 'reviewed-component-closure' }
        'generated' { 'reviewed-generated-output-lock' }
        'original' { 'GPL-3.0-only' }
        'toolchain' { 'locked-toolchain-distribution' }
    }
    if ($rootName -ceq 'source') {
        if (-not $componentDependencies.Contains($relative)) {
            throw "Source dependency '$relative' lacks component closure."
        }
        $canonicalDescriptor = $canonicalSourceDescriptors[$relative]
        if ($bytes.Length -ne [int64]$canonicalDescriptor.Bytes -or
            (Get-Sha256 $bytes) -cne [string]$canonicalDescriptor.Sha256) {
            throw "Source dependency '$relative' changed after canonical validation."
        }
    }
    $headers += [pscustomobject][ordered]@{
        root = $rootName
        relative_path = $relative
        bytes = $bytes.Length
        sha256 = Get-Sha256 $bytes
        license_scope = $licenseScope
    }
}

$sourceRootExact = $false
$sourceRootFileCount = 0
if ($RequireExactSourceRoot) {
    $dependencyRoles = Resolve-MesaCompilerDependencyRoles @($headers)
    if (-not $componentFiles.ContainsKey($dependencyRoles.ShadowedPath)) {
        throw 'Exact source root lacks the generated-shadowed dependency role.'
    }
    Assert-MesaShadowedCompilerDependencyRole `
        $componentFiles[$dependencyRoles.ShadowedPath]
    foreach ($path in $dependencyRoles.RolePaths) {
        if (-not $componentDependencies.Contains($path)) {
            throw "Exact source dependency role '$path' lacks component closure."
        }
    }
    $expectedSourcePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($unit in @($compileUnits | Where-Object source_kind -ceq 'upstream')) {
        [void]$expectedSourcePaths.Add([string]$unit.relative_path)
    }
    foreach ($path in $dependencyRoles.RolePaths) {
        [void]$expectedSourcePaths.Add($path)
    }
    $actualSourcePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $sourcePrefix = $source.TrimEnd([char[]]'\/') +
        [IO.Path]::DirectorySeparatorChar
    foreach ($file in [IO.Directory]::EnumerateFiles(
            $source, '*', [IO.SearchOption]::AllDirectories
        )) {
        $item = Get-Item -LiteralPath $file -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Exact source root contains reparse point '$file'."
        }
        $relative = $item.FullName.Substring($sourcePrefix.Length).Replace('\', '/')
        if (-not $actualSourcePaths.Add($relative)) {
            throw "Exact source root repeats '$relative'."
        }
    }
    if ($actualSourcePaths.Count -ne 1489 -or
        $expectedSourcePaths.Count -ne 1489) {
        throw 'Exact source root must contain 1,489 selected files.'
    }
    foreach ($path in $expectedSourcePaths) {
        if (-not $actualSourcePaths.Contains($path)) {
            throw "Exact source root lacks '$path'."
        }
    }
    $sourceRootExact = $true
    $sourceRootFileCount = 1489
}

$profiles = [pscustomobject][ordered]@{
    id = 'mesa-dependency-v1'
    mode = 'gcc-M-MF-MT'
    missing_header_mode = 'reject-no-MG'
    include_system_headers = $true
    timeout_seconds = $script:TimeoutSeconds
    maximum_concurrent_children = 1
    batch_size = 25
    batch_quiescence_milliseconds = 1000
    common_arguments = $logicalCommon
    language_arguments = $languageFlags
}
$objectProfile = [pscustomobject][ordered]@{
    id = 'mesa-object-v1'
    mode = 'compile-only-no-link'
    timeout_seconds = $script:TimeoutSeconds
    maximum_concurrent_children = 1
    batch_size = 25
    batch_quiescence_milliseconds = 1000
    common_arguments = $logicalObjectCommon
    language_arguments = $languageFlags
    per_unit_arguments = $logicalObjectPerUnit
    working_directory = '{proof}'
    linker_invocations = 0
}
$rootCounts = [ordered]@{}
foreach ($name in @('source', 'generated', 'original', 'toolchain')) {
    $rootCounts[$name] = @($headers | Where-Object root -ceq $name).Count
}
$evidence = [pscustomobject][ordered]@{
    _spdx = 'GPL-3.0-only'
    schema = 2
    direct_plan = [pscustomobject][ordered]@{
        bytes = $planBytes.Length
        sha256 = Get-Sha256 $planBytes
        unit_count = $plan.units.Count
    }
    profile = $profiles
    object_profile = $objectProfile
    unit_argument_overrides = $unitArgumentOverrides
    commands = $commands
    headers = $headers
    objects = $objects
    summary = [pscustomobject][ordered]@{
        command_count = $commands.Count
        twin_depfile_count = $commands.Count * 2
        unique_dependency_count = $headers.Count
        dependency_root_counts = $rootCounts
        twin_byte_identical = $true
        failed_command_count = 0
        exact_source_root = $sourceRootExact
        exact_source_root_file_count = $sourceRootFileCount
        object_compile_count = $objects.Count * 2
        unique_object_count = $objects.Count
        twin_objects_byte_identical = $true
        object_identity_collision_count = 0
        failed_object_compile_count = 0
        temporary_object_count = 0
        aggregate_object_sha256 = Get-MesaObjectAggregateSha256 $objects
    }
}
if ($appliedUnitOverrideIds.Count -ne $unitOverrideByCommand.Count) {
    throw 'Not every compile-context override was applied.'
}
foreach ($compilerName in $compilerSnapshots.Keys) {
    $compilerPath = Join-Path $toolBin $compilerName
    [byte[]]$compilerBytes = [IO.File]::ReadAllBytes($compilerPath)
    $expectedCompiler = $compilerSnapshots[$compilerName]
    if ($compilerBytes.Length -ne $expectedCompiler.bytes -or
        (Get-Sha256 $compilerBytes) -cne $expectedCompiler.sha256) {
        throw "Pinned compiler '$compilerName' changed during the proof."
    }
}
$json = $evidence | ConvertTo-Json -Depth 16
}
finally {
    foreach ($objectRoot in $objectRoots) {
        Remove-MesaObjectTree $objectRoot $proof
    }
}
[IO.File]::WriteAllText($output, $json + "`n", $script:Utf8)
Write-Host (
    "Wrote exact compiler evidence for $($commands.Count) commands, " +
    "$($headers.Count) dependencies, and $($objects.Count) twin objects to '$output'."
)

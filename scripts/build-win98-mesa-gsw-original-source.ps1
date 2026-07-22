# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MesaCheckout = 'D:\src\retvrn99-win98\mesa9x',
    [string]$ToolchainRoot = 'D:\src\retvrn99-win98\toolchains',
    [string]$PlanFile,
    [scriptblock]$BeforeFinalStabilityCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'strict-json.ps1')

$script:GswCompileSchemaSha256 = `
    '1f28a6c81f7786376df00ea798bcc98fd604165569b617ab911cc47f229a5ef9'
$script:GswCompileMaximumMetadataBytes = [UInt64]65536
$script:GswCompileMaximumInputBytes = [UInt64]65536
$script:GswCompileMaximumToolBytes = [UInt64]8388608
$script:GswSemFailCriticalErrors = [UInt32]0x0001
$script:GswSemNoGpFaultErrorBox = [UInt32]0x0002
$script:GswSemNoOpenFileErrorBox = [UInt32]0x8000
$script:GswCompileChildErrorMode = [UInt32](
    $script:GswSemFailCriticalErrors -bor
    $script:GswSemNoGpFaultErrorBox -bor
    $script:GswSemNoOpenFileErrorBox
)
$script:GswCompileErrorModeLock = [object]::new()
$script:GswCompileExpectedPrefixFlags = @(
    '-std=gnu99',
    '-m32'
)
$script:GswCompileExpectedSuffixFlags = @(
    '-D_WIN32_WINNT=0x0400',
    '-DWINVER=0x0400',
    '-D_WIN32_WINDOWS=0x0410',
    '-fno-ident',
    '-fno-asynchronous-unwind-tables',
    '-fno-unwind-tables',
    '-fno-stack-protector',
    '-frandom-seed=retvrn99-gsw-nine-memory-helper-v1',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-Wpedantic'
)
$script:GswCompileExpectedRootFlags = @(
    '-ffile-prefix-map={build_root}=.',
    '-fmacro-prefix-map={build_root}=.',
    '-I{build_root}/include'
)
$script:GswCompileExpectedRequiredMacros = @(
    '__i386__', '__MMX__', '__SSE__', '__SSE2__', '__SSE3__'
)
$script:GswCompileExpectedForbiddenMacros = @(
    '__x86_64__', '__SSE4A__', '__SSE4_1__', '__SSE4_2__', '__AVX__',
    '__AVX2__', '__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16'
)
$script:GswCompileExpectedForbiddenBackends = @(
    'softpipe', 'llvmpipe', 'virgl', 'zink', 'wined3d', 'qemu-3dfx',
    'virtualbox', 'vbox', 'vmware'
)
$script:GswCompileExpectedInputs = @(
    [pscustomobject]@{
        relative_path = 'include/git_sha1.h'
        bytes = [UInt64]525
        sha256 = 'a9fbd8a78d0ac9ae5c12f1ef6528e99f6bf9067284a3b3119ed7c9ae86a63c91'
        role = 'original-mesa-identity-header'
    },
    [pscustomobject]@{
        relative_path = 'include/nine_memory_helper.h'
        bytes = [UInt64]1473
        sha256 = 'e7aff0715a4f98a2d3aa29bdf0efd43fea8cdb2d9b70ac6b310d8a528b72cade'
        role = 'original-nine-interface-header'
    },
    [pscustomobject]@{
        relative_path = 'src/nine_memory_helper.c'
        bytes = [UInt64]9301
        sha256 = 'b1e2f213d6cf2ced951d526e31cf74430ab0b0ce6942fe5a77f898bc65b8b0ef'
        role = 'original-nine-memory-implementation'
    },
    [pscustomobject]@{
        relative_path = 'probes/compile_probe.c'
        bytes = [UInt64]1055
        sha256 = '0e8ed6a108472a6f494c5f66d76d43a626f2831b6cf6a34dda2c2ed0958242d5'
        role = 'identity-nine-and-cpu-contract-probe'
    }
)

function Assert-GswCompileString {
    param([object]$Value, [string]$Expected, [string]$Name)

    Assert-GswJsonString $Value $Name
    if ($Value -cne $Expected) { throw "$Name does not match its fixed value." }
}

function Assert-GswCompileInteger {
    param([object]$Value, [UInt64]$Expected, [string]$Name)

    Assert-GswJsonInteger $Value $Name
    if ([UInt64]$Value -ne $Expected) { throw "$Name does not match its fixed value." }
}

function Assert-GswCompileBoolean {
    param([object]$Value, [bool]$Expected, [string]$Name)

    Assert-GswJsonBoolean $Value $Name
    if ($Value -ne $Expected) { throw "$Name does not match its fixed value." }
}

function Assert-GswCompileArray {
    param([object]$Actual, [string[]]$Expected, [string]$Name)

    Assert-GswJsonArray $Actual $Name
    if ($Actual.Count -ne $Expected.Count) {
        throw "$Name must contain exactly $($Expected.Count) ordered values."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-GswCompileString $Actual[$index] $Expected[$index] "$Name[$index]"
    }
}

function Assert-GswCompileFileDescriptor {
    param(
        [object]$Actual,
        [string]$RelativePath,
        [UInt64]$Bytes,
        [string]$Sha256,
        [string]$Name,
        [string]$Role
    )

    $properties = @('relative_path', 'bytes', 'sha256')
    if (-not [string]::IsNullOrEmpty($Role)) { $properties += 'role' }
    Assert-GswJsonExactProperties $Actual $properties $Name
    Assert-GswCompileString $Actual.relative_path $RelativePath "$Name.relative_path"
    Assert-GswCompileInteger $Actual.bytes $Bytes "$Name.bytes"
    Assert-GswCompileString $Actual.sha256 $Sha256 "$Name.sha256"
    if (-not [string]::IsNullOrEmpty($Role)) {
        Assert-GswCompileString $Actual.role $Role "$Name.role"
    }
}

function Assert-GswCompilePlan {
    param([Parameter(Mandatory = $true)][object]$Plan)

    Assert-GswJsonExactProperties $Plan @(
        '_spdx', 'schema', 'schema_definition', 'status', 'guest_cpu_profile',
        'source_module', 'toolchain', 'compile', 'normalization',
        'forbidden_backend_tokens', 'claims'
    ) 'compile plan'
    Assert-GswCompileString $Plan._spdx 'GPL-3.0-only' 'compile plan._spdx'
    Assert-GswCompileInteger $Plan.schema 1 'compile plan.schema'
    Assert-GswJsonExactProperties $Plan.schema_definition @(
        'relative_path', 'sha256'
    ) 'compile plan.schema_definition'
    Assert-GswCompileString $Plan.schema_definition.relative_path `
        'compile-plan.schema.json' 'compile plan.schema_definition.relative_path'
    Assert-GswCompileString $Plan.schema_definition.sha256 `
        $script:GswCompileSchemaSha256 'compile plan.schema_definition.sha256'
    Assert-GswCompileString $Plan.status 'compile-only-proof' 'compile plan.status'

    Assert-GswJsonExactProperties $Plan.guest_cpu_profile @(
        'profile', 'verifier', 'profile_id', 'cpu_flags_source'
    ) 'compile plan.guest_cpu_profile'
    Assert-GswCompileFileDescriptor $Plan.guest_cpu_profile.profile `
        '../guest-cpu-profile.json' 3537 `
        '969b45df75c6e1d8366e6ef7468a51f04c42441914ce564ae19f62a07cad0f57' `
        'compile plan.guest_cpu_profile.profile'
    Assert-GswCompileFileDescriptor $Plan.guest_cpu_profile.verifier `
        '../../../scripts/verify-win98-guest-cpu-profile.ps1' 28631 `
        'c0e0f0c67e1cc820a2188f005adf4c3f65a449ec40d47b1826ac1ba3f74abaf6' `
        'compile plan.guest_cpu_profile.verifier'
    Assert-GswCompileString $Plan.guest_cpu_profile.profile_id `
        'gsw-886-win98-i686-v1' 'compile plan.guest_cpu_profile.profile_id'
    Assert-GswCompileString $Plan.guest_cpu_profile.cpu_flags_source `
        'guest_cpu_profile.toolchains.mingw.cpu_flags' `
        'compile plan.guest_cpu_profile.cpu_flags_source'

    Assert-GswJsonExactProperties $Plan.source_module @(
        'lock', 'verifier', 'inputs'
    ) 'compile plan.source_module'
    Assert-GswCompileFileDescriptor $Plan.source_module.lock `
        'interface-inputs.lock.json' 4336 `
        '8b64bed0e4b110b1526ff1bae136b38f23c8441c9a0a64d1d35ff74ebce77f22' `
        'compile plan.source_module.lock'
    Assert-GswCompileFileDescriptor $Plan.source_module.verifier `
        '../../../scripts/verify-win98-mesa-gsw-original-source.ps1' 29048 `
        'c4aca411f190e50a40cb9acdb294901c645977983f8fc4839392ce7e10ff67e3' `
        'compile plan.source_module.verifier'
    Assert-GswJsonArray $Plan.source_module.inputs 'compile plan.source_module.inputs'
    if ($Plan.source_module.inputs.Count -ne $script:GswCompileExpectedInputs.Count) {
        throw 'compile plan.source_module.inputs must contain four ordered descriptors.'
    }
    for ($index = 0; $index -lt $script:GswCompileExpectedInputs.Count; $index++) {
        $expected = $script:GswCompileExpectedInputs[$index]
        Assert-GswCompileFileDescriptor $Plan.source_module.inputs[$index] `
            $expected.relative_path $expected.bytes $expected.sha256 `
            "compile plan.source_module.inputs[$index]" $expected.role
    }

    Assert-GswJsonExactProperties $Plan.toolchain @(
        'lock', 'verifier', 'name', 'extracted_relative_path', 'tree_sha256',
        'compiler', 'inspector'
    ) 'compile plan.toolchain'
    Assert-GswCompileFileDescriptor $Plan.toolchain.lock `
        '../mingw32-toolchain.lock.json' 792 `
        'db3a84b7388937a5ffd5ab3e30429bae4c3ca5d8d17f095a491a42bc82413a12' `
        'compile plan.toolchain.lock'
    Assert-GswCompileFileDescriptor $Plan.toolchain.verifier `
        '../../../scripts/verify-win98-driver-toolchain.ps1' 24574 `
        '4a38d41118a3812eb7ccc973cd0706c2edbc92656c78f34941f8c7ca96868291' `
        'compile plan.toolchain.verifier'
    Assert-GswCompileString $Plan.toolchain.name `
        'msys2-mingw32-gcc-15.2.0-rev13' 'compile plan.toolchain.name'
    Assert-GswCompileString $Plan.toolchain.extracted_relative_path `
        'msys2-mingw32-gcc15.2.0-20260717' `
        'compile plan.toolchain.extracted_relative_path'
    Assert-GswCompileString $Plan.toolchain.tree_sha256 `
        '08491a4bf273920ff9078f444addffe7e08f0d0b77d34d74cc2c742c84bb614a' `
        'compile plan.toolchain.tree_sha256'
    Assert-GswCompileFileDescriptor $Plan.toolchain.compiler `
        'bin/i686-w64-mingw32-gcc.exe' 3147424 `
        '0c79d47814364067e560ba4d26849126388a44fc5765d33df00c1fdd582c89a9' `
        'compile plan.toolchain.compiler'
    Assert-GswCompileFileDescriptor $Plan.toolchain.inspector `
        'bin/objdump.exe' 2207753 `
        '3a3309d8a8f8898193d5e41e73085d8c8702a1efe296c6236a48f925fc5411f5' `
        'compile plan.toolchain.inspector'

    Assert-GswJsonExactProperties $Plan.compile @(
        'language', 'target', 'prefix_flags', 'cpu_flags_source',
        'suffix_flags', 'root_scoped_flags', 'probe', 'source',
        'temporary_output', 'repeat_count', 'process_timeout_seconds',
        'required_macros', 'forbidden_macros'
    ) 'compile plan.compile'
    Assert-GswCompileString $Plan.compile.language 'c-gnu99' `
        'compile plan.compile.language'
    Assert-GswCompileString $Plan.compile.target 'i686-w64-mingw32' `
        'compile plan.compile.target'
    Assert-GswCompileArray $Plan.compile.prefix_flags `
        $script:GswCompileExpectedPrefixFlags 'compile plan.compile.prefix_flags'
    Assert-GswCompileString $Plan.compile.cpu_flags_source `
        'guest_cpu_profile.toolchains.mingw.cpu_flags' `
        'compile plan.compile.cpu_flags_source'
    Assert-GswCompileArray $Plan.compile.suffix_flags `
        $script:GswCompileExpectedSuffixFlags 'compile plan.compile.suffix_flags'
    Assert-GswCompileArray $Plan.compile.root_scoped_flags `
        $script:GswCompileExpectedRootFlags 'compile plan.compile.root_scoped_flags'
    Assert-GswCompileString $Plan.compile.probe 'probes/compile_probe.c' `
        'compile plan.compile.probe'
    Assert-GswCompileString $Plan.compile.source 'src/nine_memory_helper.c' `
        'compile plan.compile.source'
    Assert-GswCompileString $Plan.compile.temporary_output `
        'out/nine_memory_helper.o' 'compile plan.compile.temporary_output'
    Assert-GswCompileInteger $Plan.compile.repeat_count 2 `
        'compile plan.compile.repeat_count'
    Assert-GswCompileInteger $Plan.compile.process_timeout_seconds 10 `
        'compile plan.compile.process_timeout_seconds'
    Assert-GswCompileArray $Plan.compile.required_macros `
        $script:GswCompileExpectedRequiredMacros 'compile plan.compile.required_macros'
    Assert-GswCompileArray $Plan.compile.forbidden_macros `
        $script:GswCompileExpectedForbiddenMacros 'compile plan.compile.forbidden_macros'

    Assert-GswJsonExactProperties $Plan.normalization @(
        'format', 'machine', 'timestamp_offset', 'timestamp_bytes',
        'optional_header_bytes', 'normalized_output'
    ) 'compile plan.normalization'
    Assert-GswCompileString $Plan.normalization.format 'coff-i386' `
        'compile plan.normalization.format'
    Assert-GswCompileInteger $Plan.normalization.machine 332 `
        'compile plan.normalization.machine'
    Assert-GswCompileInteger $Plan.normalization.timestamp_offset 4 `
        'compile plan.normalization.timestamp_offset'
    Assert-GswCompileInteger $Plan.normalization.timestamp_bytes 4 `
        'compile plan.normalization.timestamp_bytes'
    Assert-GswCompileInteger $Plan.normalization.optional_header_bytes 0 `
        'compile plan.normalization.optional_header_bytes'
    Assert-GswJsonExactProperties $Plan.normalization.normalized_output @(
        'bytes', 'sha256'
    ) 'compile plan.normalization.normalized_output'
    Assert-GswCompileInteger $Plan.normalization.normalized_output.bytes 4066 `
        'compile plan.normalization.normalized_output.bytes'
    Assert-GswCompileString $Plan.normalization.normalized_output.sha256 `
        'b69a37e5561c03ea9c7699a0ea394912d2c9a8a429c22886a5080524dbe0d6b6' `
        'compile plan.normalization.normalized_output.sha256'

    Assert-GswCompileArray $Plan.forbidden_backend_tokens `
        $script:GswCompileExpectedForbiddenBackends `
        'compile plan.forbidden_backend_tokens'

    Assert-GswJsonExactProperties $Plan.claims @(
        'temporary_compile_proven', 'dll_link_authorized',
        'production_build_authorized', 'build_profile_dependency_satisfied',
        'staging_authorized', 'guest_install_authorized',
        'capability_advertisement_authorized'
    ) 'compile plan.claims'
    Assert-GswCompileBoolean $Plan.claims.temporary_compile_proven $true `
        'compile plan.claims.temporary_compile_proven'
    foreach ($name in @(
        'dll_link_authorized', 'production_build_authorized',
        'build_profile_dependency_satisfied', 'staging_authorized',
        'guest_install_authorized', 'capability_advertisement_authorized'
    )) {
        Assert-GswCompileBoolean $Plan.claims.$name $false "compile plan.claims.$name"
    }
}

function Assert-GswCompileSnapshot {
    param(
        [string]$Path,
        [UInt64]$Bytes,
        [string]$Sha256,
        [string]$Name,
        [UInt64]$MaximumBytes
    )

    $snapshot = Read-GswBoundedFileSnapshot -Path $Path -Name $Name `
        -MaximumBytes $MaximumBytes
    if ($snapshot.Length -ne $Bytes -or $snapshot.Sha256 -cne $Sha256) {
        throw "$Name does not match its compile-plan descriptor."
    }
    return $snapshot
}

function ConvertTo-GswCompileProcessArgument {
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

function Get-GswCompileNativeMethodsType {
    $existing = 'Retvrn99.GswCompileNativeMethods' -as [type]
    if ($null -ne $existing) { return $existing }

    $assemblyName = [Reflection.AssemblyName]::new(
        'Retvrn99.GswCompileNativeMethods.Dynamic'
    )
    $access = [Reflection.Emit.AssemblyBuilderAccess]::Run
    $staticFactory = [Reflection.Emit.AssemblyBuilder].GetMethod(
        'DefineDynamicAssembly',
        [Reflection.BindingFlags]'Public,Static',
        $null,
        [type[]]@([Reflection.AssemblyName], [Reflection.Emit.AssemblyBuilderAccess]),
        $null
    )
    if ($null -ne $staticFactory) {
        $assembly = $staticFactory.Invoke($null, @($assemblyName, $access))
    }
    else {
        $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            $assemblyName, $access
        )
    }
    $module = $assembly.DefineDynamicModule('NativeMethods')
    $attributes = [Reflection.TypeAttributes]'Public,Abstract,Sealed'
    $typeBuilder = $module.DefineType(
        'Retvrn99.GswCompileNativeMethods', $attributes
    )
    $method = $typeBuilder.DefinePInvokeMethod(
        'SetErrorMode',
        'kernel32.dll',
        [Reflection.MethodAttributes]'Public,Static,PinvokeImpl',
        [Reflection.CallingConventions]::Standard,
        [UInt32],
        [type[]]@([UInt32]),
        [Runtime.InteropServices.CallingConvention]::Winapi,
        [Runtime.InteropServices.CharSet]::Auto
    )
    $method.SetImplementationFlags(
        $method.GetMethodImplementationFlags() -bor
        [Reflection.MethodImplAttributes]::PreserveSig
    )
    if ($typeBuilder.PSObject.Methods.Name -contains 'CreateTypeInfo') {
        return $typeBuilder.CreateTypeInfo().AsType()
    }
    return $typeBuilder.CreateType()
}

function Assert-GswCompileProcessPolicy {
    param(
        [UInt32]$ErrorMode,
        [string]$PathValue,
        [string]$ToolBin,
        [int]$TimeoutSeconds,
        [string]$TerminationSwitches
    )

    if ($ErrorMode -ne [UInt32]0x8003) {
        throw 'Compiler child error mode must suppress critical, GP-fault, and open-file dialogs.'
    }
    $expectedPath = $ToolBin + ';' + [Environment]::GetFolderPath('System')
    if ($PathValue -cne $expectedPath) {
        throw 'Compiler child PATH must contain only pinned toolchain bin and System32.'
    }
    if ($TimeoutSeconds -ne 10) {
        throw 'Compiler child timeout must remain exactly 10 seconds.'
    }
    if ($TerminationSwitches -cne '/T /F') {
        throw 'Compiler timeout cleanup must terminate the exact child tree.'
    }
}

function Start-GswCompileSuppressedProcess {
    param([Diagnostics.Process]$Process)

    $nativeMethods = Get-GswCompileNativeMethodsType
    [Threading.Monitor]::Enter($script:GswCompileErrorModeLock)
    try {
        [UInt32]$previous = $nativeMethods::SetErrorMode(
            $script:GswCompileChildErrorMode
        )
        [UInt32]$effective = $previous -bor $script:GswCompileChildErrorMode
        if ($effective -ne $script:GswCompileChildErrorMode) {
            [void]$nativeMethods::SetErrorMode($effective)
        }
        try {
            return $Process.Start()
        }
        finally {
            [void]$nativeMethods::SetErrorMode($previous)
        }
    }
    finally {
        [Threading.Monitor]::Exit($script:GswCompileErrorModeLock)
    }
}

function Stop-GswCompileProcessTree {
    param([Diagnostics.Process]$Process)

    if ($Process.HasExited) { return }
    $windows = [Environment]::GetFolderPath('Windows')
    $taskkill = Join-Path $windows 'System32\taskkill.exe'
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $taskkill
    $terminationSwitches = '/T /F'
    $info.Arguments = "/PID $($Process.Id) $terminationSwitches"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $killer = [Diagnostics.Process]::new()
    $killer.StartInfo = $info
    $killerStarted = $false
    try {
        $killerStarted = [bool](Start-GswCompileSuppressedProcess $killer)
        if ($killerStarted -and -not $killer.WaitForExit(5000)) {
            $killer.Kill()
            [void]$killer.WaitForExit(5000)
        }
    }
    catch {
        # Parent fallback below remains mandatory.
    }
    finally {
        if ($killerStarted) {
            try {
                if (-not $killer.HasExited) {
                    $killer.Kill()
                    [void]$killer.WaitForExit(5000)
                }
            }
            catch {
                # Parent fallback below remains mandatory.
            }
        }
        $killer.Dispose()
    }

    if (-not $Process.HasExited) {
        try { $Process.Kill() }
        catch { }
        try { [void]$Process.WaitForExit(5000) }
        catch { }
    }
    if (-not $Process.HasExited) {
        throw 'Compiler child tree remained live after bounded cleanup.'
    }
}

function Invoke-GswCompileProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$ToolBin,
        [string]$PrivateTemp,
        [int]$TimeoutSeconds,
        [string]$Name
    )

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Arguments = (($Arguments | ForEach-Object {
        ConvertTo-GswCompileProcessArgument ([string]$_)
    }) -join ' ')
    foreach ($ambient in @(
        'GCC_EXEC_PREFIX', 'COMPILER_PATH', 'LIBRARY_PATH', 'CPATH',
        'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
        'DEPENDENCIES_OUTPUT', 'SUNPRO_DEPENDENCIES', 'GCC_COMPARE_DEBUG',
        'GCC_COMPARE_DEBUG_EXEC'
    )) {
        [void]$info.EnvironmentVariables.Remove($ambient)
    }
    $systemDirectory = [Environment]::GetFolderPath('System')
    $childPath = $ToolBin + ';' + $systemDirectory
    $terminationSwitches = '/T /F'
    Assert-GswCompileProcessPolicy `
        -ErrorMode $script:GswCompileChildErrorMode `
        -PathValue $childPath `
        -ToolBin $ToolBin `
        -TimeoutSeconds $TimeoutSeconds `
        -TerminationSwitches $terminationSwitches
    $info.EnvironmentVariables['PATH'] = $childPath
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
        $started = [bool](Start-GswCompileSuppressedProcess $process)
        if (-not $started) { throw "$Name did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "$Name exceeded its $TimeoutSeconds-second process bound."
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = ($stderr + "`n" + $stdout).Trim()
            if ($detail.Length -gt 2048) { $detail = $detail.Substring(0, 2048) }
            throw "$Name failed with exit code $($process.ExitCode): $detail"
        }
        return [pscustomobject]@{ Stdout = $stdout; Stderr = $stderr }
    }
    finally {
        try {
            if ($started) { Stop-GswCompileProcessTree $process }
        }
        finally {
            $process.Dispose()
        }
    }
}

function Get-GswCompileRootFlags {
    param([string]$BuildRoot)

    $gccRoot = $BuildRoot.Replace('\', '/')
    return @(
        "-ffile-prefix-map=$gccRoot=.",
        "-fmacro-prefix-map=$gccRoot=.",
        "-I$gccRoot/include"
    )
}

function Assert-GswCompileMacros {
    param([string]$Text, [object]$Plan)

    foreach ($macro in $Plan.compile.required_macros) {
        if (-not [regex]::IsMatch(
                $Text,
                '(?m)^#define\s+' + [regex]::Escape([string]$macro) + '(\s|$)'
            )) {
            throw "Required guest compile macro '$macro' is absent."
        }
    }
    foreach ($macro in $Plan.compile.forbidden_macros) {
        if ([regex]::IsMatch(
                $Text,
                '(?m)^#define\s+' + [regex]::Escape([string]$macro) + '(\s|$)'
            )) {
            throw "Forbidden guest compile macro '$macro' is present."
        }
    }
}

function Normalize-GswCompileObject {
    param([string]$Path, [object]$Plan, [string]$BuildRoot)

    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 20 -or $bytes.Length -gt 1048576) {
        throw 'Compiler output is not a bounded COFF object.'
    }
    if ([BitConverter]::ToUInt16($bytes, 0) -ne [UInt16]$Plan.normalization.machine) {
        throw 'Compiler output is not IMAGE_FILE_MACHINE_I386 COFF.'
    }
    if ([BitConverter]::ToUInt16($bytes, 16) -ne
        [UInt16]$Plan.normalization.optional_header_bytes) {
        throw 'Compiler output contains an unexpected optional header.'
    }
    for ($index = [int]$Plan.normalization.timestamp_offset;
        $index -lt [int]$Plan.normalization.timestamp_offset +
            [int]$Plan.normalization.timestamp_bytes;
        $index++) {
        $bytes[$index] = 0
    }
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    foreach ($spelling in @($BuildRoot, $BuildRoot.Replace('\', '/'))) {
        if ($ascii.IndexOf($spelling, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw 'Normalized compiler output exposes its private build root.'
        }
    }
    [IO.File]::WriteAllBytes($Path, $bytes)
    return ,$bytes
}

function Remove-GswCompileTempRoot {
    param([string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]'\/'
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
            $tempRoot, [StringComparison]::OrdinalIgnoreCase
        ) -or (Split-Path -Leaf $fullPath) -notlike
            'retvrn99-mesa-gsw-compile-*') {
        throw "Refusing to remove unsafe compile root '$fullPath'."
    }
    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to remove reparse compile root '$fullPath'."
        }
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function Invoke-GswMesaOriginalCompileProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$MesaCheckoutPath,
        [Parameter(Mandatory = $true)][string]$ToolchainRootPath,
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [scriptblock]$BeforeFinalCheck
    )

    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $moduleRoot = Join-Path $repoRoot 'drivers\win98\mesa-gsw'
    $planSnapshot = Read-GswStrictJsonFileSnapshot -Path $PlanPath `
        -Name 'Original GSW compile plan' `
        -MaximumBytes $script:GswCompileMaximumMetadataBytes
    $plan = $planSnapshot.Value
    Assert-GswCompilePlan $plan

    $schemaPath = Join-Path (Split-Path -Parent $planSnapshot.Path) `
        $plan.schema_definition.relative_path
    $schemaSnapshot = Read-GswStrictJsonFileSnapshot -Path $schemaPath `
        -Name 'Original GSW compile-plan schema' `
        -MaximumBytes $script:GswCompileMaximumMetadataBytes
    if ($schemaSnapshot.Sha256 -cne $script:GswCompileSchemaSha256) {
        throw 'Original GSW compile-plan schema digest mismatch.'
    }
    Assert-GswJsonExactProperties $schemaSnapshot.Value @(
        '_spdx', '$schema', '$id', 'title', 'type', 'additionalProperties',
        'required', 'properties', '$defs'
    ) 'Original GSW compile-plan schema'
    Assert-GswCompileString $schemaSnapshot.Value._spdx 'GPL-3.0-only' `
        'Original GSW compile-plan schema._spdx'
    Assert-GswCompileString $schemaSnapshot.Value.'$id' `
        'compile-plan.schema.json' 'Original GSW compile-plan schema.$id'

    $cpuProfilePath = Join-Path $repoRoot 'drivers\win98\guest-cpu-profile.json'
    $cpuVerifierPath = Join-Path $repoRoot `
        'scripts\verify-win98-guest-cpu-profile.ps1'
    $sourceLockPath = Join-Path $moduleRoot 'interface-inputs.lock.json'
    $sourceVerifierPath = Join-Path $repoRoot `
        'scripts\verify-win98-mesa-gsw-original-source.ps1'
    $toolchainLockPath = Join-Path $repoRoot 'drivers\win98\mingw32-toolchain.lock.json'
    $toolchainVerifierPath = Join-Path $repoRoot `
        'scripts\verify-win98-driver-toolchain.ps1'
    $tracked = @()
    $cpuProfileSnapshot = Assert-GswCompileSnapshot $cpuProfilePath 3537 `
        '969b45df75c6e1d8366e6ef7468a51f04c42441914ce564ae19f62a07cad0f57' `
        'Guest CPU profile' $script:GswCompileMaximumMetadataBytes
    $tracked += $cpuProfileSnapshot
    $tracked += Assert-GswCompileSnapshot $cpuVerifierPath 28631 `
        'c0e0f0c67e1cc820a2188f005adf4c3f65a449ec40d47b1826ac1ba3f74abaf6' `
        'Guest CPU profile verifier' $script:GswCompileMaximumMetadataBytes
    $tracked += Assert-GswCompileSnapshot $sourceLockPath 4336 `
        '8b64bed0e4b110b1526ff1bae136b38f23c8441c9a0a64d1d35ff74ebce77f22' `
        'Original GSW source lock' $script:GswCompileMaximumMetadataBytes
    $tracked += Assert-GswCompileSnapshot $sourceVerifierPath 29048 `
        'c4aca411f190e50a40cb9acdb294901c645977983f8fc4839392ce7e10ff67e3' `
        'Original GSW source verifier' $script:GswCompileMaximumMetadataBytes
    $tracked += Assert-GswCompileSnapshot $toolchainLockPath 792 `
        'db3a84b7388937a5ffd5ab3e30429bae4c3ca5d8d17f095a491a42bc82413a12' `
        'MinGW32 toolchain lock' $script:GswCompileMaximumMetadataBytes
    $tracked += Assert-GswCompileSnapshot $toolchainVerifierPath 24574 `
        '4a38d41118a3812eb7ccc973cd0706c2edbc92656c78f34941f8c7ca96868291' `
        'MinGW32 toolchain verifier' $script:GswCompileMaximumMetadataBytes

    $inputSnapshots = @()
    foreach ($input in $script:GswCompileExpectedInputs) {
        $path = Join-Path $moduleRoot ($input.relative_path.Replace('/', '\'))
        $snapshot = Assert-GswCompileSnapshot $path $input.bytes $input.sha256 `
            "Compile input '$($input.relative_path)'" `
            $script:GswCompileMaximumInputBytes
        $inputSnapshots += $snapshot
        $tracked += $snapshot
        $text = ConvertFrom-GswStrictUtf8Bytes -Bytes $snapshot.Bytes `
            -Source "Compile input '$($input.relative_path)'"
        foreach ($token in $plan.forbidden_backend_tokens) {
            if ($text.IndexOf(
                    [string]$token, [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                throw "Compile input '$($input.relative_path)' references forbidden backend '$token'."
            }
        }
    }

    $cpuEvidence = @(& $cpuVerifierPath -ProfileFile $cpuProfilePath -PolicyAudit)
    if ($cpuEvidence.Count -ne 1 -or
        [string]$cpuEvidence[0] -notlike 'Policy-audited blocked guest CPU profile*') {
        throw 'Guest CPU profile verifier did not return its fixed policy evidence line.'
    }
    $cpuProfile = ConvertFrom-GswStrictJsonUtf8Bytes `
        -Bytes $cpuProfileSnapshot.Bytes -Source 'Guest CPU profile compile input'
    if ($cpuProfile.profile_id -cne $plan.guest_cpu_profile.profile_id -or
        $cpuProfile.toolchains.mingw.toolchain_id -cne $plan.toolchain.name -or
        $cpuProfile.toolchains.mingw.target -cne $plan.compile.target -or
        $cpuProfile.toolchains.mingw.compiler.sha256 -cne
            $plan.toolchain.compiler.sha256 -or
        $cpuProfile.toolchains.mingw.objdump.sha256 -cne
            $plan.toolchain.inspector.sha256) {
        throw 'Guest CPU profile does not bind this compile plan and toolchain.'
    }
    Assert-GswJsonArray $cpuProfile.toolchains.mingw.cpu_flags `
        'guest CPU profile MinGW cpu_flags'
    $cpuFlags = @()
    $seenCpuFlags = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($flag in $cpuProfile.toolchains.mingw.cpu_flags) {
        Assert-GswJsonString $flag 'guest CPU profile MinGW cpu_flag'
        if ([string]$flag -cnotmatch '^-m[a-z0-9.=+-]+$' -or
            -not $seenCpuFlags.Add([string]$flag)) {
            throw "Guest CPU profile contains unsafe or duplicate MinGW cpu_flag '$flag'."
        }
        $cpuFlags += [string]$flag
    }
    if ($cpuFlags.Count -eq 0) {
        throw 'Guest CPU profile supplies no MinGW cpu_flags.'
    }

    $sourceEvidence = @(& $sourceVerifierPath -MesaCheckout $MesaCheckoutPath `
        -LockFile $sourceLockPath)
    if ($sourceEvidence.Count -ne 1 -or
        [string]$sourceEvidence[0] -notlike 'Verified original GSW Mesa source Module:*') {
        throw 'Original GSW source verifier did not return its fixed evidence line.'
    }
    $toolchainEvidence = @(& $toolchainVerifierPath `
        -ToolchainRoot $ToolchainRootPath -LockFile $toolchainLockPath)
    if ($toolchainEvidence.Count -ne 1 -or
        [string]$toolchainEvidence[0] -notlike 'Verified Windows 98 toolchain*') {
        throw 'Pinned MinGW32 toolchain verifier did not return its evidence line.'
    }

    $extractedRoot = Join-Path ([IO.Path]::GetFullPath($ToolchainRootPath)) `
        $plan.toolchain.extracted_relative_path
    Assert-GswNoReparseAncestor $extractedRoot 'Pinned MinGW32 extracted root'
    $extractedItem = Get-Item -LiteralPath $extractedRoot -Force
    if (($extractedItem.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        ($extractedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Pinned MinGW32 extracted root is not an ordinary directory.'
    }
    $compilerPath = Join-Path $extractedRoot `
        ($plan.toolchain.compiler.relative_path.Replace('/', '\'))
    $inspectorPath = Join-Path $extractedRoot `
        ($plan.toolchain.inspector.relative_path.Replace('/', '\'))
    $compilerSnapshot = Assert-GswCompileSnapshot $compilerPath 3147424 `
        '0c79d47814364067e560ba4d26849126388a44fc5765d33df00c1fdd582c89a9' `
        'Pinned i686 compiler' $script:GswCompileMaximumToolBytes
    $inspectorSnapshot = Assert-GswCompileSnapshot $inspectorPath 2207753 `
        '3a3309d8a8f8898193d5e41e73085d8c8702a1efe296c6236a48f925fc5411f5' `
        'Pinned COFF inspector' $script:GswCompileMaximumToolBytes
    $tracked += $compilerSnapshot
    $tracked += $inspectorSnapshot

    $proofRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'retvrn99-mesa-gsw-compile-' + [Guid]::NewGuid().ToString('N')
    )
    [void][IO.Directory]::CreateDirectory($proofRoot)
    try {
        $results = @()
        foreach ($runName in @('first', 'second')) {
            $buildRoot = Join-Path $proofRoot $runName
            foreach ($directory in @('include', 'src', 'probes', 'out', 'temp')) {
                [void][IO.Directory]::CreateDirectory((Join-Path $buildRoot $directory))
            }
            foreach ($snapshot in $inputSnapshots) {
                $input = $script:GswCompileExpectedInputs |
                    Where-Object { $_.sha256 -ceq $snapshot.Sha256 } |
                    Select-Object -First 1
                if ($null -eq $input) { throw 'Compile input snapshot lost its descriptor.' }
                $destination = Join-Path $buildRoot `
                    ($input.relative_path.Replace('/', '\'))
                [IO.File]::WriteAllBytes($destination, [byte[]]$snapshot.Bytes)
            }
            $flags = @($plan.compile.prefix_flags) + @($cpuFlags) +
                @($plan.compile.suffix_flags) + @(Get-GswCompileRootFlags $buildRoot)
            $toolBin = Split-Path -Parent $compilerPath
            $privateTemp = Join-Path $buildRoot 'temp'
            [void](Invoke-GswCompileProcess -FilePath $compilerPath `
                -Arguments ($flags + @('-fsyntax-only', $plan.compile.probe)) `
                -WorkingDirectory $buildRoot -ToolBin $toolBin `
                -PrivateTemp $privateTemp `
                -TimeoutSeconds ([int]$plan.compile.process_timeout_seconds) `
                -Name "$runName interface and CPU probe")
            $macroPath = Join-Path $buildRoot 'out\macros.txt'
            [void](Invoke-GswCompileProcess -FilePath $compilerPath `
                -Arguments ($flags + @(
                    '-dM', '-E', $plan.compile.probe, '-o', 'out/macros.txt'
                )) -WorkingDirectory $buildRoot -ToolBin $toolBin `
                -PrivateTemp $privateTemp `
                -TimeoutSeconds ([int]$plan.compile.process_timeout_seconds) `
                -Name "$runName macro probe")
            $macroBytes = [IO.File]::ReadAllBytes($macroPath)
            $macroText = ConvertFrom-GswStrictUtf8Bytes -Bytes $macroBytes `
                -Source "$runName macro probe output"
            Assert-GswCompileMacros $macroText $plan
            [void](Invoke-GswCompileProcess -FilePath $compilerPath `
                -Arguments ($flags + @(
                    '-c', $plan.compile.source, '-o', $plan.compile.temporary_output
                )) -WorkingDirectory $buildRoot -ToolBin $toolBin `
                -PrivateTemp $privateTemp `
                -TimeoutSeconds ([int]$plan.compile.process_timeout_seconds) `
                -Name "$runName implementation compile")
            $objectPath = Join-Path $buildRoot `
                ($plan.compile.temporary_output.Replace('/', '\'))
            [byte[]]$normalized = Normalize-GswCompileObject $objectPath $plan $buildRoot
            $normalizedHash = Get-GswSha256Hex $normalized
            $inspection = Invoke-GswCompileProcess -FilePath $inspectorPath `
                -Arguments @('-f', $plan.compile.temporary_output) `
                -WorkingDirectory $buildRoot -ToolBin $toolBin `
                -PrivateTemp $privateTemp `
                -TimeoutSeconds ([int]$plan.compile.process_timeout_seconds) `
                -Name "$runName COFF inspection"
            if ($inspection.Stdout -cnotmatch 'file format pe-i386' -or
                $inspection.Stdout -cnotmatch 'architecture: i386') {
                throw "$runName compiler output failed i386 COFF inspection."
            }
            $results += [pscustomobject]@{
                Bytes = [UInt64]$normalized.Length
                Sha256 = $normalizedHash
                Data = [Convert]::ToBase64String($normalized)
            }
        }
        if ($results.Count -ne 2 -or $results[0].Bytes -ne $results[1].Bytes -or
            $results[0].Data -cne $results[1].Data) {
            throw 'The two clean normalized i686 COFF outputs are not byte-identical.'
        }
        if ($results[0].Bytes -ne
                [UInt64]$plan.normalization.normalized_output.bytes -or
            $results[0].Sha256 -cne
                $plan.normalization.normalized_output.sha256) {
            throw (
                'Byte-identical normalized COFF outputs do not match the fixed ' +
                "descriptor: expected $($plan.normalization.normalized_output.bytes) " +
                "bytes / $($plan.normalization.normalized_output.sha256), observed " +
                "$($results[0].Bytes) bytes / $($results[0].Sha256)."
            )
        }

        if ($null -ne $BeforeFinalCheck) { & $BeforeFinalCheck }

        $finalPlan = Read-GswBoundedFileSnapshot -Path $planSnapshot.Path `
            -Name 'Original GSW compile plan final recheck' `
            -MaximumBytes $script:GswCompileMaximumMetadataBytes
        $finalSchema = Read-GswBoundedFileSnapshot -Path $schemaSnapshot.Path `
            -Name 'Original GSW compile-plan schema final recheck' `
            -MaximumBytes $script:GswCompileMaximumMetadataBytes
        if ($finalPlan.Length -ne $planSnapshot.Length -or
            $finalPlan.Sha256 -cne $planSnapshot.Sha256 -or
            $finalSchema.Length -ne $schemaSnapshot.Length -or
            $finalSchema.Sha256 -cne $schemaSnapshot.Sha256) {
            throw 'Original GSW compile metadata changed during the proof.'
        }
        foreach ($snapshot in $tracked) {
            $final = Read-GswBoundedFileSnapshot -Path $snapshot.Path `
                -Name "Compile-bound file '$($snapshot.Path)' final recheck" `
                -MaximumBytes ([UInt64][Math]::Max(
                    [double]$script:GswCompileMaximumToolBytes,
                    [double]$snapshot.Length
                ))
            if ($final.Length -ne $snapshot.Length -or
                $final.Sha256 -cne $snapshot.Sha256) {
                throw "Compile-bound file '$($snapshot.Path)' changed during the proof."
            }
        }

        return [pscustomobject]@{
            Bytes = $results[0].Bytes
            Sha256 = $results[0].Sha256
            Runs = 2
            Target = 'i686-w64-mingw32'
            TemporaryOnly = $true
        }
    }
    finally {
        Remove-GswCompileTempRoot $proofRoot
    }
}

if ($MyInvocation.InvocationName -cne '.') {
    if ([string]::IsNullOrWhiteSpace($PlanFile)) {
        $PlanFile = Join-Path $PSScriptRoot `
            '..\drivers\win98\mesa-gsw\compile-plan.json'
    }
    $result = Invoke-GswMesaOriginalCompileProof `
        -MesaCheckoutPath $MesaCheckout `
        -ToolchainRootPath $ToolchainRoot `
        -PlanPath $PlanFile `
        -BeforeFinalCheck $BeforeFinalStabilityCheck
    Write-Output (
        "Verified deterministic compile-only GSW Mesa proof: $($result.Runs) " +
        "byte-identical temporary i686 COFF objects, $($result.Bytes) bytes, " +
        "SHA-256 $($result.Sha256); no DLL, stage, install, or capability claim."
    )
}

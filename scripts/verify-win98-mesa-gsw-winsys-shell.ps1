# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MesaCheckout = 'D:\src\retvrn99-win98\mesa9x',
    [string]$ToolchainRoot = 'D:\src\retvrn99-win98\toolchains',
    [string]$LockFile,
    [switch]$SkipCompile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requestedMesaCheckout = $MesaCheckout
$requestedToolchainRoot = $ToolchainRoot
. (Join-Path $PSScriptRoot 'verify-win98-mesa-gsw-original-source.ps1') `
    -MesaCheckout $requestedMesaCheckout
. (Join-Path $PSScriptRoot 'build-win98-mesa-gsw-original-source.ps1') `
    -MesaCheckout $requestedMesaCheckout -ToolchainRoot $requestedToolchainRoot
$MesaCheckout = $requestedMesaCheckout
$ToolchainRoot = $requestedToolchainRoot

$script:GswWinsysExpectedInputs = @(
    'mesa-23.1.x/src/gallium/drivers/svga/svga_winsys.h',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_screen.c',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_context.c',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_cmd.c',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_resource_buffer.c',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_resource_texture.c',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_pipe_query.c',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_pipe_flush.c',
    'mesa-23.1.x/src/gallium/drivers/svga/svga_shader.c'
)
$script:GswWinsysProhibitedPrefixes = @(
    'mesa-23.1.x/src/gallium/winsys/svga/drm/',
    'win9x/winsys/',
    'win9x/3d_svga.c',
    'win9x/ossvga_target.c',
    'win9x/svgadrv.c',
    'win9x/svgadrv.h',
    'win9x/svgadrv_cb.c',
    'win9x/svgadrv_cmds.h',
    'win9x/svgadrv_present.c',
    'win9x/wddm_screen.h'
)
$script:GswWinsysScreenCallbacks = @(
    'destroy', 'get_hw_version', 'get_fd', 'get_cap', 'context_create',
    'surface_create', 'surface_from_handle', 'surface_get_handle',
    'surface_is_flushed', 'surface_reference', 'surface_can_create',
    'surface_init', 'buffer_create', 'buffer_map', 'buffer_unmap',
    'buffer_destroy', 'fence_reference', 'fence_signalled', 'fence_finish',
    'fence_get_fd', 'fence_create_fd', 'fence_server_sync', 'shader_create',
    'shader_destroy', 'query_create', 'query_destroy', 'query_init',
    'query_get_result', 'stats_inc', 'stats_time_push', 'stats_time_pop',
    'host_log'
)
$script:GswWinsysContextCallbacks = @(
    'destroy', 'reserve', 'get_command_buffer_size', 'surface_relocation',
    'region_relocation', 'shader_relocation', 'context_relocation',
    'mob_relocation', 'query_relocation', 'query_bind', 'commit', 'flush',
    'surface_map', 'surface_unmap', 'shader_create', 'shader_destroy',
    'resource_rebind'
)

function Get-GswWinsysSha256 {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Read-GswWinsysFile {
    param([string]$Path, [UInt64]$MaximumBytes = 1048576)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or [UInt64]$item.Length -eq 0 -or
        [UInt64]$item.Length -gt $MaximumBytes) {
        throw "Invalid bounded file '$Path'."
    }
    return ,([IO.File]::ReadAllBytes($item.FullName))
}

function ConvertFrom-GswWinsysUtf8 {
    param([byte[]]$Bytes, [string]$Source)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) {
        throw "$Source has a UTF-8 BOM."
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    if ($text.Contains("`r") -or -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "$Source is not normalized LF text."
    }
    return $text
}

function Get-GswWinsysFunctionBody {
    param([string]$Source, [string]$Name)
    $pattern = '(?ms)^' + [regex]::Escape($Name) + '\([^\)]*\)\s*\{(?<body>.*?)^\}'
    $match = [regex]::Match($Source, $pattern)
    if (-not $match.Success) { throw "Missing function body '$Name'." }
    return $match.Groups['body'].Value
}

function Assert-GswWinsysCallbacks {
    param(
        [string]$InterfaceText,
        [string]$SourceText,
        [string]$StructName,
        [string]$InitializerName,
        [string]$Receiver,
        [string[]]$Expected
    )
    $structPattern = '(?ms)struct\s+' + [regex]::Escape($StructName) +
        '\s*\{(?<body>.*?)^\};'
    $structMatch = [regex]::Match($InterfaceText, $structPattern)
    if (-not $structMatch.Success) { throw "Missing Interface struct '$StructName'." }
    $declared = @([regex]::Matches(
        $structMatch.Groups['body'].Value,
        '\(\*([A-Za-z_][A-Za-z0-9_]*)\)'
    ) | ForEach-Object { $_.Groups[1].Value })
    if ($declared.Count -ne $Expected.Count -or
        [string]::Join('|', $declared) -cne [string]::Join('|', $Expected)) {
        throw "$StructName callback declaration set changed."
    }
    $body = Get-GswWinsysFunctionBody $SourceText $InitializerName
    foreach ($name in $Expected) {
        $matches = [regex]::Matches(
            $body,
            '(?m)^\s*' + [regex]::Escape($Receiver) + '->' +
                [regex]::Escape($name) + '\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*;'
        )
        if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -ceq 'NULL') {
            throw "$StructName callback '$name' is not populated exactly once."
        }
    }
}

function Assert-GswWinsysSemantics {
    param([string]$SourceText, [string]$ScreenCallerText)

    $returns = @(
        @('gsw_get_hw_version', 'return\s+SVGA3D_HWVERSION_WS65_B1\s*;'),
        @('gsw_get_fd', 'return\s+-1\s*;'),
        @('gsw_get_cap', 'return\s+FALSE\s*;'),
        @('gsw_context_reserve', 'return\s+NULL\s*;'),
        @('gsw_context_command_buffer_size', 'return\s+0\s*;'),
        @('gsw_query_bind', 'return\s+PIPE_ERROR\s*;'),
        @('gsw_context_flush', 'return\s+PIPE_ERROR\s*;'),
        @('gsw_context_surface_map', 'return\s+NULL\s*;'),
        @('gsw_context_shader_create', 'return\s+NULL\s*;'),
        @('gsw_context_resource_rebind', 'return\s+PIPE_ERROR\s*;'),
        @('gsw_surface_create', 'return\s+NULL\s*;'),
        @('gsw_surface_from_handle', 'return\s+NULL\s*;'),
        @('gsw_surface_get_handle', 'return\s+FALSE\s*;'),
        @('gsw_surface_is_flushed', 'return\s+FALSE\s*;'),
        @('gsw_surface_can_create', 'return\s+FALSE\s*;'),
        @('gsw_buffer_create', 'return\s+NULL\s*;'),
        @('gsw_buffer_map', 'return\s+NULL\s*;'),
        @('gsw_fence_signalled', 'return\s+-1\s*;'),
        @('gsw_fence_finish', 'return\s+-1\s*;'),
        @('gsw_fence_get_fd', 'return\s+-1\s*;'),
        @('gsw_fence_server_sync', 'return\s+-1\s*;'),
        @('gsw_shader_create', 'return\s+NULL\s*;'),
        @('gsw_query_create', 'return\s+NULL\s*;'),
        @('gsw_query_init', 'return\s+-1\s*;')
    )
    foreach ($entry in $returns) {
        $body = Get-GswWinsysFunctionBody $SourceText $entry[0]
        if (-not [regex]::IsMatch($body, $entry[1])) {
            throw "Disabled operation '$($entry[0])' no longer rejects deterministically."
        }
    }
    $ownershipBody = Get-GswWinsysFunctionBody `
        $SourceText 'gsw_svga_winsys_screen_try_create'
    if (-not [regex]::IsMatch(
            $ownershipBody,
            '(?s)screen\s*=\s*create_screen\(sws\);.*?if\s*\(screen\s*==\s*NULL\).*?sws->destroy\(sws\);'
        )) {
        throw 'Failed Mesa screen creation does not release retained winsys ownership.'
    }
    foreach ($entry in @(
        @('gsw_svga_winsys_screen_destroy', 'if\s*\(sws\s*!=\s*NULL\)'),
        @('gsw_context_destroy', 'if\s*\(swc\s*!=\s*NULL\)'),
        @('gsw_surface_reference', 'if\s*\(destination\s*!=\s*NULL\)'),
        @('gsw_fence_reference', 'if\s*\(destination\s*!=\s*NULL\)')
    )) {
        $body = Get-GswWinsysFunctionBody $SourceText $entry[0]
        if (-not [regex]::IsMatch($body, $entry[1])) {
            throw "Cleanup operation '$($entry[0])' is not null-safe."
        }
    }
    foreach ($name in @(
        'have_gb_objects', 'have_gb_dma', 'have_coherent', 'have_vgpu10',
        'have_sm4_1', 'have_sm5', 'need_to_rebind_resources',
        'have_generate_mipmap_cmd', 'have_set_predication_cmd',
        'have_transfer_from_buffer_cmd', 'have_fence_fd',
        'have_intra_surface_copy', 'have_constant_buffer_offset_cmd',
        'have_index_vertex_buffer_offset_cmd', 'have_rasterizer_state_v2_cmd',
        'have_gl43'
    )) {
        if (-not [regex]::IsMatch(
                $SourceText,
                '(?m)^\s*sws->' + [regex]::Escape($name) + '\s*=\s*(FALSE|false);$'
            )) {
            throw "Capability field '$name' is not explicitly false."
        }
    }
    foreach ($pattern in @(
        '(?i)\bvmw_', '(?i)\bvbox', '(?i)virtualbox',
        'winsys/svga/drm', '(?i)win9x/', '\bSVGA_FIFO_[A-Za-z0-9_]+',
        '\bCreateFile[A-Z]?\s*\(', '\bDeviceIoControl\s*\(',
        '\bgsw3d_[A-Za-z0-9_]*submit[A-Za-z0-9_]*\s*\('
    )) {
        if ([regex]::IsMatch($SourceText, $pattern)) {
            throw "Prohibited implementation or ABI token matched '$pattern'."
        }
    }
    if ([regex]::IsMatch($SourceText, 'abi_submission_count\s*(\+\+|--|[+\-]?=)')) {
        throw 'ABI submission count is mutable in the disabled shell.'
    }
    if (-not [regex]::IsMatch(
            $ScreenCallerText,
            '(?s)hw_version\s*<\s*SVGA3D_HWVERSION_WS8_B1.*?goto error2;'
        ) -or -not [regex]::IsMatch(
            $ScreenCallerText,
            '(?s)error2:\s*FREE\(svgascreen\);\s*error1:\s*return NULL;'
        )) {
        throw 'Pinned Mesa failed-create ownership contract changed.'
    }
}

function Invoke-GswWinsysCompileCheck {
    param([string]$ModuleRoot, [string]$Checkout, [string]$Toolchains)

    $profilePath = Join-Path (Split-Path -Parent $ModuleRoot) 'guest-cpu-profile.json'
    $profileBytes = Read-GswWinsysFile $profilePath 65536
    $profile = ConvertFrom-GswStrictJson `
        -Json (ConvertFrom-GswWinsysUtf8 $profileBytes $profilePath) -Source $profilePath
    $toolchainPath = Join-Path $Toolchains 'msys2-mingw32-gcc15.2.0-20260717'
    $toolBin = Join-Path $toolchainPath 'bin'
    $compiler = Join-Path $toolBin 'i686-w64-mingw32-gcc.exe'
    if (-not [IO.File]::Exists($compiler)) { throw "Missing compiler '$compiler'." }
    $mesa = Join-Path $Checkout 'mesa-23.1.x'
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'retvrn99-gsw-winsys-shell-' + [Guid]::NewGuid().ToString('N')
    )
    [void][IO.Directory]::CreateDirectory($tempRoot)
    try {
        $arguments = @('-std=gnu99', '-m32') +
            @($profile.toolchains.mingw.cpu_flags) + @(
                '-D_WIN32_WINNT=0x0400', '-DWINVER=0x0400',
                '-D_WIN32_WINDOWS=0x0410', '-Wall', '-Wextra', '-Werror',
                '-fsyntax-only',
                '-I' + (Join-Path $ModuleRoot 'include'),
                '-I' + (Join-Path $mesa 'src\gallium\drivers\svga'),
                '-I' + (Join-Path $mesa 'src\gallium\drivers\svga\include'),
                '-I' + (Join-Path $mesa 'src\gallium\include'),
                '-I' + (Join-Path $mesa 'src'),
                '-I' + (Join-Path $mesa 'include'),
                (Join-Path $ModuleRoot 'src\gsw_svga_winsys.c'),
                (Join-Path $ModuleRoot 'probes\gsw_svga_winsys_contract_probe.c')
            )
        [void](Invoke-GswCompileProcess -FilePath $compiler -Arguments $arguments `
            -WorkingDirectory $tempRoot -ToolBin $toolBin -PrivateTemp $tempRoot `
            -TimeoutSeconds 10 -Name 'GSW winsys shell syntax proof')
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Invoke-GswWinsysShellVerification {
    param(
        [string]$ModuleRoot,
        [string]$Checkout,
        [string]$Toolchains,
        [string]$MetadataPath,
        [bool]$Compile
    )

    $checkoutState = Assert-GswMesaCleanCheckout $Checkout
    $metadataBytes = Read-GswWinsysFile $MetadataPath 131072
    $metadata = ConvertFrom-GswStrictJson `
        -Json (ConvertFrom-GswWinsysUtf8 $metadataBytes $MetadataPath) -Source $MetadataPath
    $schemaPath = Join-Path $ModuleRoot $metadata.schema_definition.relative_path
    $schemaBytes = Read-GswWinsysFile $schemaPath 65536
    if ((Get-GswWinsysSha256 $schemaBytes) -cne $metadata.schema_definition.sha256) {
        throw 'Winsys schema binding mismatch.'
    }
    if ($metadata.schema -ne 1 -or
        $metadata.status -cne 'capability-disabled-adapter-shell') {
        throw 'Winsys lock schema or status changed.'
    }
    if ([string]::Join('|', @($metadata.prohibited_implementation_prefixes)) -cne
        [string]::Join('|', $script:GswWinsysProhibitedPrefixes)) {
        throw 'Prohibited implementation boundary changed.'
    }
    if ($metadata.inputs.Count -ne $script:GswWinsysExpectedInputs.Count) {
        throw 'Winsys allowlist count changed.'
    }
    $inputTexts = @{}
    for ($index = 0; $index -lt $script:GswWinsysExpectedInputs.Count; $index++) {
        $input = $metadata.inputs[$index]
        $expectedPath = $script:GswWinsysExpectedInputs[$index]
        if ($input.source_relative_path -cne $expectedPath -or
            $input.license_expression -cne 'MIT') {
            throw "Unexpected winsys allowlist entry '$($input.source_relative_path)'."
        }
        foreach ($prefix in $script:GswWinsysProhibitedPrefixes) {
            if ($expectedPath.StartsWith($prefix, [StringComparison]::Ordinal)) {
                throw "Allowlist entry '$expectedPath' crosses a prohibited boundary."
            }
        }
        $treeBlob = (Invoke-GswMesaGitText $Checkout @(
            'rev-parse', ('HEAD:' + $expectedPath)
        )).Trim()
        if ($treeBlob -cne $input.git_blob) {
            throw "Pinned blob mismatch for '$expectedPath'."
        }
        $bytes = Read-GswMesaGitBlob $Checkout $treeBlob
        if ($bytes.Length -ne [int64]$input.bytes -or
            (Get-GswWinsysSha256 $bytes) -cne $input.sha256) {
            throw "Pinned byte binding mismatch for '$expectedPath'."
        }
        $inputTexts[$expectedPath] = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    if ($metadata.outputs.Count -ne 2) { throw 'Winsys output count changed.' }
    foreach ($output in $metadata.outputs) {
        $bytes = Read-GswWinsysFile (Join-Path $ModuleRoot $output.relative_path) 65536
        if ($bytes.Length -ne [int64]$output.bytes -or
            (Get-GswWinsysSha256 $bytes) -cne $output.sha256 -or
            $output.license_expression -cne 'GPL-3.0-only') {
            throw "Winsys output binding mismatch for '$($output.relative_path)'."
        }
    }
    $sourcePath = Join-Path $ModuleRoot 'src\gsw_svga_winsys.c'
    $sourceText = ConvertFrom-GswWinsysUtf8 `
        (Read-GswWinsysFile $sourcePath 65536) $sourcePath
    if (-not $sourceText.StartsWith(
            '/* SPDX-License-Identifier: GPL-3.0-only */' + "`n",
            [StringComparison]::Ordinal
        )) {
        throw 'GSW winsys source lacks the required SPDX header.'
    }
    $interfaceText = $inputTexts[$script:GswWinsysExpectedInputs[0]]
    Assert-GswWinsysCallbacks $interfaceText $sourceText `
        'svga_winsys_screen' 'gsw_init_screen' 'sws' $script:GswWinsysScreenCallbacks
    Assert-GswWinsysCallbacks $interfaceText $sourceText `
        'svga_winsys_context' 'gsw_init_context' 'swc' $script:GswWinsysContextCallbacks
    Assert-GswWinsysSemantics $sourceText $inputTexts[$script:GswWinsysExpectedInputs[1]]
    if ($metadata.contract.screen_callback_count -ne 32 -or
        $metadata.contract.context_callback_count -ne 17 -or
        $metadata.contract.get_fd -ne -1 -or
        $metadata.contract.capabilities -cne 'all-false' -or
        $metadata.contract.abi_submission_count -ne 0) {
        throw 'Winsys disabled contract metadata changed.'
    }
    foreach ($claim in $metadata.claims.PSObject.Properties) {
        if ($claim.Name -ceq 'adapter_shell_complete') {
            if ($claim.Value -isnot [bool] -or -not $claim.Value) {
                throw 'Adapter shell completeness claim is not true.'
            }
        }
        elseif ($claim.Value -isnot [bool] -or $claim.Value) {
            throw "Winsys claim '$($claim.Name)' is not false."
        }
    }
    if ($Compile) {
        Invoke-GswWinsysCompileCheck $ModuleRoot $Checkout $Toolchains
    }
    $finalCheckout = Assert-GswMesaCleanCheckout $Checkout
    if ($finalCheckout.Config.Length -ne $checkoutState.Config.Length -or
        $finalCheckout.Config.Sha256 -cne $checkoutState.Config.Sha256) {
        throw 'Mesa checkout configuration changed during winsys verification.'
    }
    Write-Output (
        'Verified capability-disabled GSW svga_winsys shell: 32 screen and ' +
        '17 context callbacks, deterministic pre-WS8 rejection, zero ' +
        'capabilities, zero ABI submission, and prohibited sources unopened.'
    )
}

if ($MyInvocation.InvocationName -cne '.') {
    if ([string]::IsNullOrWhiteSpace($LockFile)) {
        $LockFile = Join-Path $PSScriptRoot `
            '..\drivers\win98\mesa-gsw\winsys-interface-inputs.lock.json'
    }
    $moduleRoot = Split-Path -Parent ([IO.Path]::GetFullPath($LockFile))
    Invoke-GswWinsysShellVerification $moduleRoot $MesaCheckout $ToolchainRoot `
        ([IO.Path]::GetFullPath($LockFile)) (-not $SkipCompile)
}

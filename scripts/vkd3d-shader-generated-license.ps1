# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

function Get-Vkd3dShaderExpectedConfigBytes {
    $text = @'
#define PACKAGE_VERSION "2.0"
#define _GNU_SOURCE 1
#define HAVE__STRTOD_L 1
#define HAVE__STRTOF_L 1
#define HAVE_ATOMIC_EXCHANGE_N 1
#define HAVE_BUILTIN_ADD_OVERFLOW 1
#define HAVE_BUILTIN_CLZ 1
#define HAVE_BUILTIN_CTZ 1
#define HAVE_BUILTIN_POPCOUNT 1
#define HAVE_SYNC_ADD_AND_FETCH 1
#define HAVE_SYNC_BOOL_COMPARE_AND_SWAP 1
#define HAVE_SPIRV_UNIFIED1_SPIRV_H 1
#define HAVE_SPIRV_UNIFIED1_GLSL_STD_450_H 1
'@.Replace("`r`n", "`n") + "`n"
    return [Text.UTF8Encoding]::new($false).GetBytes($text)
}

function Get-Vkd3dShaderExpectedVersionBytes {
    return [Text.UTF8Encoding]::new($false).GetBytes(
        '#define VKD3D_VCS_ID " (git 1b0924d1)"' + "`n"
    )
}

function Assert-Vkd3dShaderGeneratedMarker {
    param([string]$Text, [string]$Marker, [string]$Path)

    if ($Text.IndexOf($Marker, [StringComparison]::Ordinal) -lt 0) {
        throw "Generated output '$Path' lacks required license provenance."
    }
}

function Test-Vkd3dShaderGeneratedStringArrayEqual {
    param([string[]]$Left, [string[]]$Right)

    if ($Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -cne $Right[$index]) { return $false }
    }
    return $true
}

function Assert-Vkd3dShaderGeneratedRelativePath {
    param([string]$Path, [string]$Label)

    $pathParts = $Path.Split('/')
    if ([string]::IsNullOrWhiteSpace($Path) -or
        [IO.Path]::IsPathRooted($Path) -or $Path.Contains('\') -or
        $Path.StartsWith('/') -or
        [Text.Encoding]::UTF8.GetByteCount($Path) -gt 1024 -or
        @($pathParts | Where-Object {
            [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..')
        }).Count -ne 0) {
        throw "$Label '$Path' is not a canonical repository-relative path."
    }
}

function Get-Vkd3dShaderGeneratedInputPaths {
    param([string]$RelativePath)

    $definitions = @(
        @('libs/vkd3d-shader/hlsl.yy.c', @('libs/vkd3d-shader/hlsl.l')),
        @('libs/vkd3d-shader/hlsl.tab.c', @('libs/vkd3d-shader/hlsl.y')),
        @('libs/vkd3d-shader/hlsl.tab.h', @('libs/vkd3d-shader/hlsl.y')),
        @('libs/vkd3d-shader/preproc.yy.c', @('libs/vkd3d-shader/preproc.l')),
        @('libs/vkd3d-shader/preproc.tab.c', @('libs/vkd3d-shader/preproc.y')),
        @('libs/vkd3d-shader/preproc.tab.h', @('libs/vkd3d-shader/preproc.y')),
        @('include/vkd3d_d3dcommon.h', @(
            'include/vkd3d_d3dcommon.idl',
            'include/vkd3d_unknown.idl'
        )),
        @('include/vkd3d_d3dx9shader.h', @(
            'include/vkd3d_d3dx9shader.idl',
            'include/vkd3d_d3d9types.h'
        )),
        @('include/private/spirv_grammar.h', @(
            'libs/vkd3d-shader/make_spirv',
            'include/private/spirv.core.grammar.json'
        )),
        @('include/config.h', @('configure.ac')),
        @('include/private/vkd3d_version.h', @('Makefile.am'))
    )
    $matches = @($definitions | Where-Object {
        [string]$_[0] -ceq $RelativePath
    })
    if ($matches.Count -ne 1) {
        throw "Generated output '$RelativePath' has no reviewed input mapping."
    }
    return [string[]]@($matches[0][1])
}

function Get-Vkd3dShaderGeneratedLicense {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string[]]$InputRelativePaths
    )

    Assert-Vkd3dShaderGeneratedRelativePath $RelativePath 'Generated output'
    if ($Bytes.Length -eq 0 -or
        $Bytes -contains [byte]0 -or $Bytes -contains [byte]13 -or
        ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and
            $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf)) {
        throw "Generated output '$RelativePath' is not canonical LF text."
    }
    foreach ($inputPath in @($InputRelativePaths)) {
        Assert-Vkd3dShaderGeneratedRelativePath $inputPath 'Generated input'
    }
    $expectedInputPaths = @(Get-Vkd3dShaderGeneratedInputPaths $RelativePath)
    if (-not (Test-Vkd3dShaderGeneratedStringArrayEqual `
            @($InputRelativePaths) $expectedInputPaths)) {
        throw "Generated output '$RelativePath' has different input provenance."
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)

    if (@(
        'libs/vkd3d-shader/hlsl.tab.c',
        'libs/vkd3d-shader/hlsl.tab.h',
        'libs/vkd3d-shader/preproc.tab.c',
        'libs/vkd3d-shader/preproc.tab.h'
    ) -ccontains $RelativePath) {
        Assert-Vkd3dShaderGeneratedMarker $text `
            'GNU General Public License as published by' $RelativePath
        Assert-Vkd3dShaderGeneratedMarker $text `
            'either version 3 of the License, or' $RelativePath
        Assert-Vkd3dShaderGeneratedMarker $text `
            'As a special exception, you may create a larger work' $RelativePath
        return [pscustomobject][ordered]@{
            license_expression = 'LGPL-2.1-or-later AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
            provenance = 'bison-3.8.2-skeleton-exception-and-exact-lgpl-grammar-input'
        }
    }

    if (@(
        'libs/vkd3d-shader/hlsl.yy.c',
        'libs/vkd3d-shader/preproc.yy.c'
    ) -ccontains $RelativePath) {
        Assert-Vkd3dShaderGeneratedMarker $text `
            'A lexical scanner generated by flex' $RelativePath
        Assert-Vkd3dShaderGeneratedMarker $text `
            'terms of the GNU Lesser General Public' $RelativePath
        return [pscustomobject][ordered]@{
            license_expression = 'LGPL-2.1-or-later'
            provenance = 'flex-2.6.4-output-exception-and-lgpl-lexer'
        }
    }

    if (@(
        'include/vkd3d_d3dcommon.h',
        'include/vkd3d_d3dx9shader.h'
    ) -ccontains $RelativePath) {
        Assert-Vkd3dShaderGeneratedMarker $text `
            "Autogenerated by WIDL 11.0-rc1 from $($expectedInputPaths[0])" `
            $RelativePath
        return [pscustomobject][ordered]@{
            license_expression = 'LGPL-2.1-or-later'
            provenance = 'widl-11.0-rc1-from-exact-lgpl-idl'
        }
    }

    if ($RelativePath -ceq 'include/private/spirv_grammar.h') {
        Assert-Vkd3dShaderGeneratedMarker $text `
            'The original source is covered by the following license:' `
            $RelativePath
        Assert-Vkd3dShaderGeneratedMarker $text `
            'Permission is hereby granted, free of charge' $RelativePath
        return [pscustomobject][ordered]@{
            license_expression = 'MIT'
            provenance = 'unchanged-make-spirv-from-exact-mit-grammar'
        }
    }

    if ($RelativePath -ceq 'include/config.h') {
        if (-not (Test-Vkd3dShaderBytesEqual $Bytes `
            (Get-Vkd3dShaderExpectedConfigBytes))) {
            throw 'Generated config.h differs from the exact reviewed recipe.'
        }
        return [pscustomobject][ordered]@{
            license_expression = 'GPL-3.0-only'
            provenance = 'retvrn99-exact-configuration-recipe'
        }
    }

    if ($RelativePath -ceq 'include/private/vkd3d_version.h') {
        if (-not (Test-Vkd3dShaderBytesEqual $Bytes `
            (Get-Vkd3dShaderExpectedVersionBytes))) {
            throw 'Generated version header differs from the pinned commit recipe.'
        }
        return [pscustomobject][ordered]@{
            license_expression = 'GPL-3.0-only'
            provenance = 'retvrn99-exact-version-recipe'
        }
    }

    throw "Generated output '$RelativePath' has no reviewed license disposition."
}

# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

$script:MesaShadowedCompilerDependency =
    'mesa-23.1.x/src/compiler/nir_builder_opcodes.h'
$script:MesaGeneratedCompilerReplacement =
    'mesa-23.1.x/src/compiler/nir/nir_builder_opcodes.h'
$script:MesaCompilerDependencyPathSetSha256 =
    '00ac4082aab6cdca6d81b1293948ee7774da08101d708628fb1d045b5717d05e'
$script:MesaCanonicalLfDependencyOverrides =
    [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
foreach ($entry in @(
    @('mesa9x.h', '37212c196ffaefedba456bca5b0f3281c20f2c6f', 1056,
        'b93c0065efb500c3492837c2e76337618ab9f2031c99d5e02fa3f6515dc1868b',
        1012, '6bac1adec2d59ecf3477d0465941bf6e98d18151ff03b2df9e161badc1d06f0e'),
    @('win9x/nine/mesa99.h', '7d7438db3c5d7b3967f913a04b34c2bfcd4a8d47',
        1205, 'a5944659312be9cfa4d71596ba0bdd885516f8e92f7c5049fee6d9d357111f5f',
        1160, 'a8217bcb1c8ceae76250e09787f97f44aa628c15d1eb4ec537d5745ca1ed19b3'),
    @('win9x/nine/nine_present.h',
        '09d5e34ac20382da22f9ae4e6669efd9c72e102b', 1657,
        'ddb2ca07304415a88e7f749b528e180f87e00cdf9c8569a4877597aeb091be30',
        1588, '657244f52af3b3f8f89a670202f035d0cf3934d6b82a3783e25dce7f50dbc7a0'),
    @('win9x/vmsetup.h', '6359e64e34b180aa4e2f852300f655960d2f93bd',
        3346, '9b8812f11d166b36349f73ef77243fbf6071a5480ff1647483571631c9e25fdb',
        3265, '111359d1457d986b1397b1a5dea94f1214201564d29f6b1c38996d51484b7937'),
    @('win9x/wgl/pipe_access.h',
        'c52c863bac533a75234aa74c827e1f82f895c201', 1013,
        '749991efb542331963fdf3e2d5ae43ab4a120a1ac9b2269b47219a9adc2ba2a4',
        991, '76a4f09664d48e2dc1287e15d3b23e7c950e995b6d528d618b01b312aa7f555a')
)) {
    $script:MesaCanonicalLfDependencyOverrides.Add(
        [string]$entry[0],
        [pscustomobject]@{
            GitBlob = [string]$entry[1]
            RawBytes = [int64]$entry[2]
            RawSha256 = [string]$entry[3]
            Bytes = [int64]$entry[4]
            Sha256 = [string]$entry[5]
        }
    )
}

function Get-MesaCompilerDependencyPathSetSha256 {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $bytes = [Text.Encoding]::UTF8.GetBytes(($Paths -join "`n") + "`n")
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return (([BitConverter]::ToString($sha256.ComputeHash($bytes))) `
            -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-MesaShadowedCompilerDependencyRole {
    param([Parameter(Mandatory = $true)][object]$File)

    if ([string]$File.relative_path -cne
            $script:MesaShadowedCompilerDependency -or
        [int64]$File.bytes -ne 0 -or
        [string]$File.sha256 -cne
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' -or
        @($File.roles) -cnotcontains 'compiler-dependency') {
        throw 'The generated-shadowed compiler dependency role changed.'
    }
}

function Get-MesaCanonicalCompilerDependencyDescriptor {
    param([Parameter(Mandatory = $true)][object]$File)

    $path = [string]$File.relative_path
    if (@($File.roles) -cnotcontains 'compiler-dependency') {
        throw "Mesa file '$path' lacks the compiler-dependency role."
    }
    if (-not $script:MesaCanonicalLfDependencyOverrides.ContainsKey($path)) {
        return [pscustomobject]@{
            Bytes = [int64]$File.bytes
            Sha256 = [string]$File.sha256
            Mode = 'raw-git-bytes-already-canonical-lf'
        }
    }

    $expected = $script:MesaCanonicalLfDependencyOverrides[$path]
    if ([string]$File.git_blob -cne $expected.GitBlob -or
        [int64]$File.bytes -ne $expected.RawBytes -or
        [string]$File.sha256 -cne $expected.RawSha256) {
        throw "Raw CRLF dependency descriptor '$path' changed."
    }
    return [pscustomobject]@{
        Bytes = $expected.Bytes
        Sha256 = $expected.Sha256
        Mode = 'raw-crlf-git-bytes-canonicalized-to-lf'
    }
}

function Assert-MesaCanonicalCompilerDependencyEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Header,
        [Parameter(Mandatory = $true)][object]$File
    )

    $path = [string]$Header.relative_path
    if ($path -cne [string]$File.relative_path -or
        [string]$Header.license_scope -cne 'reviewed-component-closure') {
        throw "Compiler source dependency '$path' lacks ready closure."
    }
    $expected = Get-MesaCanonicalCompilerDependencyDescriptor $File
    if ([int64]$Header.bytes -ne $expected.Bytes -or
        [string]$Header.sha256 -cne $expected.Sha256) {
        throw "Compiler source dependency '$path' changed from canonical closure."
    }
}

function Resolve-MesaCompilerDependencyRoles {
    param([Parameter(Mandatory = $true)][object[]]$Headers)

    $sourceHeaders = [Collections.Generic.SortedDictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $generatedReplacementCount = 0
    foreach ($header in $Headers) {
        $root = [string]$header.root
        $path = [string]$header.relative_path
        if ($root -ceq 'generated' -and
            $path -ceq $script:MesaGeneratedCompilerReplacement) {
            $generatedReplacementCount++
        }
        if ($root -cne 'source') {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($path) -or
            $sourceHeaders.ContainsKey($path)) {
            throw "Compiler source dependency '$path' is empty or duplicated."
        }
        $sourceHeaders.Add($path, $header)
    }

    $mode = ''
    if ($sourceHeaders.Count -eq 652 -and
        $sourceHeaders.ContainsKey($script:MesaShadowedCompilerDependency)) {
        $mode = 'source-placeholder-observed'
    }
    elseif ($sourceHeaders.Count -eq 651 -and
        -not $sourceHeaders.ContainsKey($script:MesaShadowedCompilerDependency) -and
        $generatedReplacementCount -eq 1) {
        $mode = 'generated-replacement-observed'
    }
    else {
        throw (
            'Compiler dependency evidence must contain either all 652 source ' +
            'roles or 651 source roles plus the exact generated NIR replacement.'
        )
    }

    $rolePaths = [Collections.Generic.SortedSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($path in $sourceHeaders.Keys) {
        [void]$rolePaths.Add($path)
    }
    [void]$rolePaths.Add($script:MesaShadowedCompilerDependency)
    $orderedRolePaths = [string[]]@($rolePaths)
    if ($orderedRolePaths.Count -ne 652 -or
        (Get-MesaCompilerDependencyPathSetSha256 $orderedRolePaths) -cne
            $script:MesaCompilerDependencyPathSetSha256) {
        throw 'Compiler dependency role path set changed.'
    }

    return [pscustomobject]@{
        Mode = $mode
        ObservedSourceHeaders = [object[]]@($sourceHeaders.Values)
        ObservedSourcePaths = [string[]]@($sourceHeaders.Keys)
        RolePaths = $orderedRolePaths
        ShadowedPath = $script:MesaShadowedCompilerDependency
        GeneratedReplacementPath = $script:MesaGeneratedCompilerReplacement
    }
}

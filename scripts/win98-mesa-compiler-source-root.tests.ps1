# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'mesa-compiler-source-root.ps1')
. (Join-Path $PSScriptRoot 'mesa-compiler-dependency-roles.ps1')

$script:Tests = 0
$script:Failures = 0
$script:Root = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-source-root-test-' + [Guid]::NewGuid().ToString('N')
)

function Invoke-SourceRootTest {
    param([string]$Name, [scriptblock]$Body)
    $script:Tests++
    try { & $Body; Write-Output "PASS: $Name" }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Assert-SourceRootThrows {
    param([scriptblock]$Body, [string]$Expected)
    try { & $Body }
    catch {
        if ($_.Exception.Message.IndexOf(
                $Expected, [StringComparison]::OrdinalIgnoreCase
            ) -lt 0) {
            throw "Expected '$Expected', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected failure containing '$Expected'."
}

try {
    [void][IO.Directory]::CreateDirectory($script:Root)
    $utf8 = [Text.UTF8Encoding]::new($false)
    [byte[]]$canonical = $utf8.GetBytes("one`ntwo`n")
    $hash = Get-MesaCanonicalSourceSha256 $canonical
    $lf = Join-Path $script:Root 'lf.c'
    $crlf = Join-Path $script:Root 'crlf.c'
    [IO.File]::WriteAllBytes($lf, $canonical)
    [IO.File]::WriteAllBytes($crlf, $utf8.GetBytes("one`r`ntwo`r`n"))

    Invoke-SourceRootTest 'LF checkout bytes remain canonical' {
        $result = ConvertTo-MesaCanonicalSourceObservation $lf `
            $canonical.Length $hash $true 'LF fixture'
        if ($result.SawCrlf -or -not $result.RawMatchesGitBlob -or
            (Get-MesaCanonicalSourceSha256 $result.Bytes) -cne $hash) {
            throw 'LF observation changed.'
        }
    }
    Invoke-SourceRootTest 'CRLF checkout normalizes to canonical bytes' {
        $result = ConvertTo-MesaCanonicalSourceObservation $crlf `
            $canonical.Length $hash $false 'CRLF fixture'
        if (-not $result.SawCrlf -or $result.RawMatchesGitBlob -or
            (Get-MesaCanonicalSourceSha256 $result.Bytes) -cne $hash) {
            throw 'CRLF observation did not normalize.'
        }
    }
    Invoke-SourceRootTest 'Raw CRLF Git blobs produce canonical LF pairs' {
        $rawCrlf = $utf8.GetBytes("one`r`ntwo`r`n")
        $rawHash = Get-MesaCanonicalSourceSha256 $rawCrlf
        $lfResult = ConvertTo-MesaCanonicalSourceObservation $lf `
            $rawCrlf.Length $rawHash $true 'LF raw-CRLF fixture'
        $crlfResult = ConvertTo-MesaCanonicalSourceObservation $crlf `
            $rawCrlf.Length $rawHash $false 'CRLF raw-CRLF fixture'
        $resolved = Resolve-MesaCanonicalSourcePair $lfResult $crlfResult `
            'raw-CRLF fixture'
        if ($lfResult.RawMatchesGitBlob -or
            -not $crlfResult.RawMatchesGitBlob -or
            (Get-MesaCanonicalSourceSha256 $resolved.Bytes) -cne $hash) {
            throw 'Raw CRLF Git blob was not anchored and normalized.'
        }
    }
    Invoke-SourceRootTest 'CRLF content drift with no raw anchor is rejected' {
        $drift = Join-Path $script:Root 'drift.c'
        [IO.File]::WriteAllBytes($drift, $utf8.GetBytes("one`r`nchanged`r`n"))
        $first = ConvertTo-MesaCanonicalSourceObservation $drift `
            $canonical.Length $hash $false 'first drift fixture'
        $second = ConvertTo-MesaCanonicalSourceObservation $drift `
            $canonical.Length $hash $false 'second drift fixture'
        Assert-SourceRootThrows {
            Resolve-MesaCanonicalSourcePair $first $second 'drift fixture'
        } 'exact Git blob'
    }
    Invoke-SourceRootTest 'Canonical twin drift is rejected' {
        $changed = Join-Path $script:Root 'changed.c'
        [IO.File]::WriteAllBytes($changed, $utf8.GetBytes("one`nchanged`n"))
        $first = ConvertTo-MesaCanonicalSourceObservation $lf `
            $canonical.Length $hash $true 'anchored fixture'
        $second = ConvertTo-MesaCanonicalSourceObservation $changed `
            $canonical.Length $hash $true 'changed fixture'
        Assert-SourceRootThrows {
            Resolve-MesaCanonicalSourcePair $first $second 'twin drift fixture'
        } 'canonical checkout bytes differ'
    }
    Invoke-SourceRootTest 'Isolated carriage returns are rejected' {
        $isolated = Join-Path $script:Root 'isolated.c'
        [IO.File]::WriteAllBytes($isolated, $utf8.GetBytes("one`rtwo`n"))
        Assert-SourceRootThrows {
            ConvertTo-MesaCanonicalSourceObservation $isolated `
                $canonical.Length $hash $false 'isolated fixture'
        } 'isolated carriage return'
    }

    $driversRoot = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\drivers\win98')
    )
    $component = Get-Content -Raw -LiteralPath (Join-Path $driversRoot `
        'component-closures\mesa9x-23.1.x.json') | ConvertFrom-Json
    $rolePaths = [string[]]@($component.files | Where-Object {
        @($_.roles) -ccontains 'compiler-dependency'
    } | Select-Object -ExpandProperty relative_path | Sort-Object -CaseSensitive)
    $legacyHeaders = [object[]]@($rolePaths | ForEach-Object {
        [pscustomobject]@{ root = 'source'; relative_path = [string]$_ }
    })
    $v3Headers = [object[]]@($legacyHeaders | Where-Object {
        $_.relative_path -cne $script:MesaShadowedCompilerDependency
    }) + @([pscustomobject]@{
        root = 'generated'
        relative_path = $script:MesaGeneratedCompilerReplacement
    })

    Invoke-SourceRootTest 'Legacy source headers retain all dependency roles' {
        $result = Resolve-MesaCompilerDependencyRoles $legacyHeaders
        if ($result.Mode -cne 'source-placeholder-observed' -or
            $result.ObservedSourcePaths.Count -ne 652 -or
            $result.RolePaths.Count -ne 652) {
            throw 'Legacy dependency roles changed.'
        }
    }
    Invoke-SourceRootTest 'Generated replacement restores the shadowed role' {
        $result = Resolve-MesaCompilerDependencyRoles $v3Headers
        if ($result.Mode -cne 'generated-replacement-observed' -or
            $result.ObservedSourcePaths.Count -ne 651 -or
            $result.RolePaths.Count -ne 652 -or
            $result.RolePaths -cnotcontains
                $script:MesaShadowedCompilerDependency) {
            throw 'Generated-shadow dependency roles changed.'
        }
    }
    Invoke-SourceRootTest 'Missing generated replacement is rejected' {
        Assert-SourceRootThrows {
            Resolve-MesaCompilerDependencyRoles @($v3Headers | Where-Object {
                $_.root -cne 'generated'
            })
        } 'exact generated NIR replacement'
    }
    Invoke-SourceRootTest 'Duplicate source dependency is rejected' {
        Assert-SourceRootThrows {
            Resolve-MesaCompilerDependencyRoles `
                ([object[]]@($v3Headers) + @($v3Headers[0]))
        } 'empty or duplicated'
    }
    Invoke-SourceRootTest 'Substituted dependency role is rejected' {
        $changed = [object[]]@($v3Headers | ForEach-Object {
            if ($_.root -ceq 'source' -and
                $_.relative_path -ceq $rolePaths[0]) {
                [pscustomobject]@{
                    root = 'source'
                    relative_path = 'mesa-23.1.x/src/compiler/changed-role.h'
                }
            }
            else {
                $_
            }
        })
        Assert-SourceRootThrows {
            Resolve-MesaCompilerDependencyRoles $changed
        } 'role path set changed'
    }
    Invoke-SourceRootTest 'Nonzero shadowed dependency role is rejected' {
        $shadowed = @($component.files | Where-Object {
            $_.relative_path -ceq $script:MesaShadowedCompilerDependency
        })[0].PSObject.Copy()
        $shadowed.bytes = 1
        Assert-SourceRootThrows {
            Assert-MesaShadowedCompilerDependencyRole $shadowed
        } 'generated-shadowed compiler dependency role changed'
    }
    Invoke-SourceRootTest 'Raw CRLF dependencies bind canonical LF descriptors' {
        $file = @($component.files | Where-Object {
            $_.relative_path -ceq 'mesa9x.h'
        })[0]
        $descriptor = Get-MesaCanonicalCompilerDependencyDescriptor $file
        if ($descriptor.Mode -cne 'raw-crlf-git-bytes-canonicalized-to-lf' -or
            $descriptor.Bytes -ne 1012 -or
            $descriptor.Sha256 -cne
                '6bac1adec2d59ecf3477d0465941bf6e98d18151ff03b2df9e161badc1d06f0e') {
            throw 'Canonical CRLF dependency descriptor changed.'
        }
    }
    Invoke-SourceRootTest 'Raw CRLF dependency drift is rejected' {
        $file = @($component.files | Where-Object {
            $_.relative_path -ceq 'mesa9x.h'
        })[0].PSObject.Copy()
        $file.sha256 = '0' * 64
        Assert-SourceRootThrows {
            Get-MesaCanonicalCompilerDependencyDescriptor $file
        } 'Raw CRLF dependency descriptor'
    }
}
finally {
    if ([IO.Directory]::Exists($script:Root)) {
        [IO.Directory]::Delete($script:Root, $true)
    }
}
if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Tests) source-root tests failed."
}
Write-Output "All $($script:Tests) source-root tests passed."

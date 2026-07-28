# SPDX-License-Identifier: GPL-3.0-only

# Re-pins the four hash locks a Windows 98 driver or guest-tool source change
# invalidates, in the one order that works: every overlay tree in the derived
# source plan, then that plan's own recipe output trees, then the plan digest the
# build plan carries, then the built binary digests. Doing it by hand is about
# fifteen edits per change and each wrong one looks like a build failure.
#
# Editing is scalar-by-scalar inside the located JSON span rather than a
# reserialization, because these plans are hand-formatted: build-plan.json puts
# several compiler arguments on a line and derived-source-plan.json puts a whole
# patch record on one, and ConvertTo-Json would rewrite both files entirely.
#
# Nothing here weakens a lock. It writes the digests the existing describe and
# build paths report, and the build is what confirms them: the loop only stops
# when a full build verifies every output against the plan it just wrote.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,

    [Parameter(Mandatory = $true)][string]$ToolchainRoot,

    [Parameter(Mandatory = $true)][string]$OutputRoot,

    [string]$DerivedSourcePlan,

    [string]$BuildPlan,

    [string]$RecipeRoot,

    [string]$LockFile,

    # Optional staging manifest carrying a second copy of the built digests, as
    # the graphics probe's does. Rows are matched by file name.
    [string]$StageManifest,

    [int]$MaximumRounds = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DerivedSourcePlan)) {
    $DerivedSourcePlan = Join-Path $PSScriptRoot '..\drivers\win98\derived-source-plan.json'
}
if ([string]::IsNullOrWhiteSpace($BuildPlan)) {
    $BuildPlan = Join-Path $PSScriptRoot '..\drivers\win98\build-plan.json'
}
if ([string]::IsNullOrWhiteSpace($RecipeRoot)) {
    $RecipeRoot = Join-Path $PSScriptRoot '..\drivers\win98'
}
if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot '..\drivers\win98\upstream.lock.tsv'
}
if ($MaximumRounds -lt 1 -or $MaximumRounds -gt 32) {
    throw 'MaximumRounds must be between 1 and 32.'
}

$script:PrepareScript = Join-Path $PSScriptRoot 'prepare-win98-derived-sources.ps1'
$script:BuildScript = Join-Path $PSScriptRoot 'build-win98-driver-sources.ps1'
$script:TreeFields = @(
    'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
    'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
)

function Get-RepinFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

function Read-RepinText {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path)
}

# Writes back with the LF endings and single trailing newline these plans use.
function Write-RepinText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $normalized = ($Text -replace "`r`n", "`n").TrimEnd("`n") + "`n"
    [IO.File]::WriteAllText($Path, $normalized, (New-Object Text.UTF8Encoding $false))
}

# Index of the matching close for the bracket at $Open, skipping string bodies so
# a brace inside a path or a reason cannot end the span early.
function Get-RepinSpanEnd {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Open
    )
    $opening = $Text[$Open]
    $closing = if ($opening -ceq '{') { '}' } elseif ($opening -ceq '[') { ']' } else {
        throw "Not a bracket at offset ${Open}: '$opening'"
    }
    $depth = 0
    $index = $Open
    $inString = $false
    while ($index -lt $Text.Length) {
        $character = $Text[$index]
        if ($inString) {
            if ($character -ceq '\') { $index += 2; continue }
            if ($character -ceq '"') { $inString = $false }
        }
        elseif ($character -ceq '"') { $inString = $true }
        elseif ($character -ceq $opening) { $depth++ }
        elseif ($character -ceq $closing) {
            $depth--
            if ($depth -eq 0) { return $index }
        }
        $index++
    }
    throw "Unbalanced '$opening' from offset $Open."
}

# Offset of the value that follows "<Name>": inside [$Start,$End).
function Get-RepinMemberValueOffset {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End,
        [switch]$Optional
    )
    $needle = '"' + $Name + '"'
    $found = $Text.IndexOf($needle, $Start, $End - $Start, [StringComparison]::Ordinal)
    if ($found -lt 0) {
        if ($Optional) { return -1 }
        throw "Member '$Name' not found in the located span."
    }
    $index = $found + $needle.Length
    while ($index -lt $End -and ($Text[$index] -ceq ' ' -or $Text[$index] -ceq ':' -or
        $Text[$index] -ceq "`n" -or $Text[$index] -ceq "`r" -or $Text[$index] -ceq "`t")) {
        $index++
    }
    return $index
}

# Element spans of the array member "<Name>" inside [$Start,$End).
function Get-RepinArrayElementSpans {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End
    )
    $arrayStart = Get-RepinMemberValueOffset -Text $Text -Name $Name -Start $Start -End $End
    if ($Text[$arrayStart] -cne '[') { throw "Member '$Name' is not an array." }
    $arrayEnd = Get-RepinSpanEnd -Text $Text -Open $arrayStart
    $spans = @()
    $index = $arrayStart + 1
    while ($index -lt $arrayEnd) {
        if ($Text[$index] -ceq '{') {
            $elementEnd = Get-RepinSpanEnd -Text $Text -Open $index
            $spans += , @($index, $elementEnd)
            $index = $elementEnd + 1
            continue
        }
        $index++
    }
    return , $spans
}

function Get-RepinStringMember {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End
    )
    $offset = Get-RepinMemberValueOffset -Text $Text -Name $Name -Start $Start -End $End
    if ($Text[$offset] -cne '"') { throw "Member '$Name' is not a string." }
    $close = $Text.IndexOf('"', $offset + 1)
    return $Text.Substring($offset + 1, $close - $offset - 1)
}

# Replaces one scalar in place and returns the text plus how far the span moved.
function Set-RepinScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End,
        [Parameter(Mandatory = $true)][string]$Literal
    )
    $offset = Get-RepinMemberValueOffset -Text $Text -Name $Name -Start $Start -End $End
    $stop = $offset
    if ($Text[$offset] -ceq '"') {
        $stop = $Text.IndexOf('"', $offset + 1) + 1
    }
    else {
        while ($stop -lt $End -and $Text[$stop] -cnotin @(',', '}', ']', "`n", "`r", ' ')) { $stop++ }
    }
    $current = $Text.Substring($offset, $stop - $offset)
    if ($current -ceq $Literal) { return [PSCustomObject]@{ Text = $Text; Delta = 0; Changed = $false } }
    return [PSCustomObject]@{
        Text = $Text.Substring(0, $offset) + $Literal + $Text.Substring($stop)
        Delta = $Literal.Length - $current.Length
        Changed = $true
    }
}

function Set-RepinTreeDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End,
        [Parameter(Mandatory = $true)][object]$Descriptor
    )
    $changed = $false
    $spanEnd = $End
    foreach ($field in $script:TreeFields) {
        $value = $Descriptor.$field
        $literal = if ($value -is [string]) { '"' + $value + '"' } else { [string]$value }
        $result = Set-RepinScalar -Text $Text -Name $field -Start $Start -End $spanEnd -Literal $literal
        $Text = $result.Text
        $spanEnd += $result.Delta
        if ($result.Changed) { $changed = $true }
    }
    return [PSCustomObject]@{ Text = $Text; Changed = $changed }
}

# Rewrites the sha256 and bytes columns of a staging manifest from what the build
# plan now pins, matching rows by file name. Everything else is left alone.
function Update-RepinStageManifest {
    param(
        [Parameter(Mandatory = $true)][string]$BuildPlanPath,
        [AllowEmptyString()][AllowNull()][string]$ManifestPath
    )
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { return }
    $resolved = Get-RepinFullPath $ManifestPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Stage manifest not found: $resolved"
    }
    $pinned = @{}
    foreach ($step in @(($BuildPlanPath | ForEach-Object { Read-RepinText $_ } | ConvertFrom-Json).steps)) {
        foreach ($output in @($step.outputs)) {
            $pinned[(Split-Path -Leaf $output.relative_path)] = $output
        }
    }
    $lines = (Read-RepinText $resolved) -replace "`r`n", "`n" -split "`n"
    $changed = $false
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Length -eq 0) { continue }
        $fields = $lines[$index].Split([char]"`t")
        if ($fields.Count -ne 4 -or -not $pinned.ContainsKey($fields[1])) { continue }
        $output = $pinned[$fields[1]]
        $replacement = $fields[0] + "`t" + $fields[1] + "`t" + $output.sha256 + "`t" + $output.bytes
        if ($replacement -cne $lines[$index]) { $lines[$index] = $replacement; $changed = $true }
    }
    if (-not $changed) { Write-Output '  stage manifest already current'; return }
    Write-RepinText -Path $resolved -Text ($lines -join "`n")
    Write-Output "  stage manifest -> $resolved"
}

$sourceRootPath = Get-RepinFullPath $SourceRoot
$toolchainRootPath = Get-RepinFullPath $ToolchainRoot
$outputRootPath = Get-RepinFullPath $OutputRoot
$planPath = Get-RepinFullPath $DerivedSourcePlan
$buildPlanPath = Get-RepinFullPath $BuildPlan
$recipeRootPath = Get-RepinFullPath $RecipeRoot
$lockPath = Get-RepinFullPath $LockFile
foreach ($required in @($planPath, $buildPlanPath, $lockPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required plan or lock not found: $required"
    }
}

# 1. Every overlay tree, from the tree that is actually on disk.
$planText = Read-RepinText $planPath
$planRootEnd = $planText.Length - 1
$recipeSpans = Get-RepinArrayElementSpans -Text $planText -Name 'recipes' -Start 0 -End $planRootEnd
$recipeNames = @()
foreach ($recipeSpan in $recipeSpans) {
    $recipeNames += Get-RepinStringMember -Text $planText -Name 'name' `
        -Start $recipeSpan[0] -End $recipeSpan[1]
}
Write-Output "Re-pinning $($recipeNames.Count) recipe(s): $($recipeNames -join ', ')"

$overlayChanges = 0
foreach ($recipeName in $recipeNames) {
    # Re-locate every round: an earlier edit shifts every later offset.
    $planText = Read-RepinText $planPath
    $spans = Get-RepinArrayElementSpans -Text $planText -Name 'recipes' -Start 0 -End ($planText.Length - 1)
    $recipeSpan = $null
    foreach ($span in $spans) {
        if ((Get-RepinStringMember -Text $planText -Name 'name' -Start $span[0] -End $span[1]) -ceq $recipeName) {
            $recipeSpan = $span
            break
        }
    }
    if ($null -eq $recipeSpan) { throw "Recipe '$recipeName' disappeared from the plan." }
    $overlaySpans = Get-RepinArrayElementSpans -Text $planText -Name 'overlays' `
        -Start $recipeSpan[0] -End $recipeSpan[1]
    $overlayIndex = 0
    foreach ($overlaySpan in $overlaySpans) {
        # One overlay per pass, rereading the file, so offsets stay honest.
        $planText = Read-RepinText $planPath
        $spans = Get-RepinArrayElementSpans -Text $planText -Name 'recipes' -Start 0 -End ($planText.Length - 1)
        foreach ($span in $spans) {
            if ((Get-RepinStringMember -Text $planText -Name 'name' -Start $span[0] -End $span[1]) -ceq $recipeName) {
                $recipeSpan = $span
                break
            }
        }
        $currentOverlays = Get-RepinArrayElementSpans -Text $planText -Name 'overlays' `
            -Start $recipeSpan[0] -End $recipeSpan[1]
        $current = $currentOverlays[$overlayIndex]
        $relativePath = Get-RepinStringMember -Text $planText -Name 'relative_path' `
            -Start $current[0] -End $current[1]
        $overlayPath = Join-Path $recipeRootPath $relativePath
        if (-not (Test-Path -LiteralPath $overlayPath -PathType Container)) {
            throw "Overlay tree not found: $overlayPath"
        }
        $descriptor = & $script:PrepareScript -DescribeTree $overlayPath | ConvertFrom-Json
        $treeStart = Get-RepinMemberValueOffset -Text $planText -Name 'tree' `
            -Start $current[0] -End $current[1]
        $treeEnd = Get-RepinSpanEnd -Text $planText -Open $treeStart
        $applied = Set-RepinTreeDescriptor -Text $planText -Start $treeStart -End $treeEnd -Descriptor $descriptor
        if ($applied.Changed) {
            Write-RepinText -Path $planPath -Text $applied.Text
            $overlayChanges++
            Write-Output "  overlay $recipeName/$relativePath -> $($descriptor.sha256)"
        }
        $overlayIndex++
    }
}
if ($overlayChanges -eq 0) { Write-Output '  overlay trees already current' }

# 2. Each recipe's output tree, described from a draft copy with no output_tree.
$outputTreeChanges = 0
foreach ($recipeName in $recipeNames) {
    $planText = Read-RepinText $planPath
    $draft = $planText | ConvertFrom-Json
    $draft.status = 'draft'
    $draft.reason = 'repin-win98-derived-plan describe pass'
    foreach ($recipe in @($draft.recipes)) {
        $recipe.PSObject.Properties.Remove('output_tree')
    }
    $draftPath = Join-Path ([IO.Path]::GetTempPath()) (
        'retvrn99-repin-draft-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($draftPath, ($draft | ConvertTo-Json -Depth 40),
            (New-Object Text.UTF8Encoding $false))
        $described = & $script:PrepareScript -SourceRoot $sourceRootPath `
            -RecipePlan $draftPath -RecipeRoot $recipeRootPath -LockFile $lockPath `
            -DescribeRecipe $recipeName | ConvertFrom-Json
    }
    finally {
        if (Test-Path -LiteralPath $draftPath -PathType Leaf) {
            Remove-Item -LiteralPath $draftPath -Force
        }
    }
    $spans = Get-RepinArrayElementSpans -Text $planText -Name 'recipes' -Start 0 -End ($planText.Length - 1)
    $recipeSpan = $null
    foreach ($span in $spans) {
        if ((Get-RepinStringMember -Text $planText -Name 'name' -Start $span[0] -End $span[1]) -ceq $recipeName) {
            $recipeSpan = $span
            break
        }
    }
    $treeStart = Get-RepinMemberValueOffset -Text $planText -Name 'output_tree' `
        -Start $recipeSpan[0] -End $recipeSpan[1]
    $treeEnd = Get-RepinSpanEnd -Text $planText -Open $treeStart
    $applied = Set-RepinTreeDescriptor -Text $planText -Start $treeStart -End $treeEnd `
        -Descriptor $described.output_tree
    if ($applied.Changed) {
        Write-RepinText -Path $planPath -Text $applied.Text
        $outputTreeChanges++
        Write-Output "  output tree $recipeName -> $($described.output_tree.sha256)"
    }
}
if ($outputTreeChanges -eq 0) { Write-Output '  recipe output trees already current' }

# 3. The build plan's copies of its own input digests: the derived-source plan it
#    consumes and the upstream checkout lock it verifies against.
foreach ($reference in @(
    @{ Member = 'derived_source_plan'; Path = $planPath },
    @{ Member = 'upstream_lock'; Path = $lockPath }
)) {
    $digest = (Get-FileHash -LiteralPath $reference.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $buildText = Read-RepinText $buildPlanPath
    $referenceStart = Get-RepinMemberValueOffset -Text $buildText -Name $reference.Member `
        -Start 0 -End ($buildText.Length - 1) -Optional
    if ($referenceStart -lt 0) { continue }
    $referenceEnd = Get-RepinSpanEnd -Text $buildText -Open $referenceStart
    $applied = Set-RepinScalar -Text $buildText -Name 'sha256' -Start $referenceStart `
        -End $referenceEnd -Literal ('"' + $digest + '"')
    if ($applied.Changed) {
        Write-RepinText -Path $buildPlanPath -Text $applied.Text
        Write-Output "  $($reference.Member) digest -> $digest"
    }
    else { Write-Output "  $($reference.Member) digest already current" }
}

# 4. Built binary digests, absorbed from what the build reports until it verifies.
$pattern = "Build output '(?<path>[^']+)' is not reproducible from the reviewed plan: " +
    'actual bytes=(?<bytes>\d+), sha256=(?<sha>[0-9a-f]{64})\.'
for ($round = 1; $round -le $MaximumRounds; $round++) {
    $failure = $null
    # The build refuses to overwrite a published tree, and this loop builds more
    # than once, so each round gets its own directory under OutputRoot.
    $roundRoot = Join-Path $outputRootPath "round-$round"
    if (Test-Path -LiteralPath $roundRoot) { Remove-Item -LiteralPath $roundRoot -Recurse -Force }
    try {
        & $script:BuildScript -SourceRoot $sourceRootPath -ToolchainRoot $toolchainRootPath `
            -OutputRoot $roundRoot -BuildPlan $buildPlanPath -LockFile $lockPath
    }
    catch {
        $failure = [string]$_.Exception.Message
    }
    if ($null -eq $failure) {
        Write-Output "Build verified against the re-pinned plans on round $round."
        Write-Output "Built output: $roundRoot"
        Update-RepinStageManifest -BuildPlanPath $buildPlanPath -ManifestPath $StageManifest
        return
    }
    $match = [regex]::Match($failure, $pattern)
    if (-not $match.Success) { throw $failure }

    $reported = $match.Groups['path'].Value -replace '\\', '/'
    $buildText = Read-RepinText $buildPlanPath
    $stepSpans = Get-RepinArrayElementSpans -Text $buildText -Name 'steps' -Start 0 -End ($buildText.Length - 1)
    $patched = $false
    foreach ($stepSpan in $stepSpans) {
        $outputSpans = Get-RepinArrayElementSpans -Text $buildText -Name 'outputs' `
            -Start $stepSpan[0] -End $stepSpan[1]
        foreach ($outputSpan in $outputSpans) {
            $relativePath = (Get-RepinStringMember -Text $buildText -Name 'relative_path' `
                -Start $outputSpan[0] -End $outputSpan[1]) -replace '\\', '/'
            if (-not $reported.EndsWith('/' + $relativePath, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $spanEnd = $outputSpan[1]
            $result = Set-RepinScalar -Text $buildText -Name 'bytes' -Start $outputSpan[0] `
                -End $spanEnd -Literal $match.Groups['bytes'].Value
            $buildText = $result.Text
            $spanEnd += $result.Delta
            $result = Set-RepinScalar -Text $buildText -Name 'sha256' -Start $outputSpan[0] `
                -End $spanEnd -Literal ('"' + $match.Groups['sha'].Value + '"')
            $buildText = $result.Text
            Write-RepinText -Path $buildPlanPath -Text $buildText
            Write-Output "  output $relativePath -> $($match.Groups['sha'].Value) ($($match.Groups['bytes'].Value) bytes)"
            $patched = $true
            break
        }
        if ($patched) { break }
    }
    if (-not $patched) { throw "No build-plan output matched the reported path: $reported" }
}

throw "The build did not converge within $MaximumRounds rounds."

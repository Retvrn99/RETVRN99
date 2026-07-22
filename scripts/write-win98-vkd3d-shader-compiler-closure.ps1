# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceFile,
    [string]$OutputFile,
    [string]$DriversRoot,
    [switch]$Promote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'vkd3d-shader-compiler-evidence.ps1')

$vkd3dWriterWasDotSourced = $MyInvocation.InvocationName -eq '.'

function Assert-Vkd3dWriterExactFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExpectedFileIdentity
    )

    $handle = Open-Vkd3dEvidenceStableHandle $Path $Name
    try {
        $identity = Get-Vkd3dEvidenceHandleIdentity `
            $handle $Name 16777216
    }
    finally { $handle.Dispose() }
    if ([UInt64]$identity.bytes -ne [UInt64]$Bytes.Length -or
        $identity.sha256 -cne (Get-Vkd3dEvidenceSha256 $Bytes) -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedFileIdentity) -and
            $identity.file_identity -cne $ExpectedFileIdentity)) {
        throw "$Name changed."
    }
}

function Test-Vkd3dWriterExactBytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Left,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Right
    )

    return [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
        $Left,
        $Right
    )
}

function Read-Vkd3dWriterStableFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $handle = Open-Vkd3dEvidenceStableHandle $Path $Name
    try {
        $identity = Get-Vkd3dEvidenceHandleIdentity `
            $handle $Name 16777216
        [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
        if ([UInt64]$identity.bytes -ne [UInt64]$bytes.Length -or
            $identity.sha256 -cne (Get-Vkd3dEvidenceSha256 $bytes)) {
            throw "$Name changed."
        }
    }
    finally { $handle.Dispose() }
    return [pscustomobject]@{
        Bytes = $bytes
        FileIdentity = [string]$identity.file_identity
    }
}

function Get-Vkd3dWriterLeafObservation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
            return [pscustomobject]@{
                Kind = 'unknown'
                Snapshot = $null
                Failure = [InvalidOperationException]::new(
                    "$Name has an unreadable post-replace identity."
                )
            }
        }
        return [pscustomobject]@{
            Kind = 'absent'
            Snapshot = $null
            Failure = $null
        }
    }
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        return [pscustomobject]@{
            Kind = 'unknown'
            Snapshot = $null
            Failure = [InvalidOperationException]::new(
                "$Name has a non-ordinary post-replace identity."
            )
        }
    }
    try {
        $snapshot = Read-Vkd3dWriterStableFile $Path $Name
        return [pscustomobject]@{
            Kind = 'file'
            Snapshot = $snapshot
            Failure = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Kind = 'unknown'
            Snapshot = $null
            Failure = $_.Exception
        }
    }
}

function Test-Vkd3dWriterObservedLeaf {
    param(
        [Parameter(Mandatory = $true)][object]$Observation,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$FileIdentity
    )

    if ($Observation.Kind -cne 'file') { return $false }
    $snapshot = $Observation.Snapshot
    return [UInt64]$snapshot.Bytes.Length -eq [UInt64]$Bytes.Length -and
        (Get-Vkd3dEvidenceSha256 $snapshot.Bytes) -ceq
            (Get-Vkd3dEvidenceSha256 $Bytes) -and
        $snapshot.FileIdentity -ceq $FileIdentity
}

function Remove-Vkd3dWriterExactOwnedLeaf {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FileIdentity
    )

    Remove-Vkd3dEvidenceOwnedLeaf `
        -Parent $Parent -Path $Path -Name $Name `
        -ExpectedBytes ([UInt64]$Bytes.Length) `
        -ExpectedSha256 (Get-Vkd3dEvidenceSha256 $Bytes) `
        -ExpectedFileIdentity $FileIdentity
}

function New-Vkd3dWriterPrimaryFailure {
    param(
        [Parameter(Mandatory = $true)][Exception]$Primary,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PrivateRoots
    )

    $detail = Get-Vkd3dEvidenceSanitizedFailureText `
        -Exception $Primary -PrivateRoots $PrivateRoots
    return [InvalidOperationException]::new(
        "Compiler-closure promotion failed: $detail"
    )
}

function Invoke-Vkd3dWriterPromotionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceFile,
        [string]$OutputFile,
        [string]$DriversRoot,
        [switch]$Promote,
        [Parameter(DontShow = $true)]
        [AllowEmptyCollection()]
        [byte[]]$ExpectedPreviousBytes,
        [Parameter(DontShow = $true)]
        [scriptblock]$BeforeEvidenceVerification,
        [Parameter(DontShow = $true)][scriptblock]$BeforeCandidateCreate,
        [Parameter(DontShow = $true)][scriptblock]$AfterCandidateCreate,
        [Parameter(DontShow = $true)][scriptblock]$BeforePromotion,
        [Parameter(DontShow = $true)][scriptblock]$BeforeFinalVerification,
        [Parameter(DontShow = $true)][scriptblock]$AfterFinalVerification,
        [Parameter(DontShow = $true)][scriptblock]$ForwardReplaceFault,
        [Parameter(DontShow = $true)][scriptblock]$RollbackReplaceFault
    )

    $repoRoot = $null
    $drivers = $null
    $expectedOutput = $null
    $evidencePath = $null
    $outputPath = $null
    $parent = $null
    $temporaryPath = $null
    $backupPath = $null
    $displacedPath = $null
    $evidenceHandle = $null
    [byte[]]$evidenceBytes = $null
    [byte[]]$expectedPreviousSnapshot = $null
    [byte[]]$previousBytes = $null
    [byte[]]$backupBytes = $null
    $previousFileIdentity = $null
    $candidateFileIdentity = $null
    $backupFileIdentity = $null
    $hadPrevious = $false
    $candidateCreated = $false
    $promoted = $false
    $backupCreated = $false
    $displacedCreated = $false
    $primaryFailure = $null
    $cleanupFailures = [Collections.Generic.List[Exception]]::new()
    $hasExpectedPrevious =
        $PSBoundParameters.ContainsKey('ExpectedPreviousBytes')

    try {
        if (-not $Promote) {
            throw 'Compiler-closure promotion requires the explicit -Promote switch.'
        }
        if ($hasExpectedPrevious) {
            if ($null -eq $ExpectedPreviousBytes) {
                throw 'The exact expected previous bytes must not be null.'
            }
            $expectedPreviousSnapshot = [byte[]]$ExpectedPreviousBytes.Clone()
        }

        $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        if ([string]::IsNullOrWhiteSpace($DriversRoot)) {
            $DriversRoot = Join-Path $repoRoot 'drivers\win98'
        }
        $drivers = [IO.Path]::GetFullPath($DriversRoot).TrimEnd(
            [char[]]'\/'
        )
        $expectedOutput = Join-Path $drivers `
            'vkd3d-shader-compiler-closure.json'
        if ([string]::IsNullOrWhiteSpace($OutputFile)) {
            $OutputFile = $expectedOutput
        }
        $evidencePath = [IO.Path]::GetFullPath($EvidenceFile)
        $outputPath = [IO.Path]::GetFullPath($OutputFile)
        if ($evidencePath.Equals(
                $outputPath,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Evidence and promoted output paths must be distinct.'
        }
        $repoPrefix = $repoRoot.TrimEnd([char[]]'\/') +
            [IO.Path]::DirectorySeparatorChar
        if ($outputPath.StartsWith(
                $repoPrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -and -not $outputPath.Equals(
                $expectedOutput,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'A repository output must be the exact compiler-closure path.'
        }

        $evidenceHandle = Open-Vkd3dEvidenceStableHandle `
            $evidencePath 'external vkd3d-shader compiler evidence'
        try {
            $evidenceBeforeIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $evidenceHandle 'external vkd3d-shader compiler evidence' `
                16777216
            $evidenceBytes = [Retvrn99.Vkd3dEvidenceNative]::ReadAll(
                $evidenceHandle,
                [UInt64]16777216
            )
            $evidenceSha256 = Get-Vkd3dEvidenceSha256 $evidenceBytes
            if ([UInt64]$evidenceBeforeIdentity.bytes -ne
                    [UInt64]$evidenceBytes.Length -or
                [string]$evidenceBeforeIdentity.sha256 -cne
                    $evidenceSha256) {
                throw 'External compiler evidence changed during its held read.'
            }
            if ($evidenceBytes.Length -lt 2 -or
                ($evidenceBytes.Length -ge 3 -and
                    $evidenceBytes[0] -eq 0xef -and
                    $evidenceBytes[1] -eq 0xbb -and
                    $evidenceBytes[2] -eq 0xbf) -or
                $evidenceBytes -contains [byte]13 -or
                $evidenceBytes[$evidenceBytes.Length - 1] -ne 10) {
                throw 'External compiler evidence must be BOM-free canonical LF JSON.'
            }
            $evidence = ConvertFrom-GswStrictJsonUtf8Bytes `
                -Bytes $evidenceBytes `
                -Source 'external vkd3d-shader compiler evidence'
            Assert-GswJsonExactProperties $evidence.summary @(
                'source_files', 'generated_outputs', 'tracked_source_units',
                'generated_source_units', 'compile_commands',
                'twin_compile_invocations', 'dependency_files',
                'validated_amd64_coff_objects', 'objdump_validations',
                'child_processes', 'temporary_output_count',
                'proof_root_removed', 'partial_evidence_removed',
                'linker_invocations', 'failed_generator_commands',
                'failed_compile_commands', 'failed_dependency_validations',
                'failed_object_validations'
            ) 'external compiler evidence summary'
            foreach ($name in @(
                'temporary_output_count', 'linker_invocations',
                'failed_generator_commands', 'failed_compile_commands',
                'failed_dependency_validations', 'failed_object_validations'
            )) {
                if ([UInt64]$evidence.summary.$name -ne 0) {
                    throw "External compiler evidence has nonzero '$name'."
                }
            }
            if ($evidence.summary.proof_root_removed -isnot [bool] -or
                -not $evidence.summary.proof_root_removed -or
                $evidence.summary.partial_evidence_removed -isnot [bool] -or
                -not $evidence.summary.partial_evidence_removed) {
                throw 'External compiler evidence lacks complete cleanup proof.'
            }

            $verifier = Join-Path $PSScriptRoot `
                'verify-win98-vkd3d-shader-compiler-closure.ps1'
            if ($null -ne $BeforeEvidenceVerification) {
                & $BeforeEvidenceVerification $evidencePath
            }
            $preflight = @(& $verifier -ClosureFile $evidencePath `
                -DriversRoot $drivers)
            if ($preflight.Count -ne 1 -or
                [string]$preflight[0] -cnotmatch
                    '^Verified vkd3d-shader compiler closure:') {
                throw 'External compiler evidence did not pass the metadata verifier.'
            }
            $evidenceAfterIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $evidenceHandle 'verified vkd3d-shader compiler evidence' `
                16777216
            [byte[]]$evidenceAfterBytes = `
                [Retvrn99.Vkd3dEvidenceNative]::ReadAll(
                    $evidenceHandle,
                    [UInt64]16777216
                )
            if ([UInt64]$evidenceAfterIdentity.bytes -ne
                    [UInt64]$evidenceBeforeIdentity.bytes -or
                [string]$evidenceAfterIdentity.sha256 -cne
                    [string]$evidenceBeforeIdentity.sha256 -or
                [string]$evidenceAfterIdentity.file_identity -cne
                    [string]$evidenceBeforeIdentity.file_identity -or
                -not (Test-Vkd3dWriterExactBytes `
                    $evidenceAfterBytes $evidenceBytes)) {
                throw 'External compiler evidence changed across verification.'
            }
        }
        finally {
            if ($null -ne $evidenceHandle -and
                -not $evidenceHandle.IsClosed) {
                $evidenceHandle.Dispose()
            }
            $evidenceHandle = $null
        }

        $parent = [IO.Path]::GetDirectoryName($outputPath)
        Assert-Vkd3dEvidenceNoReparseAncestor `
            $parent 'compiler-closure output parent'
        Assert-Vkd3dEvidenceDirectory $parent 'compiler-closure output parent'
        $temporaryPath = $outputPath + '.partial-' +
            [Guid]::NewGuid().ToString('N')
        $outputItem = Get-Item -LiteralPath $outputPath -Force `
            -ErrorAction SilentlyContinue
        $hadPrevious = $null -ne $outputItem
        if ($hadPrevious) {
            $previous = Read-Vkd3dWriterStableFile `
                $outputPath 'existing compiler closure'
            [byte[]]$previousBytes = $previous.Bytes
            $previousFileIdentity = $previous.FileIdentity
            if ($hasExpectedPrevious) {
                if (-not (Test-Vkd3dWriterExactBytes `
                        $previousBytes $expectedPreviousSnapshot)) {
                    throw (
                        'Existing compiler closure differs from the exact ' +
                        'expected previous bytes.'
                    )
                }
            }
            elseif (-not (Test-Vkd3dWriterExactBytes `
                    $previousBytes $evidenceBytes)) {
                throw (
                    'Existing compiler closure differs from verified ' +
                    'evidence; public overwrite refused.'
                )
            }
            $backupPath = $outputPath + '.backup-' +
                [Guid]::NewGuid().ToString('N')
        }
        elseif ($hasExpectedPrevious) {
            throw 'The exact expected previous output is absent.'
        }
        elseif ([IO.File]::Exists($outputPath) -or
            [IO.Directory]::Exists($outputPath)) {
            throw 'Existing compiler closure has an unreadable identity.'
        }

        Assert-Vkd3dEvidenceFreshMutationBoundary `
            $parent @($temporaryPath) 'compiler-closure candidate boundary'
        if ($null -ne $BeforeCandidateCreate) {
            & $BeforeCandidateCreate $temporaryPath
        }
        Assert-Vkd3dEvidenceFreshMutationBoundary `
            $parent @($temporaryPath) 'compiler-closure candidate boundary'
        Initialize-Vkd3dEvidenceNative
        $stream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $candidateCreated = $true
        try {
            $stream.Write($evidenceBytes, 0, $evidenceBytes.Length)
            $stream.Flush($true)
            $candidateIdentity = Get-Vkd3dEvidenceHandleIdentity `
                $stream.SafeFileHandle 'compiler-closure candidate' 16777216
            if ([UInt64]$candidateIdentity.bytes -ne
                    [UInt64]$evidenceBytes.Length -or
                $candidateIdentity.sha256 -cne
                    (Get-Vkd3dEvidenceSha256 $evidenceBytes)) {
                throw 'Compiler-closure candidate write changed.'
            }
            $candidateFileIdentity = $candidateIdentity.file_identity
        }
        finally { $stream.Dispose() }
        if ($null -ne $AfterCandidateCreate) {
            & $AfterCandidateCreate $temporaryPath
        }
        Assert-Vkd3dWriterExactFile `
            $temporaryPath $evidenceBytes 'compiler-closure candidate' `
            $candidateFileIdentity
        $candidate = @(& $verifier -ClosureFile $temporaryPath `
            -DriversRoot $drivers)
        if ($candidate.Count -ne 1 -or
            [string]$candidate[0] -cnotmatch
                '^Verified vkd3d-shader compiler closure:') {
            throw 'Atomic compiler-closure candidate failed verification.'
        }

        Assert-Vkd3dEvidenceNoReparseAncestor `
            $parent 'compiler-closure promotion parent'
        Assert-Vkd3dEvidenceDirectory $parent 'compiler-closure promotion parent'
        if ($hadPrevious) {
            Assert-Vkd3dEvidenceFreshMutationBoundary `
                $parent @($backupPath) 'compiler-closure backup boundary'
            Assert-Vkd3dWriterExactFile `
                $outputPath $previousBytes `
                'existing compiler closure before promotion' `
                $previousFileIdentity
        }
        else {
            Assert-Vkd3dEvidenceFreshMutationBoundary `
                $parent @($outputPath) 'compiler-closure promotion boundary'
        }
        Assert-Vkd3dWriterExactFile `
            $temporaryPath $evidenceBytes `
            'compiler-closure candidate before promotion' `
            $candidateFileIdentity
        if ($null -ne $BeforePromotion) {
            & $BeforePromotion $outputPath $backupPath $hadPrevious
        }
        Assert-Vkd3dEvidenceNoReparseAncestor `
            $parent 'compiler-closure atomic promotion parent'
        Assert-Vkd3dEvidenceDirectory `
            $parent 'compiler-closure atomic promotion parent'
        Assert-Vkd3dWriterExactFile `
            $temporaryPath $evidenceBytes `
            'compiler-closure candidate at atomic promotion' `
            $candidateFileIdentity
        if ($hadPrevious) {
            Assert-Vkd3dEvidenceFreshMutationBoundary `
                $parent @($backupPath) 'compiler-closure backup boundary'
            try {
                if ($null -ne $ForwardReplaceFault) {
                    & $ForwardReplaceFault `
                        $temporaryPath $outputPath $backupPath
                }
                else {
                    [IO.File]::Replace(
                        $temporaryPath,
                        $outputPath,
                        $backupPath,
                        $true
                    )
                }
            }
            catch {
                $forwardReplaceFailure = $_.Exception
                $candidateObservation = Get-Vkd3dWriterLeafObservation `
                    $temporaryPath 'post-replace compiler-closure candidate'
                $outputObservation = Get-Vkd3dWriterLeafObservation `
                    $outputPath 'post-replace compiler closure'
                $backupObservation = Get-Vkd3dWriterLeafObservation `
                    $backupPath 'post-replace compiler-closure backup'

                if ($candidateObservation.Kind -ceq 'absent') {
                    $candidateCreated = $false
                }
                elseif (Test-Vkd3dWriterObservedLeaf `
                        $candidateObservation $evidenceBytes `
                        $candidateFileIdentity) {
                    $candidateCreated = $true
                }
                else {
                    $candidateCreated = $false
                    $cleanupFailures.Add([InvalidOperationException]::new(
                        'Forward replace left an unknown candidate leaf.'
                    ))
                }

                if (Test-Vkd3dWriterObservedLeaf `
                        $backupObservation $previousBytes `
                        $previousFileIdentity) {
                    [byte[]]$backupBytes = $previousBytes
                    $backupFileIdentity = $previousFileIdentity
                    $backupCreated = $true
                }
                elseif ($backupObservation.Kind -ceq 'absent') {
                    $backupCreated = $false
                }
                else {
                    $backupCreated = $false
                    $cleanupFailures.Add([InvalidOperationException]::new(
                        'Forward replace left an unknown backup leaf.'
                    ))
                }

                $outputIsCandidate = Test-Vkd3dWriterObservedLeaf `
                    $outputObservation $evidenceBytes $candidateFileIdentity
                $outputIsPrevious = Test-Vkd3dWriterObservedLeaf `
                    $outputObservation $previousBytes $previousFileIdentity
                if ($outputIsCandidate) {
                    if ($backupCreated) {
                        $promoted = $true
                    }
                    else {
                        $promoted = $false
                        $cleanupFailures.Add([InvalidOperationException]::new(
                            'Forward replace lost the prior destination backup.'
                        ))
                    }
                }
                elseif ($outputIsPrevious) {
                    $promoted = $false
                    if ($backupCreated) {
                        $backupCreated = $false
                        $cleanupFailures.Add([InvalidOperationException]::new(
                            'Forward replace left an unexpected backup leaf.'
                        ))
                    }
                }
                elseif ($outputObservation.Kind -ceq 'absent' -and
                    $backupCreated) {
                    $promoted = $false
                    try {
                        [IO.File]::Move($backupPath, $outputPath, $false)
                        $backupCreated = $false
                        Assert-Vkd3dWriterExactFile `
                            $outputPath $backupBytes `
                            'restored partial forward-replace destination' `
                            $backupFileIdentity
                    }
                    catch {
                        $backupCreated = $false
                        $cleanupFailures.Add($_.Exception)
                    }
                }
                else {
                    $promoted = $false
                    if ($backupCreated) { $backupCreated = $false }
                    $cleanupFailures.Add([InvalidOperationException]::new(
                        'Forward replace left an unknown destination state.'
                    ))
                }
                throw $forwardReplaceFailure
            }
            $candidateCreated = $false
            $promoted = $true
            $backupCreated = $true
            $backup = Read-Vkd3dWriterStableFile `
                $backupPath 'atomic compiler-closure backup'
            [byte[]]$backupBytes = $backup.Bytes
            $backupFileIdentity = $backup.FileIdentity
            Assert-Vkd3dWriterExactFile `
                $backupPath $previousBytes `
                'atomic compiler-closure backup' $previousFileIdentity
        }
        else {
            [IO.File]::Move($temporaryPath, $outputPath, $false)
            $candidateCreated = $false
            $promoted = $true
        }

        if ($null -ne $BeforeFinalVerification) {
            & $BeforeFinalVerification $outputPath
        }
        Assert-Vkd3dWriterExactFile `
            $outputPath $evidenceBytes `
            'promoted compiler closure before final verification' `
            $candidateFileIdentity
        $final = @(& $verifier -ClosureFile $outputPath -DriversRoot $drivers)
        if ($final.Count -ne 1 -or
            [string]$final[0] -cnotmatch
                '^Verified vkd3d-shader compiler closure:') {
            throw 'Promoted compiler closure failed final verification.'
        }
        if ($null -ne $AfterFinalVerification) {
            & $AfterFinalVerification $outputPath
        }
        Assert-Vkd3dWriterExactFile `
            $outputPath $evidenceBytes `
            'promoted compiler closure after final verification' `
            $candidateFileIdentity
        if ($backupCreated) {
            Remove-Vkd3dWriterExactOwnedLeaf `
                $parent $backupPath $backupBytes `
                'compiler-closure atomic backup' $backupFileIdentity
            $backupCreated = $false
        }
    }
    catch {
        $primaryFailure = $_.Exception
        if ($promoted) {
            try {
                Assert-Vkd3dWriterExactFile `
                    $outputPath $evidenceBytes `
                    'promoted compiler closure before rollback' `
                    $candidateFileIdentity
                if ($hadPrevious) {
                    if (-not $backupCreated -or $null -eq $backupBytes) {
                        throw 'Atomic compiler-closure backup is unavailable.'
                    }
                    Assert-Vkd3dWriterExactFile `
                        $backupPath $backupBytes `
                        'compiler-closure backup before rollback' `
                        $backupFileIdentity
                    $displacedPath = $outputPath + '.displaced-' +
                        [Guid]::NewGuid().ToString('N')
                    Assert-Vkd3dEvidenceFreshMutationBoundary `
                        $parent @($displacedPath) `
                        'compiler-closure rollback displacement boundary'
                    try {
                        if ($null -ne $RollbackReplaceFault) {
                            & $RollbackReplaceFault `
                                $backupPath $outputPath $displacedPath
                        }
                        else {
                            [IO.File]::Replace(
                                $backupPath,
                                $outputPath,
                                $displacedPath,
                                $true
                            )
                        }
                    }
                    catch {
                        $rollbackReplaceFailure = $_.Exception
                        $backupObservation = Get-Vkd3dWriterLeafObservation `
                            $backupPath `
                            'post-rollback compiler-closure backup'
                        $outputObservation = Get-Vkd3dWriterLeafObservation `
                            $outputPath 'post-rollback compiler closure'
                        $displacedObservation = `
                            Get-Vkd3dWriterLeafObservation `
                                $displacedPath `
                                'post-rollback displaced compiler closure'

                        if (Test-Vkd3dWriterObservedLeaf `
                                $backupObservation $backupBytes `
                                $backupFileIdentity) {
                            $backupCreated = $true
                        }
                        elseif ($backupObservation.Kind -ceq 'absent') {
                            $backupCreated = $false
                        }
                        else {
                            $backupCreated = $false
                            $cleanupFailures.Add(
                                [InvalidOperationException]::new(
                                    'Rollback replace left an unknown backup leaf.'
                                )
                            )
                        }

                        if (Test-Vkd3dWriterObservedLeaf `
                                $displacedObservation $evidenceBytes `
                                $candidateFileIdentity) {
                            $displacedCreated = $true
                        }
                        elseif ($displacedObservation.Kind -ceq 'absent') {
                            $displacedCreated = $false
                        }
                        else {
                            $displacedCreated = $false
                            $cleanupFailures.Add(
                                [InvalidOperationException]::new(
                                    'Rollback replace left an unknown displaced leaf.'
                                )
                            )
                        }

                        $outputIsCandidate = Test-Vkd3dWriterObservedLeaf `
                            $outputObservation $evidenceBytes `
                            $candidateFileIdentity
                        $outputIsPrior = Test-Vkd3dWriterObservedLeaf `
                            $outputObservation $backupBytes `
                            $backupFileIdentity
                        if ($outputIsPrior) {
                            $promoted = $false
                            if ($backupCreated) {
                                $backupCreated = $false
                                $cleanupFailures.Add(
                                    [InvalidOperationException]::new(
                                        'Rollback replace left a duplicate backup leaf.'
                                    )
                                )
                            }
                        }
                        elseif ($outputObservation.Kind -ceq 'absent' -and
                            $backupCreated) {
                            $promoted = $false
                            try {
                                [IO.File]::Move(
                                    $backupPath,
                                    $outputPath,
                                    $false
                                )
                                $backupCreated = $false
                                Assert-Vkd3dWriterExactFile `
                                    $outputPath $backupBytes `
                                    'restored partial rollback destination' `
                                    $backupFileIdentity
                            }
                            catch {
                                $backupCreated = $false
                                $cleanupFailures.Add($_.Exception)
                            }
                        }
                        elseif ($outputIsCandidate -and $backupCreated) {
                            try {
                                Remove-Vkd3dWriterExactOwnedLeaf `
                                    $parent $outputPath $evidenceBytes `
                                    'rollback candidate destination' `
                                    $candidateFileIdentity
                                $promoted = $false
                                [IO.File]::Move(
                                    $backupPath,
                                    $outputPath,
                                    $false
                                )
                                $backupCreated = $false
                                Assert-Vkd3dWriterExactFile `
                                    $outputPath $backupBytes `
                                    'restored fallback rollback destination' `
                                    $backupFileIdentity
                            }
                            catch {
                                $backupCreated = $false
                                $cleanupFailures.Add($_.Exception)
                            }
                        }
                        else {
                            $promoted = $false
                            if ($backupCreated) { $backupCreated = $false }
                            $cleanupFailures.Add(
                                [InvalidOperationException]::new(
                                    'Rollback replace left an unknown destination state.'
                                )
                            )
                        }
                        throw $rollbackReplaceFailure
                    }
                    $backupCreated = $false
                    $promoted = $false
                    $displacedCreated = $true
                    Assert-Vkd3dWriterExactFile `
                        $outputPath $backupBytes `
                        'restored compiler closure' $backupFileIdentity
                    Assert-Vkd3dWriterExactFile `
                        $displacedPath $evidenceBytes `
                        'displaced compiler closure after rollback' `
                        $candidateFileIdentity
                    Remove-Vkd3dWriterExactOwnedLeaf `
                        $parent $displacedPath $evidenceBytes `
                        'displaced compiler closure' `
                        $candidateFileIdentity
                    $displacedCreated = $false
                }
                else {
                    Remove-Vkd3dWriterExactOwnedLeaf `
                        $parent $outputPath $evidenceBytes `
                        'promoted compiler closure' $candidateFileIdentity
                    $promoted = $false
                }
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }
    }
    finally {
        if ($null -ne $evidenceHandle -and
            -not $evidenceHandle.IsClosed) {
            $evidenceHandle.Dispose()
            $evidenceHandle = $null
        }
        if ($candidateCreated) {
            try {
                Remove-Vkd3dWriterExactOwnedLeaf `
                    $parent $temporaryPath $evidenceBytes `
                    'compiler-closure candidate' $candidateFileIdentity
                $candidateCreated = $false
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        if ($backupCreated -and $null -ne $backupBytes) {
            try {
                Remove-Vkd3dWriterExactOwnedLeaf `
                    $parent $backupPath $backupBytes `
                    'compiler-closure atomic backup' $backupFileIdentity
                $backupCreated = $false
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        if ($displacedCreated) {
            try {
                Remove-Vkd3dWriterExactOwnedLeaf `
                    $parent $displacedPath $evidenceBytes `
                    'displaced compiler closure' $candidateFileIdentity
                $displacedCreated = $false
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }
    }

    [string[]]$privateRoots = @(@(
        $PSScriptRoot, $repoRoot, $DriversRoot, $drivers, $EvidenceFile,
        $evidencePath, $OutputFile, $outputPath, $parent, $temporaryPath,
        $backupPath, $displacedPath
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($cleanupFailures.Count -gt 0) {
        if ($null -ne $primaryFailure) {
            throw (New-Vkd3dEvidenceCombinedFailure `
                -Primary $primaryFailure `
                -Cleanup ([Exception[]]$cleanupFailures.ToArray()) `
                -PrivateRoots $privateRoots)
        }
        throw (New-Vkd3dEvidenceCleanupFailure `
            -Cleanup ([Exception[]]$cleanupFailures.ToArray()) `
            -PrivateRoots $privateRoots)
    }
    if ($null -ne $primaryFailure) {
        throw (New-Vkd3dWriterPrimaryFailure `
            -Primary $primaryFailure -PrivateRoots $privateRoots)
    }

    Write-Output (
        'Promoted compile-proven vkd3d-shader compiler closure after ' +
        'external verification, atomic LF write, and final verification.'
    )
}

if (-not $vkd3dWriterWasDotSourced) {
    Invoke-Vkd3dWriterPromotionInternal `
        -EvidenceFile $EvidenceFile `
        -OutputFile $OutputFile `
        -DriversRoot $DriversRoot `
        -Promote:$Promote
}

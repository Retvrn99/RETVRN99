# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(64, 4096)]
    [int]$Width,

    [Parameter(Mandatory = $true)]
    [ValidateRange(64, 4096)]
    [int]$Height,

    [ValidateRange(1, 10)]
    [int]$WarmupSeconds = 2,

    [ValidateRange(5, 60)]
    [int]$StableSeconds = 10,

    [Parameter(Mandatory = $true)]
    [string]$RunRoot,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'presentation-60hz-proof-support.ps1')

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [Runtime.InteropServices.OSPlatform]::Windows
)) {
    throw 'The presentation proof runner requires Windows.'
}
$p95Limit = Get-PresentationProofP95Limit -Width $Width -Height $Height
$repository = (Assert-PresentationProofOrdinaryPath `
    -Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) `
    -Name 'repository' -Kind Directory).FullName
$run = (Assert-PresentationProofOrdinaryPath -Path $RunRoot -Name 'run root' `
    -Kind Directory).FullName
$driveRoot = [IO.Path]::GetPathRoot($run).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
if ($run.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
).Equals($driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The run root must not be a filesystem root.'
}
$repositoryPrefix = $repository.TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar
$runPrefix = $run.TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar
if ($run.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
    $run.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $repository.StartsWith($runPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The run root and repository must be separate nonoverlapping trees.'
}
$evidence = Assert-PresentationProofAbsentChild -RunRoot $run -Path $EvidenceRoot `
    -Name 'evidence root'

$odin = (Get-Command odin -CommandType Application -ErrorAction Stop).Source
$git = (Get-Command git -CommandType Application -ErrorAction Stop).Source
$null = Assert-PresentationProofOrdinaryPath -Path $odin -Name 'Odin compiler' -Kind File
$null = Assert-PresentationProofOrdinaryPath -Path $git -Name 'Git executable' -Kind File
$toolSource = Join-Path $repository 'tools\presentation-60hz-proof'
$sdlSource = Join-Path $repository 'SDL3.dll'
$null = Assert-PresentationProofOrdinaryPath -Path $sdlSource -Name 'repository SDL3.dll' `
    -Kind File

$binary = Join-Path $evidence 'retvrn99-presentation-60hz-proof.exe'
$sdlCopy = Join-Path $evidence 'SDL3.dll'
$buildStdout = Join-Path $evidence 'build.stdout.txt'
$buildStderr = Join-Path $evidence 'build.stderr.txt'
$runStdout = Join-Path $evidence 'run.stdout.txt'
$runStderr = Join-Path $evidence 'run.stderr.txt'
$resultPath = Join-Path $evidence 'result.json'
$preStatePath = Join-Path $evidence 'pre-state.json'
$manifestPath = Join-Path $evidence 'run-manifest.json'
$failureManifestPath = Join-Path $evidence 'failure-manifest.json'
$maximumProcessOutputBytes = 67108864

$startedUtc = [DateTimeOffset]::UtcNow
$endedUtc = $null
$phase = 'create-evidence'
$evidenceCreated = $false
$evidenceValidated = $false
$preState = $null
$postState = $null
$build = $null
$proofRun = $null
$result = $null
$completed = $false

try {
    New-Item -ItemType Directory -Path $evidence -ErrorAction Stop | Out-Null
    $evidenceCreated = $true
    $created = Assert-PresentationProofOrdinaryPath -Path $evidence `
        -Name 'evidence root' -Kind Directory
    if (-not $created.Parent.FullName.Equals($run, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The created evidence root escaped its direct run-root parent.'
    }
    $evidenceValidated = $true

    $phase = 'capture-pre-state'
    $preState = [pscustomobject][ordered]@{
        schema = 1
        recorded_utc = [DateTimeOffset]::UtcNow.ToString('o')
        repository = $repository
        source = @(Get-PresentationProofSourceInventory -Repository $repository)
        git = Get-PresentationProofGitIdentity -Git $git -Repository $repository
        toolchain = Get-PresentationProofToolchainIdentity -Odin $odin
        runtime = [pscustomobject][ordered]@{
            operating_system = [Environment]::OSVersion.VersionString
            process_architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
            powershell = $PSVersionTable.PSVersion.ToString()
            sdl3_sha256 = (Get-FileHash -LiteralPath $sdlSource -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    Write-PresentationProofNewJson -Path $preStatePath -Value $preState

    $phase = 'build'
    $buildArguments = @(
        'build',
        $toolSource,
        '-o:speed',
        '-thread-count:8',
        "-out:$binary"
    )
    $build = Invoke-PresentationProofCapturedProcess `
        -FilePath $odin `
        -Arguments $buildArguments `
        -WorkingDirectory $repository `
        -StdoutPath $buildStdout `
        -StderrPath $buildStderr `
        -TimeoutMilliseconds 120000 `
        -MaximumStdoutBytes $maximumProcessOutputBytes `
        -MaximumStderrBytes $maximumProcessOutputBytes
    if ($build.TimedOut) { throw 'The presentation proof build exceeded its bounded timeout.' }
    if ($build.ExitCode -ne 0) {
        throw "Presentation proof build failed with exit code $($build.ExitCode)."
    }
    $null = Assert-PresentationProofOrdinaryPath -Path $binary `
        -Name 'presentation proof executable' -Kind File

    $phase = 'pre-run-revalidation'
    $preRunSource = @(Get-PresentationProofSourceInventory -Repository $repository)
    $preRunGit = Get-PresentationProofGitIdentity -Git $git -Repository $repository
    $preRunToolchain = Get-PresentationProofToolchainIdentity -Odin $odin
    Assert-PresentationProofStateEqual -Expected $preState.source -Actual $preRunSource `
        -Name 'source inventory during build'
    Assert-PresentationProofStateEqual -Expected $preState.git -Actual $preRunGit `
        -Name 'Git identity during build'
    Assert-PresentationProofStateEqual -Expected $preState.toolchain -Actual $preRunToolchain `
        -Name 'toolchain identity during build'
    $null = Assert-PresentationProofOrdinaryPath -Path $evidence `
        -Name 'evidence root before runtime staging' -Kind Directory
    [IO.File]::Copy($sdlSource, $sdlCopy, $false)
    $null = Assert-PresentationProofOrdinaryPath -Path $sdlCopy `
        -Name 'evidence SDL3.dll' -Kind File
    $sourceSdlHash = (Get-FileHash -LiteralPath $sdlSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $copySdlHash = (Get-FileHash -LiteralPath $sdlCopy -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceSdlHash -cne $copySdlHash -or
        $sourceSdlHash -cne [string]$preState.runtime.sdl3_sha256) {
        throw 'The staged SDL3.dll does not match the pre-build runtime identity.'
    }

    $phase = 'run-proof'
    $runArguments = @(
        "--width:$Width",
        "--height:$Height",
        "--warmup-seconds:$WarmupSeconds",
        "--stable-seconds:$StableSeconds"
    )
    $null = Assert-PresentationProofOrdinaryPath -Path $evidence `
        -Name 'evidence root before proof launch' -Kind Directory
    $null = Assert-PresentationProofOrdinaryPath -Path $binary `
        -Name 'presentation proof executable before launch' -Kind File
    $null = Assert-PresentationProofOrdinaryPath -Path $sdlCopy `
        -Name 'evidence SDL3.dll before launch' -Kind File
    $proofRun = Invoke-PresentationProofCapturedProcess `
        -FilePath $binary `
        -Arguments $runArguments `
        -WorkingDirectory $evidence `
        -StdoutPath $runStdout `
        -StderrPath $runStderr `
        -TimeoutMilliseconds (($WarmupSeconds + $StableSeconds + 30) * 1000) `
        -MaximumStdoutBytes $maximumProcessOutputBytes `
        -MaximumStderrBytes $maximumProcessOutputBytes
    $endedUtc = [DateTimeOffset]::UtcNow

    $phase = 'post-run-revalidation'
    $postState = [pscustomobject][ordered]@{
        recorded_utc = [DateTimeOffset]::UtcNow.ToString('o')
        source = @(Get-PresentationProofSourceInventory -Repository $repository)
        git = Get-PresentationProofGitIdentity -Git $git -Repository $repository
        toolchain = Get-PresentationProofToolchainIdentity -Odin $odin
        runtime = [pscustomobject][ordered]@{
            operating_system = [Environment]::OSVersion.VersionString
            process_architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
            powershell = $PSVersionTable.PSVersion.ToString()
            sdl3_sha256 = (Get-FileHash -LiteralPath $sdlSource -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    Assert-PresentationProofStateEqual -Expected $preState.source -Actual $postState.source `
        -Name 'source inventory during proof'
    Assert-PresentationProofStateEqual -Expected $preState.git -Actual $postState.git `
        -Name 'Git identity during proof'
    Assert-PresentationProofStateEqual -Expected $preState.toolchain -Actual $postState.toolchain `
        -Name 'toolchain identity during proof'
    Assert-PresentationProofStateEqual -Expected $preState.runtime -Actual $postState.runtime `
        -Name 'runtime identity during proof'
    if ($proofRun.TimedOut) { throw 'The presentation proof exceeded its bounded timeout.' }

    $phase = 'validate-result'
    $resultMatches = [regex]::Matches(
        $proofRun.Stdout,
        '(?m)^PRESENTATION_60HZ_RESULT (?<json>\{.*\})\r?$'
    )
    if ($resultMatches.Count -ne 1) {
        throw 'The proof process did not emit exactly one marked result.'
    }
    $resultJson = $resultMatches[0].Groups['json'].Value
    Write-PresentationProofNewText -Path $resultPath -Text ($resultJson + "`n")
    $result = Assert-PresentationProofResult -Json $resultJson -Width $Width -Height $Height `
        -WarmupSeconds $WarmupSeconds -StableSeconds $StableSeconds
    if ($proofRun.ExitCode -ne 0) {
        throw "Presentation proof process failed with exit code $($proofRun.ExitCode)."
    }

    $phase = 'write-success-manifest'
    $artifacts = @(Get-PresentationProofArtifactInventory -EvidenceRoot $evidence `
        -Exclude @('run-manifest.json', 'failure-manifest.json'))
    $manifest = [pscustomobject][ordered]@{
        schema = 1
        tool = 'retvrn99-presentation-60hz-proof-runner'
        status = 'passed'
        started_utc = $startedUtc.ToString('o')
        ended_utc = $endedUtc.ToString('o')
        source_before = $preState
        source_after = $postState
        source_revalidated = $true
        command = [pscustomobject][ordered]@{
            width = $Width
            height = $Height
            target_hz = 60
            minimum_fps_milli = 55000
            host_presentation_metric = 'pipeline_ns'
            host_presentation_p95_limit_ns = $p95Limit
            warmup_seconds = $WarmupSeconds
            stable_seconds = $StableSeconds
            arguments = @($runArguments)
        }
        process = [pscustomobject][ordered]@{
            build_exit_code = $build.ExitCode
            build_timed_out = $build.TimedOut
            run_exit_code = $proofRun.ExitCode
            run_timed_out = $proofRun.TimedOut
            maximum_stdout_bytes = $maximumProcessOutputBytes
            maximum_stderr_bytes = $maximumProcessOutputBytes
        }
        artifacts = $artifacts
        result = $result
    }
    Write-PresentationProofNewJson -Path $manifestPath -Value $manifest
    $completed = $true

    Write-Output (
        'Presentation 60 Hz proof passed: {0}x{1}, fps_milli={2}, pipeline_p95_ns={3}, samples={4}, evidence={5}' -f
            $Width,
            $Height,
            $result.presented_fps_milli,
            $result.pipeline_timing.p95_ns,
            $result.sample_count,
            $evidence
    )
}
catch {
    $failure = $_.Exception.Message
    if ($null -eq $endedUtc) { $endedUtc = [DateTimeOffset]::UtcNow }
    if ($evidenceCreated -and $evidenceValidated -and -not $completed) {
        try {
            $current = $null
            try {
                $current = [pscustomobject][ordered]@{
                    recorded_utc = [DateTimeOffset]::UtcNow.ToString('o')
                    source = @(Get-PresentationProofSourceInventory -Repository $repository)
                    git = Get-PresentationProofGitIdentity -Git $git -Repository $repository
                    toolchain = Get-PresentationProofToolchainIdentity -Odin $odin
                    runtime = [pscustomobject][ordered]@{
                        operating_system = [Environment]::OSVersion.VersionString
                        process_architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
                        powershell = $PSVersionTable.PSVersion.ToString()
                        sdl3_sha256 = (Get-FileHash -LiteralPath $sdlSource -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                }
            }
            catch {
                $current = [pscustomobject][ordered]@{
                    capture_error = $_.Exception.Message
                }
            }
            $failureManifest = [pscustomobject][ordered]@{
                schema = 1
                tool = 'retvrn99-presentation-60hz-proof-runner'
                status = 'failed'
                phase = $phase
                failure = $failure
                started_utc = $startedUtc.ToString('o')
                ended_utc = $endedUtc.ToString('o')
                source_before = $preState
                source_at_failure = $current
                process = [pscustomobject][ordered]@{
                    build_exit_code = $null -eq $build ? $null : $build.ExitCode
                    build_timed_out = $null -eq $build ? $null : $build.TimedOut
                    run_exit_code = $null -eq $proofRun ? $null : $proofRun.ExitCode
                    run_timed_out = $null -eq $proofRun ? $null : $proofRun.TimedOut
                    maximum_stdout_bytes = $maximumProcessOutputBytes
                    maximum_stderr_bytes = $maximumProcessOutputBytes
                }
                artifacts = @(Get-PresentationProofArtifactInventory -EvidenceRoot $evidence `
                    -Exclude @('run-manifest.json', 'failure-manifest.json'))
            }
            if (-not (Test-Path -LiteralPath $failureManifestPath)) {
                Write-PresentationProofNewJson -Path $failureManifestPath -Value $failureManifest
            }
        }
        catch {
            Write-Warning "Could not finish the failure manifest: $($_.Exception.Message)"
        }
    }
    throw "Presentation proof failed during '$phase': $failure Evidence was preserved at '$evidence'."
}

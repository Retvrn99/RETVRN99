# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$support = Join-Path $PSScriptRoot 'test-control-evidence-support.ps1'
$runner = Join-Path $PSScriptRoot 'run-test-control-evidence.ps1'
. $support

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $repositoryRoot (
    'dev\test-control-evidence-tests\' + [Guid]::NewGuid().ToString('N')
)
$script:tests = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:tests += 1
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $script:tests += 1
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message Observed: $($_.Exception.Message)"
        }
        return
    }
    throw $Message
}

function Write-TestUtf8 {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-TestBytes {
    param([string]$Text)
    return ,([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Start-TestOutputChild {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][Int64]$StdoutMaximumBytes,
        [Parameter(Mandatory = $true)][Int64]$StderrMaximumBytes
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add('-NoProfile')
    [void]$startInfo.ArgumentList.Add('-NonInteractive')
    [void]$startInfo.ArgumentList.Add('-Command')
    [void]$startInfo.ArgumentList.Add($Script)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $clock = [Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) { throw 'The synthetic output child did not start.' }
    $stdout = [Retvrn99.TestControlOutput.BoundedUtf8LineCollector]::Start(
        $process.StandardOutput.BaseStream,
        $clock,
        $StdoutMaximumBytes
    )
    $stderr = [Retvrn99.TestControlOutput.BoundedUtf8LineCollector]::Start(
        $process.StandardError.BaseStream,
        $clock,
        $StderrMaximumBytes
    )
    return [pscustomobject]@{
        Process = $process
        Clock = $clock
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Wait-TestOutputChild {
    param([Parameter(Mandatory = $true)][object]$Child)

    if (-not $Child.Process.WaitForExit(5000)) {
        $Child.Process.Kill($true)
        $Child.Process.WaitForExit()
        throw 'The synthetic output child exceeded its five-second deadline.'
    }
}

function New-CapturePlanText {
    param([object[]]$Captures)
    return ([ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        captures = $Captures
    } | ConvertTo-Json -Depth 6)
}

function New-PostmortemText {
    param(
        [int]$ProcessId,
        [UInt64]$Revision = 9,
        [string]$Session,
        [string]$Stage = 'complete'
    )
    if ([string]::IsNullOrEmpty($Session)) { $Session = "gui-$ProcessId-123456" }
    $measured = {
        param([UInt64]$Value)
        return [ordered]@{ value = $Value; provenance = 'measured' }
    }
    return ([ordered]@{
        schema = 2
        revision = $Revision
        session = [ordered]@{ value = $Session; provenance = 'derived' }
        device = [ordered]@{
            value = 'PCI\VEN_FFFE&DEV_0002'
            provenance = 'derived'
        }
        session_generation = & $measured 3
        guest_device_generation = & $measured 5
        host_device_generation = & $measured 7
        frame_generation = & $measured 11
        host_stage = [ordered]@{ value = $Stage; provenance = 'measured' }
        window = [ordered]@{ value = 'graphics window'; provenance = 'derived' }
        window_frame_generation = & $measured 11
        vm = [ordered]@{ value = 'EIP=12345678'; provenance = 'measured' }
        vm_frame_generation = & $measured 11
    } | ConvertTo-Json -Depth 8)
}

$validControl = @(
    'control input: state=Completed failure=None success=true actions=4 queued=4 applied=4 stale_dropped=0 reset_cancelled=0 resolved=4 unresolved=0 over_resolved=0 pending=0 correlated_events=4 correlated_presentations=3 correlation_success=true correlation_avg_us=10 correlation_p50_us=5 correlation_p95_us=15 correlation_p99_us=20 correlation_max_us=25 correlation_retained=3 correlation_capacity=4096 correlation_dropped=0 correlation_retention_enabled=true correlation_overflowed=false correlation_percentiles_valid=true',
    'graphics trace:',
    'epoch=1 lifecycle=1 source=legacy scanout_generation=1 result=presented mode=640x480/text descriptor_copy=1/1ns',
    'exit stats: None=1 Failed=0'
) -join "`n"

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $runRoot = Join-Path $testRoot 'run'
    $profileRoot = Join-Path $runRoot 'synthetic-state'
    $inputsRoot = Join-Path $runRoot 'inputs'
    New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $inputsRoot -Force | Out-Null
    $emptyLogPath = Join-Path $runRoot 'empty.log'
    $emptyLogBytes = [Text.UTF8Encoding]::new($false).GetBytes('')
    Write-TestControlNewBytes -Path $emptyLogPath -Bytes $emptyLogBytes
    Assert-True ((Test-Path -LiteralPath $emptyLogPath -PathType Leaf) -and
        (Get-Item -LiteralPath $emptyLogPath).Length -eq 0) `
        'An empty redirected stream must be retained as a zero-byte evidence file.'
    $imagePath = Join-Path $profileRoot 'c_drive.img'
    [IO.File]::WriteAllBytes($imagePath, [byte[]](1, 2, 3, 4))
    [IO.File]::WriteAllBytes((Join-Path $profileRoot 'cmos.bin'), [byte[]](5, 6))
    Write-TestUtf8 -Path (Join-Path $profileRoot 'install-state.json') -Text '{}'
    $settings = [ordered]@{
        version = 3
        cpu_mode = 'GSW-886'
        hard_drive_path = $imagePath
        floppy_path = ''
        cdrom_path = ''
    }
    Write-TestUtf8 -Path (Join-Path $profileRoot 'settings.json') `
        -Text ($settings | ConvertTo-Json)

    $child = Join-Path $inputsRoot 'control.input'
    Write-TestUtf8 -Path $child -Text "wait 100`nkey ctrl-escape`n"
    Assert-True ((Assert-TestControlContainedPath -Root $runRoot -Path $child `
        -Name 'child') -ceq [IO.Path]::GetFullPath($child)) `
        'A contained ordinary child path should resolve exactly.'
    Assert-Throws {
        Assert-TestControlContainedPath -Root $runRoot `
            -Path (Join-Path $testRoot 'outside.input') -Name 'outside'
    } 'must remain inside' 'A path outside the run root must fail closed.'
    Assert-Throws {
        Assert-TestControlContainedPath -Root $runRoot `
            -Path (Join-Path $runRoot 'unsafe.\child') -Name 'unsafe'
    } 'unsafe path segment' 'A trailing-dot path alias must fail closed.'
    Assert-True ((Assert-TestControlAbsentLeaf -Root $runRoot `
        -Path (Join-Path $runRoot 'evidence') -Name 'evidence') -like '*evidence') `
        'An absent contained evidence leaf should pass preflight.'
    New-Item -ItemType Directory -Path (Join-Path $runRoot 'existing') | Out-Null
    Assert-Throws {
        Assert-TestControlAbsentLeaf -Root $runRoot `
            -Path (Join-Path $runRoot 'existing') -Name 'evidence'
    } 'must be absent' 'An existing evidence directory must fail closed.'
    Assert-Throws {
        Assert-TestControlOrdinaryPath -Path $inputsRoot -Name 'input' -Kind File
    } 'ordinary file' 'A directory must not pass as an ordinary input file.'

    $held = Open-TestControlHeldFile -Path $child -Name 'held input' -MaximumBytes 1024
    try {
        Assert-True ($held.Sha256 -ceq (
            Get-FileHash -LiteralPath $child -Algorithm SHA256
        ).Hash.ToLowerInvariant()) 'The held input hash must match its exact bytes.'
        Assert-TestControlHeldFileUnchanged -Held $held
        Assert-True $true 'An unchanged held input should revalidate.'
    }
    finally {
        $held.Stream.Dispose()
    }

    $validPlanText = New-CapturePlanText -Captures @(
        [ordered]@{ id = 'before'; after_ms = 100; deadline_ms = 500 },
        [ordered]@{ id = 'after'; after_ms = 600; deadline_ms = 900 }
    )
    $validPlan = @(ConvertFrom-TestControlCapturePlan `
        -Bytes (ConvertTo-TestBytes $validPlanText) -AutoCloseMilliseconds 1000)
    Assert-True ($validPlan.Count -eq 2 -and $validPlan[1].Id -ceq 'after') `
        'The exact bounded capture plan should parse.'
    Assert-Throws {
        ConvertFrom-TestControlCapturePlan -Bytes (ConvertTo-TestBytes (
            '{"_spdx":"GPL-3.0-only","schema":1,"captures":[]}'
        )) -AutoCloseMilliseconds 1000
    } 'between 1 and 16' 'An empty capture plan must fail closed.'
    Assert-Throws {
        ConvertFrom-TestControlCapturePlan -Bytes (ConvertTo-TestBytes (
            '{"_spdx":"GPL-3.0-only","schema":1,"extra":0,"captures":[]}'
        )) -AutoCloseMilliseconds 1000
    } 'fields do not match' 'An extra capture-plan field must fail closed.'
    Assert-Throws {
        ConvertFrom-TestControlCapturePlan -Bytes (ConvertTo-TestBytes (
            (New-CapturePlanText -Captures @(
                [ordered]@{ id = 'one'; after_ms = 100; deadline_ms = 700 },
                [ordered]@{ id = 'two'; after_ms = 600; deadline_ms = 900 }
            ))
        )) -AutoCloseMilliseconds 1000
    } 'ordered and nonoverlapping' 'Overlapping capture windows must fail closed.'
    Assert-Throws {
        ConvertFrom-TestControlCapturePlan -Bytes (ConvertTo-TestBytes (
            (New-CapturePlanText -Captures @(
                [ordered]@{ id = '../escape'; after_ms = 100; deadline_ms = 500 }
            ))
        )) -AutoCloseMilliseconds 1000
    } 'unique lowercase' 'Unsafe capture identifiers must fail closed.'
    Assert-Throws {
        ConvertFrom-TestControlCapturePlan -Bytes (ConvertTo-TestBytes (
            (New-CapturePlanText -Captures @(
                [ordered]@{ id = 'late'; after_ms = 900; deadline_ms = 1100 }
            ))
        )) -AutoCloseMilliseconds 1000
    } 'outside the bounded host lifetime' 'A late capture deadline must fail closed.'
    Assert-Throws {
        ConvertFrom-TestControlCapturePlan -Bytes (ConvertTo-TestBytes (
            '{"_spdx":"GPL-3.0-only","schema":1,"schema":1,"captures":[]}'
        )) -AutoCloseMilliseconds 1000
    } 'Duplicate JSON property' 'Duplicate capture-plan fields must fail closed.'

    $telemetry = Assert-TestControlTelemetry -Stdout $validControl
    Assert-True ($telemetry.TraceLines -eq 1 -and
        $telemetry.NumericFields.applied -eq 4 -and
        $telemetry.ExitFields.Failed -eq 0) `
        'The exact 26-field telemetry and trace should validate.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace ' pending=0', '')
    } 'exactly 26 fields' 'A missing telemetry field must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            ' correlation_percentiles_valid=true',
            ' correlation_percentiles_valid=true extra=0'
        ))
    } 'exactly 26 fields' 'An extra telemetry field must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl + "`n" + (
            $validControl -split "`n"
        )[0])
    } 'exactly one control input' 'Duplicate telemetry summaries must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace 'success=true', 'success=false')
    } 'complete success' 'A failed control summary must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace 'state=Completed', 'state=Complete')
    } 'complete success' 'The non-emitted Complete state spelling must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace 'actions=4', 'actions=3')
    } 'incomplete or inconsistent' 'An action-to-event accounting mismatch must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            'correlation_capacity=4096',
            'correlation_capacity=4095'
        ))
    } 'incomplete or inconsistent' 'A drifted correlation capacity must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            'correlation_avg_us=10',
            'correlation_avg_us=26'
        ))
    } 'latency summary is inconsistent' `
        'An average above the maximum retained latency must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            'applied=4 stale_dropped=0',
            'applied=4 stale_dropped=1'
        ))
    } 'incomplete or inconsistent' 'Stale input accounting must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            'result=presented',
            'result=present-failed'
        ))
    } 'failed result' 'A failed graphics trace epoch must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            'result=presented',
            'result=bogus'
        ))
    } 'unsupported result' 'A bogus graphics trace result must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            'result=presented',
            'result=unknown'
        ))
    } 'unsupported result' 'An unknown graphics trace result must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            'result=presented',
            'result=Presented'
        ))
    } 'unsupported result' 'A case-drifted graphics trace result must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace (
            "graphics trace:`n.*`nexit stats:",
            "graphics trace:`nexit stats:"
        ))
    } 'graphics trace is empty' 'An empty graphics trace must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl -replace 'Failed=0', 'Failed=1')
    } 'Failed=0' 'Nonzero Failed exit stats must fail closed.'
    Assert-Throws {
        Assert-TestControlTelemetry -Stdout ($validControl + "`nunexpected")
    } 'final stdout evidence' 'Output after exit stats must fail closed.'

    $postmortemBytes = ConvertTo-TestBytes (New-PostmortemText -ProcessId 4321)
    $postmortem = Assert-TestControlPostmortem -Bytes $postmortemBytes -ProcessId 4321
    Assert-True ($postmortem.Revision -eq 9 -and
        $postmortem.Session -ceq 'gui-4321-123456') `
        'A fresh PID-bound postmortem should validate.'
    Assert-Throws {
        Assert-TestControlPostmortem -Bytes $postmortemBytes -ProcessId 4322
    } 'launched GUI PID' 'A postmortem from another PID must fail closed.'
    Assert-Throws {
        Assert-TestControlPostmortem -Bytes (ConvertTo-TestBytes (
            New-PostmortemText -ProcessId 4321 -Session 'gui-4321-%!d(Tick=bad)'
        )) -ProcessId 4321
    } 'launched GUI PID' 'A formatted Tick diagnostic session must fail closed.'
    Assert-Throws {
        Assert-TestControlPostmortem -Bytes (ConvertTo-TestBytes (
            New-PostmortemText -ProcessId 4321 -Revision 0
        )) -ProcessId 4321
    } 'schema or revision' 'A zero postmortem revision must fail closed.'
    Assert-Throws {
        Assert-TestControlPostmortem -Bytes (ConvertTo-TestBytes (
            New-PostmortemText -ProcessId 4321 -Stage 'failed'
        )) -ProcessId 4321
    } 'complete host stage' 'A failed postmortem stage must fail closed.'
    $retainedRoot = Join-Path $runRoot 'synthetic-evidence'
    New-Item -ItemType Directory -Path $retainedRoot | Out-Null
    $retained = Save-TestControlValidatedPostmortem -Bytes $postmortemBytes `
        -ProcessId 4321 -EvidenceRoot $retainedRoot
    Assert-True ((Test-Path -LiteralPath $retained.Path -PathType Leaf) -and
        $retained.Sha256 -ceq (Get-GswSha256Hex -Bytes $postmortemBytes) -and
        [IO.File]::ReadAllBytes($retained.Path).Length -eq $postmortemBytes.Length) `
        'The exact validated PID-bound postmortem bytes and hash must be retained.'

    $binding = Assert-TestControlProfileBinding -RunRoot $runRoot `
        -ProfileRoot $profileRoot
    Assert-True ($binding.ImagePath -ceq [IO.Path]::GetFullPath($imagePath)) `
        'Synthetic Profile settings should bind to their contained image.'
    $inventoryBefore = @(Get-TestControlFileInventory -Root $profileRoot `
        -Name 'synthetic state')
    $inventorySame = @(Get-TestControlFileInventory -Root $profileRoot `
        -Name 'synthetic state')
    Assert-TestControlInventoryEqual -Expected $inventoryBefore -Actual $inventorySame `
        -Name 'synthetic state'
    Assert-True $true 'An unchanged pre-launch inventory should revalidate.'
    [IO.File]::WriteAllBytes($imagePath, [byte[]](1, 2, 3, 5))
    $inventoryChanged = @(Get-TestControlFileInventory -Root $profileRoot `
        -Name 'synthetic state')
    Assert-Throws {
        Assert-TestControlInventoryEqual -Expected $inventoryBefore `
            -Actual $inventoryChanged -Name 'synthetic state'
    } 'inventory changed' 'A pre-launch state hash mutation must fail closed.'
    [IO.File]::WriteAllBytes($imagePath, [byte[]](1, 2, 3, 4))
    $outsideImage = Join-Path $runRoot 'outside.img'
    [IO.File]::WriteAllBytes($outsideImage, [byte[]](7, 8))
    $settings.hard_drive_path = $outsideImage
    Write-TestUtf8 -Path (Join-Path $profileRoot 'settings.json') `
        -Text ($settings | ConvertTo-Json)
    Assert-Throws {
        Assert-TestControlProfileBinding -RunRoot $runRoot -ProfileRoot $profileRoot
    } 'not bound' 'A Profile bound to a different image must fail closed.'
    $settings.hard_drive_path = $imagePath
    Write-TestUtf8 -Path (Join-Path $profileRoot 'settings.json') `
        -Text ($settings | ConvertTo-Json)
    Write-TestUtf8 -Path (Join-Path $profileRoot '.profile.lock') -Text '1'
    Assert-Throws {
        Assert-TestControlProfileBinding -RunRoot $runRoot -ProfileRoot $profileRoot
    } 'exactly its four' 'A Profile lock must fail the fresh inventory.'
    Remove-Item -LiteralPath (Join-Path $profileRoot '.profile.lock') -Force
    New-Item -ItemType Directory `
        -Path (Join-Path $profileRoot '.c_drive.img.retvrn99-fat32') | Out-Null
    Assert-Throws {
        Assert-TestControlProfileBinding -RunRoot $runRoot -ProfileRoot $profileRoot
    } 'exactly its four' 'A FAT32 companion must fail the fresh inventory.'
    Remove-Item -LiteralPath (Join-Path $profileRoot '.c_drive.img.retvrn99-fat32')

    $tokens = $null
    $parseErrors = $null
    $runnerAst = [Management.Automation.Language.Parser]::ParseFile(
        $runner,
        [ref]$tokens,
        [ref]$parseErrors
    )
    Assert-True (@($parseErrors).Count -eq 0) 'The evidence runner must parse without errors.'
    $commands = @($runnerAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetCommandName() })
    Assert-True ('Start-Process' -notin $commands -and
        'Stop-Process' -notin $commands -and 'taskkill' -notin $commands) `
        'The runner must not use shell launch or forced process termination.'
    $runnerText = Get-Content -Raw -LiteralPath $runner
    Assert-True ($runnerText.Contains('ProcessStartInfo') -and
        $runnerText.Contains('.ArgumentList.Add(') -and
        $runnerText.Contains('PrintWindow') -and
        $runnerText.Contains('CloseMainWindow')) `
        'The runner must retain safe argument, PrintWindow, and graceful-close seams.'
    Assert-True (-not $runnerText.Contains('ReadToEndAsync') -and
        $runnerText.Contains('stdout-timeline.json') -and
        $runnerText.Contains('16777216') -and $runnerText.Contains('1048576') -and
        $runnerText.Contains('throw $logs.CollectionFailure')) `
        'The runner must wire bounded fail-closed stdout timeline collection.'
    foreach ($name in @(
        'Initialize-TestControlOutputCollector',
        'Assert-TestControlStdoutTimelineBinding',
        'Write-TestControlLogsIfComplete'
    )) {
        $functionAst = $runnerAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $name
        }, $true)
        Assert-True ($null -ne $functionAst) "The runner must define $name."
        Invoke-Expression $functionAst.Extent.Text
    }
    Initialize-TestControlOutputCollector
    Assert-True ($null -ne ('Retvrn99.TestControlOutput.BoundedUtf8LineCollector' -as [type])) `
        'The bounded UTF-8 line collector must compile.'

    $passEvidence = Join-Path $runRoot 'output-evidence-pass'
    New-Item -ItemType Directory -Path $passEvidence | Out-Null
    $passChild = Start-TestOutputChild -StdoutMaximumBytes 16777216 `
        -StderrMaximumBytes 1048576 -Script @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.WriteLine('first')
[Console]::Out.Flush()
Start-Sleep -Milliseconds 300
[Console]::Out.WriteLine('')
[Console]::Out.Flush()
Start-Sleep -Milliseconds 300
[Console]::Out.WriteLine('café Ω')
[Console]::Out.Flush()
Start-Sleep -Milliseconds 300
[Console]::Out.Write('last')
[Console]::Out.Flush()
'@
    try {
        $deliveryWait = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 10
            $earlySnapshot = $passChild.Stdout.Snapshot()
        } while ($earlySnapshot.Lines.Count -eq 0 -and $deliveryWait.ElapsedMilliseconds -lt 2000)
        Assert-True ($earlySnapshot.Lines.Count -eq 1 -and -not $passChild.Process.HasExited) `
            'A flushed first line must be delivered before the synthetic child exits.'
        Assert-True ([object]::ReferenceEquals($passChild.Clock, $passChild.Stdout.Clock)) `
            'The stdout collector must use the exact capture Stopwatch instance.'
        Wait-TestOutputChild -Child $passChild
        $passLogs = Write-TestControlLogsIfComplete -Process $passChild.Process `
            -StdoutCollector $passChild.Stdout -StderrCollector $passChild.Stderr `
            -EvidenceRoot $passEvidence
        $expectedStdout = ConvertTo-TestBytes "first`n`ncafé Ω`nlast`n"
        $actualStdout = [IO.File]::ReadAllBytes((Join-Path $passEvidence 'stdout.log'))
        Assert-True ($passLogs.CollectionFailure -ceq '' -and
            $passLogs.StderrBytes -eq 0 -and
            ([BitConverter]::ToString($actualStdout) -ceq
                [BitConverter]::ToString($expectedStdout))) `
            'Passing output evidence must retain the exact normalized LF UTF-8 bytes.'
        $passTimeline = Get-Content -Raw -LiteralPath `
            (Join-Path $passEvidence 'stdout-timeline.json') | ConvertFrom-Json
        Assert-GswJsonExactProperties -Value $passTimeline `
            -Expected @('_spdx', 'schema', 'lines') -Label 'stdout timeline'
        $expectedLines = @('first', '', 'café Ω', 'last')
        $timelineValid = [Int64]$passTimeline.schema -eq 1 -and
            @($passTimeline.lines).Count -eq $expectedLines.Count
        for ($index = 0; $timelineValid -and $index -lt $expectedLines.Count; $index += 1) {
            $record = $passTimeline.lines[$index]
            Assert-GswJsonExactProperties -Value $record `
                -Expected @('line_index', 'received_ms', 'utf8_bytes', 'sha256') `
                -Label "stdout timeline.lines[$index]"
            $lineBytes = ConvertTo-TestBytes $expectedLines[$index]
            $timelineValid = [UInt64]$record.line_index -eq [UInt64]$index -and
                [UInt64]$record.utf8_bytes -eq [UInt64]$lineBytes.Length -and
                [string]$record.sha256 -ceq (Get-GswSha256Hex -Bytes $lineBytes)
            if ($index -gt 0) {
                $timelineValid = $timelineValid -and
                    [UInt64]$record.received_ms -ge
                        [UInt64]$passTimeline.lines[$index - 1].received_ms
            }
        }
        Assert-True $timelineValid `
            'Timeline indexes, UTF-8 sizes, hashes, and receipt times must bind to stdout.log.'
        Assert-Throws {
            Assert-TestControlStdoutTimelineBinding `
                -Bytes (ConvertTo-TestBytes "fIrst`n`ncafé Ω`nlast`n") `
                -Lines @($passChild.Stdout.Snapshot().Lines)
        } 'binding failed' 'A stdout byte mutation must fail timeline binding.'
        Assert-True (
            [UInt64]$passTimeline.lines[1].received_ms -
                [UInt64]$passTimeline.lines[0].received_ms -ge 150 -and
            [UInt64]$passTimeline.lines[2].received_ms -
                [UInt64]$passTimeline.lines[1].received_ms -ge 150
        ) 'Separated flushed lines must retain independent receipt timestamps.'
        Assert-True ((Get-Item -LiteralPath (Join-Path $passEvidence 'stdout.log')).Length -gt 0 -and
            (Get-Item -LiteralPath (Join-Path $passEvidence 'stderr.log')).Length -eq 0 -and
            (Get-Item -LiteralPath (Join-Path $passEvidence 'stdout-timeline.json')).Length -gt 0) `
            'Passing output artifacts must remain available after collection.'
    }
    finally {
        if (-not $passChild.Process.HasExited) { Wait-TestOutputChild -Child $passChild }
        $passChild.Process.Dispose()
    }

    $overflowEvidence = Join-Path $runRoot 'output-evidence-overflow'
    New-Item -ItemType Directory -Path $overflowEvidence | Out-Null
    $overflowChild = Start-TestOutputChild -StdoutMaximumBytes 16 `
        -StderrMaximumBytes 1024 -Script @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.WriteLine('kept')
[Console]::Out.Flush()
[Console]::Out.WriteLine(('x' * 80))
[Console]::Out.Flush()
[Console]::Out.WriteLine('drained-tail')
[Console]::Out.Flush()
'@
    try {
        Wait-TestOutputChild -Child $overflowChild
        $overflowLogs = Write-TestControlLogsIfComplete -Process $overflowChild.Process `
            -StdoutCollector $overflowChild.Stdout -StderrCollector $overflowChild.Stderr `
            -EvidenceRoot $overflowEvidence
        $overflowSnapshot = $overflowChild.Stdout.Snapshot()
        Assert-True ($overflowSnapshot.Completed -and $overflowSnapshot.Overflowed -and
            $overflowLogs.CollectionFailure -match 'stdout exceeded') `
            'Overflow must fail closed only after the stdout stream drains completely.'
        Assert-Throws {
            throw $overflowLogs.CollectionFailure
        } 'stdout exceeded' 'The runner must reject bounded stdout overflow.'
        $partialStdout = [Text.UTF8Encoding]::new($false, $true).GetString(
            [IO.File]::ReadAllBytes((Join-Path $overflowEvidence 'stdout.log'))
        )
        $partialTimeline = Get-Content -Raw -LiteralPath `
            (Join-Path $overflowEvidence 'stdout-timeline.json') | ConvertFrom-Json
        Assert-True ($partialStdout -ceq "kept`n" -and
            @($partialTimeline.lines).Count -eq 1 -and
            [UInt64]$partialTimeline.lines[0].line_index -eq 0) `
            'Overflow failure must retain complete, timeline-bound partial stdout evidence.'
    }
    finally {
        if (-not $overflowChild.Process.HasExited) { Wait-TestOutputChild -Child $overflowChild }
        $overflowChild.Process.Dispose()
    }

    $stderrEvidence = Join-Path $runRoot 'output-evidence-stderr-overflow'
    New-Item -ItemType Directory -Path $stderrEvidence | Out-Null
    $stderrChild = Start-TestOutputChild -StdoutMaximumBytes 1024 `
        -StderrMaximumBytes 16 -Script @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Error.WriteLine(('e' * 80))
[Console]::Error.Flush()
[Console]::Out.WriteLine('stdout-survives')
[Console]::Out.Flush()
'@
    try {
        Wait-TestOutputChild -Child $stderrChild
        $stderrLogs = Write-TestControlLogsIfComplete -Process $stderrChild.Process `
            -StdoutCollector $stderrChild.Stdout -StderrCollector $stderrChild.Stderr `
            -EvidenceRoot $stderrEvidence
        Assert-True ($stderrLogs.CollectionFailure -match 'stderr exceeded' -and
            (Test-Path -LiteralPath (Join-Path $stderrEvidence 'stderr.log')) -and
            (Test-Path -LiteralPath (Join-Path $stderrEvidence 'stdout.log')) -and
            (Test-Path -LiteralPath (Join-Path $stderrEvidence 'stdout-timeline.json'))) `
            'Bounded stderr failure must retain all available output evidence.'
    }
    finally {
        if (-not $stderrChild.Process.HasExited) { Wait-TestOutputChild -Child $stderrChild }
        $stderrChild.Process.Dispose()
    }

    $captureSource = [regex]::Match(
        $runnerText,
        "(?s)-TypeDefinition @'\r?\n(.*?)\r?\n'@"
    )
    Assert-True $captureSource.Success 'The bounded PrintWindow source must be discoverable.'
    try {
        Add-Type -AssemblyName System.Drawing.Common -ErrorAction Stop
    }
    catch {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    $drawingAssembly = [Drawing.Bitmap].Assembly
    $captureAssemblies = @($drawingAssembly.Location)
    foreach ($reference in $drawingAssembly.GetReferencedAssemblies()) {
        $location = [Reflection.Assembly]::Load($reference).Location
        if (-not [string]::IsNullOrEmpty($location)) { $captureAssemblies += $location }
    }
    Add-Type -ReferencedAssemblies @($captureAssemblies | Sort-Object -Unique) `
        -TypeDefinition $captureSource.Groups[1].Value -ErrorAction Stop
    Assert-True ($null -ne ('Retvrn99.TestControlCapture.Native' -as [type])) `
        'The bounded PrintWindow source must compile without launching a window.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $runRoot 'evidence'))) `
        'Pure tests must not create or launch a live evidence run.'

    Write-Output "PASS run-test-control-evidence tests=$script:tests"
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot `
        'dev\test-control-evidence-tests'))
    if ($resolvedTestRoot.StartsWith(
        $resolvedParent + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

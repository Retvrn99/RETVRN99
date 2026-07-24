# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'strict-json.ps1')

$script:TestControlTelemetryFields = @(
    'state',
    'failure',
    'success',
    'actions',
    'queued',
    'applied',
    'stale_dropped',
    'reset_cancelled',
    'resolved',
    'unresolved',
    'over_resolved',
    'pending',
    'correlated_events',
    'correlated_presentations',
    'correlation_success',
    'correlation_avg_us',
    'correlation_p50_us',
    'correlation_p95_us',
    'correlation_p99_us',
    'correlation_max_us',
    'correlation_retained',
    'correlation_capacity',
    'correlation_dropped',
    'correlation_retention_enabled',
    'correlation_overflowed',
    'correlation_percentiles_valid'
)

$script:TestControlSuccessfulTraceResults = @(
    'presented',
    'superseded',
    'coalesced',
    'gpu-work',
    'reset'
)

$script:TestControlProfileFiles = @(
    'c_drive.img',
    'cmos.bin',
    'install-state.json',
    'settings.json'
)

function Get-TestControlPathComparison {
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}

function Get-TestControlFullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) {
        throw "$Name is empty or invalid."
    }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Name must be fully qualified."
    }
    try {
        $pathRoot = [IO.Path]::GetPathRoot($Path)
        $remainder = $Path.Substring($pathRoot.Length)
        foreach ($segment in $remainder -split '[\\/]') {
            if ($segment.Length -eq 0) { continue }
            if ($segment -eq '.' -or $segment -eq '..' -or
                $segment.EndsWith(' ') -or $segment.EndsWith('.') -or
                $segment.Contains(':')) {
                throw "$Name contains an unsafe path segment."
            }
        }
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch {
        if ($_.Exception.Message -like "$Name contains an unsafe path segment.*") {
            throw
        }
        throw "$Name is not a valid path."
    }
    return $fullPath
}

function Assert-TestControlContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowRoot
    )

    $fullRoot = Get-TestControlFullPath -Path $Root -Name 'run root'
    $fullPath = Get-TestControlFullPath -Path $Path -Name $Name
    $relative = [IO.Path]::GetRelativePath($fullRoot, $fullPath)
    if ([IO.Path]::IsPathRooted($relative) -or
        $relative -eq '..' -or
        $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar) -or
        $relative.StartsWith('..' + [IO.Path]::AltDirectorySeparatorChar)) {
        throw "$Name must remain inside the run root."
    }
    if (-not $AllowRoot -and ($relative -eq '.' -or $relative.Length -eq 0)) {
        throw "$Name must be a child of the run root."
    }
    foreach ($segment in $relative -split '[\\/]') {
        if ($segment.Length -eq 0 -or $segment -eq '.' -or $segment -eq '..' -or
            $segment.EndsWith(' ') -or $segment.EndsWith('.') -or
            $segment.Contains(':')) {
            throw "$Name contains an unsafe path segment."
        }
    }
    return $fullPath
}

function Assert-TestControlOrdinaryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('File', 'Directory')][string]$Kind
    )

    $fullPath = Get-TestControlFullPath -Path $Path -Name $Name
    Assert-GswNoReparseAncestor -Path $fullPath -Name $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    $isDirectory = ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0 -or
        ($Kind -eq 'File' -and $isDirectory) -or
        ($Kind -eq 'Directory' -and -not $isDirectory)) {
        throw "$Name must be one ordinary $($Kind.ToLowerInvariant())."
    }
    return $item
}

function Assert-TestControlAbsentLeaf {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $fullPath = Assert-TestControlContainedPath -Root $Root -Path $Path -Name $Name
    if (Test-Path -LiteralPath $fullPath) {
        throw "$Name must be absent."
    }
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    $null = Assert-TestControlOrdinaryPath -Path $parent -Name "$Name parent" -Kind Directory
    return $fullPath
}

function Assert-TestControlOrdinaryTree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $rootItem = Assert-TestControlOrdinaryPath -Path $Root -Name $Name -Kind Directory
    foreach ($item in Get-ChildItem -LiteralPath $rootItem.FullName -Force -Recurse) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "$Name contains a nonordinary path '$($item.FullName)'."
        }
    }
}

function Open-TestControlHeldFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][UInt64]$MaximumBytes
    )

    if ($MaximumBytes -eq 0 -or $MaximumBytes -gt [int]::MaxValue) {
        throw "$Name has an invalid byte bound."
    }
    $item = Assert-TestControlOrdinaryPath -Path $Path -Name $Name -Kind File
    if ($item.Length -le 0 -or [UInt64]$item.Length -gt $MaximumBytes) {
        throw "$Name must contain between 1 and $MaximumBytes bytes."
    }
    $stream = [IO.File]::Open(
        $item.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ([UInt64]$stream.Length -ne [UInt64]$item.Length) {
            throw "$Name changed while it was opened."
        }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$Name ended during its held read." }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw "$Name grew during its held read." }
        $hash = Get-GswSha256Hex -Bytes $bytes
        $stream.Position = 0
        $after = Assert-TestControlOrdinaryPath -Path $item.FullName -Name $Name -Kind File
        Assert-GswStableFileIdentity -Before $item -After $after -Name $Name
    }
    catch {
        $stream.Dispose()
        throw
    }
    return [pscustomobject]@{
        Path = $item.FullName
        Stream = $stream
        Bytes = $bytes
        Length = [UInt64]$bytes.Length
        Sha256 = $hash
        InitialItem = $item
        Name = $Name
    }
}

function Assert-TestControlHeldFileUnchanged {
    param([Parameter(Mandatory = $true)][object]$Held)

    if ($Held.Stream.Position -ne 0) { $Held.Stream.Position = 0 }
    $heldHash = Get-GswBoundedStreamSha256Hex -Stream $Held.Stream `
        -ExpectedLength $Held.Length -Name $Held.Name
    $Held.Stream.Position = 0
    $item = Assert-TestControlOrdinaryPath -Path $Held.Path -Name $Held.Name -Kind File
    Assert-GswStableFileIdentity -Before $Held.InitialItem -After $item -Name $Held.Name
    if ($heldHash -cne $Held.Sha256) {
        throw "$($Held.Name) changed through its held handle."
    }
    $snapshot = Read-GswBoundedFileSnapshot -Path $Held.Path -Name $Held.Name `
        -MaximumBytes $Held.Length
    if ($snapshot.Sha256 -cne $Held.Sha256 -or $snapshot.Length -ne $Held.Length) {
        throw "$($Held.Name) path no longer resolves to the held bytes."
    }
}

function ConvertFrom-TestControlCapturePlan {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][UInt64]$AutoCloseMilliseconds
    )

    $text = ConvertFrom-GswStrictUtf8Bytes -Bytes $Bytes -Source 'capture plan'
    $plan = ConvertFrom-GswStrictJson -Json $text -Source 'capture plan'
    Assert-GswJsonExactProperties -Value $plan `
        -Expected @('_spdx', 'schema', 'captures') -Label 'capture plan'
    Assert-GswJsonString -Value $plan._spdx -Label 'capture plan._spdx'
    Assert-GswJsonInteger -Value $plan.schema -Label 'capture plan.schema'
    Assert-GswJsonArray -Value $plan.captures -Label 'capture plan.captures'
    if ([string]$plan._spdx -cne 'GPL-3.0-only' -or [Int64]$plan.schema -ne 1) {
        throw 'The capture plan identity is unsupported.'
    }
    $captures = @($plan.captures)
    if ($captures.Count -lt 1 -or $captures.Count -gt 16) {
        throw 'The capture plan must contain between 1 and 16 captures.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $result = @()
    [UInt64]$previousDeadline = 0
    for ($index = 0; $index -lt $captures.Count; $index += 1) {
        $capture = $captures[$index]
        $label = "capture plan.captures[$index]"
        Assert-GswJsonExactProperties -Value $capture `
            -Expected @('id', 'after_ms', 'deadline_ms') -Label $label
        Assert-GswJsonString -Value $capture.id -Label "$label.id"
        Assert-GswJsonInteger -Value $capture.after_ms -Label "$label.after_ms"
        Assert-GswJsonInteger -Value $capture.deadline_ms -Label "$label.deadline_ms"
        $id = [string]$capture.id
        [UInt64]$after = [UInt64]$capture.after_ms
        [UInt64]$deadline = [UInt64]$capture.deadline_ms
        if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{0,47}$' -or -not $ids.Add($id)) {
            throw "$label.id must be a unique lowercase evidence identifier."
        }
        if ($after -lt 100 -or $deadline -le $after -or
            $deadline -gt $AutoCloseMilliseconds) {
            throw "$label timing is outside the bounded host lifetime."
        }
        if ($index -gt 0 -and $after -lt $previousDeadline) {
            throw 'Capture timing windows must be ordered and nonoverlapping.'
        }
        $previousDeadline = $deadline
        $result += [pscustomobject]@{
            Id = $id
            AfterMilliseconds = $after
            DeadlineMilliseconds = $deadline
        }
    }
    return $result
}

function ConvertTo-TestControlUnsigned {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -cnotmatch '^(0|[1-9][0-9]*)$') {
        throw "$Name must be an unsigned decimal integer."
    }
    [UInt64]$result = 0
    if (-not [UInt64]::TryParse(
        $Value,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$result
    )) {
        throw "$Name exceeds the unsigned integer bound."
    }
    return $result
}

function Test-TestControlBooleanText {
    param([string]$Value)
    return $Value -ceq 'true' -or $Value -ceq 'false'
}

function Assert-TestControlTelemetry {
    param([Parameter(Mandatory = $true)][string]$Stdout)

    $lines = @($Stdout -split "`r?`n")
    $controlIndexes = @()
    $traceIndexes = @()
    $exitIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index += 1) {
        if ($lines[$index].StartsWith('control input:', [StringComparison]::Ordinal)) {
            $controlIndexes += $index
        }
        if ($lines[$index] -ceq 'graphics trace:') { $traceIndexes += $index }
        if ($lines[$index].StartsWith('exit stats:', [StringComparison]::Ordinal)) {
            $exitIndexes += $index
        }
    }
    if ($controlIndexes.Count -ne 1) {
        throw 'stdout must contain exactly one control input summary.'
    }
    if ($traceIndexes.Count -ne 1 -or $exitIndexes.Count -ne 1) {
        throw 'stdout must contain exactly one graphics trace and exit stats block.'
    }
    $controlIndex = $controlIndexes[0]
    $traceIndex = $traceIndexes[0]
    $exitIndex = $exitIndexes[0]
    if ($controlIndex -ge $traceIndex -or $traceIndex -ge $exitIndex) {
        throw 'stdout evidence blocks are out of order.'
    }

    $payload = $lines[$controlIndex].Substring('control input:'.Length).Trim()
    $tokens = @($payload -split ' ' | Where-Object { $_.Length -gt 0 })
    if ($tokens.Count -ne $script:TestControlTelemetryFields.Count) {
        throw 'The control input summary must contain exactly 26 fields.'
    }
    $fields = [ordered]@{}
    for ($index = 0; $index -lt $tokens.Count; $index += 1) {
        if ($tokens[$index] -cnotmatch '^([^=]+)=([^=\s]+)$') {
            throw "Malformed control input field '$($tokens[$index])'."
        }
        $name = $Matches[1]
        $value = $Matches[2]
        if ($name -cne $script:TestControlTelemetryFields[$index]) {
            throw 'The control input fields do not match the exact schema order.'
        }
        $fields[$name] = $value
    }
    if ($fields.state -cne 'Completed' -or $fields.failure -cne 'None' -or
        $fields.success -cne 'true' -or $fields.correlation_success -cne 'true') {
        throw 'The control input summary does not report complete success.'
    }
    foreach ($name in @(
        'success',
        'correlation_success',
        'correlation_retention_enabled',
        'correlation_overflowed',
        'correlation_percentiles_valid'
    )) {
        if (-not (Test-TestControlBooleanText $fields[$name])) {
            throw "control input $name is not an exact Boolean."
        }
    }
    $numbers = [ordered]@{}
    foreach ($name in $script:TestControlTelemetryFields) {
        if ($name -in @('state', 'failure', 'success', 'correlation_success',
            'correlation_retention_enabled', 'correlation_overflowed',
            'correlation_percentiles_valid')) {
            continue
        }
        $numbers[$name] = ConvertTo-TestControlUnsigned -Value $fields[$name] `
            -Name "control input $name"
    }
    if ($numbers.actions -eq 0 -or $numbers.actions -ne $numbers.queued -or
        $numbers.applied -ne $numbers.queued -or
        $numbers.resolved -ne $numbers.queued -or
        $numbers.stale_dropped -ne 0 -or $numbers.reset_cancelled -ne 0 -or
        $numbers.unresolved -ne 0 -or $numbers.over_resolved -ne 0 -or
        $numbers.pending -ne 0 -or
        $numbers.correlated_events -ne $numbers.applied -or
        $numbers.correlated_presentations -eq 0 -or
        $numbers.correlated_presentations -gt $numbers.correlated_events -or
        $numbers.correlation_retained -ne $numbers.correlated_presentations -or
        $numbers.correlation_capacity -ne 4096 -or
        $numbers.correlation_retained -gt $numbers.correlation_capacity -or
        $numbers.correlation_dropped -ne 0 -or
        $fields.correlation_retention_enabled -cne 'true' -or
        $fields.correlation_overflowed -cne 'false' -or
        $fields.correlation_percentiles_valid -cne 'true') {
        throw 'The control input accounting is incomplete or inconsistent.'
    }
    if ($numbers.correlation_avg_us -gt $numbers.correlation_max_us -or
        $numbers.correlation_p50_us -gt $numbers.correlation_p95_us -or
        $numbers.correlation_p95_us -gt $numbers.correlation_p99_us -or
        $numbers.correlation_p99_us -gt $numbers.correlation_max_us) {
        throw 'The control input latency summary is inconsistent.'
    }

    if ($exitIndex - $traceIndex -le 1) { throw 'The graphics trace is empty.' }
    $traceLines = @($lines[($traceIndex + 1)..($exitIndex - 1)] |
        Where-Object { $_.Length -gt 0 })
    if ($traceLines.Count -eq 0) { throw 'The graphics trace is empty.' }
    foreach ($line in $traceLines) {
        if ($line -cnotmatch '^epoch=[0-9]+ .+ result=([^ ]+) .+$') {
            throw 'The graphics trace contains a malformed epoch line.'
        }
        $traceResult = $Matches[1]
        if ($traceResult -cnotin $script:TestControlSuccessfulTraceResults) {
            if ($traceResult -ceq 'incomplete' -or $traceResult.EndsWith('-failed')) {
                throw "The graphics trace contains failed result '$traceResult'."
            }
            throw "The graphics trace contains unsupported result '$traceResult'."
        }
    }

    $exitPayload = $lines[$exitIndex].Substring('exit stats:'.Length).Trim()
    $exitTokens = @($exitPayload -split ' ' | Where-Object { $_.Length -gt 0 })
    if ($exitTokens.Count -eq 0) { throw 'The exit stats record is empty.' }
    $exitFields = [ordered]@{}
    foreach ($token in $exitTokens) {
        if ($token -cnotmatch '^([^=\s]+)=([^=\s]+)$') {
            throw "Malformed exit stats field '$token'."
        }
        if ($exitFields.Contains($Matches[1])) {
            throw "Duplicate exit stats field '$($Matches[1])'."
        }
        $exitFields[$Matches[1]] = ConvertTo-TestControlUnsigned `
            -Value $Matches[2] -Name "exit stats $($Matches[1])"
    }
    if (-not $exitFields.Contains('Failed') -or $exitFields.Failed -ne 0) {
        throw 'The exit stats record must contain Failed=0.'
    }
    for ($index = $exitIndex + 1; $index -lt $lines.Count; $index += 1) {
        if (-not [string]::IsNullOrWhiteSpace($lines[$index])) {
            throw 'The exit stats record must be the final stdout evidence.'
        }
    }
    return [pscustomobject]@{
        Fields = [pscustomobject]$fields
        NumericFields = [pscustomobject]$numbers
        TraceLines = [UInt64]$traceLines.Count
        ExitFields = [pscustomobject]$exitFields
    }
}

function Assert-TestControlPostmortem {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    $text = ConvertFrom-GswStrictUtf8Bytes -Bytes $Bytes -Source 'graphics postmortem'
    $value = ConvertFrom-GswStrictJson -Json $text -Source 'graphics postmortem'
    $topFields = @(
        'schema',
        'revision',
        'session',
        'device',
        'session_generation',
        'guest_device_generation',
        'host_device_generation',
        'frame_generation',
        'host_stage',
        'window',
        'window_frame_generation',
        'vm',
        'vm_frame_generation'
    )
    Assert-GswJsonExactProperties -Value $value -Expected $topFields `
        -Label 'graphics postmortem'
    Assert-GswJsonInteger -Value $value.schema -Label 'graphics postmortem.schema'
    Assert-GswJsonInteger -Value $value.revision -Label 'graphics postmortem.revision'
    if ([Int64]$value.schema -ne 2 -or [UInt64]$value.revision -eq 0) {
        throw 'The graphics postmortem schema or revision is invalid.'
    }
    foreach ($name in $topFields[2..($topFields.Count - 1)]) {
        Assert-GswJsonExactProperties -Value $value.$name `
            -Expected @('value', 'provenance') -Label "graphics postmortem.$name"
        Assert-GswJsonString -Value $value.$name.provenance `
            -Label "graphics postmortem.$name.provenance"
    }
    foreach ($name in @('session', 'device', 'host_stage', 'window', 'vm')) {
        Assert-GswJsonString -Value $value.$name.value `
            -Label "graphics postmortem.$name.value"
    }
    foreach ($name in @(
        'session_generation',
        'guest_device_generation',
        'host_device_generation',
        'frame_generation',
        'window_frame_generation',
        'vm_frame_generation'
    )) {
        Assert-GswJsonInteger -Value $value.$name.value `
            -Label "graphics postmortem.$name.value"
    }
    $session = [string]$value.session.value
    if ($session -cnotmatch '^gui-([1-9][0-9]*)-([0-9]+)$' -or
        [int]$Matches[1] -ne $ProcessId -or
        [UInt64]$Matches[2] -eq 0 -or
        [string]$value.session.provenance -cne 'derived') {
        throw 'The graphics postmortem session is not bound to the launched GUI PID.'
    }
    if ([string]$value.device.value -cne 'PCI\VEN_FFFE&DEV_0002' -or
        [string]$value.device.provenance -cne 'derived') {
        throw 'The graphics postmortem device identity is invalid.'
    }
    if ([string]$value.host_stage.value -cne 'complete' -or
        [string]$value.host_stage.provenance -cne 'measured') {
        throw 'The graphics postmortem did not finish at the complete host stage.'
    }
    return [pscustomobject]@{
        Schema = [UInt64]$value.schema
        Revision = [UInt64]$value.revision
        Session = $session
        Value = $value
    }
}

function Save-TestControlValidatedPostmortem {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot
    )

    $postmortem = Assert-TestControlPostmortem -Bytes $Bytes -ProcessId $ProcessId
    $null = Assert-TestControlOrdinaryPath -Path $EvidenceRoot `
        -Name 'evidence directory' -Kind Directory
    $path = Join-Path $EvidenceRoot 'graphics-postmortem.json'
    if (Test-Path -LiteralPath $path) {
        throw 'The retained graphics postmortem artifact must be absent.'
    }
    Write-TestControlNewBytes -Path $path -Bytes $Bytes
    $retained = Read-GswBoundedFileSnapshot -Path $path `
        -Name 'retained graphics postmortem' -MaximumBytes 98304
    $sourceHash = Get-GswSha256Hex -Bytes $Bytes
    if ($retained.Sha256 -cne $sourceHash -or $retained.Length -ne [UInt64]$Bytes.Length) {
        throw 'The retained graphics postmortem bytes changed during evidence capture.'
    }
    return [pscustomobject]@{
        Schema = $postmortem.Schema
        Revision = $postmortem.Revision
        Session = $postmortem.Session
        Value = $postmortem.Value
        Path = $path
        Bytes = $retained.Length
        Sha256 = $retained.Sha256
    }
}

function Assert-TestControlProfileBinding {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ProfileRoot
    )

    $profile = Assert-TestControlContainedPath -Root $RunRoot -Path $ProfileRoot `
        -Name 'Profile root'
    Assert-TestControlOrdinaryTree -Root $profile -Name 'Profile root'
    $items = @(Get-ChildItem -LiteralPath $profile -Force -Recurse)
    $relativeFiles = @($items | Where-Object { -not $_.PSIsContainer } |
        ForEach-Object { [IO.Path]::GetRelativePath($profile, $_.FullName).Replace('\', '/') } |
        Sort-Object)
    $directories = @($items | Where-Object { $_.PSIsContainer })
    if ($directories.Count -ne 0 -or
        (($relativeFiles -join "`n") -cne (($script:TestControlProfileFiles | Sort-Object) -join "`n"))) {
        throw 'The fresh Profile must contain exactly its four ordinary state files.'
    }
    $settingsPath = Join-Path $profile 'settings.json'
    $settingsBytes = Read-GswBoundedFileBytes -Path $settingsPath `
        -Name 'Profile settings' -MaximumBytes 65536
    $settingsText = ConvertFrom-GswStrictUtf8Bytes -Bytes $settingsBytes `
        -Source 'Profile settings'
    $settings = ConvertFrom-GswStrictJson -Json $settingsText -Source 'Profile settings'
    if ($null -eq $settings.PSObject.Properties['hard_drive_path'] -or
        $settings.hard_drive_path -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$settings.hard_drive_path)) {
        throw 'Profile settings must contain one hard_drive_path string.'
    }
    $imagePath = Assert-TestControlContainedPath -Root $RunRoot `
        -Path ([string]$settings.hard_drive_path) -Name 'Profile hard drive'
    $expectedImage = [IO.Path]::GetFullPath((Join-Path $profile 'c_drive.img'))
    $comparison = Get-TestControlPathComparison
    if (-not $imagePath.Equals($expectedImage, $comparison)) {
        throw 'Profile settings are not bound to the Profile c_drive.img.'
    }
    $null = Assert-TestControlOrdinaryPath -Path $imagePath `
        -Name 'Profile hard drive' -Kind File
    foreach ($property in @('floppy_path', 'cdrom_path')) {
        $member = $settings.PSObject.Properties[$property]
        if ($null -eq $member -or [string]::IsNullOrEmpty([string]$member.Value)) {
            continue
        }
        $mediaPath = Assert-TestControlContainedPath -Root $RunRoot `
            -Path ([string]$member.Value) -Name "Profile $property"
        $null = Assert-TestControlOrdinaryPath -Path $mediaPath `
            -Name "Profile $property" -Kind File
    }
    foreach ($absent in @(
        (Join-Path $profile '.profile.lock'),
        (Join-Path $profile 'graphics-postmortem.json'),
        (Join-Path $profile '.c_drive.img.retvrn99-fat32')
    )) {
        if (Test-Path -LiteralPath $absent) {
            throw "Fresh Profile state is not absent: $absent"
        }
    }
    return [pscustomobject]@{
        ProfileRoot = $profile
        SettingsPath = $settingsPath
        ImagePath = $imagePath
        PostmortemPath = Join-Path $profile 'graphics-postmortem.json'
        LockPath = Join-Path $profile '.profile.lock'
        CompanionPath = Join-Path $profile '.c_drive.img.retvrn99-fat32'
    }
}

function Get-TestControlFileInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-TestControlOrdinaryTree -Root $Root -Name $Name
    $result = @()
    foreach ($file in Get-ChildItem -LiteralPath $Root -Force -Recurse -File |
        Sort-Object FullName) {
        $result += [ordered]@{
            path = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
            bytes = [UInt64]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $result
}

function Assert-TestControlInventoryEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][object[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "$Name inventory count changed."
    }
    for ($index = 0; $index -lt $Expected.Count; $index += 1) {
        if ([string]$Expected[$index].path -cne [string]$Actual[$index].path -or
            [UInt64]$Expected[$index].bytes -ne [UInt64]$Actual[$index].bytes -or
            [string]$Expected[$index].sha256 -cne [string]$Actual[$index].sha256) {
            throw "$Name inventory changed at index $index."
        }
    }
}

function Get-TestControlRuntimeProcesses {
    return @(Get-Process -ErrorAction Stop | Where-Object {
        $_.ProcessName -match '(?i)^retvrn99(?:-control|-fat32)?$'
    })
}

function Assert-NoTestControlRuntimeProcess {
    $processes = @(Get-TestControlRuntimeProcesses)
    if ($processes.Count -ne 0) {
        $description = ($processes | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '
        throw "A RETVRN99 runtime process is already active: $description"
    }
}

function Wait-NoTestControlRuntimeProcess {
    param([ValidateRange(0, 30000)][int]$TimeoutMilliseconds = 5000)

    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-TestControlRuntimeProcesses).Count -ne 0 -and
        $clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        Start-Sleep -Milliseconds 100
    }
    $clock.Stop()
    Assert-NoTestControlRuntimeProcess
}

function Write-TestControlNewBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Write-TestControlNewText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    Write-TestControlNewBytes -Path $Path -Bytes $bytes
}

function Write-TestControlNewJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $text = ($Value | ConvertTo-Json -Depth 12) + "`n"
    Write-TestControlNewText -Path $Path -Text $text
}

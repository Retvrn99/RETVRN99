# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MsysRoot = 'C:\msys64',
    [string]$Ucrt64Root = 'C:\msys64\ucrt64',
    [string]$GitRoot = 'C:\Program Files\Git',
    [string]$PackageCacheRoot = 'C:\msys64\var\cache\pacman\pkg',
    [string]$NameFilter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Verifier = Join-Path $PSScriptRoot `
    'verify-win98-vkd3d-shader-toolchain.ps1'
$script:CanonicalLock = Join-Path $repoRoot `
    'drivers\win98\vkd3d-shader-toolchain-lock.json'
$script:CanonicalSchema = Join-Path $repoRoot `
    'drivers\win98\vkd3d-shader-toolchain-lock.schema.json'
$script:EvidenceHelper = Join-Path $PSScriptRoot `
    'vkd3d-shader-compiler-evidence.ps1'
$script:NativeEvidenceHelper = Join-Path $PSScriptRoot `
    'vkd3d-shader-evidence-native.ps1'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    try {
        & $Body | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $($_.Exception.Message)"
        }
        return
    }
    throw 'Expected an exception.'
}

function Assert-ThrowsSanitized {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string[]]$Forbidden
    )

    try { & $Body | Out-Null }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $message"
        }
        foreach ($value in $Forbidden) {
            if (-not [string]::IsNullOrWhiteSpace($value) -and
                $message.IndexOf(
                    $value,
                    [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                throw 'Exception exposed a forbidden private root.'
            }
        }
        if ($message -match '(?i)(?:^|\s)[a-z]:[\\/]' -or
            $message -match '\\\\[^\\/\s]+[\\/]') {
            throw 'Exception exposed an absolute private path.'
        }
        return
    }
    throw 'Expected an exception.'
}

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    if (-not [string]::IsNullOrWhiteSpace($NameFilter) -and
        $Name -notlike "*$NameFilter*") {
        return
    }
    try {
        & $Body
        Write-Host "PASS: $Name"
    }
    catch {
        $script:Failures++
        [Console]::Error.WriteLine("FAIL: $Name`n  $($_.Exception.Message)")
    }
}

function Reset-Fixture {
    [IO.File]::Copy($script:CanonicalLock, $script:LockPath, $true)
    [IO.File]::Copy($script:CanonicalSchema, $script:SchemaPath, $true)
}

function Read-LockObject {
    return [IO.File]::ReadAllText($script:CanonicalLock, $script:Utf8) |
        ConvertFrom-Json
}

function Write-LockObject {
    param([Parameter(Mandatory = $true)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 64
    [IO.File]::WriteAllText($script:LockPath, $json + "`n", $script:Utf8)
}

function Invoke-MetadataVerification {
    param([object]$InternalFaultModel)

    if ($null -eq $InternalFaultModel) {
        return & $script:Verifier -LockFile $script:LockPath -MetadataOnly
    }
    return Invoke-Win98Vkd3dShaderToolchainInternal `
        -LockFile $script:LockPath -MetadataOnly `
        -InternalFaultModel $InternalFaultModel
}

function Invoke-LiveVerification {
    param(
        [hashtable]$Mappings = $script:LiveRoots,
        [object]$InternalFaultModel
    )

    if ($null -eq $InternalFaultModel) {
        return & $script:Verifier -LockFile $script:LockPath `
            -RootMappings $Mappings
    }
    return Invoke-Win98Vkd3dShaderToolchainInternal `
        -LockFile $script:LockPath -RootMappings $Mappings `
        -InternalFaultModel $InternalFaultModel
}

function Remove-TestRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Owner
    )

    $full = [IO.Path]::GetFullPath($Path)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]'\/'
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $full) -notmatch
            '^retvrn99-vkd3d-toolchain-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unsafe test root.'
    }
    Remove-Vkd3dEvidenceOwnedTree $full $Owner.OwnerToken `
        -RootHandle $Owner.RootHandle `
        -OwnerMarkerHandle $Owner.OwnerMarkerHandle
}

foreach ($path in @(
    $script:Verifier, $script:CanonicalLock, $script:CanonicalSchema,
    $script:EvidenceHelper, $script:NativeEvidenceHelper,
    $MsysRoot, $Ucrt64Root, $GitRoot, $PackageCacheRoot
)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required vkd3d-shader toolchain test input is unavailable: $path"
    }
}
. $script:EvidenceHelper
. $script:Verifier

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-vkd3d-toolchain-{0}' -f [Guid]::NewGuid().ToString('N')
)
$script:TestRootOwner = New-Vkd3dEvidenceOwnedDirectory `
    $script:TestRoot 'vkd3d-shader toolchain test root'
$metadataRoot = Join-Path $script:TestRoot 'metadata'
$script:LockPath = Join-Path $metadataRoot 'vkd3d-shader-toolchain-lock.json'
$script:SchemaPath = Join-Path $metadataRoot `
    'vkd3d-shader-toolchain-lock.schema.json'
$script:LiveRoots = @{
    msys = [IO.Path]::GetFullPath($MsysRoot)
    ucrt64 = [IO.Path]::GetFullPath($Ucrt64Root)
    git = [IO.Path]::GetFullPath($GitRoot)
    package_cache = [IO.Path]::GetFullPath($PackageCacheRoot)
}

try {
    New-Item -ItemType Directory -Path $metadataRoot | Out-Null
    Reset-Fixture

    Invoke-SelfTest 'Canonical metadata-only verification passes' {
        $result = Invoke-MetadataVerification
        Assert-Equal $result.status 'ready'
        Assert-Equal $result.mode 'metadata-only'
        Assert-Equal $result.packages 30
        Assert-Equal $result.cached_archives 16
        Assert-Equal $result.files 50
        Assert-Equal $result.trees 2
        Assert-Equal $result.probes 0
        Assert-Equal $result.activation_authorized $false
        Assert-Equal $result.capability_advertisement_authorized $false
    }

    Invoke-SelfTest 'Public verifier exposes no mutation seam' {
        $command = Get-Command $script:Verifier -CommandType ExternalScript
        $common = @([Management.Automation.PSCmdlet]::CommonParameters) +
            @([Management.Automation.PSCmdlet]::OptionalCommonParameters)
        [string[]]$declared = @($command.Parameters.Keys | Where-Object {
            $common -cnotcontains $_
        } | Sort-Object)
        [string[]]$expected = @('LockFile', 'MetadataOnly', 'RootMappings')
        if ([string]::Join('|', $declared) -cne
            [string]::Join('|', $expected)) {
            throw "Public verifier parameters are not closed: $declared"
        }
    }

    Invoke-SelfTest 'Native evidence split is parser-closed and LF-pinned' {
        $helperText = [IO.File]::ReadAllText(
            $script:EvidenceHelper,
            $script:Utf8
        )
        $nativeText = [IO.File]::ReadAllText(
            $script:NativeEvidenceHelper,
            $script:Utf8
        )
        if ($helperText -cnotmatch [regex]::Escape(
                ". (Join-Path `$PSScriptRoot 'vkd3d-shader-evidence-native.ps1')"
            ) -or $helperText.Contains('Add-Type -TypeDefinition') -or
            -not $nativeText.StartsWith(
                "# SPDX-License-Identifier: GPL-3.0-only`n",
                [StringComparison]::Ordinal
            )) {
            throw 'Native evidence split is not exact.'
        }
        foreach ($path in @(
            $script:EvidenceHelper,
            $script:NativeEvidenceHelper
        )) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$errors
            )
            if ($errors.Count -ne 0 -or
                (Get-Content -LiteralPath $path).Count -gt 2500) {
                throw 'Native evidence split violates its parser or size bound.'
            }
        }
        $attribute = 'scripts/vkd3d-shader-evidence-native.ps1 text eol=lf'
        $matches = @(
            [IO.File]::ReadAllLines(
                (Join-Path $repoRoot '.gitattributes'),
                $script:Utf8
            ) | Where-Object { $_ -ceq $attribute }
        )
        if ($matches.Count -ne 1) {
            throw 'Native evidence helper has no unique LF attribute.'
        }
    }

    Invoke-SelfTest 'Native launcher error paths are explicit' {
        $nativeText = [IO.File]::ReadAllText(
            $script:NativeEvidenceHelper,
            $script:Utf8
        )
        foreach ($contract in @(
            'else if (!TerminateProcess(process.hProcess,',
            'WaitForSingleObject(process.hProcess, 5000)',
            'bool attributeListInitialized = false;',
            'sizingError != ERROR_INSUFFICIENT_BUFFER',
            'if (attributeListInitialized)',
            'finally { Stdout = null; }',
            'finally { Stderr = null; }',
            'finally { process = null; }',
            'Bounded process disposal failed.',
            'Bounded process execution and cleanup both failed.',
            'GetFinalPathNameByHandleW',
            'NtCreateFile',
            'CreateExclusiveDirectoryAt',
            'FILE_CREATE',
            'FILE_DIRECTORY_FILE',
            '[ValidateSet(2, 3, 5)][int]$MaximumProcessTreeWidth = 5',
            '[UInt32]$MaximumProcessTreeWidth',
            'pre-delete',
            'post-delete',
            'error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND',
            'throw NativeFailure("Namespace absence query", error);'
        )) {
            if (-not $nativeText.Contains($contract)) {
                throw "Native error-path contract is missing '$contract'."
            }
        }
        if ($nativeText.Contains('CreateDirectoryW') -or
            $nativeText.Contains('RemoveDirectoryW')) {
            throw 'Native directory creation still has a path-level split.'
        }
        $helperText = [IO.File]::ReadAllText(
            $script:EvidenceHelper,
            $script:Utf8
        )
        foreach ($contract in @(
            'Assert-Vkd3dEvidencePathAbsent $full $Name',
            "Assert-Vkd3dEvidencePathAbsent `$full 'Owned proof root'",
            "Assert-Vkd3dEvidencePathAbsent `$full 'Bootstrap proof root'"
        )) {
            if (-not $helperText.Contains($contract)) {
                throw "Final absence contract is missing '$contract'."
            }
        }
    }

    Invoke-SelfTest 'Canonical live root-mapped verification passes' {
        $result = Invoke-LiveVerification
        Assert-Equal $result.status 'ready'
        Assert-Equal $result.mode 'live'
        Assert-Equal $result.probes 9
        Assert-Equal $result.activation_authorized $false
    }

    Invoke-SelfTest 'A verification mode is required' {
        Assert-Throws {
            & $script:Verifier -LockFile $script:LockPath
        } 'Choose exactly one'
    }

    Invoke-SelfTest 'Metadata and live modes are mutually exclusive' {
        Assert-Throws {
            & $script:Verifier -LockFile $script:LockPath -MetadataOnly `
                -RootMappings $script:LiveRoots
        } 'Choose exactly one'
    }

    Invoke-SelfTest 'Malformed lock JSON is rejected' {
        try {
            [IO.File]::WriteAllText($script:LockPath, '{', $script:Utf8)
            Assert-Throws { Invoke-MetadataVerification } 'Malformed.*JSON'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Duplicate lock properties are rejected' {
        try {
            $json = [IO.File]::ReadAllText($script:CanonicalLock, $script:Utf8).Replace(
                '"schema": 1,',
                '"schema": 1, "SCHEMA": 1,'
            )
            [IO.File]::WriteAllText($script:LockPath, $json, $script:Utf8)
            Assert-Throws { Invoke-MetadataVerification } 'Duplicate JSON property'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Lock snapshot blocks an intra-read replacement' {
        [byte[]]$original = [IO.File]::ReadAllBytes($script:LockPath)
        $encoding = $script:Utf8
        $callback = {
            param([string]$path)
            [IO.File]::AppendAllText($path, ' ', $encoding)
        }.GetNewClosure()
        $faultModel = New-Win98Vkd3dShaderToolchainInternalFaultModel `
            -BeforeLockPostReadCheck $callback
        try {
            Assert-Throws {
                Invoke-MetadataVerification $faultModel
            } 'changed during its bounded read|being used by another process'
        }
        finally { [IO.File]::WriteAllBytes($script:LockPath, $original) }
    }

    Invoke-SelfTest 'Schema snapshot blocks an intra-read replacement' {
        [byte[]]$original = [IO.File]::ReadAllBytes($script:SchemaPath)
        $encoding = $script:Utf8
        $callback = {
            param([string]$path)
            [IO.File]::AppendAllText($path, ' ', $encoding)
        }.GetNewClosure()
        $faultModel = New-Win98Vkd3dShaderToolchainInternalFaultModel `
            -BeforeSchemaPostReadCheck $callback
        try {
            Assert-Throws {
                Invoke-MetadataVerification $faultModel
            } 'changed during its bounded read|being used by another process'
        }
        finally { [IO.File]::WriteAllBytes($script:SchemaPath, $original) }
    }

    Invoke-SelfTest 'Unknown top-level properties are rejected' {
        try {
            $lock = Read-LockObject
            $lock | Add-Member -NotePropertyName unknown -NotePropertyValue $true
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } "Unexpected property 'unknown'"
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Unknown nested properties are rejected' {
        try {
            $lock = Read-LockObject
            $lock.files[0] | Add-Member -NotePropertyName unknown -NotePropertyValue 1
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } "Unexpected property 'unknown'"
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Private absolute path leakage is rejected' {
        try {
            $lock = Read-LockObject
            $lock.reason = 'C:\Users\private\tool.exe'
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'private absolute path'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Unsafe relative paths are rejected' {
        try {
            $lock = Read-LockObject
            $lock.files[0].relative_path = '../flex.exe'
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'Unsafe path component'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Duplicate file identifiers are rejected' {
        try {
            $lock = Read-LockObject
            $lock.files[1].id = $lock.files[0].id
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'duplicate file id'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Duplicate file paths are rejected' {
        try {
            $lock = Read-LockObject
            $lock.files[1].relative_path = $lock.files[0].relative_path
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'Duplicate locked file path'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Package-count drift is rejected' {
        try {
            $lock = Read-LockObject
            $lock.packages = @($lock.packages | Select-Object -Skip 1)
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'exactly 30 package identities'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Malformed absent archive metadata is rejected' {
        try {
            $lock = Read-LockObject
            $package = @($lock.packages | Where-Object { -not $_.archive.present })[0]
            $package.archive.sha256 = '0' * 64
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'absent archive metadata is malformed'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Tree descriptor drift is rejected' {
        try {
            $lock = Read-LockObject
            $lock.trees[0].descriptor.file_count++
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'immutable semantic contract'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Complete dependency flag drift is rejected' {
        try {
            $lock = Read-LockObject
            $compile = @($lock.recipes | Where-Object id -ceq 'compile-c-object')[0]
            $index = [Array]::IndexOf([object[]]$compile.arguments, '-MD')
            $compile.arguments[$index] = '-MMD'
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'immutable semantic contract'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Proof-only LTO re-enablement is rejected' {
        try {
            $lock = Read-LockObject
            $compile = @($lock.recipes | Where-Object id -ceq 'compile-c-object')[0]
            $index = [Array]::IndexOf([object[]]$compile.arguments, '-fno-lto')
            $compile.arguments[$index] = '-flto=auto'
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'proof-only no-LTO contract'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Generated include precedence drift is rejected' {
        try {
            $lock = Read-LockObject
            $compile = @($lock.recipes | Where-Object id -ceq 'compile-c-object')[0]
            $first = $compile.arguments[19]
            $compile.arguments[19] = $compile.arguments[21]
            $compile.arguments[21] = $first
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'immutable semantic contract'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Parallel top-level process authorization is rejected' {
        try {
            $lock = Read-LockObject
            $lock.process_limits.maximum_top_level_processes = 2
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'bounded process contract is not exact'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Process tree width drift is rejected' {
        try {
            $lock = Read-LockObject
            $lock.process_limits.maximum_process_tree_width = 4
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } `
                'bounded process contract is not exact'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Process timeout drift is rejected' {
        try {
            $lock = Read-LockObject
            $lock.process_limits.timeout_seconds = 31
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'bounded process contract is not exact'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Process output-bound drift is rejected' {
        try {
            $lock = Read-LockObject
            $lock.process_limits.maximum_stdout_bytes = 1048577
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } 'bounded process contract is not exact'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Activation authorization is rejected' {
        try {
            $lock = Read-LockObject
            $lock.authorizations.activate = $true
            Write-LockObject $lock
            Assert-Throws { Invoke-MetadataVerification } "Authorization 'activate' must remain false"
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Schema byte drift is rejected' {
        try {
            [IO.File]::AppendAllText($script:SchemaPath, ' ', $script:Utf8)
            Assert-Throws { Invoke-MetadataVerification } 'schema hash does not match'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Lock byte drift is rejected' {
        try {
            [IO.File]::AppendAllText($script:LockPath, ' ', $script:Utf8)
            Assert-Throws { Invoke-MetadataVerification } 'immutable semantic contract'
        }
        finally {
            Reset-Fixture
        }
    }

    Invoke-SelfTest 'Unknown live root mappings are rejected' {
        $mappings = $script:LiveRoots.Clone()
        $mappings.Remove('package_cache')
        $mappings['unknown'] = $script:LiveRoots.package_cache
        Assert-Throws { Invoke-LiveVerification $mappings } 'Unknown live root mapping'
    }

    Invoke-SelfTest 'Missing live root mappings are rejected' {
        $mappings = $script:LiveRoots.Clone()
        $mappings.Remove('git')
        Assert-Throws { Invoke-LiveVerification $mappings } 'exactly four root mappings'
    }

    Invoke-SelfTest 'Missing live files are rejected' {
        $empty = Join-Path $script:TestRoot 'empty-ucrt64'
        New-Item -ItemType Directory -Path $empty | Out-Null
        $mappings = $script:LiveRoots.Clone()
        $mappings.ucrt64 = $empty
        Assert-ThrowsSanitized { Invoke-LiveVerification $mappings } `
            'could not be locked|snapshot failed' @($empty)
    }

    Invoke-SelfTest 'Missing package archives are rejected' {
        $empty = Join-Path $script:TestRoot 'empty-packages'
        New-Item -ItemType Directory -Path $empty | Out-Null
        $mappings = $script:LiveRoots.Clone()
        $mappings.package_cache = $empty
        Assert-ThrowsSanitized { Invoke-LiveVerification $mappings } `
            'snapshot failed' @($empty)
    }

    Invoke-SelfTest 'Final metadata recheck detects mutation' {
        [byte[]]$original = [IO.File]::ReadAllBytes($script:LockPath)
        $path = $script:LockPath
        $encoding = $script:Utf8
        $callback = {
            [IO.File]::AppendAllText($path, ' ', $encoding)
        }.GetNewClosure()
        $faultModel = New-Win98Vkd3dShaderToolchainInternalFaultModel `
            -BeforeFinalCheck $callback
        try {
            Assert-Throws {
                Invoke-LiveVerification -InternalFaultModel $faultModel
            } 'immutable semantic contract'
        }
        finally {
            [IO.File]::WriteAllBytes($script:LockPath, $original)
        }
    }

    Invoke-SelfTest 'Live verifier pins handle-owned ordering' {
        $text = [IO.File]::ReadAllText($script:Verifier, $script:Utf8)
        foreach ($pattern in @(
            'Open-LiveProbeFileLocks',
            'New-Vkd3dEvidenceOwnedDirectory',
            'Assert-Vkd3dEvidenceFreshMutationBoundary',
            '-PinnedExecutableHandle',
            '-RootHandle \$ownedDirectory\.RootHandle',
            '-OwnerMarkerHandle \$ownedDirectory\.OwnerMarkerHandle',
            'New-Vkd3dEvidenceCombinedFailure'
        )) {
            if ($text -cnotmatch $pattern) {
                throw "Ownership protocol is missing '$pattern'."
            }
        }
        $ordered = @(
            '$lockedFiles = Open-LiveProbeFileLocks',
            '$ownedDirectory = New-Vkd3dEvidenceOwnedDirectory',
            'foreach ($probe in @($metadata.Lock.tool_probes))',
            'Remove-Vkd3dEvidenceOwnedTree $probeTemp',
            '$finalMetadata = Read-ToolchainMetadata $metadata.Path'
        )
        $previous = -1
        foreach ($value in $ordered) {
            $index = $text.IndexOf(
                $value,
                $previous + 1,
                [StringComparison]::Ordinal
            )
            if ($index -le $previous) {
                throw "Live ownership ordering is invalid at '$value'."
            }
            $previous = $index
        }
    }

    Invoke-SelfTest 'Bootstrap cleanup removes only bounded owned states' {
        $absent = Join-Path $script:TestRoot 'bootstrap-absent'
        Remove-Vkd3dEvidenceBootstrapTree $absent $false

        $empty = Join-Path $script:TestRoot 'bootstrap-empty'
        [void][IO.Directory]::CreateDirectory($empty)
        Remove-Vkd3dEvidenceBootstrapTree $empty $false
        if ([IO.Directory]::Exists($empty)) {
            throw 'Empty bootstrap root survived cleanup.'
        }

        $markerOnly = Join-Path $script:TestRoot 'bootstrap-marker'
        [void][IO.Directory]::CreateDirectory($markerOnly)
        [IO.File]::WriteAllText(
            (Join-Path $markerOnly '.retvrn99-vkd3d-proof-owner'),
            'synthetic-marker',
            [Text.UTF8Encoding]::new($false)
        )
        Remove-Vkd3dEvidenceBootstrapTree $markerOnly $true
        if ([IO.Directory]::Exists($markerOnly)) {
            throw 'Marker bootstrap root survived cleanup.'
        }

        $foreign = Join-Path $script:TestRoot 'bootstrap-foreign'
        [void][IO.Directory]::CreateDirectory($foreign)
        $foreignFile = Join-Path $foreign 'foreign.txt'
        [IO.File]::WriteAllText(
            $foreignFile,
            'preserve',
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws {
            Remove-Vkd3dEvidenceBootstrapTree $foreign $false
        } 'foreign entr'
        if (-not [IO.File]::Exists($foreignFile)) {
            throw 'Bootstrap cleanup removed a foreign entry.'
        }
    }

    Invoke-SelfTest 'Owned cleanup rejects a raced-in entry before deletion' {
        $root = Join-Path $script:TestRoot 'owned-race'
        $owned = New-Vkd3dEvidenceOwnedDirectory $root `
            'owned cleanup race root'
        $late = Join-Path $root 'late.txt'
        [byte[]]$lateBytes = $script:Utf8.GetBytes('late')
        $callback = {
            param([string]$ownedRoot)
            [IO.File]::WriteAllBytes($late, $lateBytes)
        }.GetNewClosure()
        try {
            Assert-Throws {
                Remove-Vkd3dEvidenceOwnedTree $root $owned.OwnerToken `
                    -RootHandle $owned.RootHandle `
                    -OwnerMarkerHandle $owned.OwnerMarkerHandle `
                    -BeforeDelete $callback
            } 'changed after its cleanup snapshot'
            if (-not [IO.File]::Exists($late) -or
                -not [IO.File]::Exists((Join-Path $root `
                    '.retvrn99-vkd3d-proof-owner'))) {
                throw 'Raced cleanup removed an entry before rejecting drift.'
            }
        }
        finally {
            if ([IO.File]::Exists($late)) {
                Remove-Vkd3dEvidenceOwnedLeaf $root $late 'raced cleanup leaf' `
                    -ExpectedBytes $lateBytes.Length `
                    -ExpectedSha256 (Get-Vkd3dEvidenceSha256 $lateBytes)
            }
            if ([IO.Directory]::Exists($root)) {
                $rootHandle = Open-Vkd3dEvidenceDeleteHandle $root `
                    'raced cleanup recovery root'
                $markerHandle = Open-Vkd3dEvidenceDeleteHandle `
                    (Join-Path $root '.retvrn99-vkd3d-proof-owner') `
                    'raced cleanup recovery marker'
                Remove-Vkd3dEvidenceOwnedTree $root $owned.OwnerToken `
                    -RootHandle $rootHandle -OwnerMarkerHandle $markerHandle
            }
        }
    }

    Invoke-SelfTest 'Delete handles cannot cross their held root namespace' {
        $firstRoot = Join-Path $script:TestRoot 'bound-delete-first'
        $secondRoot = Join-Path $script:TestRoot 'bound-delete-second'
        $first = New-Vkd3dEvidenceOwnedDirectory $firstRoot `
            'first bound-delete root'
        $second = $null
        try {
            $second = New-Vkd3dEvidenceOwnedDirectory $secondRoot `
                'second bound-delete root'
            $target = Join-Path $secondRoot 'target.bin'
            [IO.File]::WriteAllBytes($target, [byte[]](1, 2, 3))
            $targetHandle = Open-Vkd3dEvidenceDeleteHandle $target `
                'cross-root target'
            try {
                Assert-Throws {
                    Set-Vkd3dEvidenceBoundHandleDelete `
                        $first.RootHandle $targetHandle `
                        $firstRoot $target 'cross-root delete'
                } 'outside its held root namespace'
            }
            finally { $targetHandle.Dispose() }
            if (-not [IO.File]::Exists($target)) {
                throw 'Cross-root rejection deleted the foreign target.'
            }
        }
        finally {
            try {
                if ([IO.Directory]::Exists($firstRoot)) {
                    Remove-Vkd3dEvidenceOwnedTree $firstRoot `
                        $first.OwnerToken -RootHandle $first.RootHandle `
                        -OwnerMarkerHandle $first.OwnerMarkerHandle
                }
            }
            finally {
                if ($null -ne $second -and
                    [IO.Directory]::Exists($secondRoot)) {
                    Remove-Vkd3dEvidenceOwnedTree $secondRoot `
                        $second.OwnerToken -RootHandle $second.RootHandle `
                        -OwnerMarkerHandle $second.OwnerMarkerHandle
                }
            }
        }
    }

    Invoke-SelfTest 'Namespace errors are not accepted as absence' {
        $invalid = Join-Path $script:TestRoot 'invalid|absence'
        Assert-Throws {
            Test-Vkd3dEvidencePathAbsent $invalid
        } 'Namespace absence query'
    }

    Invoke-SelfTest 'Verifier cleanup race fails closed and recovers exactly' {
        $capture = [pscustomobject]@{ Path = '' }
        $callback = {
            param([string]$probeRoot)
            $capture.Path = $probeRoot
        }.GetNewClosure()
        $faultModel = New-Win98Vkd3dShaderToolchainInternalFaultModel `
            -BeforeFinalCheck $callback `
            -CleanupMutation 'race-owned-cleanup'
        Assert-Throws {
            Invoke-LiveVerification -InternalFaultModel $faultModel
        } 'Compiler evidence cleanup failed'
        if ([string]::IsNullOrWhiteSpace($capture.Path) -or
            [IO.Directory]::Exists($capture.Path) -or
            [IO.File]::Exists($capture.Path)) {
            throw 'Verifier cleanup-race recovery left its exact root.'
        }
    }

    Invoke-SelfTest 'Cleanup failure preserves the primary failure' {
        $capture = [pscustomobject]@{ Path = '' }
        $callback = {
            param([string]$probeRoot)
            $capture.Path = $probeRoot
            throw 'synthetic live verification failure'
        }.GetNewClosure()
        $faultModel = New-Win98Vkd3dShaderToolchainInternalFaultModel `
            -BeforeFinalCheck $callback `
            -CleanupMutation 'race-owned-cleanup'
        $observed = $null
        try {
            Invoke-LiveVerification -InternalFaultModel $faultModel | Out-Null
        }
        catch { $observed = $_.Exception }
        if ($null -eq $observed) {
            throw 'Expected combined verification and cleanup failure.'
        }
        $detail = $observed.ToString()
        if ($detail -notmatch
                'Compiler evidence collection and cleanup both failed' -or
            $detail -notmatch
                'Primary failure:.*synthetic live verification failure' -or
            $detail -notmatch
                'Cleanup failure 1:.*changed after its cleanup snapshot') {
            throw "Combined failure lost a boundary: $detail"
        }
        if ([IO.Directory]::Exists($capture.Path) -or
            [IO.File]::Exists($capture.Path)) {
            throw 'Combined cleanup recovery left its exact root.'
        }
    }

    Invoke-SelfTest 'Exclusive directory creation rejects a raced leaf' {
        $root = Join-Path $script:TestRoot 'exclusive-directory'
        $handle = New-Vkd3dEvidenceExclusiveDirectory $root `
            'exclusive directory fixture'
        try {
            Assert-Throws {
                New-Vkd3dEvidenceExclusiveDirectory $root `
                    'exclusive directory collision' | Out-Null
            } 'could not be created with exclusive ownership'
        }
        finally {
            Remove-Vkd3dEvidenceBootstrapTree $root $false `
                -RootHandle $handle
        }
    }

    Invoke-SelfTest 'Atomic directory creation is handle-relative' {
        $root = Join-Path $script:TestRoot 'atomic-directory'
        $handle =
            [Retvrn99.Vkd3dEvidenceNative]::CreateExclusiveDirectoryAt(
                $script:TestRootOwner.RootHandle,
                [IO.Path]::GetFileName($root)
            )
        try {
            Assert-Equal (
                [Retvrn99.Vkd3dEvidenceNative]::GetFinalPath($handle)
            ) ([IO.Path]::GetFullPath($root))
            Assert-Throws {
                [Retvrn99.Vkd3dEvidenceNative]::CreateExclusiveDirectoryAt(
                    $script:TestRootOwner.RootHandle,
                    [IO.Path]::GetFileName($root)
                ) | Out-Null
            } 'Atomic directory creation'
        }
        finally {
            Remove-Vkd3dEvidenceBootstrapTree $root $false `
                -RootHandle $handle
        }
    }

    Invoke-SelfTest 'Stable file handle blocks replacement and pins identity' {
        $path = Join-Path $script:TestRoot 'stable-file.bin'
        [byte[]]$bytes = $script:Utf8.GetBytes('stable-file')
        [IO.File]::WriteAllBytes($path, $bytes)
        $handle = Open-Vkd3dEvidenceStableHandle $path 'stable fixture'
        try {
            $before = Get-Vkd3dEvidenceHandleIdentity $handle `
                'stable fixture'
            Assert-Throws {
                [IO.File]::WriteAllBytes($path, $bytes)
            } 'being used by another process|cannot access'
            $after = Get-Vkd3dEvidenceHandleIdentity $handle `
                'stable fixture'
            Assert-Equal $after.file_identity $before.file_identity
            Assert-Equal $after.sha256 $before.sha256
            Assert-Equal $after.bytes $before.bytes
        }
        finally { $handle.Dispose() }
        Remove-Vkd3dEvidenceOwnedLeaf $script:TestRoot $path `
            'stable fixture' -ExpectedBytes $bytes.Length `
            -ExpectedSha256 (Get-Vkd3dEvidenceSha256 $bytes) `
            -ParentHandle $script:TestRootOwner.RootHandle
    }

    Invoke-SelfTest 'Owned leaf cleanup rejects a same-byte replacement' {
        $path = Join-Path $script:TestRoot 'same-byte-replacement.bin'
        [byte[]]$bytes = $script:Utf8.GetBytes('same-byte-replacement')
        [IO.File]::WriteAllBytes($path, $bytes)
        $handle = Open-Vkd3dEvidenceStableHandle $path `
            'same-byte original'
        try {
            $original = Get-Vkd3dEvidenceHandleIdentity $handle `
                'same-byte original'
        }
        finally { $handle.Dispose() }
        $originalPath = Join-Path $script:TestRoot `
            'same-byte-replacement.original'
        [IO.File]::Move($path, $originalPath)
        [IO.File]::WriteAllBytes($path, $bytes)
        Assert-Throws {
            Remove-Vkd3dEvidenceOwnedLeaf $script:TestRoot $path `
                'same-byte replacement' -ExpectedBytes $bytes.Length `
                -ExpectedSha256 $original.sha256 `
                -ExpectedFileIdentity $original.file_identity `
                -ParentHandle $script:TestRootOwner.RootHandle
        } 'expected owned file identity'
        if (-not [IO.File]::Exists($path)) {
            throw 'Identity-gated cleanup deleted the replacement.'
        }
        Remove-Vkd3dEvidenceOwnedLeaf $script:TestRoot $path `
            'same-byte replacement recovery' -ExpectedBytes $bytes.Length `
            -ExpectedSha256 $original.sha256 `
            -ParentHandle $script:TestRootOwner.RootHandle
        Remove-Vkd3dEvidenceOwnedLeaf $script:TestRoot $originalPath `
            'same-byte original recovery' -ExpectedBytes $bytes.Length `
            -ExpectedSha256 $original.sha256 `
            -ExpectedFileIdentity $original.file_identity `
            -ParentHandle $script:TestRootOwner.RootHandle
    }

    Invoke-SelfTest 'Evidence paths reject non-portable components' {
        foreach ($path in @(
            'a//b', 'a/./b', 'a/../b', 'C:/private/file', 'C:private/file',
            'a\b', '/absolute', 'a/NUL.txt', ('a/' + ('x' * 1024))
        )) {
            Assert-Throws {
                Assert-Vkd3dEvidenceRelativePath $path 'synthetic path'
            } 'unsafe relative path'
        }
        Assert-Vkd3dEvidenceRelativePath `
            'libs/vkd3d-shader/vkd3d_shader_main.c' 'synthetic path'
    }

    Invoke-SelfTest 'Empty evidence stream has the canonical SHA-256' {
        Assert-Equal (Get-Vkd3dEvidenceSha256 ([byte[]]@())) `
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' `
            'Empty evidence SHA-256 changed.'
    }

    Invoke-SelfTest 'Runtime output bound terminates the child' {
        $childCount = 0
        $pwsh = (Get-Process -Id $PID).Path
        $command = '[Console]::Out.Write("x" * 1048576); Start-Sleep -Seconds 20'
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($command)
        )
        Assert-Throws {
            Invoke-Vkd3dEvidenceProcess -File $pwsh `
                -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
                -WorkingDirectory $script:TestRoot -PathDirectories @($PSHOME) `
                -PrivateTemp $script:TestRoot -Name 'synthetic output child' `
                -ChildCount ([ref]$childCount) -TimeoutSeconds 10 `
                -MaximumOutputBytes 4096
        } '^synthetic output child exceeded its output bound\.$'
        Assert-Equal $childCount 1 'Output-bound child accounting changed.'
    }

    Invoke-SelfTest 'Unsupported process tree widths are rejected before launch' {
        $pwsh = (Get-Process -Id $PID).Path
        foreach ($width in @(1, 4, 6)) {
            $childCount = 0
            Assert-Throws {
                Invoke-Vkd3dEvidenceProcess -File $pwsh `
                    -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') `
                    -WorkingDirectory $script:TestRoot `
                    -PathDirectories @($PSHOME) `
                    -PrivateTemp $script:TestRoot `
                    -Name 'synthetic invalid-width child' `
                    -ChildCount ([ref]$childCount) `
                    -MaximumProcessTreeWidth $width
            } 'MaximumProcessTreeWidth'
            Assert-Equal $childCount 0 `
                'Rejected process width started a child.'
        }
    }

    Invoke-SelfTest 'Child environment is isolated from ambient poison' {
        $poisonName = 'RETVRN99_VKD3D_TEST_POISON'
        $gccPoisonName = 'GCC_EXEC_PREFIX'
        $oldPoison = [Environment]::GetEnvironmentVariable($poisonName, 'Process')
        $oldGccPoison = [Environment]::GetEnvironmentVariable(
            $gccPoisonName, 'Process'
        )
        try {
            [Environment]::SetEnvironmentVariable(
                $poisonName, 'private-value', 'Process'
            )
            [Environment]::SetEnvironmentVariable(
                $gccPoisonName, 'C:\private\compiler', 'Process'
            )
            $command = @"
if ([Environment]::GetEnvironmentVariable('$poisonName', 'Process') -or
    [Environment]::GetEnvironmentVariable('$gccPoisonName', 'Process')) {
    exit 41
}
"@
            $encoded = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($command)
            )
            $childCount = 0
            $pwsh = (Get-Process -Id $PID).Path
            $result = Invoke-Vkd3dEvidenceProcess -File $pwsh `
                -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
                -WorkingDirectory $script:TestRoot -PathDirectories @($PSHOME) `
                -PrivateTemp $script:TestRoot -Name 'synthetic isolated child' `
                -ChildCount ([ref]$childCount) -TimeoutSeconds 5 `
                -MaximumOutputBytes 4096
            Assert-Equal $result.exit_code 0
            Assert-Equal $childCount 1 'Isolated child accounting changed.'
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                $poisonName, $oldPoison, 'Process'
            )
            [Environment]::SetEnvironmentVariable(
                $gccPoisonName, $oldGccPoison, 'Process'
            )
        }
    }

    Invoke-SelfTest 'Exact noninteractive Git environment is permitted' {
        $command = @'
$expected = @{
    GIT_CONFIG_NOSYSTEM = '1'
    GIT_CONFIG_GLOBAL = 'NUL'
    GIT_OPTIONAL_LOCKS = '0'
    GIT_TERMINAL_PROMPT = '0'
}
foreach ($name in $expected.Keys) {
    if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne
        $expected[$name]) {
        exit 42
    }
}
'@
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($command)
        )
        $childCount = 0
        $pwsh = (Get-Process -Id $PID).Path
        $result = Invoke-Vkd3dEvidenceProcess -File $pwsh `
            -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
            -WorkingDirectory $script:TestRoot -PathDirectories @($PSHOME) `
            -PrivateTemp $script:TestRoot -Name 'synthetic Git environment child' `
            -ChildCount ([ref]$childCount) -Environment @{
                GIT_CONFIG_NOSYSTEM = '1'
                GIT_CONFIG_GLOBAL = 'NUL'
                GIT_OPTIONAL_LOCKS = '0'
                GIT_TERMINAL_PROMPT = '0'
            } -TimeoutSeconds 5 -MaximumOutputBytes 4096
        Assert-Equal $result.exit_code 0
        Assert-Equal $childCount 1 'Git environment child accounting changed.'
        Assert-Throws {
            Invoke-Vkd3dEvidenceProcess -File $pwsh `
                -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') `
                -WorkingDirectory $script:TestRoot -PathDirectories @($PSHOME) `
                -PrivateTemp $script:TestRoot -Name 'synthetic unsafe Git environment' `
                -ChildCount ([ref]$childCount) -Environment @{
                    GIT_TERMINAL_PROMPT = '1'
                } -TimeoutSeconds 5 -MaximumOutputBytes 4096
        } '^synthetic unsafe Git environment has an unsupported environment override\.$'
        Assert-Equal $childCount 1 'Rejected Git environment started a child.'
    }

    Invoke-SelfTest 'Private child diagnostics are not exposed' {
        $command = @'
[Console]::Error.Write('C:\Users\private\shader.c: failure')
exit 23
'@
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($command)
        )
        $childCount = 0
        $pwsh = (Get-Process -Id $PID).Path
        $message = ''
        try {
            Invoke-Vkd3dEvidenceProcess -File $pwsh `
                -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
                -WorkingDirectory $script:TestRoot -PathDirectories @($PSHOME) `
                -PrivateTemp $script:TestRoot -Name 'synthetic private child' `
                -ChildCount ([ref]$childCount) -TimeoutSeconds 5 `
                -MaximumOutputBytes 4096 | Out-Null
            throw 'Expected private diagnostic child rejection.'
        }
        catch { $message = $_.Exception.Message }
        Assert-Equal $message `
            'synthetic private child failed with exit code 23.' `
            'Child failure diagnostics were not sanitized.'
        if ($message -match '(?i)Users|shader\.c|[a-z]:[\\/]') {
            throw 'Child failure exposed raw private diagnostics.'
        }
        Assert-Equal $childCount 1 'Private diagnostic child accounting changed.'
    }

    Invoke-SelfTest 'Timeout terminates the owned process tree' {
        $pwsh = (Get-Process -Id $PID).Path
        $pidFile = Join-Path $script:TestRoot 'timeout-descendant.pid'
        $sentinel = Join-Path $script:TestRoot 'timeout-descendant-survived.txt'
        $quotedPidFile = $pidFile.Replace("'", "''")
        $quotedSentinel = $sentinel.Replace("'", "''")
        $descendantCommand = @"
[IO.File]::WriteAllText('$quotedPidFile', `$PID.ToString())
Start-Sleep -Seconds 4
[IO.File]::WriteAllText('$quotedSentinel', 'survived')
"@
        $descendantEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($descendantCommand)
        )
        $quotedPwsh = $pwsh.Replace("'", "''")
        $parentCommand = @"
`$child = Start-Process -FilePath '$quotedPwsh' -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-EncodedCommand', '$descendantEncoded'
) -WindowStyle Hidden -PassThru
for (`$index = 0; `$index -lt 100 -and
    -not [IO.File]::Exists('$quotedPidFile'); `$index++) {
    Start-Sleep -Milliseconds 20
}
Start-Sleep -Seconds 30
"@
        $parentEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($parentCommand)
        )
        $childCount = 0
        Assert-Throws {
            Invoke-Vkd3dEvidenceProcess -File $pwsh `
                -Arguments @(
                    '-NoProfile', '-NonInteractive', '-EncodedCommand',
                    $parentEncoded
                ) `
                -WorkingDirectory $script:TestRoot -PathDirectories @($PSHOME) `
                -PrivateTemp $script:TestRoot -Name 'synthetic timeout child' `
                -ChildCount ([ref]$childCount) -TimeoutSeconds 1 `
                -MaximumOutputBytes 4096
        } '^synthetic timeout child exceeded its 1-second bound\.$'
        if (-not [IO.File]::Exists($pidFile)) {
            throw 'Timeout descendant did not publish its bounded PID fixture.'
        }
        $descendantPid = [int][IO.File]::ReadAllText($pidFile)
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        do {
            $descendant = Get-Process -Id $descendantPid `
                -ErrorAction SilentlyContinue
            if ($null -eq $descendant) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -ne (Get-Process -Id $descendantPid `
                -ErrorAction SilentlyContinue)) {
            throw 'Timeout descendant survived process-tree cleanup.'
        }
        if ([IO.File]::Exists($sentinel)) {
            throw 'Timeout descendant executed after process-tree cleanup.'
        }
        Assert-Equal $childCount 1 'Timeout child accounting changed.'
    }

    Invoke-SelfTest 'Parent exit cannot detach a bounded descendant' {
        $pwsh = (Get-Process -Id $PID).Path
        $pidFile = Join-Path $script:TestRoot 'detached-descendant.pid'
        $sentinel = Join-Path $script:TestRoot `
            'detached-descendant-survived.txt'
        $quotedPidFile = $pidFile.Replace("'", "''")
        $quotedSentinel = $sentinel.Replace("'", "''")
        $descendantCommand = @"
[IO.File]::WriteAllText('$quotedPidFile', `$PID.ToString())
Start-Sleep -Seconds 4
[IO.File]::WriteAllText('$quotedSentinel', 'survived')
"@
        $descendantEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($descendantCommand)
        )
        $quotedPwsh = $pwsh.Replace("'", "''")
        $parentCommand = @"
Start-Process -FilePath '$quotedPwsh' -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-EncodedCommand', '$descendantEncoded'
) -WindowStyle Hidden | Out-Null
for (`$index = 0; `$index -lt 100 -and
    -not [IO.File]::Exists('$quotedPidFile'); `$index++) {
    Start-Sleep -Milliseconds 20
}
exit 0
"@
        $parentEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($parentCommand)
        )
        $childCount = 0
        Assert-Throws {
            Invoke-Vkd3dEvidenceProcess -File $pwsh `
                -Arguments @(
                    '-NoProfile', '-NonInteractive', '-EncodedCommand',
                    $parentEncoded
                ) `
                -WorkingDirectory $script:TestRoot -PathDirectories @($PSHOME) `
                -PrivateTemp $script:TestRoot -Name 'synthetic detached child' `
                -ChildCount ([ref]$childCount) -TimeoutSeconds 1 `
                -MaximumOutputBytes 4096
        } '^synthetic detached child left a detached descendant after its parent exited\.$'
        if (-not [IO.File]::Exists($pidFile)) {
            throw 'Detached descendant did not publish its bounded PID fixture.'
        }
        $descendantPid = [int][IO.File]::ReadAllText($pidFile)
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        do {
            $descendant = Get-Process -Id $descendantPid `
                -ErrorAction SilentlyContinue
            if ($null -eq $descendant) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -ne (Get-Process -Id $descendantPid `
                -ErrorAction SilentlyContinue)) {
            throw 'Detached descendant survived kill-on-close job cleanup.'
        }
        if ([IO.File]::Exists($sentinel)) {
            throw 'Detached descendant executed after bounded job cleanup.'
        }
        Assert-Equal $childCount 1 'Detached child accounting changed.'
    }
}
finally {
    Remove-TestRoot $script:TestRoot $script:TestRootOwner
}

if ($script:Failures -ne 0) {
    throw "$script:Failures vkd3d-shader toolchain test(s) failed."
}
Write-Host 'All Windows 98 vkd3d-shader toolchain tests passed.'

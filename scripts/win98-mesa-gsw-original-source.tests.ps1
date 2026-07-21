# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MesaCheckout = 'D:\src\retvrn99-win98\mesa9x',
    [string]$NameFilter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Tests = 0
$script:NameFilter = [string]$NameFilter
$script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ModuleRoot = Join-Path $script:Root 'drivers\win98\mesa-gsw'
$script:Verifier = Join-Path $PSScriptRoot `
    'verify-win98-mesa-gsw-original-source.ps1'
$requestedMesaCheckout = [string]$MesaCheckout

. $script:Verifier
$script:TestMesaCheckout = [IO.Path]::GetFullPath($requestedMesaCheckout)

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    if (-not [string]::IsNullOrWhiteSpace($script:NameFilter) -and
        $Name -notlike "*$($script:NameFilter)*") {
        return
    }
    $script:Tests++
    try {
        & $Body
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [Parameter(Mandatory = $true)][string]$ExpectedText
    )
    try { & $Body }
    catch {
        if ($_.Exception.Message.IndexOf(
                $ExpectedText, [StringComparison]::OrdinalIgnoreCase
            ) -lt 0) {
            throw "Expected error containing '$ExpectedText', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error containing '$ExpectedText'."
}

function Read-SourceText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $path = Join-Path $script:ModuleRoot $RelativePath
    if (-not [IO.File]::Exists($path)) { throw "Missing '$RelativePath'." }
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert-True ($bytes.Length -ge 1) "$RelativePath is empty."
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)) "$RelativePath has a UTF-8 BOM."
    Assert-True (-not ($bytes -contains 0)) "$RelativePath contains NUL."
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    Assert-True (-not $text.Contains("`r")) "$RelativePath is not normalized LF text."
    Assert-True ($text.EndsWith("`n", [StringComparison]::Ordinal)) `
        "$RelativePath lacks a terminal newline."
    return $text
}

function Write-TestJson {
    param([string]$Path, [object]$Value)

    $json = $Value | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText(
        $Path,
        $json + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function New-ModuleFixture {
    $fixture = Join-Path $script:TestRoot ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'include'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'src'))
    foreach ($relativePath in @(
        'interface-inputs.lock.json',
        'interface-inputs.schema.json',
        'include\git_sha1.h',
        'include\nine_memory_helper.h',
        'src\nine_memory_helper.c'
    )) {
        $source = Join-Path $script:ModuleRoot $relativePath
        $destination = Join-Path $fixture $relativePath
        [IO.File]::Copy($source, $destination, $false)
    }
    return $fixture
}

function Get-FixtureLockObject {
    param([string]$Fixture)

    $path = Join-Path $Fixture 'interface-inputs.lock.json'
    $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true))
    return ConvertFrom-GswStrictJson -Json $text -Source $path
}

function Invoke-FixtureVerification {
    param(
        [Parameter(Mandatory = $true)][string]$Fixture,
        [scriptblock]$BeforeFinalCheck
    )

    return @(
        Invoke-GswMesaOriginalSourceVerification `
            -CheckoutPath $script:TestMesaCheckout `
            -MetadataPath (Join-Path $Fixture 'interface-inputs.lock.json') `
            -BeforeFinalCheck $BeforeFinalCheck
    )
}

function Remove-TestRoot {
    param([string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]'\/'
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
            $tempPrefix, [StringComparison]::OrdinalIgnoreCase
        ) -or (Split-Path -Leaf $fullPath) -notlike
            'retvrn99-mesa-gsw-original-source-*') {
        throw "Refusing to remove unsafe test root '$fullPath'."
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-gsw-original-source-' + [Guid]::NewGuid().ToString('N')
)
[void][IO.Directory]::CreateDirectory($script:TestRoot)

$identity = Read-SourceText 'include\git_sha1.h'
$interface = Read-SourceText 'include\nine_memory_helper.h'
$implementation = Read-SourceText 'src\nine_memory_helper.c'
$inputLockText = Read-SourceText 'interface-inputs.lock.json'
$inputLock = ConvertFrom-GswStrictJson -Json $inputLockText `
    -Source 'production original-source lock'
$schemaText = Read-SourceText 'interface-inputs.schema.json'
$schema = ConvertFrom-GswStrictJson -Json $schemaText `
    -Source 'production original-source schema'
$verifierText = [IO.File]::ReadAllText(
    $script:Verifier,
    [Text.UTF8Encoding]::new($false, $true)
)
$readme = Read-SourceText 'README.md'
$allSource = $identity + "`n" + $interface + "`n" + $implementation

try {
Invoke-SelfTest 'Every source carries GPL-3.0-only SPDX' {
    foreach ($text in @($identity, $interface, $implementation)) {
        Assert-Match $text '\A/\* SPDX-License-Identifier: GPL-3\.0-only \*/\n' `
            'A C source does not begin with the required SPDX identifier.'
    }
    Assert-Match $readme '\A<!-- SPDX-License-Identifier: GPL-3\.0-only -->\n' `
        'README does not begin with the required SPDX identifier.'
    Assert-True ($inputLock._spdx -ceq 'GPL-3.0-only' -and
        $schema._spdx -ceq 'GPL-3.0-only') `
        'Original-source metadata does not carry GPL-3.0-only SPDX.'
    Assert-Match $verifierText '\A# SPDX-License-Identifier: GPL-3\.0-only\n' `
        'Verifier does not begin with the required SPDX identifier.'
}

Invoke-SelfTest 'Mesa identity is immutable and complete' {
    Assert-Match $identity '^#define RETVRN99_MESA_SOURCE_VERSION "23\.1\.9-retvrn99-gsw"$' `
        'The fixed Mesa package version is missing.'
    Assert-Match $identity '"29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f"' `
        'The full pinned Mesa9x commit is missing.'
    Assert-Match $identity '^#define MESA_GIT_SHA1 " \(git-29b9adb44b\)"$' `
        'MESA_GIT_SHA1 does not bind the pinned short commit.'
    Assert-Match $identity '^#define PACKAGE_VERSION RETVRN99_MESA_SOURCE_VERSION$' `
        'PACKAGE_VERSION does not bind the immutable GSW version.'
    Assert-True (-not [regex]::IsMatch($identity, '__DATE__|__TIME__|getenv|system\s*\(')) `
        'The identity header contains a runtime or ambient identity probe.'
}

Invoke-SelfTest 'Permissive Interface inputs are hash locked' {
    Assert-True ($inputLock._spdx -ceq 'GPL-3.0-only') `
        'Interface-input lock SPDX policy changed.'
    Assert-True ($inputLock.schema -eq 1 -and
        $inputLock.status -ceq 'reviewed-permissive-interfaces') `
        'Interface-input lock schema or status changed.'
    Assert-True ($inputLock.schema_definition.relative_path -ceq
        'interface-inputs.schema.json' -and
        $inputLock.schema_definition.sha256 -ceq
        'a7c0520ed4ae206f8b5fd5bad971005d0e57e067b114ba45ac444f9d9324ced8') `
        'Interface-input schema binding changed.'
    Assert-True ($inputLock.source.commit -ceq `
        '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f') `
        'Interface-input lock commit changed.'
    Assert-True ($inputLock.inputs.Count -eq 8) `
        'Interface-input lock must contain exactly eight reviewed files.'
    foreach ($input in $inputLock.inputs) {
        Assert-True ($input.license_expression -ceq 'MIT') `
            "Input '$($input.source_relative_path)' is not MIT."
        Assert-True ([regex]::IsMatch([string]$input.git_blob, '^[0-9a-f]{40}$')) `
            "Input '$($input.source_relative_path)' has an invalid Git blob."
        Assert-True ([regex]::IsMatch([string]$input.sha256, '^[0-9a-f]{64}$')) `
            "Input '$($input.source_relative_path)' has an invalid SHA-256."
        Assert-True ([int64]$input.bytes -gt 0) `
            "Input '$($input.source_relative_path)' has no bytes."
    }
    $excluded = @($inputLock.excluded_implementation_paths)
    Assert-True ($excluded.Count -eq 2 -and
        $excluded -ccontains 'include/git_sha1.h' -and
        $excluded -ccontains 'win9x/nine/nine_memory_helper.c') `
        'Excluded donor implementations changed.'
    foreach ($claim in $inputLock.claims.PSObject.Properties) {
        Assert-True ($claim.Value -is [bool] -and -not $claim.Value) `
            "Claim '$($claim.Name)' is not false."
    }
}

Invoke-SelfTest 'Build-consumable original outputs are hash locked' {
    Assert-True ($inputLock.outputs.Count -eq 3) `
        'Original-source lock must contain exactly three outputs.'
    $expected = @(
        'include/git_sha1.h|525|a9fbd8a78d0ac9ae5c12f1ef6528e99f6bf9067284a3b3119ed7c9ae86a63c91|mesa-build-identity',
        'include/nine_memory_helper.h|1473|e7aff0715a4f98a2d3aa29bdf0efd43fea8cdb2d9b70ac6b310d8a528b72cade|nine-memory-interface',
        'src/nine_memory_helper.c|9301|b1e2f213d6cf2ced951d526e31cf74430ab0b0ce6942fe5a77f898bc65b8b0ef|nine-resident-memory-adapter'
    )
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $output = $inputLock.outputs[$index]
        $observed = '{0}|{1}|{2}|{3}' -f $output.relative_path,
            $output.bytes, $output.sha256, $output.role
        Assert-True ($observed -ceq $expected[$index]) `
            "Output descriptor $index changed."
        Assert-True ($output.license_expression -ceq 'GPL-3.0-only') `
            "Output descriptor $index is not GPL-3.0-only."
    }
}

Invoke-SelfTest 'Schema closes the source Module shape and authorization claims' {
    Assert-True ($schema.'$id' -ceq 'interface-inputs.schema.json') `
        'Original-source schema identity changed.'
    Assert-True ($schema.additionalProperties -is [bool] -and
        -not $schema.additionalProperties) `
        'Original-source schema permits unknown top-level properties.'
    Assert-True ($schema.properties.inputs.minItems -eq 8 -and
        $schema.properties.inputs.maxItems -eq 8 -and
        $schema.properties.inputs.prefixItems.Count -eq 8) `
        'Schema does not bind eight ordered inputs.'
    Assert-True ($schema.properties.outputs.minItems -eq 3 -and
        $schema.properties.outputs.maxItems -eq 3 -and
        $schema.properties.outputs.prefixItems.Count -eq 3) `
        'Schema does not bind three ordered outputs.'
    foreach ($property in $schema.properties.claims.properties.PSObject.Properties) {
        Assert-True ($property.Value.const -is [bool] -and
            -not $property.Value.const) `
            "Schema claim '$($property.Name)' is not fixed false."
    }
}

Invoke-SelfTest 'Nine Interface exports the complete caller-required symbol set' {
    $symbols = @(
        'nine_allocate',
        'nine_free',
        'nine_free_worker',
        'nine_get_pointer',
        'nine_pointer_weakrelease',
        'nine_pointer_strongrelease',
        'nine_pointer_delayedstrongrelease',
        'nine_suballocate',
        'nine_wrap_external_pointer',
        'nine_allocator_create',
        'nine_allocator_destroy'
    )
    foreach ($symbol in $symbols) {
        Assert-Match $interface ("\b" + [regex]::Escape($symbol) + '\s*\(') `
            "Interface declaration '$symbol' is missing."
        Assert-Match $implementation ("(?m)^[A-Za-z_][^;\n]*\b" + `
            [regex]::Escape($symbol) + '\s*\(') `
            "Implementation '$symbol' is missing."
    }
}

Invoke-SelfTest 'Original sources exclude donor implementations and alternate devices' {
    $forbidden = @(
        'VirtualBox',
        'VMware',
        'VBOX_',
        'SVGA3D',
        'GMR',
        'MOB',
        'nine_memory_helper\.c["'']',
        'include[/\\]git_sha1\.h'
    )
    foreach ($pattern in $forbidden) {
        Assert-True (-not [regex]::IsMatch($allSource, $pattern, `
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)) `
            "Original source contains forbidden donor/device token '$pattern'."
    }
}

Invoke-SelfTest 'Owned allocation failure paths are fail closed' {
    Assert-Match $implementation 'allocator == NULL \|\| size == 0\) return NULL;' `
        'Zero-size or missing-allocator rejection is absent.'
    Assert-Match $implementation 'if \(allocation == NULL\) return NULL;' `
        'Allocation-record failure is not rejected.'
    Assert-Match $implementation '\(SIZE_T\)size > \(SIZE_T\)-1 - \(GSW_NINE_ALIGNMENT - 1U\)' `
        'Alignment-reserve overflow is not rejected.'
    Assert-Match $implementation 'if \(memory == NULL\) \{[\s\S]*?HeapFree\(allocator->heap, 0, allocation\);[\s\S]*?return NULL;' `
        'Backing-allocation failure does not release its metadata.'
    Assert-Match $implementation 'if \(allocator->destroying\) \{[\s\S]*?HeapFree\(allocator->heap, 0, memory\);[\s\S]*?HeapFree\(allocator->heap, 0, allocation\);' `
        'Destruction-race rejection does not release both allocations.'
}

Invoke-SelfTest 'Owned buffers have bounded SIMD-safe alignment overhead' {
    Assert-Match $implementation '^#define GSW_NINE_ALIGNMENT 64U$' `
        'Owned-buffer alignment is not fixed at 64 bytes.'
    Assert-Match $implementation 'reserve = \(SIZE_T\)size \+ \(GSW_NINE_ALIGNMENT - 1U\);' `
        'Owned-buffer reserve is not bounded to alignment padding.'
    Assert-Match $implementation 'aligned_address = \(raw_address \+ \(GSW_NINE_ALIGNMENT - 1U\)\) &[\s\S]*?~\(\(uintptr_t\)GSW_NINE_ALIGNMENT - 1U\);' `
        'Owned-buffer address is not aligned without division.'
    Assert-Match $implementation 'allocation->heap_pointer = memory;' `
        'The original heap pointer is not retained for release.'
    Assert-Match $implementation 'HeapFree\(allocator->heap, 0, allocation->heap_pointer\);' `
        'Normal release does not free the original heap pointer.'
    Assert-Match $implementation 'HeapFree\(heap, 0, current->heap_pointer\);' `
        'Allocator destruction does not free the original heap pointer.'
}

Invoke-SelfTest 'Suballocation arithmetic is bounded' {
    Assert-Match $implementation 'offset < 0\) return NULL;' `
        'Negative offsets are not rejected.'
    Assert-Match $implementation 'parent->child_count == UINT_MAX' `
        'Child-count overflow is not rejected.'
    Assert-Match $implementation 'displacement >= parent->size' `
        'Owned-parent offset bounds are not enforced.'
    Assert-Match $implementation '\(uintptr_t\)displacement > UINTPTR_MAX - base' `
        'Pointer addition overflow is not rejected.'
    Assert-Match $implementation 'child->size = parent->size - displacement;' `
        'Owned suballocation extent is not bounded by its parent.'
}

Invoke-SelfTest 'Worker frees share the locked ownership path' {
    Assert-Match $implementation 'void nine_free_worker\([\s\S]*?\)\n\{\n    nine_free\(allocator, allocation\);\n\}' `
        'nine_free_worker does not use the common locked free path.'
    Assert-Match $implementation 'EnterCriticalSection\(&allocator->lock\);' `
        'Allocator ownership is not guarded by the Win32 lock.'
}

Invoke-SelfTest 'Resident pointer releases cannot unmap or free storage' {
    foreach ($name in @(
        'nine_pointer_weakrelease',
        'nine_pointer_strongrelease',
        'nine_pointer_delayedstrongrelease'
    )) {
        $pattern = '(?ms)^void ' + $name + '\(.*?^\}\n'
        $match = [regex]::Match($implementation, $pattern)
        Assert-True $match.Success "Could not isolate '$name'."
        Assert-True (-not [regex]::IsMatch($match.Value, `
            'HeapFree|VirtualFree|UnmapViewOfFile|CloseHandle')) `
            "$name releases resident storage."
    }
}

Invoke-SelfTest 'Allocator destruction drains owned storage and metadata' {
    Assert-Match $implementation 'allocator->destroying = 1;' `
        'Allocator destruction is not closed before draining.'
    Assert-Match $implementation 'while \(current != NULL\) \{[\s\S]*?GSW_NINE_OWNS_MEMORY[\s\S]*?HeapFree\(heap, 0, current->heap_pointer\);[\s\S]*?HeapFree\(heap, 0, current\);' `
        'Allocator destruction does not drain owned storage and every record.'
    Assert-Match $implementation 'DeleteCriticalSection\(&allocator->lock\);' `
        'Allocator destruction does not release its lock.'
}

Invoke-SelfTest 'External storage is never owned by the Adapter' {
    Assert-Match $implementation 'allocation->flags = GSW_NINE_EXTERNAL_ROOT;' `
        'External allocations are not distinguished from owned storage.'
    Assert-True (-not [regex]::IsMatch($implementation, `
        'allocation->flags\s*=\s*GSW_NINE_EXTERNAL_ROOT\s*\|\s*GSW_NINE_OWNS_MEMORY')) `
        'External storage is marked as owned.'
    Assert-Match $readme 'external-pointer Interface supplies no byte extent' `
        'The external extent limitation is not documented.'
}

Invoke-SelfTest 'Verifier accepts the canonical clean checkout under hostile Git environment' {
    $fixture = New-ModuleFixture
    $names = @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_CONFIG_COUNT', 'GIT_TRACE')
    $saved = @{}
    foreach ($name in $names) {
        $item = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        $saved[$name] = if ($null -eq $item) { $null } else { [string]$item.Value }
        Set-Item -LiteralPath "Env:$name" -Value 'hostile-test-value'
    }
    try {
        $output = @(Invoke-FixtureVerification $fixture)
        Assert-True ($output.Count -eq 1 -and
            $output[0] -like 'Verified original GSW Mesa source Module:*') `
            'Canonical verification did not return its source-only proof.'
    }
    finally {
        foreach ($name in $names) {
            if ($null -eq $saved[$name]) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -LiteralPath "Env:$name" -Value $saved[$name]
            }
        }
    }
}

Invoke-SelfTest 'Verifier rejects unknown lock properties' {
    $fixture = New-ModuleFixture
    $lock = Get-FixtureLockObject $fixture
    $lock | Add-Member -NotePropertyName unexpected -NotePropertyValue $false
    Write-TestJson (Join-Path $fixture 'interface-inputs.lock.json') $lock
    Assert-Throws { Invoke-FixtureVerification $fixture | Out-Null } `
        'fields do not match its schema'
}

Invoke-SelfTest 'Verifier rejects duplicate-case JSON properties' {
    $fixture = New-ModuleFixture
    $path = Join-Path $fixture 'interface-inputs.lock.json'
    $text = [IO.File]::ReadAllText($path)
    $text = $text.Replace(
        '  "status": "reviewed-permissive-interfaces",',
        "  `"Status`": `"reviewed-permissive-interfaces`",`n" +
        '  "status": "reviewed-permissive-interfaces",'
    )
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    Assert-Throws { Invoke-FixtureVerification $fixture | Out-Null } `
        "Duplicate JSON property 'status'"
}

Invoke-SelfTest 'Verifier rejects reordered permissive inputs' {
    $fixture = New-ModuleFixture
    $lock = Get-FixtureLockObject $fixture
    $first = $lock.inputs[0]
    $lock.inputs[0] = $lock.inputs[1]
    $lock.inputs[1] = $first
    Write-TestJson (Join-Path $fixture 'interface-inputs.lock.json') $lock
    Assert-Throws { Invoke-FixtureVerification $fixture | Out-Null } `
        'inputs[0].source_relative_path does not match its fixed value'
}

Invoke-SelfTest 'Verifier rejects changed input and exclusion identities' {
    $inputFixture = New-ModuleFixture
    $inputLockObject = Get-FixtureLockObject $inputFixture
    $inputLockObject.inputs[0].git_blob = '0000000000000000000000000000000000000000'
    Write-TestJson (Join-Path $inputFixture 'interface-inputs.lock.json') `
        $inputLockObject
    Assert-Throws { Invoke-FixtureVerification $inputFixture | Out-Null } `
        'inputs[0].git_blob does not match its fixed value'

    $excludedFixture = New-ModuleFixture
    $excludedLock = Get-FixtureLockObject $excludedFixture
    $excludedLock.excluded_implementation_paths[0] = `
        'mesa-23.1.x/src/mesa/main/context.c'
    Write-TestJson (Join-Path $excludedFixture 'interface-inputs.lock.json') `
        $excludedLock
    Assert-Throws { Invoke-FixtureVerification $excludedFixture | Out-Null } `
        'excluded_implementation_paths[0] does not match its fixed value'
}

Invoke-SelfTest 'Verifier rejects changed output descriptors and authorization claims' {
    $outputFixture = New-ModuleFixture
    $outputLock = Get-FixtureLockObject $outputFixture
    $outputLock.outputs[0].sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
    Write-TestJson (Join-Path $outputFixture 'interface-inputs.lock.json') $outputLock
    Assert-Throws { Invoke-FixtureVerification $outputFixture | Out-Null } `
        'outputs[0].sha256 does not match its fixed value'

    $claimFixture = New-ModuleFixture
    $claimLock = Get-FixtureLockObject $claimFixture
    $claimLock.claims.build_authorized = $true
    Write-TestJson (Join-Path $claimFixture 'interface-inputs.lock.json') $claimLock
    Assert-Throws { Invoke-FixtureVerification $claimFixture | Out-Null } `
        'claims.build_authorized must remain false'
}

Invoke-SelfTest 'Verifier rejects mutated original output bytes' {
    $fixture = New-ModuleFixture
    $path = Join-Path $fixture 'include\git_sha1.h'
    [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
    Assert-Throws { Invoke-FixtureVerification $fixture | Out-Null } `
        "Original GSW output 'include/git_sha1.h' descriptor mismatch"
}

Invoke-SelfTest 'Final stability seam rejects output and metadata drift' {
    $outputFixture = New-ModuleFixture
    $outputPath = Join-Path $outputFixture 'src\nine_memory_helper.c'
    Assert-Throws {
        Invoke-FixtureVerification $outputFixture -BeforeFinalCheck {
            [IO.File]::AppendAllText(
                $outputPath,
                "`n",
                [Text.UTF8Encoding]::new($false)
            )
        } | Out-Null
    } "Original GSW output 'src/nine_memory_helper.c' descriptor mismatch"

    $metadataFixture = New-ModuleFixture
    $metadataPath = Join-Path $metadataFixture 'interface-inputs.lock.json'
    Assert-Throws {
        Invoke-FixtureVerification $metadataFixture -BeforeFinalCheck {
            [IO.File]::AppendAllText(
                $metadataPath,
                " ",
                [Text.UTF8Encoding]::new($false)
            )
        } | Out-Null
    } 'Original GSW source metadata changed during verification'
}

Invoke-SelfTest 'Verifier rechecks every proof class after the stability seam' {
    $callbackIndex = $verifierText.IndexOf(
        'if ($null -ne $BeforeFinalCheck) { & $BeforeFinalCheck }',
        [StringComparison]::Ordinal
    )
    Assert-True ($callbackIndex -ge 0) 'Verifier final callback is missing.'
    $after = $verifierText.Substring($callbackIndex)
    Assert-Match $after 'Read-GswStrictJsonFileSnapshot -Path \$lockPath' `
        'Final seam does not recheck lock metadata.'
    Assert-Match $after 'Read-GswStrictJsonFileSnapshot -Path \$schemaPath' `
        'Final seam does not recheck schema metadata.'
    Assert-Match $after 'Assert-GswMesaCleanCheckout \$checkout\.Checkout' `
        'Final seam does not recheck checkout metadata.'
    Assert-Match $after 'foreach \(\$input in \$script:GswMesaExpectedInputs\)' `
        'Final seam does not recheck all immutable inputs.'
    Assert-Match $after 'foreach \(\$output in \$script:GswMesaExpectedOutputs\)' `
        'Final seam does not recheck all original outputs.'
}
}
finally {
    Remove-TestRoot $script:TestRoot
}

if ($script:Tests -eq 0) { throw 'No self-tests matched the requested filter.' }
if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Tests) original-source tests failed."
}
Write-Output "All $($script:Tests) original-source tests passed."

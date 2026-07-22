# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceRoot = Join-Path $repoRoot 'drivers\win98\gsw-sound'

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [string]$Message = 'Expected true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', observed '$Actual'." }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message = 'Required text is absent.')
    if ($Text -notmatch $Pattern) { throw "$Message Pattern: $Pattern" }
}

function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Message = 'Forbidden text is present.')
    if ($Text -match $Pattern) { throw "$Message Pattern: $Pattern" }
}

function Invoke-SelfTest {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures++
        [Console]::Error.WriteLine("FAIL $Name`: $($_.Exception.Message)")
    }
}

function Read-Source {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return [IO.File]::ReadAllText((Join-Path $repoRoot $RelativePath)).Replace("`r`n", "`n")
}

Invoke-SelfTest 'The original three-file source contract is complete and contains no binaries' {
    $required = @(
        'GSWSOUND.INF', 'gswsound.mak', 'README.md', 'draft-build-delivery-plan.md',
        'interface-inputs.lock.json', 'gsw-sound-build-plan.json',
        'build-support\configmg.h', 'build-support\mmdevldr.h', 'build-support\mmsystem.lbc',
        'build-support\vmm.h', 'build-support\vpicd.h',
        'build-support\vxdwraps.c', 'build-support\vxdwraps.h',
        'include\gswsound_types.h', 'include\gswsound_abi.h', 'include\gswsound_pm.h',
        'include\gswsound_telemetry.h',
        'drv\gswsound_drv.c', 'drv\gswsound_mixer.c', 'drv\gswsound_mixer.h',
        'drv\gswsound_pm16.c', 'drv\gswsound_pm16.h', 'drv\gswsound_win16_mmddk.h',
        'drv\gswsound.def', 'drv\gswsound.rc', 'vxd\gswsound_transport.c',
        'vxd\gswsound_transport.h', 'vxd\gswsound_ddk.h',
        'vxd\gswsound_vxd.c', 'vxd\gswsound.def'
    )
    foreach ($relativePath in $required) {
        Assert-True (Test-Path -LiteralPath (Join-Path $sourceRoot $relativePath) -PathType Leaf) `
            "Missing GSW-Sound source '$relativePath'."
    }
    $binaryExtensions = @('.drv', '.vxd', '.sys', '.dll', '.exe', '.obj', '.res', '.map', '.lib')
    $binaries = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object {
        $_.Extension.ToLowerInvariant() -in $binaryExtensions
    })
    Assert-Equal $binaries.Count 0 'Compiled artifacts must remain outside the tracked source tree.'
}

Invoke-SelfTest 'Every tracked source contract file is licensed and LF-stable' {
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
        if ($file.Extension -ceq '.json') {
            $metadata = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            Assert-Equal $metadata._spdx 'GPL-3.0-only' "Missing SPDX metadata in '$($file.FullName)'."
        }
        elseif ($file.Extension -ceq '.lbc') {
            Assert-Equal $file.Name 'mmsystem.lbc' "Unexpected untagged command file '$($file.FullName)'."
            $imports = @([IO.File]::ReadAllLines($file.FullName) | Where-Object { $_ -ne '' })
            Assert-Equal $imports.Count 5 'The reviewed MMSYSTEM import command must remain minimal.'
            foreach ($import in $imports) {
                Assert-Match $import '^\+\+[A-Za-z]+\.MMSYSTEM$' "Unexpected MMSYSTEM import '$import'."
            }
        }
        else {
            $firstLine = [IO.File]::ReadLines($file.FullName) | Select-Object -First 1
            Assert-Match $firstLine 'SPDX-License-Identifier: GPL-3\.0-only' "Missing SPDX line in '$($file.FullName)'."
        }
    }
    $attributes = Read-Source '.gitattributes'
    Assert-Match $attributes '(?m)^drivers/win98/gsw-sound/GSWSOUND\.INF text eol=lf$'
    foreach ($extension in @('c', 'def', 'h', 'json', 'lbc', 'mak', 'md', 'rc')) {
        Assert-Match $attributes "(?m)^drivers/win98/gsw-sound/\*\*/\*\.$extension text eol=lf$" `
            "Missing LF attribute for GSW-Sound .$extension files."
    }
}

Invoke-SelfTest 'Guest and host ABI v1 register maps agree exactly' {
    $guest = Read-Source 'drivers\win98\gsw-sound\include\gswsound_abi.h'
    $hostAbi = Read-Source 'src\audio\gsw_pcm.odin'
    $offsets = [ordered]@{
        ID = '00'; VERSION = '04'; CAPABILITIES = '08'; STATUS = '0C'; CONTROL = '10'
        SAMPLE_RATE = '14'; FORMAT = '18'; RING_GPA_LOW = '1C'; RING_GPA_HIGH = '20'
        RING_SIZE = '24'; RING_HEAD = '28'; RING_TAIL = '2C'; PERIOD_BYTES = '30'
        IRQ_ENABLE = '34'; IRQ_STATUS = '38'; POSITION_LOW = '3C'; POSITION_HIGH = '40'
        XRUN_COUNT = '44'; INVALID_COUNT = '48'; AVAILABLE_BYTES = '4C'; MASTER_GAIN = '50'
    }
    foreach ($entry in $offsets.GetEnumerator()) {
        $name = [regex]::Escape([string]$entry.Key)
        $hex = [regex]::Escape([string]$entry.Value)
        Assert-Match $guest "(?m)^#define GSW_PCM_REG_$name\s+0x${hex}UL$" "Guest offset mismatch for $($entry.Key)."
        Assert-Match $hostAbi "(?m)^GSW_PCM_REG_$name :: u32\(0x$hex\)$" "Host offset mismatch for $($entry.Key)."
    }
    Assert-Match $guest '(?m)^#define GSW_PCM_ID 0x31575347UL'
    Assert-Match $hostAbi '(?m)^GSW_PCM_ID :: u32\(0x3157_5347\)'
    Assert-Match $guest '(?m)^#define GSW_PCM_INTERFACE_VERSION\s+1UL$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_INTERFACE_VERSION :: u32\(1\)$'
    Assert-Match $guest '(?m)^#define GSW_PCM_DEFAULT_CONTROL_BASE 0xF1001000UL$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_DEFAULT_CONTROL_BASE :: u64\(0xF100_1000\)$'
    Assert-Match $guest '(?m)^#define GSW_PCM_CONTROL_SIZE\s+0x00001000UL$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_CONTROL_SIZE :: u64\(0x1000\)$'
    Assert-Match $guest '(?m)^#define GSW_PCM_RING_MIN_SIZE\s+4096UL$'
    Assert-Match $guest '(?m)^#define GSW_PCM_RING_MAX_SIZE\s+\(256UL \* 1024UL\)$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_RING_MIN_SIZE :: u32\(4 \* 1024\)$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_RING_MAX_SIZE :: u32\(256 \* 1024\)$'
    Assert-Match $guest '(?m)^#define GSW_PCM_RING_GPA_ALIGNMENT\s+16UL$'
    Assert-Match $hostAbi 'g\.ring_gpa & 0xF == 0'

    $capabilityBits = [ordered]@{
        PLAYBACK = 0; PCM_U8 = 1; PCM_S16 = 2; MONO = 3; STEREO = 4
        PERIOD_IRQ = 5; MASTER_GAIN = 6
    }
    foreach ($entry in $capabilityBits.GetEnumerator()) {
        Assert-Match $guest "(?m)^#define GSW_PCM_CAP_$($entry.Key)\s+\(1UL << $($entry.Value)\)$"
        Assert-Match $hostAbi "(?m)^GSW_PCM_CAP_$($entry.Key) :: u32\(1 << $($entry.Value)\)$"
    }
    Assert-Match $guest '(?m)^#define GSW_PCM_REQUIRED_CAPS GSW_PCM_CAPABILITIES$'
    foreach ($name in $capabilityBits.Keys) {
        Assert-Match $guest "(?s)#define GSW_PCM_CAPABILITIES \(.*GSW_PCM_CAP_$name"
        Assert-Match $hostAbi "(?s)GSW_PCM_CAPABILITIES ::.*GSW_PCM_CAP_$name"
    }

    $statusBits = [ordered]@{READY = 0; RUNNING = 1; BAD_CONFIG = 2; UNDERRUN = 3}
    foreach ($entry in $statusBits.GetEnumerator()) {
        Assert-Match $guest "(?m)^#define GSW_PCM_STATUS_$($entry.Key)\s+\(1UL << $($entry.Value)\)$"
        Assert-Match $hostAbi "(?m)^GSW_PCM_STATUS_$($entry.Key) :: u32\(1 << $($entry.Value)\)$"
    }
    Assert-Match $guest '(?m)^#define GSW_PCM_STATUS_ERROR\s+GSW_PCM_STATUS_BAD_CONFIG$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_STATUS_ERROR :: GSW_PCM_STATUS_BAD_CONFIG$'

    foreach ($entry in ([ordered]@{START = 0; STOP = 1; RESET = 2}).GetEnumerator()) {
        Assert-Match $guest "(?m)^#define GSW_PCM_CONTROL_$($entry.Key)\s+\(1UL << $($entry.Value)\)$"
        Assert-Match $hostAbi "(?m)^GSW_PCM_CONTROL_$($entry.Key) :: u32\(1 << $($entry.Value)\)$"
    }
    Assert-Match $guest '(?m)^#define GSW_PCM_CONTROL_MASK \(GSW_PCM_CONTROL_START \| GSW_PCM_CONTROL_STOP \| GSW_PCM_CONTROL_RESET\)$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_CONTROL_MASK :: GSW_PCM_CONTROL_START \| GSW_PCM_CONTROL_STOP \| GSW_PCM_CONTROL_RESET$'

    foreach ($entry in ([ordered]@{PERIOD = 0; UNDERRUN = 1; INVALID = 2}).GetEnumerator()) {
        Assert-Match $guest "(?m)^#define GSW_PCM_IRQ_$($entry.Key)\s+\(1UL << $($entry.Value)\)$"
        Assert-Match $hostAbi "(?m)^GSW_PCM_IRQ_$($entry.Key) :: u32\(1 << $($entry.Value)\)$"
    }
    Assert-Match $guest '(?m)^#define GSW_PCM_IRQ_MASK \(GSW_PCM_IRQ_PERIOD \| GSW_PCM_IRQ_UNDERRUN \| GSW_PCM_IRQ_INVALID\)$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_IRQ_MASK :: GSW_PCM_IRQ_PERIOD \| GSW_PCM_IRQ_UNDERRUN \| GSW_PCM_IRQ_INVALID$'

    Assert-Match $guest '(?m)^#define GSW_PCM_FORMAT_CHANNELS_MASK 0x000000FFUL$'
    Assert-Match $guest '(?m)^#define GSW_PCM_FORMAT_BITS_SHIFT\s+8$'
    Assert-Match $guest '(?m)^#define GSW_PCM_FORMAT_BITS_MASK\s+0x0000FF00UL$'
    Assert-Match $guest '(?m)^#define GSW_PCM_FORMAT_MASK \(GSW_PCM_FORMAT_CHANNELS_MASK \| GSW_PCM_FORMAT_BITS_MASK\)$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_FORMAT_CHANNELS_MASK :: u32\(0xFF\)$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_FORMAT_BITS_SHIFT :: 8$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_FORMAT_BITS_MASK :: u32\(0xFF << GSW_PCM_FORMAT_BITS_SHIFT\)$'
    Assert-Match $hostAbi '(?m)^GSW_PCM_FORMAT_MASK :: GSW_PCM_FORMAT_CHANNELS_MASK \| GSW_PCM_FORMAT_BITS_MASK$'

    foreach ($rate in @('11025', '22050', '44100', '48000')) {
        Assert-Match $guest "(?m)^#define GSW_PCM_RATE_$rate $rate`UL$"
        $underscored = $rate -replace '000$', '_000' -replace '100$', '_100' -replace '050$', '_050' -replace '025$', '_025'
        Assert-Match $hostAbi "g\.sample_rate == $underscored"
    }
    Assert-Match $guest '(?m)^#define GSW_PCM_MASTER_GAIN_UNITY\s+65536UL$'
}

Invoke-SelfTest 'INF binds only the playback-only VxD package shape' {
    $inf = Read-Source 'drivers\win98\gsw-sound\GSWSOUND.INF'
    $resource = Read-Source 'drivers\win98\gsw-sound\drv\gswsound.rc'
    foreach ($pattern in @(
        '(?m)^Signature="\$CHICAGO\$"$', '(?m)^Class=MEDIA$',
        '(?m)^DriverVer=07/19/2026,0\.1\.0\.3$',
        '(?m)^%DeviceDesc%=GSW\.Install,PCI\\VEN_FFFE&DEV_0003$',
        '(?m)^HKR,,DevLoader,,mmdevldr\.vxd$', '(?m)^HKR,,Driver,,GSWSOUND\.VXD$',
        '(?m)^HKR,Drivers,MIGRATED,,0$',
        '(?m)^HKR,Drivers\\wave,,,$', '(?m)^HKR,Drivers\\mixer,,,$',
        '(?m)^HKR,Drivers,SubClasses,,"wave,mixer"$',
        '(?m)^HKR,Drivers\\wave\\GSWSOUND\.DRV,Driver,,GSWSOUND\.DRV$',
        '(?m)^HKR,Drivers\\wave\\GSWSOUND\.DRV,Description,,%WaveDesc%$',
        '(?m)^HKR,Drivers\\mixer\\GSWSOUND\.DRV,Driver,,GSWSOUND\.DRV$',
        '(?m)^HKR,Drivers\\mixer\\GSWSOUND\.DRV,Description,,%MixerDesc%$',
        '(?m)^AddReg=GSW\.AddReg,GSW\.Telemetry\.AddReg$',
        '(?m)^\[GSW\.Telemetry\.AddReg\]$',
        '(?m)^HKLM,Software\\RETVRN99\\GSW-Sound,StartTelemetry,1,(?:[0-9A-F]{2},){31}[0-9A-F]{2}$'
    )) { Assert-Match $inf $pattern }
    Assert-Equal ([regex]::Matches($inf, '(?im)^GSWSOUND\.(?:DRV|VXD)(?:=1)?$')).Count 4 `
        'The copy list and source list must each name exactly the DRV and VxD.'
    Assert-NotMatch $inf '(?i)\.SYS\b|WDM|NTKERN|MIDI|capture|record|DirectSound|RunOnce|BLASTER='
    Assert-Match $resource '(?m)^FILEVERSION 0,1,0,3$'
    Assert-Match $resource '(?m)^PRODUCTVERSION 0,1,0,3$'
    Assert-Match $resource 'VALUE "FileVersion", "0\.1\.0\.3\\0"'
    Assert-Match $resource 'VALUE "ProductVersion", "0\.1\.0\.3\\0"'
}

Invoke-SelfTest 'DRV exposes queued PCM, WinMM loops, mixer controls, and fail-closed DirectSound' {
    $definition = Read-Source 'drivers\win98\gsw-sound\drv\gswsound.def'
    $driver = Read-Source 'drivers\win98\gsw-sound\drv\gswsound_drv.c'
    $mixer = Read-Source 'drivers\win98\gsw-sound\drv\gswsound_mixer.c'
    $compat = Read-Source 'drivers\win98\gsw-sound\drv\gswsound_win16_mmddk.h'
    foreach ($export in @('WEP @1', 'DriverProc @2', 'wodMessage @3', 'mxdMessage @4')) {
        Assert-Match $definition "(?im)^\s*$([regex]::Escape($export))(?:\s|$)"
    }
    Assert-Match $definition '(?im)^CODE PRELOAD FIXED$'
    Assert-Match $definition '(?im)^DATA PRELOAD FIXED SINGLE$'
    Assert-NotMatch $definition '(?i)widMessage|midMessage|modMessage|auxMessage'
    foreach ($message in @(
        'WODM_INIT', 'DRVM_EXIT', 'DRVM_DISABLE', 'DRVM_ENABLE',
        'WODM_GETNUMDEVS', 'WODM_GETDEVCAPS', 'WODM_OPEN', 'WODM_CLOSE',
        'WODM_PREPARE', 'WODM_UNPREPARE', 'WODM_WRITE', 'WODM_BREAKLOOP',
        'WODM_PAUSE', 'WODM_RESTART', 'WODM_RESET', 'WODM_GETPOS',
        'WODM_GETVOLUME', 'WODM_SETVOLUME'
    )) { Assert-Match $driver $message }
    Assert-Match $driver '(?s)switch \(message\) \{\s*case WODM_INIT:\s*case DRVM_EXIT:\s*case DRVM_DISABLE:\s*case DRVM_ENABLE:\s*return MMSYSERR_NOERROR;\s*\}\s*if \(device_id'
    Assert-Match $driver 'if \(message == DRV_QUERYDRVENTRY\) return MMSYSERR_NOTSUPPORTED;'
    Assert-Match $driver 'if \(message == DRV_QUERYDSOUNDIFACE\) return MMSYSERR_NOTSUPPORTED;'
    Assert-Match $driver '(?s)case DRV_OPEN:\s*case DRV_CLOSE:\s*case DRV_ENABLE:'
    Assert-Match $driver 'timeBeginPeriod'
    Assert-Match $driver 'timeEndPeriod'
    Assert-Match $driver 'if \(result == MMSYSERR_NOERROR\) gsw_wave\.paused = 0;'
    Assert-Match $driver 'position = \(\(gsw_u64\)request\.position_high << 32\) \| request\.position_low;'
    Assert-Match $driver 'return gsw_mixer_get_wave_volume\(volume\);'
    Assert-Match $driver 'return gsw_mixer_set_wave_volume\(volume\);'
    Assert-Match $driver 'BOOL FAR PASCAL LibMain'
    foreach ($pattern in @(
        'buffer_linear', 'buffer_bytes', 'header_flags', 'loop_count',
        'queue_loop_open', 'loop_active', 'loop_remaining', 'loop_release_pending',
        'loop_break_requested', 'break_next_loop', 'gsw_complete_loop',
        'header->dwLoops == 0', 'WHDR_BEGINLOOP', 'WHDR_ENDLOOP',
        'case CALLBACK_EVENT:',
        'header->dwFlags \|= WHDR_INQUEUE', 'header->dwFlags \|= WHDR_DONE',
        'gsw_snapshot_buffer_linear', 'gsw_wave_user_valid'
    )) { Assert-Match $driver $pattern }
    Assert-Match $driver '\*linear > 0xFFFFFFFFUL - \(bytes - 1\)'
    Assert-NotMatch $driver 'bytes > 0x10000UL - offset'
    Assert-Match $driver 'GSW_DRIVER_CALLBACK_FLAGS\(flags\)'
    Assert-Match $driver '__loadds wodMessage'
    Assert-NotMatch $driver '_export'
    Assert-NotMatch $driver 'queue_submit'
    Assert-NotMatch $driver '#include\s*[<"]mmddk\.h[>"]|build-support'

    foreach ($pattern in @(
        'GSW_MIXER_LINE_SPEAKERS', 'GSW_MIXER_LINE_WAVEOUT',
        'GSW_MIXER_CONTROL_MASTER', 'GSW_MIXER_CONTROL_WAVE',
        'MIXERLINE_COMPONENTTYPE_DST_SPEAKERS',
        'MIXERLINE_COMPONENTTYPE_SRC_WAVEOUT',
        'MIXERCONTROL_CONTROLTYPE_VOLUME', 'MIXERCONTROL_CONTROLF_UNIFORM',
        'MM_MIXM_LINE_CHANGE', 'MM_MIXM_CONTROL_CHANGE',
        'GSW_DRIVER_CALLBACK_FLAGS\(flags\)', 'callback_type != CALLBACK_EVENT',
        'details->cChannels != 1',
        '\(gsw_u32\)master \* \(gsw_u32\)wave \+ \(GSW_MIXER_VOLUME_MAX / 2\)',
        'effective \+ \(effective >= 0x8000UL \? 1 : 0\)',
        'volume & 0xFFFFUL'
    )) { Assert-Match $mixer $pattern }
    $mapGain = {
        param([uint32]$Master, [uint32]$Wave)
        $effective = [uint32](([uint64]$Master * [uint64]$Wave + 32767) / 65535)
        return [uint32]($effective + $(if ($effective -ge 0x8000) { 1 } else { 0 }))
    }
    Assert-Equal (& $mapGain 0 65535) 0 'Muted master must map to Q16.16 zero.'
    Assert-Equal (& $mapGain 65535 0) 0 'Muted wave source must map to Q16.16 zero.'
    Assert-Equal (& $mapGain 65535 65535) 65536 'Full master and wave must map to Q16.16 unity.'
    foreach ($message in @(
        'MXDM_INIT', 'DRVM_EXIT', 'DRVM_DISABLE', 'DRVM_ENABLE',
        'MXDM_GETNUMDEVS', 'MXDM_GETDEVCAPS', 'MXDM_OPEN', 'MXDM_CLOSE',
        'MXDM_GETLINEINFO', 'MXDM_GETLINECONTROLS',
        'MXDM_GETCONTROLDETAILS', 'MXDM_SETCONTROLDETAILS'
    )) { Assert-Match $mixer $message }
    Assert-Match $mixer '(?s)switch \(message\) \{\s*case MXDM_INIT:\s*case DRVM_EXIT:\s*case DRVM_DISABLE:\s*case DRVM_ENABLE:\s*return MMSYSERR_NOERROR;\s*\}\s*gsw_mixer_initialize\(\);'
    Assert-Match $mixer 'local\.cDestinations = 1;'
    Assert-Match $mixer 'line->cConnections = 1;'
    Assert-NotMatch $mixer '#include\s*[<"]mmddk\.h[>"]|build-support'

    foreach ($pattern in @(
        'public-domain MinGW-w64 mmddk\.h/mmeapi\.h', '#pragma pack\(push, 1\)',
        '#define DRVM_INIT\s+100', '#define DRVM_EXIT\s+101',
        '#define DRVM_DISABLE\s+102', '#define DRVM_ENABLE\s+103',
        '#define WODM_INIT\s+DRVM_INIT', '#define MXDM_INIT\s+DRVM_INIT',
        'typedef UINT GSW_MMRESULT;', 'typedef UINT GSW_HMIXER;',
        '#define CALLBACK_EVENT 0x00050000UL',
        'GSW_DRIVER_CALLBACK_FLAGS', 'CALLBACK_TYPEMASK\) >> 16',
        'sizeof\(GSW_WAVEFORMATEX\) == 18', 'sizeof\(GSW_WAVEOPENDESC\) == 20',
        'sizeof\(GSW_MIXEROPENDESC\) == 18', 'sizeof\(GSW_MIXERCAPS\) == 46',
        'sizeof\(GSW_MIXERLINE\) == 166', 'sizeof\(GSW_MIXERCONTROL\) == 148',
        'sizeof\(GSW_MIXERLINECONTROLS\) == 24',
        'sizeof\(GSW_MIXERCONTROLDETAILS\) == 24'
    )) { Assert-Match $compat $pattern }
    Assert-NotMatch $compat '#include\s*[<"]mmddk\.h[>"]'
    Assert-NotMatch $driver '(?i)widMessage|midMessage|modMessage|DirectSoundCreate|EAX|DirectSound3D'
}

Invoke-SelfTest 'VxD uses MMDEVLDR lifecycle, ConfigMgr resources, telemetry, and shared VPICD' {
    $definition = Read-Source 'drivers\win98\gsw-sound\vxd\gswsound.def'
    $ddk = Read-Source 'drivers\win98\gsw-sound\vxd\gswsound_ddk.h'
    $vxd = Read-Source 'drivers\win98\gsw-sound\vxd\gswsound_vxd.c'
    $transport = Read-Source 'drivers\win98\gsw-sound\vxd\gswsound_transport.c'
    $wrappers = Read-Source 'drivers\win98\gsw-sound\build-support\vxdwraps.c'
    Assert-Match $definition '(?im)^\s*GSWSOUND_DDB\s+@1\s*$'
    foreach ($pattern in @(
        '_PageAllocate', '_LinPageLock', 'GSW_SOUND_PTE_USER', 'GSW_SOUND_PTE_WRITE',
        'request_bytes != sizeof\(local_request\)', 'GSW_SOUND_RING3_LIMIT',
        'GSW_SOUND_MAX_SUBMIT_BYTES', 'PNP_New_Devnode',
        'gsw_mmdevldr_register_device_driver', 'gsw_configmg_get_allocated_resources',
        'GSW_SOUND_CONFIG_START', 'GSW_SOUND_CONFIG_STOP', 'GSW_SOUND_CONFIG_REMOVE',
        'gsw_configuration_handler_thunk', 'GSW_SOUND_DIAGNOSTIC_POLLING_FALLBACK 0',
        'VPICD_OPT_CAN_SHARE', 'descriptor\.Hw_Int_Proc', 'gsw_vpicd_virtualize_irq',
        'gsw_vpicd_physically_unmask', 'gsw_vpicd_physically_mask',
        'gsw_vpicd_force_default_behavior', 'gsw_vpicd_phys_eoi',
        'DDB GSWSOUND_DDB', 'stc', 'clc'
    )) { Assert-Match $vxd $pattern }
    Assert-Match $vxd '(?m)^#define GSW_SOUND_RING3_LIMIT\s+0xC0000000UL$'
    Assert-Match $vxd '(?s)address == 0 \|\| address >= GSW_SOUND_RING3_LIMIT.*address > 0xFFFFFFFFUL - \(bytes - 1\).*address \+ bytes > GSW_SOUND_RING3_LIMIT'
    Assert-Match $vxd '(?s)GSW_SOUND_PTE_PRESENT \| GSW_SOUND_PTE_USER.*_LinPageLock\(range->first_page, range->page_count, 0\).*if \(writable\) required \|= GSW_SOUND_PTE_WRITE.*\(pte & required\) != required.*_LinPageUnLock'
    $ring3RangeValid = {
        param([uint64]$Address, [uint64]$Bytes)
        $limit = [uint64]3221225472 # 0xC0000000
        return $Bytes -ne 0 -and $Address -ne 0 -and $Address -lt $limit -and
            $Address + $Bytes -le 4294967296L -and $Address + $Bytes -le $limit
    }
    Assert-True (& $ring3RangeValid 2147483632 16) 'Private ring-3 memory must remain valid.'
    Assert-True (& $ring3RangeValid 2147483648 64) 'The Win16 shared arena must be valid.'
    Assert-True (& $ring3RangeValid 3221225456 16) 'The last shared-arena bytes must be valid.'
    Assert-True (-not (& $ring3RangeValid 3221225456 17)) 'A range crossing into ring 0 must fail.'
    Assert-True (-not (& $ring3RangeValid 3221225472 1)) 'The ring-0 arena must fail.'
    foreach ($pattern in @(
        '#include <configmg\.h>', '#include <mmdevldr\.h>', '#include <vpicd\.h>',
        'GSW_SOUND_DDK_RESOURCES',
        'GSW_SOUND_DDK_ALLOCATION', 'GSW_SOUND_DDK_MAX_MEMORY_WINDOWS\s+4',
        'GSW_SOUND_DDK_MMIO_ALIGNMENT\s+0x1000UL', 'GSW_SOUND_DDK_IRQ',
        'GSW_SOUND_CONFIG_START\s+0x00000001UL',
        'GSW_SOUND_CONFIG_STOP\s+0x00000002UL',
        'GSW_SOUND_CONFIG_TEST\s+0x00000003UL',
        'GSW_SOUND_CONFIG_REMOVE\s+0x00000004UL'
    )) { Assert-Match $ddk $pattern }
    Assert-Match $vxd '(?s)static CONFIGRET __cdecl gsw_register_devnode\(.*gsw_u32 load_type.*GSW_SOUND_TELEMETRY_PNP.*devnode_value,\s*load_type.*if \(devnode == 0\).*gsw_sound_ddk_register_devnode\(devnode, gsw_configuration_handler_thunk\);.*return CR_SUCCESS;'
    Assert-NotMatch $vxd 'load_type\s*!=|load_type\s*=='
    Assert-Match $vxd '(?s)gsw_configuration_handler_thunk.*push \[ebp \+ 24\].*push \[ebp \+ 8\].*call gsw_configuration_handler_impl.*add esp, 20.*clc.*ret'
    Assert-Match $vxd '(?s)gsw_control_new_devnode:\s*pushad\s*push edx\s*push ebx\s*call gsw_register_devnode\s*add esp, 8\s*/\* PNP_New_Devnode is handled with CF set and CONFIGRET in EAX\. \*/\s*mov \[esp \+ 28\], eax\s*popad\s*stc\s*ret\s*gsw_control_exit:'
    Assert-NotMatch $vxd '(?s)gsw_control_new_devnode:.*?test eax, eax.*?gsw_control_exit:'
    Assert-NotMatch $vxd '(?s)gsw_control_new_devnode:.*?\bclc\b.*?gsw_control_exit:'
    foreach ($pattern in @(
        'GSW_CMCONFIG_RAW', 'sizeof\(GSW_CMCONFIG_RAW\) == 216',
        'VxDCall\(MMDEVLDR, Register_Device_Driver\)',
        'VxDJmp\(CONFIGMG, _Get_Alloc_Log_Conf\)',
        'VMMJmp\(_RegOpenKey\)', 'VMMJmp\(_RegSetValueEx\)',
        'VMMJmp\(_RegCloseKey\)',
        'VxDCall\(VPICD, Virtualize_IRQ\)', 'VxDCall\(VPICD, Phys_EOI\)',
        'VxDCall\(VPICD, Physically_Mask\)', 'VxDCall\(VPICD, Physically_Unmask\)',
        'VxDCall\(VPICD, Force_Default_Behavior\)',
        'configuration\.memory_count > GSW_SOUND_DDK_MAX_MEMORY_WINDOWS',
        'configuration\.irq_count > GSW_SOUND_DDK_MAX_IRQS'
    )) { Assert-Match $wrappers $pattern }
    Assert-NotMatch ($wrappers + $ddk) 'CONFIGMG.*Register_Device_Driver|gsw_configmg_register_device_driver'
    $mmdevldr = Read-Source 'drivers\win98\gsw-sound\build-support\mmdevldr.h'
    Assert-Match $mmdevldr '(?m)^#define MMDEVLDR_DEVICE_ID\s+0x044A$'
    Assert-Match $mmdevldr '(?m)^#define MMDEVLDR__Register_Device_Driver\s+0x0000$'
    $telemetry = Read-Source 'drivers\win98\gsw-sound\include\gswsound_telemetry.h'
    foreach ($checkpoint in @('PNP', 'REGISTER', 'START', 'RESOURCE', 'MAP', 'PAGE', 'BIND', 'IRQ', 'MODE', 'SUCCESS')) {
        Assert-Match $telemetry "GSW_SOUND_TELEMETRY_$checkpoint"
    }
    Assert-Match $telemetry 'sizeof\(GSW_SOUND_START_TELEMETRY\) == 32'
    Assert-Match $vxd 'gsw_vmm_reg_set_value_ex'
    foreach ($pattern in @(
        'GSW_PCM_REG_ID', 'GSW_PCM_INTERFACE_VERSION', 'GSW_PCM_REQUIRED_CAPS',
        'GSW_PCM_RING_MIN_SIZE', 'gsw_sound_power_of_two', 'GSW_PCM_CONTROL_RESET',
        'GSW_PCM_REG_IRQ_STATUS', 'GSW_PCM_IRQ_MASK', 'GSW_PCM_REG_MASTER_GAIN',
        'GSW_SOUND_DEFAULT_PERIOD_FRAMES\s+256UL',
        'gsw_sound_transport_handle_interrupt', 'transport->interrupt_mode',
        'transport->pending_irq_status', 'transport->period_irq_count',
        'transport->underrun_irq_count', 'transport->invalid_irq_count',
        'gsw_sound_position_add', 'if \(\*low < previous\) \(\*high\)\+\+',
        'gsw_sound_position_before'
    )) { Assert-Match $transport $pattern }
    Assert-Match $transport 'transport->interrupt_mode \? GSW_PCM_IRQ_MASK : 0'
    Assert-Match $transport 'GSW_PCM_REG_STATUS, GSW_PCM_STATUS_UNDERRUN'
    Assert-Match $transport 'GSW_PCM_STATUS_BAD_CONFIG'
    Assert-Match $transport '(?s)gsw_sound_service_irq.*GSW_PCM_REG_IRQ_STATUS, irq_status.*return 1;'
    Assert-Match $vxd '(?s)gsw_sound_transport_handle_interrupt.*gsw_vpicd_phys_eoi'
    Assert-NotMatch $vxd '(?i)GSW_SOUND_PCI_CONFIG_ADDRESS|0CF8h|0CFCh|gsw_pci_read32'
    Assert-NotMatch ($vxd + $ddk) '(?i)VPICD_Thunk|IRQHANDLE|CMCONFIGHANDLER'
    Assert-NotMatch $transport 'gsw_u64|<<\s*32|>>\s*32'
}

Invoke-SelfTest 'Build makefile keeps all outputs external and consumes only reviewed support' {
    $makefile = Read-Source 'drivers\win98\gsw-sound\gswsound.mak'
    foreach ($required in @('WATCOM', 'GSW_SOUND_OUT')) {
        Assert-Match $makefile "!ifndef $required"
    }
    Assert-NotMatch $makefile 'GSW_DDK_INCLUDE|GSW_DDK_LIB'
    foreach ($output in @('GSWSOUND.INF', 'GSWSOUND.DRV', 'GSWSOUND.VXD')) {
        Assert-Match $makefile "\$\(GSW_SOUND_OUT\)\\$output"
    }
    Assert-Match $makefile 'system win_vxd dynamic'
    Assert-Match $makefile 'system windows dll initglobal memory'
    Assert-NotMatch $makefile 'system windows dll initinstance'
    Assert-Match $makefile 'option nodefaultlibs'
    foreach ($pattern in @(
        'gswsound_mixer\.obj', 'vxdwraps\.obj', 'mmsystem\.lbc', '\$\(WLIB\)',
        'fixlink\.exe -40', 'fixlink\.exe -vxd32', 'libfile .*libentry\.obj',
        'library .*windows\.lib', 'library .*clibl\.lib',
        '-i="\$\(WATCOM\)\\h\\win" -i="\$\(WATCOM\)\\h"',
        '-i="\$\(WATCOM\)\\h\\nt" -i="\$\(WATCOM\)\\h\\win" -i="\$\(WATCOM\)\\h"'
    )) { Assert-Match $makefile $pattern }
    Assert-NotMatch $makefile '(?i)curl|wget|git clone|http://|https://'
}

Invoke-SelfTest 'Hash-locked twin-build plan covers every deterministic input and canonical output' {
    $planPath = Join-Path $sourceRoot 'gsw-sound-build-plan.json'
    $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
    Assert-Equal $plan._spdx 'GPL-3.0-only'
    Assert-Equal $plan.schema 1
    Assert-Equal $plan.status 'ready-for-manual-install'
    Assert-Equal @($plan.source_files).Count 26
    Assert-Equal @($plan.repository_files).Count 12
    Assert-Equal @($plan.outputs).Count 3
    $upstreamLock = @($plan.repository_files | Where-Object {
        $_.relative_path -ceq 'drivers/win98/upstream.lock.tsv'
    })
    Assert-Equal $upstreamLock.Count 1
    Assert-Equal "$($upstreamLock[0].bytes):$($upstreamLock[0].sha256)" `
        '1786:9ac835757077b5f908113c84e966d06a8edbbc57b6491fc480b081ba5f21d70d'
    foreach ($record in @($plan.source_files)) {
        $path = Join-Path $sourceRoot ([string]$record.relative_path).Replace('/', '\')
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing planned source '$($record.relative_path)'."
        Assert-Equal (Get-Item -LiteralPath $path).Length ([long]$record.bytes) `
            "Planned byte count differs for '$($record.relative_path)'."
        Assert-Equal (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() `
            ([string]$record.sha256) "Planned hash differs for '$($record.relative_path)'."
    }
    foreach ($record in @($plan.repository_files)) {
        $path = Join-Path $repoRoot ([string]$record.relative_path).Replace('/', '\')
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing planned metadata '$($record.relative_path)'."
        Assert-Equal (Get-Item -LiteralPath $path).Length ([long]$record.bytes) `
            "Metadata byte count differs for '$($record.relative_path)'."
        Assert-Equal (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() `
            ([string]$record.sha256) "Metadata hash differs for '$($record.relative_path)'."
    }
    $expectedOutputs = [ordered]@{
        'GSWSOUND.INF' = '1370:7f79a999e8200dde6d1d3aac0e31c4163c58f38b39b57249d4122529626fec53'
        'GSWSOUND.DRV' = '12104:b2fe52450982cf35129b474bfa84bacda2feecd4179e2d00f4fde8f07aa8bd7d'
        'GSWSOUND.VXD' = '9476:410bbaea37876d0c1edc9734f03c16c948ab51b8eeb866cd698ec682a644fb51'
    }
    foreach ($record in @($plan.outputs)) {
        Assert-True $expectedOutputs.Contains([string]$record.name) "Unexpected output '$($record.name)'."
        Assert-Equal "$($record.bytes):$($record.sha256)" $expectedOutputs[[string]$record.name]
    }

    $builder = Read-Source 'scripts\build-win98-gsw-sound.ps1'
    $vxdNormalizer = Read-Source 'scripts\normalize-win98-vxd-ddb-entry.ps1'
    foreach ($pattern in @(
        'verify-win98-gsw-sound-interfaces\.ps1', "@\('build-a', 'build-b'\)",
        'normalize-win98-vxd-ddb-entry\.ps1',
        'normalize-win16-version-date\.ps1', 'verify-win98-gsw-sound-binaries\.ps1',
        'Twin-build comparison differs', 'Output root must be absent',
        "PackageNames = @\('GSWSOUND\.INF', 'GSWSOUND\.DRV', 'GSWSOUND\.VXD'\)"
    )) { Assert-Match $builder $pattern }
    Assert-NotMatch $builder '(?i)curl|wget|git clone|http://|https://'
    foreach ($pattern in @(
        'EntryExported = 0x01', 'EntryShared = 0x02',
        "Read-U32 .*'entry-table offset'", "bundleType -ne 3",
        'entryFlags -ne \$script:EntryExported',
        'GSWSOUND_DDB has unsupported LE entry flags',
        'WriteByte\(\[byte\]\$normalizedFlags\)', 'Flush\(\$true\)'
    )) { Assert-Match $vxdNormalizer $pattern }
    Assert-NotMatch $vxdNormalizer '(?i)curl|wget|git clone|http://|https://'
}

Invoke-SelfTest 'Sound delivery remains unavailable and absent from the real payload manifest' {
    $plan = Read-Source 'src\win98imageprep\driver_delivery_plan.odin'
    $inventory = Read-Source 'drivers\win98\payload-inventory.schema.tsv'
    $manifest = Read-Source 'drivers\win98\payload-manifest.schema.tsv'
    $delivery = Read-Source 'drivers\win98\gsw-sound\draft-build-delivery-plan.md'
    Assert-Match $plan '\{package_id = GSW_SOUND_PACKAGE_ID, phase = \.PnP, hardware_id = GSW_SOUND_HARDWARE_ID\}'
    Assert-NotMatch $inventory '(?m)^gsw-sound\t'
    Assert-NotMatch $manifest '(?m)^gsw-sound\t'
    Assert-Match $delivery 'Package_Content_Unavailable'
}

if ($script:Failures -ne 0) {
    throw "$script:Failures GSW-Sound source contract test(s) failed."
}
Write-Host 'All GSW-Sound source contract tests passed.'

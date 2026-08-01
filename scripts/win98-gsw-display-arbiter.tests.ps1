# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$CompilerPath,
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$overlayRoot = Join-Path $repoRoot 'drivers\win98\derived\vmdisp9x-gsw\overlay'
$arbiterSource = Join-Path $overlayRoot 'gsw_display_arbiter.c'

if (-not (Test-Path -LiteralPath $arbiterSource -PathType Leaf)) {
    throw "Missing display arbiter source: $arbiterSource"
}

if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    $compiler = Get-Command gcc -ErrorAction SilentlyContinue
    if ($null -eq $compiler) {
        $compiler = Get-Command clang -ErrorAction SilentlyContinue
    }
    if ($null -eq $compiler) {
        throw 'A C compiler is required. Pass -CompilerPath or place gcc/clang on PATH.'
    }
    $CompilerPath = $compiler.Source
}

$CompilerPath = (Resolve-Path -LiteralPath $CompilerPath).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $tempBase = if (Test-Path -LiteralPath 'V:\tmp' -PathType Container) {
        'V:\tmp'
    } else {
        [IO.Path]::GetTempPath()
    }
    $OutputRoot = Join-Path $tempBase (
        'retvrn99-gsw-display-arbiter-' + [Guid]::NewGuid().ToString('N')
    )
}

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$repoPrefix = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($OutputRoot.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Display arbiter test output must be outside the repository.'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$testSource = Join-Path $OutputRoot 'gsw_display_arbiter_tests.c'
$testExe = Join-Path $OutputRoot 'gsw_display_arbiter_tests.exe'

$testProgram = @'
/* SPDX-License-Identifier: GPL-3.0-only */

#include <stdio.h>
#include <string.h>

#include "gsw_display_arbiter.h"

#define STATE(l, a, t, w, o, x, g) { l, a, t, w, o, x, g }
#define EVENT(k, v, o, n, f) { k, v, o, n, f }

typedef struct Test_Step {
    const char *name;
    int reset;
    GSW_Display_Arbiter initial;
    GSW_Display_Event event;
    GSW_Display_Arbiter expected;
    GSW_Display_Action action;
    GSW_Display_Dispi_Trap trap;
    unsigned short vbe_ax;
    unsigned char fault;
} Test_Step;

static const Test_Step steps[] = {
    {
        "firmware request before registration", 1,
        STATE(GSW_DISPLAY_COLD, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 41, 0, 0x13, 0),
        STATE(GSW_DISPLAY_COLD, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 0),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "device ready", 0, STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_READY, 0, 0, 0, 0),
        STATE(GSW_DISPLAY_READY, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 0),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "duplicate device ready", 0, STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_READY, 0, 0, 0, 0),
        STATE(GSW_DISPLAY_READY, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 0),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "PhysicalEnable registers after early notifications are dropped", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 0, 100, 0),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "PhysicalEnable fresh POST commits initial desktop", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "register Windows VM", 1,
        STATE(GSW_DISPLAY_READY, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 0, 100, 0),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate registration", 0, STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 0, 100, 0),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "mode 13 has no special authority", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 200, 0, 0x13, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 0, 100, 0),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "Windows desktop programming is authorized", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 100, 0, 0x13, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 0, 100, 0),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "unauthorized VBE set is rejected", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VBE_MODE_SET, 200, 0, 0x118, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 0, 100, 0),
        GSW_DISPLAY_REJECT_VBE, GSW_DISPLAY_DISPI_INTERCEPT,
        GSW_DISPLAY_VBE_REJECT_AX, 0
    },
    {
        "desktop programming completes", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate desktop completion", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "stable desktop consumes another VM", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 200, 0, 0x03, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "stable desktop rejects ConfigMgr VBE", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VBE_MODE_SET, 100, 0, 0x118, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_REJECT_VBE, GSW_DISPLAY_DISPI_INTERCEPT,
        GSW_DISPLAY_VBE_REJECT_AX, 0
    },
    {
        "stable desktop consumes ConfigMgr legacy mode", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 100, 0, 0x13, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "stable desktop consumes ConfigMgr mode 3", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 100, 0, 0x03, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "stable desktop consumes foreign DISPI", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DISPI_ACCESS, 200, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "stable desktop consumes ConfigMgr DISPI", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DISPI_ACCESS, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 1),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "VDD pre authorizes foreground target", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND, 200, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 200, 1),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "old owner is blocked during transition", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 100, 0, 0x13, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 200, 1),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "foreground target can program mode 13", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 200, 0, 0x13, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 200, 1),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate VDD pre", 0, STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND, 200, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 200, 1),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "mismatched POST preserves transition", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND, 201, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 200, 1),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "fresh physical owner validates mismatched POST", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND, 201, 201, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 201, 0, 2),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate foreground POST", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND, 201, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 201, 0, 2),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "VDD pre restores desktop", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 201, 100, 2),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "Windows restore access is authorized", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VBE_MODE_SET, 100, 0, 0x118, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 201, 100, 2),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "desktop POST commits authority", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 3),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "foreign DirectDraw begin records fault", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 200, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 3),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "foreign DirectDraw end records fault", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 200, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 3),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "DirectDraw exclusive begin authorizes Windows", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 3),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate DirectDraw begin", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 3),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "DirectDraw transition forwards Windows DISPI", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DISPI_ACCESS, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 3),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "DirectDraw desktop programming completes", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 4),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "late DirectDraw end leaves stable desktop closed", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 4),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate late DirectDraw end", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 4),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "stale DirectDraw end cannot seize foreign foreground", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 200, 0, 4),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 200, 0, 4),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "stable completion after late DirectDraw end", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 4),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 4),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "fresh physical owner authorizes foreground VM", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 5),
        EVENT(GSW_DISPLAY_EVENT_PHYSICAL_OWNER, 300, 300, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 6),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate physical owner observation", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_PHYSICAL_OWNER, 300, 300, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 6),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "stale physical owner is ignored", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_PHYSICAL_OWNER, 301, 301, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 6),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "mismatched physical owner records fault", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_PHYSICAL_OWNER, 301, 302, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 6),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "standalone Windows owner preserves foreground authority", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_PHYSICAL_OWNER, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 6),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "desktop POST reconciles fresh Windows owner", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "foreground transition before disable", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND, 400, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 400, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "driver disabling cancels transition", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DRIVER_DISABLING, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "duplicate disabling", 0, STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DRIVER_DISABLING, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "foreign duplicate disabling is rejected", 1,
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        EVENT(GSW_DISPLAY_EVENT_DRIVER_DISABLING, 101, 0, 0, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 1
    },
    {
        "zero VM cannot begin disabling", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 400, 7),
        EVENT(GSW_DISPLAY_EVENT_DRIVER_DISABLING, 0, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 400, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "foreign VM cannot begin disabling", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 400, 7),
        EVENT(GSW_DISPLAY_EVENT_DRIVER_DISABLING, 101, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 400, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "pre-registration disabling is rejected", 1,
        STATE(GSW_DISPLAY_READY, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DRIVER_DISABLING, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_READY, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 0),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 1
    },
    {
        "DirectDraw end after disabling does not wait", 1,
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "disabling bypasses DISPI", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DISPI_ACCESS, 999, 0, 0, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "disabling permits Windows mode 3", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 100, 0, 0x03, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "disabling permits Windows mode 83", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 100, 0, 0x83, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "disabling blocks Windows mode 13", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 100, 0, 0x13, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "disabling blocks another VM mode 3", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 101, 0, 0x03, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "disabling rejects VBE mode set", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VBE_MODE_SET, 100, 0, 0x118, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 7),
        GSW_DISPLAY_REJECT_VBE, GSW_DISPLAY_DISPI_BYPASS,
        GSW_DISPLAY_VBE_REJECT_AX, 0
    },
    {
        "system exit returns authority to firmware", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_SYSTEM_EXIT, 0, 0, 0, 0),
        STATE(GSW_DISPLAY_EXITED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 8),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "duplicate exit", 0, STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_EXIT, 0, 0, 0, 0),
        STATE(GSW_DISPLAY_EXITED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 8),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "late DirectDraw begin after exit is ignored", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_EXITED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 8),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "late DirectDraw end after exit is ignored", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_EXITED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 8),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "DirectDraw programming failure setup", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 80),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 80),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "reconfigure failure preserves stable desktop", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 80),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate stable reconfigure failure", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 80),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "failed programming rejects contradictory desktop POST", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 200, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 80),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "desktop restore failure setup", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 90),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 300, 100, 90),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "failed desktop restore preserves foreground", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 90),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate foreground restore failure is idempotent", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 90),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "failed restore rejects contradictory desktop POST", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 300, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 90),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "firmware request after exit", 1,
        STATE(GSW_DISPLAY_EXITED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 8),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 101, 0, 0x13, 0),
        STATE(GSW_DISPLAY_EXITED, GSW_DISPLAY_FIRMWARE,
              GSW_DISPLAY_TRANSITION_NONE, 0, 0, 0, 8),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "fresh owner can validate POST without PRE", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 9),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND, 500, 500, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 500, 0, 10),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "POST without PRE or fresh owner is a fault", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 9),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND, 500, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 9),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "physical owner validates a different POST target", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 500, 600, 9),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 10),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "disabling cancels desktop reconfigure", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 20),
        EVENT(GSW_DISPLAY_EVENT_DRIVER_DISABLING, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 20),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 0
    },
    {
        "exact POST rejects contradictory fresh owner", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 500, 30),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND, 500, 501, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 500, 30),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "duplicate POST rejects contradictory fresh owner", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 500, 0, 30),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND, 500, 501, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 500, 0, 30),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "Windows observation cannot cancel foreground transition", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 500, 30),
        EVENT(GSW_DISPLAY_EVENT_PHYSICAL_OWNER, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 500, 30),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "GDI VDD pre begins bounded desktop programming", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 40),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 40),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate GDI VDD pre", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 40),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "bounded ConfigMgr reconfigure forwards Windows VBE", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VBE_MODE_SET, 100, 0, 0x118, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 40),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "bounded ConfigMgr reconfigure blocks foreign BIOS", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 200, 0, 0x13, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 40),
        GSW_DISPLAY_CONSUME, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "GDI programming success waits for owner POST", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 40),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate GDI programming success", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 40),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "GDI desktop POST rejects contradictory owner", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 200, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 40),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "GDI fresh desktop POST commits restoration", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 41),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "desktop failure preserves foreground transition", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 200, 50),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 200, 50),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "desktop success preserves foreground conflict", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 200, 50),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "fresh Windows owner validates conflicting desktop POST", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 51),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "desktop POST rejects contradictory owner during programming", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 60),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 200, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 60),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "old foreground observation preserves desktop transition", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 300, 100, 70),
        EVENT(GSW_DISPLAY_EVENT_PHYSICAL_OWNER, 300, 300, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 300, 100, 70),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake DirectDraw begin", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 100),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 100),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake VDD pre refines DirectDraw begin", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 100, 100),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake duplicate DirectDraw begin preserves VDD transition", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 100, 100),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake mode 13 programming", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_BIOS_MODE_SET, 100, 0, 0x13, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 100, 100),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake foreground POST", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 101),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake DirectDraw end opens desktop reconfigure", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 101),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake desktop PRE refines DirectDraw end", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 101),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake desktop programming", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VBE_MODE_SET, 100, 0, 0x118, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 101),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake desktop programming waits for owner POST", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 101),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake fresh desktop POST commits restoration", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 102),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "WinQuake late DirectDraw end stays closed", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 102),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "DirectDraw end preserves same-Windows desktop transition", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 110),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TO_WINDOWS_DESKTOP, 100, 100, 100, 110),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "same-Windows foreground DirectDraw begin is idempotent", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 120),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 120),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "foreign foreground rejects Windows DirectDraw begin", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 200, 0, 121),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 200, 0, 121),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "DirectDraw begin-only setup", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 122),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 122),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "DirectDraw end closes begin-only transition", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 122),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "DirectDraw end preserves foreground VDD transition", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 100, 123),
        EVENT(GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TO_FOREGROUND_VGA, 100, 100, 100, 123),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "foreground PRE rejects conflicting reconfigure target", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 130),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND, 200, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 130),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "desktop PRE rejects conflicting reconfigure target", 1,
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 200, 200, 140),
        EVENT(GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 200, 200, 140),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "matching Windows VM re-enables disabled driver", 1,
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 150),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 150),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate registration during re-enable", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 150),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "re-enabled fresh POST commits desktop ownership", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 151),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "duplicate re-enabled desktop POST is idempotent", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_VDD_POST_DESKTOP, 100, 100, 0,
              GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 151),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "zero VM cannot re-enable disabled driver", 1,
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 160),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 0, 0, 0, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 160),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 1
    },
    {
        "mismatched VM cannot re-enable disabled driver", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 200, 0, 0, 0),
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_TRANSITION_NONE, 100, 100, 0, 160),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_BYPASS, 0, 1
    },
    {
        "matching re-enable recovers after rejected attempts", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 160),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "mismatched duplicate registration preserves re-enable", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 200, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_WINDOWS_DESKTOP,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 100, 100, 160),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 1
    },
    {
        "failed re-enable preserves foreground authority", 1,
        STATE(GSW_DISPLAY_DISABLING, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 170),
        EVENT(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_DESKTOP_RECONFIGURE, 100, 300, 100, 170),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    },
    {
        "failed re-enable programming keeps foreground generation", 0,
        STATE(0, 0, 0, 0, 0, 0, 0),
        EVENT(GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED, 100, 0, 0, 0),
        STATE(GSW_DISPLAY_REGISTERED, GSW_DISPLAY_FOREGROUND_VGA,
              GSW_DISPLAY_TRANSITION_NONE, 100, 300, 0, 170),
        GSW_DISPLAY_FORWARD, GSW_DISPLAY_DISPI_INTERCEPT, 0, 0
    }
};

static int state_equal(
    GSW_Display_Arbiter left,
    GSW_Display_Arbiter right
)
{
    return left.lifecycle == right.lifecycle &&
           left.authority == right.authority &&
           left.transition == right.transition &&
           left.windows_vm == right.windows_vm &&
           left.authority_vm == right.authority_vm &&
           left.transition_vm == right.transition_vm &&
           left.generation == right.generation;
}

static void print_state(const char *label, GSW_Display_Arbiter state)
{
    fprintf(
        stderr,
        "%s lifecycle=%d authority=%d transition=%d windows=%lu "
        "owner=%lu target=%lu generation=%lu\n",
        label,
        (int)state.lifecycle,
        (int)state.authority,
        (int)state.transition,
        state.windows_vm,
        state.authority_vm,
        state.transition_vm,
        state.generation
    );
}

int main(void)
{
    GSW_Display_Arbiter state;
    GSW_Display_Result result;
    unsigned long index;
    unsigned long count;

    memset(&state, 0, sizeof(state));
    count = (unsigned long)(sizeof(steps) / sizeof(steps[0]));
    for (index = 0; index < count; index++) {
        if (steps[index].reset) {
            state = steps[index].initial;
        }
        result = gsw_display_step(state, steps[index].event);
        if (!state_equal(result.next, steps[index].expected) ||
            result.action != steps[index].action ||
            result.dispi_trap != steps[index].trap ||
            result.vbe_ax != steps[index].vbe_ax ||
            result.protocol_fault != steps[index].fault) {
            fprintf(stderr, "FAIL step %lu: %s\n", index + 1, steps[index].name);
            print_state("actual", result.next);
            print_state("expected", steps[index].expected);
            fprintf(
                stderr,
                "actual action=%d trap=%d ax=%04X fault=%u\n",
                (int)result.action,
                (int)result.dispi_trap,
                (unsigned int)result.vbe_ax,
                (unsigned int)result.protocol_fault
            );
            return 1;
        }
        state = result.next;
    }

    printf("PASS: %lu display arbiter table steps\n", count);
    return 0;
}
'@

[IO.File]::WriteAllText(
    $testSource,
    $testProgram + [Environment]::NewLine,
    [Text.Encoding]::ASCII
)

$compileArguments = @(
    '-std=c89',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-pedantic',
    '-I', $overlayRoot,
    $arbiterSource,
    $testSource,
    '-o', $testExe
)

& $CompilerPath @compileArguments
if ($LASTEXITCODE -ne 0) {
    throw "Display arbiter test compilation failed with exit code $LASTEXITCODE."
}

& $testExe
if ($LASTEXITCODE -ne 0) {
    throw "Display arbiter table test failed with exit code $LASTEXITCODE."
}

Write-Host "Display arbiter test artifact: $testExe"

<!-- SPDX-License-Identifier: GPL-3.0-only -->

# GSW-Sound Windows 98 smoke test

`GSWSMOKE.EXE` is a no-CRT Win32 console test for the manually installed
GSW-Sound Windows 98 wave and mixer driver. It deliberately does not exercise
DirectSound.

Run it from a Windows 98 command prompt after installing `GSWSOUND.INF` and
restarting the guest:

```bat
GSWSMOKE.EXE
ECHO Result: %ERRORLEVEL%
```

The program selects devices named `RETVRN99 GSW-Sound` and
`RETVRN99 GSW-Sound Mixer`; it will not silently test another sound device. It
enumerates both device classes, briefly changes and restores the Wave and
Master mixer levels, plays all 16 advertised PCM combinations, then exercises
finite and interrupted loops, pause/position/restart, and reset. Successful
format tests produce a short sequence of tones.

Before WinMM enumeration, the program reports the latest persistent VxD start
checkpoint from `HKLM\Software\RETVRN99\GSW-Sound`. The checkpoint, outcome,
sequence, and two hexadecimal details remain useful even when the driver did
not load far enough to expose a wave or mixer endpoint.

The same compact result stream is written to `GSWSOUND.LOG`. A successful run
ends with `GSWSOUND_SMOKE PASS` and exit code zero. Preserve the log from a
failed run because the telemetry and individual `FAIL` lines identify the first
guest-native contract that still needs work.

To rebuild with the repository's hash-locked MinGW32 toolchain:

```powershell
./build.ps1 -ToolchainRoot D:\src\retvrn99-win98\toolchains
```

The output is `out\GSWSMOKE.EXE`. The build uses a Windows 4.0 PE32 console
boundary, imports only `ADVAPI32.dll`, `KERNEL32.dll`, and `WINMM.DLL`, and
inserts no timestamp.

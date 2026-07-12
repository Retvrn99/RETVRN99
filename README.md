# Mate98

HLE Virtual Machine for Windows 98 / MS-DOS 7.1. Games-first.

License: GPL-3.0-only

## Status — M1

Boots stock SeaBIOS under hardware virtualization, synthesizes a FAT32
C: drive live from a host folder, and is ready to boot MS-DOS 7.1 to an
interactive `C:\>` prompt in an SDL3 window (you provide the DOS system
files — see below).

## Requirements

- Windows x86_64 with the **Windows Hypervisor Platform** feature enabled
  (Settings → Optional features → More Windows features → check
  "Windows Hypervisor Platform", reboot).
- [Odin](https://odin-lang.org) (dev-2026-07 or newer) on `PATH`.
- `SDL3.dll` next to `mate98.exe` (copy from `<odin>/vendor/sdl3`).
- NASM only if you modify the boot code in `assets/vbr/`.

## Build

```
.\build.ps1          # produces mate98.exe
odin build src/smoke -out:smoke.exe   # headless smoke test
```

Tests: `odin test src/<pkg> -define:ODIN_TEST_THREADS=1` for each of
`machine`, `vga`, `hv`, `disk`, `fat32`, `host`.

## Run

1. Put your own MS-DOS 7.1 system files (`IO.SYS`, `MSDOS.SYS`,
   `COMMAND.COM` — e.g. from your Windows 98 install media) into
   `%USERPROFILE%\.mate98\c_drive\`. Anything else you drop in that folder
   appears on the guest's C: drive; guest writes come back as host files.
2. `.\mate98.exe` — GUI with menu (Machine / Media / Debug).
   `--console` runs headless with the SeaBIOS log on stdout;
   `--no-disk` boots without the C: drive.
3. Floppy images (1.44MB IMG) mount via Media → Mount Floppy.

`smoke.exe` boots to `C:\>`, types `DIR`, and checks the output
(skips politely when WHPX or the DOS files are missing).

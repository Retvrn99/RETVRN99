![RETVRN99 logo](assets/logo.png)

HLE Virtual Machine built around Windows 98.

License: GPL-3.0-only

## Status — Windows 98 installation foundation

Boots stock SeaBIOS under hardware virtualization, synthesizes a FAT32
C: drive live from a host folder, boots MS-DOS 7.1 to an interactive
`C:\>` prompt, and exposes read-only ISO images through an ATAPI CD-ROM.

## Requirements

- Windows x86_64 with the **Windows Hypervisor Platform** feature enabled
  (Settings → Optional features → More Windows features → check
  "Windows Hypervisor Platform", reboot).
- [Odin](https://odin-lang.org) (dev-2026-07 or newer) on `PATH`.
- `SDL3.dll` next to `retvrn99.exe` (copy from `<odin>/vendor/sdl3`).
- NASM only if you modify the boot code in `assets/vbr/`.
- Rebuilding the vendored SeaBIOS firmware additionally requires a Linux GCC,
  binutils, Make, and Python 3 toolchain. Windows builds use WSL.

## Build

```
.\build.ps1          # produces retvrn99.exe
.\build.ps1 -Firmware # rebuilds SeaBIOS first (WSL Debian by default)
odin build src/smoke -out:smoke.exe   # headless smoke test
```

Use `-WslDistro <name>` with `-Firmware` when the toolchain is installed in a
different WSL distribution. Normal application builds use the checked-in ROM
and do not require the firmware toolchain.

Tests: `odin test src/<pkg> -define:ODIN_TEST_THREADS=1` for each of
`profile`, `machine`, `vga`, `hv`, `disk`, `fat32`, `host`, `win98media`,
and `win98prep`.

## Run

1. Put your own MS-DOS 7.1 system files (`IO.SYS`, `MSDOS.SYS`,
   `COMMAND.COM` — e.g. from your Windows 98 install media) into
   `%USERPROFILE%\.retvrn99\c_drive\`. Anything else you drop in that
   folder appears on the guest's C: drive; guest writes come back as
   host files.
2. `.\retvrn99.exe` — GUI with menu (Machine / Media / Debug).
   `--console` runs headless with the SeaBIOS log on stdout;
   `--no-disk` boots without the C: drive.
   Machine → CPU Speed selects the roughly paced GSW-886 mode (default)
   or Turbo. Both expose the same Pentium III-class CPU and 1 GHz TSC.
3. Floppy images (1.44MB IMG) mount via Media → Mount Floppy. ISO images
   mount read-only via Media → Mount CD-ROM.
4. Machine → Install Windows 98 validates a user-selected Second Edition
   ISO in any language, stages its WIN98 flat beside `c_drive`, copies it
   to `C:\GSWSETUP`, mounts the disc, reboots, and launches the localized
   Setup executable with the media's MSBATCH template. Windows Setup can
   still request user-owned licensing details; GSW guest drivers are a
   post-install step.

Runtime state lives beside `c_drive`: `settings.json` stores host-visible
preferences and `cmos.bin` stores battery-backed guest CMOS state. The
folder-backed system disk rejects FDISK, FORMAT, and other writes that
would replace its synthesized partition or FAT32 layout.

For the known DOS-only seed, RETVRN99 replaces only the four-byte
placeholder `MSDOS.SYS` with `Logo=0` and `BootGUI=0`. This avoids the
Windows boot-logo handoff and produces the initial `C:\>` prompt correctly;
an existing configured `MSDOS.SYS` is never rewritten. The Windows 98
launcher re-enables GUI boot before starting Setup.

`smoke.exe` boots to `C:\>`, types `DIR`, and checks the output
(skips politely when WHPX or the DOS files are missing).

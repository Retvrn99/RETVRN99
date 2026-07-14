![RETVRN99 logo](assets/logo.png)

HLE Virtual Machine built around Windows 98.

License: GPL-3.0-only

## Status — Windows 98 installation foundation

Boots stock SeaBIOS under hardware virtualization, synthesizes a FAT32
C: drive live from a host folder, boots MS-DOS 7.1 to an interactive
`C:\>` prompt, exposes optical-disc images through an ATAPI DVD/CD-ROM drive, and
provides legacy VGA plus unaccelerated Bochs VBE 2.0 graphics through a
vendored Bochs VGABIOS.

The fixed platform currently exposes 256 MiB of PC133-class RAM, UDMA/66,
and private GSW CPU/chipset identities calibrated to an Athlon K7 700 / AMD-750
capability envelope. It does not identify itself as AMD hardware.

## Requirements

- Windows x86_64 with the **Windows Hypervisor Platform** feature enabled
  (Settings → Optional features → More Windows features → check
  "Windows Hypervisor Platform", reboot).
- [Odin](https://odin-lang.org) (dev-2026-07 or newer) on `PATH`.
- `SDL3.dll` next to `retvrn99.exe` (copy from `<odin>/vendor/sdl3`).
- NASM only if you modify the boot code in `assets/vbr/`.
- Rebuilding the vendored firmware additionally requires a Linux GCC, binutils,
  Make, Python 3, and dev86 (`bcc` and `as86`) toolchain. Windows builds use
  WSL; dev86 is required only for Bochs VGABIOS.

## Build

```
.\build.ps1          # produces retvrn99.exe
.\build.ps1 -Firmware # rebuilds SeaBIOS and Bochs VGABIOS (WSL Debian by default)
odin build src/smoke -out:smoke.exe   # headless smoke test
```

Use `-WslDistro <name>` with `-Firmware` when the toolchain is installed in a
different WSL distribution. Normal application builds use the checked-in ROM
and do not require the firmware toolchain.

Tests: `odin test src/<pkg> -define:ODIN_TEST_THREADS=1` for each of
`profile`, `machine`, `vga`, `hv`, `disk`, `fat32`, `host`, `hosttime`,
`audio`, `acceptance`, `win98media`, and `win98prep`; run `odin test src`
for the root integration tests. Workload-runner self-tests live in
`scripts/run-workload-gates.tests.ps1`.

## Run

1. For an ordinary DOS profile, put your own MS-DOS 7.1 system files
   (`IO.SYS`, `MSDOS.SYS`, and `COMMAND.COM`) into
   `%USERPROFILE%\.retvrn99\c_drive\`. Anything else you drop in that
   folder appears on the guest's C: drive; guest writes come back as
   host files. A fresh Windows installation does not require this manual
   step: RETVRN99 extracts the matching system files from the mounted
   Windows 98 boot floppy.
2. `.\retvrn99.exe` — GUI with menu (Machine / Media / Debug).
   `--console` runs headless with the SeaBIOS log on stdout;
   `--no-disk` boots without the C: drive.
   Machine → CPU Speed selects the roughly paced GSW-886 mode (default)
   or Turbo. Both expose the same GSW-886 CPU and 700 MHz TSC; the default
   mode is paced to an Athlon K7 700-class throughput envelope.
3. Floppy images (1.44MB IMG) mount via Media → Mount Floppy. ISO images
   mount read-only via Media → Mount DVD/CD-ROM.
4. To start a fresh installation, mount the matching Windows 98 SE boot
   floppy and choose Machine → Install Windows 98. RETVRN99 validates the
   selected Second Edition ISO, stages its WIN98 flat beside `c_drive`,
   extracts the DOS boot seed, and installs a one-shot launcher. The next
   HDD boot runs the media's localized Setup executable directly with a
   normalized `MSBATCH.INF` answer file; no prompt detection or injected typing is
   involved. The answer file retains the source media's locale and keyboard
   selection. Licensing details may still be requested, and GSW guest
   drivers remain a post-install step in this slice.

The boot seed is checked as a structurally valid FAT12 image containing
`IO.SYS`, `MSDOS.SYS`, and `COMMAND.COM`, and is accepted only while
preparing an independently validated Windows 98 SE ISO. `IO.SYS` has no stable,
language-neutral Second Edition build marker; exact hashes and the numeric
string found in some `COMMAND.COM` builds would reject legitimate localized,
OEM, or updated SE boot disks. RETVRN99 therefore requires the user to mount
the matching SE boot floppy rather than guessing compatibility from those
brittle signatures.

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

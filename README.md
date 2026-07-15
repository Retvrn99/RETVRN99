![RETVRN99 logo](assets/logo.png)

RETVRN99 is an experimental, games-first virtual machine for Windows 98 SE and
MS-DOS 7.1. It uses hardware virtualization for the CPU and emulates a small,
fixed late-1990s PC around it.

Bring your own Windows 98 media. RETVRN99 does not include Microsoft system
files or installation images.

## Current status

RETVRN99 is under active development and is not ready for important data. The
current Windows build boots the bundled SeaBIOS and user-supplied MS-DOS 7.1
system files, provides a folder-backed FAT32 system disk, reads common CD/DVD
image formats, and can run an unattended Windows 98 SE installation. The
install and driver paths are still being stabilized.

The current virtual machine exposes:

- 256 MiB of PC133-class RAM.
- A GSW-886 CPU identity with a 700 MHz TSC. The default mode is paced to an
  Athlon K7 700-class target; Turbo removes the throughput cap.
- An AMD-751 northbridge and AMD-756 ISA/IDE southbridge.
- A 2 GiB folder-backed FAT32 disk on a UDMA/66 (Ultra DMA mode 4) IDE
  controller.
- A 1.44 MB floppy drive and an ATAPI 10x DVD / 52x CD-ROM drive.
- The guest-visible GSW VGA device, with legacy VGA and Bochs VBE available
  while the Windows GSW driver is being finished.
- PC-speaker and CD-audio output. The planned Windows and DOS sound devices are
  not complete yet.

## Requirements

To run RETVRN99:

- x86-64 Windows with an AVX2-capable processor.
- The Windows Hypervisor Platform optional feature enabled.
- `SDL3.dll` beside `retvrn99.exe`.
- Your own operating-system and application media.

Windows Hypervisor Platform is available under **Windows Features**. Windows
may ask for a restart after it is enabled.

To build from source, install [Odin](https://odin-lang.org) dev-2026-07 or
newer and make sure `odin` is on `PATH`. NASM is needed only when modifying the
boot code under `assets/vbr/`.

## Build and run

```powershell
.\build.ps1
.\retvrn99.exe
```

`build.ps1` produces `retvrn99.exe`. Copy `SDL3.dll` from the Odin SDL3 vendor
directory into the repository root before running it.

The default profile lives in `%USERPROFILE%\.retvrn99`. To keep a machine
separate, pass a different profile directory:

```powershell
.\retvrn99.exe "--profile-root:D:\VMs\retvrn99-win98"
```

The current menu is:

- **Machine** — start or stop the VM, pause it, or exit.
- **Emulation** — choose **GSW886 @700MHz** or **Turbo (Uncapped)**, change
  scaling, enter full screen, select a visual shader, and view the hotkeys.
- **Tools** — start the experimental Windows 98 installer through **Install
  Windows 98**.
- **Help** — open the project page or About dialog. Third-party licenses and
  acknowledgements are linked from About.

Hold the Windows/Super key and Shift, then press `F1` to release captured
input, `F3` for full screen, `F5` for Turbo, or `F9`/`F10` for volume.

## Install Windows 98 SE

The reproducible install route is currently the headless runner. Use a new
profile, a Windows 98 SE ISO, and its matching 1.44 MB boot image:

```powershell
.\retvrn99.exe `
  "--install-windows:D:\Media\win98se.iso" `
  "--floppy:D:\Media\win98se-boot.img" `
  "--profile-root:D:\VMs\retvrn99-win98" `
  --accept-until=desktop
```

The installer validates the SE media, extracts its localized Setup files,
builds the FAT32 system disk, and launches Setup from the hard disk. Active
installs run in Turbo mode. Setup uses its normal hardware detection and only
guest-requested resets; the runner stops after the first Explorer desktop has
remained graphical and responsive for ten minutes.

Retail, OEM, and localized Second Edition media are intended to work, but this
matrix is still being tested. The boot image must match the installation media.
`IO.SYS` does not contain a reliable language-neutral SE marker, so RETVRN99
checks the disk structure and required DOS files instead of guessing from a
short version string.

After installation, start the same profile without `--install-windows` to use
the normal GUI:

```powershell
.\retvrn99.exe "--profile-root:D:\VMs\retvrn99-win98"
```

The GUI media and install-finalization controls are still being wired into the
new menu. For now, use the headless command above for a clean installation.

## Storage and media

The guest C: drive is synthesized from the profile's `c_drive` directory.
Files placed there appear in the guest, and supported guest writes are
reconciled back to host files. RETVRN99 rejects FDISK, FORMAT, and other writes
that would replace the synthesized partition or FAT32 layout.

Optical images are mounted read-only. The current backend supports ISO images,
raw Mode 1 images, and single-file CUE/BIN sets with Mode 1 or audio tracks.
Floppy images must be exactly 1.44 MB; floppy writes are not persisted yet.

Runtime state sits beside `c_drive`: `settings.json` stores the selected CPU
mode, `cmos.bin` stores guest CMOS state, and active sparse-write journals are
kept in `.retvrn99-journal` until they can be reconciled safely.

## FAQ

### Why is SMARTDrive disabled during Windows 98 Setup?

The generated `GSWSETUP.BAT` passes `/C`, which tells Setup not to load
SMARTDrive. RETVRN99's C: drive is backed by the host filesystem and does not
model rotational seek latency, while the host already caches the underlying
files. Skipping a second DOS-era cache avoids guest-side buffering overhead.
This affects Setup only; installed Windows 98 still uses its normal
protected-mode disk cache.

### Where are my guest files?

The default C: drive is `%USERPROFILE%\.retvrn99\c_drive`. A custom
`--profile-root` keeps its own `c_drive` inside that profile.

### Why do I need a boot image as well as the ISO?

RETVRN99 uses the matching Windows 98 SE boot disk to seed the localized
MS-DOS 7.1 system files. Those files differ across languages and editions, so
substituting an unrelated boot disk can produce a broken installation.

### Why do FDISK and FORMAT fail?

The FAT32 disk is a live view of a host folder, not a raw disk-image file.
Replacing its partition table or filesystem would break that mapping, so those
layout-changing writes are intentionally blocked.

## Development

Normal builds use checked-in ROM images built from the vendored SeaBIOS and
Bochs VGABIOS sources. Rebuilding SeaBIOS requires WSL with Linux GCC,
binutils, Make, and Python 3. Bochs VGABIOS also requires dev86 (`bcc` and
`as86`):

```powershell
.\build.ps1 -Firmware
.\build.ps1 -Firmware -WslDistro Debian
```

Run each package separately, then run the root integration tests:

```powershell
$packages = @(
  'profile', 'persona', 'machine', 'vga', 'hv', 'disk', 'fat32', 'host',
  'hosttime', 'audio', 'acceptance', 'win98media', 'win98prep'
)
foreach ($package in $packages) {
  odin test "src/$package" -define:ODIN_TEST_THREADS=1
}
odin test src -define:ODIN_TEST_THREADS=1
pwsh -File scripts/run-workload-gates.tests.ps1
```

The headless runner can also save deterministic install evidence:

```powershell
.\retvrn99.exe `
  "--install-windows:<iso>" `
  "--floppy:<boot.img>" `
  "--profile-root:<scratch-profile>" `
  --accept-until=desktop `
  --setup-diagnostics=hardware `
  "--artifacts:<artifact-directory>" `
  "--result-json:<result.json>"
```

Media, installed profiles, registry exports, traces, and screenshots belong in
ignored scratch directories and must not be committed.

## License

GPL-3.0-only.

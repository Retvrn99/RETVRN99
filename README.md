![RETVRN99 logo](assets/logo.png)

RETVRN99 is an experimental, games-first virtual machine for Windows 98 SE and
MS-DOS 7.1. It uses hardware virtualization for the CPU and emulates a small,
fixed late-1990s PC around it.

Bring your own Windows 98 media. RETVRN99 does not include Microsoft system
files or installation images.

## Current status

RETVRN99 is under active development. Do not trust it with important data yet.
The Windows build boots the bundled SeaBIOS, uses a raw FAT32 image for its C:
drive, reads common CD and DVD image formats, and has a guided Windows 98 SE
installer. The install and driver paths are still being stabilized.

The virtual machine currently exposes:

- 256 MiB of PC133-class RAM.
- A GSW-886 CPU identity with a 700 MHz TSC. The default mode is paced to an
  Athlon K7 700-class target; Turbo removes the throughput cap.
- An AMD-751 northbridge and AMD-756 ISA/IDE southbridge.
- A FAT32 hard drive on a UDMA/66 (Ultra DMA mode 4) IDE controller.
- A 1.44 MB floppy drive and an ATAPI 10x DVD / 52x CD-ROM drive.
- The guest-visible GSW VGA device, with legacy VGA and Bochs VBE available
  while the Windows GSW driver is being finished. Its guarded v2 transport and
  host-resident SDL_GPU path have an exact, bounded developer triangle grammar
  with dynamic full-surface targets, ticketed physical completion, and two
  frames in flight, but the normal guest persona still advertises no 3D
  acceleration.
- PC-speaker and CD-audio output, plus fixed-resource Sound Blaster 16 digital
  audio at `220h`/IRQ5/DMA1+5 and an OPL3-compatible device at `388h`, including
  the Sound Blaster FM aliases at `220h`-`223h`. The OPL
  path includes 2-operator and 4-operator voices, envelopes, feedback, eight
  waveforms, rhythm mode, stereo routing, and timers. The Windows GSW-SOUND
  driver does not ship yet.
## Requirements

- x86-64 Windows with an AVX2-capable processor.
- The Windows Hypervisor Platform optional feature enabled.
- A Vulkan 1.1-capable GPU and display driver.
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

The build produces `retvrn99.exe` and its internal `retvrn99-fat32.exe`
storage helper. Keep the two executables together. Copy `SDL3.dll` from the
Odin SDL3 vendor directory into the repository root before running RETVRN99.

The GUI opens with the machine stopped. This lets you choose media and a hard
drive before any virtual hardware starts. Pass `--start` if you want RETVRN99
to start the machine as soon as the window is ready:

```powershell
.\retvrn99.exe --start
```

Renderer developers can add `--gsw3d-proof` to attach the guarded
POSITIONT/D3DCOLOR transport profile. It preserves the captured command and
fixed-function state grammar while allowing bounded target dimensions, clear
RGB, and three already-validated vertices. It retains at most two physical GPU
submissions and is not a game-compatible acceleration mode.

Run `odin run tools\gsw3d-proof-smoke -thread-count:8` to render the proof
through Vulkan at 640x480 and 1600x1200, exercise mixed-size frames in flight,
download the idle offscreen targets, and validate repeated CRCs plus orientation
and channel-order anchors. The 640x480 path also crosses the SDL compositor.
This developer gate is the only GSW3D texture readback path; normal presentation
remains host-resident.

The default profile is `%USERPROFILE%\.retvrn99`. To keep a machine separate,
pass another profile directory:

```powershell
.\retvrn99.exe "--profile-root:D:\VMs\retvrn99-win98"
```

RETVRN99 does not create a hard drive automatically. On first launch, either
choose **Tools > Install Windows 98...** for the guided route or use **Tools >
Create Hard Drive...** for a manual setup. The complete walkthrough is in the
[user guide](docs/user-guide.md).

> **Installing Windows 98 by hand?** Two different old bugs matter here.
> **GSW-886** helps with the CPU-speed bug. It does nothing for Windows 98's TLB
> invalidation bug, which depends on the real host CPU and can appear even
> inside a VM. On an affected host, patch the installation files with
> [Patcher9x](https://github.com/JHRobotics/patcher9x) before running Setup.
> RETVRN99's guided installer applies its TLB compatibility fix automatically.

## Menus

- **Machine** starts, stops, pauses, or resets the virtual machine.
- **Hard Drive** selects an existing image or opens the stopped-machine C:
  drive browser.
- **Media** mounts or ejects floppy and CD/DVD images.
- **Emulation** controls CPU speed, scaling, full screen, shaders, and hotkeys.
- **Tools** creates a hard drive and starts or abandons a Windows 98 install.
- **Help** opens the documentation, project page, and About dialog.

Selecting or browsing a hard drive is disabled while the machine is running.
Media can normally be changed while stopped or hot-swapped while running. An
active Windows installation locks its disk and media until it finishes or you
choose **Abandon Windows 98 Installation...**.

Hold Windows/Super and Shift, then press `F1` to release captured input, `F3`
for full screen, `F5` for Turbo, or `F9`/`F10` for volume.

## Hard drives

RETVRN99 stores the guest C: drive in a standard raw `.img` file. The creation
tool suggests `%USERPROFILE%\.retvrn99\c_drive.img` and 20 GiB, but you can put
the image on another drive and choose any whole size from 1 through 127 GiB.

New images are sparse when the host filesystem supports it. A 20 GiB image
therefore has a 20 GiB logical capacity without immediately consuming 20 GiB
of host space. Its allocated size grows as the guest writes data. If sparse
files are unavailable at the chosen location, RETVRN99 shows the full
allocation cost and asks before continuing.

You do not need to mount the image in Windows. Stop the machine and choose
**Hard Drive > Browse C drive...** to import, export, rename, or delete files.
Edits remain staged until you choose **Apply**. **Discard** leaves the image as
it was when the browser opened.

The FAT32 partition layout is protected because RETVRN99's installer and file
browser depend on it. Guest programs can use the filesystem normally, but
FDISK, FORMAT, and writes that replace the MBR or reserved FAT32 layout are
blocked.

## Installing Windows 98 SE

Choose **Tools > Install Windows 98...** while the machine is stopped. If no
hard drive is selected, the installer first opens the creation tool. It then
asks for your Windows 98 SE disc image and shows a final disk and media summary
before changing the image.

Spanish and Korean OEM media with a compatible embedded 1.44 MB El Torito boot
image can supply their own localized DOS files. English retail media normally
needs a matching FAT12 boot-floppy image, which RETVRN99 asks you to select.
Do not substitute a boot disk from another language or edition.

Preparation is transactional: cancelling before the installation transaction
commits leaves the hard drive unchanged. Compatible standard MBR/FAT32 images
are adopted inside that same transaction: their BPB geometry is preserved, and
the RETVRN99 format marker is written only after the new mirrored boot sectors
commit. Once an installation is active, drive selection, creation, browsing,
and unrelated media changes remain locked. Stop the machine and use
**Tools > Abandon Windows 98 Installation...** if you want to remove only the
files staged by RETVRN99 and start over.

The Windows ISO is never rewritten. RETVRN99 integrates its setup policy into
the bounded copy at `C:\GSWSETUP`: localized replacements for known inbox files
are placed loose beside the CABs, while new GSW Plug and Play drivers will use
a separate OEM package manifest and `CUSTOM.INF` registration. This is also the
installation seam for the forthcoming GSW VGA and sound drivers.

Optical images are read-only. The media backend supports ISO images, raw Mode
1 images, and single-file CUE/BIN sets containing Mode 1 or audio tracks.
Floppy images must be exactly 1.44 MB.

## FAQ

### Can I install Windows 98 manually and use Turbo mode?

Yes, but Windows 98 has two separate problems here. **GSW-886** keeps the
effective CPU speed in the range expected by its old timing code. Turbo can run
into that speed bug unless the installation has the matching patch.

The TLB bug is unrelated to the selected speed. After changing a memory
mapping, Windows 98 can keep using the stale translation. An affected host CPU
can expose this even through WHPX, so GSW-886 will not save you. The symptoms
are delightfully unhelpful: Explorer may crash, or Windows may blame a
perfectly good DLL or file.

RETVRN99's guided installer patches the TLB issue and uses GSW-886 for Setup.
For a manual installation on an affected host, use
[Patcher9x](https://github.com/JHRobotics/patcher9x) to patch the Setup files
before installing; apply its CPU-speed fixes too if you plan to use Turbo. A
few old Windows updates replace `VMM.VXD` and undo the TLB fix, so rerun
Patcher9x if the strange errors return after an update.

### Why is SMARTDrive disabled during Windows 98 Setup?

The generated `GSWSETUP.BAT` passes `/C`, which tells Setup not to load
SMARTDrive. The virtual disk has no rotational seek delay, and the host already
caches access to the image. Adding a second DOS-era cache costs memory and
extra copying without helping this workload. This applies only to Setup;
installed Windows 98 still uses its normal protected-mode disk cache.

### Where are my guest files?

They are inside the selected `.img` file. The creation tool suggests
`%USERPROFILE%\.retvrn99\c_drive.img`, but the image may live anywhere you
choose. Use **Hard Drive > Browse C drive...** while the machine is stopped to
work with its files.

### What is retvrn99-fat32.exe?

It is RETVRN99's automatically managed storage helper, not a standalone tool.
It owns the image while a machine or edit session is open and keeps
acknowledged writes recoverable in a small write-ahead log (WAL). RETVRN99
fails clearly if the matching helper is missing or incompatible.

If the emulator closes unexpectedly, the helper notices that its parent pipe
has closed, replays committed records, syncs the image, preserves any evidence
it cannot safely resolve, and exits. The helper pages its working data and does
not copy the virtual hard drive into RAM.

Linux uses an advisory `flock` for image ownership. A program that ignores that
lock can still replace or resize the file, so RETVRN99 verifies the live path
and logical size before disk operations and freezes if they change. Live edits
remain unsupported: stop the machine before using another image tool.

### What is the directory beside my image?

While an image is open, RETVRN99 may create a hidden companion directory such
as `.c_drive.img.retvrn99-fat32`. It holds the WAL and disk-backed staging data.
A clean close or discarded edit removes it. If RETVRN99 leaves it behind after
a failure, do not delete it; reopen the image so the helper can recover it.

### Why do I sometimes need a boot-floppy image as well as the ISO?

Windows 98 boot files vary by language and edition. RETVRN99 can extract a
compatible embedded boot image when the disc includes one. Otherwise it asks
for the matching 1.44 MB FAT12 boot disk rather than guessing.

### Why do FDISK and FORMAT fail?

The C: drive is a real raw FAT32 image, but RETVRN99 reserves its partition and
boot layout. Replacing that layout would break recovery, installation, and the
stopped-machine browser. Normal file and directory operations remain writable.

## Development

Normal builds use checked-in ROM images built from the vendored SeaBIOS and
Bochs VGABIOS sources. Rebuilding SeaBIOS requires WSL with Linux GCC,
binutils, Make, and Python 3. Bochs VGABIOS also requires dev86 (`bcc` and
`as86`):

```powershell
.\build.ps1 -Firmware
.\build.ps1 -Firmware -WslDistro Debian
```

Run package tests and then the root integration and workload gates. Automated
installation runs require a pre-created, selected test image; they never create
one implicitly.

Media, installed images, registry exports, traces, and screenshots belong in
ignored scratch directories and must not be committed.

## License

GPL-3.0-only.

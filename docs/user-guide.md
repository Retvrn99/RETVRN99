<!-- SPDX-License-Identifier: GPL-3.0-only -->

# RETVRN99 user guide

RETVRN99 starts with the virtual machine stopped. No virtual CPU, audio device,
storage helper, or hard drive is open yet. They start only when you run the
machine or open a disk tool. This is the safe time to choose a disk and mount
boot media.

RETVRN99 never creates a hard drive without asking. If you have not configured
one, the welcome screen offers two routes:

- **Tools > Install Windows 98...** walks through the normal setup.
- **Tools > Create Hard Drive...** creates a blank FAT32 image for a manual
  installation or an existing DOS setup.

Use `retvrn99.exe --start` when you want the normal Start action queued as soon
as the GUI is ready. If no disk or bootable media is configured, the virtual
BIOS explains that no RETVRN99 hard drive is present.

## Create and select a hard drive

Open **Tools > Create Hard Drive...**, choose a filename and enter a whole size
from 1 through 127 GiB. The defaults are:

- Location: `%USERPROFILE%\.retvrn99\c_drive.img`
- Size: 20 GiB

The tool creates an MBR-partitioned FAT32 image and selects it after validation.
It will not overwrite an existing file.

The image is sparse when its host filesystem supports sparse files. Its logical
size is what Windows 98 sees; its allocated size is the host space currently in
use. A new 20 GiB image can occupy very little host space, then grow as files
are written. If sparse storage is unavailable, RETVRN99 tells you that the
complete logical size may be allocated and requires another confirmation.

Choose **Hard Drive > Select Hard Drive...** to switch to another compatible
MBR/FAT32 `.img`. The selection is stored as an absolute path in the current
Profile. If a selected image is moved or missing, RETVRN99 reports that path
instead of silently creating a replacement.

Drive creation, selection, and browsing are disabled while the machine is
running. Stop it first. This avoids changing the filesystem underneath Windows
98 or racing the storage helper.

## Browse the C: drive

With the machine stopped, choose **Hard Drive > Browse C drive...**. This opens
RETVRN99's own FAT32 browser; Windows does not mount the image.

The window has a folder tree, breadcrumbs, a paginated file list, and file
metadata. It supports:

- Dragging in files and folders, or importing them with native file and folder
  pickers.
- Exporting a selected file or folder to the host.
- Creating folders, renaming entries, and deleting directory trees.
- Replace, Skip, and Cancel choices for name conflicts, with an Apply-to-all
  option.

These operations are staged in a disk-backed overlay. **Apply** commits the
whole batch to the image; **Discard** removes the staged work and leaves the
image byte-for-byte as it was when editing began. Closing the window with
pending changes asks you to Apply, Discard, or Cancel. Large copies show
progress and can be cancelled between bounded work steps.

RETVRN99 rejects host symlinks, reparse points, special files, path traversal,
invalid FAT names, and names that collide after FAT's case-insensitive or 8.3
alias rules.

## Mount boot and game media

Use the **Media** menu for floppy and optical images. You can mount media while
the machine is stopped so it is present on the next Start. Outside an active
Windows installation, floppy and optical media can also be hot-swapped while
the machine runs.

Optical images are mounted read-only. RETVRN99 supports ISO, raw Mode 1,
single- and multi-file CUE/BIN images with Mode 1, Mode 2 Form 1, or audio
tracks, CloneCD CCD/IMG sets, and single-track Alcohol MDS/MDF data images.

On Windows, choose **Media > DVD-ROM > Use Host Optical Drive** to attach a
physical CD/DVD drive. The guest receives read-only SCSI packet access, so raw
sectors and subchannels come from the host drive rather than being synthesized
from an image. Host-drive access can require elevated privileges depending on
the Windows device policy. A floppy image must be exactly 1.44 MB.

## Guided Windows 98 installation

Stop the machine and choose **Tools > Install Windows 98...**.

1. If no valid hard drive is selected, create one. Cancelling here creates
   nothing.
2. Select your Windows 98 SE disc image.
3. Supply boot files. Compatible Spanish and Korean OEM discs can provide an
   embedded 1.44 MB El Torito image. English retail media normally prompts for
   its matching FAT12 boot-floppy image.
4. Review the disk and media summary.
5. If the selected disk is a compatible standard FAT32 image, the sidecar
   transactionally adopts its boot sectors while retaining its BPB geometry.
   Cancelling restores the original boot sectors and enrollment bytes.
6. RETVRN99 stages the localized DOS and Setup files, its setup launcher and
   cleanup files, its internal driver metadata, the Windows 98 TLB
   compatibility fix, and the required boot-sector patch. The selected ISO
   remains unchanged.
7. The sidecar commits and syncs the preparation, records the image-bound
   install state, and starts Setup.

Adoption fails safely if the image geometry cannot support the RETVRN99 boot
loader or `IO.SYS` cannot be reached in its bounded root-directory scan. The
image remains usable for stopped-machine browsing in that case.

Use a boot disk that matches the Windows language and edition. The localized
DOS files are not interchangeable.

If you install Windows 98 by hand, there are two separate bugs to deal with.
**GSW-886** helps with the old CPU-speed problem. It does nothing for the TLB
invalidation bug, which depends on the real host CPU and can appear even
through WHPX. On an affected host, use
[Patcher9x](https://github.com/JHRobotics/patcher9x) to patch the Setup files
before installing. Apply its CPU-speed fixes as well before using Turbo.

The guided installer applies RETVRN99's TLB compatibility fix automatically
and uses GSW-886 for Setup. Some old Windows updates replace `VMM.VXD`; rerun
Patcher9x if misleading DLL, file, or Explorer errors return afterward.

RETVRN99 edits only its bounded copy of the Setup source in `C:\GSWSETUP`.
For a known Windows file, such as an inbox INF, it starts from the localized
copy supplied by that disc and places a complete updated loose file beside the
CABs; Windows Setup gives that file precedence over the CAB member. New GSW
device drivers will use a separate OEM/PnP package manifest so their INFs and
payloads are registered for the correct Setup phase. This keeps Spanish,
English, Korean, and future media-specific text in the source's own code page.

The repository can reproducibly build and stage the complete five-file GSW-VGA
PnP package, but Guided Setup does not yet inject it into the Setup source.
The native GSW-Sound driver, DirectX 9, and compatibility-layer RunOnce actions
also remain disabled. A reproducible GSW-Sound `INF + DRV + VXD` developer
package exists, but repeated guest binding tests did not produce a working
device. It has no reviewed payload inventory rows and is not injected. The
default machine now hides its reserved `PCI\VEN_FFFE&DEV_0003` endpoint; do not
force the Creative inbox SB16 driver onto a PCI device node.

The experimental legacy audio Interface exposes fixed Sound Blaster 16-
compatible resources at `220h`, IRQ5, DMA1, and DMA5, with OPL3-compatible
ports at `388h`. Deterministic host-side acceptance now covers the master
timeline, PC-speaker response, DSP reset and playback formats, DMA and separate
interrupt acknowledgements, OPL3 scheduling, and offline capture stability.
The OPL3 synthesis Implementation is preserved behind the new scheduler.
Cold-DOS, Windows 98 real-DOS-mode, licensed-game, and independent chip-fidelity
gates remain open; do not treat port presence or host-side tests as those
guest-native claims.

For the next manual Windows audio gate, restore a clean pre-driver Windows 98
SE snapshot, or an equivalent image copy made while the VM was stopped and its
storage session was closed. Do not use a guest that has already had the native
GSW-Sound package or a Creative driver forced onto its PCI node as binding
evidence. Confirm that no PCI multimedia device appears, then open **Add New
Hardware**, choose the sound-device class manually, and select Creative's
**Sound Blaster 16 or AWE-32 or compatible** as a new legacy device. Its
Resources page must show I/O `0220-022F` and `0388-038B`, IRQ5, DMA1, and DMA5,
with no memory range. Prefer a configuration without MPU-401 `0330-0331`;
RETVRN99 does not emulate that endpoint.

Invoking global hardware detection on the previously modified guest closed the
Windows desktop and remained at a black text screen with a blinking cursor and
no continuing disk activity. That is a failed gate: it did not reach resource
selection and is not evidence that the inbox driver bound. Any repeat that
loses the desktop this way also fails immediately. Successful binding is not
claimed until a clean guest returns to Windows, Device Manager reports the
legacy resources above without a warning, and the later playback gates pass.

While installation is active, RETVRN99 locks drive switching, drive creation,
browsing, and unrelated media changes. This prevents an install state from
being attached to the wrong image. To start over, stop the machine and choose
**Tools > Abandon Windows 98 Installation...**. RETVRN99 removes only the files
it staged and clears the install state.

## Start, reset, and stop

- **Start** opens the selected image and launches the storage helper before the
  virtual hardware begins.
- **Reset** keeps the current machine storage session and performs a guest
  reset.
- **Stop** flushes acknowledged writes, closes the image, and exits the helper.

If a storage flush cannot complete safely, RETVRN99 freezes the machine instead
of pretending it stopped. Disk tools remain disabled so the recovery evidence
is not overwritten.

## Storage recovery

`retvrn99-fat32.exe` is an internal sibling process launched automatically
beside the emulator. It exclusively locks the active image. Each acknowledged
ATA write has a checksummed redo record in a write-ahead log (WAL), and guest
FLUSH, reset, Stop, and clean close force the required durable syncs.

Temporary state lives in a hidden companion directory beside the image, named
after it, for example `.c_drive.img.retvrn99-fat32`. A clean close removes that
directory. If the helper or emulator crashes, complete WAL records are replayed
the next time the image opens; only a torn final record is discarded.

The helper also watches its inherited parent pipe. If it becomes orphaned, it
replays committed records, syncs what it can, preserves unresolved state, and
exits. It never holds a full image in memory: command buffers, FAT pages, and
directory pages are bounded, while edit overlays stay on the host drive.

Do not delete a retained companion directory after a failure, and do not edit
an image with another program while RETVRN99 owns it.

On Linux, the image lock uses advisory `flock`. Most well-behaved tools honor
it, but another program can ignore it. RETVRN99 checks the selected path and
exact image size before each machine disk operation and freezes safely if the
file is replaced or resized; this does not make live external editing
supported. Stop the machine before opening the image elsewhere.

## Profiles and paths

The default Profile is `%USERPROFILE%\.retvrn99`. `settings.json` stores the
selected image's absolute path and CPU mode; `cmos.bin` stores guest CMOS state;
and `install-state.json` records an active installation for that specific image.

Use a separate Profile when you want independent settings and CMOS state:

```powershell
.\retvrn99.exe "--profile-root:D:\VMs\retvrn99-win98"
```

The hard-drive image does not have to live inside the Profile.

## SMARTDrive during Setup

RETVRN99 passes `/C` through `GSWSETUP.BAT`, so Windows 98 Setup does not load
SMARTDrive. The virtual disk has no mechanical seek latency, and the host
already caches the image. A second DOS-era block cache adds memory use and
copying without helping Setup. Installed Windows 98 still uses its normal
protected-mode disk cache.

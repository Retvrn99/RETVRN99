<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0002: FAT32 sidecar ownership and durability

## Status

Accepted

## Context

The original C drive was synthesized from a live host folder. That made guest
FAT semantics depend on host filesystem behavior, made portable locking and
rename guarantees difficult to define, and required a reconciliation layer
between acknowledged sectors and materialized host files. A standard raw disk
image has a simpler ownership boundary and can be copied, mounted by external
tools while stopped, and used on Windows or Linux without redefining the guest
disk.

## Decision

One deep image service owns each open C-drive image. It validates and creates
standard MBR-partitioned FAT32 images and opens either a `Machine_Session` or an
`Edit_Session`, never both. A separate Profile lock protects settings, CMOS,
and installation state; the sidecar holds an exclusive OS lock on the image.
On Linux this lock is an advisory, inode-scoped `flock`: software that ignores
advisory locks can still resize, unlink, or replace the path. The Machine
therefore verifies both the open-file identity and exact logical size against
the selected path before each block operation, and freezes with retained state
if either changes. External image access remains supported only while stopped.

The Module has `In_Process_Adapter` and production-default `Process_Adapter`
Implementations. The latter launches the internal `retvrn99-fat32.exe` sibling
over inherited anonymous pipes. Frames are versioned, checksummed, explicitly
little-endian, monotonically numbered, and bounded. There is one outstanding
request and each complete ATA command uses one round trip with at most 128 KiB
of block data. Missing or incompatible helpers fail startup. Transport loss
freezes the Machine without retry or in-process fallback.

For a Machine session, every acknowledged ATA write has one checksummed redo
record durably appended before the same bytes are applied directly to the raw
image. Guest FLUSH, Reset, Stop, and clean close durably sync the image,
checkpoint the highest sequence, and retire completed WAL data. Recovery drops
only a torn WAL tail and replays every complete record after the checkpoint.
The redo operation is idempotent. Parent pipe closure asks an orphaned helper
to replay committed records, sync, preserve any failure evidence, and exit.

Companion state lives beside the selected image under a hidden directory named
from the image, for example `.c_drive.img.retvrn99-fat32`. It contains the WAL,
checkpoint, and disk-backed Edit overlays. It is removed after clean close or
Discard and preserved after failure. A checksummed enrollment/dirty marker in
a safe unused FAT32 reserved sector binds companion state to the image. A
marker/state mismatch fails closed.

Writable startup is ordered in two durable phases. The sidecar first locks the
image and persists a `Prepared` Machine or Edit owner, including newly generated
enrollment identity, then marks the image dirty and enables writes. Directory
entries are synchronized before the marker on Linux. A crash on either side of
that boundary therefore leaves either a clean image with disposable prepared
state or a dirty image with complete recovery ownership. Dirty recovery uses a
structural parse that can identify the protected layout despite a torn FSInfo
or backup VBR; redo or Apply replay runs before strict validation, and all
evidence is retained if replay cannot restore a coherent filesystem.

The Machine writes the image directly. Edit sessions stage changed sectors in
a sparse, disk-backed overlay and commit transactionally. FAT and allocation
metadata use paged caches, directory listings are paginated, and import/export
jobs use fixed buffers. Memory use is therefore independent of image capacity.

Images are created through a sparse temporary file and atomic rename, and are
never overwritten. Linux creation synchronizes the containing directory after
publication so the new name is durable as well as the image contents. The
supported creation range is 1 through 127 whole GiB,
defaulting to 20 GiB with Windows-compatible cluster sizing. Compatible
external MBR/FAT32 images may be enrolled when a safe marker sector exists.
Guided installation adopts a compatible standard image through the same Edit
transaction: it durably preserves both original VBRs in companion evidence,
stages current RETVRN99 boot-code twins while retaining the image's BPB
geometry, and sets the format marker only after Apply succeeds. Discard or a
pre-intent cancellation restores every protected byte. Adoption fails closed
when the cluster geometry cannot satisfy the boot loader or `IO.SYS` is not in
the bounded first root-directory cluster.
Normal guest FAT contents are writable, but the MBR, partition geometry, VBR,
recovery marker, and reserved layout are protected.
Layout-compatible guest rewrites of MBR/VBR boot code and Windows' reserved
boot-continuation sectors are acknowledged without changing the protected
bytes; any partition-table or BPB geometry change fails closed. The protected
boot loader resolves `IO.SYS` from the bounded first root-directory cluster on
each boot, so a Windows Setup relocation does not leave a stale physical-LBA
target in the VBR.

Stopped-machine `Edit_Session` operations provide bounded listing and I/O plus
import, export, mkdir, rename, and recursive delete. Apply commits an entire
edit transaction or restores the old image; Discard leaves the base image
byte-identical. External tools may modify a clean, unlocked image while the
Machine is stopped. Dirty images must recover successfully before editing or
moving.

## Consequences

- ATA command handling keeps its synchronous one-command/one-round-trip model.
- Acceptance reads use ordered FAT observations from the image owner.
- Host-folder reconciliation, fingerprints, maintenance rotation, backups, and
  sealed generations are removed.
- The GUI opens stopped and never creates a disk without confirmation.
- Drive selection, creation, and browsing are stopped-only and blocked by an
  unfinished image-bound Windows installation.
- The Process Adapter becomes the default only after the Spanish OEM
  installation and crash, orphan, memory, and performance gates pass. English
  retail and Korean OEM remain compatibility follow-ups, while Korean path and
  protocol coverage is blocking.

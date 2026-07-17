# Vendored SeaBIOS source

- Upstream: https://github.com/coreboot/seabios
- Release: `rel-1.16.3`
- Commit: `a6ed6b701f0a57db0569ab98b0661c12a6ec3ff8`
- License: LGPL-3.0-only; see `COPYING.LESSER` and `COPYING`.
- RETVRN99 raises the INT 05h entry diagnostic to debug level 2 so a repeated
  bounds exception cannot saturate the firmware debug port in production.
- RETVRN99 replaces the terminal no-boot message when no hard disk is present
  with guidance to stop the Machine and create a hard drive from the Tools
  menu. Attached but non-bootable disks retain the upstream diagnostic.
- RETVRN99 initializes its AMD-756 primary-master disk for UDMA-4 after ATA
  discovery, including the drive mode, controller timing, and bus-master
  capability state expected by Windows 98.
- RETVRN99 configuration and build wrappers live in `tools/seabios/`.

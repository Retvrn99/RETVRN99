# SeaBIOS / SeaVGABIOS binaries

- `bios.bin` is RETVRN99's 128 KiB build of SeaBIOS `rel-1.16.3`. The source is
  vendored at `vendor_local/seabios/`; configuration and builders are under
  `tools/seabios/`. Its SHA-256 is recorded in `bios.bin.sha256`.
- The build keeps the legacy hardware and BIOS interfaces RETVRN99 exposes,
  including the PCI BIOS, while omitting unsupported USB, SCSI, ACPI, serial,
  parallel, and S3 firmware paths.
- `vgabios-stdvga.bin` (39424 bytes) remains verbatim from QEMU v9.0.0
  `pc-bios/` (SeaVGABIOS `rel-1.16.3`).
- SeaBIOS and SeaVGABIOS are licensed under LGPL-3.0-only. LGPLv3 is one-way
  compatible with this project's GPL-3.0-only license.

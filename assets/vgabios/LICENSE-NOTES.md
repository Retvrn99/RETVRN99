# Bochs VGABIOS binary

- `vgabios.bin` is built from Bochs VGABIOS upstream commit
  `6563908d0f54b7699b6adb13e0f0503ef8d84cfc` (30 December 2025).
- The standard upstream target defines `VBE` and `PCIBIOS`, providing the
  legacy INT 10h interface and Bochs VBE 2.0 services. It produces a 32 KiB
  PCI option ROM with a valid `55 AA` signature and byte checksum.
- The vendored source carries a pre-`DIV` page-count clamp needed when the
  DISPI device reports 32 MiB; see `vendor_local/vgabios/LICENSE-NOTES.md`.
  Its SHA-256 is recorded in `vgabios.bin.sha256`.
- Rebuilding uses the standard target with `VBE` and `PCIBIOS` plus a fixed
  upstream commit date. The Linux/WSL builder requires dev86 (`bcc` and
  `as86`).
- Bochs VGABIOS source headers grant LGPL-2.0-or-later; upstream ships the
  LGPL-2.1 license text. Corresponding source and that complete license text
  are in `vendor_local/vgabios/`.

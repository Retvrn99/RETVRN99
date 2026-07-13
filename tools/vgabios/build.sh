#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="$root/vendor_local/vgabios"
source_version="$source_dir/.version"
asset="$root/assets/vgabios/vgabios.bin"
manifest="$root/assets/vgabios/vgabios.bin.sha256"
expected_version="6563908d0f54b7699b6adb13e0f0503ef8d84cfc"
build_date="30 Dec 2025"

if [[ ! -f "$source_dir/vgabios/Makefile" ]]; then
    echo "Bochs VGABIOS source is missing: $source_dir" >&2
    exit 1
fi
if [[ ! -f "$source_version" ]] || ! grep -qx "$expected_version" "$source_version"; then
    echo "Bochs VGABIOS source version does not match $expected_version." >&2
    exit 1
fi
for tool in make gcc bcc as86 sed sha256sum python3 mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Bochs VGABIOS build requires '$tool' in the Linux/WSL environment." >&2
        exit 1
    fi
done

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/retvrn99-vgabios.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
cp -a "$source_dir/." "$build_dir/"

make -C "$build_dir/vgabios" clean
make -C "$build_dir/vgabios" \
    "VGABIOS_DATE=\"-DVGABIOS_DATE=\\\"$build_date\\\"\"" \
    vgabios.bin

rom="$build_dir/vgabios/VGABIOS-lgpl-latest.bin"
python3 - "$rom" <<'PY'
from pathlib import Path
import sys

rom = Path(sys.argv[1]).read_bytes()
if len(rom) != 32 * 1024:
    raise SystemExit(f"unexpected Bochs VGABIOS size: {len(rom)}")
if rom[:2] != b"\x55\xaa":
    raise SystemExit("Bochs VGABIOS option-ROM signature is missing")
if rom[2] * 512 != len(rom):
    raise SystemExit("Bochs VGABIOS option-ROM size byte is invalid")
if sum(rom) & 0xff:
    raise SystemExit("Bochs VGABIOS option-ROM checksum is invalid")
if b"Bochs VGABios (PCI)" not in rom:
    raise SystemExit("Bochs VGABIOS PCI build marker is missing")
PY

mkdir -p "$(dirname "$asset")"
cp "$rom" "$asset.next"
mv "$asset.next" "$asset"
hash="$(sha256sum "$asset" | cut -d' ' -f1)"
printf '%s  vgabios.bin\n' "$hash" > "$manifest.next"
mv "$manifest.next" "$manifest"
printf '%s  %s\n' "$hash" "$asset"

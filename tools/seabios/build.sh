#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="$root/vendor_local/seabios"
config="$root/tools/seabios/retvrn99.config"
asset="$root/assets/seabios/bios.bin"
manifest="$root/assets/seabios/bios.bin.sha256"

if [[ ! -f "$source_dir/Makefile" ]]; then
    echo "SeaBIOS source is missing: $source_dir" >&2
    exit 1
fi
for tool in make gcc ld objcopy objdump strip python3 sha256sum nproc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SeaBIOS build requires '$tool' in the Linux/WSL environment." >&2
        exit 1
    fi
done

cp "$config" "$source_dir/.config"
make -C "$source_dir" PYTHON=python3 olddefconfig
make -C "$source_dir" PYTHON=python3 clean
make -C "$source_dir" PYTHON=python3 EXTRAVERSION=-retvrn99 -j"$(nproc)"

grep -qx 'CONFIG_PCIBIOS=y' "$source_dir/.config"
grep -qx 'CONFIG_ROM_SIZE=128' "$source_dir/.config"

rom="$source_dir/out/bios.bin"
python3 - "$rom" <<'PY'
from pathlib import Path
import sys

rom = Path(sys.argv[1]).read_bytes()
if len(rom) != 128 * 1024:
    raise SystemExit(f"unexpected SeaBIOS size: {len(rom)}")
if b"\x24\x50\x43\x49" not in rom:
    raise SystemExit("SeaBIOS PCI BIOS service is missing")
PY

cp "$rom" "$asset.next"
mv "$asset.next" "$asset"
hash="$(sha256sum "$asset" | cut -d' ' -f1)"
printf '%s  bios.bin\n' "$hash" > "$manifest.next"
mv "$manifest.next" "$manifest"
printf '%s  %s\n' "$hash" "$asset"

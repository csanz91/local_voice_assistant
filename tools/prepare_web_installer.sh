#!/usr/bin/env bash
# Package sparse firmware parts. A merged offset-zero image overwrites the NVS
# gap even when eraseAll is false, so the USB installer must use separate parts.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/firmware/build"
TASK_OUTPUT="$TASK_ROOT/web-installer/dist/firmware"
TASK_VERSION="${1:-$(git -C "$TASK_ROOT" describe --tags --always --dirty)}"
for TASK_FILE in bootloader/bootloader.bin partition_table/partition-table.bin sebastian.bin; do
    [[ -f "$TASK_BUILD/$TASK_FILE" ]] || { echo "Missing $TASK_BUILD/$TASK_FILE; run make fw-build" >&2; exit 1; }
done
mkdir -p "$TASK_OUTPUT"
cp "$TASK_BUILD/bootloader/bootloader.bin" "$TASK_OUTPUT/bootloader.bin"
cp "$TASK_BUILD/partition_table/partition-table.bin" "$TASK_OUTPUT/partition-table.bin"
cp "$TASK_BUILD/sebastian.bin" "$TASK_OUTPUT/sebastian.bin"
python3 - "$TASK_VERSION" "$TASK_ROOT/web-installer/dist/manifest.json" <<'PY'
import json, sys
from pathlib import Path
manifest = {
    "name": "Sebastian", "version": sys.argv[1],
    # esp-web-tools erases non-Improv devices automatically when this is false.
    # With true, its erase checkbox starts unchecked and the operator chooses.
    "new_install_prompt_erase": True, "new_install_improv_wait_time": 0,
    "builds": [{"chipFamily": "ESP32-S3", "improv": False, "parts": [
        {"path": "firmware/bootloader.bin", "offset": 0},
        {"path": "firmware/partition-table.bin", "offset": 0x8000},
        {"path": "firmware/sebastian.bin", "offset": 0x10000},
    ]}],
}
Path(sys.argv[2]).write_text(json.dumps(manifest, indent=2) + "\n")
PY
echo "[installer] Sparse bootloader, partition table and app packaged in $TASK_OUTPUT"
echo "[installer] Leave Erase device unchecked to preserve NVS. Nothing published or flashed."

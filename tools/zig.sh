#!/usr/bin/env bash
# Use the pinned Xtensa fork fetched by firmware/cmake/zig.cmake.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for TASK_ZIG in "$TASK_ROOT"/firmware/build/zig-relsafe-*/zig; do
  [[ -f "$TASK_ZIG" ]] || continue
  if "$TASK_ZIG" version >/dev/null 2>&1; then exec "$TASK_ZIG" "$@"; fi
  if [[ "$TASK_ZIG" == *linux-musl* ]] && command -v docker >/dev/null 2>&1; then
    # Editors and devtools pass absolute host paths. Mount at the same path so
    # those arguments, relative imports and the working directory all survive.
    TASK_WORKDIR="$TASK_ROOT"
    [[ "$PWD" == "$TASK_ROOT" || "$PWD" == "$TASK_ROOT"/* ]] && TASK_WORKDIR="$PWD"
    exec docker run --rm -v "$TASK_ROOT:$TASK_ROOT" -w "$TASK_WORKDIR" --entrypoint "$TASK_ZIG" espressif/idf:v5.4.4 "$@"
  fi
done
echo 'Pinned Zig missing: run make fw-build or make fw-build-docker first.' >&2
exit 1

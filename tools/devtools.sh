#!/usr/bin/env bash
# Small firmware shortcuts for interactive terminals.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-Build}" in
  Build) exec "$TASK_ROOT/tools/idf.sh" build ;;
  Monitor) exec "$TASK_ROOT/tools/idf.sh" -p "${PORT:?set PORT}" monitor ;;
  Flash) exec "$TASK_ROOT/tools/idf.sh" -p "${PORT:?set PORT}" flash ;;
  'Flash + Monitor') exec "$TASK_ROOT/tools/idf.sh" -p "${PORT:?set PORT}" flash monitor ;;
  'Zig fmt') exec "$TASK_ROOT/tools/zig.sh" fmt "$TASK_ROOT/firmware/main" "$TASK_ROOT/firmware/core_test.zig" ;;
  'Zig fmt check') exec make -C "$TASK_ROOT" fw-fmt ;;
  *) echo 'Use Build, Flash, Monitor, Flash + Monitor, Zig fmt, or Zig fmt check' >&2; exit 1 ;;
esac

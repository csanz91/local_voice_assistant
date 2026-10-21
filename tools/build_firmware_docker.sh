#!/usr/bin/env bash
# Pinned, disposable ESP-IDF build; no USB, external services or credentials.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm -v "$TASK_ROOT:/workspace" -w /workspace/firmware \
    espressif/idf:v5.4.4 bash -c 'idf.py build'

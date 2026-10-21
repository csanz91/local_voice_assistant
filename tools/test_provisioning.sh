#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -m unittest discover -s "$TASK_ROOT/tests/provisioning" -p 'test_*.py' -v
if [[ -f "${IDF_PATH:-}/components/json/cJSON/cJSON.c" ]]; then
    TASK_BINARY="$(mktemp "${TMPDIR:-/tmp}/provisioning.XXXXXX")"
    trap 'rm -f "$TASK_BINARY"' EXIT
    cc -std=c11 -Wall -Wextra -Werror -I "$TASK_ROOT/firmware/main" -I "$IDF_PATH/components/json/cJSON" \
        "$TASK_ROOT/tests/provisioning/config_test.c" "$TASK_ROOT/firmware/main/provisioning_config.c" \
        "$IDF_PATH/components/json/cJSON/cJSON.c" -lm -o "$TASK_BINARY"
    "$TASK_BINARY"
else
    exec docker run --rm -v "$TASK_ROOT:/workspace:ro" -w /workspace --entrypoint bash espressif/idf:v5.4.4 -c \
        'cc -std=c11 -Wall -Wextra -Werror -I firmware/main -I /opt/esp/idf/components/json/cJSON tests/provisioning/config_test.c firmware/main/provisioning_config.c /opt/esp/idf/components/json/cJSON/cJSON.c -lm -o /tmp/provisioning-test && /tmp/provisioning-test'
fi

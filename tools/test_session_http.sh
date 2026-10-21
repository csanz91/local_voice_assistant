#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${IDF_PATH:-}/components/json/cJSON/cJSON.c" ]]; then
    TASK_BINARY="$(mktemp "${TMPDIR:-/tmp}/session-http.XXXXXX")"
    trap 'rm -f "$TASK_BINARY"' EXIT
    cc -std=c11 -Wall -Wextra -Werror -I "$TASK_ROOT/tests/http/stubs" -I "$TASK_ROOT/firmware/main" \
        -I "$IDF_PATH/components/json/cJSON" "$TASK_ROOT/tests/http/session_http_test.c" \
        "$TASK_ROOT/firmware/main/session_http.c" "$IDF_PATH/components/json/cJSON/cJSON.c" -lm -o "$TASK_BINARY"
    "$TASK_BINARY"
else
    exec docker run --rm -v "$TASK_ROOT:/workspace:ro" -w /workspace --entrypoint bash espressif/idf:v5.4.4 -c \
        'cc -std=c11 -Wall -Wextra -Werror -I tests/http/stubs -I firmware/main -I /opt/esp/idf/components/json/cJSON tests/http/session_http_test.c firmware/main/session_http.c /opt/esp/idf/components/json/cJSON/cJSON.c -lm -o /tmp/session-http && /tmp/session-http'
fi

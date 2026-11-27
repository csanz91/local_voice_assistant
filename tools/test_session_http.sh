#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Each test file has its own deterministic HTTP mock: the LiveKit session
# request ({}) and the experimental direct GPT-Live request ({"sdp": ...}).
TESTS=(session_http_test live_session_http_test)
if [[ -f "${IDF_PATH:-}/components/json/cJSON/cJSON.c" ]]; then
    TASK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/session-http.XXXXXX")"
    trap 'rm -rf "$TASK_DIR"' EXIT
    for test in "${TESTS[@]}"; do
        cc -std=c11 -Wall -Wextra -Werror -I "$TASK_ROOT/tests/http/stubs" -I "$TASK_ROOT/firmware/main" \
            -I "$IDF_PATH/components/json/cJSON" "$TASK_ROOT/tests/http/$test.c" \
            "$TASK_ROOT/firmware/main/session_http.c" "$IDF_PATH/components/json/cJSON/cJSON.c" -lm -o "$TASK_DIR/$test"
        "$TASK_DIR/$test"
    done
else
    exec docker run --rm -v "$TASK_ROOT:/workspace:ro" -w /workspace --entrypoint bash espressif/idf:v5.4.4 -c \
        'for test in session_http_test live_session_http_test; do cc -std=c11 -Wall -Wextra -Werror -I tests/http/stubs -I firmware/main -I /opt/esp/idf/components/json/cJSON tests/http/$test.c firmware/main/session_http.c /opt/esp/idf/components/json/cJSON/cJSON.c -lm -o /tmp/$test && /tmp/$test || exit 1; done'
fi

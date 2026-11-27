// Experimental direct GPT-Live session request (profile mode gpt_live): the
// production C shim against a deterministic IDF HTTP transport.
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "session_http.h"
#include "session_policy.h"

static const char *endpoint = "https://example.test/api/v2/device-voice-session";
static const char *response;
static size_t response_len;
static int status, open_error, read_error, open_len;
static bool complete, insecure, initialized, closed, cleaned;
static char written[32 * 1024];
static size_t written_len;
struct mock_client { size_t pos; };
static struct mock_client mock;

bool sebastian_cfg_get_bool(const char *key, bool fallback) { (void)fallback; assert(!strcmp(key, "insecure_http")); return insecure; }
int esp_crt_bundle_attach(void *p) { (void)p; return 0; }
esp_http_client_handle_t esp_http_client_init(const esp_http_client_config_t *cfg) {
    assert(!strcmp(cfg->url, endpoint));
    assert(cfg->method == HTTP_METHOD_POST && cfg->timeout_ms >= 10000);
    assert(cfg->crt_bundle_attach == esp_crt_bundle_attach && cfg->disable_auto_redirect);
    initialized = true;
    return &mock;
}
int esp_http_client_set_header(esp_http_client_handle_t c, const char *name, const char *value) {
    (void)c;
    if (!strcmp(name, "Authorization")) assert(!strcmp(value, "Bearer test-device-secret"));
    else assert(!strcmp(name, "Content-Type") && !strcmp(value, "application/json"));
    return 0;
}
int esp_http_client_open(esp_http_client_handle_t c, int len) { (void)c; open_len = len; return open_error; }
int esp_http_client_write(esp_http_client_handle_t c, const char *body, int len) {
    (void)c;
    assert(len == open_len && (size_t)len < sizeof(written));
    memcpy(written, body, (size_t)len);
    written[len] = '\0';
    written_len = (size_t)len;
    return len;
}
long long esp_http_client_fetch_headers(esp_http_client_handle_t c) { (void)c; return (long long)response_len; }
int esp_http_client_get_status_code(esp_http_client_handle_t c) { (void)c; return status; }
int esp_http_client_read(esp_http_client_handle_t c, char *out, int len) {
    if (read_error) return -1;
    size_t n = response_len - c->pos;
    if (n > (size_t)len) n = (size_t)len;
    if (n > 97) n = 97; // fragmented body
    memcpy(out, response + c->pos, n);
    c->pos += n;
    return (int)n;
}
bool esp_http_client_is_complete_data_received(esp_http_client_handle_t c) { return complete && c->pos == response_len; }
int esp_http_client_close(esp_http_client_handle_t c) { (void)c; closed = true; return 0; }
int esp_http_client_cleanup(esp_http_client_handle_t c) { (void)c; cleaned = true; return 0; }

static const char *OFFER = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\na=\"quoted\"\\x\r\n";

static void reset(const char *body) {
    mock.pos = 0; response = body; response_len = strlen(body); status = 200;
    open_error = read_error = 0; complete = true; insecure = false;
    initialized = closed = cleaned = false; written_len = 0; written[0] = '\0';
    endpoint = "https://example.test/api/v2/device-voice-session";
}
static int run_offer(const char *offer, char *answer, size_t answer_size) {
    char conv[64] = "stale";
    int rc = sebastian_live_session_create(endpoint, "test-device-secret", offer, answer, answer_size, conv, sizeof(conv));
    if (initialized) assert(closed && cleaned);
    if (rc) assert(!answer[0]);
    return rc;
}
static int run(void) {
    char answer[4096] = "stale";
    return run_offer(OFFER, answer, sizeof(answer));
}

int main(void) {
    const char *ok = "{\"transport\":\"gpt_live\",\"sdp\":\"v=0\\r\\no=answer\\r\\n\",\"conversationId\":\"0f8c-11aa\"}";

    // The request body is exactly {"sdp":"<escaped offer>"} and parses back.
    reset(ok);
    char answer[4096] = "";
    char conv[64] = "";
    assert(sebastian_live_session_create(endpoint, "test-device-secret", OFFER, answer, sizeof(answer), conv, sizeof(conv)) == 0);
    assert(!strcmp(answer, "v=0\r\no=answer\r\n"));
    assert(!strcmp(conv, "0f8c-11aa"));
    assert(!strcmp(written, "{\"sdp\":\"v=0\\r\\no=- 1 1 IN IP4 0.0.0.0\\r\\ns=-\\r\\na=\\\"quoted\\\"\\\\x\\r\\n\"}"));
    assert(closed && cleaned);

    // HTTP rejections, including the server's "disabled" 409, are surfaced.
    int codes[] = {301, 401, 403, 409, 422, 429, 502, 503};
    for (size_t i = 0; i < sizeof(codes) / sizeof(*codes); i++) { reset(ok); status = codes[i]; assert(run() == codes[i]); }
    reset(ok); open_error = -1; assert(run() == -2);
    reset(ok); read_error = 1; assert(run() == -4);
    reset(ok); complete = false; assert(run() == -4);
    reset(""); assert(run() == -4);

    const char *bad[] = {
        "{}", "[]", "not-json",
        "{\"serverUrl\":\"wss://x\",\"participantToken\":\"t\",\"roomName\":\"r\"}", // a LiveKit reply
        "{\"transport\":\"livekit\",\"sdp\":\"v=0\\r\\n\"}",
        "{\"transport\":\"gpt_live\",\"sdp\":\"\"}",
        "{\"transport\":\"gpt_live\",\"sdp\":\"hello\"}",
        "{\"transport\":\"gpt_live\",\"sdp\":5}",
        "{\"transport\":\"gpt_live\",\"sdp\":\"v=0\\u0000\"}",
        "{\"transport\":\"gpt_live\",\"sdp\":\"v=0\"} garbage",
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(*bad); i++) { reset(bad[i]); assert(run() == -5); }

    // An answer that does not fit the caller's buffer is rejected, not truncated.
    reset(ok);
    char tiny[8] = "stale";
    assert(run_offer(OFFER, tiny, sizeof(tiny)) == -5);

    // A conversation id with unexpected characters is dropped, the call still works.
    reset("{\"transport\":\"gpt_live\",\"sdp\":\"v=0\\r\\n\",\"conversationId\":\"../x\"}");
    conv[0] = 'x';
    answer[0] = '\0';
    assert(sebastian_live_session_create(endpoint, "test-device-secret", OFFER, answer, sizeof(answer), conv, sizeof(conv)) == 0);
    assert(!conv[0]);

    // Local validation happens before any connection is opened.
    reset(ok); endpoint = "http://example.test/api"; assert(run() == -6); assert(!initialized);
    reset(ok); endpoint = "http://example.test/api"; insecure = true; assert(run() == 0);
    char empty_answer[16] = "";
    reset(ok); assert(run_offer("", empty_answer, sizeof(empty_answer)) == -1);
    reset(ok); assert(run_offer("v=0\x01", answer, sizeof(answer)) == -6); assert(!initialized);
    char *huge = malloc(SEBASTIAN_LIVE_SDP_MAX + 2);
    memset(huge, 'a', SEBASTIAN_LIVE_SDP_MAX + 1);
    huge[SEBASTIAN_LIVE_SDP_MAX + 1] = '\0';
    reset(ok); assert(run_offer(huge, answer, sizeof(answer)) == -6); assert(!initialized);
    free(huge);

    // The quoting helper itself.
    char q[16];
    assert(sebastian_json_quote("a\"b", q, sizeof(q)) == 6 && !strcmp(q, "\"a\\\"b\""));
    assert(sebastian_json_quote("abcdefghijklmnop", q, sizeof(q)) == 0);
    assert(sebastian_json_quote("\x02", q, sizeof(q)) == 0);

    puts("live session HTTP tests passed");
    return 0;
}

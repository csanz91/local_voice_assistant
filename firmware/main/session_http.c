// One authenticated conversation request. Redirects are intentionally refused:
// the per-device credential must never travel to another origin or cleartext URL.
#include "session_http.h"
#include "session_policy.h"
#include "cJSON.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include <stdlib.h>
#include <string.h>
#ifdef ESP_PLATFORM
#include "esp_heap_caps.h"
#endif

static const char *TAG = "session_http";

int sebastian_session_create(const char *endpoint, const char *device_id, const char *secret,
                            char *url_out, size_t url_size, char *token_out, size_t token_size,
                            char *room_out, size_t room_size) {
    if (!url_out || !token_out || !room_out || !url_size || !token_size || !room_size) return -1;
    url_out[0] = token_out[0] = room_out[0] = '\0';
    const bool insecure = sebastian_cfg_get_bool("insecure_http", false);
    if (!session_url_valid(endpoint, false, insecure) || !session_secret_valid(secret) ||
        !device_id || strlen(device_id) != 12 || strspn(device_id, "0123456789abcdef") != 12) return -6;
    esp_http_client_config_t config = {
        .url = endpoint,
        .method = HTTP_METHOD_POST,
        .timeout_ms = 5000,
        .buffer_size_tx = 1088, // 1024-byte bearer, header name, delimiters and terminator
        .crt_bundle_attach = esp_crt_bundle_attach,
        .disable_auto_redirect = true,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (!client) return -1;
    int result = -2;
    cJSON *root = NULL;
    static char body[1536]; // bounded, static: internal RAM is scarce
    static char authorization[1032];
    memcpy(authorization, "Bearer ", 7);
    memcpy(authorization + 7, secret, strlen(secret) + 1);
    if (esp_http_client_set_header(client, "Authorization", authorization) != ESP_OK ||
        esp_http_client_set_header(client, "Content-Type", "application/json") != ESP_OK ||
        esp_http_client_open(client, 2) != ESP_OK ||
        esp_http_client_write(client, "{}", 2) != 2) goto cleanup;
    if (esp_http_client_fetch_headers(client) < 0) goto cleanup;
    const int code = esp_http_client_get_status_code(client);
    if (code != 200) {
        ESP_LOGW(TAG, "session endpoint returned HTTP %d", code);
        result = code > 0 ? code : -3;
        goto cleanup;
    }
    // Read until EOF, including chunked responses. Never parse a valid prefix
    // after truncation: an extra byte or incomplete HTTP body is an error.
    size_t used = 0;
    while (used < sizeof(body) - 1) {
        const int n = esp_http_client_read(client, body + used, sizeof(body) - 1 - used);
        if (n < 0) { result = -4; goto cleanup; }
        if (!n) break;
        used += n;
    }
    char extra;
    if (esp_http_client_read(client, &extra, 1) != 0 || !esp_http_client_is_complete_data_received(client) || !used) {
        result = -4;
        goto cleanup;
    }
    body[used] = '\0';
    // Require the full JSON document and reject embedded NULs before parsing.
    if (memchr(body, '\0', used) || strstr(body, "\\u0000")) { result = -5; goto cleanup; }
    root = cJSON_ParseWithLengthOpts(body, used + 1, NULL, true);
    const cJSON *server_url = root ? cJSON_GetObjectItemCaseSensitive(root, "serverUrl") : NULL;
    const cJSON *token = root ? cJSON_GetObjectItemCaseSensitive(root, "participantToken") : NULL;
    const cJSON *room = root ? cJSON_GetObjectItemCaseSensitive(root, "roomName") : NULL;
    if (!cJSON_IsObject(root) || !cJSON_IsString(server_url) || !cJSON_IsString(token) || !cJSON_IsString(room) ||
        !room->valuestring[0] || strlen(room->valuestring) >= room_size ||
        strspn(room->valuestring, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-") != strlen(room->valuestring) ||
        !session_url_valid(server_url->valuestring, true, insecure) || !token->valuestring[0] ||
        strlen(server_url->valuestring) >= url_size || strlen(token->valuestring) >= token_size ||
        strspn(token->valuestring, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.") != strlen(token->valuestring)) {
        result = -5;
        goto cleanup;
    }
    memcpy(url_out, server_url->valuestring, strlen(server_url->valuestring) + 1);
    memcpy(token_out, token->valuestring, strlen(token->valuestring) + 1);
    memcpy(room_out, room->valuestring, strlen(room->valuestring) + 1);
    result = 0;
cleanup:
    cJSON_Delete(root);
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    return result;
}


// ── Experimental direct GPT-Live session (profile mode gpt_live) ─────────────
// SDP offers/answers are a few KB, far past the static LiveKit body. Keep the
// buffers in PSRAM and only for the duration of the request.
static void *live_alloc(size_t size) {
#ifdef ESP_PLATFORM
    void *ptr = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    return ptr ? ptr : malloc(size);
#else
    return malloc(size);
#endif
}

size_t sebastian_json_quote(const char *in, char *out, size_t out_size) {
    if (!in || !out || out_size < 3) return 0;
    size_t used = 0;
    out[used++] = '"';
    for (const unsigned char *c = (const unsigned char *)in; *c; ++c) {
        char one[2] = {0, 0};
        const char *esc;
        switch (*c) {
            case '"': esc = "\\\""; break;
            case '\\': esc = "\\\\"; break;
            case '\r': esc = "\\r"; break;
            case '\n': esc = "\\n"; break;
            case '\t': esc = "\\t"; break;
            default:
                if (*c < 0x20) return 0;
                one[0] = (char)*c;
                esc = one;
        }
        const size_t len = strlen(esc);
        if (used + len + 2 > out_size) return 0;
        memcpy(out + used, esc, len);
        used += len;
    }
    out[used++] = '"';
    out[used] = '\0';
    return used;
}

int sebastian_live_session_create(const char *endpoint, const char *secret, const char *offer,
                                  char *answer_out, size_t answer_size, char *conv_out, size_t conv_size) {
    if (!answer_out || !answer_size || !offer || !offer[0]) return -1;
    answer_out[0] = '\0';
    if (conv_out && conv_size) conv_out[0] = '\0';
    const bool insecure = sebastian_cfg_get_bool("insecure_http", false);
    if (!session_url_valid(endpoint, false, insecure) || !session_secret_valid(secret)) return -6;
    const size_t offer_len = strlen(offer);
    if (offer_len > SEBASTIAN_LIVE_SDP_MAX) return -6;

    // {"sdp":"<escaped>"}: escaping CR/LF at most doubles the offer.
    const size_t request_cap = offer_len * 2 + 16;
    char *request = live_alloc(request_cap);
    char *body = live_alloc(SEBASTIAN_LIVE_BODY_MAX + 1);
    char *authorization = live_alloc(1032);
    esp_http_client_handle_t client = NULL;
    cJSON *root = NULL;
    int result = -1;
    if (!request || !body || !authorization) goto cleanup;
    memcpy(request, "{\"sdp\":", 7);
    const size_t quoted = sebastian_json_quote(offer, request + 7, request_cap - 8);
    if (!quoted) { result = -6; goto cleanup; }
    request[7 + quoted] = '}';
    request[8 + quoted] = '\0';
    const int request_len = (int)(8 + quoted);

    esp_http_client_config_t config = {
        .url = endpoint,
        .method = HTTP_METHOD_POST,
        .timeout_ms = 15000, // the server creates the Live session before it answers
        .buffer_size_tx = 1088,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .disable_auto_redirect = true,
    };
    client = esp_http_client_init(&config);
    if (!client) goto cleanup;
    result = -2;
    memcpy(authorization, "Bearer ", 7);
    memcpy(authorization + 7, secret, strlen(secret) + 1);
    if (esp_http_client_set_header(client, "Authorization", authorization) != ESP_OK ||
        esp_http_client_set_header(client, "Content-Type", "application/json") != ESP_OK ||
        esp_http_client_open(client, request_len) != ESP_OK ||
        esp_http_client_write(client, request, request_len) != request_len) goto cleanup;
    if (esp_http_client_fetch_headers(client) < 0) goto cleanup;
    const int code = esp_http_client_get_status_code(client);
    if (code != 200) {
        ESP_LOGW(TAG, "live session endpoint returned HTTP %d", code);
        result = code > 0 ? code : -3;
        goto cleanup;
    }
    size_t used = 0;
    while (used < SEBASTIAN_LIVE_BODY_MAX) {
        const int n = esp_http_client_read(client, body + used, SEBASTIAN_LIVE_BODY_MAX - used);
        if (n < 0) { result = -4; goto cleanup; }
        if (!n) break;
        used += n;
    }
    char extra;
    if (esp_http_client_read(client, &extra, 1) != 0 || !esp_http_client_is_complete_data_received(client) || !used) {
        result = -4;
        goto cleanup;
    }
    body[used] = '\0';
    if (memchr(body, '\0', used) || strstr(body, "\\u0000")) { result = -5; goto cleanup; }
    root = cJSON_ParseWithLengthOpts(body, used + 1, NULL, true);
    const cJSON *transport = root ? cJSON_GetObjectItemCaseSensitive(root, "transport") : NULL;
    const cJSON *sdp = root ? cJSON_GetObjectItemCaseSensitive(root, "sdp") : NULL;
    const cJSON *conv = root ? cJSON_GetObjectItemCaseSensitive(root, "conversationId") : NULL;
    if (!cJSON_IsObject(root) || !cJSON_IsString(transport) || strcmp(transport->valuestring, "gpt_live") != 0 ||
        !cJSON_IsString(sdp) || strncmp(sdp->valuestring, "v=0", 3) != 0 ||
        strlen(sdp->valuestring) >= answer_size) {
        result = -5;
        goto cleanup;
    }
    memcpy(answer_out, sdp->valuestring, strlen(sdp->valuestring) + 1);
    if (conv_out && conv_size && cJSON_IsString(conv) && strlen(conv->valuestring) < conv_size &&
        strspn(conv->valuestring, "abcdefABCDEF0123456789-") == strlen(conv->valuestring)) {
        memcpy(conv_out, conv->valuestring, strlen(conv->valuestring) + 1);
    }
    result = 0;
cleanup:
    cJSON_Delete(root);
    if (client) {
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
    }
    free(request);
    free(body);
    if (authorization) {
        memset(authorization, 0, 1032); // holds the device bearer
        free(authorization);
    }
    return result;
}

// Strict request correlation; transport sender authentication is done by the
// firmware before parsing. ACK means API result, never RTP/hardware drain.
int sebastian_wake_result(const unsigned char *bytes, size_t size, const char *request) {
    if (!bytes || !size || size > 512 || !request || memchr(bytes, 0, size)) return 0;
    char json[513];
    memcpy(json, bytes, size); json[size] = 0;
    cJSON *root = cJSON_ParseWithLengthOpts(json, size + 1, NULL, true);
    if (!root) return 0;
    const cJSON *version = cJSON_GetObjectItemCaseSensitive(root, "version");
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(root, "request_id");
    const cJSON *status = cJSON_GetObjectItemCaseSensitive(root, "status");
    const cJSON *reason = cJSON_GetObjectItemCaseSensitive(root, "reason");
    int result = 0;
    // Refuse duplicate keys and unexpected fields, including embedded NUL escapes.
    if (cJSON_IsObject(root) && cJSON_GetArraySize(root) == 4 && !strstr(json, "\\u0000") &&
        cJSON_IsNumber(version) && version->valuedouble == 2 &&
        cJSON_IsString(id) && !strcmp(id->valuestring, request) &&
        cJSON_IsString(status) && cJSON_IsString(reason)) {
        if (!strcmp(status->valuestring, "accepted") && !strcmp(reason->valuestring, "interrupted")) result = 1;
        if (!strcmp(status->valuestring, "rejected")) {
            if (!strcmp(reason->valuestring, "policy")) result = -1;
            else if (!strcmp(reason->valuestring, "not_ready") || !strcmp(reason->valuestring, "timeout") ||
                     !strcmp(reason->valuestring, "invalid")) result = -2;
        }
    }
    cJSON_Delete(root);
    return result;
}

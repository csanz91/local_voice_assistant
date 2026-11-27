#pragma once
#include <stdbool.h>
#include <stddef.h>

bool sebastian_get_token_url(char *out, size_t out_size);
bool sebastian_get_device_secret(char *out, size_t out_size);
bool sebastian_ensure_device_secret(void);
bool sebastian_cfg_get_bool(const char *key, bool fallback);
bool sebastian_provisioning_apply(const char *json, char *err, size_t err_size);
// POST {} with the provisioned voice-scoped, finite per-device Bearer JWT.
// 0: success; positive: HTTP rejection; negative: local/transport/parse failure.
int sebastian_session_create(const char *endpoint, const char *device_id, const char *secret,
                            char *url_out, size_t url_size, char *token_out, size_t token_size,
                            char *room_out, size_t room_size);
int sebastian_wake_result(const unsigned char *bytes, size_t size, const char *request);

// Experimental direct GPT-Live (profile mode gpt_live). POST {"sdp": offer} to
// the same provisioned endpoint; the reply must be
// {"transport":"gpt_live","sdp":"v=0...","conversationId":"..."}.
// Same return convention as sebastian_session_create.
#define SEBASTIAN_LIVE_SDP_MAX (8 * 1024)
#define SEBASTIAN_LIVE_BODY_MAX (12 * 1024)
int sebastian_live_session_create(const char *endpoint, const char *secret, const char *offer,
                                  char *answer_out, size_t answer_size, char *conv_out, size_t conv_size);
// JSON string literal (with quotes) for `in`; 0 if it does not fit or `in`
// holds control characters other than CR/LF/TAB.
size_t sebastian_json_quote(const char *in, char *out, size_t out_size);

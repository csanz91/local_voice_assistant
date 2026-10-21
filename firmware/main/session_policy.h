// Shared provisioning/session URL policy. No credentials, fragments, ambiguous
// whitespace or backslashes. Unencrypted transport is a deliberate LAN opt-in.
#pragma once
#include <stdbool.h>
#include <string.h>

static inline bool session_url_valid(const char *url, bool websocket, bool insecure) {
    if (!url || !url[0] || strlen(url) > 255) return false;
    const char *host = NULL;
    const char *secure = websocket ? "wss://" : "https://";
    const char *plain = websocket ? "ws://" : "http://";
    if (strncmp(url, secure, strlen(secure)) == 0) host = url + strlen(secure);
    else if (insecure && strncmp(url, plain, strlen(plain)) == 0) host = url + strlen(plain);
    else return false;
    if (!host[0] || host[0] == '/' || host[0] == '?' || host[0] == ':') return false;
    const char *authority_end = host + strcspn(host, "/?");
    for (const char *p = url; *p; p++) {
        if ((unsigned char)*p <= 32 || (unsigned char)*p == 127 || *p == '#' || *p == '\\') return false;
        if (p >= host && p < authority_end && *p == '@') return false;
    }
    return true;
}

static inline bool session_secret_valid(const char *secret) {
    if (!secret || !secret[0] || strlen(secret) > 1024) return false;
    for (const char *p = secret; *p; p++) if ((unsigned char)*p <= 32 || (unsigned char)*p >= 127) return false;
    return true;
}

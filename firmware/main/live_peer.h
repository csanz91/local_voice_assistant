// Experimental direct GPT-Live WebRTC session (profile mode gpt_live).
//
// One esp_peer connection, no LiveKit: the device's SDP offer goes to the
// provisioned IoTCloud endpoint (sebastian_live_session_create), the answer
// comes back, Opus audio flows on the media tracks and JSON events on the
// "oai-events" data channel. The capturer and renderer are the same ones the
// LiveKit path uses; this module only owns the peer and the 20 ms send task.
//
// Kept in C so Zig binds a handful of plain functions, not esp_peer structs.
#pragma once

#include <stdbool.h>
#include <stddef.h>

#define LIVE_PEER_STATE_IDLE 0
#define LIVE_PEER_STATE_CONNECTING 1
#define LIVE_PEER_STATE_CONNECTED 2 // media up and oai-events open
#define LIVE_PEER_STATE_ENDED 3

// Called on the peer thread for every oai-events message; `json` is borrowed
// until return and NOT NUL-terminated. Must not block.
typedef void (*live_peer_event_cb)(const char *json, size_t len, void *ctx);
// Called on the peer thread for every received audio frame; false drops it.
typedef bool (*live_peer_audio_filter)(void *ctx);

// Create the offer, exchange it with the endpoint and apply the answer. Blocks
// the caller for the HTTPS round trip (bounded). 0 on success; otherwise the
// sebastian_live_session_create code (HTTP status > 0, local error < 0) or
// -10 for a local WebRTC failure. On failure everything is already released.
int live_peer_open(void *capturer, void *renderer, const char *endpoint, const char *secret,
                   live_peer_event_cb on_event, live_peer_audio_filter audio_filter, void *ctx);
int live_peer_state(void);
// Send one JSON event on oai-events; false when the channel is not open.
bool live_peer_send_json(const char *json);
// Graceful close: session.close, wait (bounded) for session.closed, then tear
// down media and the peer. Safe to call in any state, including after failure.
void live_peer_close(void);
// Pre-generate the DTLS certificate once at boot to shorten the handshake.
void live_peer_prepare(void);

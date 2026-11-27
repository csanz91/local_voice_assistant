// Experimental direct GPT-Live WebRTC session. See live_peer.h.
//
// This is the single-peer subset of components/livekit/core/peer.c and the
// media half of engine.c: the same esp_peer defaults, data-channel caches,
// capture sink and render hookup, with OpenAI's HTTP SDP exchange instead of
// LiveKit signaling. Thread names reuse the LiveKit scheduler entries
// (system.c) so stack sizes, priorities and core pinning stay identical.
#include "live_peer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "av_render.h"
#include "esp_capture.h"
#include "esp_capture_sink.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_peer.h"
#include "esp_peer_default.h"
#include "esp_timer.h"
#include "media_lib_os.h"
#include "session_http.h"

static const char *TAG = "live_peer";

#define EVENTS_LABEL "oai-events"
#define STREAM_ID_INVALID 0xFFFF
#define OFFER_TIMEOUT_MS 10000
#define CLOSE_ACK_TIMEOUT_MS 5000
#define SEND_INTERVAL_MS 20
#define ANSWER_CAP (SEBASTIAN_LIVE_BODY_MAX)

#define BIT_OFFER (1 << 0)
#define BIT_PEER_EXIT (1 << 1)
#define BIT_SEND_EXIT (1 << 2)
#define BIT_CLOSED (1 << 3)

typedef struct {
    esp_peer_handle_t peer;
    esp_capture_handle_t capturer;
    esp_capture_sink_handle_t sink;
    av_render_handle_t renderer;
    media_lib_event_grp_handle_t events;
    live_peer_event_cb on_event;
    live_peer_audio_filter audio_filter;
    void *ctx;
    char *offer;     // PSRAM, set on the peer thread
    char *answer;    // PSRAM
    volatile bool peer_running;
    volatile bool send_running;
    bool capture_started;
    bool stream_added;
    atomic_int state;
    atomic_uint_fast16_t stream_id;
} live_peer_t;

static live_peer_t g;

static void *psram(size_t size) {
    void *ptr = heap_caps_calloc(1, size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    return ptr ? ptr : calloc(1, size);
}

static void set_state(int state) {
    const int previous = atomic_exchange(&g.state, state);
    if (previous != state) ESP_LOGI(TAG, "state %d -> %d", previous, state);
}

// ── esp_peer callbacks (peer thread) ─────────────────────────────────────────

static int on_state(esp_peer_state_t state, void *ctx) {
    (void)ctx;
    switch (state) {
        case ESP_PEER_STATE_CONNECT_FAILED:
        case ESP_PEER_STATE_DISCONNECTED:
            if (atomic_load(&g.state) != LIVE_PEER_STATE_IDLE) set_state(LIVE_PEER_STATE_ENDED);
            break;
        case ESP_PEER_STATE_DATA_CHANNEL_CONNECTED: {
            // OpenAI expects the client to open the event channel (as the
            // browser does with createDataChannel before the offer).
            esp_peer_data_channel_cfg_t cfg = {
                .label = EVENTS_LABEL,
                .type = ESP_PEER_DATA_CHANNEL_RELIABLE,
                .ordered = true,
            };
            if (esp_peer_create_data_channel(g.peer, &cfg) != ESP_PEER_ERR_NONE) {
                ESP_LOGE(TAG, "could not create %s", EVENTS_LABEL);
                set_state(LIVE_PEER_STATE_ENDED);
            }
            break;
        }
        case ESP_PEER_STATE_DATA_CHANNEL_CLOSED:
        case ESP_PEER_STATE_DATA_CHANNEL_DISCONNECTED:
            atomic_store(&g.stream_id, STREAM_ID_INVALID);
            if (atomic_load(&g.state) == LIVE_PEER_STATE_CONNECTED) set_state(LIVE_PEER_STATE_ENDED);
            break;
        default:
            break;
    }
    return 0;
}

static int on_msg(esp_peer_msg_t *msg, void *ctx) {
    (void)ctx;
    if (msg->type != ESP_PEER_MSG_TYPE_SDP || !msg->data || msg->size <= 0) return 0;
    if (msg->size > SEBASTIAN_LIVE_SDP_MAX || g.offer[0]) {
        ESP_LOGE(TAG, "unexpected SDP (%d bytes)", msg->size);
        return 0;
    }
    memcpy(g.offer, msg->data, (size_t)msg->size);
    g.offer[msg->size] = '\0';
    media_lib_event_group_set_bits(g.events, BIT_OFFER);
    return 0;
}

static int on_audio_info(esp_peer_audio_stream_info_t *info, void *ctx) {
    (void)ctx;
    av_render_audio_info_t render = {
        .codec = info->codec == ESP_PEER_AUDIO_CODEC_OPUS ? AV_RENDER_AUDIO_CODEC_OPUS
               : info->codec == ESP_PEER_AUDIO_CODEC_G711A ? AV_RENDER_AUDIO_CODEC_G711A
               : info->codec == ESP_PEER_AUDIO_CODEC_G711U ? AV_RENDER_AUDIO_CODEC_G711U
                                                           : AV_RENDER_AUDIO_CODEC_NONE,
        .sample_rate = info->codec == ESP_PEER_AUDIO_CODEC_OPUS ? info->sample_rate : 8000,
        .channel = info->codec == ESP_PEER_AUDIO_CODEC_OPUS ? info->channel : 1,
        .bits_per_sample = 16,
    };
    if (g.stream_added) av_render_reset(g.renderer);
    if (av_render_add_audio_stream(g.renderer, &render) != ESP_MEDIA_ERR_OK) {
        ESP_LOGE(TAG, "renderer rejected the remote audio stream");
        return 0;
    }
    g.stream_added = true;
    ESP_LOGI(TAG, "remote audio codec=%d rate=%" PRIu32 " ch=%u", info->codec, info->sample_rate, info->channel);
    return 0;
}

static int on_audio_data(esp_peer_audio_frame_t *frame, void *ctx) {
    (void)ctx;
    if (!g.stream_added || (g.audio_filter && !g.audio_filter(g.ctx))) return 0;
    av_render_audio_data_t data = {.pts = frame->pts, .data = frame->data, .size = (uint32_t)frame->size};
    av_render_add_audio_data(g.renderer, &data);
    return 0;
}

static int on_video_info(esp_peer_video_stream_info_t *info, void *ctx) { (void)info; (void)ctx; return 0; }
static int on_video_data(esp_peer_video_frame_t *frame, void *ctx) { (void)frame; (void)ctx; return 0; }

static int on_channel_open(esp_peer_data_channel_info_t *ch, void *ctx) {
    (void)ctx;
    ESP_LOGI(TAG, "channel open: %s (%u)", ch->label ? ch->label : "?", ch->stream_id);
    if (ch->label && strcmp(ch->label, EVENTS_LABEL) == 0) {
        atomic_store(&g.stream_id, ch->stream_id);
        if (atomic_load(&g.state) == LIVE_PEER_STATE_CONNECTING) set_state(LIVE_PEER_STATE_CONNECTED);
    }
    return 0;
}

static int on_channel_close(esp_peer_data_channel_info_t *ch, void *ctx) {
    (void)ctx;
    if (ch->label && strcmp(ch->label, EVENTS_LABEL) == 0) atomic_store(&g.stream_id, STREAM_ID_INVALID);
    return 0;
}

static int on_data(esp_peer_data_frame_t *frame, void *ctx) {
    (void)ctx;
    if (!frame->data || frame->size <= 0 || frame->stream_id != atomic_load(&g.stream_id)) return 0;
    const char *json = (const char *)frame->data;
    const size_t len = (size_t)frame->size;
    // The final event: let live_peer_close() stop waiting.
    static const char closed[] = "\"session.closed\"";
    if (len >= sizeof(closed) - 1 && memmem(json, len, closed, sizeof(closed) - 1)) {
        media_lib_event_group_set_bits(g.events, BIT_CLOSED);
    }
    if (g.on_event) g.on_event(json, len, g.ctx);
    return 0;
}

// ── threads ──────────────────────────────────────────────────────────────────

static void peer_task(void *arg) {
    (void)arg;
    while (g.peer_running) {
        esp_peer_main_loop(g.peer);
        media_lib_thread_sleep(10);
    }
    media_lib_event_group_set_bits(g.events, BIT_PEER_EXIT);
    media_lib_thread_destroy(NULL);
}

static void send_task(void *arg) {
    (void)arg;
    while (g.send_running) {
        esp_capture_stream_frame_t frame = {.stream_type = ESP_CAPTURE_STREAM_TYPE_AUDIO};
        while (esp_capture_sink_acquire_frame(g.sink, &frame, true) == ESP_CAPTURE_ERR_OK) {
            // Frames captured before the media path is up are dropped, not queued.
            if (atomic_load(&g.state) == LIVE_PEER_STATE_CONNECTED) {
                esp_peer_audio_frame_t out = {.pts = frame.pts, .data = frame.data, .size = frame.size};
                esp_peer_send_audio(g.peer, &out);
            }
            esp_capture_sink_release_frame(g.sink, &frame);
        }
        media_lib_thread_sleep(SEND_INTERVAL_MS);
    }
    media_lib_event_group_set_bits(g.events, BIT_SEND_EXIT);
    media_lib_thread_destroy(NULL);
}

// ── lifecycle ────────────────────────────────────────────────────────────────

static void release(void) {
    if (g.send_running) {
        g.send_running = false;
        media_lib_event_group_wait_bits(g.events, BIT_SEND_EXIT, MEDIA_LIB_MAX_LOCK_TIME);
    }
    if (g.capture_started) {
        esp_capture_stop(g.capturer);
        g.capture_started = false;
    }
    if (g.peer) {
        esp_peer_disconnect(g.peer);
        if (g.peer_running) {
            g.peer_running = false;
            media_lib_event_group_wait_bits(g.events, BIT_PEER_EXIT, MEDIA_LIB_MAX_LOCK_TIME);
        }
        esp_peer_close(g.peer);
        g.peer = NULL;
    }
    if (g.events) {
        media_lib_event_group_destroy(g.events);
        g.events = NULL;
    }
    free(g.offer);
    free(g.answer);
    g.offer = g.answer = NULL;
    g.stream_added = false;
    atomic_store(&g.stream_id, STREAM_ID_INVALID);
    set_state(LIVE_PEER_STATE_IDLE);
}

static int start_media(void) {
    esp_capture_sink_cfg_t sink_cfg = {
        .audio_info = {
            .format_id = ESP_CAPTURE_FMT_ID_OPUS,
            .sample_rate = 48000,
            .channel = 1,
            .bits_per_sample = 16,
        },
    };
    if (esp_capture_sink_setup(g.capturer, 0, &sink_cfg, &g.sink) != ESP_CAPTURE_ERR_OK ||
        esp_capture_sink_enable(g.sink, ESP_CAPTURE_RUN_MODE_ALWAYS) != ESP_CAPTURE_ERR_OK) {
        ESP_LOGE(TAG, "capture sink setup failed");
        return -1;
    }
    if (esp_capture_start(g.capturer) != ESP_CAPTURE_ERR_OK) {
        ESP_LOGE(TAG, "capture start failed");
        return -1;
    }
    g.capture_started = true;
    media_lib_thread_handle_t thread = NULL;
    g.send_running = true;
    if (media_lib_thread_create_from_scheduler(&thread, "lk_eng_stream", send_task, NULL) != ESP_PEER_ERR_NONE) {
        g.send_running = false;
        ESP_LOGE(TAG, "send task create failed");
        return -1;
    }
    return 0;
}

int live_peer_open(void *capturer, void *renderer, const char *endpoint, const char *secret,
                   live_peer_event_cb on_event, live_peer_audio_filter audio_filter, void *ctx) {
    if (g.peer) live_peer_close();
    memset(&g, 0, sizeof(g));
    atomic_store(&g.stream_id, STREAM_ID_INVALID);
    g.capturer = capturer;
    g.renderer = renderer;
    g.on_event = on_event;
    g.audio_filter = audio_filter;
    g.ctx = ctx;
    g.offer = psram(SEBASTIAN_LIVE_SDP_MAX + 1);
    g.answer = psram(ANSWER_CAP + 1);
    media_lib_event_group_create(&g.events);
    if (!g.offer || !g.answer || !g.events) {
        release();
        return -10;
    }
    set_state(LIVE_PEER_STATE_CONNECTING);
    const int64_t t0 = esp_timer_get_time();

    esp_peer_default_cfg_t extra = {
        .data_ch_cfg = {
            .cache_timeout = 5000,
            .send_cache_size = 100 * 1024,
            .recv_cache_size = 100 * 1024,
        },
    };
    esp_peer_cfg_t cfg = {
        .server_lists = NULL, // OpenAI's candidates are public; host candidates suffice
        .server_num = 0,
        .role = ESP_PEER_ROLE_CONTROLLING,
        .ice_trans_policy = ESP_PEER_ICE_TRANS_POLICY_ALL,
        .audio_info = {.codec = ESP_PEER_AUDIO_CODEC_OPUS, .sample_rate = 48000, .channel = 1},
        .audio_dir = ESP_PEER_MEDIA_DIR_SEND_RECV,
        .video_dir = ESP_PEER_MEDIA_DIR_NONE,
        .no_auto_reconnect = true, // a dropped call ends; the app opens a new one
        .enable_data_channel = true,
        .manual_ch_create = true,
        .extra_cfg = &extra,
        .extra_size = sizeof(extra),
        .on_state = on_state,
        .on_msg = on_msg,
        .on_video_info = on_video_info,
        .on_audio_info = on_audio_info,
        .on_video_data = on_video_data,
        .on_audio_data = on_audio_data,
        .on_channel_open = on_channel_open,
        .on_channel_close = on_channel_close,
        .on_data = on_data,
        .ctx = &g,
    };
    if (esp_peer_open(&cfg, esp_peer_get_default_impl(), &g.peer) != ESP_PEER_ERR_NONE) {
        ESP_LOGE(TAG, "esp_peer_open failed");
        release();
        return -10;
    }
    media_lib_thread_handle_t thread = NULL;
    g.peer_running = true;
    if (media_lib_thread_create_from_scheduler(&thread, "lk_peer_pub", peer_task, NULL) != ESP_PEER_ERR_NONE) {
        g.peer_running = false;
        release();
        return -10;
    }
    if (esp_peer_new_connection(g.peer) != ESP_PEER_ERR_NONE) {
        release();
        return -10;
    }
    // esp_peer emits the offer once candidate gathering is done (no trickle).
    if (!(media_lib_event_group_wait_bits(g.events, BIT_OFFER, OFFER_TIMEOUT_MS) & BIT_OFFER)) {
        ESP_LOGE(TAG, "no SDP offer within %d ms", OFFER_TIMEOUT_MS);
        release();
        return -10;
    }
    const int64_t t_offer = esp_timer_get_time();
    char conversation[64] = "";
    const int rc = sebastian_live_session_create(endpoint, secret, g.offer, g.answer, ANSWER_CAP + 1,
                                                 conversation, sizeof(conversation));
    const int64_t t_answer = esp_timer_get_time();
    if (rc != 0) {
        ESP_LOGW(TAG, "live session request failed: %d", rc);
        release();
        return rc;
    }
    esp_peer_msg_t answer = {.type = ESP_PEER_MSG_TYPE_SDP, .data = (uint8_t *)g.answer, .size = (int)strlen(g.answer)};
    if (esp_peer_send_msg(g.peer, &answer) != ESP_PEER_ERR_NONE) {
        ESP_LOGE(TAG, "answer rejected");
        release();
        return -10;
    }
    if (start_media() != 0) {
        release();
        return -10;
    }
    ESP_LOGI(TAG, "live session %s: offer %d bytes in %lld ms, answer %d bytes in %lld ms", conversation,
             (int)strlen(g.offer), (t_offer - t0) / 1000, (int)strlen(g.answer), (t_answer - t_offer) / 1000);
    return 0;
}

int live_peer_state(void) { return atomic_load(&g.state); }

bool live_peer_send_json(const char *json) {
    const uint16_t stream_id = (uint16_t)atomic_load(&g.stream_id);
    if (!g.peer || !json || stream_id == STREAM_ID_INVALID) return false;
    esp_peer_data_frame_t frame = {
        .type = ESP_PEER_DATA_CHANNEL_STRING,
        .stream_id = stream_id,
        .data = (uint8_t *)json,
        .size = (int)strlen(json),
    };
    return esp_peer_send_data(g.peer, &frame) == ESP_PEER_ERR_NONE;
}

void live_peer_close(void) {
    if (!g.peer && !g.events) return;
    // Graceful close: the server finalizes usage and sends session.closed. Keep
    // media and the channel alive until then (bounded), as the docs require.
    if (live_peer_send_json("{\"type\":\"session.close\"}") && g.events) {
        if (!(media_lib_event_group_wait_bits(g.events, BIT_CLOSED, CLOSE_ACK_TIMEOUT_MS) & BIT_CLOSED)) {
            ESP_LOGW(TAG, "no session.closed within %d ms", CLOSE_ACK_TIMEOUT_MS);
        }
    }
    release();
    ESP_LOGI(TAG, "closed");
}

void live_peer_prepare(void) {
    if (esp_peer_pre_generate_cert() != ESP_PEER_ERR_NONE) ESP_LOGW(TAG, "DTLS cert pre-generation failed");
}

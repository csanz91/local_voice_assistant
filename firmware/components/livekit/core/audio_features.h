#pragma once
#include "livekit_rtc.pb.h"
/* Capacity two is required: stereo and native pre-connect are independent. */
static inline void livekit_set_audio_features(livekit_pb_add_track_request_t *req,
                                             bool stereo, bool preconnect)
{
    req->audio_features_count = 0;
    if (stereo) req->audio_features[req->audio_features_count++] = LIVEKIT_PB_AUDIO_TRACK_FEATURE_TF_STEREO;
    if (preconnect) req->audio_features[req->audio_features_count++] = LIVEKIT_PB_AUDIO_TRACK_FEATURE_TF_PRECONNECT_BUFFER;
}

#pragma once
#include <stdbool.h>
#include <stddef.h>
#define LIVEKIT_PARTICIPANT_ATTRIBUTES_MAX 16
#define LIVEKIT_PARTICIPANT_TRACKS_MAX 8
/* Excess/oversize attributes are skipped; lk.agent.state has priority. */
typedef struct { char key[64]; char value[128]; } livekit_pb_attribute_t;
typedef struct {
    size_t count;
    bool truncated;
    livekit_pb_attribute_t entries[LIVEKIT_PARTICIPANT_ATTRIBUTES_MAX];
} livekit_pb_attributes_t;

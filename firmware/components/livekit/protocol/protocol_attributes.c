#include "livekit_models.pb.h"
#include "pb_decode.h"
#include "pb_encode.h"
#include <string.h>

/* Nanopb message callback: works inside pointer participants/oneof responses,
 * unlike pb_callback_t callbacks that would require preinitializing each object. */
bool livekit_pb_attributes_callback(pb_istream_t *in, pb_ostream_t *out, const pb_field_t *field)
{
    livekit_pb_attributes_t *attrs = field->pData;
    if (in) {
        livekit_pb_attribute_t entry = {0};
        bool valid = true;
        while (in->bytes_left) {
            pb_wire_type_t wire;
            uint32_t tag;
            bool eof;
            if (!pb_decode_tag(in, &wire, &tag, &eof)) return false;
            if ((tag == 1 || tag == 2) && wire == PB_WT_STRING) {
                pb_istream_t str;
                if (!pb_make_string_substream(in, &str)) return false;
                char *dest = tag == 1 ? entry.key : entry.value;
                size_t cap = tag == 1 ? sizeof(entry.key) : sizeof(entry.value);
                size_t len = str.bytes_left;
                if (len >= cap) valid = false;
                else {
                    memset(dest, 0, cap);
                    if (!pb_read(&str, (pb_byte_t *)dest, len)) return false;
                    if (memchr(dest, '\0', len)) valid = false;
                }
                if (!pb_close_string_substream(in, &str)) return false;
            } else if (!pb_skip_field(in, wire)) return false;
        }
        if (!valid || entry.key[0] == '\0') { attrs->truncated = true; return true; }
        size_t index = attrs->count;
        for (size_t i = 0; i < attrs->count; i++) {
            if (!strcmp(attrs->entries[i].key, entry.key)) { index = i; break; }
        }
        if (index == LIVEKIT_PARTICIPANT_ATTRIBUTES_MAX) {
            attrs->truncated = true;
            if (strcmp(entry.key, "lk.agent.state")) return true;
            index--; /* Preserve the state even after unrelated attribute overflow. */
        }
        attrs->entries[index] = entry;
        if (index == attrs->count) attrs->count++;
        return true;
    }
    if (out) {
        if (attrs->count > LIVEKIT_PARTICIPANT_ATTRIBUTES_MAX) return false;
        for (size_t i = 0; i < attrs->count; i++) {
            pb_byte_t encoded[324];
            pb_ostream_t map = pb_ostream_from_buffer(encoded, sizeof(encoded));
            const livekit_pb_attribute_t *entry = &attrs->entries[i];
            size_t key_len = strnlen(entry->key, sizeof(entry->key));
            size_t value_len = strnlen(entry->value, sizeof(entry->value));
            if (key_len == sizeof(entry->key) || value_len == sizeof(entry->value)) return false;
            if (!pb_encode_tag(&map, PB_WT_STRING, 1) || !pb_encode_string(&map, (const pb_byte_t *)entry->key, key_len) ||
                !pb_encode_tag(&map, PB_WT_STRING, 2) || !pb_encode_string(&map, (const pb_byte_t *)entry->value, value_len) ||
                !pb_encode_tag_for_field(out, field) || !pb_encode_string(out, encoded, map.bytes_written)) return false;
        }
    }
    return true;
}

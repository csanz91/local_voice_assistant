/* Host test links production nanopb bindings and data-stream writer/reader. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pb_encode.h"
#include "pb_decode.h"
#include "audio_features.h"
#include "data_stream_writer.h"
#include "data_stream_reader.h"

static data_stream_reader_handle_t reader;
static int opens, chunks, closes;
static size_t received;
int64_t get_unix_time_ms(void) { return 123; }
void generate_uuid(char out[37]) { strcpy(out, "12345678-1234-4234-8234-123456789012"); }
static void on_open(const livekit_data_stream_header_t *h, void *ctx)
{
    assert(h->attributes_count == 3 && !h->is_text && h->total_length == 6400);
    assert(!strcmp(h->sender_identity, "device"));
    assert(!strcmp(h->attributes[0].key, "trackId") && !strcmp(h->attributes[0].value, "TR_audio"));
    assert(!strcmp(h->attributes[1].value, "16000"));
    assert(!strcmp(h->attributes[2].value, ctx));
    opens++;
}
static void on_chunk(const livekit_data_stream_chunk_t *c, void *ctx) { (void)ctx; chunks++; received += c->content_size; }
static void on_close(const livekit_data_stream_trailer_t *t, void *ctx) { (void)ctx; assert(!t->reason[0]); closes++; }
static bool send_packet(const livekit_pb_data_packet_t *packet, void *ctx)
{
    (void)ctx;
    uint8_t wire[17000];
    pb_ostream_t out = pb_ostream_from_buffer(wire, sizeof(wire));
    assert(pb_encode(&out, LIVEKIT_PB_DATA_PACKET_FIELDS, packet));
    livekit_pb_data_packet_t decoded = LIVEKIT_PB_DATA_PACKET_INIT_ZERO;
    pb_istream_t in = pb_istream_from_buffer(wire, out.bytes_written);
    assert(pb_decode(&in, LIVEKIT_PB_DATA_PACKET_FIELDS, &decoded));
    if (decoded.which_value == LIVEKIT_PB_DATA_PACKET_STREAM_HEADER_TAG)
        assert(!data_stream_reader_handle_header(reader, decoded.value.stream_header, "device"));
    else if (decoded.which_value == LIVEKIT_PB_DATA_PACKET_STREAM_CHUNK_TAG)
        assert(!data_stream_reader_handle_chunk(reader, decoded.value.stream_chunk));
    else assert(!data_stream_reader_handle_trailer(reader, decoded.value.stream_trailer));
    pb_release(LIVEKIT_PB_DATA_PACKET_FIELDS, &decoded);
    return true;
}
static void streams(const char *channels)
{
    assert(!data_stream_reader_create(&reader));
    livekit_data_stream_handler_t handler = { .on_open=on_open, .on_recv=on_chunk, .on_close=on_close, .ctx=(void *)channels };
    assert(!data_stream_reader_register(reader, "lk.agent.pre-connect-audio-buffer", &handler));
    data_stream_writer_handle_t writer;
    data_stream_writer_options_t wo = { .send_packet=send_packet };
    assert(!data_stream_writer_create(&writer, &wo));
    livekit_attribute_t attrs[] = { {"trackId","TR_audio"}, {"sampleRate","16000"}, {"channels", channels} };
    livekit_data_stream_options_t options = { .topic="lk.agent.pre-connect-audio-buffer", .total_length=6400, .has_total_length=true, .attributes=attrs, .attributes_count=3 };
    livekit_data_stream_handle_t stream;
    options.attributes_count=4; assert(data_stream_writer_open(writer, &options, &stream)==DATA_STREAM_WRITER_ERR_INVALID_ARG);
    options.attributes_count=3;
    attrs[2].key="trackId"; assert(data_stream_writer_open(writer, &options, &stream)==DATA_STREAM_WRITER_ERR_INVALID_ARG);
    attrs[2].key="channels";
    char too_long[129]; memset(too_long,'x',128); too_long[128]=0;
    attrs[2].value=too_long; assert(data_stream_writer_open(writer, &options, &stream)==DATA_STREAM_WRITER_ERR_INVALID_ARG);
    attrs[2].value=channels;
    assert(!data_stream_writer_open(writer, &options, &stream));
    uint8_t pcm[6400]={0}; assert(!data_stream_writer_write(writer, stream, pcm, sizeof(pcm)));
    assert(!data_stream_writer_close(writer, stream));
    assert(!data_stream_writer_destroy(writer)); assert(!data_stream_reader_destroy(reader));
}
static void features(void)
{
    for(int stereo=0;stereo<2;stereo++) for(int pre=0;pre<2;pre++) {
        livekit_pb_signal_request_t request=LIVEKIT_PB_SIGNAL_REQUEST_INIT_ZERO;
        request.which_message=LIVEKIT_PB_SIGNAL_REQUEST_ADD_TRACK_TAG;
        livekit_set_audio_features(&request.message.add_track, stereo, pre);
        uint8_t wire[256]; pb_ostream_t out=pb_ostream_from_buffer(wire,sizeof(wire));
        assert(pb_encode(&out,LIVEKIT_PB_SIGNAL_REQUEST_FIELDS,&request));
        livekit_pb_signal_request_t decoded=LIVEKIT_PB_SIGNAL_REQUEST_INIT_ZERO;
        pb_istream_t in=pb_istream_from_buffer(wire,out.bytes_written);
        assert(pb_decode(&in,LIVEKIT_PB_SIGNAL_REQUEST_FIELDS,&decoded));
        assert(decoded.message.add_track.audio_features_count==stereo+pre);
        if(stereo) assert(decoded.message.add_track.audio_features[0]==LIVEKIT_PB_AUDIO_TRACK_FEATURE_TF_STEREO);
        if(pre) assert(decoded.message.add_track.audio_features[stereo]==LIVEKIT_PB_AUDIO_TRACK_FEATURE_TF_PRECONNECT_BUFFER);
        pb_release(LIVEKIT_PB_SIGNAL_REQUEST_FIELDS,&decoded);
    }
}
static void signal_roundtrip(livekit_pb_signal_response_t *response)
{
    uint8_t wire[16000]; pb_ostream_t out=pb_ostream_from_buffer(wire,sizeof(wire));
    assert(pb_encode(&out,LIVEKIT_PB_SIGNAL_RESPONSE_FIELDS,response));
    livekit_pb_signal_response_t decoded=LIVEKIT_PB_SIGNAL_RESPONSE_INIT_ZERO;
    pb_istream_t in=pb_istream_from_buffer(wire,out.bytes_written);
    assert(pb_decode(&in,LIVEKIT_PB_SIGNAL_RESPONSE_FIELDS,&decoded));
    if(response->which_message==LIVEKIT_PB_SIGNAL_RESPONSE_TRACK_PUBLISHED_TAG) {
        assert(!strcmp(decoded.message.track_published.cid,"a0"));
        assert(!strcmp(decoded.message.track_published.track.sid,"TR_audio"));
        assert(decoded.message.track_published.track.source==LIVEKIT_PB_TRACK_SOURCE_MICROPHONE);
    } else {
        livekit_pb_participant_info_t *p=response->which_message==LIVEKIT_PB_SIGNAL_RESPONSE_JOIN_TAG ?
            &decoded.message.join.other_participants[0] : &decoded.message.update.participants[0];
        assert(p->kind==LIVEKIT_PB_PARTICIPANT_INFO_KIND_AGENT);
        assert(p->attributes.count==1 && !strcmp(p->attributes.entries[0].key,"lk.agent.state"));
        const livekit_pb_participant_info_t *expected=response->which_message==LIVEKIT_PB_SIGNAL_RESPONSE_JOIN_TAG ?
            &response->message.join.other_participants[0] : &response->message.update.participants[0];
        assert(!strcmp(p->attributes.entries[0].value,expected->attributes.entries[0].value));
        assert(p->tracks_count==expected->tracks_count);
        if(p->tracks_count) assert(!strcmp(p->tracks[0].name,"roomio_audio"));
    }
    pb_release(LIVEKIT_PB_SIGNAL_RESPONSE_FIELDS,&decoded);
    /* Decoder must release fields allocated before a malformed tail. This is
     * the parse-error ownership path used before signaling frees its object. */
    livekit_pb_signal_response_t *partial=calloc(1,sizeof(*partial));
    assert(partial);
    in=pb_istream_from_buffer(wire,out.bytes_written-1);
    assert(!pb_decode(&in,LIVEKIT_PB_SIGNAL_RESPONSE_FIELDS,partial));
    free(partial);
}
static void signals(void)
{
    livekit_pb_track_info_t track=LIVEKIT_PB_TRACK_INFO_INIT_ZERO;
    track.sid="TR_audio"; strcpy(track.name,"roomio_audio"); track.source=LIVEKIT_PB_TRACK_SOURCE_MICROPHONE;
    livekit_pb_signal_response_t response=LIVEKIT_PB_SIGNAL_RESPONSE_INIT_ZERO;
    response.which_message=LIVEKIT_PB_SIGNAL_RESPONSE_TRACK_PUBLISHED_TAG;
    strcpy(response.message.track_published.cid,"a0"); response.message.track_published.track=track;
    signal_roundtrip(&response);
    livekit_pb_participant_info_t agent=LIVEKIT_PB_PARTICIPANT_INFO_INIT_ZERO;
    agent.kind=LIVEKIT_PB_PARTICIPANT_INFO_KIND_AGENT;
    agent.attributes.count=1; strcpy(agent.attributes.entries[0].key,"lk.agent.state"); strcpy(agent.attributes.entries[0].value,"listening");
    agent.tracks_count=1; agent.tracks=&track;
    memset(&response,0,sizeof(response)); response.which_message=LIVEKIT_PB_SIGNAL_RESPONSE_JOIN_TAG;
    response.message.join.other_participants_count=1; response.message.join.other_participants=&agent; signal_roundtrip(&response);
    memset(&response,0,sizeof(response)); response.which_message=LIVEKIT_PB_SIGNAL_RESPONSE_UPDATE_TAG;
    response.message.update.participants_count=1; response.message.update.participants=&agent;
    strcpy(agent.attributes.entries[0].value,"speaking"); signal_roundtrip(&response);
    agent.attributes.entries[0].value[0]=0; agent.tracks_count=0; signal_roundtrip(&response);
}
static void attribute_overflow(void)
{
    uint8_t wire[7000]; pb_ostream_t out=pb_ostream_from_buffer(wire,sizeof(wire));
    assert(pb_encode_tag(&out,PB_WT_STRING,11) && pb_encode_string(&out,NULL,0));
    for(int i=0;i<21;i++) {
        uint8_t map[512]; pb_ostream_t m=pb_ostream_from_buffer(map,sizeof(map));
        char key[64]; snprintf(key,sizeof(key),"other.%d",i);
        const char *k=i==20 ? "lk.agent.state" : key;
        char oversize[129]; memset(oversize,'x',128); oversize[128]=0;
        const char *v=i==20 ? "speaking" : i==19 ? oversize : "unused";
        assert(pb_encode_tag(&m,PB_WT_STRING,1) && pb_encode_string(&m,(const uint8_t*)k,strlen(k)));
        assert(pb_encode_tag(&m,PB_WT_STRING,2) && pb_encode_string(&m,(const uint8_t*)v,strlen(v)));
        assert(pb_encode_tag(&out,PB_WT_STRING,15) && pb_encode_string(&out,map,m.bytes_written));
    }
    livekit_pb_participant_info_t p=LIVEKIT_PB_PARTICIPANT_INFO_INIT_ZERO;
    pb_istream_t in=pb_istream_from_buffer(wire,out.bytes_written);
    assert(pb_decode(&in,LIVEKIT_PB_PARTICIPANT_INFO_FIELDS,&p));
    assert(p.attributes.count==16 && p.attributes.truncated);
    assert(!strcmp(p.attributes.entries[15].key,"lk.agent.state"));
    assert(!strcmp(p.attributes.entries[15].value,"speaking"));
    pb_release(LIVEKIT_PB_PARTICIPANT_INFO_FIELDS,&p);
}
int main(void)
{
    features(); streams("1"); streams("2"); signals(); attribute_overflow();
    assert(opens==2 && chunks==2 && closes==2 && received==12800);
    puts("C SDK compatibility: mono/stereo features, native streams/attributes, invalid bounds, publication SID, join/update state/tracks, attribute overflow passed");
}

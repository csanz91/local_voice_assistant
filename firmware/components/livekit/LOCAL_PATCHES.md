# Local LiveKit SDK patch

Base component: LiveKit ESP32 **0.3.10** (Apache-2.0; retain upstream LICENSE).
The initial project vendored this component. `core/peer.c` creates data channels
only for `PEER_ROLE_PUBLISHER`; the subscriber must not create a competing SCTP
association. Preserve the publisher-role condition at `ESP_PEER_STATE_DATA_CHANNEL_CONNECTED`
and the corresponding role conditions in peer configuration.

The peer setting `no_auto_reconnect` is **false**. An earlier main manifest
incorrectly described a `true` change. WebSocket automatic reconnect is disabled
independently in `core/signaling.c`; session recovery belongs to the application.

`core/signaling.c` attaches `esp_crt_bundle_attach` when
`CONFIG_MBEDTLS_CERTIFICATE_BUNDLE` is enabled. The firmware defaults explicitly
enable it, and session responses require WSS except for a provisioned LAN dev opt-in.
Do not remove this override or upgrade the SDK during firmware extraction.

## Native RoomIO compatibility (2026-10-20)

The component and protocol revision remain pinned; these are local changes to
0.3.10, not an SDK/protocol upgrade.

- `livekit_room_options_t.enable_preconnect_buffer` opts the published microphone
  into `TF_PRECONNECT_BUFFER`. Stereo remains independently advertised; the
  generated AddTrackRequest capacity is two. The default remains disabled.
- Outgoing stream options and incoming open callbacks carry up to three string
  attributes (31-byte keys, 127-byte values, excluding terminators). The writer
  rejects invalid, duplicate or oversized entries before creating a stream.
  Native RoomIO uses `trackId`, `sampleRate`, `channels`; chunks remain raw PCM.
- TrackPublishedResponse is decoded. A response matching local microphone CID
  `a0`, audio type and microphone source invokes `on_local_track_published` with
  the server's track SID. This applies during initial signaling and connected
  operation.
- Initial join snapshots and subsequent participant updates expose attributes
  and track information. Participant attribute storage is fixed at 16 entries,
  keys 63 bytes and values 127 bytes. The nanopb message callback skips oversized
  and excess entries while preserving `lk.agent.state` even if encountered after
  unrelated entries fill the storage. Empty values remain empty, including state
  removal. `info_truncated` marks omitted participant information. Public track
  projection is limited to eight tracks; the existing SDK's pointer-backed
  underlying track-list decoding is retained. Track names are bounded to 63 bytes
  by nanopb; oversized track names reject that signaling message.
- All pointers, strings and arrays passed to info/data-stream callbacks are
  borrowed until callback return. Retained SIDs, attributes or track names must
  be copied. Outgoing attributes need only remain alive through stream open.
- `audio_receive_filter` is an optional, nonblocking, thread-safe peer-thread
  predicate before encoded audio reaches `av_render_add_audio_data`. False drops
  an arriving frame. The application still owns renderer flushing and gate
  policy; this is not an RTP epoch or acoustic-playout barrier.
- Signaling response objects now live on the heap and are transferred to the
  engine queue by pointer, then released on every rejection/cleanup path. Fixed
  participant attribute storage must not enlarge WebSocket/engine stack frames
  or every event queue slot by several kilobytes.
- C/Zig ILP32 ABI guards agree: participant info 44 bytes, stream options 32,
  room options 80 (84 after the 2026-11-22 track filter below). Existing
  room-option fields keep their offsets; new fields follow `ctx`. Public attribute pairs are 8 bytes and track info is 20 bytes.

## Upstream engine fixes (2026-11-23)

Cherry-picked from `Zetesis-Labs/Sebastian`:

- `5a2cdb4`: the engine task's stack and event queue live in PSRAM, which saves
  about 14 KB of internal RAM per room. The task now suspends when it finishes and
  `engine_destroy` deletes it. **Nothing that runs on the engine task may use the
  flash, including NVS**: `spi_flash` asserts. Check this when adding a room
  callback.
- `ed0fb96` (upstream branch `fix/engine-destroy-peers`, not on its `main`):
  `engine_destroy` stops the peers with `destroy_peer_connections`, so closing a
  room mid-negotiation cannot leave peer tasks using freed memory.

## Device-control follow-up (2026-11-22)

Still 0.3.10 with no protocol upgrade:

- `livekit_room_options_t.audio_track_filter` (offset 80, size now 84) is an
  optional predicate `(participant_sid, track_name, ctx)` consulted before
  subscribing to a remote audio track. `NULL` keeps the previous behavior
  (subscribe to the first remote audio track). Firmware accepts only the pinned
  agent's `roomio_audio`.
- `handle_participant_update` now invokes `on_participant_info` before
  `subscribe_tracks` for remote participants, so an application can bind the
  agent from the same update that first carries its track.
- Data-stream reader/writer copy fixed-size `stream_id` arrays with `memcpy`
  guarded by `_Static_assert` on equal sizes, instead of `strlcpy`. The host
  fixture builds with `-D_POSIX_C_SOURCE=200809L`, where `strlcpy` is not
  declared on every libc.
- Pre-roll credits rely on one existing property, not a patch: stream chunks
  and `livekit_room_publish_data(lossy=false)` both go through
  `engine_send_data_packet(reliable=true)`, which is the publisher's single
  ordered reliable channel.

Bindings were regenerated from the existing vendored `.proto` files using
`nanopb==0.4.9.1` and the existing `protocol/update/update.py`'s
`generate_bindings()` function, **without** calling its downloader/main function.
With `protoc` and that nanopb generator on PATH, run from `protocol/update/`:

```sh
python -c 'import update; update.generate_bindings()'
```

Host regression checks link the production writer, reader, generated bindings,
custom attribute decoder and managed nanopb runtime:

```sh
firmware/components/livekit/test_app/host/run.sh
```

They use AddressSanitizer/UndefinedBehaviorSanitizer and cover all mono/stereo
feature combinations, native stream attributes and raw chunk delivery, invalid
attribute bounds/duplicates, publication CID/SID, join snapshots, participant
updates, excess/oversized attributes and preservation of agent state. No real
room, service, credentials or hardware is used. ESP32 rendering, transport timing,
provider behavior and acoustic wake acceptance require separate board tests.

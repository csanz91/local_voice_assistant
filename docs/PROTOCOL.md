# Native LiveKit device protocol

This is the implemented IoTCloud device contract. The earlier Phase 1 SBPR and
`sebastian.*` topics are superseded. The existing agent retains standard RoomIO,
providers, tools, turn detection and lifecycle. See [SDK proof](SDK_COMPATIBILITY.md).

## Provisioning and session creation

Register the device in the existing IoTCloud inventory under its location. The
location **owner**, authenticated through the normal user API, requests:

```http
POST /api/v2/device-voice-credential/device_id/{inventory-device-id}
Authorization: Bearer <owner's normal access token>
```

HTTP 200 returns `token` and `expiresAt`. This is a voice-scoped device bearer,
valid for 90 days. Provision it as `device.secret` over USB; provision the full
HTTPS URL `https://YOUR_API/api/v2/device-voice-session` as
`livekit.tokenServerUrl`. The hardware MAC is diagnostic, not the inventory
authorization identity. No random local credential is generated. Never provision
owner access/refresh tokens, M2M keys, MQTT signing keys or LiveKit API keys.

On wake the firmware sends exactly:

```http
POST /api/v2/device-voice-session
Authorization: Bearer <device voice credential>
Content-Type: application/json

{}
```

The adapter rejects caller-supplied context/model/template authority, checks the
credential's signature, issuer, audience, scope, role and expiry, then rechecks
the existing device/location/current owner. It reuses the normal voice call
service with **AUDIO at session startup** and signs an immutable participant
attribute `iotcloud.device.voice=1`. Browser/mobile/SIP sessions keep their prior
path. The voice credential is not accepted by MQTT. Deletion, movement or an
ownership change denies the old credential; issuing a replacement does **not**
revoke an earlier token on its own. There is no new revocation database. Reprovision
before expiry. Shared signing-key rotation affects all credentials using that key.

HTTP 200 returns the existing service response:

```json
{"serverUrl":"wss://livekit.example","participantToken":"<short-lived JWT>","roomName":"web_<uuid>","conversationId":"<uuid>"}
```

The firmware bounds the complete body to 1,535 bytes, URL to 255 bytes, participant
token to 1,279 bytes, room name to 127 bytes and provisioned bearer to 1,024 bytes.
HTTPS and WSS require certificate and hostname verification. Plain HTTP/WS needs
the explicit `livekit.allowInsecureHttp=true` development opt-in. Redirects are
refused; failed opens return to local wake listening without credential logging.
The API prefix is part of the provisioned complete URL; firmware never appends it.

## Native pre-roll and state

The device publishes its ordinary mono 48 kHz Opus microphone with
`TF_PRECONNECT_BUFFER`. It waits for its actual server-assigned microphone SID
and the selected agent's standard `roomio_audio` publication. It then switches the
microphone track to live capture **first** and sends **one** reliable byte stream
on `lk.agent.pre-connect-audio-buffer`, with no declared total length:

| Header attribute | Value |
| --- | --- |
| `trackId` | Published microphone SID |
| `sampleRate` | `16000` |
| `channels` | `1` |

The body is raw signed PCM16 little endian mono at 16 kHz with no SBPR header or
duplex flags. The window is anchored to the wake mark: two seconds before the
wake word through the handoff, bounded by the 12-second PSRAM ring (at most
384,000 bytes). After a wake the ring stops overwriting once it holds 12 seconds
past the mark, so the start of the command survives a slow join of up to
12 seconds; the two-second lead is lost after 10 seconds. Muting clears the ring,
and nothing is sent if the device is muted at handoff.

The stream is sent in 64 KiB batches (32,768 samples). After each batch except the
last, the device reliably sends the 4-byte little-endian batch number to the pinned
agent on `iotcloud.device.preroll.credit` and waits for the agent to echo the same
four bytes on `iotcloud.device.preroll.credit.ack`. Credits, stream chunks and
other data use the publisher's single ordered reliable data channel, so the echo
shows that the preceding bytes have left the C SDK's 100 KiB SCTP send cache.
(Oversized bursts into that cache previously corrupted the heap.) The whole send
must finish within 2.5 seconds. RoomIO applies two separate three-second limits:
- **Stream read:** the read must complete within three seconds of stream open,
  or it is cancelled.
- **Agent wait:** the agent waits at most three seconds for the buffer, counted
  from when it subscribes to the microphone. That can be earlier than stream
  open. If this wait expires, the **whole** pre-roll is discarded, even if the
  stream completes later. RoomIO logs `timeout waiting for pre-connect audio
  buffer`, while the firmware still logs a successful send. Watch the agent log
  for this during board acceptance.

In loopback, subscription to stream open took 9 ms, and 128 KB went out in 20 ms.
Real ESP32 Wi-Fi timing has not been measured. On a device deadline or write
failure the device closes the stream early. Without a declared length this is a
valid, shorter stream that RoomIO still uses (if its wait has not expired); the
missing part is the newest audio nearest the live seam. The firmware logs
`sent pre-roll … batches= send_ms=` or `send pre-roll truncated … sent_bytes= of …`.

Native RoomIO owns pre-roll decoding, resampling and ordering. It buffers live
frames that arrive while it waits for the stream, then plays the pre-roll followed
by those buffered live frames, so speech spoken during the send is not lost. The
microphone sends silence until the handoff. That silence (from subscription to
handoff) is also buffered, and it follows the pre-roll. RoomIO waits three seconds
after track attachment, and it may discard a completed stream older than one
second before attachment. Do not send before the handler-ready output track event
or wait for `listening` after an early mic publication. AUDIO-at-start is
required: the existing text-first lazy audio path has no native handler.

The native handoff is once per mic SID. A failed or partial attempt falls back to
normal live audio; it is not retried as a second injection. Mid-session wake
speech uses the normal live microphone path.

State comes from the participant attribute `lk.agent.state`, including initial
snapshots and later updates. `speaking` drives the speaking indicator and
half-duplex mic gate; `listening` and `thinking` update the local UI. Room close,
agent disconnect/reconnect, silence and maximum-duration watchdogs govern session
end. Agent state and session close use no custom topics. The only custom topics
are the pre-roll credits above and the wake control topics below.

Each fresh call has a unique room with a device and its dispatched agent. The
firmware pins the first server-classified agent's identity and participant SID
for that room generation; other/stale callbacks cannot control the session. It
subscribes only to that agent's `roomio_audio` track. This assumes the backend
issues no other participant tokens for that private call.

## Wake interruption (control version 2)

Both duplex profiles detect the local wake word while the agent is speaking.
The device immediately blocks incoming speaker audio and flushes queued PCM,
then reliably sends to the pinned agent on `iotcloud.device.wake`:

```json
{"version":2,"request_id":"<unique-session-sequence>","room":"<roomName>"}
```

IDs contain 1–64 ASCII letters, digits, underscores or hyphens. Messages are at
most 512 bytes and have exactly these keys. The agent checks the reliable channel,
actual current linked participant, signed opt-in attribute, room and request,
then calls the existing `session.interrupt(force=False)`. It replies reliably to
that participant on `iotcloud.device.wake.result`, echoing the request version:

```json
{"version":2,"request_id":"<same-id>","status":"accepted","reason":"interrupted"}
```

Rejection uses `status=rejected`, with `policy`, `not_ready`, `timeout` or
`invalid`. Noninterruptible greetings keep their current policy. One request runs
at a time; duplicate completed IDs replay their result and never interrupt a new
response. The helper retains at most 128 IDs per session and bounds its wait and
publication to two seconds each. New IDs after that limit are rejected.

The firmware accepts only its pending request's version-2 result from the pinned
agent and treats the outcomes differently:

| Result | Device action |
| --- | --- |
| `accepted` / `interrupted` | Drain, then reopen and send resume (below) |
| `rejected` / `policy` | Reopen after the 250 ms guard; the protected speech continues and the real half-duplex mic gate is restored |
| `rejected` / `not_ready`, `timeout`, `invalid` | Keep incoming audio gated and close the session: the old reply may still be live |

### Next-reply hold

Acknowledgement is **not an RTP barrier**: the SDK experiment observed another
58–126 ms of non-silent media after it. For an accepted version-2 request, the
agent therefore holds every frame of the *next* reply until the device has drained.
`DeviceOutputHold` is inserted directly above the RoomIO room sink, below the
transcript/recorder wrappers, and only for sessions with a device-marked
participant. It is installed while idle. It is deliberately not
`AudioOutput.pause()`: Agents 1.8.12 calls `resume()` on the output chain whenever
a reply starts forwarding (`AgentActivity._reconcile_playout_pause`). The hold is
separate from pause/resume, which still pass through for the SDK's own
false-interruption handling. Held frames never reach the room sink, so
`speaking` and playout accounting stay truthful. A held reply can itself be
interrupted, in which case its frames are dropped.

The device drain needs a 250 ms minimum guard and 150 ms without incoming audio
packets. Any packet counts, including silent ones. In loopback the idle agent track
sends packets only about every 400 ms (Opus DTX). After an accepted interrupt its
packets stopped for about 330 ms, until the device's resume released the held
reply. Without the hold, a fast reply keeps packets flowing and the drain can only
time out. The device then flushes its renderer again, opens the receive gate and
reliably sends the raw request ID bytes on `iotcloud.device.wake.resume`. The
agent releases the hold only for the matching ID from the linked device. If the
drain does not finish within five seconds of the request, the device closes the
session. If resume does not arrive within six seconds of the acknowledgement, the
agent shuts its session down, because the device has already closed. A wake
received while a hold is pending is rejected `invalid`. These are conservative
software bounds, not acoustic guarantees. Board tests must prove stale audio
cannot resume and the next utterance/reply is not clipped.

### Deployment order

Deploy the agent before version-2 firmware. The agent still accepts version 1
requests (no hold), so existing firmware keeps working. Version-2 firmware against
an older agent fails visibly: every wake gets `invalid` and the session closes.
Pre-roll also stalls for 2.5 seconds with no credit acknowledgement, then is cut
after its first 64 KiB batch.

## Disposable tests

`make check fw-fmt` runs firmware, production C SDK serialization/decode,
HTTP/provisioning and stdlib fixture checks. The C SDK fixtures use ASan/UBSan.
Installer checks run separately with `cd web-installer && npm test && npm run build`.

For local HTTP parsing checks, supply a disposable `FIXTURE_DEVICE_SECRET` and run:

```sh
python3 tools/protocol/session_fixture.py --device-id aabbccddeeff
```

The fixture is loopback by default and uses HTTP 200 plus Bearer authentication.
It accepts only `{}` and never implements real credential issuance or dispatch.
`--case` exercises 401/403/409/429/503, malformed/oversized JSON, missing token and
insecure WS. `--path` tests complete paths/queries; `--cert` and `--key` enable
HTTPS using supplied trust material. A fake participant token only tests parsing.

For actual LiveKit transport use an isolated server (for example
`livekit-server --dev --bind 127.0.0.1`, whose development key is `devkey`/`secret`), disposable
`LIVEKIT_URL`/`LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` environment values, Python 3.14,
and an existing temporary directory. Start the native test peer:

```sh
uv run --script tools/protocol/livekit_peer.py --device-id aabbccddeeff \
  --token-file /tmp/firmware-test/device.jwt \
  --wake-helper /PATH/TO/IotCloud2/voice/realtime_agent/app/services/session/device_wake.py
```

It uses the **production** interruption helper and pinned RoomIO, with synthetic
tones and no model, tools, transcripts or recordings. It writes new mode-0600
device-token and `.room` files. Once ready, serve those connection details:

```sh
python3 tools/protocol/session_fixture.py --device-id aabbccddeeff \
  --token-file /tmp/firmware-test/device.jwt
```

Then connect the board with the explicit LAN/HTTP development setting, or run:

```sh
uv run --script tools/protocol/simulate_device.py \
  --session-url http://127.0.0.1:8765/api/v2/device-voice-session --allow-insecure
```

The simulator waits for native readiness and sends four seconds of PCM with track
attributes, in credited 64 KiB batches. It checks the native states and the
production helper's correlated wake result. It also listens to the agent track
and fails if any fresh-reply audio arrives before it sends the resume. With the
old pause-based hold this check fails, because 4,800 samples leak through.
`--no-preroll --no-barge` checks normal live fallback and completed tone. Each run
needs fresh peer/token files; stop the fixture and remove only its temporary
credentials afterward. Physical networking, TLS, AEC, renderer drain, providers
and active delegation remain separate acceptance work.

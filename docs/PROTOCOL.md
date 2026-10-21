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
and the selected agent's standard `roomio_audio` publication, then sends **one**
reliable byte stream on `lk.agent.pre-connect-audio-buffer`:

| Header attribute | Value |
| --- | --- |
| `trackId` | Published microphone SID |
| `sampleRate` | `16000` |
| `channels` | `1` |

The body is raw signed PCM16 little endian mono at 16 kHz, capped at 80,000 bytes
(2.5 seconds). It has no SBPR header or duplex flags. The local PSRAM ring stays
bounded; a slow join can exceed the exported window. Native RoomIO owns pre-roll
decoding, resampling and ordering before live input. Its default wait is three
seconds after track attachment, and a completed stream older than one second
before attachment may be discarded. Do not send before the handler-ready output
track event or wait for `listening` after an early mic publication. AUDIO-at-start
is required: the existing text-first lazy audio path has no native handler.

The native handoff is once per mic SID. A failed/partial attempt falls back to
normal live audio; it is not retried as a second injection. Mid-session wake
speech uses the normal live microphone path.

State comes from the participant attribute `lk.agent.state`, including initial
snapshots and later updates. `speaking` drives the speaking indicator and
half-duplex mic gate; `listening` and `thinking` update the local UI. Room close,
agent disconnect/reconnect, silence and maximum-duration watchdogs govern session
end. There is no custom state or close data topic.

Each fresh call has a unique room with a device and its dispatched agent. The
firmware pins the first server-classified agent's identity and participant SID
for that room generation; other/stale callbacks cannot control the session. This
assumes the backend issues no other participant tokens for that private call.

## Wake interruption

Both duplex profiles detect the local wake word while the agent is speaking.
The device immediately blocks incoming speaker audio and flushes queued PCM,
then reliably sends to the pinned agent on `iotcloud.device.wake`:

```json
{"version":1,"request_id":"<unique-session-sequence>","room":"<roomName>"}
```

IDs contain 1–64 ASCII letters, digits, underscores or hyphens. Messages are at
most 512 bytes and have exactly these keys. The agent checks the reliable channel,
actual current linked participant, signed opt-in attribute, room and request,
then calls the existing `session.interrupt(force=False)`. It replies reliably to
that participant on `iotcloud.device.wake.result`:

```json
{"version":1,"request_id":"<same-id>","status":"accepted","reason":"interrupted"}
```

Rejection uses `status=rejected`, with `policy`, `not_ready`, `timeout` or
`invalid`. Noninterruptible greetings keep their current policy. One request runs
at a time; duplicate completed IDs replay their result and never interrupt a new
response. The helper retains at most 128 IDs per session and bounds its wait and
publication to two seconds each. New IDs after that limit are rejected.

The firmware accepts only its pending request's result from the pinned agent.
Acknowledgement is **not an RTP barrier**: the SDK experiment observed another
58–126 ms of non-silent media. The local drain uses a 250 ms minimum guard,
150 ms without incoming audio packets, and accepted interruption plus listening
state before reopening; a policy rejection restores the actual speaking/mic state.
Failure to drain/receive a result within five seconds closes the session. These
are conservative software bounds, not acoustic guarantees. Board tests must prove
stale audio cannot resume and the next utterance/reply is not clipped.

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

For actual LiveKit transport use an isolated server, disposable
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

The simulator waits for native readiness, sends PCM with track attributes and
checks native states plus the production helper's correlated wake result.
`--no-preroll --no-barge` checks normal live fallback and completed tone. Each run
needs fresh peer/token files; stop the fixture and remove only its temporary
credentials afterward. Physical networking, TLS, AEC, renderer drain, providers
and active delegation remain separate acceptance work.

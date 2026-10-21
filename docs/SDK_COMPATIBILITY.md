# LiveKit SDK compatibility proof

Recorded 2026-10-20 for Milestone 1 of [INTEGRATION_PLAN.md](INTEGRATION_PLAN.md).
This is an isolated compatibility experiment, not an implementation. The prior
over-scoped Phase 2 remains rolled back. No firmware, IoTCloud agent, SDK source,
dependency lock, existing service, or home-action code was changed for these
tests.

## Decision

For device calls that start in audio mode, keep the existing Python agent on
standard `AgentSession` and native RoomIO. The installed framework accepts the
standard LiveKit pre-connect stream, places it before live microphone frames,
resamples it into the ordinary input path, and publishes `lk.agent.state`. No
custom microphone input, second VAD controller, sidecar, or replacement
conversation path is needed.

For first-utterance pre-roll, wait for the agent's standard `roomio_audio` track
publication before sending the native byte stream. In the installed RoomIO
startup order, the pre-connect byte-stream handler is registered before that
output track is published. A `listening` state arrives after model-session setup
and can be too late for RoomIO's default three-second buffer wait. A six-second
device-session timeout passed the synthetic 4.25-second delay, but it cannot
recover data sent before handler registration and adds up to six seconds of
startup waiting. The agent track publication is the better readiness signal
for those audio-enabled sessions.

This does not cover a text-first session that enables audio later. The existing
`agent_pipeline.py` starts those sessions with RoomIO audio disabled, and
`LazySessionAudioIO.enable()` later creates an input stream with
`pre_connect_audio_handler=None`. Its later `roomio_audio` publication therefore
does not mean a native pre-connect handler is ready. Request the existing AUDIO
initial mode for the device call. If the device must enter through TEXT first,
the lazy-audio path needs a separate opt-in native-handler integration and a
new compatibility test; do not use its output publication as a readiness
signal by itself.

Native pre-connect audio is a one-time handoff for a published microphone SID.
The repeat test did not inject a second buffer sent on the same SID after its
first buffer was consumed. During a later wake or barge-in, keep using the
existing published microphone and forward the captured samples through its
normal live-audio path; do not resend pre-connect data on that SID. If a future
flow needs another native pre-roll handoff, it must publish a new microphone
track/SID or use the ordinary capture path.

For remote wake interruption, add only an explicit, session-scoped reliable
control-message handler. Bind it to the device linked by RoomIO, check the
LiveKit sender identity, call `session.interrupt(force=False)`, and return an
acknowledgement or a policy rejection. The API cancelled the active speech and
cleared RoomIO's actual output queue. It did **not** establish an RTP or hardware
playout barrier: non-silent frames arrived for 57.7 ms after the renderer ACK in
the asserted run (about 66.2 ms in a paced repeat and 126.2 ms in a faster burst
repeat). The firmware must flush locally as soon as wake is detected and keep
discarding stale output until an epoch/drain rule that passes board acceptance
allows playback again. The test's renderer queue was synthetic; it is not proof
of the C SDK or speaker's flush behavior.

## Tested environment and reproduction

The compatibility probe ran against the pinned IoTCloud interpreter and a
disposable LiveKit server:

| Component | Tested version |
| --- | --- |
| Python | 3.14 |
| `livekit-agents` | 1.8.8 (the repository pin) |
| Python RTC package `livekit` | 1.1.20 |
| `livekit-api` | 1.2.2 |
| Disposable LiveKit server | 1.13.6 |
| Vendored firmware C SDK | 0.3.10 (source inspected, not executed) |

This differs from [Phase 1's loopback test](PHASE1_VALIDATION.md), which used
Python RTC 1.1.12 and API 1.1.1. The source pin is in
`/Users/csanz/code/IotCloud2/voice/realtime_agent/pyproject.toml` and the
resolved versions are in its `uv.lock`.

The server used only generated disposable test credentials and loopback host
bindings (`127.0.0.1:27880` HTTP, `27881` RTC/TCP, `27882` RTC/UDP). It ran as a
separate `livekit/livekit-server:v1.13.6` container; unrelated Aurelia
containers were not touched. The client and agent joined unique temporary rooms.
No provider keys, real user tokens, external model/provider requests, tool calls,
home actions, or recorded audio were used.

With that server running and its disposable values supplied only in the process
environment, the full 11-case run is:

```sh
LIVEKIT_URL=ws://127.0.0.1:27880 \
LIVEKIT_API_KEY=<disposable-test-key> \
LIVEKIT_API_SECRET=<disposable-test-secret> \
/Users/csanz/code/IotCloud2/voice/realtime_agent/.venv/bin/python \
  docs/tools/sdk_compatibility_probe.py
```

The probe prints one JSON record per case plus a summary; it exits nonzero on a
case error or any failed assertion. `PROBE_CASES` can select a subset using the
case IDs in `main()`. The sanitized measurements and assertions are recorded in
[sdk_compatibility_results.json](tools/sdk_compatibility_results.json).

Eleven distinct cases passed, with 46 asserted checks and no failed or
inconclusive cases. Ten cases ran as one suite; the early-send-before-RoomIO
registration case ran separately against the same harness and server. The final
copied repository probe also reran that race case successfully. The probe wraps
native `wait_for_data()` only to record its timing and returned frame count, and
uses private members to observe session input frames and output queue depth. The
original RoomIO handler still receives and decodes the stream; production hooks
recommended here use public RoomIO behavior and `AgentSession.interrupt()`.

## Measured behavior

### Native pre-roll and readiness

- A normal `AgentSession` with default RoomIO received a 200 ms, 16 kHz mono
  deterministic pre-roll sent as 6,400 bytes. The microphone publication
  advertised `TF_PRECONNECT_BUFFER`; the stream used topic
  `lk.agent.pre-connect-audio-buffer` and the attributes `trackId`, `sampleRate`,
  and `channels`. Captured frames entered the standard activity input at 24 kHz,
  totaling approximately 200 ms, followed by 48 kHz live microphone audio
  resampled to the same input rate. Tone timestamps showed pre-roll before live
  input, with no second injection when the same SID was sent again after
  consumption. Frame grouping reflects the resampler; this is not a byte-for-byte
  round-trip claim.
- A completed byte stream delivered 200 ms before the microphone track was
  subscribed was accepted. At 1.2 seconds old it was discarded; the installed
  handler rejects an already completed buffer older than its one-second age
  window. Normal live input arrived in both cases.
- The current application order connects the room and can publish/subscribe the
  microphone before `session.start()` registers RoomIO. In that exact sequence,
  a 6,400-byte pre-roll sent 8 ms before `session.start()` was not replayed after
  registration; the native wait expired and 79 live-tone frames then reached
  input. Waiting for the standard agent output track avoids this registration
  race.
- A local `RealtimeModel` test double delayed its awaited session update by 4.25
  seconds. With RoomIO's default three-second timeout, the native wait expired
  about 1.25 seconds before model setup finished; late pre-roll was not injected,
  while live audio continued. Sending pre-roll on the normal `roomio_audio`
  publication event let the native handler accept and queue it before listening
  state and before the fake model update completed. The standard input
  forwarding task delivered those queued frames to the realtime session after
  the awaited model update finished. Setting the device-only native timeout to
  six seconds also retained pre-roll through that delay. These are framework timing tests,
  not timing claims for the real provider or the agent's preceding database,
  IoT, and tool setup.
- A microphone published only after the real `lk.agent.state=listening`
  attribute was observed also received pre-roll. That option delays microphone
  publication and would require a runtime publish/defer API in the current C
  client, so it is less attractive than exposing the agent track event.
- Omitting `sampleRate` and `channels` caused the native pre-roll reader to
  reject the payload. The normal live microphone path recovered without a
  session failure. The exercised pre-roll was 200 ms / 6,400 bytes; the Python
  handler does not impose a byte cap, and over-limit rejection was not tested.

### State and interruption

- The device observed the normal participant attribute `lk.agent.state` from
  the actual session, including its initial `listening` value and the
  `speaking → listening` updates during synthetic output. Separately, the local
  session event recorded the `initializing → listening` transition. The test
  agent token explicitly had
  `can_update_own_metadata=True`; production dispatch-token permission was not
  inspected. Use the state for UI and coarse microphone policy, not as proof
  that sound has left the physical speaker or as an RTP ordering barrier.
- A deterministic `session.say()` produced actual RoomIO output. The handler
  accepted a reliable control message from the linked device and ignored a
  message from another room participant. The RoomIO source queue measured
  207.4 ms before the unauthorized request, remained at 206.5 ms afterward, and
  was 0 ms after the authorized `interrupt()` future completed. The active
  generator was cancelled. The test exchanged a server result and a separate
  renderer-flush acknowledgement, then measured the remaining non-silent RTP
  tail described above.
- `session.interrupt(force=False)` preserved the per-speech policy. When a test
  speech disallowed interruption, the handler received `RuntimeError`, the
  generator continued, and the correct outcome was rejection rather than forced
  cancellation. The production initial-speech paths have different policies:
  `app/agent_pipeline.py` uses `runtime_settings.allow_initial_reply_interruptions`,
  while the speaks-first `generate_reply()` in `app/agent.py` explicitly sets
  `allow_interruptions=False`. A wake request during either noninterruptible
  greeting will be rejected. Preserve each rule and include both cases in
  acceptance.
- The standard `AgentSession`/RoomIO input boundary and a realtime-session input
  boundary both received synthetic pre-roll and live audio. Realtime startup was
  represented by an in-process `RealtimeModel`/`RealtimeSession` test double
  whose `update_instructions` awaited a controlled delay. No real STT, model,
  provider, or conversation tool ran.

The harness emitted `FfiHandle.__del__` assertion traces during Python teardown
(30 in the 10-case run; a cleanup smoke after explicitly closing audio streams
logged 19; the separate registration-race run logged 7). The probe processes
exited successfully and the functional assertions passed. The report treats
this as a harness/SDK cleanup limitation; no dependency or production workaround
was attempted.

## Minimal changes supported by evidence

### Agent

For AUDIO-at-start device sessions, no agent audio-path replacement, startup
reorder, extra VAD, or fleet/service change is indicated. Request the existing
AUDIO initial mode, and keep `ctx.connect()`, the existing session factory,
provider construction, tool/delegation setup, recording, metrics, and normal
session lifecycle. Let native RoomIO register its handler at `session.start()`;
the device waits for the standard agent audio track before sending first
pre-roll. Do not lengthen the timeout globally. If timing on the real provider
proves a longer post-registration wait is needed, make the timeout opt-in for
device sessions only.

Wake control is the one genuinely missing agent hook: attach a small listener
next to the existing session control registration, restrict it to the linked
participant and expected topic/message shape, call the public
`session.interrupt(force=False)`, and return a request-correlated accepted or
rejected response. Tie listener cleanup to that session. Do not use `force=True`
or change automatic turn detection/history behavior. The C SDK has inbound RPC
registration only, not a working outbound `livekit_room_rpc_invoke`; reliable
data packets with the authenticated sender identity and an application response
fit the existing transport better.

The existing production delegation path is `TerminationGPTLiveModel` with
OpenAI `ResponsesDelegationOptions` in
`/Users/csanz/code/IotCloud2/voice/realtime_agent/app/models/llm_models.py` and
`app/services/session/gpt_live_termination.py`; its lifecycle also touches
`app/services/session/session_factory.py` and `app/agent.py`. The test did not
exercise a provider or active delegation. Before release, verify interruption,
acknowledgement, continuation, and cleanup against that exact configured path;
the local fake realtime adapter is not evidence for delegation behavior.

### Firmware and vendored C SDK

These are proposed compatibility edits only; none was implemented in this
milestone. Keep LiveKit C pinned at 0.3.10 and retain the publisher-only data
channel correction documented in
`firmware/components/livekit/LOCAL_PATCHES.md`.

1. **Advertise the feature.** The protocol already defines
   `TF_PRECONNECT_BUFFER = 6` in
   `firmware/components/livekit/protocol/protobufs/livekit_models.proto`, but
   `send_add_audio_track()` in `firmware/components/livekit/core/engine.c`
   currently advertises only `TF_STEREO` and sends zero features for mono.
   Advertise pre-connect support for the microphone and preserve stereo when
   present. Increase the `AddTrackRequest.audio_features` nanopb capacity from
   one to at least two, regenerate bindings, and verify both mono and stereo
   serialization.
2. **Expose stream attributes.** Add bounded string attributes to the public
   data-stream header/options and reader callback for `trackId`, `sampleRate`,
   and `channels`. The fields exist in the proto, but
   `livekit_models.options` ignores `DataStream.Header.attributes` and the
   current writer/reader and public options do not fill or return them. Bound
   count and string sizes in the device, and keep the first buffer capped to the
   firmware's existing wake-window memory budget. The native Python handler
   keys only by `trackId`, does not compare the stream sender with the owner of
   that microphone track, and does not cap bytes; rely on authenticated room
   membership plus sender-side bounds, not on those native checks.
3. **Return the local microphone SID.** The firmware needs the server SID for
   the `trackId` attribute. `TrackPublishedResponse.cid` and `.track`, plus
   `SignalResponse.track_published`, are currently ignored by
   `livekit_rtc.options`; the generated response type is effectively empty.
   Decode the signaling response, map local CID to the returned track SID, and
   add a public track-published callback (or equivalent API) with documented
   pointer lifetime. A getter alone cannot recover the ignored response.
4. **Expose agent readiness and state.** The C SDK already decodes
   `ParticipantInfo.tracks` internally, but the public participant callback
   drops tracks and `ParticipantInfo.attributes`, `TrackInfo.name`, and
   `TrackInfo.source` are ignored. Extend the callback data to expose bounded
   participant attributes and enough track information to recognize the
   standard `roomio_audio` publication. The device can then wait for that
   publication before its first native pre-roll and read `lk.agent.state` for
   indicators. Document ABI changes and borrowed-memory lifetime; test initial
   participant snapshots and later attribute/track updates.
5. **Use existing reliable data.** Send wake control and renderer acknowledgement
   through the existing reliable data-publish API, including message IDs and
   handling the returned sender identity. Do not add outbound RPC just for this
   feature unless a later SDK/API review proves data messages inadequate.

In a mid-session barge, retain the existing microphone SID and send buffered
speech through the normal microphone capture/publish path. The native pre-roll
handler waits for one handoff per input track; it is not a reusable buffer
channel for every wake event.

## Not established by this experiment

- Actual ESP32/C SDK wire compatibility, target ABI/build effects, firmware
  memory use, radio loss, audio clock behavior, I2S queue flushing, or speaker
  acoustics.
- Real AgentActivity/STT/turn detection/provider behavior, actual production
  dispatch-token metadata permissions, provider interruption behavior, or the
  configured `TerminationGPTLiveModel` delegation path.
- A successful native pre-roll path for text-first sessions. Source inspection
  found that the existing lazy-audio input is created without a native
  pre-connect handler; a later output-track event is not readiness proof in
  that mode. The device should request AUDIO at session start, or this path
  needs a separate opt-in change and test.
- Database/IoT/tool setup duration before production `session.start()`, and
  worst-case provider startup relative to a device timeout.
- A hard byte cap or sender ownership check in the native pre-connect handler;
  the probe only verified an in-cap 200 ms payload and source-audited the
  current handler.
- Hardware confirmation that stale output is gated through the measured RTP
  tail, that a new response can reopen the gate without clipping, and that LEDs
  follow state through reconnects and stale events.

These remain acceptance items in Milestone 3 of the integration plan. This report
selects the native RoomIO approach and records the smallest supported change set;
it does not start the implementation milestone.

# Revised integration plan: preserve the existing LiveKit agent

Prepared 2026-10-20 following the user's scope correction. This supersedes the
original Phase 2 implementation approach in `REUSE_PLAN.md`.

Current status: the earlier broad implementation was rolled back, the isolated
SDK proof completed, and the narrow integration is implemented and software
tested. Physical-board and real-provider/delegation acceptance remains open.
See [implementation validation](IMPLEMENTATION_VALIDATION.md) and the active
[protocol/setup contract](PROTOCOL.md). The milestones below retain the design
and acceptance criteria used for this work.

## Objective and boundary

The ESP32 is a LiveKit client of the existing IoTCloud voice service. Preserve
the proven agent's normal audio path, model setup, tools, turn detection,
interruption policy, delegation, recording, metrics and conversation lifecycle.

Pre-roll, wake-word interruption and speaking indicators are mandatory acceptance
criteria. Basic connectivity alone does not complete the integration.

The preferred session flow stays:

```text
ESP32 --authenticated call request--> existing IoTCloud session service
      <-- LiveKit URL + participant token; existing agent dispatched --
ESP32 <---------------- audio and control over LiveKit ----------------> agent
```

Reuse `api/app/services/voice.py` and its existing user/location authorization,
model/template selection, room creation and agent dispatch. Adapt the firmware
request/response to the existing API where practical. If device authentication
requires a different HTTP entry point, it should be a small adapter calling the
same service. The implementation uses an owner-issued, finite-lived voice bearer
for an existing inventory device, revalidates current ownership per call, and
requests AUDIO at startup. Legacy MQTT credentials are not accepted by the HTTP
voice endpoint. No database migration or new device-management subsystem was added.

## What inspection established

These facts come from the installed LiveKit Agents 1.8.8 source and the firmware's
vendored LiveKit C 0.3.10 source, rather than assuming current website examples
match the installed versions:

- Python RoomIO already supports pre-connect audio and enables it by default.
  Its stream is `lk.agent.pre-connect-audio-buffer`. It matches buffered audio
  to a microphone track SID, checks the pre-connect track feature, and resamples
  labelled PCM through the existing input path.
- RoomIO already publishes `lk.agent.state` as a participant attribute. Firmware
  can consume it for listening/thinking/speaking indicators and microphone gating.
- The ESP32 component's protobuf schema contains the pre-connect audio track
  feature, but its track publication does not currently advertise it. Its public
  data-stream options do not expose the attributes needed by native pre-connect
  audio, and its generated bindings currently ignore stream/participant
  attributes. Its participant callback also omits those attributes.
- The original firmware's SBPR framing and `sebastian.*` topics are specific to
  that project. Matching the standard LiveKit protocol is a valid firmware-side
  change; we do not need to keep those names just to preserve the features.
- The normal agent exposes `session.interrupt()`. A remote wake-word event needs
  a small explicit handler to invoke it; sending arbitrary data does not invoke
  that method automatically. Stopping the speaker locally is only half the job:
  generation/playout must also be canceled through the agent's existing API.

Official references:
[pre-connect audio](https://docs.livekit.io/agents/multimodality/audio/),
[agent state](https://docs.livekit.io/frontends/build/agent-state/),
[session interruption](https://docs.livekit.io/agents/logic/turns/).
Installed-source behavior takes precedence where newer documentation differs.

## Feature ownership

| Feature | Firmware / ESP32 SDK | Necessary agent work |
| --- | --- | --- |
| Session startup | Call existing service, parse its connection details, join LiveKit and publish the microphone. | Reuse existing room creation and dispatch. Add only the authentication/response adaptation actually needed. |
| Pre-roll | Keep local wake buffer; send the native pre-connect format, track feature and track SID/attributes with correct timing. | Prefer existing RoomIO support. Any readiness/timeout adjustment must be scoped to device sessions and proven necessary. |
| Wake-word interruption | Detect locally during playback, promptly flush the renderer, send a reliable control request and handle acknowledgement/in-flight audio. | A small helper validates the linked participant and invokes the existing interruption API. Preserve cancellation/history/delegation behavior. |
| Speaking indicators and half-duplex gating | Read the standard agent state, update LEDs and retain XVF/AEC/microphone behavior. | Prefer the SDK's existing state publication. Use a small state relay only if extending the ESP32 callback is demonstrably less suitable. |
| Session end and recovery | Handle normal room/agent disconnect and retain local watchdogs/return to wake listening. | Keep the existing lifecycle. Add an explicit close notification only if a measured C-client issue requires it. |

Full/half duplex remains a hardware decision. Existing agent turn detection stays
in charge of normal speech interruptions. This plan does not introduce a second
server VAD/talk-over controller or replace RoomIO with a custom microphone queue.

## Milestone 0 — Restore a clear implementation baseline

1. Inventory the interrupted Phase 2 delta against the saved pre-Phase 2 source
   snapshot at `/private/tmp/sebastian-phase2-baseline-_4pztelq`.
2. Save that delta for reference, then selectively remove the old approach's
   unfinished registry/schema/audio-path/lifecycle changes. Preserve all user
   changes that predated it and any subsequent user edits. Do not overwrite files
   wholesale from the snapshot or reset the repository.
3. Keep the reviewed Phase 1 firmware extraction. Record the exact restored
   agent baseline and run the relevant existing checks before integration work.

**Exit:** a small, identifiable integration diff can be reviewed separately from
the user's existing IoTCloud/Aurelia work.

## Milestone 1 — Prove compatibility before selecting an implementation

Use an isolated LiveKit server and a synthetic device against the installed SDK.
No production schema changes or agent audio-path replacement are needed for this
experiment.

1. Start a normal AgentSession using standard RoomIO and deterministic test audio.
   Verify native pre-connect audio for the actual pipeline and realtime entry
   paths. Check track SID, required attributes, microphone feature, timeout,
   pre-roll-before-live ordering, resampling and registration/readiness timing.
2. Observe the existing state attribute and identify which state is a safe
   firmware readiness signal. A participant joining is not proof its audio
   handler is ready. Prefer adapting the firmware handshake to existing state;
   alter agent startup ordering only if this cannot be made reliable.
3. Exercise a tiny authenticated interruption handler using the normal session
   API. Test interruption while audio is queued and while the existing backend
   delegation path is active. Verify prompt audio stop and coherent continuation.
4. List the exact ESP32 SDK extensions required: stream attributes, pre-connect
   feature, published track SID and participant-state attributes. Preserve its
   existing data-channel patch and pin dependency versions.

**Decision:** prefer native pre-connect audio plus firmware compatibility work.
If measured timing or C-SDK limitations make it impractical, document that evidence
and propose the smallest device-only pre-roll input adapter before replacing any
normal agent audio path. A separate sidecar/proxy is not the default: it adds
another audio hop and service.

**Exit:** a tested feature map, exact proposed files/hooks, and an evidence-based
choice. The three mandatory features remain in scope whichever route is chosen.

## Milestone 2 — Implement the narrow integration

1. Wire session startup through the existing backend. Settle device authentication
   using the existing platform identity/location rules and return the connection
   details already used by other clients. Keep provider keys on the server.
2. Implement the necessary firmware/C-SDK compatibility changes, preserving the
   current I2S/XVF/AEC, USB arbitration, profiles, PSRAM use and watchdogs. Preserve
   bounded pre-roll delivery and account for the existing SCTP cache when testing
   slow joins; do not remove memory bounds to make a test pass.
3. Add one small, removable device-control helper only for capabilities missing
   from the installed SDK: principally wake-word interruption, and an explicit
   flush acknowledgement if needed. Register/clean up its handlers through small
   attachment points in the relevant agent entry points. Bind requests to the
   participant authorized by the existing session, rather than a hardcoded name.
4. Keep standard RoomIO/STT/realtime audio consumption and existing session logic.
   Device-specific options should be opt-in; an ordinary browser/mobile/SIP
   session must continue taking its previous path.
5. Revise `PROTOCOL.md` to the tested contract and update fixtures. Its original
   SBPR/`sebastian.*` contract is a Phase 1 baseline, not a permanent constraint on
   the new design.

**Exit:** reviewable backend/agent changes limited to their necessary boundary,
with hardware-specific behavior concentrated in this firmware repository.

## Milestone 3 — Accept the mandatory features and check regressions

- **Pre-roll:** speech immediately after the wake word reaches the existing
  agent in order, without duplication or clipped handoff, within the defined
  capture window. Exercise slow joins, missing/late data, timeout and repeated
  sessions; measure the supported latency/window rather than assuming it.
- **Wake interruption:** during a long spoken reply, the local wake word stops
  audible buffered playback promptly, cancels the current agent response through
  its normal API, and permits the next request. Verify queued and in-flight audio
  does not keep speaking afterward. Repeat during delegation and applicable
  noninterruptible-policy cases without silently changing the agent's rules.
- **Speaking indicators:** LEDs and half-duplex gating follow the agent's real
  state; reconnect and stale events cannot leave the microphone gated or the
  indicator stuck. Validate acoustic playback timing as well as model state.
- **Existing behavior:** targeted tests cover the normal pipeline and realtime
  paths, plus affected browser/mobile/SIP/security behavior. Prompts, models,
  tools, confirmation rules, recording and metrics retain their existing meaning.
- **Hardware acceptance:** repeat wake/conversation/close, mute, USB takeover and
  release, network failure and restart on the identified ReSpeaker/XIAO. Record
  firmware/agent versions, state/interrupt latency, clipping/echo and recovery.

**Completion:** all three mandatory features pass with the existing agent, and
the minimal integration has no outstanding regressions. Simulated tests and
physical-board evidence are reported separately.

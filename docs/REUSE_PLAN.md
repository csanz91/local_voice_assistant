# ESP32 firmware reuse and IoTCloud integration plan

Prepared 2026-10-20. This is a planning review; no firmware or backend behavior
has been changed or tested on hardware during this review.

Reviewed working trees:

- Sebastian: `/Users/csanz/code/Sebastian`, `main`, HEAD `5104b32`.
- IoTCloud: `/Users/csanz/code/IotCloud2`, HEAD `916c99c`, including the current
  local changes under `voice/`. Those changes must be preserved during execution.

The goal is to keep the useful Seeed ReSpeaker XVF3800 + XIAO ESP32-S3 firmware
and use IoTCloud's backend, LiveKit deployment and Aurelia agents. Keep this
repository as the firmware project and keep backend/agent changes in IoTCloud.

## Findings that determine the split

1. **The audio implementation is the main reusable asset.** It includes XVF
   firmware loading, separate I2S RX/TX ports, codec setup, AEC configuration and
   fallback, local wake word, pre-roll, USB microphone, microphone arbitration,
   physical controls, LEDs, persistent profiles, boot recovery and diagnostics.
   Retain the current Zig/ESP-IDF implementation rather than rewriting it.
2. **Deleting the backend directories alone would break the firmware.**
   `token.zig`, `session_http.c`, `control.zig`, `adopt.c`, `announce.c`,
   `provisioning.c` and `app.zig` share session, identity, enrollment, polling and
   meeting behavior. Device-secret creation currently starts inside
   `control.start()` and must survive removal of that control plane.
3. **IoTCloud already has two session-creation paths.**
   `voice/back/app/services/voice.py` serves the voice dashboard. The main API's
   `api/app/services/voice.py` already checks location access and dispatches the
   home agent with location/user metadata and `agent_speaks_first=False`.
   Use that main API service as the integration point. `voice-back` is currently
   in the optional `voice-tools` Compose profile, so a speaker should not depend
   on enabling the dashboard services.
4. **Ordinary LiveKit audio is insufficient for full feature reuse.** The
   firmware also sends `sebastian.preroll` and `sebastian.barge_in`, and expects
   `sebastian.agent_state`. Neither existing IoTCloud agent implements these
   topics. Its existing conversation termination deletes the room; the device
   also needs an explicit close signal and its own recovery timers.
5. **The existing provisioning URL loses its path.** `token.zig` extracts the
   origin and `session_http.c` appends `/v1/sessions`. A URL behind IoTCloud's
   `/api/v2` proxy cannot work by provisioning a different URL alone. The HTTP
   shim also lacks a configured certificate trust bundle for HTTPS.
6. **Retain the local LiveKit component and document its actual patch.**
   `firmware/main/idf_component.yml` describes a `no_auto_reconnect=true` fix,
   but `firmware/components/livekit/core/peer.c` actually limits the data channel
   to the publisher peer and leaves `no_auto_reconnect=false`. Preserve the
   implementation and correct the stale description before considering upgrades.
7. **Build success will not prove acoustic reliability.** The source's status
   notes record earlier I2C/SCTP failures and an unresolved maximum-volume XVF
   issue. The partition table has a factory app and coredump partition, with no
   OTA app slots. Remote firmware OTA is additional work, not an existing feature
   we can preserve by retaining the source.

## Phase 1 — Extract and stabilize the firmware project

**Outcome:** a firmware-focused repository that builds and can be provisioned and
validated without the creator's services or any IoTCloud code changes.

### Preserve, remove and adapt

| Area | Phase 1 disposition |
| --- | --- |
| `firmware/main/board.zig`, `xvf_*`, `mic_src.zig`, `wakeword.zig`, `pre_roll.zig`, `main/core/` | Preserve hardware/audio behavior and relevant tests. Keep LEFT/comms capture, separate I2S ports and bounded pre-roll. |
| `firmware/components/mww`, embedded wake model and XVF binary, `firmware/components/livekit` | Preserve required assets, local SDK changes and their license notices. |
| `profile.zig`, `profiles.c`, `selector.zig`, `usb_mic.zig`, `xvf_ui.zig` | Preserve USB mic, USB/agent arbitration, profile selection, mute and useful local gestures/LEDs. Remove meeting-only actions. |
| `provisioning.c`, provisioning/flash scripts, `web-installer/` | Keep local WiFi, endpoint, device credential, audio and profile provisioning. Remove fleet-dashboard embedding and organization adoption dependencies. Preserve existing useful NVS data. |
| `token.zig`, `session_http.c`, session portions of `app.zig` | Adapt to one provisioned full session endpoint and the contract below. Keep session reducer, watchdogs and clean teardown. Move identity/secret initialization out of fleet startup. |
| `control.zig`, `adopt.c`, `announce.c`, fleet-only declarations | Remove creator-specific enrollment, UDP adoption, desired-profile/config polling and meeting commands. Extract the small identity function still needed by session authentication. |
| `agent/` | Extract only the protocol/parser and audio ordering behavior needed as documented fixtures/reference, then remove the creator's runtime, token server and control plane. Phase 2 ports selected behavior into Aurelia. |
| `server/`, `dashboard/`, `helm/`, `homeassistant/` | Remove the creator's application stack and deployment/reference configuration from the active tree. Preserve required firmware assets regardless of their origin. |
| `.devcontainer/`, `Makefile`, `.vscode/`, tooling | Reduce to firmware build/test/flash/provisioning. Remove Go/Atlas/NATS/backend services and hooks that would refer to deleted directories. Keep diagnostics optional. |
| `.github/workflows/`, release configuration | Keep firmware validation; remove upstream mirror automation, backend/dashboard/container/Helm publishing and creator-specific runners/registries. Retarget retained installer/release workflows to this fork without publishing during cleanup. |
| README and documentation | Replace active setup/architecture instructions with the firmware scope. Keep useful hardware/audio/build troubleshooting; retire obsolete product roadmaps and deployment instructions. Preserve MIT attribution and dependency notices. |

### Implementation order

1. Record the baseline, required embedded assets, component patch and toolchain.
   Use ESP-IDF 5.4.4, the pinned Xtensa Zig fork and existing LiveKit 0.3.10
   component for the initial extraction. Align the devcontainer with CI's IDF
   pin; do not combine extraction with SDK upgrades.
2. Capture the cross-repository protocol fixtures before removing `agent/`.
   Keep a short protocol document and focused fixtures/tests, not a second
   production voice agent or a replacement backend service.
3. Decouple session access from fleet management. Preserve per-device secrets,
   local provisioning and configuration; remove enrollment/polling and meeting
   session branches. Retain `livekit.tokenServerUrl`/`token_url` as the stored
   endpoint setting, but make it a full URL and relabel it in provisioning UI.
   Existing units will need their URL updated, not an NVS erase.
4. Add proper server certificate validation for HTTPS session requests and
   verify the returned LiveKit WSS endpoint with the pinned client. Allow plain
   HTTP only as an explicit local development configuration. Keep secrets out
   of logs, binaries and committed configuration.
5. Remove the unused product services, then repair build references, scripts,
   devcontainer hooks, installer fields, documentation and CI triggers.
6. Validate against local protocol fixtures and a disposable LiveKit test
   participant/session harness. All harness code is development tooling and
   disappears from the production runtime.

### Phase 1 completion criteria

- `make fw-test`, Zig formatting and a full ESP-IDF build/link pass using the
  pinned environment. The installer still builds and provisioning works.
- No production firmware calls remain to `/v1/devices/*`, enrollment/adoption,
  desired config/profile or meeting APIs. No retained workflow starts or
  publishes a removed component, or synchronizes this fork from upstream.
- HTTP fixtures verify full path preservation, authentication headers, valid
  response parsing, malformed/oversized responses and unavailable backend
  behavior. HTTPS trust failures are handled without an insecure fallback.
- On the physical board, verify boot/XVF audio, wake word, mute/LEDs, profile
  selection and safe boot, USB capture and USB takeover/release. Verify LiveKit
  audio, pre-roll and session teardown against the test harness when available.
- Record hardware results separately from automated checks. If the board is
  unavailable, report hardware acceptance as outstanding.

**Handoff:** the cleaned firmware, protocol document, shared fixture examples,
build/flash/provision instructions and a recorded validation result. Phase 1
requires no production IoTCloud endpoint.

## Contract shared by both phases

Freeze this contract during Phase 1 so Phase 2 can be implemented with a simulated
device independently of firmware development.

### Session creation

- Proposed endpoint: `POST /device-voice-sessions` in IoTCloud's public API,
  externally under its deployed `/api/v2` prefix. Provision the complete URL;
  verify actual proxy routing during deployment.
- Headers: existing `X-Device-Id` (normalized hardware MAC) and
  `X-Device-Secret` (per-device credential). No user token, M2M credential,
  LiveKit API secret or AI-provider key is stored on the speaker.
- A normal wake requests a conversational audio session with no caller-supplied
  user, location, organization, model or template authority. The backend resolves
  these from the authenticated device binding.
- Return HTTP 201 with `{"serverUrl":"wss://…","token":"…"}`. This keeps
  the existing firmware response shape; adapt the existing service's
  `participant_token` result at the new endpoint. Keep the existing user-facing
  API response unchanged.
- Issue a short-lived token scoped to a fresh room, the device's participant
  identity, microphone/data publishing and agent audio/data subscription.
  Dispatch the agent explicitly; roll back rooms created before a failed
  dispatch and bound duplicate/retried opens per device.
- Define fixtures for unknown/bad credentials (401), disabled or unauthorized
  bindings (403), duplicate opens (409), throttling (429) and unavailable session
  creation (503). Failed attempts must return the firmware to local listening.

### Audio and lifecycle

| Direction | Contract |
| --- | --- |
| Device → agent, media | Existing Opus mono 48 kHz microphone track. |
| Agent → device, media | Normal LiveKit agent audio, played through existing renderer. |
| Device → agent, `sebastian.preroll` byte stream | Preserve SBPR v1: 16-byte header, 16 kHz mono signed little-endian PCM, sample count, wake ID and effective-duplex flags. Maximum 2.5 seconds / 80,000 PCM bytes plus header. |
| Device → agent, `sebastian.barge_in` data | Payload `barge`; interrupt generation/playout and immediately signal device buffer flush. |
| Agent → device, `sebastian.agent_state` data | Publish listening/thinking/speaking state plus explicit `interrupted` and `close`; firmware uses speaking for gating and interrupted for renderer flush. |

Register device handlers before the agent becomes visible as ready to the
firmware. Preserve pre-roll-before-live ordering, bounded buffering, validation
of sender identity and graceful fallback if pre-roll never arrives. Resample to
the selected agent's required input rate rather than assuming all model packs
consume the creator's 24 kHz frames. Avoid adding a second concurrent microphone
consumer through standard RoomIO.

Use the device's declared *effective* full/half-duplex mode. Unknown mode must
not enable full-duplex talk-over logic. Retain firmware AEC fallback and local
wake-word interruption. Deliver `close` before room deletion through the existing
session lifecycle; keep firmware timeouts/watchdogs for lost signals or failures.
Keeping the `sebastian.*` wire names initially avoids a simultaneous protocol
rename while replacing both server and agent.

## Phase 2 — Integrate IoTCloud and the existing Aurelia agents

**Superseded approach:** following the user's 2026-10-20 scope correction, use
[the revised integration plan](INTEGRATION_PLAN.md). It keeps pre-roll,
wake-word interruption and speaking indicators mandatory while preferring native
LiveKit capabilities and firmware adaptation over changes to the proven agent.
The original Phase 2 proposal below remains historical context.

**Outcome:** the physical speaker uses the user's existing voice stack and home
tools, with no running component from the creator's backend or Python agent.

### Backend work in `/Users/csanz/code/IotCloud2`

1. Add a small voice-device credential/binding record linked to the existing
   `iotcloud.devices` inventory. Store the credential hash, enabled state and
   initiating IoTCloud user, plus only voice configuration that is not already
   derivable from the device/location or existing server settings. Do not create
   a parallel fleet inventory. Treat a provisioning key/MAC as an identifier,
   not a credential; existing MQTT JWTs are not currently HTTP voice credentials.
2. Provide authenticated administrative registration, revocation and credential
   replacement using the existing API conventions. Initial physical pairing can
   use USB provisioning and a small operator script; a new fleet dashboard and
   UDP adoption protocol are unnecessary for the first integration.
3. Add the contracted device endpoint in `api/app/api/v2/`, authenticate the
   binding, and reuse `api/app/services/voice.py` for location authorization,
   room creation and dispatch. Derive `context_id` from the device location and
   `contact_id` from the bound IoTCloud user. Recheck access so removed sharing
   permissions cannot leave a speaker authorized indefinitely.
4. Add an optional explicit participant identity/device-session marker to the
   existing session metadata/building path. Dispatch the existing model-selected
   worker with its configured agent suffix, template, organization and language;
   retain `agent_speaks_first=False` for wake-triggered speech. Do not change
   browser/mobile or SIP behavior.
5. Use existing Redis only where needed for bounded duplicate-open protection;
   do not add a broker or orchestration service. Preserve transcript, metrics,
   memory, recording policy and existing home-tool behavior.

### Agent work in `voice/realtime_agent/`

1. Add a small device-audio integration module under the existing session
   services. Port the useful SBPR parser and ordered input logic from
   `agent/preroll.py` and `agent/audio_input.py`, with focused tests; do not copy
   the creator's model/provider setup, Home Assistant tools, recording defaults,
   meeting service or control plane.
2. Attach it only for authenticated device dispatch metadata in both
   `app/agent_pipeline.py` and `app/agent.py`. First complete a real conversation
   with one configured model pack, then verify the second entry point within
   this same phase. Keep ordinary web, text, SIP and security sessions on their
   existing audio path.
3. Bridge states, interruptions and close into the existing session lifecycle.
   Account for assistant audio already queued on the device and for work still
   running during backend delegation. Use existing session limits and termination
   policy; do not import a competing conversation-end controller.
4. Preserve `app/iotcloud/` context/tools, confirmation keys, Redis state reads
   and Internal API actions. A device identity must not replace the authorized
   user identity used by those tools.
5. Configure routable HTTPS/WSS endpoints and the existing LiveKit media network
   path. Container-only hostnames are unsuitable for the ESP32. Verify the
   deployed LiveKit setup rather than assuming Cloud or self-hosting.

### Phase 2 completion criteria

- Backend tests cover pairing/authentication, disabled/revoked credentials,
  location access removal, metadata/agent dispatch, duplicate opens and cleanup
  after dispatch failure. A simulated device can exercise this without hardware.
- Agent tests cover SBPR bounds and malformed input, correct sender/track,
  pre-roll/live ordering and resampling, missing pre-roll, effective duplex,
  immediate interruption/flush and explicit close. Verify both agent entry
  points and affected browser/SIP/security lifecycle regressions.
- Run the relevant API and voice checks with each project's uv/Make targets;
  update shared metadata tests and regenerate frontend API types when schemas
  affect that API. Place migrations with the owning schema: IoTCloud inventory
  changes in `api/db/migrations/` and the root bootstrap; any Aurelia schema
  changes must also update both voice schema snapshots.
- Hardware acceptance: wake → authenticated session → complete first utterance
  → home action → spoken response → close → wake listening. Repeat with speech
  immediately after the wake word, full/half duplex, interruption, mute and USB
  takeover/release. Measure clipping, latency, echo and recovery at realistic
  speaker volume.
- Exercise backend/agent restart, WiFi loss, failed HTTP/TLS, missing agent and
  repeated conversations; confirm bounded resource use and return to listening.
- Startup requires only the existing IoTCloud/LiveKit services and firmware.
  Document versions, configuration, provisioning and any outstanding acoustic
  limits; do not claim hardware acceptance from automated tests alone.

## Scope defaults and independence

Keep USB microphone and local profiles because they are reusable device
capabilities. Exclude the creator's meeting/transcription product, remote fleet
management, Home Assistant integration, custom wake-word training and production
OTA from these two phases. Their removal does not remove basic microphone/audio
capture or IoTCloud's existing conversation recording policy.

Phase 1 can be developed and accepted with fixtures/test peers; Phase 2 can be
developed and backend-tested with a device simulator. Their only shared dependency
is the frozen contract. Final end-to-end hardware acceptance belongs to Phase 2.
No phase should restore the creator's server merely to make integration pass.

Initial settings remain backend-controlled: use the existing home template and
an available model pack, Spanish `es-ES`, and the stock Okay Nabu model until
explicitly changed. These defaults avoid expanding the extraction into an
assistant-model or wake-word redesign.

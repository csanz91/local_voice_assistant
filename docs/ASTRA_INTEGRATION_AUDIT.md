# Independent Astra integration audit

Audit performed 2026-10-20–21. Reviewer: Astra, HIGH reasoning. This is an independent readiness assessment of the implementation described in `IMPLEMENTATION_VALIDATION.md`, not a replacement for that implementation record. Source changes were assessed against `/private/tmp/sebastian-native-integration-3xi5_255/{sebastian,iotcloud}/implementation.patch`, with surrounding firmware, native SDK, current API, agent and installed framework code inspected where the integration depends on them.

## Decision

**Not ready to declare the three mandatory features accepted, or to promise that the arriving board will work without further software work.** The architecture is compatible with the existing backend and ordinary native RoomIO. There is no evidence supporting a broad rewrite of the proven agent. However, one concrete failure-handling bug and two deterministic functional counterexamples remain in the firmware contract. GPT-Live interruption additionally has a provider-interface limitation that the generic speech tests do not cover.

The useful next step is a small firmware failure fix plus focused, provider-free acceptance work on first-utterance retention and interruption continuation. Physical bring-up remains necessary afterward. The tested default device route is the existing **pipeline** model pack, not GPT-Live. Keep that distinction explicit when deciding what is required for the first board.

This audit made no implementation edits, commits, deployments, restarts of existing services, provider requests, home actions or flashes. This report is the only repository write. Temporary probes and an owned loopback server were used; the server and ephemeral signing-key configuration were removed.

## Ordered findings

### 1. Fix before acceptance: failed wake requests can resume the response they were meant to stop

**Confirmed implementation bug; high priority.**

The production helper distinguishes `policy`, `not_ready`, `timeout` and `invalid` (`IotCloud2/voice/realtime_agent/app/services/session/device_wake.py:79–107`). The production C parser maps every one of those rejections to the same `-1` (`firmware/main/session_http.c:108`). The callback reduces this again to `accepted=false` (`firmware/main/app.zig:342`). `Drain.advance()` then returns `reopen` after 250 ms for any rejection, even if incoming audio continues and the agent is still speaking (`firmware/main/core/device_voice.zig:55–60`). Reopen removes the receive gate (`firmware/main/app.zig:740–747`).

A valid failure sequence is: local wake gates and flushes playback; the agent's interrupt completion exceeds its two-second bound; the helper returns `rejected/timeout`; the board interprets this as permission to resume old audio. A `not_ready` or `invalid` result has the same outcome. This is contrary to the documented distinction between restoring a protected greeting and closing on failure.

**Audit reproduction:** compile the actual production parser against the existing host HTTP stubs. All four reasons produce `-1`. Import the actual production `Drain` into a Zig test, then call `start(); acknowledge(false); advance(250, true, false)`: the result is `reopen`. These are production-code executions, not a rewritten model of the condition.

**Smallest fix:** preserve at least accepted / policy rejection / failure through the parser, event/mailbox and drain. Only policy rejection may restore protected output. A matched non-policy failure should keep output gated and close. Preserve request correlation and missing-ACK timeout. Add a cross-boundary regression for each reason; the current parser test covers only policy rejection and the current drain test labels all rejections as policy.

### 2. Resolve before claiming first-utterance pre-roll: the retained window can contain none of the command

**Confirmed deterministic behavior and acceptance gap; already partially documented, not a newly discovered unbounded-buffer bug.**

The device captures a 12-second ring but transmits only the **newest** 2.5 seconds (`firmware/main/core/pre_roll_core.zig:3–19`, `firmware/main/pre_roll.zig:send`). This cap has a real memory justification: the C SDK's SCTP send cache is 100 KiB and earlier oversized bursts caused corruption. That constraint must remain.

The command-retention claim does not follow from that cap. For a command spoken from wake+0.2 s to wake+1.2 s and handoff at wake+4 s, the exported window is wake+1.5 s through wake+4 s. **Zero command samples are sent**, despite every command sample still being present in the 12-second ring. Until the handoff the normal microphone sends silence, so live input cannot recover the omitted command. The production `windowSamples()` calculation reproduced this exact result in an imported Zig test.

A four-second handoff is a test scenario, not a measured production startup percentile. HTTP token issuance, dispatch/context preparation, connection and output readiness are all before the handoff; no measured bound here excludes that scenario. The comment that newest samples “still hold the command spoken while connecting” is consequently too strong. `PROTOCOL.md` acknowledges a slow-join window loss, but that acknowledgement does not establish the requested user experience of speaking immediately after wake.

**Smallest direction to evaluate:** retain a wake-anchored command interval instead of allowing subsequent silence to evict it, while preserving the per-send/cache bound. A fixed 2.5-second anchored interval can prove a deliberately bounded short-command case but does not solve longer utterances or a gap before live handoff. If the requirement includes those, evaluate paced native-stream delivery from the existing ring with explicit bounded backpressure, rather than a larger uncontrolled burst or a custom server audio queue. This needs a measured selection/handoff contract, not an arbitrary cap increase.

**Required software proof:** use labelled PCM segments for wake, a complete short command, a longer command, trailing silence and live continuation. Vary handoff delays across 0.5/2/4/8 seconds and assert actual retained command samples, ordering and absence of duplicate or missing speech at the native RoomIO input boundary. Existing window-arithmetic tests and a synthetic tone accepted by RoomIO do not make this assertion.

### 3. Resolve or explicitly constrain continuation: a successful interruption can discard the new reply and close a healthy call

**Confirmed policy counterexample; the implementation report acknowledges this conservative limitation, but mandatory continuation is not accepted.**

For accepted wake requests, the drain requires all of: 250 ms elapsed, 150 ms without incoming audio and the **current** native agent state being `listening` (`firmware/main/core/device_voice.zig:50–60`). Incoming frames are discarded before the renderer while this is pending; the timeout closes the call at five seconds (`firmware/main/app.zig:297–301,738–750`). There is no media generation identifier that distinguishes an old response tail from the new response.

**Audit reproduction:** accepted result, quiet/listening for the first 100 ms, then a fresh response by 200 ms and ongoing new audio through the deadline. The imported production drain never reopens and returns `close` at 5,000 ms, although this sequence contains no stale old media. A shorter new reply can instead be inaudible until it ends. These are valid input sequences for the policy; this test does not claim a measured frequency in the configured model pack.

Waiting for every native state transition is also unsafe as an assumption: installed Agents 1.8.8 `voice/room_io/room_io.py:502–513` cancels an outstanding state-publication task when the next state arrives. A brief local `listening` state need not be an observed remote transition. The firmware mailbox intentionally coalesces latest state too.

**Smallest direction:** first reproduce the sequence with real local RoomIO and production wake helper, including a queued protected reply and a deliberately fast new reply. Then choose a narrowly scoped device control/output coordination rule that can distinguish completion of the old response from permission to play the new one. Merely shortening timers, latching any historical listening state, or treating an ACK as an RTP barrier does not prove both no stale playback and no clipped new reply. A device-only server output hold/resume handshake is a candidate to investigate, not an already-proven drop-in fix; RoomIO output capabilities and transcript/playout accounting must be preserved. No global turn-detection or model change is justified by the current evidence.

### 4. Conditional blocker for GPT-Live acceptance: the ordinary interrupt API does not cancel its provider/delegation transport

**Verified installed-SDK limitation; not evidence that the current default pipeline cannot work.**

The endpoint supplies AUDIO mode and otherwise uses `VoiceConnectionTokenAttributes` defaults. Current `shared/shared/models/voice.py:1585` selects `GEMMA_4_31B_IT_LK_ELEVENLABS`: Deepgram Flux STT, Gemma 4 through LiveKit inference and ElevenLabs TTS. Its architecture dispatches the pipeline worker. The default production Compose service enables that worker; the separate realtime worker is behind the `realtime-agent` profile.

For the supported GPT-Live packs, Agents 1.8.8 adapts the duplex model through `llm/duplex_adapter.py`. Its `interrupt()` at line 644 is literally a no-op, with the comment that barge-in belongs to the model and cannot be cancelled; `truncate()` is also a no-op. `AgentActivity.interrupt()` at `voice/agent_activity.py:1909` interrupts framework speech handles and calls that realtime method. Completion of framework speech is not proof of cancellation of provider output or active Responses delegation. The existing `TerminationGPTLiveSession` owns separate client-delegation tasks and backend activity; its termination path is not invoked by `DeviceWakeControl`.

The new helper correctly calls the ordinary API, but its `accepted/interrupted` acknowledgement must not be described as proof that active GPT-Live provider work or tools have stopped. Acoustic user input may trigger the provider's native barge-in; that is a separate mechanism. In half duplex, the detected wake was locally gated and only subsequent microphone samples reach the provider, making wake-alone behavior especially important to test.

**Smallest action:** retain the proven default pack. If GPT-Live is required on the board, add an isolated scripted duplex/backend-event test covering wake alone, wake plus the next utterance, a pending Responses response and an in-flight harmless fake tool. Establish which work continues and what subsequent speech is emitted. Provider-specific cancellation promises require an actually supported provider operation and then live acceptance; do not invent a cancellation event or replace the existing delegation machinery to make a generic test pass.

## What the audit positively established

- The scoped device bearer is issued only through the current owner's ordinary auth path, uses an explicit issuer/audience/scope/role and 90-day lifetime, and is revalidated against current inventory/location ownership on every session. The device never receives the server signing key. Existing MQTT tokens are not the voice credential. The shared signing key and manual replacement/revocation limits are documented rather than hidden behind a new registry.
- The adapter reuses `create_livekit_connection()`, including location access checking, the existing organization/template/context/contact chain, unique room/conversation IDs and normal agent dispatch. The server-signed `iotcloud.device.voice=1` marker and `can_update_own_metadata=False` are appropriate opt-in boundaries for the wake helper. No caller-controlled model/context override was introduced.
- The public API includes the voice router; the application declares `/api/v2` as its root path. The firmware provisions the complete endpoint. Exact deployed proxy and endpoint behavior still needs a smoke test; the unit HTTP fixture is not deployment evidence.
- AUDIO at startup is necessary for the standard native pre-connect handler. The handler is registered in RoomIO before `roomio_audio` publication. Waiting for that output publication plus the actual local microphone SID is more appropriate than waiting for `listening`. The native three-second wait begins in RoomIO's input-track forwarder, not simply at raw RTC connection or arbitrary model initialization. Delaying the stream until listening can consume that wait; this does not justify a general claim that every slow model startup breaks the implemented publication-based handshake.
- The C SDK really advertises optional `TF_PRECONNECT_BUFFER`, serializes the raw stream attributes and reports local TrackPublished information and bounded remote attributes/tracks. The public callback projection borrows data during callbacks, and Zig copies the identifiers it retains. State-overflow handling gives `lk.agent.state` priority. Ordinary private device rooms contain far fewer tracks than the public projection cap; no concrete truncation blocker was found in the inspected path.
- Fresh session generations, pinned server-classified agent identity/SID, mailbox latches and capture-owned wake detector resets materially address stale callback and dropped-notification hazards. These protections do not substitute for hardware race, stack and heap measurements.
- On reconnect/agent departure the firmware closes the session and returns toward fresh wake listening; it does not attempt to reuse an old microphone SID indefinitely. Native server leave handling exists in the C SDK. Actual room deletion, abrupt networking failure and teardown watchdog behavior remain C-client/board acceptance items, especially given historical stuck-connected behavior.
- HTTPS/WSS verification is wired through the ESP certificate bundle, redirects are refused, output sizes are bounded, and insecure transport is explicit. A three-second SNTP sleep is not proof of successful clock synchronization. The API returns its configured `LIVEKIT_URL` verbatim, so the actual value must be a board-reachable `wss://` base URL with compatible public certificate trust; the SDK appends `/rtc` and its own query. Production URL/trust/time/size are deployment acceptance facts, not reasons to replace the auth design.
- Agent/API image builds use the repository and frozen uv lock. The inspected agent lock resolves Agents 1.8.8 / RTC 1.1.20 / API 1.2.2, matching the synthetic environment. This audit did not attest that existing running containers already contain these edits or that the production LiveKit server is 1.13.6.

## New protocol-1 signaling evidence

The Python RTC simulator does not use the ESP C SDK's exact signaling mode. To close that specific gap, this audit started a separate `livekit/livekit-server:v1.13.6` container exposed only on host loopback (17880 signaling, 17881 RTC TCP, 17882 RTC UDP). A synthetic Python AgentSession used normal RoomIO with no model/provider/tools. A raw WebSocket device used `sdk=esp32`, C SDK version 0.3.10, `auto_subscribe=false` and **`protocol=1`**, authenticating with an ephemeral device-marked JWT.

Observed assertions passed:

1. Join returned **`subscriber_primary=false`**. This agrees with `firmware/components/livekit/core/url.c:33–36`, where protocol 1 deliberately avoids subscriber-primary negotiation. A hypothetical subscriber-primary deadlock must not be reported as an established current bug.
2. The raw device's Join contained its signed opt-in attribute. The existing remote participant was server-classified **AGENT**, **ACTIVE**, with `lk.agent.state=listening`.
3. An AddTrack request for `cid=a0`, AUDIO/MICROPHONE with `TF_PRECONNECT_BUFFER` returned a nonempty server TrackPublished SID and retained that feature.
4. The actual synthetic AgentSession published **`roomio_audio`**. The raw protocol-1 client received that publication and subsequent real participant-attribute `speaking` and `listening` updates.

Join was 737 bytes, TrackPublished 68 bytes, and observed agent track/state snapshots at most 237 bytes, comfortably below the C SDK's 20 KiB WebSocket buffer for this minimal room. This is an observed minimal fixture, not a bound for arbitrary participant metadata.

**Boundary:** this raw probe did not negotiate the device's ICE/DTLS/SCTP or execute the C SDK/ESP32 renderer, so it is signaling compatibility evidence only. The first probe additionally set `disable_dtx=true` on its synthetic microphone AddTrack; the assertion concerns retention of the independent preconnect feature, not equality of every negotiated codec feature. The resulting extra `TF_NO_DTX` is not a production firmware claim.

The probe exited 0. Existing `FfiHandle.__del__` assertions recurred during Python teardown and are retained in the log. They do not negate the observed signaling assertions, and the run is not labelled warning-free.

## Evidence and reproduction artifacts

Nonsecret audit artifacts are retained under `/private/tmp/sebastian-astra-audit-3jk3atk3/`:

- `protocol1_probe.py`, `protocol1-result.json`, `protocol1-probe.log`, `server.log` — raw signaling assertions and actual results. To rerun, recreate a local `livekit.json` with a new disposable key/secret, the three ports above and `rtc.node_ip=127.0.0.1`, then use the existing realtime-agent uv project with `uv run --no-sync python .../protocol1_probe.py`. The original key file was deleted after the owned server was removed.
- `wake_parser_probe.c` — includes the existing test stubs and calls production `sebastian_wake_result()` for each rejection reason.
- `firmware_policy_probe.zig` — imports production `device_voice.zig` and `pre_roll_core.zig`, demonstrating rejection reopen, lost command samples, and fresh-reply timeout.
- `firmware-policy-probe.log` — all three deterministic policy reproductions passed, with all four parser results printed. “Passed” here means the undesirable behavior was reproduced, not that the firmware met acceptance.

The C/Zig probes ran in an existing ESP-IDF 5.4.4 image with the repository mounted read-only, using the pinned Xtensa Zig host executable and temporary build/cache directories. No dependency install or upgrade was performed. An initial probe-only renamed-main warning and a probe-only integer-width error were corrected in temporary harnesses before the successful run; production sources were not changed.

Earlier full target builds, sanitizer fixtures and suites are documented in `IMPLEMENTATION_VALIDATION.md`. This audit relied on that recorded evidence where indicated and did not rerun an unrelated broad suite merely to duplicate passing totals. It added the focused falsification tests above.

## Concrete pre-hardware completion list

1. Fix finding 1 in the firmware boundary and add parser-to-drain tests for every response reason. Keep the existing backend helper and policy semantics.
2. Resolve the supported first-utterance retention contract and run the delayed-handoff labelled-PCM matrix from finding 2 through native RoomIO. Keep the SCTP/cache bound. Do not call latest-window arithmetic proof of retained speech.
3. Test the production helper with native RoomIO plus a firmware-equivalent receive gate for fast next replies, coalesced/missing listening updates, queued noninterruptible speech, duplicate requests and delayed/failed control replies. Resolve the finding-3 tradeoff before claiming coherent continuation. Current Python simulator success does not exercise the actual firmware drain.
4. Exercise the existing pipeline's session configuration with deterministic fake STT/LLM/TTS and harmless fake tools, rather than only `session.say()` tones. Include the actual 1.5-second AEC warmup from `session_factory.py:233`, ordinary termination, background/tool work and recording/lifecycle callbacks. Do not modify global defaults to simplify the test.
5. If GPT-Live is part of the intended first deployment, complete the offline duplex/delegation event test and then separately authorize/perform live-provider acceptance. Existing GPT-Live termination tests do not prove wake cancellation of active delegation.
6. Verify the concrete deployment chain without invoking home actions: owner-auth issue → device bearer request → response bounds → expected room metadata/dispatch and worker suffix → device-linked helper. Confirm API/agent revisions, actual server version, public HTTPS/WSS routes and certificate/time prerequisites. A staged fake-inference call can establish most of this before a board arrives. Deploy/restart remains outside this audit.

## Board and live-provider acceptance that software simulation cannot replace

- Identify the exact board/profile and flash only that device. Cold-boot provisioning must accept the real scoped JWT and preserve configured fields; HTTPS/WSS must work with actual DNS, clock and certificate chain. Expired/rotated/revoked credentials must return to local wake listening without logging credentials.
- Record wake-to-token, join, local mic SID, RoomIO output publication and handoff timings together with known spoken test phrases. Check complete first-command capture, native pre-roll ordering, live seam and both delayed and repeated joins.
- In both duplex modes, repeat wake during audible and queued output, wake alone and wake plus the next utterance. Measure acoustic stop latency, stale-tail replay, new-reply clipping, protection of noninterruptible speech, actual mic reopening and LEDs. Include room noise, realistic speaker volume and the genuine AEC path.
- With the actual selected provider pack, verify STT/turn behavior, harmless responses, recording/transcript continuity, shutdown and any supported delegation path. A cancelled speech handle is not a cancelled physical action; use harmless fake or read-only tools while testing interruption.
- Repeat fresh conversations, mute, USB takeover/release, Wi-Fi outage, agent departure, room deletion and recovery. Measure internal heap/largest free block, PSRAM, task-stack headroom and post-session integrity; image/partition free space does not establish runtime memory safety.

A successful board pass should name the firmware build, deployed API/agent revisions, resolved SDK versions, model pack, hardware profile and measured failure/recovery behavior. Until then the accurate status is **compatible foundation with identified software acceptance work and physical/live-provider acceptance still outstanding**.

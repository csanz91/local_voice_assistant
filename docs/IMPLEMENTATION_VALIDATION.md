# Native IoTCloud integration: implementation and validation

Recorded 2026-10-20, with a follow-up on 2026-11-22 (below) that supersedes the
pre-roll, wake-result and drain details in the original record. This implements
the narrow integration selected by
[SDK_COMPATIBILITY.md](SDK_COMPATIBILITY.md). The active wire/setup instructions
are in [PROTOCOL.md](PROTOCOL.md); Phase 1 reports describe the earlier baseline.
Code is ready for physical acceptance, not deployed or flashed.

## Implemented scope

- The pinned LiveKit C 0.3.10 component advertises optional native pre-connect
  support, encodes bounded stream attributes, exposes the published mic SID,
  and reports agent tracks/attributes. Zig bindings and target C ABI assertions
  match. Enlarged signaling responses are heap-owned rather than put on task
  stacks; callback data remains borrowed. The publisher-only data-channel and
  certificate trust patches remain intact.
- Firmware exports one wake-anchored native pre-roll stream per mic SID, after the
  standard agent output publication. (The original 80,000-byte newest-window cap
  was replaced on 2026-11-22; see below.) It consumes native agent state for LEDs
  and microphone policy. Both duplex modes detect local wake during replies,
  immediately block incoming output, flush, request normal interruption, and
  apply a bounded drain before reopening. Lost callback notifications cannot
  lose readiness/state/wake/close/acknowledgement; the capture task owns detector
  state and CNN resets.
- The existing API issues an owner-authorized, voice-scoped 90-day credential
  for an existing inventory device. A small adapter revalidates device/location
  ownership and calls the existing AUDIO session service. No tables, migrations,
  new credential registry, global client secret, model changes or provider changes
  were added. The current agent entry points each attach one small opt-in
  reliable wake handler calling `session.interrupt(force=False)`.
- USB provisioning and the standalone installer accept the scoped bearer.
  The development fixtures now use native RoomIO and import the actual production
  wake handler; the obsolete custom SBPR decoder/ordered audio queue is removed.

The IoTCloud delta (2026-11-22, uncommitted on `feature/esp32-voice-current`)
is 13 files:
- API: `api/app/api/v2/voice.py`, `api/app/models/api/voice.py`,
  `api/app/services/voice.py`, `api/tests/test_voice.py` and the new
  `api/tests/test_device_voice.py`.
- Voice backend: `voice/back/app/{api,models/api,services}/voice.py` and
  `voice/back/tests/api/test_mobile_voice_api.py`, which sign the device marker.
- Agent: the two entry points `voice/realtime_agent/app/agent.py` and
  `agent_pipeline.py`, the new helper `app/services/session/device_wake.py` and
  its test `tests/test_device_wake.py`.

The original record said "eight files"; that count omitted the voice-backend
marker files. Relative to the
pre-implementation snapshot, every other existing IoTCloud file is unchanged,
including the user's weather work. HEAD is unchanged. Firmware dependency pins
and the local relative lock path are unchanged.

## Checks and results

| Check | Result |
| --- | --- |
| ESP-IDF 5.4.4 / pinned Xtensa Zig target build and link | Passed; app `0x37a350` = 3,646,288 bytes; 13% factory partition free |
| `make check fw-fmt` | Passed; 79 Zig tests, production C SDK sanitizer fixture, 5 HTTP/control fixture tests, production HTTP/provisioning C fixtures, 4 provisioning CLI tests, Zig formatting |
| C SDK ASan/UBSan fixture | Passed; actual writer/reader and generated nanopb encode/decode: mono/stereo flags, attributes/limits, local publication SID, join/state/track updates, malformed-response cleanup |
| Installer | 5 tests and TypeScript/Vite production build passed |
| IoTCloud API | 23 focused tests passed; voice JWT rejected by real MQTT verifier, legacy MQTT tokens unchanged |
| Agent regression suite | 35 tests passed covering wake control, GPT-Live termination and session modality; independent verifier also reran the 14 wake tests |
| API and realtime-agent project type checks | Both passed, 0 errors |
| Scoped API/agent Ruff lint and formatting | Passed |
| Independent review | Luna xhigh reviewed backend, firmware/C SDK and cross-contract changes against the saved pre-implementation snapshot |

Review found and corrected three firmware defects before acceptance: lost critical
events when the callback queue filled, cross-task detector mutations, and drain
timing charging pre-request delays. Added regressions cover notification loss,
capture ownership/epochs, and the true per-request 250 ms / 5 s clock boundaries.

Two real loopback transport runs used LiveKit server 1.13.6, Agents 1.8.8,
RTC 1.1.20 and API 1.2.2. The native peer imported IoTCloud's production
`DeviceWakeControl`; the simulator called the HTTP fixture, published mic/pre-roll,
observed native `listening → speaking → listening`, and required a matching
accepted interruption result. A second `--no-preroll --no-barge` run exercised the
native live fallback and normal completed tone. Both clients and peers exited 0.
These runs establish the Python wire path, not execution on the C SDK/ESP32.

Known Python SDK cleanup warnings remain: `FfiHandle.__del__` assertions and FFI
handle/audio callback errors during teardown, also seen in the earlier isolated
SDK proof. They were retained in the logs; functional success is not a claim of
warning-free teardown. No SDK/provider workaround was added.

Nonsecret build/check logs remain at `/private/tmp/sebastian-native-build-final.log`
and `/private/tmp/sebastian-native-check-final.log`; transport logs are under
`/private/tmp/sebastian-native-transport-bqyyvh0a`. Snapshot/hash records are under
`/private/tmp/sebastian-native-integration-3xi5_255`. The disposable server and its
generated credentials/device-token files were removed. Existing running Aurelia
containers were not restarted.

## Required physical and live-provider acceptance

1. Deploy the reviewed API/agent code through the normal deployment process;
   issue a real device credential and provision the complete endpoint and bearer.
2. Flash only an identified board and verify HTTPS/WSS trust, native startup,
   complete speech within the exported wake window, and pre-roll-before-live audio.
3. Exercise wake during queued speech in both duplex modes, mute, repeated wake,
   rejection of protected greetings, and immediate continuation. Tune/validate
   the 250 ms guard, 150 ms packet-quiet rule and five-second failure close under
   radio jitter; an ACK cannot prove acoustic silence. A too-early new reply can
   conservatively close the call rather than reopen through stale media.
4. Check real configured providers and active GPT-Live Responses delegation for
   cancellation/continuation, recording, tools and shutdown, plus ordinary
   browser/mobile/SIP regression. The synthetic transport did not run them.
5. Repeat USB takeover/release, agent disconnect/reconnect, missing credential,
   expiry and failed session opens; measure PSRAM/internal heap, audio clipping,
   echo, state LEDs and recovery. No synthetic test establishes these properties.

No commit, deployment, provider/home action or board flash was performed.

## Follow-up 2026-11-22: audit findings 1–3

This work addresses the first three findings of
[ASTRA_INTEGRATION_AUDIT.md](ASTRA_INTEGRATION_AUDIT.md). Finding 4 (GPT-Live
cancellation) is unchanged. The current contract is in [PROTOCOL.md](PROTOCOL.md)
(control version 2).

**Finding 1 — failed wake results.** The parser returns `1` for accepted, `-1` for
policy and `-2` for `not_ready`/`timeout`/`invalid`. The mailbox carries
accepted/policy/failed separately. A failure keeps incoming audio gated and
closes the session, and only `policy` restores protected speech. There are host
tests for each reason.

**Finding 2 — first-utterance retention.** The newest-2.5-s cap is gone. The
window is anchored to the wake mark (two-second lead through handoff, up to the
12-second ring), and the ring stops evicting the command after a wake. The stream
is sent in 64 KiB batches separated by credit round trips on the ordered reliable
channel, so the 100 KiB SCTP cache bound is kept. The whole send has a 2.5 s
deadline. The stream declares no total length, so a truncated send is still a
valid, shorter stream. That only helps while RoomIO is still waiting: if its
three-second wait from mic subscription expires first, the whole pre-roll is
discarded (agent log: `timeout waiting for pre-connect audio buffer`). The live microphone starts before the send, and RoomIO
buffers it behind the pre-roll. Not yet established: real ESP32 Wi-Fi throughput.
A long window (up to 384,000 bytes in six batches) may exceed 2.5 s and lose its
newest part. The send log records batches, bytes and `send_ms`, so that can be
measured on the board.

**Finding 3 — continuation.** The first follow-up attempt paused
`session.output.audio` until a device resume. A real-`AgentSession` probe and the
loopback simulator showed it does not hold: `AgentActivity._reconcile_playout_pause`
calls `resume()` whenever the next reply starts forwarding. The agent now
inserts `DeviceOutputHold` directly above the RoomIO sink, for device sessions
only, and holds the next reply's frames independently of pause/resume. The device
drain no longer waits for a `listening` state (that can be coalesced). It reopens
after the 250 ms guard plus 150 ms without packets, then sends
`iotcloud.device.wake.resume`.

**Deployment order.** The agent must be deployed before version-2 firmware. The
agent still serves version-1 firmware (no hold).

### Follow-up checks

| Check | Result |
| --- | --- |
| Agent `tests/test_device_wake.py`, real `AgentSession` | 19 passed. Includes the SDK-resume hold, interrupting a held reply without hanging playout, the unresumed-hold shutdown, and ordinary sessions keeping their output chain. Disabling the hold makes the two hold tests fail. |
| Full realtime-agent suite (Agents 1.8.12) | 1482 passed, 5 skipped |
| Agent ruff check/format, pyright (helper and test) | Passed, 0 errors |
| API `test_device_voice.py` + `test_voice.py` | 52 passed |
| Real loopback: `livekit-server --dev`, `livekit_peer.py` with the production helper, `session_fixture.py`, `simulate_device.py` | Passed twice. 4 s pre-roll in two credited batches; states `listening,speaking,listening,speaking,listening`; no fresh-reply audio before resume. `--no-preroll --no-barge` also passed. The same run with the earlier pause-based helper **failed** (4,800 fresh-reply samples before resume). |
| Loopback packet timing (instrumented scratch copy of the simulator, polling inbound-RTP `packets_received` every 20 ms) | Idle agent track: at most one packet per ~400 ms (DTX). After the ACK: no packets for ~330 ms, until the device resume at 350 ms. Mic subscription to pre-roll stream open: 9 ms; 128 KB sent in 20 ms. |
| `make sdk-test` (ASan/UBSan C SDK fixture), `make protocol-test` | Passed |
| `make http-test`, `make provisioning-test` | Not run on 2026-11-22 (no Docker disk space). Passed on 2026-11-23, see below. |
| `make fw-test fw-fmt`, ESP-IDF target build | Not run on 2026-11-22. The Zig tests, formatting and an Xtensa compile passed on 2026-11-23, see below. **The ESP-IDF target build is still not run.** |

Known Python teardown noise is unchanged (`AUDIO_CAPTURE … server is not configured`).

Board acceptance for these items:
- the pre-roll send time and truncation rate at realistic join delays;
- that no stale tail is heard and the next reply is not clipped, in both duplex
  modes;
- that a lost resume closes cleanly.

## Follow-up 2026-11-23: upstream firmware fixes

Cherry-picked from `Zetesis-Labs/Sebastian` with `-x`. Nothing here has run on a
board, and no board is available yet.

| Upstream commits | Change |
| --- | --- |
| `145a561`, `b262ee1`, `f9ad920` | Pin component versions. `esp-tflite-micro` 1.4.2 moved a header that the wake word component includes. |
| `499a828` | Drain the speaker, then reset the renderer, so session audio resources do not fragment internal RAM. |
| `5a2cdb4`, `ed0fb96` | Engine stack and queue in PSRAM; closing a room mid-negotiation stops its peers. `ed0fb96` is only on upstream's `fix/engine-destroy-peers`. |
| `ee95a17`, `e9c7fd2`, `d6de512` | Keep retrying Wi-Fi after an outage or at boot. Only on upstream's `fix/wifi-reconexion`. |

Deliberately not taken:
- `2cb7c24` (wake word on core 1). Upstream measured it in a playback room, which
  encodes nothing. In a conversation core 1 also runs the Opus encoder and the
  LiveKit peer tasks, at higher priority. Measure on a board first.
- `14fef8c`, `34cb363` (heap diagnostics). Take them when debugging on a board.
- Playback, AirPlay, announcements, and the server, dashboard, Helm and agent
  changes: this branch does not contain that code.

`firmware/dependencies.lock` was aligned by hand for `dl_fft` 0.7.0 and
`esp32-camera` 2.1.7. Its `manifest_hash` is stale, so the next
`idf.py reconfigure` rewrites the lock: review that diff.

| Check (2026-11-23) | Result |
| --- | --- |
| Zig core tests (pinned Zig 0.16.0) | 92 passed |
| `zig fmt --check` | Passed |
| `main/app.zig` compiled for `xtensa-freestanding-none`, `esp32s3`, ReleaseSafe | Passed. Zig only: no C, no link. |
| `make http-test`, `make provisioning-test` | Passed, on the macOS host with cJSON at ESP-IDF v5.4.4's submodule commit `c859b25` |
| `make sdk-test`, `make protocol-test` | Passed |
| Room callbacks (`onStateChanged`, `onParticipantInfo`, `onDataReceived`, `onLocalTrackPublished`, `selectVoiceTrack`, `audioReceiveFilter`) | Source review of their `app.zig` call graph: no call into NVS, profile or provisioning code |
| **ESP-IDF target build and link** | **Not run.** The `espressif/idf:v5.4.4` image did not fit on the development machine. `engine.c` and `provisioning.c` changes have not been compiled for the target, and the pinned dependency set has not been resolved. |

Board acceptance added by these fixes:
- detector frame time while the agent speaks (budget 15 ms per frame), to decide
  the wake word task's core. `Adec` runs on core 0 above the detector; core 1 has
  the Opus encoder and peer tasks;
- the post-session drain, now 1.5 s to 10 s instead of a fixed 1.5 s, so the wake
  word re-arms later after a long reply.

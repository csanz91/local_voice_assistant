# Native IoTCloud integration: implementation and validation

Recorded 2026-10-20. This implements the narrow integration selected by
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
- Firmware exports at most 80,000 raw PCM bytes once per mic SID, after the
  standard agent output publication. It consumes native agent state for LEDs
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

The IoTCloud delta is eight files: three existing API files, two existing agent
entry points, one new wake helper and two focused test files. Relative to the
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

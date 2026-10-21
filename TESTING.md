# Firmware validation

Automated checks and board acceptance are separate. See the exact recorded
results and limitations in [PHASE1_VALIDATION](docs/PHASE1_VALIDATION.md).

```sh
make fw-build-docker
make check fw-fmt
make installer-build
```

The Zig tests cover PCM conversion, native pre-roll bounds, gating, decimation,
AEC math, session reducer/watchdogs, profile selector and USB arbitration.
The C HTTP harness compiles the actual production `session_http.c` against the
ESP-IDF 5.4.4 cJSON parser and deterministic HTTP stubs. It checks full URL/auth,
redirect rejection, certificate configuration, explicit HTTP/WS opt-in, status
failures and malformed, oversized or truncated responses. Stubbed transport does
not prove an ESP32 TLS handshake; board testing must verify trust rejection too.
The provisioning tests run the production USB validation entry point with a
storage spy and check the CLI, including rejection before writes when profile
JSON exceeds the loader's UTF-8 storage limit.
The production C SDK harness checks generated protobuf serialization/decode and
streaming boundaries with ASan/UBSan. The Python fixture suite checks real local
HTTP requests; native RoomIO transport is exercised by the optional peer/simulator.
Installer tests verify partial credential updates, profile preservation and URL
policy; its production build validates TypeScript and Vite packaging.

No automated check flashes hardware. On an identified ReSpeaker/XIAO, verify:

- Boot/XVF DFU, audio in/out, comms channel, AEC readback/fallback and safe boot.
- Okay Nabu activation, physical mute/software capture gating and state LEDs.
- Local profile selector, serial read/write/credential persistence and USB window.
- USB input capture, host mute/volume, agent-to-USB takeover and release.
- Session auth, HTTPS/WSS trusted chain/hostname, untrusted/expired cert rejection,
  HTTP disabled by default, refused redirects and backend unavailable recovery.
- Against the disposable [protocol harness](docs/PROTOCOL.md): complete first
  utterance/pre-roll ordering, LiveKit audio, states, wake interruption/flush and
  disconnect recovery. Repeat failed opens, missing agent, WiFi loss and server restart.
- Repeated conversations at realistic volume; record clipping, echo, latency,
  internal RAM and teardown behavior. Maximum-volume XVF reliability remains an
  upstream acoustic concern until measured on this board.

Keep the matching ELF/map for coredump analysis. A successful host/build check
never counts as physical/acoustic acceptance. No OTA slots exist in the current
factory+coredump partition table.

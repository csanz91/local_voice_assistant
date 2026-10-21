# Sebastian ESP32 voice firmware

Reusable firmware for the Seeed ReSpeaker XVF3800 + XIAO ESP32-S3. It retains
local Okay Nabu activation, XVF DSP/AEC, Opus/LiveKit audio, bounded pre-roll,
USB microphone and automatic microphone arbitration, persistent profiles,
physical mute, LEDs, boot recovery and diagnostics.

This repository contains firmware, a standalone USB installer and development
protocol fixtures. The session backend and voice agent live outside this project.
The [integration plan](docs/INTEGRATION_PLAN.md) and [SDK proof](docs/SDK_COMPATIBILITY.md)
describe the native IoTCloud handoff.

Build with ESP-IDF **5.4.4**, the pinned **0.16.0-xtensa Zig fork**, and the local
patched LiveKit **0.3.10** component:

```sh
make fw-build-docker       # requires Docker; downloads dependencies/compiler
make fw-test fw-fmt        # pure firmware tests, formatting
make http-test protocol-test provisioning-test
make installer-build      # Node.js/npm; standalone web-installer/dist
make installer-image      # packages sparse firmware parts, no publish
```

Native ESP-IDF and devcontainer instructions are in [BUILD_AND_RUN](docs/BUILD_AND_RUN.md).
Provision WiFi, the **complete HTTPS session endpoint**, and a device credential
through USB. Existing NVS settings survive; update the old token URL to the new
complete endpoint instead of erasing NVS. The location owner issues a 90-day
voice credential for the device already in IoTCloud's inventory and provisions
it as `device.secret`. The board does not generate a local backend credential.

The [session and LiveKit protocol](docs/PROTOCOL.md) documents the implemented
call adapter, native pre-roll/state and minimal interruption handler.
For development, `tools/protocol/` provides a disposable authenticated session
fixture and optional LiveKit test peer. No production IoTCloud endpoint is
required for the disposable tests.

See [TESTING](TESTING.md), [integration validation](docs/IMPLEMENTATION_VALIDATION.md),
[Phase 1 validation](docs/PHASE1_VALIDATION.md),
[hardware](docs/HARDWARE.md), [audio architecture](docs/ARCHITECTURE.md),
[profiles](docs/PROFILES.md), [USB mic](docs/USB_MIC.md), and [troubleshooting](docs/TROUBLESHOOTING.md).

Original project attribution remains in [LICENSE](LICENSE). Dependency licenses
and the embedded XVF/model assets are retained; the SDK patch is documented in
[LOCAL_PATCHES](firmware/components/livekit/LOCAL_PATCHES.md).

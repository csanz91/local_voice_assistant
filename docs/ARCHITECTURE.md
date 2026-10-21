# Firmware architecture

The common boot path initializes the board, serial provisioning, device identity,
profiles, XVF firmware/DSP and LED UI. TinyUSB takes the shared USB PHY after a
5-second provisioning window (extended by configuration read). The active profile
then selects LiveKit conversation mode or a standalone USB microphone.

Conversation flow:

1. The local Okay Nabu detector consumes LEFT/comms I2S audio and fills pre-roll.
2. A wake requests a session at the complete provisioned HTTPS endpoint, using
   the owner-issued, voice-scoped device bearer credential.
3. LiveKit connects using the response's WSS URL and short-lived token. The
   application waits for room/agent readiness before handing microphone ownership
   from wake detection to the live capture path.
4. Bounded raw PCM pre-roll uses the native RoomIO stream and the published mic
   SID after `roomio_audio` appears. RoomIO preserves pre-roll-before-live order.
5. The standard `lk.agent.state` attribute drives LEDs and half-duplex gating.
   Wake flushes and gates the renderer, and a reliable correlated request invokes
   the normal agent interruption API. Local drain bounds, disconnect and
   silence/max-duration watchdogs govern recovery.
6. Clean teardown resets the gates and returns to local wake listening. The
   watchdog bounds blocking transport calls.

`core/session_reducer.zig` owns host-tested session transitions;
`core/arbiter_core.zig` controls USB ownership hysteresis. In agent mode, sustained
host capture causes clean session teardown and gives the microphone to USB.
After host capture stops, wake detection resumes. `usb_mic` profiles keep the
microphone without creating sessions and can disable WiFi completely.

The board keeps separate I2S RX/TX ports, LEFT/comms capture, codec setup and XVF
AEC fallback. PSRAM holds large buffers and the wake arena; scarce internal
DMA RAM remains available to USB/WiFi/TLS. See [FIRMWARE](FIRMWARE.md),
[AEC](AEC.md), [USB_MIC](USB_MIC.md) and [PROTOCOL](PROTOCOL.md).

Only USB provisioning and local profile selection modify persistent settings.
There is no fleet polling, UDP adoption, meeting recording path or production
backend in this repository. IoTCloud owns credential issuance, normal session
creation and the small opt-in wake handler; audio processing stays in RoomIO.

# Local provisioning protocol

The firmware accepts newline-terminated USB serial commands at 115200 baud:

```text
sebastian.config.v1 {"schema":"sebastian.config.v1",...}
sebastian.config.get
sebastian.profile.set {"name":"micro-usb"}
```

A config write replies `sebastian.config.ok` and restarts. Validation failures
reply `sebastian.config.err <reason>`. The complete command, including prefix and
newline, must fit within 8191 UTF-8 bytes. A document is a partial update: omitted
fields keep their current NVS values. The web form fills ordinary settings with
defaults, but preserves omission for credentials and profiles.

```json
{
  "schema": "sebastian.config.v1",
  "mode": "full_duplex",
  "wifi": {"ssid": "Home", "password": "replace-me"},
  "livekit": {
    "tokenServerUrl": "https://api.example.com/api/v2/device-voice-session",
    "allowInsecureHttp": false
  },
  "device": {"secret": "replace-with-a-per-device-credential"},
  "telemetry": {"syslogIp": "", "syslogPort": 514},
  "audio": {"fullDuplex": true, "fixedBeam": true, "fixedBeamAzimuthDeg": 0},
  "session": {"silenceTimeoutMs": 12000, "voiceLevel": 3000},
  "profiles": [
    {"name": "agente", "mode": "agent"},
    {"name": "micro-usb", "mode": "usb_mic", "fixedBeam": false}
  ],
  "activeProfile": "agente"
}
```

`tokenServerUrl` retains its old NVS-compatible name but now means the **complete
session endpoint**. The firmware posts directly to that URL without appending a
path. Update older origin-only URLs; an NVS erase is unnecessary. Endpoint URLs
are limited to 255 UTF-8 bytes and cannot contain credentials, fragments,
whitespace or control characters. HTTPS uses certificate validation. Local HTTP
requires `allowInsecureHttp: true`; this opt-in never disables HTTPS verification.

Session authentication uses `Authorization: Bearer <device.secret>`. Provision
an owner-issued, voice-scoped device JWT from
`POST /api/v2/device-voice-credential/device_id/{device_id}` while signed into
IoTCloud as the current device owner. It expires after 90 days; renew manually
before expiry. Ordinary MQTT tokens and user OIDC tokens are not device voice
credentials. `POST /api/v2/device-voice-session` returns HTTP `200` and
`{"serverUrl":"wss://…","participantToken":"…","roomName":"…","conversationId":"…"}`.
Provider and LiveKit signing keys remain on the server.

## Credentials and config dumps

Omitting `wifi.password` or `device.secret` preserves the stored value. Empty
`wifi.password` selects an open network. Empty `device.secret` deliberately clears
it; voice sessions remain unavailable until a replacement JWT is provisioned.
Credentials use up to 1024 printable ASCII characters without spaces.
The installer can
import legacy `adoption.deviceSecret` into `device.secret`; organization adoption
is removed and `adoption.orgSecret` is discarded.

`config.get` replies `sebastian.config.dump <JSON>` containing stored settings,
`provisioned`, `wifi.passwordSet` and `device: {id, secret, secretSet}`. The WiFi
password is never returned. The physical USB read includes the normalized
hardware MAC ID and per-device credential so an operator can register them with
their backend. The installer holds this readback separately from the editable
config, previews, exports and logs. Use the private pairing panel's explicit
Reveal or Copy action; protect the credential and clear the clipboard afterward.
Merely loading and sending does not rotate or rewrite the credential. Legacy
credential readback is likewise kept out of the editable document.

Load keeps the serial connection open for 120 seconds so the
same port can receive edits. Otherwise the boot serial window lasts around five
seconds before the USB microphone takes the ESP32-S3 USB PHY. Replug after a
restart or lost connection.

## Settings

| Field | Behavior |
| --- | --- |
| `mode` | Sets the full/half duplex audio preset; explicit audio keys can override it. |
| `wifi.ssid` / `password` | WiFi credentials, applied on boot. SSID max 32 bytes; password max 64 bytes. |
| `livekit.tokenServerUrl` / `allowInsecureHttp` | Complete session endpoint and explicit development HTTP opt-in. |
| `device.secret` | Per-device session credential; absent preserves, empty clears. |
| `telemetry.syslogIp` / `syslogPort` | Optional IPv4 UDP syslog receiver. Empty IP disables remote logging. |
| `audio.fullDuplex` / `fixedBeam` / `fixedBeamAzimuthDeg` | Stored audio settings, applied at boot before XVF/AEC setup. |
| `session.silenceTimeoutMs` / `voiceLevel` | Silence timeout 5000–120000 ms; voice threshold 1–32767. |
| `profiles` | Up to six named agent/USB microphone profiles. Omitted preserves; `[]` restores built-ins. Stored JSON max 1023 bytes. |
| `activeProfile` | Selects a profile by name. Omitted preserves existing selection. |

Profiles have a unique `name` of 1–23 UTF-8 bytes, optional `mode` (`agent` or
`usb_mic`) and optional `fullDuplex`, `fixedBeam`, `beamAzimuthDeg`, `wifi` and
`telemetry` overrides. A selected profile can override the global audio settings.
The existing profile selector and boot-failure guard remain firmware features.

The microphone channel is compiled as LEFT/comms. Boot audio diagnostics also
require a rebuild. Removed or ignored legacy fields (`wifi.hidden`,
`audio.micChannel`, static LiveKit `deviceIdentity`/`room`/`agentName`, OTLP/Grafana
settings and fleet config versions) are not presented as working device settings.
The canonical document shape is
[sebastian-config.schema.json](sebastian-config.schema.json); byte limits and
cross-field constraints are also validated by the installer/firmware.

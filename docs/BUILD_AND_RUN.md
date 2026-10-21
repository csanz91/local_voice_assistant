# Build, install and provision

Use ESP-IDF **5.4.4**, Xtensa Zig **0.16.0-xtensa** and LiveKit ESP32 **0.3.10**.
The component lock and Zig SHA256s are committed. Do not upgrade the SDK during
extraction. First build needs internet access to the Espressif registry and GitHub.

## Docker or devcontainer

From the repository root:

```sh
make fw-build-docker
make fw-test fw-fmt http-test protocol-test
```

The build runs a disposable `espressif/idf:v5.4.4` container with just this
repository mounted at `/workspace`; it starts no backend services. The downloaded
Linux Zig also runs through Docker when called by `tools/zig.sh` on macOS.
Open the supplied devcontainer for interactive IDF commands and `make fw-build`.
On a native installation, `tools/idf.sh` uses `IDF_PATH` or `~/esp/esp-idf`.
Use a separate build directory when changing between native and Docker paths.

ESP-IDF may rewrite the local LiveKit lock source to an absolute path. Before
sharing, retain `path: ../components/livekit` in `firmware/dependencies.lock`.
The main component describes the actual publisher-only data-channel patch.

## Flash

Identify the XIAO ESP32-S3 port before flashing. Flashing writes the application,
bootloader and partition table; avoid erase-flash to preserve NVS settings.
No board is flashed by the automated checks.

```sh
PORT=/dev/cu.usbmodemYOUR_BOARD make flash
# or from an IDF environment:
PORT=/dev/ttyACM0 make fw-flash
```

If necessary hold BOOT, tap RESET, release BOOT to enter download mode. After
normal boot the USB peripheral becomes a UAC microphone; serial provisioning
is available for the first 5 seconds. `sebastian.config.get` extends the window
to 120 seconds. Unplug/replug to reopen serial. XVF firmware family conversion
and I2C/audio diagnostics are covered in [XVF3800](XVF3800.md) and
[TROUBLESHOOTING](TROUBLESHOOTING.md).

## Standalone installer

```sh
make installer-build
make installer-image
cd web-installer && npm run preview
```

The output is `web-installer/dist/`. Firmware packaging copies separate bootloader,
partition table and app parts, avoiding the NVS gap. Leave **Erase device unchecked**
in ESP Web Tools to preserve existing settings. The enabled erase prompt defaults
to unchecked; disabling that prompt would automatically erase a non-Improv device. Nothing is published automatically.
Use Chrome/Edge with Web Serial on localhost or HTTPS; choose the identified
board. Obtain an owner-issued voice credential for the existing inventory device
using the [device endpoint](PROTOCOL.md), then provision it as `device.secret`.
Treat exported configuration files as private credentials.

Provision at least:

```json
{
  "schema": "sebastian.config.v1",
  "wifi": {"ssid": "YOUR_WIFI", "password": "YOUR_WIFI_PASSWORD"},
  "livekit": {
    "tokenServerUrl": "https://api.example.test/api/v2/device-voice-session",
    "allowInsecureHttp": false
  }
}
```

A device voice credential is owner-issued, expires after 90 days and is stored as
`dev_secret`. Provision `device.secret` to install or replace it. Missing fields retain existing
NVS values. Old `adoption.deviceSecret` imports still work; organization secrets
are ignored. `token_url`, WiFi, profiles and audio settings keep their NVS keys.
Do not include user/M2M credentials, LiveKit API secrets or model keys on a board.

HTTPS and WSS verify the IDF public root CA bundle and hostname. The complete
endpoint path/query is preserved. HTTP redirects are refused. A private CA must
be deliberately added to the build's certificate bundle; there is no insecure
fallback. For a local test network only, explicitly provision
`livekit.allowInsecureHttp: true` to permit HTTP session creation and WS LiveKit.
Clock synchronization must complete before TLS can validate time-bound certs.

The CLI alternative is `uv run tools/provision_device.py private-config.json PORT`.
See the [serial protocol](../web-installer/public/PROVISIONING.md) and
[profiles](PROFILES.md) for USB-only configuration and local selection.

# Standalone ESP32 installer

Flash and provision the ReSpeaker XVF3800 + XIAO ESP32-S3 using ESP Web Tools and
Web Serial. Serve this static app over HTTPS or localhost in a browser exposing
`navigator.serial`.

```sh
cd web-installer
npm ci
npm test
npm run build
```

`dist/` contains the static site. From the repository root run
`tools/prepare_web_installer.sh` after building firmware to copy separate
bootloader/partition-table/app files into `dist/firmware/` and write its manifest.
Use sparse parts so flashing does not write the NVS gap. In ESP Web Tools leave
**Erase device unchecked** to preserve WiFi, device credentials and profiles.
The erase prompt is enabled because disabling it makes ESP Web Tools automatically
erase this non-Improv firmware. The UI checks all three part headers before
allowing installation. No dashboard or hosted publishing service is required.

Load an already flashed board to edit its settings, or import a JSON file. Set
WiFi, the complete session POST URL (including your proxy prefix/path), audio
settings and optional local profiles. HTTPS certificate validation is the default;
plain HTTP needs the explicit local development switch. Server-issued LiveKit
room, participant identity and agent selection are not provisioning fields.

Omitted WiFi passwords and device credentials preserve stored values. To replace
the device credential, enable replacement and enter its new value. An explicit
empty credential clears it; the next boot generates a fresh value. The WiFi password is never returned. Physical USB reads include the device ID
and credential in a separate private pairing panel: the credential remains hidden
until you explicitly reveal or copy it. Register that ID and credential with your
backend. The on-screen JSON preview redacts entered secrets and does not include
the pairing readback.
Download and Copy are explicit exports and include any credentials you entered;
protect those files and clipboard contents.

The Profiles JSON editor preserves agent/USB microphone profiles on load, import
and export. Blank keeps the current array; `[]` restores the firmware's built-in
profiles. Select an active profile by its stored name. Microphone capture uses the
firmware's compiled LEFT/comms channel; this UI does not pretend to change it.

After USB power-up, the serial provisioning window lasts approximately five
seconds before TinyUSB takes over for audio. Load from device holds the window
open for 120 seconds. Close other monitor/serial readers first. If connection
fails, unplug/replug the board; the ReSpeaker RESET button resets the XVF chip.

The ESP32 installer does not perform the XMOS USB-to-I2S firmware-family switch
needed on a new XVF3800 board. Follow the repository hardware instructions first.
See [PROVISIONING.md](PROVISIONING.md) and
[sebastian-config.schema.json](sebastian-config.schema.json) for the wire format.

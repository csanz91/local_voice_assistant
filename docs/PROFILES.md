# Provisioning profiles

One binary, several personalities. A **profile** is a named capability bundle
stored in NVS; the active profile decides what Sebastian IS after boot:

- `mode`: `agent` (LiveKit voice assistant) or `usb_mic` (plug-and-play USB
  microphone — see `USB_MIC.md`)
- optional overrides of the audio config: `fullDuplex`, `fixedBeam`,
  `beamAzimuthDeg`
- `wifi`: en `usb_mic`, `false` desactiva la red; sin esa exclusión se habilitan
  syslog opcional. `telemetry` se conserva en el perfil, pero actualmente
  no controla por separado el arranque de la telemetría.

Fields a profile does not set are inherited from the legacy NVS keys /
compiled defaults (`config.zig`), so pre-profile units keep their behaviour.

With no provisioned profiles the firmware ships two built-ins:

| # | Name | Ring color | What |
|---|------|-----------|------|
| 0 | `agente` | azul | LiveKit agent, config inherited |
| 1 | `micro-usb` | ámbar | USB mic, adaptive beam |

## Modo convivencia (agente + micro USB a la vez)

Since the arbitration work, the `agent` mode ALSO exposes the USB mic — the
personality switch for the everyday desk case is **implicit, usage-driven and
zero-config**:

- Plugged into a charger/TV: pure agent (nothing ever opens the USB stream).
- Plugged into a computer: the agent runs normally AND "Sebastian Mic" is
  available as an input source. The moment an app actually captures from it
  (~300 ms sustained), the agent yields the mic — wake word off, ring beam
  turns **amber** — and the host gets the echo-cancelled comms beam. When the
  host stops capturing (~3 s of silence, hysteresis against flapping hosts),
  the agent takes the mic back and the wake word rearms.
- If it happens mid-conversation, the session closes cleanly first (the user
  at the PC wins).

The explicit `usb_mic` profile remains for a pure offline mic (`wifi: false`),
and can be selected locally.

## Switching profiles

**Boot selector (on-device)** — when the ring lights up dim white shortly
after plugging in (~2-3 s, once the XVF is up), double-tap the mute button.
The ring splits into one colored arc per profile: each further press advances
the highlighted arc, leaving the button alone for 5 s confirms. The choice
persists and boot continues straight into the chosen profile. A unit that
merely boots muted never triggers the selector (zero button *changes*).

**Serial (installer / scripts)** — one line over USB-Serial-JTAG during the
**5 s provisioning window** at every boot, in BOTH modes (convivencia keeps
TinyUSB up alongside the agent, so the PHY stops being serial right after the
window; unplug/replug to reopen USB serial):

Una lectura `sebastian.config.get` amplía la ventana a **120 s** antes de que
TinyUSB tome el periférico; véase [aprovisionamiento](../web-installer/public/PROVISIONING.md).

```
sebastian.profile.set {"name":"micro-usb"}
```

Replies `sebastian.profile.ok` and reboots into the profile (`err` if the name
matches no profile). The full installer flow (`sebastian.config.v1 {...}`) also
accepts a `profiles` array plus `activeProfile`:

```json
{
  "schema": "sebastian.config.v1",
  "wifi": { "ssid": "...", "password": "..." },
  "profiles": [
    { "name": "salon-full", "mode": "agent", "fullDuplex": true, "fixedBeam": true },
    { "name": "salon-half", "mode": "agent", "fullDuplex": false, "fixedBeam": false },
    { "name": "micro-usb", "mode": "usb_mic" }
  ],
  "activeProfile": "salon-full"
}
```

Limits: max 6 profiles, names up to 23 chars; the whole provisioning line must
fit the 8 KB boot-window command buffer. The compact `profiles` array must
fit within **1023 UTF-8 bytes** (the shared C loader capacity includes one NUL).
Direct USB provisioning and the CLI reject larger arrays before NVS writes.
Command storage is temporary PSRAM; the receiver task and USB-serial driver are
released before TinyUSB takes the PHY.

## Safe boot (anti-brick)

A boot counter increments at every boot start and clears once the selected
mode is up. "Up" means **administrable**, not connected: for the agent that is
provisioning listening + audio pipeline built, deliberately before the WiFi
connect (an outage is not a broken boot); for usb_mic it is the UAC device
initialized. Three straight failed boots ⇒ the firmware runs the first `agent`
profile for that boot, **in memory only** — the provisioned choice is never
rewritten, so a transient failure can't hijack the profile (field-validated).
While failures persist the fallback re-fires each boot; one healthy boot
clears the counter and the provisioned profile returns.

## Storage

NVS namespace `sebastian` (same as provisioning): `profiles` (raw JSON array),
`active_prof` (name), `boot_fails` (i32). Parsing lives in
`main/profiles.c`; `main/profile.zig` overlays the active profile onto
`config.zig` at boot, and the selector state machine is host-tested pure logic
in `main/core/selector_core.zig`.

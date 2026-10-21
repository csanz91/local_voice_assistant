import type { DeviceConfig, OperatingMode } from "./config";

// Single source of truth for the config form: every field's label, help text,
// whether the firmware applies it today, and which mode it belongs to. The form
// (ConfigForm) is rendered from this — no hand-wired inputs.

export type FieldType = "text" | "password" | "url" | "number" | "toggle" | "enum";

export interface FieldMeta {
  path: string; // dot path into DeviceConfig, e.g. "audio.fixedBeamAzimuthDeg"
  label: string;
  help: string;
  type: FieldType;
  applied?: boolean; // firmware stores + applies it today (NVS badge)
  advanced?: boolean; // hidden until "Show advanced" is on
  options?: { value: string; label: string }[];
  unit?: string;
  min?: number;
  max?: number;
  placeholder?: string;
  issuePath?: string; // where to look up a validation issue (defaults to path)
}

export interface Lock {
  label: string;
  value: string;
  why: string;
}

export interface ModeMeta {
  id: OperatingMode;
  pill: string;
  title: string;
  sub: string;
  blurb: string;
  best: string;
  callout?: { tone: "info" | "warn"; text: string };
  locks: Lock[];
  fields: FieldMeta[];
}

export type SharedIcon = "wifi" | "cloud" | "chart";
export interface SharedGroup {
  id: string;
  title: string;
  sub: string;
  icon: SharedIcon;
  fields: FieldMeta[];
}

// ── read/write a config value by dot path (paths are always section.key) ──────
// Sections may be absent (device is optional): reading one must not throw,
// or the whole form dies with the field.
// A top-level key ("mode") is read and written as such — spreading a string
// into an object was how a mode once became {"0":"f","1":"u",…}.
export function getField(config: DeviceConfig, path: string): unknown {
  const [section, key] = path.split(".") as [keyof DeviceConfig, string | undefined];
  if (key === undefined) return config[section];
  const holder = (config[section] ?? {}) as Record<string, unknown>;
  return holder[key];
}

export function setField(config: DeviceConfig, path: string, value: unknown): DeviceConfig {
  const [section, key] = path.split(".") as [keyof DeviceConfig, string | undefined];
  if (key === undefined) return { ...config, [section]: value };
  return { ...config, [section]: { ...((config[section] ?? {}) as object), [key]: value } };
}

const sessionFields: FieldMeta[] = [
  {
    path: "session.silenceTimeoutMs",
    applied: true,
    label: "Silence to close",
    type: "number",
    unit: "ms",
    min: 5000,
    max: 120000,
    advanced: true,
    help:
      "How long it waits in silence before ending the session and going back to listening for the wake word. Higher tolerates long pauses; lower closes sooner.",
  },
  {
    path: "session.voiceLevel",
    applied: true,
    label: "Voice threshold",
    type: "number",
    min: 1,
    max: 32767,
    advanced: true,
    help:
      "Audio level (0–32767) above which it counts as you speaking, so your turn isn't cut short. Raise it in noisy rooms.",
  },
];

// ── the operating modes ─────────────────────────────────────────────────
export const MODES: ModeMeta[] = [
  {
    id: "full_duplex",
    pill: "Default",
    title: "Full-duplex",
    sub: "Natural conversation",
    blurb: "The mic stays open while it speaks: you cut in just by talking, no wake word.",
    best: "Quiet room · speaker in a fixed spot",
    callout: {
      tone: "info",
      text: "Relies on the AEC cancelling the speaker's echo. If your room is echoey or reverberant, use Half-duplex.",
    },
    locks: [
      {
        label: "Mic beam",
        value: "Fixed",
        why: "The echo canceller (AEC) only converges with a fixed beam. Without it, the agent would hear itself.",
      },
    ],
    fields: [
      {
        path: "audio.fixedBeamAzimuthDeg",
        label: "Speaker direction",
        type: "number",
        unit: "°",
        min: -180,
        max: 180,
        applied: true,
        help:
          "Where the fixed beam points. 0° = straight ahead of the array; positive = counter-clockwise. Aim it at where you sit: it improves pickup and helps the AEC converge.",
      },
      ...sessionFields,
    ],
  },
  {
    id: "half_duplex",
    pill: "Robust",
    title: "Half-duplex",
    sub: "Turn-taking",
    blurb:
      "You talk in turns; to interrupt while it speaks you say the wake word. Far more immune to echo, noise and flaky networks.",
    best: "Echoey/noisy rooms · congested 2.4 GHz",
    callout: {
      tone: "info",
      text: "The recommended mode when there's echo or the device's link is weak: it kills the “hears-itself” loop.",
    },
    locks: [
      {
        label: "Mic beam",
        value: "Adaptive",
        why: "Tracks the speaker wherever they are (no need to aim it). Echo is handled by turn-taking + wake-word barge-in.",
      },
      {
        label: "Interrupt",
        value: "Wake word",
        why: "Since the mic is muted while the agent speaks, you cut in by saying the wake word (barge-in).",
      },
    ],
    fields: [...sessionFields],
  },
];

// ── sections shown in every mode ──────────────────────────────────────────────
export const SHARED: SharedGroup[] = [
  {
    id: "net",
    icon: "wifi",
    title: "WiFi network",
    sub: "2.4 GHz",
    fields: [
      {
        path: "wifi.ssid",
        label: "Network name (SSID)",
        type: "text",
        applied: true,
        placeholder: "MyNetwork",
        issuePath: "wifi.ssid",
        help: "The WiFi network the device joins. The ESP32-S3 is 2.4 GHz only.",
      },
      {
        path: "wifi.password",
        label: "Password",
        type: "password",
        applied: true,
        help: "Stored in the device's NVS, not returned on load. An untouched field preserves the stored password; editing to empty selects an open network.",
      },
    ],
  },
  {
    id: "lk",
    icon: "cloud",
    title: "Session access",
    sub: "your backend",
    fields: [
      {
        path: "livekit.tokenServerUrl", label: "Full session endpoint URL", type: "url", applied: true,
        placeholder: "https://api.example.com/api/v2/device-voice-session", issuePath: "livekit.tokenServerUrl",
        help: "Complete POST endpoint, including its path. The backend authenticates the device and creates the LiveKit room and token. The firmware does not append a path.",
      },
      {
        path: "livekit.allowInsecureHttp", label: "Allow HTTP for local development", type: "toggle", applied: true,
        help: "Off by default. Enable only for a trusted local development endpoint. HTTP sends the device credential without transport encryption.",
      },
    ],
  },
  {
    id: "tel",
    icon: "chart",
    title: "Telemetry",
    sub: "optional",
    fields: [
      {
        path: "telemetry.syslogIp",
        label: "Syslog receiver IP",
        type: "text",
        applied: true,
        placeholder: "192.168.1.10",
        issuePath: "telemetry.syslogIp",
        help: "Optional UDP syslog receiver. Empty keeps logs on the device.",
      },
      {
        path: "telemetry.syslogPort",
        label: "Syslog port",
        type: "number",
        applied: true,
        min: 1,
        max: 65535,
        issuePath: "telemetry.syslogPort",
        help: "UDP port of the syslog receiver. Default 514.",
      },
    ],
  },
];

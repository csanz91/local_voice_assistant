import type { DeviceConfig } from "./config";

export interface FieldIssue { path: string; message: string; severity: "error" | "warning" }
const byteLength = (value: string) => new TextEncoder().encode(value).length;

export function validate(config: DeviceConfig): FieldIssue[] {
  const issues: FieldIssue[] = [];
  const error = (path: string, message: string) => issues.push({ path, message, severity: "error" });
  if (!config.wifi.ssid.trim() || byteLength(config.wifi.ssid) > 32) error("wifi.ssid", "SSID must contain 1–32 UTF-8 bytes.");
  if (config.wifi.password !== undefined && byteLength(config.wifi.password) > 64) error("wifi.password", "WiFi password must fit in 64 bytes.");
  const endpoint = config.livekit.tokenServerUrl;
  if (!endpoint) {
    issues.push({ path: "livekit.tokenServerUrl", message: "Without a session endpoint the device cannot open conversations.", severity: "warning" });
  } else {
    try {
      const url = new URL(endpoint);
      if (endpoint !== endpoint.trim() || /[\s\u0000-\u001f\u007f\\]/.test(endpoint) || byteLength(endpoint) > 255 ||
          !/^https?:\/\//.test(endpoint) || !url.hostname || url.username || url.password || endpoint.includes("#") ||
          (url.protocol !== "https:" && !(url.protocol === "http:" && config.livekit.allowInsecureHttp))) {
        throw new Error();
      }
    } catch {
      error("livekit.tokenServerUrl", "Use a complete HTTPS session URL (max 255 bytes), without URL credentials or fragments. HTTP requires the development opt-in.");
    }
  }
  const ip = config.telemetry.syslogIp;
  if (ip && (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip) || ip.split(".").some((part) => Number(part) > 255))) error("telemetry.syslogIp", "Use a valid IPv4 address or leave empty.");
  if (!Number.isInteger(config.telemetry.syslogPort) || config.telemetry.syslogPort < 1 || config.telemetry.syslogPort > 65535) error("telemetry.syslogPort", "Port must be 1–65535.");
  if (!Number.isInteger(config.session.silenceTimeoutMs) || config.session.silenceTimeoutMs < 5000 || config.session.silenceTimeoutMs > 120000) error("session.silenceTimeoutMs", "Use 5000–120000 ms.");
  if (!Number.isInteger(config.session.voiceLevel) || config.session.voiceLevel < 1 || config.session.voiceLevel > 32767) error("session.voiceLevel", "Use an integer from 1 to 32767.");
  if (!Number.isFinite(config.audio.fixedBeamAzimuthDeg) || config.audio.fixedBeamAzimuthDeg < -180 || config.audio.fixedBeamAzimuthDeg > 180) error("audio.fixedBeamAzimuthDeg", "Use an angle from −180 to 180 degrees.");
  const secret = config.device?.secret;
  if (secret !== undefined && (secret.length > 1024 || /[^\x21-\x7e]/.test(secret))) error("device.secret", "Use up to 1024 printable ASCII characters without spaces. Empty clears the credential. Provision a voice-scoped device JWT before opening a session.");

  if (config.profiles !== undefined) {
    const names = new Set<string>();
    if (config.profiles.length > 6) error("profiles", "At most 6 profiles are supported.");
    if (byteLength(JSON.stringify(config.profiles)) > 1023) error("profiles", "Profiles must fit in 1023 UTF-8 bytes.");
    for (const entry of config.profiles) {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) { error("profiles", "Each profile must be an object."); continue; }
      if (typeof entry.name !== "string" || !entry.name || byteLength(entry.name) > 23 || /[\u0000-\u001f\u007f]/.test(entry.name) || names.has(entry.name)) error("profiles", "Profile names must be unique and contain 1–23 UTF-8 bytes without control characters.");
      names.add(entry.name);
      if (entry.mode !== undefined && entry.mode !== "agent" && entry.mode !== "usb_mic") error("profiles", "Profile mode must be agent or usb_mic.");
      for (const [key, value] of Object.entries(entry)) {
        if (["fullDuplex", "fixedBeam", "wifi", "telemetry"].includes(key)) {
          if (typeof value !== "boolean") error("profiles", `${key} must be a boolean.`);
        } else if (key === "beamAzimuthDeg") {
          if (typeof value !== "number" || !Number.isFinite(value) || value < -180 || value > 180) error("profiles", "beamAzimuthDeg must be −180…180.");
        } else if (!["name", "mode"].includes(key)) error("profiles", `Unsupported profile field: ${key}`);
      }
    }
    if (config.activeProfile && config.profiles.length && !names.has(config.activeProfile)) error("activeProfile", "The active profile must name one of the supplied profiles.");
  }
  if (config.activeProfile !== undefined && (!config.activeProfile || byteLength(config.activeProfile) > 23 || /[\u0000-\u001f\u007f]/.test(config.activeProfile))) error("activeProfile", "Active profile must contain 1–23 UTF-8 bytes without control characters.");
  if (byteLength(`sebastian.config.v1 ${JSON.stringify(config)}\n`) > 8191) error("profiles", "The complete provisioning command must fit in 8191 bytes.");
  return issues;
}

export const hasBlockingErrors = (issues: FieldIssue[]): boolean => issues.some((issue) => issue.severity === "error");

export const CONFIG_SCHEMA = "sebastian.config.v1";
export type OperatingMode = "full_duplex" | "half_duplex";
export const OPERATING_MODES: OperatingMode[] = ["full_duplex", "half_duplex"];

export interface DeviceProfile {
  name: string;
  mode?: "agent" | "usb_mic";
  fullDuplex?: boolean;
  fixedBeam?: boolean;
  beamAzimuthDeg?: number;
  wifi?: boolean;
  telemetry?: boolean;
}

export interface DeviceConfig {
  schema: typeof CONFIG_SCHEMA;
  mode: OperatingMode;
  wifi: { ssid: string; password?: string };
  // Keep this NVS-compatible name: the value is the complete session endpoint.
  livekit: { tokenServerUrl: string; allowInsecureHttp: boolean };
  telemetry: { syslogIp: string; syslogPort: number };
  audio: { fixedBeam: boolean; fixedBeamAzimuthDeg: number; fullDuplex: boolean };
  session: { silenceTimeoutMs: number; voiceLevel: number };
  device?: { secret?: string };
  profiles?: DeviceProfile[];
  activeProfile?: string;
}

export const MODE_PRESETS: Record<OperatingMode, Partial<DeviceConfig["audio"]>> = {
  full_duplex: { fullDuplex: true, fixedBeam: true },
  half_duplex: { fullDuplex: false, fixedBeam: false },
};

export function applyMode(config: DeviceConfig, mode: OperatingMode): DeviceConfig {
  return { ...config, mode, audio: { ...config.audio, ...MODE_PRESETS[mode] } };
}

export const defaultConfig = (): DeviceConfig => ({
  schema: CONFIG_SCHEMA,
  mode: "full_duplex",
  wifi: { ssid: "" },
  livekit: { tokenServerUrl: "", allowInsecureHttp: false },
  telemetry: { syslogIp: "", syslogPort: 514 },
  audio: { fixedBeam: true, fixedBeamAzimuthDeg: 0, fullDuplex: true },
  session: { silenceTimeoutMs: 12000, voiceLevel: 3000 },
});

export const serialize = (config: DeviceConfig): string => JSON.stringify(config, null, 2);

// Preview and serial logs must never print credentials automatically. Export is
// an explicit operator action and intentionally contains entered credentials.
export function preview(config: DeviceConfig): string {
  return serialize({
    ...config,
    wifi: { ...config.wifi, ...(config.wifi.password !== undefined ? { password: "[redacted]" } : {}) },
    ...(config.device?.secret !== undefined ? { device: { secret: "[redacted]" } } : {}),
  });
}

export interface DeviceDump {
  provisioned: boolean;
  passwordSet: boolean;
  secretSet: boolean;
  deviceId?: string;
  storedDeviceSecret?: string;
  config: DeviceConfig;
}

const object = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : {};

export function parseDump(input: unknown): DeviceDump {
  const src = object(input);
  const wifi = object(src.wifi);
  const device = object(src.device);
  const legacy = object(src.adoption);
  const config = mergeConfig(src);
  // Physical USB pairing readback stays separate from the editable document.
  // It must never reach the automatic preview/export or be sent back implicitly.
  delete config.wifi.password;
  delete config.device;
  return {
    provisioned: src.provisioned === true,
    passwordSet: wifi.passwordSet === true,
    secretSet: device.secretSet === true || legacy.deviceSecretSet === true ||
      typeof device.secret === "string" || typeof legacy.deviceSecret === "string",
    ...(typeof device.id === "string" ? { deviceId: device.id } : {}),
    ...(typeof device.secret === "string" && device.secret
      ? { storedDeviceSecret: device.secret }
      : typeof legacy.deviceSecret === "string" && legacy.deviceSecret
        ? { storedDeviceSecret: legacy.deviceSecret } : {}),
    config,
  };
}

export function payloadFor(config: DeviceConfig, keepStoredPassword: boolean): string {
  const out = { ...config, wifi: { ...config.wifi } };
  if (keepStoredPassword) delete out.wifi.password;
  return JSON.stringify(out);
}

// Only supported keys survive import. Legacy device credentials migrate, while
// organization adoption and static server authority fields are discarded.
export function mergeConfig(input: unknown): DeviceConfig {
  const base = defaultConfig();
  const src = object(input);
  if (src.schema !== undefined && src.schema !== CONFIG_SCHEMA) throw new Error("Unsupported configuration schema");
  const section = <T extends object>(key: string, fallback: T): T => {
    const values = object(src[key]);
    const result = { ...fallback };
    for (const field of Object.keys(fallback) as (keyof T)[]) {
      if (values[field as string] !== undefined) {
        const value = values[field as string];
        if (typeof value !== typeof fallback[field]) throw new Error(`Invalid ${key}.${String(field)}`);
        result[field] = value as T[keyof T];
      }
    }
    return result;
  };
  if (src.mode !== undefined && !OPERATING_MODES.includes(src.mode as OperatingMode)) throw new Error("Invalid operating mode");
  const result: DeviceConfig = {
    schema: CONFIG_SCHEMA,
    mode: (src.mode as OperatingMode | undefined) ?? base.mode,
    wifi: section("wifi", base.wifi),
    livekit: section("livekit", base.livekit),
    telemetry: section("telemetry", base.telemetry),
    audio: section("audio", base.audio),
    session: section("session", base.session),
  };
  const wifi = object(src.wifi);
  if (wifi.password !== undefined) {
    if (typeof wifi.password !== "string") throw new Error("Invalid wifi.password");
    result.wifi.password = wifi.password;
  }
  const device = object(src.device);
  const legacy = object(src.adoption);
  const secret = device.secret !== undefined ? device.secret : legacy.deviceSecret;
  if (secret !== undefined) {
    if (typeof secret !== "string") throw new Error("Invalid device.secret");
    result.device = { secret };
  }
  if (src.profiles !== undefined) {
    if (!Array.isArray(src.profiles)) throw new Error("profiles must be an array");
    // Preserve profiles verbatim; validation blocks malformed/unsupported fields.
    result.profiles = structuredClone(src.profiles) as DeviceProfile[];
  }
  if (src.activeProfile !== undefined) {
    if (typeof src.activeProfile !== "string") throw new Error("Invalid activeProfile");
    result.activeProfile = src.activeProfile;
  }
  return result;
}

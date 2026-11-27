import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript";

const configSource = readFileSync(new URL("../src/lib/config.ts", import.meta.url), "utf8");
const validateSource = readFileSync(new URL("../src/lib/validate.ts", import.meta.url), "utf8");
const moduleFrom = (source) => import(`data:text/javascript;base64,${Buffer.from(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText).toString("base64")}`);
const { defaultConfig, mergeConfig, parseDump, payloadFor, serialize, preview } = await moduleFrom(configSource);
const { validate, hasBlockingErrors } = await moduleFrom(validateSource);
const valid = () => ({ ...defaultConfig(), wifi: { ssid: "Home" }, livekit: { tokenServerUrl: "https://api.example.com/api/v2/device-voice-sessions", allowInsecureHttp: false } });

test("load/edit/send and import/export retain local profiles without copying stored credentials", () => {
  const profiles = [{ name: "agente", mode: "agent" }, { name: "usb", mode: "usb_mic", wifi: false, fixedBeam: false }];
  const dump = parseDump({ ...valid(), provisioned: true, wifi: { ssid: "Home", passwordSet: true }, device: { id: "aabbccddeeff", secret: "unit-private-key", secretSet: true }, profiles, activeProfile: "usb" });
  assert.equal(dump.passwordSet, true);
  assert.equal(dump.secretSet, true);
  assert.equal(dump.deviceId, "aabbccddeeff");
  assert.equal(dump.storedDeviceSecret, "unit-private-key");
  assert.equal(preview(dump.config).includes("unit-private-key"), false);
  assert.equal(serialize(dump.config).includes("unit-private-key"), false);
  assert.deepEqual(dump.config.profiles, profiles);
  assert.deepEqual(mergeConfig(JSON.parse(serialize(dump.config))).profiles, profiles);
  const payload = JSON.parse(payloadFor(dump.config, true));
  assert.deepEqual(payload.profiles, profiles);
  assert.equal(payload.activeProfile, "usb");
  assert.equal("password" in payload.wifi, false);
  assert.equal("device" in payload, false);
});

test("secret omission preserves, empty clears, legacy device secret imports without organization authority", () => {
  const cfg = mergeConfig({ ...valid(), adoption: { orgSecret: "organization-secret", deviceSecret: "unit-secret" }, livekit: { ...valid().livekit, room: "old", agentName: "old", deviceIdentity: "old" } });
  assert.deepEqual(cfg.device, { secret: "unit-secret" });
  assert.equal("adoption" in cfg, false);
  assert.deepEqual(Object.keys(cfg.livekit), ["tokenServerUrl", "allowInsecureHttp"]);
  assert.deepEqual(mergeConfig({ device: { secret: "" } }).device, { secret: "" });
  assert.equal("device" in mergeConfig({ adoption: { orgSecret: "old" } }), false);
  assert.equal("device" in parseDump({ adoption: { deviceSecret: "legacy" } }).config, false);
  assert.equal(preview(cfg).includes("unit-secret"), false);
  assert.equal(serialize(cfg).includes("unit-secret"), true);
});

test("complete session endpoint retains path and requires an explicit HTTP opt-in", () => {
  assert.equal(hasBlockingErrors(validate(valid())), false);
  for (const url of ["http://localhost:8787/device-voice-sessions", "ftp://host/path", "https://user:pass@host/path", "https://host/path#fragment", "https://host/path#", "https://host/" + "a".repeat(250), " https://host/path", "https://host/path\\x"]) {
    const cfg = valid(); cfg.livekit.tokenServerUrl = url;
    assert.equal(hasBlockingErrors(validate(cfg)), true, url);
  }
  const cfg = valid(); cfg.livekit.tokenServerUrl = "http://localhost:8787/device-voice-sessions"; cfg.livekit.allowInsecureHttp = true;
  assert.equal(hasBlockingErrors(validate(cfg)), false);
  assert.equal(JSON.parse(payloadFor(cfg, false)).livekit.tokenServerUrl, cfg.livekit.tokenServerUrl);
});

test("invalid profile, UTF-8 storage limits and unsafe credentials block sending", () => {
  for (const profiles of [[{ name: "dup" }, { name: "dup" }], [{ name: "🗣".repeat(8) }], [{ name: "usb", mode: "meeting" }], [null], [{ name: "usb", fixedBeam: "false" }]]) {
    const cfg = valid(); cfg.profiles = profiles;
    assert.equal(hasBlockingErrors(validate(cfg)), true);
  }
  for (const secret of ["has space", "line\nbreak", "a".repeat(1025)]) {
    const cfg = valid(); cfg.device = { secret };
    assert.equal(hasBlockingErrors(validate(cfg)), true);
  }
  assert.throws(() => mergeConfig({ livekit: { allowInsecureHttp: "false" } }));
});

test("owner issued device JWT accepts its 1024 byte boundary", () => {
  const cfg = valid(); cfg.device = { secret: "a".repeat(1024) };
  assert.equal(hasBlockingErrors(validate(cfg)), false);
});

test("the gpt_live profile mode validates; unknown modes still fail", () => {
  const ok = { ...valid(), profiles: [{ name: "agente", mode: "agent" }, { name: "gpt-live", mode: "gpt_live" }] };
  assert.equal(hasBlockingErrors(validate(ok)), false);
  const bad = { ...valid(), profiles: [{ name: "x", mode: "gpt-live" }] };
  assert.equal(hasBlockingErrors(validate(bad)), true);
});

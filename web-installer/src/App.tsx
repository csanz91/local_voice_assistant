import { useEffect, useMemo, useRef, useState } from "react";
import { defaultConfig, mergeConfig, preview, serialize, type DeviceConfig, type DeviceDump } from "./lib/config";
import { hasBlockingErrors, validate, type FieldIssue } from "./lib/validate";
import { HOLD_AFTER_LOAD_MS, linkAgeMs, linkOpen, loadConfig, sendConfig } from "./lib/serial";
import { ConfigForm } from "./components/ConfigForm";
import { Btn, Card, Eyebrow, SectionTitle, cx } from "./components/ui";
import { Bolt, Check, Chevron, Copy, Download, Upload, Wifi } from "./components/icons";

type Tone = "" | "ok" | "warn";
const BASE = import.meta.env.BASE_URL;

export default function App() {
  const [config, setConfig] = useState<DeviceConfig>(defaultConfig);
  const [formRevision, setFormRevision] = useState(0);
  const [pairing, setPairing] = useState<Pick<DeviceDump, "deviceId" | "storedDeviceSecret"> | null>(null);
  const [pairingRevealed, setPairingRevealed] = useState(false);
  const [pairingMsg, setPairingMsg] = useState("");
  const [sendMsg, setSendMsg] = useState("With the board flashed and connected via USB, click send and choose the port.");
  const [sendTone, setSendTone] = useState<Tone>("");
  const [sending, setSending] = useState(false);
  const [loading, setLoading] = useState(false);
  // Set by "load from device": the board has a WiFi password we never see. It is
  // kept (key omitted from the payload) until the operator explicitly edits it.
  const [storedPassword, setStoredPassword] = useState<"keep" | "edit" | undefined>();
  const [holdLeft, setHoldLeft] = useState<number | null>(null);
  const [sourceMsg, setSourceMsg] = useState("Checking published firmware…");
  const [installReady, setInstallReady] = useState(false);
  const [firmwareVersion, setFirmwareVersion] = useState<string | null>(null);
  const [log, setLog] = useState<string[]>([]);
  const fileRef = useRef<HTMLInputElement>(null);
  const issues = useMemo<FieldIssue[]>(() => validate(config), [config]);
  const [profilesInvalid, setProfilesInvalid] = useState(false);
  const blocked = profilesInvalid || hasBlockingErrors(issues);

  useEffect(() => {
    // Are the sparse firmware parts available next to the page? ESP Web Tools
    // has nothing to flash — say so instead of a dead button.
    (async () => {
      try {
        const res = await fetch(`${BASE}manifest.json`, { cache: "no-store" });
        if (!res.ok) throw new Error();
        const manifest = await res.json();
        const parts = manifest?.builds?.[0]?.parts;
        const offsets = [0, 0x8000, 0x10000];
        if (!Array.isArray(parts) || parts.length !== 3 ||
            parts.some((part, i) => part.offset !== offsets[i] || typeof part.path !== "string")) throw new Error("invalid-sparse-manifest");
        setFirmwareVersion(typeof manifest?.version === "string" ? manifest.version : null);
        // Validate it's a REAL ESP image, not an SPA-fallback index.html. A dev
        // server returns HTML (200) for a missing .bin; ESP Web Tools would then
        // flash that HTML over the bootloader and brick the chip. Require the
        // ESP32 image magic byte 0xE9 (HTML starts with '<' = 0x3C).
        for (const part of parts) {
          const bin = await fetch(new URL(part.path, res.url), {
            cache: "no-store", headers: { Range: "bytes=0-3" },
          });
          const ct = bin.headers.get("content-type") ?? "";
          if (!bin.ok || ct.includes("text/html")) throw new Error("html-fallback");
          const bytes = new Uint8Array(await bin.arrayBuffer());
          const valid = part.offset === 0x8000
            ? bytes[0] === 0xaa && bytes[1] === 0x50
            : bytes[0] === 0xe9;
          if (!valid) throw new Error("invalid-firmware-part");
        }
        setInstallReady(true);
        setSourceMsg("Firmware parts ready. Leave Erase device unchecked to preserve settings.");
      } catch {
        setInstallReady(false);
        setSourceMsg("No valid firmware image published. Provision an already flashed board (step 3), or package the firmware parts first (Advanced).");
      }
    })();
  }, []);

  // Countdown of the firmware's held window while the port stays open after a load.
  useEffect(() => {
    if (holdLeft === null) return;
    const id = setInterval(() => {
      if (!linkOpen()) {
        setHoldLeft(null);
        return;
      }
      const left = Math.max(0, Math.round((HOLD_AFTER_LOAD_MS - linkAgeMs()) / 1000));
      setHoldLeft(left);
      if (left === 0) {
        setSendTone("warn");
        setSendMsg("La placa ha cerrado el puerto. Desenchufa y enchufa el USB y vuelve a cargar o enviar.");
      }
    }, 1000);
    return () => clearInterval(id);
  }, [holdLeft]);

  async function load() {
    setLoading(true);
    setPairing(null);
    setPairingRevealed(false);
    setPairingMsg("");
    setSendTone("");
    setSendMsg("Leyendo la config guardada en la placa…");
    setLog([]);
    const result = await loadConfig((line) => setLog((prev) => [...prev, line]));
    setLoading(false);
    switch (result.status) {
      case "ok": {
        const { dump } = result;
        setConfig(dump.config);
        setPairing({ deviceId: dump.deviceId, storedDeviceSecret: dump.storedDeviceSecret });
        setFormRevision((value) => value + 1);
        setProfilesInvalid(false);
        setStoredPassword(dump.passwordSet ? "keep" : undefined);
        setHoldLeft(Math.round(HOLD_AFTER_LOAD_MS / 1000));
        setSendTone("ok");
        setSendMsg(
          dump.provisioned
            ? `✓ Config cargada de la placa (SSID "${dump.config.wifi.ssid}"). Edita lo que quieras y envía: el puerto sigue abierto.`
            : "✓ La placa contestó pero aún no está provisionada: rellena el formulario y envía.",
        );
        break;
      }
      case "no-reply":
        setSendTone("warn");
        setSendMsg("La placa no contesta. ¿Lleva más de 5 s enchufada? Desenchufa, enchufa y pulsa cargar en cuanto aparezca el puerto.");
        break;
      case "unsupported":
        setSendTone("warn");
        setSendMsg("This browser does not support Web Serial. Use Chrome, Edge, Opera, or Brave.");
        break;
      case "cancelled":
        setSendTone("");
        setSendMsg("Carga cancelada.");
        break;
      default:
        setSendTone("warn");
        setSendMsg(`No se pudo cargar: ${result.message}`);
    }
  }

  function importJson(file: File | undefined) {
    if (!file) return;
    file
      .text()
      .then((text) => {
        setConfig(mergeConfig(JSON.parse(text)));
        setPairing(null);
        setPairingRevealed(false);
        setPairingMsg("");
        setFormRevision((value) => value + 1);
        setProfilesInvalid(false);
        setStoredPassword(undefined);
        setSendTone("ok");
        setSendMsg(`Config importada desde ${file.name}.`);
      })
      .catch((e) => {
        setSendTone("warn");
        setSendMsg(`No se pudo leer el JSON: ${e instanceof Error ? e.message : e}`);
      });
  }

  function downloadJson() {
    const blob = new Blob([serialize(config), "\n"], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "sebastian-config.json";
    a.click();
    URL.revokeObjectURL(url);
  }

  async function copyJson() {
    await navigator.clipboard.writeText(serialize(config));
    setSendTone("ok");
    setSendMsg("Config copied to clipboard.");
  }

  async function copyPairing() {
    if (!pairing?.deviceId || !pairing.storedDeviceSecret) return;
    try {
      await navigator.clipboard.writeText(JSON.stringify({
        deviceId: pairing.deviceId, deviceSecret: pairing.storedDeviceSecret,
      }, null, 2));
      setPairingMsg("Pairing credentials copied. Register them with your backend and clear the clipboard afterward.");
    } catch {
      setPairingMsg("Clipboard access failed. Reveal the credential to copy it manually.");
    }
  }

  async function send() {
    if (blocked) {
      setSendTone("warn");
      setSendMsg("Correct the marked fields before sending.");
      return;
    }
    setSending(true);
    setSendTone("");
    setSendMsg("Sending and waiting for board reply…");
    setLog([]);
    const result = await sendConfig(config, storedPassword === "keep", (line) => setLog((prev) => [...prev, line]));
    setSending(false);
    setHoldLeft(null);
    switch (result.status) {
      case "ok":
        setSendTone("ok");
        setSendMsg("✓ Config accepted. The board will restart and connect.");
        setPairing(null);
        setPairingRevealed(false);
        setPairingMsg("");
        setStoredPassword(undefined);
        break;
      case "rejected":
        setSendTone("warn");
        setSendMsg(`La placa rechazó la config: ${result.reason}.`);
        break;
      case "no-reply":
        setSendTone("warn");
        setSendMsg("Sent, but no reply from the board. Has it finished booting? Retry.");
        break;
      case "unsupported":
        setSendTone("warn");
        setSendMsg("This browser does not support Web Serial. Use Chrome, Edge, Opera, or Brave.");
        break;
      case "cancelled":
        setSendTone("");
        setSendMsg("Send cancelled.");
        break;
      default:
        setSendTone("warn");
        setSendMsg(`No se pudo enviar: ${result.message}`);
    }
  }

  const toneCls = (t: Tone) => (t === "ok" ? "text-ok" : t === "warn" ? "text-warn" : "text-fg-muted");

  return (
    <div className="mx-auto w-[min(1120px,calc(100%-32px))] pb-20">
      <JsonToolbar
        onImport={() => fileRef.current?.click()}
        onDownload={downloadJson}
        onCopy={copyJson}
      />
      <input
        ref={fileRef}
        type="file"
        accept=".json,application/json"
        className="hidden"
        onChange={(e) => {
          importJson(e.target.files?.[0]);
          e.target.value = "";
        }}
      />

      <main className="grid gap-5">
        {/* Hero + install (step 1) */}
        <Card className="grid items-center gap-8 p-8 md:grid-cols-[1.15fr_0.85fr]">
          <div className="grid gap-5">
            <Eyebrow>ReSpeaker XVF3800 + XIAO ESP32-S3</Eyebrow>
            <h1 className="font-serif text-[clamp(34px,5vw,52px)] font-medium leading-[1.03] text-fg">
              Install Sebastian from your browser
            </h1>
            <p className="max-w-xl text-[17px] leading-relaxed text-fg-muted">
              Connect via USB in Chrome, Edge, Opera, or Brave and follow three steps. The binary
              does not contain credentials: the config is injected via Web&nbsp;Serial.
            </p>
            <div className="mt-1 grid justify-items-start gap-3">
              {/* @ts-expect-error web component */}
              <esp-web-install-button manifest={`${BASE}manifest.json`}>
                <button
                  slot="activate"
                  disabled={!installReady}
                  className="inline-flex items-center gap-2.5 rounded-xl border border-brand/50 bg-gradient-to-br from-brand-deep via-brand-strong to-brand px-5 py-3 text-[15px] font-bold text-[#1c1204] shadow-[0_14px_34px_-12px_var(--color-brand)] transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-45"
                >
                  <span className="grid size-6 place-items-center rounded-full bg-black/20 text-xs">1</span>
                  Connect and install
                </button>
                <span slot="unsupported" className="text-sm font-semibold text-danger">
                  Browser without Web Serial. Use desktop Chromium.
                </span>
                <span slot="not-allowed" className="text-sm font-semibold text-danger">
                  Web Serial requires HTTPS or localhost. To use it on this address, open{" "}
                  <code>chrome://flags/#unsafely-treat-insecure-origin-as-secure</code>, add{" "}
                  <code>{typeof window === "undefined" ? "" : window.location.origin}</code> and relaunch Chrome.
                </span>
                {/* @ts-expect-error web component */}
              </esp-web-install-button>
              <p className={cx("text-sm", toneCls(installReady ? "" : "warn"))}>
                {sourceMsg}
                {installReady && firmwareVersion && (
                  <>
                    {" "}
                    <span className="font-mono text-fg-muted">Firmware {firmwareVersion}</span>
                  </>
                )}
              </p>
              <p className="text-sm text-fg-muted">
                Is the board already flashed? Skip this step and go directly to{" "}
                <a href="#enviar" className="font-semibold text-brand hover:underline">
                  Send via serial
                </a>{" "}
                (paso 3).
              </p>
            </div>
          </div>
          <DeviceVisual />
        </Card>

        {/* Configure (step 2) */}
        <Card className="p-7 md:p-8">
          <SectionTitle
            step={2}
            eyebrow="Provisioning"
            title="Configure the unit"
            hint={
              <>
                Pick a mode, configure your full session endpoint, then provision the board.
                Local profiles can override the audio settings at boot.
              </>
            }
          />
          <ConfigForm
            key={formRevision}
            config={config}
            onChange={setConfig}
            issues={issues}
            onProfilesInvalid={setProfilesInvalid}
            storedPassword={storedPassword}
            onStoredPassword={setStoredPassword}
          />

          {pairing && (pairing.deviceId || pairing.storedDeviceSecret) && (
            <section className="mt-7 rounded-xl border border-line bg-black/20 p-4" aria-label="Private backend pairing">
              <h3 className="font-semibold text-fg">Pair this device with your backend</h3>
              <p className="mt-2 text-sm text-fg-muted">Read over the physical USB connection. Keep the credential private: it authenticates this device to your backend. It stays separate from configuration previews and exports.</p>
              <p className="mt-3 text-sm text-fg-soft">Hardware device ID: <code className="select-all">{pairing.deviceId ?? "Unavailable with this firmware"}</code></p>
              {pairing.storedDeviceSecret && <>
                <div className="mt-3 flex flex-wrap items-center gap-3">
                  <Btn onClick={() => setPairingRevealed((shown) => !shown)}>{pairingRevealed ? "Hide credential" : "Reveal pairing credential"}</Btn>
                  <Btn onClick={copyPairing} disabled={!pairing.deviceId}><Copy className="size-4" />Copy pairing credentials</Btn>
                </div>
                {pairingRevealed && <p className="mt-3 break-all rounded-lg border border-line p-3 font-mono text-sm text-fg-soft select-all">{pairing.storedDeviceSecret}</p>}
              </>}
              {!pairing.storedDeviceSecret && <p className="mt-3 text-sm text-fg-muted">No credential was returned. Provision a known per-device credential, restart and load again.</p>}
              {pairingMsg && <p role="status" className="mt-3 text-sm text-fg-muted">{pairingMsg}</p>}
            </section>
          )}

          <details className="group mt-7 rounded-xl border border-line bg-black/20">
            <summary className="flex cursor-pointer list-none items-center gap-2 px-4 py-3 text-sm font-semibold text-fg-soft">
              <Chevron className="size-4 transition group-open:rotate-180" />
              View config (credentials redacted)
            </summary>
            <pre className="max-h-72 overflow-auto border-t border-line px-4 py-3 font-mono text-[12.5px] leading-relaxed text-[#f4c78f]">
              {preview(config)}
            </pre>
          </details>
        </Card>

        {/* Send (step 3) */}
        <Card id="enviar" className="scroll-mt-24 p-7 md:p-8">
          <SectionTitle
            step={3}
            eyebrow="Provisioning"
            title="Send the config to the board"
            hint="No flashing required: it talks to the firmware already running. Load first to edit what the board already has (WiFi, session endpoint…) instead of retyping it."
          />
          <div className="mt-6 flex flex-wrap items-center gap-4">
            <Btn onClick={load} disabled={loading || sending} className="px-5 py-3 text-[15px]">
              {loading ? (
                <span className="size-4 animate-[spin-ring_0.8s_linear_infinite] rounded-full border-2 border-white/30 border-t-white/70" />
              ) : (
                <Download className="size-4" />
              )}
              Load from device
            </Btn>
            <Btn variant="primary" onClick={send} disabled={sending || loading} className="px-5 py-3 text-[15px]">
              {sending ? (
                <span className="size-4 animate-[spin-ring_0.8s_linear_infinite] rounded-full border-2 border-black/30 border-t-black/70" />
              ) : (
                <Bolt className="size-4" />
              )}
              Send via serial
            </Btn>
            <p className={cx("flex items-center gap-2 text-sm", toneCls(sendTone))}>
              {sendTone === "ok" && <Check className="size-4" />}
              {sendMsg}
              {holdLeft !== null && holdLeft > 0 && (
                <span className="rounded-full border border-line px-2 py-0.5 font-mono text-[11px] text-fg-muted">
                  puerto abierto {holdLeft}s
                </span>
              )}
            </p>
          </div>
          {log.length > 0 && (
            <pre className="mt-5 max-h-56 overflow-auto rounded-xl border border-line bg-black/40 px-4 py-3 font-mono text-[12.5px] leading-relaxed text-fg-soft">
              {log.join("\n")}
            </pre>
          )}
        </Card>

        <Advanced installReady={installReady} />
        <Notes />
      </main>
    </div>
  );
}

function JsonToolbar({
  onImport,
  onDownload,
  onCopy,
}: {
  onImport: () => void;
  onDownload: () => void;
  onCopy: () => void;
}) {
  return (
    <header className="sticky top-0 z-20 -mx-4 mb-5 flex items-center gap-3 px-4 py-3 backdrop-blur-md">
      <div className="pointer-events-none absolute inset-0 -z-10 border-b border-line bg-ink/70" />
      <a href="./" className="flex items-center gap-2.5 text-fg" aria-label="Firmware installer">
        <Bolt className="size-7 text-brand" />
        <span className="hidden text-sm font-semibold tracking-tight text-fg-soft sm:block">
          Sebastian Installer
        </span>
      </a>
      <div className="ml-auto flex items-center gap-1.5 rounded-xl border border-line bg-white/[0.03] p-1">
        <ToolbarBtn onClick={onImport} icon={<Upload className="size-4" />} label="Import" />
        <ToolbarBtn onClick={onDownload} icon={<Download className="size-4" />} label="Download" />
        <ToolbarBtn onClick={onCopy} icon={<Copy className="size-4" />} label="Copy" />
      </div>

    </header>
  );
}

function ToolbarBtn({ onClick, icon, label }: { onClick: () => void; icon: React.ReactNode; label: string }) {
  return (
    <button
      onClick={onClick}
      className="inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-[13px] font-semibold text-fg-soft transition hover:bg-white/[0.07] hover:text-fg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/30"
    >
      {icon}
      <span className="hidden sm:inline">{label}</span>
    </button>
  );
}

function DeviceVisual() {
  const tags = ["ESP32-S3", "Web Serial", "Provisioning"];

  return (
    <aside className="hidden md:grid gap-4">
      <div className="relative grid aspect-[4/3] place-items-center overflow-hidden rounded-2xl border border-line bg-gradient-to-br from-white/[0.07] via-white/[0.025] to-brand/[0.08]">
        <div className="absolute inset-x-8 top-7 h-px bg-gradient-to-r from-transparent via-brand/45 to-transparent" />
        <div className="absolute inset-x-8 bottom-7 h-px bg-gradient-to-r from-transparent via-brand/35 to-transparent" />
        <span className="font-mono text-3xl text-brand">ESP32-S3</span>
      </div>
      <div className="flex flex-wrap gap-2">
        {tags.map((tag) => (
          <span
            key={tag}
            className="rounded-full border border-line bg-white/[0.035] px-3 py-1.5 font-mono text-[11px] font-semibold text-fg-muted"
          >
            {tag}
          </span>
        ))}
      </div>
    </aside>
  );
}

function Advanced({ installReady }: { installReady: boolean }) {
  return (
    <details
      className="group overflow-hidden rounded-[var(--radius-xl)] border border-line bg-gradient-to-b from-white/[0.055] to-white/[0.015] shadow-[0_28px_90px_-30px_rgba(0,0,0,0.75)]"
      open={!installReady}
    >
      <summary className="flex cursor-pointer list-none items-center gap-3 p-6">
        <Wifi className="size-5 text-brand" />
        <div>
          <Eyebrow>Advanced</Eyebrow>
          <h2 className="font-serif text-xl text-fg">Firmware source</h2>
        </div>
        <Chevron className="ml-auto size-5 text-fg-muted transition group-open:rotate-180" />
      </summary>
      <div className="border-t border-line px-6 pb-6 pt-5 text-sm text-fg-muted">
        <p>
          Package bootloader, partition table, app and matching manifest in <code className="text-fg-soft">firmware/ next to this page</code>.
        </p>
      </div>
    </details>
  );
}

function Notes() {
  const items = [
    "The firmware is a factory image: WiFi and the full session endpoint live in NVS, not in the binary. They are injected via Web Serial in step 3.",
    "The board only listens on USB during the first 5 s after power-up (then the USB becomes the microphone interface). Plug it in and click within that window; after a reset or a crash, re-plug it.",
    "Load from device asks the firmware for the stored config (sebastian.config.get) and keeps the port open for 2 minutes so you can edit and send on the same connection. The WiFi password is never returned. A separate private pairing panel lets you explicitly reveal or copy the device credential read over USB.",
    "When accepting the config, the firmware responds sebastian.config.ok and restarts itself to connect.",
    "The installer uses separate bootloader, partition table and app parts. Leave Erase device unchecked to preserve WiFi, credentials and profiles.",
    "If the serial connection fails, close any open monitor/bridge/esptool and retry.",
  ];
  return (
    <Card className="p-7">
      <Eyebrow>How it works</Eyebrow>
      <h2 className="mt-1 font-serif text-2xl text-fg">The binary carries no credentials</h2>
      <ul className="mt-4 grid gap-2.5">
        {items.map((t) => (
          <li key={t} className="flex gap-3 text-[15px] leading-relaxed text-fg-muted">
            <Check className="mt-1 size-4 shrink-0 text-brand" />
            {t}
          </li>
        ))}
      </ul>
    </Card>
  );
}

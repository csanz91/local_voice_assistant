# /// script
# requires-python = ">=3.11"
# dependencies = ["pyserial>=3.5"]
# ///
"""Provisiona el device por serial con un JSON sebastian.config.v1.

Corre en el HOST (Docker en macOS no ve el USB), igual que tools/flash.sh:

    uv run tools/provision_device.py tools/provisioning/full_duplex.json [puerto]

Envía la línea de provisioning, espera el ack, y muestra el arranque posterior
(fixed_beam aplicado, WiFi, detección activa) para verificar el modo. Las
claves ausentes del JSON conservan su valor en NVS — en particular el password
WiFi y el secreto del dispositivo. Los JSON con credenciales son archivos
locales: no deben subirse a git. La URL conserva su ruta completa; HTTP requiere
livekit.allowInsecureHttp=true de forma explícita.
"""

import glob
import json
import sys
import time
from urllib.parse import urlsplit


PROFILE_JSON_CAPACITY = 1024  # includes NUL; shared C loader bound in profiles.h
VERIFY_SECONDS = 30
INTERESTING = (
    "fixed_beam",
    "AEC config",
    "Connected:",
    "detection active",
)


def find_port() -> str:
    for pattern in ("/dev/cu.usbmodem*", "/dev/ttyACM*", "/dev/ttyUSB*"):
        ports = sorted(glob.glob(pattern))
        if ports:
            return ports[0]
    sys.exit("Sin puerto serie (cu.usbmodem*/ttyACM*/ttyUSB*) — ¿está enchufado el device? (esto corre en el HOST, no en el devcontainer)")


def prepare_config(cfg: object) -> dict:
    """Validate session/credential fields without printing sensitive values."""
    if not isinstance(cfg, dict) or cfg.get("schema") != "sebastian.config.v1":
        raise ValueError("el JSON debe llevar schema=sebastian.config.v1")
    cfg = {k: v for k, v in cfg.items() if k in {
        "schema", "mode", "wifi", "livekit", "telemetry", "audio", "session",
        "device", "adoption", "profiles", "activeProfile",
    }}
    if "mode" in cfg and cfg["mode"] not in ("full_duplex", "half_duplex"):
        raise ValueError("mode inválido")
    legacy = cfg.pop("adoption", None)
    device = cfg.get("device", {})
    if not isinstance(device, dict):
        raise ValueError("device debe ser un objeto")
    device = {k: v for k, v in device.items() if k == "secret"}
    if "secret" not in device and isinstance(legacy, dict) and "deviceSecret" in legacy:
        device["secret"] = legacy["deviceSecret"]
    if "secret" in device:
        secret = device["secret"]
        if not isinstance(secret, str) or len(secret) > 1024 or any(not 33 <= ord(c) <= 126 for c in secret):
            raise ValueError("device.secret debe usar hasta 1024 caracteres ASCII imprimibles sin espacios; vacío borra")
        cfg["device"] = device
    else:
        cfg.pop("device", None)
    lk = cfg.get("livekit", {})
    if not isinstance(lk, dict):
        raise ValueError("livekit debe ser un objeto")
    lk = {k: v for k, v in lk.items() if k in ("tokenServerUrl", "allowInsecureHttp")}
    if "allowInsecureHttp" in lk and not isinstance(lk["allowInsecureHttp"], bool):
        raise ValueError("allowInsecureHttp debe ser booleano")
    endpoint = lk.get("tokenServerUrl", "")
    if not isinstance(endpoint, str):
        raise ValueError("tokenServerUrl debe ser una URL completa")
    if endpoint:
        try:
            url = urlsplit(endpoint)
            _ = url.port
            valid = (len(endpoint.encode()) <= 255 and endpoint.startswith(("https://", "http://")) and
                     url.hostname and not url.username and not url.password and "#" not in endpoint and
                     not any(c.isspace() or ord(c) < 32 or ord(c) == 127 or c == "\\" for c in endpoint) and
                     (url.scheme == "https" or (url.scheme == "http" and lk.get("allowInsecureHttp") is True)))
        except ValueError:
            valid = False
        if not valid:
            raise ValueError("URL de sesión inválida: HTTPS completo sin credenciales/fragmento, máximo 255 bytes; HTTP requiere opt-in explícito")
    if "livekit" in cfg:
        cfg["livekit"] = lk
    for section, fields in {
        "wifi": ("ssid", "password"),
        "telemetry": ("syslogIp", "syslogPort"),
        "audio": ("fullDuplex", "fixedBeam", "fixedBeamAzimuthDeg"),
        "session": ("silenceTimeoutMs", "voiceLevel"),
    }.items():
        if section in cfg:
            if not isinstance(cfg[section], dict):
                raise ValueError(f"{section} debe ser un objeto")
            cfg[section] = {k: v for k, v in cfg[section].items() if k in fields}
    if "profiles" in cfg:
        profiles = cfg["profiles"]
        if not isinstance(profiles, list):
            raise ValueError("profiles debe ser un array")
        compact = json.dumps(profiles, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        if len(compact.encode("utf-8")) >= PROFILE_JSON_CAPACITY:
            raise ValueError("profiles JSON supera 1023 bytes UTF-8")
    if len(("sebastian.config.v1 " + json.dumps(cfg) + "\n").encode()) > 8191:
        raise ValueError("el comando de provisioning supera 8191 bytes")
    return cfg


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(f"uso: {sys.argv[0]} <config.json> [puerto]")
    import serial

    try:
        with open(sys.argv[1], encoding="utf-8") as config_file:
            cfg = prepare_config(json.load(config_file))
    except (OSError, ValueError):
        sys.exit("Configuración inválida: revise el schema, URL completa HTTPS, opt-in HTTP y formato del secreto (no se imprime el archivo).")
    port = sys.argv[2] if len(sys.argv) > 2 else find_port()

    line = "sebastian.config.v1 " + json.dumps(cfg) + "\n"
    ser = serial.Serial(port, 115200, timeout=1)
    ser.reset_input_buffer()
    ser.write(line.encode())
    ser.flush()
    print(f">>> {port}: mode={cfg.get('mode', '?')}")

    acked = False
    deadline = time.time() + VERIFY_SECONDS
    buf = b""
    while time.time() < deadline:
        buf += ser.read(4096)
        text = buf.decode("utf-8", errors="replace")
        if "sebastian.config.err" in text:
            ser.close()
            sys.exit("el device rechazó la config (no se imprime la respuesta para proteger credenciales)")
        if not acked and "sebastian.config.ok" in text:
            acked = True
            print("<<< sebastian.config.ok — reiniciando para aplicar")
    ser.close()

    for ln in buf.decode("utf-8", errors="replace").splitlines():
        if "sebastian.config" not in ln and not any(k in ln.lower() for k in ("secret", "password", "token")) and any(k in ln for k in INTERESTING):
            print(f"    {ln.strip()}")
    if not acked:
        sys.exit("sin ack del device — ¿algo más está leyendo el serial (bridge/monitor)?")
    print("[provision] OK")


if __name__ == "__main__":
    main()

# Optional serial telemetry

`uv run tools/telemetry/bridge.py` reads a serial port and exports logs/metrics
through OTLP to a receiver you supply. Set `SEBASTIAN_SERIAL_PORT` or
`SEBASTIAN_SERIAL_URL` for your identified device, and
`OTEL_EXPORTER_OTLP_ENDPOINT` for your receiver (see the script for defaults).
No collector, Grafana, Loki or backend starts with this firmware project.

Serial is available only in the provisioning boot window before TinyUSB claims
the PHY. For runtime logs, provision `telemetry.syslogIp` (IPv4) and `syslogPort`
for an existing UDP syslog receiver; leave the IP blank to disable the sink.
Logs never include device secrets/session tokens. Avoid exporting private USB
configuration dumps, which deliberately contain the credential for pairing.

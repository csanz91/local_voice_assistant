# Firmware devcontainer

The devcontainer contains ESP-IDF **5.4.4** only. CMake downloads the SHA256-pinned
Xtensa Zig fork on the first build. No backend, database, dashboard, broker or
agent starts with the container.

Open the repository in VS Code's devcontainer and run `make fw-build`,
`make fw-test fw-fmt http-test protocol-test`. Node/npm on the host builds the
standalone installer. `make fw-build-docker` offers the same pinned build without
starting an interactive devcontainer.

On macOS, USB belongs to the host: use `PORT=<identified-port> make flash`
and host-side provisioning. Linux users may explicitly map their identified
board into the container. The default compose configuration mounts no USB device.
Optional serial telemetry remains in `tools/telemetry/`; configure your own OTLP
receiver. See [BUILD_AND_RUN](BUILD_AND_RUN.md) for provisioning and TLS policy.

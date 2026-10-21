# Phase 1 extraction validation

Recorded 2026-10-20 against baseline `5104b32`, with changes left in the working
tree for independent review. No commits, publishing, production service changes
or board flashing were performed. IoTCloud files were not edited.

## Implementation scope

Retained board/XVF/codec audio, AEC fallback, local Okay Nabu, pre-roll/SBPR,
USB capture/arbitration, persistent profiles, physical mute/LEDs, boot recovery,
watchdogs, coredump and optional syslog/serial diagnostics. The creator's backend,
agent, dashboard, deployment stack, fleet/adoption/polling and meeting runtime
were removed after extracting the protocol reference and fixtures.

Session requests now use the entire stored URL, device MAC ID/secret, public CA
bundle validation, redirect refusal and bounded complete-response parsing.
HTTP/WS require explicit local development opt-in. Device identity initialization
runs before board/audio/WiFi startup in either profile. The first secret uses
`bootloader_random_enable`/`esp_fill_random`/`bootloader_random_disable`, so offline
USB profiles do not generate credentials from an unseeded RF-disabled RNG.
The NVS keys `token_url`/`dev_secret`, WiFi/audio/profiles are retained. Old
organization/binding keys are unused; no factory erase is needed to migrate.
Physical USB readback exposes ID and an explicitly revealed/copied secret for
later backend registration. Config previews and logs redact credentials.

## Automated results

| Command / check | Result |
| --- | --- |
| `docker pull espressif/idf:v5.4.4` | Passed; image digest `sha256:9ce51d4ace496845678065dc86f8e55fb9c25fc9f01f45597042afa7ed546926`. |
| `make fw-build-docker` | Passed full ESP-IDF compile/link after extraction. |
| `docker run --rm -v "$PWD:/workspace" -w /workspace/firmware espressif/idf:v5.4.4 bash -c 'idf.py reconfigure && idf.py build'` | Initial firmware passed; the final `make fw-build-docker` also passed after the independent review corrections below. App `0x376d40` = 3,632,448 bytes; 4 MiB factory slot has 13% free. |
| `make check fw-fmt` | Passed: 68 Zig tests, 16 Python protocol tests, 3 CLI provisioning tests, production C HTTP and USB-provisioning fixtures, and Zig formatting. |
| `npm --prefix web-installer ci --cache /private/tmp/sebastian-installer-npm-cache` | Passed with the existing npm lock, without dependency upgrades. |
| `npm --prefix web-installer test` | Passed all 4 tests: profile/credential preservation, legacy import, full endpoint/HTTP opt-in, malformed/UTF-8 bounds. |
| `npm --prefix web-installer run build` | Passed TypeScript and Vite production build after final sparse packaging/UI changes. |
| `tools/prepare_web_installer.sh phase1-local-validation` | Passed; copied sparse firmware parts and generated installer manifest. No flash/publish. |
| `python3 -m compileall -q tools/protocol tools/provision_device.py` | Passed. |
| `bash -n tools/*.sh` | Passed. |
| `docker compose -f .devcontainer/docker-compose.yml config --quiet` | Passed; firmware-only container. |
| `git diff --check` | Passed. |

The full build used the SHA256-pinned AArch64 Linux Zig fork from
`0.16.0-xtensa`, LiveKit 0.3.10, and ESP-IDF 5.4.4. The initial manifest change
caused the resolver to propose unrelated `dl_fft`/camera upgrades; these were
reverted and final configure/build used baseline 0.7.0/2.1.7. The final lock
retains `path: ../components/livekit`; other remaining dependency versions are
unchanged. The publisher-only data-channel SDK patch is unchanged and documented
in `firmware/components/livekit/LOCAL_PATCHES.md`.

Embedded asset checks against Git baseline passed:

- XVF master 1.0.7 SHA256: `d1132b7e779818923072396315304a5dd2324aa56969b4111b30678f968a7c6a`.
- Both Okay Nabu copies SHA256: `0689abe1912a95a3318a0d8cb2e67bad0cbcfe3e24dd6e050c75debddfb6f891`.

### HTTP and trust-policy coverage

`tools/test_session_http.sh` compiles the actual production `session_http.c`
against ESP-IDF 5.4.4 cJSON and deterministic host HTTP stubs. It verifies exact
path/query preservation, authentication headers, exact `Content-Type: application/json`
and `{}` body bytes, partial request-write failure, certificate bundle callback,
redirect-disabled client config, 201 parsing, 301/302/307/308 refusal,
401/403/409/429/503 handling, transport failure with no fallback, HTTP/WS opt-in,
invalid URLs/tokens, embedded NUL, malformed/trailing/truncated data, oversize
responses, complete 1,535-byte boundary response and output-size limits.

These are firmware parser/configuration checks with a stubbed transport. They do
not demonstrate a real ESP32 HTTPS/WSS connection or certificate rejection.
The final generated sdkconfig enables the full root certificate bundle and keeps
`CONFIG_ESP_TLS_INSECURE` disabled. Its factory WiFi settings are blank.

### Installer NVS preservation evidence

The inherited merged image wrote the address gap containing NVS. Packaging now
uses separate parts at 0, 0x8000 and 0x10000, checked against the actual partition
table. Rounded flash-sector write ranges for the final artifacts are:

| Part | Sector range (end exclusive) |
| --- | --- |
| Bootloader (22,368 bytes) | `[0x0, 0x6000)` |
| Partition table (3,072 bytes) | `[0x8000, 0x9000)` |
| Application (3,632,448 bytes) | `[0x10000, 0x387000)` |

None overlaps NVS `[0x9000, 0xf000)` or phy_init `[0xf000, 0x10000)`.
The part headers were checked (`e9` bootloader/app, `aa 50` partition table), and
the UI checks all three before enabling installation.

Installed, lock-pinned ESP Web Tools **10.2.1** source provides the erase-policy
evidence: `web-installer/node_modules/esp-web-tools/dist/install-dialog.js`,
`_renderDashboardNoImprov` lines 263-270, calls `_startInstall(true)` when
`new_install_prompt_erase` is false. `_renderAskErase` lines 464-488 creates an
unchecked `ew-checkbox` and passes `checkbox.checked` to `_startInstall`.
`dist/flash.js` lines 114 and 143 explicitly erases only when requested and
otherwise writes sparse parts with `eraseAll: false`. Therefore the manifest
keeps the erase prompt **true**, and instructions say to leave **Erase device
unchecked** when preserving settings. Physical flash/NVS persistence still
requires board verification.

## Actual disposable network validation

The harness delegate ran a separate loopback LiveKit server **1.13.6** on isolated
ports 17880/17881/17882, using pinned Python RTC **1.1.12** / API **1.1.1**.
The peer/fixture/simulated-device commands are in [PROTOCOL](PROTOCOL.md).
Two real HTTP/WS/media/data scenarios passed:

- Authenticated HTTP 201 session, 3,200-byte SBPR pre-roll with effective
  full-duplex, ordered microphone media, then listening → thinking → speaking →
  barge → interrupted → listening → close. The peer counted 326,400 ordered
  live bytes without saving microphone audio.
- No pre-roll: six-second buffered-live fallback, unknown duplex, complete test
  tone and explicit close.

Only temporary test rooms/processes/credentials were used. Temporary processes
and token files were removed. Existing Aurelia/IoTCloud containers were untouched.
This tests development tooling and Python wire compatibility, not the ESP32 C SDK.

## Outstanding physical acceptance

No identified board was available for these checks. Boot/XVF/audio/AEC,
wake/mute/LEDs, profile selection/safe boot, USB enumeration/capture and ownership
handoff, real HTTPS/WSS trust failures, session interruption/teardown and repeated
conversations remain unverified on hardware. The earlier source's maximum-volume
XVF reliability issue remains an acoustic concern until measured. Existing
factory+coredump partitions provide no OTA slots.

The final full link emits an upstream Xtensa `crtn.o` missing `.note.GNU-stack`
warning. The installer uses its existing dependency lock and reports existing
package deprecation/audit notices; dependency/security upgrades were not mixed
into this extraction. No automated result is claimed as hardware acceptance.


## Independent review corrections and final resource proof

The final `make fw-build-docker` passed with the review fixes and the reviewer’s
HTTP-body and absolute-path Zig-wrapper corrections in the shared working tree.
`make check fw-fmt` passed all 68 Zig, 16 protocol and 3 CLI tests plus both
production C fixture executables. `tools/test_provisioning.sh` calls the actual
`sebastian_provisioning_apply` USB entry point (now in `provisioning_config.c`)
with an NVS-store spy. Compact profiles of 1,023 bytes pass; 1,024/1,025 bytes,
non-arrays and oversized decoded UTF-8 profiles are refused without calling any
NVS writer, even when the same payload also contains WiFi updates. Missing
profiles preserve state and an empty array remains accepted. The C loader and
validator share `SEBASTIAN_PROFILES_JSON_CAPACITY`; a CLI regression checks its
Python constant against the C header.

The earlier extracted build permanently retained an 8,192-byte internal static
command buffer and an 8 KB USB receiver ring. The final receiver instead
allocates its bounded command storage with
`MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT`, without an internal-memory fallback. The
8 KB RX capacity remains only during provisioning so large commands do not
depend on unmeasured receiver throughput while XVF setup runs.

`app_main` now calls `sebastian_provisioning_stop` immediately before
`usb_mic.initUac`, before either profile starts networking. Stop requests are
cooperative: the receiver finishes its current driver call/command and honors
an active configuration-read hold, frees the PSRAM command storage, acknowledges
completion and suspends. The boot task waits for the suspended state, deletes
that task, then uninstalls the USB-Serial-JTAG driver. No task is deleted inside
a driver call; its stack and driver buffers are released before TinyUSB/WiFi/TLS.
In ESP-IDF 5.4.4, `esp_driver_usb_serial_jtag/src/usb_serial_jtag.c`,
`usb_serial_jtag_driver_uninstall` explicitly deletes both ring buffers, its
semaphores and interrupt, and frees its driver object.

The final ELF/map establishes the static-memory reduction compared with the
pre-review extracted build:

| Map region | Before review fixes | Final |
| --- | --- | --- |
| `.dram0.bss` | 44,272 bytes (`0xacf0`) | 36,080 bytes (`0x8cf0`) |
| `.dram0.data` | 24,756 bytes (`0x60b4`) | 24,756 bytes (`0x60b4`) |
| Static provisioning line | `.bss.line$0`, 8,192 bytes | Absent |

Thus internal static BSS decreased by exactly 8,192 bytes. Driver/task heap
reclamation follows from the explicit pre-UAC call path and inspected IDF
cleanup; runtime heap headroom and acoustic reliability still require the board.
No memory claim relies on presumed savings from removing fleet or mDNS tasks.

Final application size is **3,632,448 bytes (`0x376d40`)**, with 13% factory
partition space free. Sparse installer packaging was regenerated using
`tools/prepare_web_installer.sh phase1-reviewed-local-validation`. Header and
sector-range checks still pass: bootloader `[0x0,0x6000)`, partition table
`[0x8000,0x9000)`, app `[0x10000,0x387000)`, without NVS/PHY overlap. The lock path
was restored to `../components/livekit` after the final build. No board was
flashed and no network/hardware acceptance claim was added.

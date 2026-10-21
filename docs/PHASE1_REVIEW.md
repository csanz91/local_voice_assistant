# Phase 1 independent review

Reviewed the working-tree changes against `5104b32b635eaf55700d51fbd181754ebcfa0b1b`
and `docs/REUSE_PLAN.md`. The implementation and review agents worked separately;
the review included new untracked files as well as tracked modifications.
No implementation commits or publishing were requested or performed.

## Standards

The independent standards review reported three P2 findings:

1. **Provisioning RAM:** an 8 KiB static serial command buffer and enlarged RX
   ring remained allocated during USB audio and LiveKit sessions. Non-DMA
   command storage belongs in PSRAM, and boot-only provisioning resources should
   be released before TinyUSB takes the shared PHY. Increased RAM pressure was
   established from the linked map; a resulting TLS failure was not claimed.
2. **HTTP contract:** the firmware sent no request body, while the shared
   protocol specified `Content-Type: application/json` and `{}`. A backend
   implementing the published contract could reject the device request.
3. **Docker formatter paths:** the Zig fallback mounted the checkout at
   `/workspace` while forwarding absolute host paths. Retained editor/devtools
   formatting would therefore fail after a Docker firmware build.

Command storage now uses a bounded PSRAM allocation. The receiver cooperatively
stops after the serial window, frees that allocation, and acknowledges that it
will make no more driver calls. Common boot then deletes its task and uninstalls
the USB-JTAG driver before initializing TinyUSB. The larger RX ring is transient.
Active configuration-read holds are honored during shutdown.

The HTTP client now sends exactly the documented JSON request and handles a
partial write as failure. Its production C harness asserts both behaviors.
The Zig wrapper mounts the repository at its original absolute path; formatting
with absolute host filenames has been exercised successfully. The shared header
comment was updated with the HTTP contract too.

No additional baseline code-smell findings were reported.

## Spec

The independent spec review reported one P2 finding:

1. **Profile storage bound:** the expanded serial command capacity allowed a
   profile array larger than the retained loader's 1,024-byte buffer. CLI/direct
   USB configuration could be acknowledged and saved, then cause fallback to
   built-in profiles at reboot. The browser already rejected this case; firmware
   and CLI needed the same bound before storing settings.

The review found no separate missing features or unrequested product behavior.
Physical board acceptance was correctly disclosed as outstanding and was not
counted as an implementation defect.

Firmware now checks the compact profile JSON against a shared loader-capacity
constant before calling storage. The CLI enforces the same UTF-8 bound. New
tests execute the production USB validation entry point with a storage spy and
verify rejection without writes, including boundary and Unicode cases. CI runs
these regressions through `make check`.

## Validation and remaining acceptance

The parent independently reran the 68 Zig tests, 16 protocol tests, production C
HTTP fixtures, Zig formatting, four installer tests and TypeScript/Vite build
before applying the focused review corrections. HTTP and absolute-path formatter
checks were rerun after their fixes, followed by the production USB validator and
three CLI regression tests. Final firmware build and memory evidence are recorded
in `PHASE1_VALIDATION.md`.

Both independent reviewers rechecked the corrected source and confirmed their
original findings resolved, with no new actionable issues. Standards: three
findings resolved, zero outstanding. Spec: one finding resolved, zero outstanding.

Hardware boot/audio/USB, acoustic behavior and actual ESP32 HTTPS/WSS trust
acceptance remain separate from host tests and simulated LiveKit transport.
See `TESTING.md` for the physical acceptance checklist.

.PHONY: check fw-test fw-fmt fw-build fw-build-docker fw-flash flash protocol-test http-test installer-build installer-image bridge
check: fw-test sdk-test protocol-test http-test provisioning-test

.PHONY: sdk-test
sdk-test:
	firmware/components/livekit/test_app/host/run.sh

fw-test:
	cd firmware && ../tools/zig.sh test core_test.zig

fw-fmt:
	tools/zig.sh fmt --check firmware/main firmware/core_test.zig firmware/build.zig

fw-build:
	tools/idf.sh build

fw-build-docker:
	tools/build_firmware_docker.sh

# Supply the board's identified port explicitly; do not flash a random device.
fw-flash:
	tools/idf.sh -p "$${PORT:?set PORT to the identified ESP32 serial port}" flash

flash:
	tools/flash.sh "$${PORT:?set PORT to the identified ESP32 serial port}"

protocol-test:
	python3 -m unittest discover -s tests/protocol -v

http-test:
	tools/test_session_http.sh

installer-build:
	cd web-installer && npm ci && npm run build

installer-image:
	tools/prepare_web_installer.sh

bridge:
	uv run tools/telemetry/bridge.py

.PHONY: provisioning-test
provisioning-test:
	tools/test_provisioning.sh

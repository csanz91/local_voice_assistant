"""Real local HTTP fixture checks. SDK/audio checks live in the SDK probe."""

from dataclasses import replace
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from threading import Thread
import unittest

from tools.protocol.protocol import MAX_WAKE_BYTES, wake_request
from tools.protocol.session_fixture import Config, handler_for

DEVICE = "aabbccddeeff"


class WakeFixtureTests(unittest.TestCase):
    def test_control_request_bounds_and_room_binding(self):
        request = {"version": 1, "request_id": "wake-1", "room": "current"}
        self.assertEqual(wake_request(json.dumps(request).encode(), "current"), request)
        for change in ({"version": True}, {"version": 2}, {"request_id": ""},
                       {"request_id": "x" * 65}, {"room": "previous"}, {"authority": "owner"}):
            self.assertIsNone(wake_request(json.dumps({**request, **change}).encode(), "current"))
        for data in (b"[", b"[]", b"null", b"\xff", b" " * (MAX_WAKE_BYTES + 1)):
            self.assertIsNone(wake_request(data, "current"))


class HttpFixtureTests(unittest.TestCase):
    def request(self, config, *, path=None, headers=None, body=b"{}"):
        with ThreadingHTTPServer(("127.0.0.1", 0), handler_for(config)) as server:
            thread = Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
            thread.start()
            try:
                connection = HTTPConnection(*server.server_address, timeout=2)
                connection.request("POST", config.path if path is None else path, body=body,
                                   headers=headers if headers is not None else {
                                       "Authorization": "Bearer local-test-secret",
                                       "Content-Type": "application/json"})
                response = connection.getresponse()
                result = response.status, response.read()
                connection.close()
                return result
            finally:
                server.shutdown()
                thread.join(timeout=2)

    def setUp(self):
        self.config = Config(DEVICE, "local-test-secret")

    def test_standard_response_and_exact_endpoint(self):
        cfg = replace(self.config, path="/api/v2/device-voice-session?fixture=1")
        status, raw = self.request(cfg)
        self.assertEqual(status, 200)
        body = json.loads(raw)
        self.assertEqual((body["serverUrl"], body["participantToken"], body["roomName"]),
                         (cfg.server_url, cfg.token, cfg.room_name))
        for path in ("/device-voice-session", "/v1/sessions", "/api/v2/device-voice-sessions"):
            self.assertEqual(self.request(cfg, path=path)[0], 404)

    def test_bearer_required_and_failure_statuses(self):
        for headers in ({}, {"Authorization": "Bearer wrong"},
                        {"X-Device-Id": DEVICE, "X-Device-Secret": "local-test-secret"}):
            self.assertEqual(self.request(self.config, headers=headers)[0], 401)
        for status in (401, 403, 409, 429, 503):
            self.assertEqual(self.request(replace(self.config, case=str(status)))[0], status)

    def test_request_cannot_supply_authority(self):
        for body in (b'{"user_id":"admin"}', b'{"attributes":{"initialMode":"TEXT"}}', b"["):
            self.assertEqual(self.request(self.config, body=body)[0], 400)
        self.assertEqual(self.request(self.config, body=b"x" * 257)[0], 413)

    def test_fault_fixtures(self):
        status, body = self.request(replace(self.config, case="malformed"))
        self.assertEqual(status, 200)
        with self.assertRaises(ValueError):
            json.loads(body)
        status, body = self.request(replace(self.config, case="oversized"))
        self.assertEqual(status, 200)
        self.assertGreater(len(body), 1535)
        self.assertNotIn("participantToken", json.loads(self.request(replace(self.config, case="missing-token"))[1]))
        self.assertTrue(json.loads(self.request(replace(self.config, case="insecure-ws"))[1])["serverUrl"].startswith("ws:"))


if __name__ == "__main__":
    unittest.main()

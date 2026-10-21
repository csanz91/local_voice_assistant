#!/usr/bin/env python3
"""Disposable, stdlib-only session HTTP fixture. Never deploy as a backend."""

import argparse
from dataclasses import dataclass
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl

try:
    from .protocol import SESSION_PATH
except ImportError:
    from protocol import SESSION_PATH

CASES = ("success", "401", "403", "409", "429", "503", "malformed", "oversized", "missing-token", "insecure-ws")


@dataclass(frozen=True)
class Config:
    device_id: str
    secret: str
    server_url: str = "wss://fixture.invalid"
    token: str = "fixture-not-a-valid-jwt"
    case: str = "success"
    path: str = SESSION_PATH
    room_name: str = "firmware-fixture"


def handler_for(config: Config):
    class Handler(BaseHTTPRequestHandler):
        # Deliberately omit headers/body/URL from access logs: credentials and
        # tokens must never be logged, even by this disposable fixture.
        def log_message(self, *args):
            pass

        def reply(self, status: int, body: bytes):
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path != config.path:
                return self.reply(404, b'{"error":"wrong_session_path"}')
            credential = self.headers.get("Authorization", "")
            # compare_digest's bytes form also handles malformed non-ASCII input.
            if not hmac.compare_digest(credential.encode(), ("Bearer " + config.secret).encode()):
                return self.reply(401, b'{"error":"unauthorized"}')
            if self.headers.get("Transfer-Encoding"):
                return self.reply(400, b'{"error":"unsupported_transfer_encoding"}')
            try:
                size = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self.reply(400, b'{"error":"invalid_length"}')
            if size < 0 or size > 256:
                return self.reply(413, b'{"error":"oversized_request"}')
            self.connection.settimeout(5)
            try:
                raw = self.rfile.read(size)
                if len(raw) != size or json.loads(raw or b"{}") != {}:
                    return self.reply(400, b'{"error":"body_must_be_empty_object"}')
            except (TimeoutError, ValueError):
                return self.reply(400, b'{"error":"malformed_request"}')
            if config.case.isdigit():
                return self.reply(int(config.case), b'{"error":"fixture_failure"}')
            body = {"serverUrl": config.server_url, "participantToken": config.token,
                    "roomName": config.room_name, "conversationId": "fixture-only"}
            if config.case == "malformed":
                return self.reply(200, b"{not-json")
            if config.case == "oversized":
                body["participantToken"] = "x" * 16_384
            if config.case == "missing-token":
                del body["participantToken"]
            if config.case == "insecure-ws":
                body["serverUrl"] = "ws://fixture.invalid:7880"
            self.reply(200, json.dumps(body).encode())

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1", help="use a LAN IP explicitly for a physical board")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device-id", required=True, help="12 lowercase MAC hex digits, no separators")
    parser.add_argument("--case", choices=CASES, default="success")
    parser.add_argument("--token-file", type=Path, help="file produced by livekit_peer.py")
    parser.add_argument("--room-name", help="room from peer; defaults to token-file companion .room file")
    parser.add_argument("--path", default=SESSION_PATH, help="exact endpoint, including any query string")
    parser.add_argument("--cert", type=Path)
    parser.add_argument("--key", type=Path)
    args = parser.parse_args()
    if bool(args.cert) != bool(args.key):
        parser.error("--cert and --key must be supplied together")
    secret = os.environ.get("FIXTURE_DEVICE_SECRET")
    if not secret:
        parser.error("set FIXTURE_DEVICE_SECRET to the board's local test credential")
    room_name = args.room_name or (args.token_file.with_suffix(".room").read_text().strip()
                                  if args.token_file else "firmware-fixture")
    config = Config(args.device_id, secret, os.environ.get("LIVEKIT_URL", "wss://fixture.invalid"),
                    args.token_file.read_text().strip() if args.token_file else "fixture-not-a-valid-jwt",
                    args.case, args.path, room_name)
    with ThreadingHTTPServer((args.bind, args.port), handler_for(config)) as server:
        if args.cert:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(args.cert, args.key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https" if args.cert else "http"
        print(f"Development fixture: {scheme} on {args.bind}:{args.port}; case={args.case}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()

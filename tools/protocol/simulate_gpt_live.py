#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["aiortc==1.14.0", "numpy==2.3.3"]
# ///
"""Disposable native client for the experimental direct GPT-Live path (profile mode gpt_live).

Does what live_peer.c + sebastian_live_session_create do on the device: one
WebRTC peer, a full (non-trickle) SDP offer POSTed as {"sdp": ...} to the
device session endpoint with the device Bearer, Opus mic audio out, remote
audio in, JSON events on "oai-events", and a graceful session.close.

    FIXTURE_DEVICE_SECRET=... uv run tools/protocol/simulate_gpt_live.py \\
        --session-url https://.../api/v2/device-voice-session --wav prompt.wav

Without --wav it only checks the session comes up and closes cleanly (a
spoken reply needs a real prompt; a tone will not get one).
"""

import argparse
import asyncio
from fractions import Fraction
import json
import os
import re
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import wave

import av
from aiortc import MediaStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription

# Same bounds as firmware/main/session_http.h.
SDP_MAX = 8 * 1024
BODY_MAX = 12 * 1024
RATE = 48_000
FRAME = 960  # 20 ms, the device send cadence
AUDIBLE_PEAK = 1000
CONVERSATION_ID = re.compile(r"^[0-9a-fA-F-]+$")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def open_session(args, offer):
    if urlsplit(args.session_url).scheme != "https" and not args.allow_insecure:
        raise ValueError("HTTPS required; --allow-insecure is for a local fixture")
    if len(offer) > SDP_MAX:
        raise ValueError(f"offer is {len(offer)} bytes, firmware limit {SDP_MAX}")
    body = json.dumps({"sdp": offer}).encode()
    request = urllib.request.Request(args.session_url, body, method="POST", headers={
        "Authorization": "Bearer " + os.environ["FIXTURE_DEVICE_SECRET"],
        "Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
            if response.status != 200:  # exactly what the firmware accepts
                raise ValueError(f"session returned HTTP {response.status}")
            raw = response.read(BODY_MAX + 1)
    except urllib.error.HTTPError as error:
        raise ValueError(f"session returned HTTP {error.code}: {error.read(512)!r}") from None
    if len(raw) > BODY_MAX:
        raise ValueError(f"session response exceeds firmware bound {BODY_MAX}")
    result = json.loads(raw)
    answer = result.get("sdp")
    if result.get("transport") != "gpt_live" or not isinstance(answer, str) or not answer.startswith("v=0"):
        raise ValueError("not a gpt_live session response")
    if len(answer) > SDP_MAX:
        raise ValueError(f"answer is {len(answer)} bytes, firmware limit {SDP_MAX}")
    conversation = result.get("conversationId")
    if conversation is not None and not (isinstance(conversation, str) and CONVERSATION_ID.match(conversation)):
        raise ValueError("conversationId has characters the firmware drops")
    return answer, conversation, len(raw)


class Mic(MediaStreamTrack):
    """20 ms mono s16 frames: the prompt (if any) once `live` is set, then silence."""

    kind = "audio"

    def __init__(self, pcm: bytes, live: asyncio.Event):
        super().__init__()
        self.pcm, self.live, self.pts, self.pos, self.start = pcm, live, 0, 0, None

    async def recv(self):
        if self.start is None:
            self.start = time.monotonic()
        wait = self.start + self.pts / RATE - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        chunk = b""
        if self.live.is_set() and self.pos < len(self.pcm):
            chunk = self.pcm[self.pos:self.pos + FRAME * 2]
            self.pos += len(chunk)
        chunk = chunk.ljust(FRAME * 2, b"\0")
        frame = av.AudioFrame(format="s16", layout="mono", samples=FRAME)
        frame.planes[0].update(chunk)
        frame.sample_rate, frame.pts, frame.time_base = RATE, self.pts, Fraction(1, RATE)
        self.pts += FRAME
        return frame

    @property
    def prompt_done(self):
        return self.pos >= len(self.pcm)


def load_wav(path):
    if not path:
        return b""
    with wave.open(path, "rb") as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, RATE):
            raise ValueError("--wav must be 48 kHz mono 16-bit PCM (ffmpeg -ar 48000 -ac 1 -sample_fmt s16)")
        return wav.readframes(wav.getnframes())


async def run(args):
    pcm = load_wav(args.wav)
    t0 = time.monotonic()
    marks = {}

    def mark(name):
        marks.setdefault(name, time.monotonic() - t0)

    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))  # no STUN/TURN, like the device
    started, closed, heard = asyncio.Event(), asyncio.Event(), asyncio.Event()
    channel_open = asyncio.Event()
    types: dict[str, int] = {}
    heard_samples = 0
    tasks = []

    channel = pc.createDataChannel("oai-events", ordered=True)
    channel.on("open", lambda: (mark("channel_open"), channel_open.set()))

    @channel.on("message")
    def on_message(message):
        if isinstance(message, bytes):
            message = message.decode()
        event = json.loads(message)
        kind = event.get("type", "?")
        types[kind] = types.get(kind, 0) + 1
        if kind == "session.started":
            mark("session_started")
            started.set()
        elif kind == "session.closed":
            mark("session_closed")
            closed.set()
        elif kind == "session.output_transcript.delta":
            mark("first_output_transcript")
        elif kind == "error":
            print("server error:", json.dumps(event)[:400])

    async def hear(track):
        nonlocal heard_samples
        while True:
            frame = await track.recv()
            samples = frame.to_ndarray()
            if int(abs(samples).max()) >= AUDIBLE_PEAK:
                mark("first_remote_audio")
                heard_samples += samples.shape[-1] // max(1, len(frame.layout.channels))
                if heard_samples >= RATE // 2:
                    heard.set()

    @pc.on("track")
    def on_track(track):
        if track.kind == "audio":
            mark("remote_track")
            tasks.append(asyncio.create_task(hear(track)))

    @pc.on("connectionstatechange")
    def on_state():
        if pc.connectionState == "connected":
            mark("peer_connected")

    mic = Mic(pcm, started)
    pc.addTrack(mic)
    try:
        await pc.setLocalDescription(await pc.createOffer())  # aiortc gathers fully here
        offer = pc.localDescription.sdp
        mark("offer_ready")
        answer, conversation, body_len = await asyncio.to_thread(open_session, args, offer)
        mark("answer")
        print(f"offer {len(offer)} B, answer {len(answer)} B, body {body_len} B, conversation {conversation}")
        await pc.setRemoteDescription(RTCSessionDescription(answer, "answer"))
        await asyncio.wait_for(channel_open.wait(), args.timeout)
        await asyncio.wait_for(started.wait(), args.timeout)
        if pcm:
            await asyncio.wait_for(heard.wait(), args.timeout)
            # Let the reply finish (or a tool round trip run) before hanging up.
            await asyncio.sleep(args.linger)
        channel.send(json.dumps({"type": "session.close"}))
        mark("close_sent")
        await asyncio.wait_for(closed.wait(), 10)
        if args.expect_delegation and not any(t == "response.event" or t.startswith("session.delegation.")
                                              for t in types):
            raise AssertionError("no delegation events seen on oai-events")
        print("timings (s): " + ", ".join(f"{k}={v:.3f}" for k, v in sorted(marks.items(), key=lambda kv: kv[1])))
        print("events: " + ", ".join(f"{k}x{v}" for k, v in sorted(types.items())))
        print(f"GPT-Live simulated device passed; heard {heard_samples / RATE:.1f} s of reply audio")
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await pc.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--session-url", required=True)
    parser.add_argument("--allow-insecure", action="store_true")
    parser.add_argument("--wav", help="48 kHz mono s16 prompt, sent once session.started arrives")
    parser.add_argument("--linger", type=float, default=6, help="seconds to keep listening after the reply starts")
    parser.add_argument("--expect-delegation", action="store_true",
                        help="fail unless delegation events reach the device channel")
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    if not os.environ.get("FIXTURE_DEVICE_SECRET"):
        parser.error("set FIXTURE_DEVICE_SECRET to the disposable fixture credential")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()

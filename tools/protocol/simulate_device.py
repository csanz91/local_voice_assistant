#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["livekit==1.1.20"]
# ///
"""Disposable native client: HTTP session, pre-connect PCM, standard state, wake ACK."""

import argparse
from array import array
import asyncio
import json
import math
import os
import urllib.request
from urllib.parse import urlsplit

from livekit import rtc
from protocol import OUTPUT_TRACK, PREROLL_TOPIC, STATE_ATTRIBUTE, WAKE_TOPIC, WAKE_RESULT_TOPIC


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def open_session(args):
    if urlsplit(args.session_url).scheme != "https" and not args.allow_insecure:
        raise ValueError("HTTPS required; --allow-insecure is for a local fixture")
    request = urllib.request.Request(args.session_url, b"{}", method="POST", headers={
        "Authorization": "Bearer " + os.environ["FIXTURE_DEVICE_SECRET"],
        "Content-Type": "application/json"})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=5) as response:
        if response.status != 200:
            raise ValueError("session did not return HTTP200")
        body = response.read(1536)
    if len(body) > 1535:
        raise ValueError("session response exceeds firmware bound")
    result = json.loads(body)
    url, token, name = result["serverUrl"], result["participantToken"], result["roomName"]
    if not all(isinstance(value, str) and value for value in (url, token, name)):
        raise ValueError("invalid session response")
    if urlsplit(url).scheme != "wss" and not (args.allow_insecure and urlsplit(url).scheme == "ws"):
        raise ValueError("WSS required")
    return url, token, name


async def run(args):
    url, token, name = await asyncio.to_thread(open_session, args)
    room = rtc.Room()
    source = rtc.AudioSource(48_000, 1)
    states = []
    closed = asyncio.Event()
    ready = asyncio.Event()
    wake_reply = asyncio.Event()
    tasks = []
    selected = None
    request_id = "simulated-wake-1"
    result = None

    async def interrupt():
        await room.local_participant.publish_data(json.dumps({"version": 1,
            "request_id": request_id, "room": name}), topic=WAKE_TOPIC, reliable=True,
            destination_identities=[selected.identity])

    def observe(participant):
        nonlocal selected
        if participant.kind != rtc.ParticipantKind.PARTICIPANT_KIND_AGENT:
            return
        if selected is None:
            selected = participant
        if participant is not selected:
            return
        if any(pub.name == OUTPUT_TRACK for pub in participant.track_publications.values()):
            ready.set()
        state = participant.attributes.get(STATE_ATTRIBUTE)
        if state and (not states or states[-1] != state):
            states.append(state)
            if state == "speaking" and not args.no_barge and not tasks:
                tasks.append(asyncio.create_task(interrupt()))

    def on_data(packet):
        nonlocal result
        if packet.participant is not selected or packet.topic != WAKE_RESULT_TOPIC:
            return
        value = json.loads(packet.data)
        if value.get("version") == 1 and value.get("request_id") == request_id:
            result = value
            wake_reply.set()

    room.on("participant_connected", observe)
    room.on("participant_attributes_changed", lambda _, participant: observe(participant))
    room.on("track_published", lambda _, participant: observe(participant))
    room.on("participant_disconnected", lambda participant: closed.set() if participant is selected else None)
    room.on("disconnected", lambda *_: closed.set())
    room.on("data_received", on_data)

    async def media():
        for tick in range(int(args.timeout * 50)):
            pcm = array("h", (int(2000 * math.sin(2 * math.pi * 880 * (tick * 960 + n) / 48_000))
                              for n in range(960)))
            await source.capture_frame(rtc.AudioFrame(pcm.tobytes(), 48_000, 1, 960))

    media_task = None
    try:
        await room.connect(url, token)
        if room.name != name:
            raise ValueError("returned room does not match participant token")
        for participant in room.remote_participants.values():
            observe(participant)
        track = rtc.LocalAudioTrack.create_audio_track("simulated-device-mic", source)
        pub = await room.local_participant.publish_track(track,
            rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE, preconnect_buffer=True))
        await asyncio.wait_for(ready.wait(), args.timeout)
        if not args.no_preroll:
            pcm = array("h", (int(1500 * math.sin(2 * math.pi * 440 * n / 16_000)) for n in range(3200))).tobytes()
            writer = await room.local_participant.stream_bytes("wake.pcm", topic=PREROLL_TOPIC,
                total_size=len(pcm), attributes={"trackId": pub.sid, "sampleRate": "16000", "channels": "1"})
            await writer.write(pcm)
            await writer.aclose()
        media_task = asyncio.create_task(media())
        await asyncio.wait_for(closed.wait(), args.timeout)
        if not {"listening", "speaking"}.issubset(states):
            raise AssertionError("missing native session states")
        if not args.no_barge and (not wake_reply.is_set() or result.get("status") != "accepted"):
            raise AssertionError("production wake helper did not accept interruption")
        print("Native simulated device passed; states=" + ",".join(states))
    finally:
        if media_task:
            media_task.cancel()
            await asyncio.gather(media_task, return_exceptions=True)
        await asyncio.gather(*tasks, return_exceptions=True)
        await room.disconnect()
        await source.aclose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-url", required=True)
    parser.add_argument("--allow-insecure", action="store_true")
    parser.add_argument("--no-preroll", action="store_true", help="exercise native three-second live fallback")
    parser.add_argument("--no-barge", action="store_true")
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    if not os.environ.get("FIXTURE_DEVICE_SECRET"):
        parser.error("set FIXTURE_DEVICE_SECRET to the disposable fixture credential")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()

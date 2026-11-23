#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["livekit-agents==1.8.12", "livekit==1.2.1", "livekit-api==1.2.2"]
# ///
"""Disposable native RoomIO peer using the production wake helper, without models.

Point --wake-helper at IoTCloud's device_wake.py. No tools, transcript storage,
providers, custom audio ordering, or explicit room deletion. Each run is one room.
"""

import argparse
from array import array
import asyncio
from contextlib import suppress
from datetime import timedelta
import importlib.util
import logging
import math
import os
from pathlib import Path
import signal
import sys
import uuid

from livekit import api, rtc
from livekit.agents import Agent, AgentSession
from livekit.agents.voice.room_io import RoomOptions

from protocol import DEVICE_ATTRIBUTE

log = logging.getLogger("native-peer")


async def run(args):
    spec = importlib.util.spec_from_file_location("device_wake", args.wake_helper)
    if spec is None or spec.loader is None:
        raise ValueError("cannot load production wake helper")
    helper = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = helper
    spec.loader.exec_module(helper)

    room_name = "firmware-fixture-" + uuid.uuid4().hex[:12]
    room = rtc.Room()
    session = AgentSession(vad=None, turn_handling={"turn_detection": None},
                           aec_warmup_duration=None, user_away_timeout=None)
    control = helper.DeviceWakeControl(session, room)
    stop = asyncio.Event()
    microphone = asyncio.Event()
    task = None
    input_samples = 0

    def on_track(track, publication, participant):
        if (participant.identity == args.device_id
                and publication.source == rtc.TrackSource.SOURCE_MICROPHONE):
            microphone.set()

    room.on("track_subscribed", on_track)
    room.on("disconnected", lambda *_: stop.set())
    session.on("agent_state_changed", lambda event: log.info("Native state: %s", event.new_state))
    for sig in (signal.SIGINT, signal.SIGTERM):
        asyncio.get_running_loop().add_signal_handler(sig, stop.set)

    def token(identity, kind, *, device=False):
        return (api.AccessToken().with_identity(identity).with_kind(kind)
                .with_ttl(timedelta(minutes=5))
                .with_attributes({DEVICE_ATTRIBUTE: "1"} if device else {})
                .with_grants(api.VideoGrants(room_join=True, room=room_name,
                    can_publish=True, can_subscribe=True, can_publish_data=True,
                    can_update_own_metadata=not device, can_publish_sources=["microphone"]))
                .to_jwt())

    async def tone(frequency, seconds):
        for tick in range(int(seconds * 100)):
            pcm = array("h", (int(1200 * math.sin(2 * math.pi * frequency * (tick * 480 + n) / 48_000))
                              for n in range(480)))
            yield rtc.AudioFrame(pcm.tobytes(), 48_000, 1, 480)

    async def reply():
        await microphone.wait()
        await asyncio.sleep(args.reply_after)
        speech = session.say("Disposable test tone", audio=tone(440, args.tone_seconds),
                             allow_interruptions=True, add_to_chat_ctx=False)
        await speech
        if speech.interrupted:
            await session.say("Immediate follow-up", audio=tone(990, 0.8), add_to_chat_ctx=False)

    try:
        await room.connect(os.environ["LIVEKIT_URL"], token("protocol-peer", "agent"))
        await session.start(Agent(instructions="Synthetic tone test; no provider"), room=room,
                            room_options=RoomOptions(participant_identity=args.device_id),
                            record=False, session_host=False)
        control.mark_ready()
        # Observe the native input boundary without replacing RoomIO or its decoder.
        original = session._activity.push_audio

        def observe(frame):
            nonlocal input_samples
            input_samples += frame.samples_per_channel
            return original(frame)

        session._activity.push_audio = observe
        for path, contents in ((args.token_file, token(args.device_id, "standard", device=True)),
                               (args.token_file.with_suffix(".room"), room_name)):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as output:
                output.write(contents)
        log.info("Peer ready room=%s; token and .room companion written", room_name)
        task = asyncio.create_task(reply())
        stop_task = asyncio.create_task(stop.wait())
        done, _ = await asyncio.wait((task, stop_task), timeout=args.close_after,
                                     return_when=asyncio.FIRST_COMPLETED)
        # A completed tone leaves time for the client to observe listening before disconnect.
        if task in done:
            task.result()
            await asyncio.sleep(.5)
        stop_task.cancel()
        await asyncio.gather(stop_task, return_exceptions=True)
    finally:
        if task:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        await control.aclose()
        await session.aclose()
        await room.disconnect()
        log.info("Peer stopped; native input samples=%d; no audio saved", input_samples)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-id", required=True, help="fixture participant identity")
    parser.add_argument("--token-file", type=Path, required=True, help="NEW short-lived device-token file")
    parser.add_argument("--wake-helper", type=Path, required=True, help="IoTCloud device_wake.py source")
    parser.add_argument("--reply-after", type=float, default=4)
    parser.add_argument("--tone-seconds", type=float, default=4)
    parser.add_argument("--close-after", type=float, default=30)
    args = parser.parse_args()
    if not args.wake_helper.is_file():
        parser.error("--wake-helper must be an existing production helper file")
    if any(value <= 0 for value in (args.reply_after, args.tone_seconds, args.close_after)):
        parser.error("timing values must be positive")
    for name in ("LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET"):
        if not os.environ.get(name):
            parser.error(f"set {name} for a disposable test server")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    with suppress(KeyboardInterrupt):
        asyncio.run(run(args))


if __name__ == "__main__":
    main()

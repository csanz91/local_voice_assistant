"""Wire constants and strict wake parsing for disposable development peers.

Native RoomIO owns pre-connect decoding, resampling and ordering. This module
does not implement a second audio path or the production credential service.
"""

import json
import re

SESSION_PATH = "/api/v2/device-voice-session"
PREROLL_TOPIC = "lk.agent.pre-connect-audio-buffer"
STATE_ATTRIBUTE = "lk.agent.state"
OUTPUT_TRACK = "roomio_audio"
WAKE_TOPIC = "iotcloud.device.wake"
WAKE_RESULT_TOPIC = WAKE_TOPIC + ".result"
DEVICE_ATTRIBUTE = "iotcloud.device.voice"
SAMPLE_RATE = 16_000
MAX_PCM_BYTES = 12 * SAMPLE_RATE * 2
MAX_WAKE_BYTES = 512


def wake_request(data: bytes, room_name: str) -> dict | None:
    """Validate the test peer's small control request; sender checked separately."""
    if len(data) > MAX_WAKE_BYTES:
        return None
    try:
        value = json.loads(data)
    except (ValueError, UnicodeDecodeError):
        return None
    if (not isinstance(value, dict) or set(value) != {"version", "request_id", "room"}
            or type(value["version"]) is not int or value["version"] not in (1, 2)
            or value["room"] != room_name
            or not isinstance(value["request_id"], str)
            or re.fullmatch(r"[A-Za-z0-9_-]{1,64}", value["request_id"]) is None):
        return None
    return value

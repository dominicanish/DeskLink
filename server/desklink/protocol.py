"""DeskLink wire protocol (see docs/PROTOCOL.md).

Pure-Python, dependency-free, and unit-tested so it can be validated on any
platform (including Linux CI) without the Windows audio stack.

* Control messages  -> JSON text frames (helpers below).
* Audio frames      -> binary frames: [stream_id:1][ts_us:8 LE][payload].
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from enum import IntEnum
from typing import Any

PROTOCOL_VERSION = 1

# Capability identifiers.
CAP_PLAYBACK = "audio.playback"
CAP_MIC = "audio.mic"
CAP_NOWPLAYING = "meta.nowplaying"
CAP_TRANSPORT = "transport"
CAP_DYNAMIC_ISLAND = "dynamic_island"

SERVER_CAPABILITIES = [CAP_PLAYBACK, CAP_MIC, CAP_NOWPLAYING, CAP_TRANSPORT]


class StreamId(IntEnum):
    PLAYBACK = 1  # PC -> phone
    MIC = 2       # phone -> PC


# ---------------------------------------------------------------------------
# Binary audio framing
# ---------------------------------------------------------------------------

_HEADER = struct.Struct("<BQ")  # stream_id (u8), timestamp_us (u64 LE)


def encode_audio_frame(stream_id: int, timestamp_us: int, payload: bytes) -> bytes:
    """Pack an audio frame into a single binary WebSocket message."""
    return _HEADER.pack(stream_id, timestamp_us & 0xFFFFFFFFFFFFFFFF) + payload


@dataclass(frozen=True)
class AudioFrame:
    stream_id: int
    timestamp_us: int
    payload: bytes


def decode_audio_frame(data: bytes) -> AudioFrame:
    """Unpack a binary audio frame. Raises ValueError if malformed."""
    if len(data) < _HEADER.size:
        raise ValueError("audio frame too short")
    stream_id, ts = _HEADER.unpack(data[: _HEADER.size])
    return AudioFrame(stream_id, ts, data[_HEADER.size :])


# ---------------------------------------------------------------------------
# Control messages (JSON)
# ---------------------------------------------------------------------------

def dumps(message: dict[str, Any]) -> str:
    return json.dumps(message, separators=(",", ":"), ensure_ascii=False)


def loads(text: str | bytes) -> dict[str, Any]:
    obj = json.loads(text)
    if not isinstance(obj, dict) or "type" not in obj:
        raise ValueError("control message must be a JSON object with a 'type'")
    return obj


def hello(*, server: str, session: str, capabilities: list[str], pairing_required: bool,
          playback: dict, mic: dict) -> dict:
    return {
        "type": "hello",
        "protocol": PROTOCOL_VERSION,
        "server": server,
        "session": session,
        "pairing_required": pairing_required,
        "capabilities": capabilities,
        "audio": {"playback": playback, "mic": mic},
    }


def ready(*, capabilities: list[str], playback_codec: str, mic_codec: str) -> dict:
    return {
        "type": "ready",
        "capabilities": capabilities,
        "audio": {"playback": {"codec": playback_codec}, "mic": {"codec": mic_codec}},
        "stream_ids": {"playback": int(StreamId.PLAYBACK), "mic": int(StreamId.MIC)},
    }


def nowplaying(*, title: str, artist: str, album: str, app: str, duration_ms: int,
               position_ms: int, playing: bool, artwork_b64: str | None = None) -> dict:
    msg = {
        "type": "nowplaying",
        "title": title,
        "artist": artist,
        "album": album,
        "app": app,
        "durationMs": duration_ms,
        "positionMs": position_ms,
        "playing": playing,
    }
    if artwork_b64 is not None:
        msg["artwork"] = artwork_b64
    return msg


def transport_state(*, can_next: bool, can_prev: bool, can_seek: bool) -> dict:
    return {"type": "transport_state", "canNext": can_next, "canPrev": can_prev, "canSeek": can_seek}


def bye(reason: str) -> dict:
    return {"type": "bye", "reason": reason}


def negotiate_capabilities(server_caps: list[str], client_caps: list[str]) -> list[str]:
    """Intersection preserving server order."""
    client = set(client_caps)
    return [c for c in server_caps if c in client]


def negotiate_codec(server_prefers_opus: bool, client_codec: str, opus_available: bool) -> str:
    """Both sides must support Opus, otherwise fall back to PCM."""
    if server_prefers_opus and opus_available and client_codec == "opus":
        return "opus"
    return "pcm"

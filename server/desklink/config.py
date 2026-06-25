"""Runtime configuration for the DeskLink server."""

from __future__ import annotations

import random
import socket
from dataclasses import dataclass, field

SERVICE_TYPE = "_desklink._tcp.local."
DEFAULT_PORT = 8765

# Audio defaults (see docs/PROTOCOL.md).
PLAYBACK_RATE = 48000
PLAYBACK_CHANNELS = 2
MIC_RATE = 48000
MIC_CHANNELS = 1
FRAME_MS = 20


def _default_name() -> str:
    try:
        return socket.gethostname()
    except OSError:
        return "DeskLink-PC"


def _new_pairing_code() -> str:
    return f"{random.randint(0, 999999):06d}"


@dataclass
class ServerConfig:
    host: str = "0.0.0.0"
    port: int = DEFAULT_PORT
    name: str = field(default_factory=_default_name)
    pairing_required: bool = True
    pairing_code: str = field(default_factory=_new_pairing_code)
    prefer_opus: bool = True
    # bitrate hints (bps)
    music_bitrate: int = 96_000
    mic_bitrate: int = 32_000

    def regenerate_pairing(self) -> str:
        self.pairing_code = _new_pairing_code()
        return self.pairing_code

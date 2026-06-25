"""WASAPI loopback capture of the Windows system output.

Uses PyAudioWPatch (a PyAudio fork that exposes WASAPI loopback). On the default
output device, loopback gives us exactly what the speakers are playing — i.e. the
mix of Spotify / Apple Music / browser / games — which is what we stream to the
phone.

The capture runs in a background thread and pushes fixed-size PCM frames onto an
asyncio queue via a thread-safe callback supplied by the server.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable

from ..config import FRAME_MS, PLAYBACK_CHANNELS, PLAYBACK_RATE

log = logging.getLogger("desklink.capture")

try:
    import pyaudiowpatch as pyaudio  # type: ignore
    _AVAILABLE = True
except Exception:  # pragma: no cover - Windows-only dependency
    pyaudio = None  # type: ignore
    _AVAILABLE = False

try:
    import numpy as np  # part of the [windows] extra
    _NUMPY = True
except Exception:  # pragma: no cover
    np = None  # type: ignore
    _NUMPY = False


def available() -> bool:
    return _AVAILABLE


class LoopbackCapture:
    """Capture system audio (WASAPI loopback) and deliver 20 ms s16le frames."""

    def __init__(self, on_frame: Callable[[bytes], None],
                 rate: int = PLAYBACK_RATE, channels: int = PLAYBACK_CHANNELS):
        if not _AVAILABLE:
            raise RuntimeError(
                "PyAudioWPatch is not installed. Install with: pip install desklink[windows]"
            )
        self._on_frame = on_frame
        self._rate = rate
        self._channels = channels
        self._frames_per_buffer = rate * FRAME_MS // 1000
        self._pa: "pyaudio.PyAudio | None" = None
        self._stream = None
        self._lock = threading.Lock()
        self._float = False

    def _default_loopback_device(self) -> dict:
        """Find the loopback companion of the default output device."""
        assert self._pa is not None
        wasapi = self._pa.get_host_api_info_by_type(pyaudio.paWASAPI)
        default_out = self._pa.get_device_info_by_index(wasapi["defaultOutputDevice"])
        # PyAudioWPatch exposes loopback devices; match by name.
        for dev in self._pa.get_loopback_device_info_generator():
            if default_out["name"] in dev["name"]:
                return dev
        raise RuntimeError("No WASAPI loopback device found for the default output")

    def start(self) -> None:
        with self._lock:
            self._pa = pyaudio.PyAudio()
            dev = self._default_loopback_device()
            self._channels = int(dev["maxInputChannels"]) or self._channels
            self._rate = int(dev["defaultSampleRate"]) or self._rate
            # WASAPI shared-mode loopback delivers 32-bit float. Capture in that
            # native format and convert to s16le ourselves (the wire format the
            # client expects). Requesting paInt16 directly yields garbage/noise.
            self._float = _NUMPY
            fmt = pyaudio.paFloat32 if self._float else pyaudio.paInt16
            log.info("Capturing loopback device: %s (%d Hz, %d ch, %s)",
                     dev.get("name"), self._rate, self._channels,
                     "float32->int16" if self._float else "int16")
            self._stream = self._pa.open(
                format=fmt,
                channels=self._channels,
                rate=self._rate,
                frames_per_buffer=self._frames_per_buffer,
                input=True,
                input_device_index=dev["index"],
                stream_callback=self._callback,
            )
            self._stream.start_stream()

    def _callback(self, in_data, frame_count, time_info, status):  # noqa: ANN001
        # Called on PortAudio's thread. Convert float32 -> s16le if needed, then
        # hand the PCM off without blocking.
        try:
            if self._float and np is not None:
                f = np.frombuffer(in_data, dtype=np.float32)
                pcm = (np.clip(f, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
            else:
                pcm = in_data
            self._on_frame(pcm)
        except Exception:
            pass
        return (None, pyaudio.paContinue)

    @property
    def rate(self) -> int:
        return self._rate

    @property
    def channels(self) -> int:
        return self._channels

    def stop(self) -> None:
        with self._lock:
            if self._stream is not None:
                self._stream.stop_stream()
                self._stream.close()
                self._stream = None
            if self._pa is not None:
                self._pa.terminate()
                self._pa = None

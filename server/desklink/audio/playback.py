"""Play the iPhone microphone stream on the PC's default output device.

Receives decoded s16le mono frames and writes them to a WASAPI render stream.
"""

from __future__ import annotations

from ..config import MIC_CHANNELS, MIC_RATE

try:
    import pyaudiowpatch as pyaudio  # type: ignore
    _AVAILABLE = True
except Exception:  # pragma: no cover - Windows-only dependency
    pyaudio = None  # type: ignore
    _AVAILABLE = False


def available() -> bool:
    return _AVAILABLE


class MicPlayback:
    """A simple blocking render sink for the phone-mic stream."""

    def __init__(self, rate: int = MIC_RATE, channels: int = MIC_CHANNELS):
        if not _AVAILABLE:
            raise RuntimeError(
                "PyAudioWPatch is not installed. Install with: pip install desklink[windows]"
            )
        self._rate = rate
        self._channels = channels
        self._pa: "pyaudio.PyAudio | None" = None
        self._stream = None

    def start(self) -> None:
        self._pa = pyaudio.PyAudio()
        self._stream = self._pa.open(
            format=pyaudio.paInt16,
            channels=self._channels,
            rate=self._rate,
            output=True,
        )

    def write(self, pcm: bytes) -> None:
        if self._stream is not None:
            self._stream.write(pcm, exception_on_underflow=False)

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop_stream()
            self._stream.close()
            self._stream = None
        if self._pa is not None:
            self._pa.terminate()
            self._pa = None

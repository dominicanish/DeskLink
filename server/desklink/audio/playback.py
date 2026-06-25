"""Render the iPhone microphone stream into a PC audio endpoint.

By default we render into the **VB-CABLE** virtual cable ("CABLE Input"), which
makes the phone mic show up as a real microphone ("CABLE Output") that any PC app
can select. If the virtual cable isn't installed we fall back to the default
output device (so you at least hear the phone mic on the speakers), with a log
hint to run ``desklink --install-vmic``.

Incoming frames are s16le **mono** 48 kHz (20 ms). The cable endpoint is stereo,
so we upmix mono → stereo (L = R) before writing; WASAPI shared mode resamples to
the cable's internal rate.
"""

from __future__ import annotations

import logging

from ..config import MIC_CHANNELS, MIC_RATE
from . import vmic

log = logging.getLogger("desklink.micplayback")

try:
    import pyaudiowpatch as pyaudio  # type: ignore
    _AVAILABLE = True
except Exception:  # pragma: no cover - Windows-only dependency
    pyaudio = None  # type: ignore
    _AVAILABLE = False

try:
    import numpy as np
    _NUMPY = True
except Exception:  # pragma: no cover
    np = None  # type: ignore
    _NUMPY = False


def available() -> bool:
    return _AVAILABLE


class MicPlayback:
    """Render the phone-mic stream into the virtual mic (or default output)."""

    def __init__(self, rate: int = MIC_RATE, channels: int = MIC_CHANNELS):
        if not _AVAILABLE:
            raise RuntimeError(
                "PyAudioWPatch is not installed. Install with: pip install desklink[windows]"
            )
        self._rate = rate
        self._channels = channels
        self._pa: "pyaudio.PyAudio | None" = None
        self._stream = None
        self._out_channels = 2          # cable endpoints are stereo
        self._to_virtual_mic = False

    def start(self) -> None:
        self._pa = pyaudio.PyAudio()
        device_index = vmic.find_render_device_index(self._pa)
        self._to_virtual_mic = device_index is not None
        if self._to_virtual_mic:
            info = self._pa.get_device_info_by_index(device_index)
            self._out_channels = max(1, int(info.get("maxOutputChannels", 2)))
            log.info("Phone mic -> virtual mic (%s). Select \"%s\" as the mic in your PC app.",
                     info.get("name"), vmic.CABLE_CAPTURE_NAME)
        else:
            self._out_channels = self._channels
            log.warning("Virtual mic (VB-CABLE) not found; playing phone mic on the default "
                        "output instead. Run `desklink --install-vmic` to enable phone-as-PC-mic.")
        # WASAPI shared mode resamples our 48 kHz to the endpoint's rate.
        self._stream = self._pa.open(
            format=pyaudio.paInt16,
            channels=self._out_channels,
            rate=self._rate,
            output=True,
            output_device_index=device_index,  # None => default output
        )

    def write(self, pcm: bytes) -> None:
        if self._stream is None:
            return
        if self._out_channels == 2 and self._channels == 1:
            pcm = self._mono_to_stereo(pcm)
        self._stream.write(pcm, exception_on_underflow=False)

    @staticmethod
    def _mono_to_stereo(mono: bytes) -> bytes:
        """Duplicate each mono sample into L and R (s16le)."""
        if _NUMPY:
            a = np.frombuffer(mono, dtype="<i2")
            return np.repeat(a[:, None], 2, axis=1).tobytes()
        # numpy-free fallback: interleave 2-byte samples.
        out = bytearray(len(mono) * 2)
        for i in range(0, len(mono), 2):
            out[2 * i:2 * i + 2] = mono[i:i + 2]
            out[2 * i + 2:2 * i + 4] = mono[i:i + 2]
        return bytes(out)

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop_stream()
            self._stream.close()
            self._stream = None
        if self._pa is not None:
            self._pa.terminate()
            self._pa = None

"""Opus encode/decode with a transparent raw-PCM fallback.

If ``opuslib`` (libopus) isn't installed, ``opus_available()`` returns False and
both endpoints negotiate ``pcm`` instead — the rest of the pipeline is unchanged
because every encoder/decoder here takes and returns raw s16le bytes.
"""

from __future__ import annotations

try:
    import opuslib  # type: ignore
    _OPUS = True
except Exception:  # pragma: no cover - depends on host libopus
    opuslib = None  # type: ignore
    _OPUS = False


def opus_available() -> bool:
    return _OPUS


class PcmPassthrough:
    """No-op codec: encode == decode == identity on s16le bytes."""

    def encode(self, pcm: bytes) -> bytes:
        return pcm

    def decode(self, payload: bytes) -> bytes:
        return payload


class OpusEncoder:
    def __init__(self, rate: int, channels: int, bitrate: int, frame_ms: int = 20):
        if not _OPUS:
            raise RuntimeError("opuslib is not available")
        self._enc = opuslib.Encoder(rate, channels, application="audio")
        self._enc.bitrate = bitrate
        self._frame_samples = rate * frame_ms // 1000
        self._channels = channels

    def encode(self, pcm: bytes) -> bytes:
        # opuslib expects exactly frame_samples per channel.
        return self._enc.encode(pcm, self._frame_samples)


class OpusDecoder:
    def __init__(self, rate: int, channels: int, frame_ms: int = 20):
        if not _OPUS:
            raise RuntimeError("opuslib is not available")
        self._dec = opuslib.Decoder(rate, channels)
        self._frame_samples = rate * frame_ms // 1000

    def decode(self, payload: bytes) -> bytes:
        return self._dec.decode(payload, self._frame_samples)


def make_encoder(codec: str, rate: int, channels: int, bitrate: int, frame_ms: int = 20):
    if codec == "opus":
        return OpusEncoder(rate, channels, bitrate, frame_ms)
    return PcmPassthrough()


def make_decoder(codec: str, rate: int, channels: int, frame_ms: int = 20):
    if codec == "opus":
        return OpusDecoder(rate, channels, frame_ms)
    return PcmPassthrough()

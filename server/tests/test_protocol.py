"""Unit tests for the wire protocol (platform-independent)."""

from desklink import protocol as proto


def test_audio_frame_roundtrip():
    payload = b"\x01\x02\x03\x04abcdef"
    raw = proto.encode_audio_frame(proto.StreamId.PLAYBACK, 123456789, payload)
    frame = proto.decode_audio_frame(raw)
    assert frame.stream_id == proto.StreamId.PLAYBACK
    assert frame.timestamp_us == 123456789
    assert frame.payload == payload


def test_audio_frame_rejects_short():
    import pytest
    with pytest.raises(ValueError):
        proto.decode_audio_frame(b"\x01\x02")


def test_control_roundtrip():
    msg = proto.nowplaying(title="Song", artist="Artist", album="Album", app="Spotify",
                           duration_ms=200000, position_ms=42000, playing=True)
    text = proto.dumps(msg)
    back = proto.loads(text)
    assert back["type"] == "nowplaying"
    assert back["title"] == "Song"
    assert back["playing"] is True
    assert "artwork" not in back  # omitted when None


def test_loads_rejects_non_object():
    import pytest
    with pytest.raises(ValueError):
        proto.loads("[1,2,3]")


def test_negotiate_capabilities_preserves_server_order():
    server = [proto.CAP_PLAYBACK, proto.CAP_MIC, proto.CAP_NOWPLAYING, proto.CAP_TRANSPORT]
    client = [proto.CAP_TRANSPORT, proto.CAP_PLAYBACK]
    assert proto.negotiate_capabilities(server, client) == [proto.CAP_PLAYBACK, proto.CAP_TRANSPORT]


def test_negotiate_codec_fallback_to_pcm():
    # Opus only when server prefers it, lib available, and client asks for opus.
    assert proto.negotiate_codec(True, "opus", True) == "opus"
    assert proto.negotiate_codec(True, "opus", False) == "pcm"
    assert proto.negotiate_codec(True, "pcm", True) == "pcm"
    assert proto.negotiate_codec(False, "opus", True) == "pcm"


def test_hello_shape():
    h = proto.hello(server="PC", session="abc", capabilities=[proto.CAP_PLAYBACK],
                    pairing_required=True, playback={"codec": "opus"}, mic={"codec": "opus"})
    assert h["type"] == "hello"
    assert h["protocol"] == proto.PROTOCOL_VERSION
    assert h["pairing_required"] is True

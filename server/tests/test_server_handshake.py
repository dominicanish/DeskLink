"""Integration tests for the server handshake / capability negotiation.

These exercise ``DeskLinkServer._do_join`` end-to-end with a fake WebSocket, so
they run without a network or audio hardware. ``websockets`` is stubbed when not
installed (e.g. on a minimal dev box) so the import of ``desklink.server``
succeeds; in CI the real package is present and the stub is skipped.
"""

import asyncio
import sys
import types

import pytest

# --- make `import websockets` succeed even if the package isn't installed ---
if "websockets" not in sys.modules:
    try:
        import websockets  # noqa: F401
    except Exception:
        ws_mod = types.ModuleType("websockets")
        ws_mod.ConnectionClosed = type("ConnectionClosed", (Exception,), {})
        ws_mod.serve = lambda *a, **k: None
        server_mod = types.ModuleType("websockets.server")
        server_mod.WebSocketServerProtocol = object
        ws_mod.server = server_mod
        sys.modules["websockets"] = ws_mod
        sys.modules["websockets.server"] = server_mod

from desklink import protocol as proto  # noqa: E402
from desklink.config import ServerConfig  # noqa: E402
from desklink.server import ClientSession, DeskLinkServer  # noqa: E402


class FakeWS:
    """Records text frames sent by the server."""

    def __init__(self):
        self.sent: list[str] = []

    async def send(self, data):
        self.sent.append(data)

    async def close(self):
        self.sent.append('{"closed":true}')


def make_session(server):
    return ClientSession(FakeWS(), server)


def run(coro):
    return asyncio.run(coro)


def test_join_success_negotiates_caps_and_sends_ready():
    cfg = ServerConfig(pairing_required=True, pairing_code="123456")
    server = DeskLinkServer(cfg)
    session = make_session(server)

    join = proto.dumps({
        "type": "join",
        "client": "Maykol's iPhone",
        "pairing_code": "123456",
        "capabilities": [proto.CAP_PLAYBACK, proto.CAP_TRANSPORT, proto.CAP_DYNAMIC_ISLAND],
        "audio": {"playback": {"codec": "opus"}, "mic": {"codec": "opus"}},
    })

    ok = run(server._do_join(session, join))
    assert ok is True

    # The negotiated set is the intersection (server order), and dynamic_island
    # passes through because the server allows it explicitly.
    assert proto.CAP_PLAYBACK in session.caps
    assert proto.CAP_TRANSPORT in session.caps
    assert proto.CAP_DYNAMIC_ISLAND in session.caps
    assert proto.CAP_MIC not in session.caps  # client didn't ask for it

    ready = proto.loads(session.ws.sent[-1])
    assert ready["type"] == "ready"
    assert ready["stream_ids"]["playback"] == int(proto.StreamId.PLAYBACK)
    # Without libopus in the test env, the codec must fall back to pcm.
    assert ready["audio"]["playback"]["codec"] in ("opus", "pcm")


def test_join_wrong_pairing_code_rejected():
    cfg = ServerConfig(pairing_required=True, pairing_code="123456")
    server = DeskLinkServer(cfg)
    session = make_session(server)

    join = proto.dumps({"type": "join", "client": "x", "pairing_code": "000000",
                        "capabilities": [proto.CAP_PLAYBACK]})
    ok = run(server._do_join(session, join))
    assert ok is False
    bye = proto.loads(session.ws.sent[-1])
    assert bye == {"type": "bye", "reason": "unpaired"}


def test_join_requires_join_type():
    cfg = ServerConfig(pairing_required=False)
    server = DeskLinkServer(cfg)
    session = make_session(server)

    ok = run(server._do_join(session, proto.dumps({"type": "hello"})))
    assert ok is False
    assert proto.loads(session.ws.sent[-1])["reason"] == "expected_join"


def test_join_without_pairing_when_disabled():
    cfg = ServerConfig(pairing_required=False)
    server = DeskLinkServer(cfg)
    session = make_session(server)

    join = proto.dumps({"type": "join", "client": "x",
                        "capabilities": [proto.CAP_PLAYBACK, proto.CAP_MIC],
                        "audio": {"playback": {"codec": "pcm"}, "mic": {"codec": "pcm"}}})
    ok = run(server._do_join(session, join))
    assert ok is True
    assert session.playback_codec == "pcm"
    assert proto.CAP_MIC in session.caps


def test_transport_dispatch_calls_provider():
    """`_on_transport` routes actions to the SMTC provider (NullProvider here)."""
    cfg = ServerConfig(pairing_required=False)
    server = DeskLinkServer(cfg)
    calls = []

    class RecordingProvider:
        async def play(self): calls.append("play"); return True
        async def pause(self): calls.append("pause"); return True
        async def toggle(self): calls.append("toggle"); return True
        async def next(self): calls.append("next"); return True
        async def prev(self): calls.append("prev"); return True
        async def seek(self, ms): calls.append(("seek", ms)); return True

    server.smtc = RecordingProvider()
    for action in ("play", "pause", "toggle", "next", "prev"):
        run(server._on_transport({"action": action}))
    run(server._on_transport({"action": "seek", "positionMs": 5000}))
    assert calls == ["play", "pause", "toggle", "next", "prev", ("seek", 5000)]

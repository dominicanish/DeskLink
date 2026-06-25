"""DeskLink asyncio WebSocket server.

Low-latency design notes
------------------------
* ``TCP_NODELAY`` is set on every connection (disable Nagle) so small audio
  frames go out immediately.
* Playback frames are 20 ms (configurable down to 10 ms). The outgoing queue is
  *bounded and drop-oldest*: if the network stalls we throw away stale audio
  instead of building a growing delay — real-time beats completeness for live
  audio.
* Capture → encode → send is a single hop with no resampling on the hot path.
* The phone keeps only a tiny jitter buffer (see the iOS client).
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
import uuid

import websockets
from websockets.server import WebSocketServerProtocol

from . import protocol as proto
from .audio import capture as cap
from .audio import codec
from .audio import playback as play
from .config import FRAME_MS, ServerConfig
from .metadata import smtc

log = logging.getLogger("desklink")

# Bound the outgoing playback backlog. At 20 ms/frame, 5 frames == 100 ms max
# added latency before we start dropping the oldest audio.
MAX_PLAYBACK_BACKLOG = 5


class ClientSession:
    def __init__(self, ws: WebSocketServerProtocol, server: "DeskLinkServer"):
        self.ws = ws
        self.server = server
        self.id = uuid.uuid4().hex[:8]
        self.name = "client"
        self.caps: list[str] = []
        self.playback_codec = "pcm"
        self.mic_codec = "pcm"
        self.output_muted = False
        self.mic_enabled = False
        self.encoder = None
        self.mic_decoder = None
        # drop-oldest queue keeps latency bounded
        self.out: asyncio.Queue[bytes] = asyncio.Queue(maxsize=MAX_PLAYBACK_BACKLOG)

    def wants(self, cap_name: str) -> bool:
        return cap_name in self.caps

    def enqueue_playback(self, frame: bytes) -> None:
        if self.output_muted or not self.wants(proto.CAP_PLAYBACK):
            return
        try:
            self.out.put_nowait(frame)
        except asyncio.QueueFull:
            # Drop the oldest frame to stay real-time.
            with contextlib.suppress(asyncio.QueueEmpty):
                self.out.get_nowait()
            with contextlib.suppress(asyncio.QueueFull):
                self.out.put_nowait(frame)


class DeskLinkServer:
    def __init__(self, config: ServerConfig):
        self.config = config
        self.clients: set[ClientSession] = set()
        self.smtc = smtc.make_provider()
        self._capture: cap.LoopbackCapture | None = None
        self._mic_sink: play.MicPlayback | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._pcm_in: asyncio.Queue[bytes] = asyncio.Queue(maxsize=MAX_PLAYBACK_BACKLOG)

    # ---- lifecycle ----

    async def run(self) -> None:
        self._loop = asyncio.get_running_loop()
        # iOS opens short TCP reachability probes that never send a WebSocket
        # upgrade; that's harmless, so don't dump tracebacks for failed handshakes.
        logging.getLogger("websockets.server").setLevel(logging.CRITICAL)
        await self.smtc.start()
        self._start_capture()

        async with websockets.serve(
            self._handle, self.config.host, self.config.port,
            max_size=None, ping_interval=10, ping_timeout=20,
            compression=None,  # never compress audio; adds latency + CPU
        ):
            tasks = [
                asyncio.create_task(self._playback_pump()),
                asyncio.create_task(self._metadata_pump()),
            ]
            log.info("DeskLink listening on %s:%s", self.config.host, self.config.port)
            try:
                await asyncio.Future()  # run forever
            finally:
                for t in tasks:
                    t.cancel()
                self._stop_capture()

    def _start_capture(self) -> None:
        if not cap.available():
            log.warning("WASAPI loopback capture unavailable (install desklink[windows]); "
                        "playback disabled.")
            return
        self._capture = cap.LoopbackCapture(self._on_pcm_captured)
        self._capture.start()
        log.info("Loopback capture: %d Hz, %d ch", self._capture.rate, self._capture.channels)

    def _stop_capture(self) -> None:
        if self._capture:
            self._capture.stop()
        if self._mic_sink:
            self._mic_sink.stop()

    # ---- capture callback (PortAudio thread) ----

    def _on_pcm_captured(self, pcm: bytes) -> None:
        # Hand raw PCM to the event loop without blocking the audio thread.
        if self._loop is None:
            return
        self._loop.call_soon_threadsafe(self._push_pcm, pcm)

    def _push_pcm(self, pcm: bytes) -> None:
        try:
            self._pcm_in.put_nowait(pcm)
        except asyncio.QueueFull:
            with contextlib.suppress(asyncio.QueueEmpty):
                self._pcm_in.get_nowait()
            with contextlib.suppress(asyncio.QueueFull):
                self._pcm_in.put_nowait(pcm)

    # ---- pumps ----

    async def _playback_pump(self) -> None:
        """Encode each captured PCM frame once per client and fan out."""
        while True:
            pcm = await self._pcm_in.get()
            ts = time.monotonic_ns() // 1000
            for client in list(self.clients):
                if client.output_muted or not client.wants(proto.CAP_PLAYBACK):
                    continue
                try:
                    payload = client.encoder.encode(pcm) if client.encoder else pcm
                except Exception:
                    payload = pcm
                frame = proto.encode_audio_frame(proto.StreamId.PLAYBACK, ts, payload)
                client.enqueue_playback(frame)

    async def _metadata_pump(self) -> None:
        """Poll SMTC and push now-playing + transport state to clients."""
        last_state: tuple | None = None
        while True:
            try:
                np = await self.smtc.poll()
            except Exception as e:  # pragma: no cover
                log.debug("smtc poll failed: %s", e)
                np = None

            if np is not None:
                msg = proto.nowplaying(
                    title=np.title, artist=np.artist, album=np.album, app=np.app,
                    duration_ms=np.duration_ms, position_ms=np.position_ms,
                    playing=np.playing, artwork_b64=np.artwork_jpeg_b64,
                )
                state = (np.can_next, np.can_prev, np.can_seek)
                await self._broadcast_json(msg, cap=proto.CAP_NOWPLAYING)
                if state != last_state:
                    await self._broadcast_json(
                        proto.transport_state(can_next=np.can_next, can_prev=np.can_prev,
                                               can_seek=np.can_seek),
                        cap=proto.CAP_TRANSPORT,
                    )
                    last_state = state
            await asyncio.sleep(1.0)  # position ticks; artwork only on track change

    async def _broadcast_json(self, message: dict, *, cap: str | None = None) -> None:
        text = proto.dumps(message)
        for client in list(self.clients):
            if cap and not client.wants(cap):
                continue
            with contextlib.suppress(Exception):
                await client.ws.send(text)

    # ---- per-connection ----

    async def _handle(self, ws: WebSocketServerProtocol) -> None:
        _set_nodelay(ws)
        session = ClientSession(ws, self)
        await ws.send(proto.dumps(proto.hello(
            server=self.config.name,
            session=session.id,
            capabilities=proto.SERVER_CAPABILITIES,
            pairing_required=self.config.pairing_required,
            playback={"codec": "opus" if codec.opus_available() else "pcm",
                      "rate": 48000, "channels": 2},
            mic={"codec": "opus" if codec.opus_available() else "pcm",
                 "rate": 48000, "channels": 1},
        )))

        # Expect a join message.
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=15)
        except (asyncio.TimeoutError, websockets.ConnectionClosed):
            return
        if not await self._do_join(session, raw):
            return

        self.clients.add(session)
        log.info("client joined: %s (%s) caps=%s", session.name, session.id, session.caps)
        sender = asyncio.create_task(self._client_sender(session))
        try:
            await self._client_receiver(session)
        finally:
            sender.cancel()
            self.clients.discard(session)
            log.info("client left: %s", session.id)

    async def _do_join(self, session: ClientSession, raw) -> bool:
        try:
            msg = proto.loads(raw)
        except ValueError:
            await session.ws.send(proto.dumps(proto.bye("bad_join")))
            return False
        if msg.get("type") != "join":
            await session.ws.send(proto.dumps(proto.bye("expected_join")))
            return False
        if self.config.pairing_required and msg.get("pairing_code") != self.config.pairing_code:
            await session.ws.send(proto.dumps(proto.bye("unpaired")))
            return False

        session.name = str(msg.get("client", "client"))[:64]
        client_caps = msg.get("capabilities", [])
        session.caps = proto.negotiate_capabilities(
            proto.SERVER_CAPABILITIES + [proto.CAP_DYNAMIC_ISLAND], client_caps,
        )
        audio = msg.get("audio", {})
        session.playback_codec = proto.negotiate_codec(
            self.config.prefer_opus, audio.get("playback", {}).get("codec", "pcm"),
            codec.opus_available())
        session.mic_codec = proto.negotiate_codec(
            self.config.prefer_opus, audio.get("mic", {}).get("codec", "pcm"),
            codec.opus_available())

        # Build per-client codecs.
        rate = self._capture.rate if self._capture else 48000
        chans = self._capture.channels if self._capture else 2
        session.encoder = codec.make_encoder(
            session.playback_codec, rate, chans, self.config.music_bitrate, FRAME_MS)
        session.mic_decoder = codec.make_decoder(session.mic_codec, 48000, 1, FRAME_MS)

        await session.ws.send(proto.dumps(proto.ready(
            capabilities=session.caps,
            playback_codec=session.playback_codec,
            mic_codec=session.mic_codec,
        )))
        return True

    async def _client_sender(self, session: ClientSession) -> None:
        while True:
            frame = await session.out.get()
            with contextlib.suppress(Exception):
                await session.ws.send(frame)

    async def _client_receiver(self, session: ClientSession) -> None:
        async for message in session.ws:
            if isinstance(message, bytes):
                await self._on_binary(session, message)
            else:
                await self._on_control(session, message)

    async def _on_binary(self, session: ClientSession, data: bytes) -> None:
        try:
            frame = proto.decode_audio_frame(data)
        except ValueError:
            return
        if frame.stream_id != proto.StreamId.MIC or not session.mic_enabled:
            return
        self._ensure_mic_sink()
        if self._mic_sink is None:
            return
        try:
            pcm = session.mic_decoder.decode(frame.payload) if session.mic_decoder else frame.payload
            self._mic_sink.write(pcm)
        except Exception:
            pass

    def _ensure_mic_sink(self) -> None:
        if self._mic_sink is None and play.available():
            self._mic_sink = play.MicPlayback()
            self._mic_sink.start()

    async def _on_control(self, session: ClientSession, text: str) -> None:
        try:
            msg = proto.loads(text)
        except ValueError:
            return
        t = msg.get("type")
        if t == "transport":
            await self._on_transport(msg)
        elif t == "mic":
            session.mic_enabled = bool(msg.get("enabled"))
            log.info("client %s mic=%s", session.id, session.mic_enabled)
        elif t == "output_mute":
            session.output_muted = bool(msg.get("muted"))
        elif t == "ping":
            await session.ws.send(proto.dumps({"type": "pong", "t": msg.get("t")}))
        elif t == "bye":
            await session.ws.close()

    async def _on_transport(self, msg: dict) -> None:
        action = msg.get("action")
        provider = self.smtc
        if action == "play":
            await provider.play()
        elif action == "pause":
            await provider.pause()
        elif action == "toggle":
            await provider.toggle()
        elif action == "next":
            await provider.next()
        elif action == "prev":
            await provider.prev()
        elif action == "seek":
            await provider.seek(int(msg.get("positionMs", 0)))


def _set_nodelay(ws: WebSocketServerProtocol) -> None:
    import socket as _socket
    try:
        sock = ws.transport.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(_socket.IPPROTO_TCP, _socket.TCP_NODELAY, 1)
    except Exception:
        pass


async def serve(config: ServerConfig) -> None:
    await DeskLinkServer(config).run()

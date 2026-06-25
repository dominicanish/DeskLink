"""Windows System Media Transport Controls (SMTC) integration.

Reads the *system* media session via
``Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager`` —
this aggregates Spotify, Apple Music for Windows, Chrome/Edge media, etc. — so we
get the current title / artist / album / artwork and can forward transport
commands (play / pause / next / prev) to whichever app actually owns playback.

Requires the ``winsdk`` package (``pip install desklink[windows]``). On non-Windows
hosts the module imports but ``available()`` returns False, and a no-op provider
is used so the rest of the server runs.
"""

from __future__ import annotations

import asyncio
import base64
from dataclasses import dataclass

try:
    from winsdk.windows.media.control import (  # type: ignore
        GlobalSystemMediaTransportControlsSessionManager as MediaManager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
    )
    from winsdk.windows.storage.streams import (  # type: ignore
        Buffer,
        InputStreamOptions,
    )
    _AVAILABLE = True
except Exception:  # pragma: no cover - Windows-only dependency
    MediaManager = None  # type: ignore
    PlaybackStatus = None  # type: ignore
    _AVAILABLE = False


def available() -> bool:
    return _AVAILABLE


@dataclass
class NowPlaying:
    title: str = ""
    artist: str = ""
    album: str = ""
    app: str = ""
    duration_ms: int = 0
    position_ms: int = 0
    playing: bool = False
    can_next: bool = False
    can_prev: bool = False
    can_seek: bool = False
    artwork_jpeg_b64: str | None = None  # set only when the track changes


async def _read_thumbnail_b64(media_props) -> str | None:
    ref = getattr(media_props, "thumbnail", None)
    if ref is None:
        return None
    try:
        stream = await ref.open_read_async()
        size = stream.size
        if not size:
            return None
        buf = Buffer(size)
        await stream.read_async(buf, size, InputStreamOptions.READ_AHEAD)
        data = bytes(buf)
        return base64.b64encode(data).decode("ascii")
    except Exception:
        return None


class SmtcProvider:
    """Polls the current SMTC session and exposes NowPlaying + transport control."""

    def __init__(self) -> None:
        self._manager = None
        self._last_track_key: tuple[str, str] | None = None

    async def start(self) -> None:
        if not _AVAILABLE:
            return
        self._manager = await MediaManager.request_async()

    def _current_session(self):
        if self._manager is None:
            return None
        return self._manager.get_current_session()

    async def poll(self) -> NowPlaying | None:
        """Return the current NowPlaying, or None if nothing is playing."""
        session = self._current_session()
        if session is None:
            return None

        props = await session.try_get_media_properties_async()
        playback = session.get_playback_info()
        timeline = session.get_timeline_properties()

        controls = playback.controls
        status = playback.playback_status
        playing = status == PlaybackStatus.PLAYING

        np = NowPlaying(
            title=props.title or "",
            artist=props.artist or "",
            album=props.album_title or "",
            app=session.source_app_user_model_id or "",
            duration_ms=int(timeline.end_time.total_seconds() * 1000),
            position_ms=int(timeline.position.total_seconds() * 1000),
            playing=playing,
            can_next=bool(controls.is_next_enabled),
            can_prev=bool(controls.is_previous_enabled),
            can_seek=bool(controls.is_playback_position_enabled),
        )

        # Only ship artwork when the track actually changes (it's the heavy part).
        track_key = (np.title, np.artist)
        if track_key != self._last_track_key:
            np.artwork_jpeg_b64 = await _read_thumbnail_b64(props)
            self._last_track_key = track_key

        return np

    # --- transport: forwarded to the real app via the SMTC session ---

    async def play(self) -> bool:
        s = self._current_session()
        return bool(s and await s.try_play_async())

    async def pause(self) -> bool:
        s = self._current_session()
        return bool(s and await s.try_pause_async())

    async def toggle(self) -> bool:
        s = self._current_session()
        return bool(s and await s.try_toggle_play_pause_async())

    async def next(self) -> bool:
        s = self._current_session()
        return bool(s and await s.try_skip_next_async())

    async def prev(self) -> bool:
        s = self._current_session()
        return bool(s and await s.try_skip_previous_async())

    async def seek(self, position_ms: int) -> bool:
        s = self._current_session()
        # SMTC playback position is in 100-ns ticks.
        ticks = int(position_ms) * 10_000
        return bool(s and await s.try_change_playback_position_async(ticks))


class NullProvider:
    """Used when SMTC is unavailable so the server still runs."""

    async def start(self) -> None:
        return None

    async def poll(self) -> NowPlaying | None:
        return None

    async def play(self) -> bool: return False
    async def pause(self) -> bool: return False
    async def toggle(self) -> bool: return False
    async def next(self) -> bool: return False
    async def prev(self) -> bool: return False
    async def seek(self, position_ms: int) -> bool: return False


def make_provider():
    return SmtcProvider() if _AVAILABLE else NullProvider()


# Allow `python -m desklink.metadata.smtc` for a quick manual check.
if __name__ == "__main__":  # pragma: no cover
    async def _demo() -> None:
        p = make_provider()
        await p.start()
        np = await p.poll()
        print(np)

    asyncio.run(_demo())

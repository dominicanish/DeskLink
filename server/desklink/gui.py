"""Minimal system-tray "app" version of the DeskLink server.

Runs the asyncio server on a background thread and shows a tray icon with the
pairing code and a Quit item. Requires the ``gui`` extra:

    pip install desklink[gui]
    desklink-tray
"""

from __future__ import annotations

import asyncio
import threading

from . import config as cfg
from .discovery import Advertiser
from .server import serve

try:
    import pystray
    from PIL import Image, ImageDraw
    _AVAILABLE = True
except Exception:  # pragma: no cover
    pystray = None  # type: ignore
    _AVAILABLE = False


def _icon_image():
    # Simple graphite glyph matching branding/logo.svg (two nodes + link).
    img = Image.new("RGBA", (64, 64), (28, 28, 30, 255))
    d = ImageDraw.Draw(img)
    d.ellipse((16, 26, 28, 38), fill=(245, 245, 247, 255))
    d.ellipse((36, 26, 48, 38), fill=(245, 245, 247, 255))
    d.line((24, 32, 40, 32), fill=(245, 245, 247, 255), width=4)
    return img


class _ServerThread(threading.Thread):
    def __init__(self, config: cfg.ServerConfig):
        super().__init__(daemon=True)
        self._config = config
        self._loop: asyncio.AbstractEventLoop | None = None

    def run(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        self._loop.run_until_complete(serve(self._config))

    def stop(self) -> None:
        if self._loop:
            self._loop.call_soon_threadsafe(self._loop.stop)


def main() -> None:
    if not _AVAILABLE:
        raise SystemExit("Tray app needs the gui extra: pip install desklink[gui]")

    config = cfg.ServerConfig()
    advertiser = Advertiser(config.name, config.port)
    ip = advertiser.start()

    server = _ServerThread(config)
    server.start()

    def _on_quit(icon, _item):  # noqa: ANN001
        advertiser.stop()
        server.stop()
        icon.stop()

    menu = pystray.Menu(
        pystray.MenuItem(f"DeskLink — {ip}:{config.port}", None, enabled=False),
        pystray.MenuItem(f"Pairing code: {config.pairing_code}", None, enabled=False),
        pystray.MenuItem("Quit", _on_quit),
    )
    pystray.Icon("DeskLink", _icon_image(), "DeskLink", menu).run()


if __name__ == "__main__":
    main()

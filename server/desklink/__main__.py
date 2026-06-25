"""DeskLink terminal entry point.

    desklink                 # start with defaults
    desklink --port 9000     # custom port
    desklink --no-pairing    # skip the pairing code (open LAN)
    desklink --low-latency   # 10 ms frames (lower delay, a bit more overhead)
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal

from . import __version__, config as cfg
from .audio import codec
from .discovery import Advertiser
from .server import serve


def _install_vmic() -> None:
    """Install (or confirm) the VB-CABLE virtual microphone, then report status."""
    from .audio import vmic
    try:
        import pyaudiowpatch as pyaudio  # type: ignore
    except Exception:
        print("PyAudioWPatch isn't installed. Run the server once (or pip install desklink[windows]).")
        return

    pa = pyaudio.PyAudio()
    if vmic.installed(pa):
        print(f'Virtual mic already installed. Select "{vmic.CABLE_CAPTURE_NAME}" as the microphone in your PC app.')
        pa.terminate()
        return
    pa.terminate()

    print("Installing the VB-CABLE virtual microphone (you'll get a Windows UAC prompt)…")
    if not vmic.install():
        print("Install did not complete. See the messages above.")
        return

    pa = pyaudio.PyAudio()
    ok = vmic.installed(pa)
    pa.terminate()
    if ok:
        print(f'\nDone. In your PC app, choose "{vmic.CABLE_CAPTURE_NAME}" as the microphone,')
        print("then enable the mic in the DeskLink phone app.")
    else:
        print("\nThe cable isn't visible yet — a reboot may be required, then re-run with --install-vmic.")


def _banner(c: cfg.ServerConfig, ip: str) -> None:
    codec_name = "Opus (low-latency)" if codec.opus_available() else "PCM (install opus extra)"
    pairing = c.pairing_code if c.pairing_required else "disabled (open LAN)"
    print("")
    print("==================== DeskLink " + __version__ + " ====================")
    print(f"  Server name : {c.name}")
    print(f"  Address     : {ip}:{c.port}")
    print("  Bonjour     : auto-discovered on your iPhone")
    print(f"  Audio codec : {codec_name}")
    print(f"  Pairing code: {pairing}")
    print("=========================================================")
    print("Open the DeskLink app on your iPhone (same Wi-Fi). Ctrl+C to stop.")
    print("")


def main() -> None:
    parser = argparse.ArgumentParser(prog="desklink", description="DeskLink PC audio server")
    parser.add_argument("--port", type=int, default=cfg.DEFAULT_PORT)
    parser.add_argument("--name", default=None, help="server name shown to clients")
    parser.add_argument("--no-pairing", action="store_true", help="disable the pairing code")
    parser.add_argument("--low-latency", action="store_true", help="use 10 ms audio frames")
    parser.add_argument("--no-opus", action="store_true", help="force raw PCM")
    parser.add_argument("--install-vmic", action="store_true",
                        help="install the VB-CABLE virtual microphone driver, then exit")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S",
    )

    if args.install_vmic:
        _install_vmic()
        return

    if args.low_latency:
        cfg.FRAME_MS = 10  # type: ignore[attr-defined]

    c = cfg.ServerConfig(port=args.port, pairing_required=not args.no_pairing)
    if args.name:
        c.name = args.name
    if args.no_opus:
        c.prefer_opus = False

    advertiser = Advertiser(c.name, c.port)
    ip = advertiser.start()
    _banner(c, ip)

    async def _amain() -> None:
        stop = asyncio.Event()

        def _request_stop(*_: object) -> None:
            stop.set()

        try:
            signal.signal(signal.SIGINT, _request_stop)
            signal.signal(signal.SIGTERM, _request_stop)
        except (ValueError, AttributeError):
            pass

        server_task = asyncio.create_task(serve(c))
        await stop.wait()
        server_task.cancel()

    try:
        asyncio.run(_amain())
    except KeyboardInterrupt:
        pass
    finally:
        advertiser.stop()
        print("DeskLink stopped.")


if __name__ == "__main__":
    main()

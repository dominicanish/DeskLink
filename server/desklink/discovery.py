"""Advertise the DeskLink server over Bonjour/mDNS so the iPhone finds it
automatically (no IP typing)."""

from __future__ import annotations

import socket

from zeroconf import ServiceInfo, Zeroconf

from .config import SERVICE_TYPE


def _primary_ipv4() -> str:
    """Best-effort local LAN IPv4 (no traffic actually sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class Advertiser:
    def __init__(self, name: str, port: int):
        self._zc: Zeroconf | None = None
        self._info: ServiceInfo | None = None
        self._name = name
        self._port = port

    def start(self) -> str:
        ip = _primary_ipv4()
        safe = self._name.replace(".", "-")
        self._info = ServiceInfo(
            SERVICE_TYPE,
            name=f"{safe}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(ip)],
            port=self._port,
            properties={"v": "1", "name": self._name},
            server=f"{safe}.local.",
        )
        self._zc = Zeroconf()
        self._zc.register_service(self._info)
        return ip

    def stop(self) -> None:
        if self._zc and self._info:
            try:
                self._zc.unregister_service(self._info)
            finally:
                self._zc.close()
        self._zc = None
        self._info = None

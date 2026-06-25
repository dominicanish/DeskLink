"""Virtual microphone support via VB-CABLE (a free, Microsoft-signed virtual
audio cable from VB-Audio).

A real virtual *microphone* on Windows needs a signed kernel audio driver — you
can't synthesise an input endpoint from user space. VB-CABLE provides exactly
that, already signed, so we route through it instead of shipping our own driver:

    phone mic  ->  DeskLink  ->  "CABLE Input"  ===(virtual cable)===>  "CABLE Output"  ->  any PC app

DeskLink renders the phone mic into the **CABLE Input** playback endpoint; PC
apps (Google Translate, Zoom, Discord, …) then pick **CABLE Output** as their
microphone. This module finds the cable and can download + install it.
"""

from __future__ import annotations

import logging
import os
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

log = logging.getLogger("desklink.vmic")

# We write the phone mic into this render endpoint…
CABLE_RENDER_NAME = "CABLE Input"
# …and PC apps read from this capture endpoint.
CABLE_CAPTURE_NAME = "CABLE Output"

# Official VB-Audio driver pack (free for personal use). Pinned; bump if VB-Audio
# releases a newer pack and this 404s.
_DRIVER_PACK_URL = "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip"

try:
    import pyaudiowpatch as _pa  # type: ignore
except Exception:  # pragma: no cover
    _pa = None  # type: ignore


def _wasapi_index(pa) -> int | None:
    if _pa is None:
        return None
    try:
        return pa.get_host_api_info_by_type(_pa.paWASAPI)["index"]
    except Exception:
        return None


def find_render_device_index(pa) -> int | None:
    """Index of the CABLE Input render endpoint (WASAPI preferred), or None."""
    wasapi = _wasapi_index(pa)
    best: tuple[bool, int] | None = None
    for i in range(pa.get_device_count()):
        d = pa.get_device_info_by_index(i)
        name = d.get("name", "")
        if (CABLE_RENDER_NAME.lower() in name.lower()
                and d.get("maxOutputChannels", 0) > 0
                and "loopback" not in name.lower()):
            prefer = d.get("hostApi") == wasapi
            if best is None or (prefer and not best[0]):
                best = (prefer, i)
    return best[1] if best else None


def installed(pa) -> bool:
    """True if the VB-CABLE virtual device is present."""
    return find_render_device_index(pa) is not None


def install() -> bool:
    """Download VB-CABLE and run its installer (elevated via UAC).

    Returns True if the installer was launched. The cable usually appears
    immediately (no reboot). Windows-only.
    """
    if sys.platform != "win32":
        log.error("Virtual-mic install is Windows-only.")
        return False
    try:
        tmp = tempfile.mkdtemp(prefix="desklink_vbcable_")
        zip_path = os.path.join(tmp, "vbcable.zip")
        log.info("Downloading VB-CABLE driver pack…")
        urllib.request.urlretrieve(_DRIVER_PACK_URL, zip_path)
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(tmp)
        setup = os.path.join(tmp, "VBCABLE_Setup_x64.exe")
        if not os.path.exists(setup):
            log.error("VBCABLE_Setup_x64.exe not found in the driver pack.")
            return False
        log.info("Launching the VB-CABLE installer — approve the Windows (UAC) prompt.")
        # Elevate via PowerShell; '-i' runs the install. Wait so we can re-check after.
        subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
             f"Start-Process -FilePath '{setup}' -ArgumentList '-i' -Verb RunAs -Wait"],
            check=False,
        )
        return True
    except Exception as e:
        log.error("VB-CABLE install failed: %s", e)
        return False

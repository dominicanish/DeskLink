# DeskLink server (Windows)

Captures your PC's system audio and streams it to DeskLink clients over Wi-Fi,
exposes now-playing metadata + transport controls (via Windows SMTC), and plays
back the phone's microphone.

## Install & run (one click)

Double-click **`run.bat`** (or right-click **`run.ps1`** → Run with PowerShell).
It creates a virtualenv, installs everything, and starts the server.

## Install & run (manual)

```powershell
cd server
python -m venv .venv
.venv\Scripts\activate
pip install -e ".[windows,opus]"
desklink
```

You'll see the address, Bonjour status, and a 6-digit pairing code. Open the
DeskLink app (or `tools/webtest/index.html` in a browser) on the same Wi-Fi.

## Options

```
desklink                 start with defaults (Opus, pairing on)
desklink --low-latency   10 ms frames (lowest delay)
desklink --no-opus       raw PCM (zero codec delay; needed for the web test client)
desklink --no-pairing    open LAN, no code
desklink --port 9000     custom port
desklink --name "Studio" custom server name
desklink -v              verbose logging
```

Tray app (optional): `pip install -e ".[gui]"` then `desklink-tray`.

## Quick test from a browser (no iPhone needed)

1. Run the server with PCM so the browser can decode it:

   ```powershell
   desklink --no-opus --no-pairing
   ```

2. On any device on the same Wi-Fi, open `tools/webtest/index.html` and enter the
   address shown by the server (e.g. `192.168.1.50:8765`). You should hear your PC
   audio and see the now-playing info + working transport buttons.

## What needs which dependency

| Feature                       | Dependency                         | Without it |
|-------------------------------|------------------------------------|------------|
| Stream system audio           | `PyAudioWPatch` (Windows)          | playback disabled, control still works |
| Now playing + transport       | `winsdk` (Windows)                 | no metadata; transport no-ops |
| Low-latency Opus              | `opuslib` (+ libopus)              | falls back to PCM automatically |
| Tray app                      | `pystray`, `Pillow`                | use the CLI instead |

The server runs even if optional parts are missing — it logs a warning and
disables just that capability (everything is capability-negotiated).

## Tests

```powershell
pip install pytest
pytest -q
```

## Troubleshooting

- **iPhone/browser can't find the PC** — same Wi-Fi? Allow Python through the
  Windows Firewall (Private networks). Some routers block mDNS; you can still
  type the IP shown by the server manually.
- **No audio / silence** — make sure something is actually playing on the PC; the
  loopback captures the *default* output device. Switch outputs and restart.
- **Web client warns about Opus** — restart with `desklink --no-opus` (the browser
  test client decodes PCM only; the native iOS app handles Opus).
- **Stutter** — prefer 5 GHz Wi-Fi; try `--low-latency` off (default 20 ms is more
  robust than 10 ms on congested networks).

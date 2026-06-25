# DeskLink

Stream your **Windows PC audio to your iPhone over Wi-Fi**, with two-way audio
(PC speaker out → iPhone, iPhone mic → PC), live "Now Playing" metadata
(title, artist, album art) pulled from whatever app is playing on the PC
(Spotify, Apple Music, browsers, …), Dynamic Island integration, and transport
controls (play / pause / next / previous) that travel from the phone back to the PC.

> Status: **early scaffold / work in progress.** The architecture, protocol,
> Windows server, iOS client, and CI build are all in place. Some audio paths
> are functional and others are clearly marked as TODO. See
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for what is and isn't wired up.

## What it does (by capability)

DeskLink negotiates a **capability set** when a client connects, so each device
only gets the features its environment supports.

| Capability        | Description                                                        | Wi-Fi |
|-------------------|--------------------------------------------------------------------|:-----:|
| `audio.playback`  | PC system audio streamed to the device                             |  ✅   |
| `audio.mic`       | Device microphone captured and sent back to the PC                 |  ✅   |
| `meta.nowplaying` | Title / artist / album art of the PC's active media session       |  ✅   |
| `transport`       | play / pause / next / previous forwarded to the PC's media session |  ✅   |
| `dynamic_island`  | Live Activity + system Now Playing on supported iPhones            |  ✅   |

USB and Bluetooth are intentionally **not** in v1: a sideloaded iOS app cannot
get raw USB audio without the MFi program, and it cannot drive Bluetooth A2DP
sink behavior from app code. Wi-Fi (with Bonjour auto-discovery) is the
transport. The protocol is transport-agnostic, so a future USB/BLE backend can
be added without touching the app logic.

## Repository layout

```
DeskLink/
├── server/            Python Windows server (CLI + tray app)
│   └── desklink/
│       ├── audio/     WASAPI loopback capture, Opus codec, mic playback
│       ├── metadata/  Windows.Media.Control (SMTC) now-playing + transport
│       ├── server.py  asyncio WebSocket server
│       └── discovery.py  Bonjour/mDNS advertising
├── ios/               SwiftUI client + Widget extension (Live Activity)
│   ├── DeskLink/
│   └── DeskLinkWidget/
├── docs/              ARCHITECTURE, PROTOCOL, INSTALL_IOS
├── branding/          Logo (Apple-flavored, minimal)
└── .github/workflows/ CI: build unsigned IPA + lint server
```

## Quick start (PC server)

Windows 10/11, Python 3.10+:

```powershell
cd server
python -m venv .venv
.venv\Scripts\activate
pip install -e .
desklink            # starts the server + prints the QR/address to connect
```

Then open the DeskLink app on your iPhone (same Wi-Fi network); it discovers the
PC automatically via Bonjour. See [`docs/INSTALL_IOS.md`](docs/INSTALL_IOS.md)
for building and sideloading the app with AltStore / SideStore.

## Test the server today (no iPhone needed)

You can verify the PC server from any browser on the same Wi-Fi before the iOS
app is built. Run the server in PCM mode and open the web test client:

```powershell
cd server
desklink --no-opus --no-pairing
```

Then open `tools/webtest/index.html` and enter the address the server printed
(e.g. `192.168.1.50:8765`). You should hear your PC audio and see live
now-playing info with working transport buttons.

## iOS app

The app is built **in the cloud by GitHub Actions** (you don't need a Mac).
Every push produces an **unsigned `.ipa`** as a build artifact, ready to sideload
with AltStore / SideStore using a free Apple ID. Details in
[`docs/INSTALL_IOS.md`](docs/INSTALL_IOS.md).

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — components, what's wired up vs TODO.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — the wire protocol (handshake, control, audio framing).
- [`docs/LATENCY.md`](docs/LATENCY.md) — the real-time / low-delay strategy and tuning knobs.
- [`docs/INSTALL_IOS.md`](docs/INSTALL_IOS.md) — building & sideloading the iPhone app (no Mac).
- [`docs/PUSH_TO_GITHUB.md`](docs/PUSH_TO_GITHUB.md) — get this repo onto GitHub so CI builds the IPA.

## License

MIT — see [`LICENSE`](LICENSE).

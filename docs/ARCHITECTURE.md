# DeskLink — Architecture

## High-level

```
┌─────────────────────────────── Windows PC ───────────────────────────────┐
│                                                                           │
│  Any media app (Spotify / Apple Music / browser / game)                   │
│         │ system audio                  │ SMTC media session              │
│         ▼                               ▼                                 │
│   WASAPI loopback   ┌──────────────────────────────┐   Windows.Media.     │
│   capture ─────────▶│         DeskLink server       │◀── Control (SMTC)    │
│                     │  (Python, asyncio)            │   now-playing +      │
│   default render ◀──│                               │   transport control  │
│   (play phone mic)  └──────────────┬───────────────┘                      │
│                                    │                                       │
│              Bonjour advert  ◀─────┤  WebSocket (control + audio)          │
└────────────────────────────────────┼──────────────────────────────────────┘
                                     │  Wi-Fi (LAN)
┌────────────────────────────────────┼──────────────────────────────────────┐
│                                    ▼                              iPhone   │
│   NWBrowser (Bonjour) ──▶ discovers PC ──▶ URLSessionWebSocketTask         │
│                                                                           │
│   ┌─ AudioEngine ──────────────────────────────────────────────────────┐ │
│   │  decode Opus ─▶ play   |   capture mic ─▶ encode Opus ─▶ send to PC │ │
│   └────────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│   MPNowPlayingInfoCenter + MPRemoteCommandCenter  ──▶ Dynamic Island       │
│   ActivityKit Live Activity (album art)                                    │
│   Transport buttons ──▶ control channel ──▶ PC media session                │
└───────────────────────────────────────────────────────────────────────────┘
```

## Components

### Server (Python, Windows)

| Module                       | Responsibility                                                              | State |
|------------------------------|----------------------------------------------------------------------------|-------|
| `desklink/server.py`         | asyncio WebSocket server, per-client session, capability negotiation        | ✅ working |
| `desklink/discovery.py`      | Advertise `_desklink._tcp.` over Bonjour/mDNS (zeroconf)                     | ✅ working |
| `desklink/protocol.py`       | Message schema + (de)serialization (control JSON, audio binary frames)      | ✅ working |
| `desklink/audio/capture.py`  | WASAPI **loopback** capture of system output                                | ✅ working (needs `pyaudiowpatch`) |
| `desklink/audio/playback.py` | Play the iPhone mic stream on the PC's default render device                | ✅ working |
| `desklink/audio/codec.py`    | Opus encode/decode (falls back to raw PCM if `opuslib` missing)             | ✅ working |
| `desklink/metadata/smtc.py`  | Windows.Media.Control now-playing (title/artist/thumbnail) + send transport | ✅ working (needs `winsdk`) |
| `desklink/gui.py`            | Minimal system-tray app (start/stop, show clients) — the "app" version      | ⚙️ optional |
| `desklink/__main__.py`       | CLI entry — the "terminal" version                                          | ✅ working |

The server is fully **capability-driven**: it advertises what it supports in the
`hello` handshake, the client replies with what *it* wants, and only the
intersection is activated.

### iOS client (SwiftUI)

| File                                   | Responsibility                                                  | State |
|----------------------------------------|----------------------------------------------------------------|-------|
| `Networking/Discovery.swift`           | Bonjour `NWBrowser` to find DeskLink servers                   | ✅ |
| `Networking/DeskLinkClient.swift`      | WebSocket client, handshake, control + audio routing            | ✅ |
| `Networking/Protocol.swift`            | Swift mirror of `protocol.py` message types                     | ✅ |
| `Audio/AudioEngine.swift`              | `AVAudioEngine` playback + mic capture, Opus via `OpusKit`      | ⚙️ playback ✅ / Opus decode stubbed |
| `LiveActivity/NowPlaying.swift`        | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`              | ✅ |
| `LiveActivity/DeskLinkActivity.swift`  | ActivityKit attributes for Dynamic Island                       | ✅ |
| `DeskLinkWidget/`                      | Widget extension rendering the Live Activity / Dynamic Island   | ✅ |
| `Views/*.swift`                        | Liquid Glass UI (connect, player, mic toggle)                   | ✅ |

## Audio format

- **Sample rate:** 48 kHz, **stereo**, for PC→phone playback.
- **Mic (phone→PC):** 48 kHz **mono**.
- **Codec:** Opus, 20 ms frames, ~96 kbps for music, ~32 kbps for the mic.
  Opus is chosen for low latency (≈26 ms algorithmic) and resilience. If the
  Opus library is unavailable on either end, both sides fall back to raw
  little-endian 16-bit PCM (negotiated in the handshake).
- **Framing:** each audio frame is a binary WebSocket message:
  `[1 byte stream-id][8 byte little-endian timestamp µs][opus/pcm payload]`.

## Now Playing & Dynamic Island

The phone never needs to know which PC app is playing. The server reads the
**system** media session via SMTC (`GlobalSystemMediaTransportControlsSessionManager`),
which aggregates Spotify, Apple Music for Windows, Chrome/Edge media, etc. It
forwards `{title, artist, album, durationMs, positionMs, artwork}` over the
control channel. The phone feeds this into `MPNowPlayingInfoCenter`, which makes
the iOS system show it in the **Dynamic Island** and on the Lock Screen for free,
and a custom **ActivityKit Live Activity** renders the album art in the expanded
island. Transport button presses (`MPRemoteCommandCenter`) are sent back to the
server, which calls `TryPlayAsync` / `TryPauseAsync` / `TrySkipNextAsync` /
`TrySkipPreviousAsync` on the SMTC session — so the real PC app responds.

`next`/`previous` are best-effort (the server reports per-session whether the
controls are enabled); `pause`/`play` are always honored.

## Transport security note

v1 uses a plain WebSocket on the LAN plus a short pairing code shown by the
server and entered/confirmed on the phone (prevents a random device on the
network from connecting). TLS with a self-signed cert pinned at pairing time is
a planned upgrade (`docs/PROTOCOL.md` reserves the fields).

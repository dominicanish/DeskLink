# DeskLink — Handoff to Claude Code

## Status — 2026-06-25 (Claude Code session)

Reference projects live at `C:\Users\dominicanish\streamer` (Node.js PC server)
and `C:\Users\dominicanish\streamer-app` (Expo RN + native Swift audio module) —
*one level above* this repo, not inside it.

Diagnosed all four bugs (server verified empirically on this Windows box; iOS
fixed by inspection — **still needs a device/CI build to confirm**):

1. **Audio noise — server capture is CLEAN.** Verified: silence → all-zero PCM,
   440 Hz tone → clean sine, 48 kHz/2ch/3840-byte 20 ms frames. The noise is the
   **iOS playback path**: it used `AVAudioPlayerNode + scheduleBuffer` with *no
   jitter buffer* (constant underruns on Wi-Fi). **Fixed** by porting the proven
   `streamer-app` receiver: `AVAudioSourceNode` + float ring buffer + ~100 ms
   pre-roll (`ios/.../Audio/AudioEngine.swift`). *Needs device test.*
2. **Stuck on "Connecting…"** — SwiftUI does not observe *nested* ObservableObjects.
   Views read `model.client.state` but only subscribe to `AppModel`. **Fixed** by
   forwarding `client`/`discovery` `objectWillChange` → `AppModel` (`AppModel.swift`).
3. **Bonjour unreliable / "appears only after manual attempt"** — same nested-
   observation bug (list found but UI didn't redraw) + no recovery from the
   Local-Network-permission startup race. **Fixed**: observation forwarding +
   `NWBrowser` restart on `.failed` (`Discovery.swift`). Info.plist keys were
   already correct.
4. **Now-playing empty** — TWO server bugs (both **fixed + verified**):
   (a) PortAudio's WASAPI init put the event-loop thread in a COM **STA** apartment
   with no message pump, so WinRT/SMTC `poll()` **hung forever** → nothing sent.
   Fix: claim **MTA** before capture (`_init_com_mta` in `server.py`).
   (b) Artwork only shipped on track *change*, so clients joining mid-track never
   got album art. Fix: cache the full now-playing snapshot (with artwork) +
   transport state and replay to each client on join.

Verified server-side with a Python client that mimics the iOS handshake: hello →
join → ready, audio frames (3840 B), and `nowplaying` with `artwork_len=30536` +
`transport_state` delivered immediately on join.

Note: env is now Python **3.14** + websockets **16** (legacy `WebSocketServerProtocol`
deprecation warning — still works; worth migrating later).

## What I want you to do

DeskLink streams **Windows PC audio to an iPhone over Wi-Fi** (plus mic return,
now-playing metadata, transport controls, Dynamic Island). The scaffold in this
repo builds and *connects*, but several core things don't work (see "Failing"
below).

I have **two reference projects in the folders `streamer` and `streamer-app`
that actually work** (a PC audio streamer and its iOS client). **Your main task
is to port the proven, working approach from `streamer` / `streamer-app` into
DeskLink**, fixing the bugs below, while keeping DeskLink's product features
(Liquid Glass UI, Dynamic Island / Live Activity, capability negotiation,
now-playing with album art, mic toggle, output mute).

Start by reading `streamer` and `streamer-app` end to end and comparing them to
DeskLink's `server/` (Python) and `ios/` (SwiftUI). Prefer adopting their audio
capture/encode/transport and their iOS receive/playback/connection code over
debugging mine. If their protocol differs, align both ends to whatever they do
(it's known-good) and keep DeskLink's extra control messages on top.

## Failing right now (in priority order)

1. **Audio is noise.** The phone plays loud noise even when the PC is playing
   nothing (should be silence). So either the captured audio is the wrong device
   or wrong sample format, or the phone-side playback is misinterpreting the
   bytes. This is the #1 thing to fix. `streamer`/`streamer-app` get this right —
   match their capture format, framing, and playback exactly.

2. **iOS UI gets stuck on "Connecting…"** even when it has connected and audio is
   flowing. The state machine / view never reliably switches to the player. The
   Bonjour-discovery connection path is especially unreliable; manual-IP is the
   only path that sometimes works.

3. **Bonjour auto-discovery is unreliable** — the PC only appears in the list
   *after* a failed manual connection (looks like iOS Local Network permission
   timing).

4. **Now-playing metadata never updates on the client** (title/artist/artwork
   stay empty), even though the transport buttons (play/pause/next/prev) DO work
   and control the real PC app. So the SMTC read or the now-playing message path
   is broken on the server, or the client doesn't render it.

## Architecture of the current (DeskLink) code

- **Server** (`server/`, Python 3, Windows): `desklink/`
  - `audio/capture.py` — WASAPI loopback via **PyAudioWPatch** (just changed to
    capture float32 and convert to s16le; noise persists, so revisit).
  - `audio/codec.py` — Opus (opuslib) with raw-PCM fallback. Phone currently
    negotiates **PCM** (no Opus on the client yet), so the server sends raw
    s16le 48 kHz stereo.
  - `metadata/smtc.py` — Windows.Media.Control (**winsdk**) for now-playing +
    transport. Transport works; now-playing read seems to fail/return empty.
  - `server.py` — asyncio **websockets** server, capability handshake, audio
    fan-out, metadata pump.
  - `discovery.py` — **zeroconf** advertising `_desklink._tcp`.
  - `__main__.py` — CLI (`desklink`), flags: `--no-pairing`, `--no-opus`,
    `--low-latency`, `--port`, `--name`, `-v`.
- **iOS** (`ios/`, SwiftUI, **iOS 26**, Liquid Glass): `DeskLink/`
  - `Networking/DeskLinkClient.swift` — **URLSessionWebSocketTask** client
    (switched from NWConnection, which sent 0-byte handshakes). ATS exception
    `NSAllowsLocalNetworking` is set so `ws://` to LAN works.
  - `Networking/Discovery.swift` — Bonjour `NWBrowser`.
  - `Audio/AudioEngine.swift` — `AVAudioEngine` playback (s16le→float convert),
    mic capture. Session is `.playback`, upgrades to `.playAndRecord` for mic.
  - `LiveActivity/` — `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` +
    ActivityKit Live Activity (Dynamic Island).
  - `Views/` — Liquid Glass UI (discovery, pairing, manual-IP, player).
  - `DeskLinkWidget/` — Widget extension for the Live Activity.

## Protocol (DeskLink — change if `streamer` differs)

One WebSocket. **Text frames = JSON control**, **binary frames = audio**:
`[stream_id:u8][timestamp_us:u64 LE][payload]`, stream 1 = PC→phone playback,
2 = phone→PC mic. Audio is **s16le, 48 kHz, stereo** (playback) / mono (mic),
20 ms frames. Handshake: server `hello` (capabilities + pairing flag) → client
`join` (pairing code + wanted caps) → server `ready` (negotiated set). Control
messages: `nowplaying`, `transport`, `transport_state`, `mic`, `output_mute`,
`ping`/`pong`, `bye`. See `docs/PROTOCOL.md`.

## Build / run constraints (important)

- **I do not own a Mac.** The iOS app is built by **GitHub Actions** on the
  `macos-26` runner (Xcode 26, needed for Liquid Glass). It uses **XcodeGen**
  (`ios/project.yml`) and produces an **unsigned IPA** artifact that I sideload
  with **SideStore** (free Apple ID). So: no Xcode locally, no signing locally.
  Workflow: `.github/workflows/ios-build.yml`. Keep this build path working; if
  you change the iOS file layout, update `ios/project.yml` accordingly.
- The PC server runs on **Windows** (Python 3.13 currently; `winsdk`/
  `PyAudioWPatch` wheels must exist for that version — if not, note it).
- Iteration loop is slow (push → CI builds IPA → I download + reinstall). Please
  batch fixes and reason carefully rather than relying on rebuilds to test iOS.
- A **browser web test client** exists at `tools/webtest/index.html` that does
  the same handshake and plays the PCM stream — use it to validate the *server*
  audio/metadata independently of the phone (run server with `--no-opus`).

## Things already tried (don't redo blindly)

- iOS WebSocket: NWConnection sent 0-byte handshakes (server logged
  "did not receive a valid HTTP request"); switched to URLSessionWebSocketTask +
  `NSAllowsLocalNetworking`. Connection now succeeds, but UI still stalls and
  audio is noise.
- Windows Firewall opened for TCP 8765 and UDP 5353 (mDNS) — connections do
  reach the server now.
- Server bundle/Info.plist: added `CFBundleIdentifier`/version keys (archive
  was failing without them).
- Capture: switched from `paInt16` to `paFloat32` + numpy→int16 — noise
  persists, so the real cause may be the wrong loopback device or the iOS
  playback path. Check what `streamer` does.

## Definition of done

- Play music on the PC → iPhone plays it **clearly** (no noise), reasonably low
  latency; silence is silent.
- Connect via manual IP **and** Bonjour; UI reliably shows the player when
  connected and an error (not an infinite spinner) when it can't.
- Now-playing (title/artist/artwork) shows on the phone and in the Dynamic
  Island; transport buttons keep working.
- Mic toggle streams the iPhone mic to the PC.
- iOS still builds via the existing GitHub Actions / XcodeGen path.

Read `streamer` and `streamer-app` first, then adapt. Thanks!

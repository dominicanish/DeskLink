# DeskLink Protocol v1

A single **WebSocket** connection carries two kinds of messages:

- **Text frames** → JSON control messages (handshake, metadata, transport, mic state).
- **Binary frames** → audio (see framing below).

The server listens on TCP (default **`:8765`**) and advertises itself over
Bonjour as `_desklink._tcp.` with TXT records `v=1`, `name=<host>`.

## 1. Handshake & capabilities

On connect, the **server** sends `hello`:

```json
{
  "type": "hello",
  "protocol": 1,
  "server": "MAYKOL-PC",
  "session": "9f3c…",
  "pairing_required": true,
  "capabilities": ["audio.playback", "audio.mic", "meta.nowplaying", "transport"],
  "audio": { "playback": {"codec": "opus", "rate": 48000, "channels": 2},
             "mic":      {"codec": "opus", "rate": 48000, "channels": 1} }
}
```

The **client** replies with `join`, echoing the subset it wants plus the pairing
code (if `pairing_required`):

```json
{
  "type": "join",
  "client": "Maykol's iPhone",
  "pairing_code": "428913",
  "capabilities": ["audio.playback", "audio.mic", "meta.nowplaying", "transport", "dynamic_island"],
  "audio": { "playback": {"codec": "opus"}, "mic": {"codec": "pcm"} }
}
```

The server answers `ready` with the **negotiated** set (intersection, plus a
per-stream agreed codec — if either side lacks Opus, that stream becomes `pcm`):

```json
{ "type": "ready",
  "capabilities": ["audio.playback", "audio.mic", "meta.nowplaying", "transport"],
  "audio": { "playback": {"codec": "opus"}, "mic": {"codec": "pcm"} },
  "stream_ids": { "playback": 1, "mic": 2 } }
```

## 2. Control messages (text / JSON)

| `type`            | Direction | Payload                                                                 |
|-------------------|-----------|-------------------------------------------------------------------------|
| `nowplaying`      | S → C     | `{title, artist, album, app, durationMs, positionMs, playing, artwork?}`. `artwork` is base64 JPEG (sent once per track change, omitted on position ticks). |
| `transport`       | C → S     | `{action: "play"\|"pause"\|"toggle"\|"next"\|"prev"\|"seek", positionMs?}` |
| `transport_state` | S → C     | `{canNext, canPrev, canSeek}` — lets the client enable/disable buttons   |
| `mic`             | C → S     | `{enabled: true\|false}` — start/stop sending mic frames                  |
| `output_mute`     | C → S     | `{muted: true\|false}` — client stops *playing* PC audio (server may pause sending to save bandwidth) |
| `ping` / `pong`   | both      | `{t}` keepalive / RTT measurement                                        |
| `bye`             | both      | `{reason}`                                                               |

`output_mute` is deliberately distinct from `transport: pause`:
muting only silences playback **on this device**, while `pause` pauses the actual
media on the PC for everyone.

## 3. Audio frames (binary)

Each binary WebSocket message:

```
byte 0      : stream id   (1 = playback PC→phone, 2 = mic phone→PC)
bytes 1..8  : timestamp, microseconds, uint64 little-endian
bytes 9..   : payload (one Opus packet, or raw PCM s16le for the fallback)
```

- Playback frames flow **S → C** only while the client is joined with
  `audio.playback` and not `output_mute`d.
- Mic frames flow **C → S** only while the client has sent `mic {enabled:true}`.
- 20 ms per frame. Opus packets are self-delimiting; PCM frames are
  `rate * channels * 2 * 0.02` bytes.

## 4. Pairing

If `pairing_required`, the server prints/shows a 6-digit code. The client must
include it in `join`. Wrong/absent code → server closes with `bye{reason:"unpaired"}`.
The code rotates each server start. (TLS + cert pinning reserved for v2 via an
optional `tls_fingerprint` field in `hello`.)

## 5. Versioning

`protocol` is an integer. A client and server proceed only if they share the
same major version; otherwise the server sends `bye{reason:"version"}`.

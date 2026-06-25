# DeskLink — Latency strategy

Goal: as close to real-time as Wi-Fi allows. Below is the end-to-end budget and
every decision made to keep delay down. There's no single "no delay" switch in
networked audio — latency is the sum of many small buffers, so DeskLink keeps
each one as small as is safe and **drops audio instead of letting delay grow**.

## End-to-end budget (typical, good Wi-Fi)

| Stage                                   | Target      | Notes |
|-----------------------------------------|-------------|-------|
| PC capture buffer (WASAPI loopback)     | ~10–20 ms   | one frame |
| Opus encode                             | ~3 ms       | algorithmic + compute |
| Server → phone over Wi-Fi               | ~3–15 ms    | LAN RTT/2, varies with congestion |
| Phone jitter buffer                     | ~20–40 ms   | smallest that avoids dropouts |
| Opus decode + AVAudioEngine output      | ~10–15 ms   | ~5 ms IO buffer + mixer |
| **Total (one-way, PC → ear)**           | **~50–90 ms** | music-grade; great for video sync is harder |

For comparison, AirPlay 2 deliberately buffers ~2 seconds. DeskLink targets
**~50–90 ms**, trading robustness for responsiveness.

## What we do to minimize delay

**Transport**
- `TCP_NODELAY` on both ends → no Nagle batching of small frames.
- WebSocket permessage-deflate **disabled** → no compression latency on audio.
- One WebSocket, audio as raw binary frames (no JSON overhead on the hot path).

**Framing / codec**
- 20 ms Opus frames by default; `desklink --low-latency` drops to **10 ms**.
- Opus in `audio`/low-delay mode; ~26 ms algorithmic delay, far less than AAC.
- PCM fallback has *zero* codec delay (at the cost of bandwidth) if you prefer:
  run the server with `--no-opus`.

**Drop-oldest, never queue-up (the key idea)**
- Every buffer in the chain is **bounded**. The server's per-client send queue
  holds at most ~100 ms; if the network stalls, the **oldest** frames are
  discarded so you snap back to live instead of drifting behind.
- The phone keeps only a tiny jitter buffer and a ~5 ms `preferredIOBufferDuration`.

**Metadata is off the audio path**
- Now-playing/artwork updates run on a separate 1 Hz control loop, so they never
  add latency or jank to the audio stream.

## Tuning knobs

| Want | Do |
|------|----|
| Lowest possible delay | `desklink --low-latency` (10 ms frames) on strong 5 GHz Wi-Fi |
| Most robust (some delay) | keep defaults; the jitter buffer can be raised in `AudioEngine.swift` |
| Zero codec delay | `desklink --no-opus` (raw PCM; needs ~1.5 Mbps) |
| Diagnose | the player shows live RTT in ms (top-right) |

## Practical tips
- Use **5 GHz Wi-Fi**, keep the PC on Ethernet if possible.
- Avoid heavy network neighbors (large downloads) on the same band.
- Mic→PC path uses the same drop-oldest discipline at 32 kbps mono.

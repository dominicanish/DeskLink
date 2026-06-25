import Foundation
import AVFoundation
import os

/// Plays the PC audio stream and (optionally) captures the mic to send back.
///
/// Playback strategy (ported from the proven `streamer-app` receiver)
/// ------------------------------------------------------------------
/// Incoming s16le frames are converted to float and written into a lock-free
/// ring buffer. An `AVAudioSourceNode` *pulls* from that ring on the audio
/// thread. We pre-roll until a small jitter buffer (~100 ms) has filled, then
/// play continuously; if we ever fall too far behind we drop the oldest audio,
/// and on underrun we output silence (never garbage). This is what keeps Wi-Fi
/// playback clean — the previous `scheduleBuffer` path had no jitter buffer and
/// glitched/under-ran constantly, which is the "noise" the phone played.
final class AudioEngine {
    private let engine = AVAudioEngine()

    // Server playback format: 48 kHz, stereo. We render float (non-interleaved).
    private let sampleRate: Double = 48_000
    private let channels = 2

    // Lock-free-ish SPSC ring buffer of interleaved float frames (L,R,L,R…).
    private let capFrames = 48_000 * 4          // 4 s of headroom
    private var ring: [Float]
    private var writeIdx = 0                    // monotonic frame counters
    private var readIdx = 0
    private var lock = os_unfair_lock()
    private var playing = false                 // false until the jitter buffer fills
    private var targetFrames = Int(48_000 * 0.1)  // ~100 ms jitter buffer

    private var sourceNode: AVAudioSourceNode?
    // The source node's render format (48 kHz float, deinterleaved stereo).
    private lazy var playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                channels: AVAudioChannelCount(channels), interleaved: false)!

    private var micActive = false
    private var onMicFrame: ((Data, UInt64) -> Void)?
    private(set) var outputMuted = false
    // Once the mic has been used we keep the `.playAndRecord` session for the rest
    // of the connection, so later mic toggles are just tap install/remove with no
    // engine restart (restarting on every toggle killed audio / added latency).
    private var recordSessionActive = false

    // Mic wire format the server expects: 48 kHz mono s16le. The tap delivers the
    // hardware's native format; we convert to this. Converter is built lazily from
    // the first buffer's actual format (we don't assume the input rate up front).
    private lazy var micWireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                                   channels: 1, interleaved: true)!
    private var micConverter: AVAudioConverter?

    init() {
        ring = [Float](repeating: 0, count: capFrames * 2)
    }

    // MARK: Session

    /// Playback-only session for listening (the common case). Using `.playback`
    /// avoids touching the microphone input node — which would otherwise crash
    /// AVAudioEngine when mic permission hasn't been granted. We upgrade to
    /// `.playAndRecord` lazily in `startMic()`.
    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.01)      // ~10 ms
        try session.setActive(true)
    }

    /// Upgrade the session so the mic can be captured. Called from `startMic`.
    private func enableRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.defaultToSpeaker` only — do NOT allow Bluetooth here: in playAndRecord
        // `.allowBluetooth` forces the low-quality HFP call profile and can route
        // playback away from the speaker, which killed the PC audio while the mic
        // was on. `.default` mode keeps full-range 48 kHz playback.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.01)   // ~10 ms; keep latency low
        try session.setActive(true)
        // Force the loudspeaker — in playAndRecord the route can otherwise default
        // to the (silent-seeming) receiver, which looked like "no audio with mic on".
        try? session.overrideOutputAudioPort(.speaker)
    }

    // MARK: Engine lifecycle

    func start() throws {
        try startPlaybackGraph()
    }

    /// Build (once) and (re)start the playback graph. Safe to call repeatedly —
    /// we reconnect the source node every time, because an engine stop/start
    /// across an audio-session category change (mic on/off) otherwise leaves the
    /// connection stale and playback goes silent until the app restarts.
    private func startPlaybackGraph() throws {
        if engine.isRunning { engine.stop() }
        if sourceNode == nil {
            let node = AVAudioSourceNode(format: playFormat) { [weak self] _, _, frameCount, abl -> OSStatus in
                guard let self else { return noErr }
                return self.render(frameCount: Int(frameCount), abl: abl)
            }
            engine.attach(node)
            sourceNode = node
        }
        engine.connect(sourceNode!, to: engine.mainMixerNode, format: playFormat)
        engine.mainMixerNode.outputVolume = outputMuted ? 0 : 1
        resetJitterBuffer()
        engine.prepare()
        try engine.start()
    }

    /// Drop any buffered audio and re-arm the pre-roll. Called on every (re)start
    /// so latency doesn't grow: while the engine is stopped (e.g. switching to the
    /// mic session) the network keeps filling the ring, and without this we'd play
    /// through that whole backlog.
    private func resetJitterBuffer() {
        os_unfair_lock_lock(&lock); writeIdx = 0; readIdx = 0; playing = false; os_unfair_lock_unlock(&lock)
    }

    func stop() {
        stopMic()
        recordSessionActive = false
        if engine.isRunning { engine.stop() }
        if let n = sourceNode { engine.detach(n); sourceNode = nil }
    }

    func setOutputMuted(_ muted: Bool) {
        outputMuted = muted
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    // MARK: Playback (server -> phone)

    /// Feed one decoded-or-pcm playback payload (s16le interleaved stereo) into
    /// the ring buffer. Called off the audio thread (the WebSocket receive loop).
    func enqueuePlayback(_ payload: Data) {
        let pcm = OpusCodec.available ? OpusCodec.decode(payload) : payload
        let frames = (pcm.count / 2) / channels
        guard frames > 0 else { return }
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let i16 = raw.bindMemory(to: Int16.self)
            os_unfair_lock_lock(&lock)
            var w = writeIdx
            for f in 0..<frames {
                let l = Float(Int16(littleEndian: i16[f * 2])) / 32768.0
                let r = Float(Int16(littleEndian: i16[f * 2 + 1])) / 32768.0
                let idx = (w % capFrames) * 2
                ring[idx] = l; ring[idx + 1] = r
                w += 1
            }
            writeIdx = w
            // Never let the backlog exceed the buffer; snap to the jitter target.
            if writeIdx - readIdx > capFrames { readIdx = writeIdx - targetFrames }
            os_unfair_lock_unlock(&lock)
        }
    }

    /// Audio-thread render callback: pull `n` frames from the ring buffer.
    private func render(frameCount n: Int, abl audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let outL = abl[0].mData!.assumingMemoryBound(to: Float.self)
        let outR = (abl.count > 1 ? abl[1].mData! : abl[0].mData!).assumingMemoryBound(to: Float.self)

        os_unfair_lock_lock(&lock)
        let available = writeIdx - readIdx
        if !playing {
            // Pre-roll: wait until the jitter buffer has filled before starting.
            if available >= targetFrames {
                playing = true
            } else {
                for i in 0..<n { outL[i] = 0; outR[i] = 0 }
                os_unfair_lock_unlock(&lock)
                return noErr
            }
        }
        // Drop-oldest if we've drifted too far ahead (bounds latency).
        let maxBuf = targetFrames * 2 + Int(sampleRate * 0.1)
        if available > maxBuf { readIdx = writeIdx - targetFrames }

        var produced = 0
        while produced < n {
            if readIdx >= writeIdx {                 // underrun → silence, re-arm pre-roll
                for i in produced..<n { outL[i] = 0; outR[i] = 0 }
                playing = false
                break
            }
            let idx = (readIdx % capFrames) * 2
            outL[produced] = ring[idx]; outR[produced] = ring[idx + 1]
            readIdx += 1; produced += 1
        }
        os_unfair_lock_unlock(&lock)
        return noErr
    }

    // MARK: Mic (phone -> server)

    /// Mic capture must be enabled *only* after the record permission is granted
    /// (the caller guarantees this). On the first enable we upgrade the session to
    /// `.playAndRecord` and rebuild the playback graph under it once; after that the
    /// engine stays running so each later toggle is just a tap install/remove — no
    /// engine restart (restarting every toggle dropped audio and added latency).
    @discardableResult
    func startMic(onFrame: @escaping (Data, UInt64) -> Void) -> Bool {
        guard !micActive else { return true }

        // First time only: upgrade to the record session and rebuild the playback
        // graph under it once. After this the engine stays running in
        // `.playAndRecord`, so enabling the mic again is just a re-tap.
        if !recordSessionActive {
            do {
                try enableRecordingSession()
                try startPlaybackGraph()   // rebuild playback under the new session
                recordSessionActive = true
            } catch {
                // Roll back to playback-only and keep playing.
                recordSessionActive = false
                restorePlaybackSession()
                return false
            }
        }

        onMicFrame = onFrame
        micConverter = nil   // rebuilt lazily from the first buffer's real format
        // The engine is already running with a settled route; tap with `format:
        // nil` so the tap adopts the input bus's own format (an explicit format
        // didn't match the bus on-device and crashed inside CreateRecordingTap).
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }
        micActive = true
        return true
    }

    /// Convert one captured buffer (native format) to 48 kHz mono s16le and ship it.
    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        let inFormat = buffer.format
        if micConverter == nil
            || micConverter!.inputFormat.sampleRate != inFormat.sampleRate
            || micConverter!.inputFormat.channelCount != inFormat.channelCount {
            micConverter = AVAudioConverter(from: inFormat, to: micWireFormat)
        }
        guard let conv = micConverter, buffer.frameLength > 0 else { return }
        let ratio = micWireFormat.sampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard cap > 0, let out = AVAudioPCMBuffer(pcmFormat: micWireFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let byteCount = Int(out.frameLength) * 2
        let data = Data(bytes: ch[0], count: byteCount)
        let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        onMicFrame?(OpusCodec.available ? OpusCodec.encode(data) : data, ts)
    }

    func stopMic() {
        guard micActive else { return }
        // Just stop capturing — keep the record session + engine running so the
        // next enable is a cheap re-tap (no restart → no audio drop, no latency).
        engine.inputNode.removeTap(onBus: 0)
        micActive = false
        onMicFrame = nil
    }

    /// Roll back to the playback-only session and rebuild playback (used only when
    /// the mic *fails* to start). The normal mic-off path keeps the record session.
    private func restorePlaybackSession() {
        try? configureSession()
        try? startPlaybackGraph()
    }
}

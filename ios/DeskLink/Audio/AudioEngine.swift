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

    private var micActive = false
    private var onMicFrame: ((Data, UInt64) -> Void)?
    private(set) var outputMuted = false

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
        // Keep options minimal so the I/O stays at 48 kHz and playback quality
        // isn't degraded. (A2DP is output-only and conflicts with record; voice
        // modes can force a lower voice-optimized rate.)
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
    }

    // MARK: Engine lifecycle

    func start() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw AudioError.format
        }
        os_unfair_lock_lock(&lock); writeIdx = 0; readIdx = 0; playing = false; os_unfair_lock_unlock(&lock)

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            return self.render(frameCount: Int(frameCount), abl: abl)
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        engine.mainMixerNode.outputVolume = outputMuted ? 0 : 1
        engine.prepare()
        try engine.start()
    }

    func stop() {
        stopMic()
        if engine.isRunning { engine.stop() }
        if let n = sourceNode { engine.detach(n); sourceNode = nil }
    }

    func setOutputMuted(_ muted: Bool) {
        outputMuted = muted
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    enum AudioError: Error { case format }

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
    /// (the caller guarantees this). We fully stop the engine before reconfiguring
    /// the session for record, then install the tap with `format: nil` so the tap
    /// adopts the input bus's *own* hardware format. Passing an explicit format
    /// (even `inputFormat`/`outputFormat(forBus:)`) didn't match the bus exactly
    /// on-device and made `CreateRecordingTap` throw an uncatchable Obj-C
    /// exception (SIGABRT) that crashed the app.
    @discardableResult
    func startMic(onFrame: @escaping (Data, UInt64) -> Void) -> Bool {
        guard !micActive else { return true }

        if engine.isRunning { engine.stop() }
        do {
            try enableRecordingSession()
        } catch {
            // Couldn't switch to record — restore playback-only and keep playing.
            restorePlaybackSession()
            return false
        }

        onMicFrame = onFrame
        micConverter = nil   // rebuilt lazily from the first buffer's real format
        let input = engine.inputNode

        // Start the engine *before* tapping so the input route/format has settled
        // (the route is still changing right after the category switch — the crash
        // log showed an in-flight `IOFormatsChanged`). Then tap with `format: nil`.
        do {
            engine.prepare()
            try engine.start()
        } catch {
            onMicFrame = nil
            restorePlaybackSession()
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
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
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        micActive = false
        onMicFrame = nil
        restorePlaybackSession()
    }

    /// Return to the playback-only session and resume playback (used after the
    /// mic stops or fails to start).
    private func restorePlaybackSession() {
        if engine.isRunning { engine.stop() }
        try? configureSession()
        try? engine.start()
    }
}

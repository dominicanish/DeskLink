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
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
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

    func startMic(onFrame: @escaping (Data, UInt64) -> Void) {
        guard !micActive else { return }
        // Upgrade the audio session and restart the engine so the input node
        // becomes available; bail out gracefully on any failure.
        engine.pause()
        do {
            try enableRecordingSession()
        } catch {
            try? engine.start()
            return
        }
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.channelCount > 0,
              let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                            channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: hwFormat, to: micFormat) else {
            try? engine.start()
            return
        }
        onMicFrame = onFrame
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = micFormat.sampleRate / hwFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, let ch = out.int16ChannelData else { return }
            let byteCount = Int(out.frameLength) * 2
            let data = Data(bytes: ch[0], count: byteCount)
            let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            self.onMicFrame?(OpusCodec.available ? OpusCodec.encode(data) : data, ts)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onMicFrame = nil
            return
        }
        micActive = true
    }

    func stopMic() {
        guard micActive else { return }
        engine.inputNode.removeTap(onBus: 0)
        micActive = false
        onMicFrame = nil
    }
}

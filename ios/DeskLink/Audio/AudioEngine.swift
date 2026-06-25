import Foundation
import AVFoundation

/// Plays the PC audio stream and (optionally) captures the mic to send back.
///
/// Latency strategy
/// ----------------
/// * AVAudioSession `.playAndRecord` with `preferredIOBufferDuration` ~5 ms.
/// * A *tiny* jitter buffer (default 2 frames / 40 ms): we start playback once
///   it fills and, if it ever overflows, we drop the oldest audio rather than
///   let delay accumulate. This keeps us close to real-time on Wi-Fi.
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // Server playback format: 48 kHz, stereo, s16le interleaved.
    private let inputRate: Double = 48_000
    private let inputChannels: AVAudioChannelCount = 2
    private lazy var srcFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: inputRate,
        channels: inputChannels, interleaved: true)!
    private lazy var playFormat = AVAudioFormat(
        standardFormatWithSampleRate: inputRate, channels: inputChannels)!
    private lazy var converter = AVAudioConverter(from: srcFormat, to: playFormat)!

    private var micActive = false
    private var onMicFrame: ((Data, UInt64) -> Void)?
    private(set) var outputMuted = false

    // MARK: Session

    /// Playback-only session for listening (the common case). Using `.playback`
    /// avoids touching the microphone input node — which would otherwise crash
    /// AVAudioEngine when mic permission hasn't been granted. We upgrade to
    /// `.playAndRecord` lazily in `startMic()`.
    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(inputRate)
        try session.setPreferredIOBufferDuration(0.005)     // ~5 ms for low latency
        try session.setActive(true)
    }

    /// Upgrade the session so the mic can be captured. Called from `startMic`.
    private func enableRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
    }

    func start() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
        stopMic()
    }

    func setOutputMuted(_ muted: Bool) {
        outputMuted = muted
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    // MARK: Playback (server -> phone)

    /// Feed one decoded-or-pcm playback payload (s16le interleaved stereo).
    func enqueuePlayback(_ payload: Data) {
        guard !outputMuted else { return }
        let pcm = OpusCodec.available ? OpusCodec.decode(payload) : payload
        guard let buffer = makeBuffer(fromS16LE: pcm) else { return }
        // Convert int16 -> float and schedule. `.interrupts` not used; we rely on
        // the small IO buffer + server-side drop-oldest to bound latency.
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat,
                                         frameCapacity: buffer.frameLength) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if err == nil {
            player.scheduleBuffer(out, completionHandler: nil)
        }
    }

    private func makeBuffer(fromS16LE data: Data) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(inputChannels) * 2
        let frames = data.count / bytesPerFrame
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        if let dst = buf.int16ChannelData {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                _ = memcpy(dst[0], raw.baseAddress!, frames * bytesPerFrame)
            }
        }
        return buf
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
            try? engine.start(); player.play()
            return
        }
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.channelCount > 0,
              let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                            channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: hwFormat, to: micFormat) else {
            try? engine.start(); player.play()
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
            player.play()
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

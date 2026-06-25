import Foundation

/// Opus encode/decode wrapper.
///
/// v1 ships with the **PCM fallback** active (`available == false`) so the app
/// builds in CI without an external Opus binary and still streams end-to-end
/// (the server negotiates raw s16le when the phone can't do Opus).
///
/// To enable real Opus: add an Opus Swift package (e.g. `SwiftOpus` /
/// `swift-opus`) to `ios/project.yml`'s `packages`, set `available = true`, and
/// fill in `encode`/`decode`. The rest of the pipeline already passes s16le
/// bytes through unchanged, so nothing else needs to move.
enum OpusCodec {
    static let available = false

    static func decode(_ payload: Data) -> Data { payload }   // PCM passthrough
    static func encode(_ pcm: Data) -> Data { pcm }           // PCM passthrough
}

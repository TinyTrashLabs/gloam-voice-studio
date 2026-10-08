import Foundation

/// `first`'s result; when it throws at runtime (HQ Voice not honoured, a
/// render error), `second` gets the same take -- availability alone doesn't
/// prove a cleaner works on this device. Moved from gloam-voice-studio-ios.
public struct FallbackDenoiser: SpeechDenoiser {
    public let first: SpeechDenoiser
    public let second: SpeechDenoiser
    public init(first: SpeechDenoiser, second: SpeechDenoiser) { self.first = first; self.second = second }
    public var name: String { "\(first.name), else \(second.name)" }
    public func denoise(_ samples24k: [Float]) async throws -> [Float] {
        do { return try await first.denoise(samples24k) } catch {
            NSLog("[denoise] %@ failed (%@); trying %@", first.name, error.localizedDescription, second.name)
            return try await second.denoise(samples24k)
        }
    }
}

extension NoiseCleanup {
    /// The cleaner every app ships: Apple's Voice Isolation where the device has
    /// it, else (or when it fails at runtime) the app's own model, e.g. the
    /// iPhone Studio's bundled DPDFNet. Nil when neither exists: the app hides
    /// the cleanup offer.
    public static func standardDenoiser(fallback: SpeechDenoiser? = nil) -> SpeechDenoiser? {
        let isolation: SpeechDenoiser? = AppleVoiceIsolation.isAvailable ? AppleVoiceIsolation() : nil
        if let isolation, let fallback { return FallbackDenoiser(first: isolation, second: fallback) }
        return isolation ?? fallback
    }
}

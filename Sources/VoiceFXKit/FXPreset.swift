import Foundation

/// A character voice, as data.
///
/// Deliberately a document rather than Swift constants: a controller can send
/// one inline, a UI can serialise its sliders straight into this shape, and new
/// characters ship without an app release.
///
/// Every field except `version` and `name` is optional. A nil section means
/// that stage is absent from the chain, not that it runs with defaults.
public struct FXPreset: Codable, Sendable, Equatable {
    public struct Pitch: Codable, Sendable, Equatable {
        /// Negative shifts down.
        public var transposeSemitones: Float
        /// INDEPENDENT of pitch. Below `transposeSemitones` reads as "too big".
        public var formantSemitones: Float
        /// Rough f0 hint. 0 = let the library detect it.
        public var formantBaseHz: Float
        public init(transposeSemitones: Float, formantSemitones: Float, formantBaseHz: Float) {
            self.transposeSemitones = transposeSemitones
            self.formantSemitones = formantSemitones
            self.formantBaseHz = formantBaseHz
        }
    }

    /// A second shifted voice summed under the first.
    public struct Detune: Codable, Sendable, Equatable {
        public var transposeSemitones: Float
        public var formantSemitones: Float
        public var formantBaseHz: Float
        public var gain: Float
    }

    public struct RingMod: Codable, Sendable, Equatable {
        public var frequencyHz: Double
        public var mix: Float
    }

    public struct Drive: Codable, Sendable, Equatable {
        public var preGain: Double
        public var postGain: Double
        public var shape1: Double
        public var shape2: Double
    }

    public struct BitCrush: Codable, Sendable, Equatable {
        public var bitDepth: Double
        public var targetRateHz: Double
    }

    public struct Reverb: Codable, Sendable, Equatable {
        public var feedback: Double
        public var lowpassHz: Double
        public var mix: Float
    }

    public struct Limiter: Codable, Sendable, Equatable {
        public var ceiling: Float
        public var releaseSeconds: Double
    }

    public var version: Int
    public var name: String
    public var highpassHz: Double?
    public var lowpassHz: Double?
    public var pitch: Pitch?
    public var detune: Detune?
    public var ringMod: RingMod?
    public var drive: Drive?
    public var bitCrush: BitCrush?
    public var dcBlock: Bool?
    public var reverb: Reverb?
    public var limiter: Limiter?

    public static let builtInNames = ["demon", "glitch", "whisper"]

    /// Returns a copy with every parameter clamped to a safe range.
    ///
    /// The spec requires out-of-range values to clamp rather than throw: a
    /// controller with a runaway slider should make the Furby sound wrong, not
    /// make the request fail. Feedback above 1.0 would make the reverb
    /// self-oscillate without bound, which is the one case that must not reach
    /// the DSP.
    public func clamped() -> FXPreset {
        var copy = self
        copy.highpassHz = highpassHz.map { min(max($0, 20), 20_000) }
        copy.lowpassHz = lowpassHz.map { min(max($0, 20), 20_000) }
        if var p = copy.pitch {
            p.transposeSemitones = min(max(p.transposeSemitones, -36), 36)
            p.formantSemitones = min(max(p.formantSemitones, -36), 36)
            p.formantBaseHz = min(max(p.formantBaseHz, 0), 2_000)
            copy.pitch = p
        }
        if var d = copy.detune {
            d.transposeSemitones = min(max(d.transposeSemitones, -36), 36)
            d.formantSemitones = min(max(d.formantSemitones, -36), 36)
            d.formantBaseHz = min(max(d.formantBaseHz, 0), 2_000)
            d.gain = min(max(d.gain, 0), 4)
            copy.detune = d
        }
        if var d = copy.drive {
            // Deliberately wide: DriveStage's waveshaper already guards its
            // own non-finite results by emitting 0, so these bounds only
            // need to keep a runaway value in the region that still
            // produces sound. Wrong-sounding is fine; silence is not.
            d.preGain = min(max(d.preGain, 0), 20)
            d.postGain = min(max(d.postGain, 0), 4)
            d.shape1 = min(max(d.shape1, -10), 10)
            d.shape2 = min(max(d.shape2, -10), 10)
            copy.drive = d
        }
        if var r = copy.ringMod {
            r.frequencyHz = min(max(r.frequencyHz, 0), 20_000)
            r.mix = min(max(r.mix, 0), 1)
            copy.ringMod = r
        }
        if var c = copy.bitCrush {
            c.bitDepth = min(max(c.bitDepth, 1), 24)
            c.targetRateHz = min(max(c.targetRateHz, 100), 192_000)
            copy.bitCrush = c
        }
        if var v = copy.reverb {
            // Strictly below 1.0: at or above it the delay lines never decay.
            v.feedback = min(max(v.feedback, 0), 0.99)
            v.lowpassHz = min(max(v.lowpassHz, 20), 20_000)
            v.mix = min(max(v.mix, 0), 1)
            copy.reverb = v
        }
        if var l = copy.limiter {
            l.ceiling = min(max(l.ceiling, 0.01), 1.0)
            l.releaseSeconds = min(max(l.releaseSeconds, 0.001), 2.0)
            copy.limiter = l
        } else {
            // "The limiter is last, always" (see FXChain+Preset) is not
            // optional over the network: an inline preset with no limiter
            // section still gets the safety stage, since the eventual
            // playback target is a small toy speaker.
            copy.limiter = Limiter(ceiling: 0.95, releaseSeconds: 0.05)
        }
        return copy
    }

    /// Loads a bundled preset. Returns nil for an unknown name — callers
    /// surface that as a request error rather than silently substituting one.
    public static func builtIn(named name: String) -> FXPreset? {
        guard builtInNames.contains(name),
              let url = Bundle.module.url(forResource: name,
                                          withExtension: "json",
                                          subdirectory: "Presets")
                ?? Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return (try? JSONDecoder().decode(FXPreset.self, from: data))?.clamped()
    }
}

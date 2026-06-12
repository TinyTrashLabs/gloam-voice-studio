import AVFAudio
import Foundation

/// Validates a prospective cloning reference before it enters the library:
/// decodable by CoreAudio and within duration bounds. Decodability implies a
/// convertible sample rate (the engine resamples on load).
public enum RefAudioValidator {
    public static let durationRange: ClosedRange<Double> = 1.0...120.0

    /// Returns the decoded duration in seconds.
    @discardableResult
    public static func validate(url: URL) throws -> Double {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw StudioError.invalidRefAudio("not a decodable audio file")
        }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard durationRange.contains(seconds) else {
            throw StudioError.invalidRefAudio(String(
                format: "duration %.1fs is outside %.0f–%.0fs",
                seconds, durationRange.lowerBound, durationRange.upperBound))
        }
        return seconds
    }
}

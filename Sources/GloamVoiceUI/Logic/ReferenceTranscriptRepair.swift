import AVFoundation
import Foundation

/// Makes a voice's reference transcript account for its reference audio.
///
/// LuxTTS sizes every render from the reference: frames per token comes from
/// the prompt, so the transcript's length against the clip's duration IS the
/// speaking rate the voice will read at. A transcript that covers only part
/// of the audio inflates that ratio — the render stretches, and the surplus
/// prompt audio gives the model reference speech to carry on with, which is
/// heard as the voice saying something from the recording before it says
/// what was asked.
///
/// Measured on the Simulator, 2026-09-11, one 123-character line:
///
///     pack       transcript          render
///     Jeff       17.4 chars/s         9.07 s
///     My voice   11.2 chars/s        13.56 s
///
/// The recorder no longer stores a transcript that misses part of the take
/// (`RecordingCheck.transcriptCoverage`). This repairs the packs made before
/// it did, once, the first time one is rendered from.
public enum ReferenceTranscriptRepair {
    /// Below this the transcript cannot be the whole of what was said. The
    /// packs that render at the right speed sit at 14.7–17.9 chars/s.
    public static let minCharsPerSecond = 13.0

    public static func rate(chars: Int, seconds: Double) -> Double {
        guard seconds > 0 else { return .infinity }
        return Double(chars) / seconds
    }

    public static func needsRepair(chars: Int, seconds: Double) -> Bool {
        rate(chars: chars, seconds: seconds) < minCharsPerSecond
    }

    /// What the clip actually says, or nil when the stored transcript already
    /// accounts for it and when nothing better can be had. Never throws: a
    /// voice that cannot be transcribed keeps the transcript it has.
    public static func repaired(reference url: URL, transcript: String,
                                transcribe: (URL) async throws -> String) async -> String? {
        guard let seconds = duration(of: url), needsRepair(chars: transcript.count, seconds: seconds) else {
            return nil
        }
        guard let heard = try? await transcribe(url) else {
            NSLog("[voice] reference reads %.1f chars/s but could not be transcribed; keeping the transcript",
                  rate(chars: transcript.count, seconds: seconds))
            return nil
        }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only ever trade up: a recogniser that heard less than the stored
        // transcript is the one that is wrong.
        guard text.count > transcript.count else { return nil }
        NSLog("[voice] reference transcript covered %.1f chars/s, transcription gives %.1f — repairing",
              rate(chars: transcript.count, seconds: seconds), rate(chars: text.count, seconds: seconds))
        return text
    }

    private static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
